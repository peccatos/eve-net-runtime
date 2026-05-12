use crate::config::{Config, Policy};
use crate::dns;
use crate::dns_cache;
use anyhow::{anyhow, Context, Result};
use std::collections::BTreeSet;
use std::net::SocketAddr;
use std::time::Duration;
use tokio::net::UdpSocket;
use tokio::time;
use tracing::{debug, info, warn};

const QTYPE_A: u16 = 1;
const QTYPE_AAAA: u16 = 28;
const QCLASS_IN: u16 = 1;
const RCODE_REFUSED: u16 = 5;
const RCODE_SERVFAIL: u16 = 2;

#[derive(Debug, Clone)]
struct DnsQuestion {
    domain: String,
    qtype: u16,
    qclass: u16,
}

#[derive(Debug, Clone)]
struct ARecordSet {
    ips: Vec<String>,
}

pub async fn run_dns_proxy(cfg: &Config, write_cache: bool) -> Result<()> {
    if !cfg.dns_interception.enabled {
        return Err(anyhow!(
            "dns_interception.enabled=false. Enable it in config before running dns-proxy. This is disabled by default for safety."
        ));
    }

    let listen_addr: SocketAddr = cfg.dns_interception.listen_addr.parse()?;
    let upstreams = cfg.dns_interception.effective_upstreams();
    if upstreams.is_empty() {
        return Err(anyhow!(
            "dns_interception has no valid upstreams; configure dns_interception.upstreams or upstream_addr"
        ));
    }
    let socket = UdpSocket::bind(listen_addr)
        .await
        .with_context(|| format!("failed to bind DNS proxy listener: {listen_addr}"))?;

    info!(
        listen = %listen_addr,
        primary_upstream = %upstreams[0],
        upstreams = ?upstreams,
        fallback_count = upstreams.len().saturating_sub(1),
        write_cache,
        "eve-net DNS proxy started"
    );
    info!(auto_redirect_enabled = cfg.dns_interception.auto_redirect_enabled, "DNS proxy does not install host-wide redirect automatically");

    let mut buf = vec![0u8; 4096];
    loop {
        let (len, peer) = socket.recv_from(&mut buf).await?;
        let query = buf[..len].to_vec();
        let response = handle_query(cfg, &query, &upstreams, write_cache).await;
        match response {
            Ok(response) => {
                if let Err(err) = socket.send_to(&response, peer).await {
                    warn!(peer = %peer, error = %err, "failed to send DNS response");
                }
            }
            Err(err) => {
                warn!(peer = %peer, error = %err, "DNS query handling failed; returning SERVFAIL");
                let response = build_error_response(&query, RCODE_SERVFAIL).unwrap_or_else(|_| query.clone());
                let _ = socket.send_to(&response, peer).await;
            }
        }
    }
}

pub fn print_dns_intercept_status(cfg: &Config) -> Result<()> {
    println!("eve-net dns intercept status");
    println!("dns_interception:");
    println!("  enabled: {}", yes_no(cfg.dns_interception.enabled));
    println!("  listen_addr: {}", cfg.dns_interception.listen_addr);
    println!("  upstream_addr: {}", cfg.dns_interception.upstream_addr);
    let effective_upstreams = cfg.dns_interception.effective_upstreams();
    println!("  primary_upstream: {}", effective_upstreams.first().map(ToString::to_string).unwrap_or_else(|| "none".to_string()));
    println!("  upstreams:");
    if effective_upstreams.is_empty() {
        println!("    none");
    } else {
        for upstream in &effective_upstreams {
            println!("    - {}", upstream);
        }
    }
    println!("  active_fallback_count: {}", cfg.dns_interception.active_fallback_count());
    for entry in cfg.dns_interception.malformed_upstream_entries() {
        println!("  warning: malformed upstream ignored: {}", entry);
    }
    println!("  timeout_ms: {}", cfg.dns_interception.timeout_ms);
    println!("  cache_answers: {}", yes_no(cfg.dns_interception.cache_answers));
    println!("  deny_unresolved_policy_domains: {}", yes_no(cfg.dns_interception.deny_unresolved_policy_domains));
    println!("  deny_aaaa_for_policy_domains: {}", yes_no(cfg.dns_interception.deny_aaaa_for_policy_domains));
    println!("  audit_log_queries: {}", yes_no(cfg.dns_interception.audit_log_queries));
    println!("  auto_redirect_enabled: {}", yes_no(cfg.dns_interception.auto_redirect_enabled));
    println!("  hard_fail_closed_ready: {}", yes_no(hard_fail_closed_ready(cfg)));
    println!("  note: DNS proxy diagnostics do not rewrite NetworkManager or /etc/resolv.conf automatically");
    println!();

    println!("dns_cache_link:");
    println!("  dns_cache.dns_interception_enabled: {}", yes_no(cfg.dns_cache.dns_interception_enabled));
    println!("  unresolved_domain_mode: {}", cfg.dns_cache.unresolved_domain_mode);
    println!("  hard_fail_closed_ready: {}", yes_no(hard_fail_closed_ready(cfg)));
    if !hard_fail_closed_ready(cfg) {
        println!("  warning: hard domain fail-closed is not active until dns_interception.enabled=true and dns_cache.dns_interception_enabled=true");
    }
    println!();

    println!("domain_policies:");
    let mut found = false;
    for policy in cfg.policies.iter().filter(|policy| policy.enabled) {
        if let Some(domain) = policy.match_spec.domain.as_deref() {
            found = true;
            println!("  - {} -> {}", dns::normalize_domain(domain)?, policy.action.egress);
        }
    }
    if !found {
        println!("  none");
    }

    Ok(())
}

async fn handle_query(cfg: &Config, query: &[u8], upstreams: &[SocketAddr], write_cache: bool) -> Result<Vec<u8>> {
    let question = parse_question(query)?;
    let policy = find_enabled_domain_policy(cfg, &question.domain)?;
    let is_policy_domain = policy.is_some();

    if cfg.dns_interception.audit_log_queries {
        debug!(domain = %question.domain, qtype = %qtype_name(question.qtype), policy_domain = is_policy_domain, "dns query");
    }

    if is_policy_domain && question.qtype == QTYPE_AAAA && cfg.dns_interception.deny_aaaa_for_policy_domains {
        warn!(domain = %question.domain, "denying AAAA query for policy domain to avoid IPv6 bypass in v0.10");
        return build_error_response(query, RCODE_REFUSED);
    }

    let response = forward_query_with_failover(query, upstreams, cfg.dns_interception.timeout_ms).await;
    let response = match response {
        Ok(response) => response,
        Err(err) => {
            if is_policy_domain && cfg.dns_interception.deny_unresolved_policy_domains && cfg.dns_cache.fail_closed_unresolved {
                warn!(domain = %question.domain, error = %err, "upstream DNS failed for policy domain; hard-fail-closing DNS response");
                return build_error_response(query, RCODE_REFUSED);
            }
            return Err(err);
        }
    };

    if is_policy_domain && question.qtype == QTYPE_A && question.qclass == QCLASS_IN {
        let records = parse_a_records(&response)?;
        if records.ips.is_empty() {
            if cfg.dns_interception.deny_unresolved_policy_domains && cfg.dns_cache.fail_closed_unresolved {
                warn!(domain = %question.domain, "no A records for policy domain; hard-fail-closing DNS response");
                return build_error_response(query, RCODE_REFUSED);
            }
        } else if cfg.dns_interception.cache_answers {
            dns_cache::upsert_live_ips_from_proxy(cfg, &question.domain, records.ips.clone(), write_cache)?;
            info!(domain = %question.domain, ips = ?records.ips, write_cache, "DNS proxy cached A answers for policy domain");
        }
    }

    Ok(response)
}

async fn forward_query_with_failover(query: &[u8], upstreams: &[SocketAddr], timeout_ms: u64) -> Result<Vec<u8>> {
    let mut failures = Vec::new();
    for upstream in upstreams {
        match forward_query(query, *upstream, timeout_ms).await {
            Ok(response) => {
                debug!(upstream = %upstream, "DNS upstream answered");
                return Ok(response);
            }
            Err(err) => {
                let reason = format!("{err:#}");
                warn!(upstream = %upstream, error = %reason, "DNS upstream failed; trying next upstream if available");
                failures.push(format!("{upstream}: {reason}"));
            }
        }
    }

    Err(anyhow!("all DNS upstreams failed: {}", failures.join("; ")))
}

async fn forward_query(query: &[u8], upstream: SocketAddr, timeout_ms: u64) -> Result<Vec<u8>> {
    let socket = UdpSocket::bind("0.0.0.0:0").await?;
    socket
        .send_to(query, upstream)
        .await
        .with_context(|| format!("failed to send DNS query to upstream {upstream}"))?;
    let mut buf = vec![0u8; 4096];
    let (len, _) = time::timeout(Duration::from_millis(timeout_ms), socket.recv_from(&mut buf))
        .await
        .with_context(|| format!("upstream DNS timeout after {timeout_ms}ms for {upstream}"))?
        .with_context(|| format!("failed to receive DNS response from upstream {upstream}"))?;
    Ok(buf[..len].to_vec())
}

fn find_enabled_domain_policy<'a>(cfg: &'a Config, domain: &str) -> Result<Option<&'a Policy>> {
    let domain = dns::normalize_domain(domain)?;
    for policy in cfg.policies.iter().filter(|policy| policy.enabled) {
        if let Some(policy_domain) = policy.match_spec.domain.as_deref() {
            let policy_domain = dns::normalize_domain(policy_domain)?;
            if policy_domain == domain {
                return Ok(Some(policy));
            }
        }
    }
    Ok(None)
}

fn hard_fail_closed_ready(cfg: &Config) -> bool {
    cfg.dns_interception.enabled
        && cfg.dns_cache.dns_interception_enabled
        && cfg.dns_cache.unresolved_domain_mode.trim() == "hard_fail_closed_dns_required"
}

fn parse_question(buf: &[u8]) -> Result<DnsQuestion> {
    if buf.len() < 12 {
        return Err(anyhow!("DNS packet too short"));
    }
    let qdcount = read_u16(buf, 4)?;
    if qdcount == 0 {
        return Err(anyhow!("DNS packet has zero questions"));
    }
    let (domain, pos) = read_qname(buf, 12)?;
    if pos + 4 > buf.len() {
        return Err(anyhow!("DNS question is truncated"));
    }
    let qtype = read_u16(buf, pos)?;
    let qclass = read_u16(buf, pos + 2)?;
    Ok(DnsQuestion { domain, qtype, qclass })
}

fn parse_a_records(buf: &[u8]) -> Result<ARecordSet> {
    if buf.len() < 12 {
        return Err(anyhow!("DNS response too short"));
    }
    let qdcount = read_u16(buf, 4)? as usize;
    let ancount = read_u16(buf, 6)? as usize;
    let mut pos = 12;
    for _ in 0..qdcount {
        pos = skip_name(buf, pos)?;
        if pos + 4 > buf.len() {
            return Err(anyhow!("DNS response question section truncated"));
        }
        pos += 4;
    }

    let mut ips = BTreeSet::new();
    for _ in 0..ancount {
        pos = skip_name(buf, pos)?;
        if pos + 10 > buf.len() {
            return Err(anyhow!("DNS answer section truncated"));
        }
        let rr_type = read_u16(buf, pos)?;
        let rr_class = read_u16(buf, pos + 2)?;
        let rdlen = read_u16(buf, pos + 8)? as usize;
        pos += 10;
        if pos + rdlen > buf.len() {
            return Err(anyhow!("DNS answer rdata truncated"));
        }
        if rr_type == QTYPE_A && rr_class == QCLASS_IN && rdlen == 4 {
            let ip = format!("{}.{}.{}.{}", buf[pos], buf[pos + 1], buf[pos + 2], buf[pos + 3]);
            ips.insert(ip);
        }
        pos += rdlen;
    }

    Ok(ARecordSet { ips: ips.into_iter().collect() })
}

fn build_error_response(query: &[u8], rcode: u16) -> Result<Vec<u8>> {
    if query.len() < 12 {
        return Err(anyhow!("cannot build DNS error response from truncated query"));
    }
    let mut response = query.to_vec();
    let query_flags = read_u16(query, 2)?;
    let rd = query_flags & 0x0100;
    let flags = 0x8000 | rd | 0x0080 | (rcode & 0x000f); // QR + RD preserve + RA + RCODE
    write_u16(&mut response, 2, flags)?;
    write_u16(&mut response, 6, 0)?;  // ANCOUNT
    write_u16(&mut response, 8, 0)?;  // NSCOUNT
    write_u16(&mut response, 10, 0)?; // ARCOUNT
    Ok(response)
}

fn read_qname(buf: &[u8], mut pos: usize) -> Result<(String, usize)> {
    let mut labels = Vec::new();
    loop {
        if pos >= buf.len() {
            return Err(anyhow!("DNS qname truncated"));
        }
        let len = buf[pos] as usize;
        pos += 1;
        if len == 0 {
            break;
        }
        if len & 0xc0 != 0 {
            return Err(anyhow!("compressed qname in question is unsupported"));
        }
        if len > 63 || pos + len > buf.len() {
            return Err(anyhow!("invalid DNS qname label"));
        }
        let label = std::str::from_utf8(&buf[pos..pos + len]).context("DNS qname label is not UTF-8")?;
        labels.push(label.to_ascii_lowercase());
        pos += len;
    }
    let domain = labels.join(".");
    let domain = dns::normalize_domain(&domain)?;
    Ok((domain, pos))
}

fn skip_name(buf: &[u8], mut pos: usize) -> Result<usize> {
    loop {
        if pos >= buf.len() {
            return Err(anyhow!("DNS name truncated"));
        }
        let len = buf[pos] as usize;
        if len == 0 {
            return Ok(pos + 1);
        }
        if len & 0xc0 == 0xc0 {
            if pos + 1 >= buf.len() {
                return Err(anyhow!("DNS compressed pointer truncated"));
            }
            return Ok(pos + 2);
        }
        if len > 63 {
            return Err(anyhow!("invalid DNS name label length"));
        }
        pos += 1 + len;
    }
}

fn read_u16(buf: &[u8], pos: usize) -> Result<u16> {
    if pos + 2 > buf.len() {
        return Err(anyhow!("u16 read out of bounds"));
    }
    Ok(u16::from_be_bytes([buf[pos], buf[pos + 1]]))
}

fn write_u16(buf: &mut [u8], pos: usize, value: u16) -> Result<()> {
    if pos + 2 > buf.len() {
        return Err(anyhow!("u16 write out of bounds"));
    }
    let bytes = value.to_be_bytes();
    buf[pos] = bytes[0];
    buf[pos + 1] = bytes[1];
    Ok(())
}

fn qtype_name(qtype: u16) -> &'static str {
    match qtype {
        QTYPE_A => "A",
        QTYPE_AAAA => "AAAA",
        _ => "OTHER",
    }
}

fn yes_no(value: bool) -> &'static str {
    if value { "yes" } else { "no" }
}
