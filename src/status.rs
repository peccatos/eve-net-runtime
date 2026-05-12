use crate::config::{Config, EgressInterface, EgressKind};
use crate::direct_egress;
use crate::dns_cache;
use crate::exec::Executor;
use crate::wireguard;
use anyhow::Result;
use std::fs;
use std::process::Command;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ProbeState {
    Ok,
    Missing,
    PermissionDenied,
    Error,
}

impl ProbeState {
    fn label(self) -> &'static str {
        match self {
            Self::Ok => "OK",
            Self::Missing => "MISSING",
            Self::PermissionDenied => "PERMISSION_DENIED",
            Self::Error => "ERROR",
        }
    }
}

pub fn print_status(cfg: &Config) -> Result<()> {
    let exec = Executor::new(false);

    println!("eve-net status");
    println!("version: {}", cfg.version);
    println!("runtime_config: {}", if cfg.runtime.dry_run { "dry-run" } else { "apply-enabled" });
    println!("fail_closed: {}", cfg.runtime.fail_closed);
    println!("interval_sec: {}", cfg.runtime.interval_sec);
    println!("auto_refresh_direct_egress: {}", yes_no(cfg.runtime.auto_refresh_direct_egress));
    println!();

    print_dns_cache_config(cfg);
    print_dns_interception_config(cfg);
    print_underlay(cfg);
    let nft_chain_output = print_nft_status(cfg);
    print_egress_status(cfg, &exec);
    print_policy_status(cfg, &nft_chain_output);

    Ok(())
}

pub fn print_dns_cache_status(cfg: &Config) -> Result<()> {
    println!("eve-net dns cache");
    print_dns_cache_config(cfg);
    let snapshot = match dns_cache::configured_domain_cache_snapshot(cfg) {
        Ok(snapshot) => snapshot,
        Err(err) => {
            let label = cache_read_error_label(&err);
            println!("cache_read: {label}");
            println!("cache_path: {}", cfg.dns_cache.path);
            println!("note: cannot inspect DNS cache as current user; run with sudo or use scripts/preflight.sh, which uses an isolated temp cache");
            println!("error: {err}");
            return Ok(());
        }
    };
    if snapshot.is_empty() {
        println!("domain_policies: none");
        return Ok(());
    }
    println!("domain_cache_entries:");
    let now = dns_cache::now_epoch();
    for (domain, entry) in snapshot {
        println!("  - domain: {domain}");
        match entry {
            Some(entry) => {
                let freshness = cache_freshness_label(entry.expires_at_epoch, now);
                println!("    state: {}", freshness);
                println!("    source: {}", entry.source);
                println!("    resolved_at_epoch: {}", entry.resolved_at_epoch);
                println!("    expires_at_epoch: {}", entry.expires_at_epoch);
                println!("    seconds_until_expiry: {}", entry.expires_at_epoch.saturating_sub(now));
                if freshness == "STALE" {
                    println!("    warning: cache entry is stale; run dns-refresh --apply or enable eve-net-dns-refresh.timer");
                }
                if let Some(err) = entry.last_error.as_deref() {
                    println!("    last_error: {err}");
                }
                if entry.resolved_ipv4.is_empty() {
                    println!("    resolved_ipv4: none");
                } else {
                    println!("    resolved_ipv4:");
                    for ip in entry.resolved_ipv4 {
                        println!("      - {ip}");
                    }
                }
            }
            None => {
                println!("    state: MISSING");
                println!("    warning: no cache entry yet; run: sudo /usr/local/bin/eve-net dns-refresh --config /etc/eve-net/policy.json --apply");
            }
        }
    }
    Ok(())
}

fn print_dns_cache_config(cfg: &Config) {
    println!("dns_cache:");
    println!("  enabled: {}", yes_no(cfg.dns_cache.enabled));
    println!("  path: {}", cfg.dns_cache.path);
    println!("  ttl_sec: {}", cfg.dns_cache.ttl_sec);
    println!("  stale_grace_sec: {}", cfg.dns_cache.stale_grace_sec);
    println!("  fail_closed_unresolved: {}", cfg.dns_cache.fail_closed_unresolved);
    println!("  unresolved_domain_mode: {}", cfg.dns_cache.unresolved_domain_mode);
    println!("  dns_interception_enabled: {}", yes_no(cfg.dns_cache.dns_interception_enabled));
    if cfg.dns_cache.fail_closed_unresolved && !cfg.dns_cache.dns_interception_enabled {
        println!("  note: unresolved domain policies are soft-fail-closed at L3: eve-net will not create nft route rules for unknown IPs");
        println!("  note: hard domain fail-closed requires DNS interception or DNS deny/proxy support");
    }
    println!();
}


fn print_dns_interception_config(cfg: &Config) {
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
    println!("  hard_fail_closed_ready: {}", yes_no(hard_fail_closed_ready(cfg)));
    for entry in cfg.dns_interception.malformed_upstream_entries() {
        println!("  warning: malformed upstream ignored: {}", entry);
    }
    println!("  timeout_ms: {}", cfg.dns_interception.timeout_ms);
    println!("  cache_answers: {}", yes_no(cfg.dns_interception.cache_answers));
    println!("  deny_unresolved_policy_domains: {}", yes_no(cfg.dns_interception.deny_unresolved_policy_domains));
    println!("  deny_aaaa_for_policy_domains: {}", yes_no(cfg.dns_interception.deny_aaaa_for_policy_domains));
    println!("  auto_redirect_enabled: {}", yes_no(cfg.dns_interception.auto_redirect_enabled));
    if cfg.dns_interception.enabled && !cfg.dns_cache.dns_interception_enabled {
        println!("  warning: DNS proxy is enabled, but dns_cache.dns_interception_enabled=false; hard fail-closed semantics are not fully declared");
    }
    if cfg.dns_interception.auto_redirect_enabled {
        println!("  warning: auto_redirect_enabled is a declaration only in v0.10; host-wide DNS redirect is not installed automatically");
    }
    println!();
}

fn print_underlay(cfg: &Config) {
    let iface = cfg.wifi_underlay.interface.as_str();
    let exists = interface_exists(iface);
    let state = interface_state(iface).unwrap_or_else(|| "missing".to_string());

    println!("underlay:");
    println!("  interface: {}", iface);
    println!("  exists: {}", yes_no(exists));
    println!("  state: {}", state);
    if !cfg.wifi_underlay.allowed_bands.is_empty() {
        println!("  bands: {}", cfg.wifi_underlay.allowed_bands.join(", "));
    }
    println!();
}

fn print_nft_status(cfg: &Config) -> String {
    let table_probe = nft_probe(["list", "table", "inet", cfg.nft.table.as_str()]);
    let chain_probe = nft_probe([
        "list",
        "chain",
        "inet",
        cfg.nft.table.as_str(),
        cfg.nft.output_chain.as_str(),
    ]);

    let chain_output = if chain_probe == ProbeState::Ok {
        nft_stdout([
            "list",
            "chain",
            "inet",
            cfg.nft.table.as_str(),
            cfg.nft.output_chain.as_str(),
        ])
        .unwrap_or_default()
    } else {
        String::new()
    };

    let counters_present = chain_output.contains("counter packets");

    println!("nft:");
    println!("  table inet {}: {}", cfg.nft.table, table_probe.label());
    println!("  chain {}: {}", cfg.nft.output_chain, chain_probe.label());
    println!("  counters: {}", yes_no(counters_present));

    if table_probe == ProbeState::PermissionDenied || chain_probe == ProbeState::PermissionDenied {
        println!("  note: run status with sudo to inspect nftables on this host");
    }

    let counter_lines: Vec<&str> = chain_output
        .lines()
        .map(str::trim)
        .filter(|line| line.contains("counter packets") && line.contains("meta mark set"))
        .collect();

    if !counter_lines.is_empty() {
        println!("  matched_rules:");
        for line in counter_lines {
            println!("    {}", line);
        }
    }
    println!();

    chain_output
}

fn print_egress_status(cfg: &Config, exec: &Executor) {
    let rules = exec.capture_or_empty("ip", ["rule", "show"]);

    println!("egress:");
    for egress in &cfg.egress_interfaces {
        print_one_egress(egress, &rules, exec);
    }
    println!();
}

fn print_one_egress(egress: &EgressInterface, rules: &str, exec: &Executor) {
    let state = interface_state(&egress.name).unwrap_or_else(|| "missing".to_string());
    let table = egress.table.to_string();
    let route_table = exec.capture_or_empty("ip", ["route", "show", "table", table.as_str()]);
    let route_ok = route_table.lines().any(|line| line.starts_with("default"));
    let rule_ok = rules.lines().any(|line| {
        line.contains(&format!("fwmark 0x{:x}", egress.fwmark)) && line.contains(&format!("lookup {}", egress.table))
    });

    println!("  - name: {}", egress.name);
    println!("    enabled: {}", yes_no(egress.enabled));
    println!("    kind: {}", egress.kind.as_str());
    println!("    state: {}", state);
    println!("    table: {} ({})", egress.table, ok_bad(route_ok));
    println!("    fwmark: {} ({})", egress.fwmark, ok_bad(rule_ok));
    println!("    gateway: {}", display_opt(egress.gateway.as_deref()));
    println!("    source_ip: {}", display_opt(egress.source_ip.as_deref()));
    if egress.kind == EgressKind::Direct {
        match direct_egress::inspect_direct_egress(&egress.name) {
            Ok(state) => {
                let drift = state.drift(egress.gateway.as_deref(), egress.source_ip.as_deref());
                println!("    runtime_gateway: {}", display_opt(state.runtime_gateway.as_deref()));
                println!("    runtime_source_ip: {}", display_opt(state.runtime_source_ip.as_deref()));
                println!("    drift: {}", drift.as_str());
                if drift.is_drift() {
                    println!(
                        "    warning: direct egress {} source_ip/gateway differs from runtime host state; run refresh-direct-egress or reconcile with auto-refresh",
                        egress.name
                    );
                }
            }
            Err(err) => {
                println!("    runtime_gateway: unknown");
                println!("    runtime_source_ip: unknown");
                println!("    drift: UNKNOWN");
                println!("    warning: failed to inspect direct egress runtime state: {err}");
            }
        }
    }
    if egress.kind == EgressKind::Wireguard {
        println!("    wireguard: {}", wireguard::wireguard_summary(&egress.name));
    }
}

fn print_policy_status(cfg: &Config, nft_chain_output: &str) {
    let enabled = cfg.policies.iter().filter(|policy| policy.enabled).count();

    println!("policies:");
    println!("  total: {}", cfg.policies.len());
    println!("  enabled: {}", enabled);
    for policy in &cfg.policies {
        println!(
            "  - {} -> {} [{}]",
            policy.id,
            policy.action.egress,
            if policy.enabled { "enabled" } else { "disabled" }
        );

        if let Some(domain) = policy.match_spec.domain.as_deref() {
            print_domain_policy_status(cfg, policy.action.egress.as_str(), domain, policy.enabled, nft_chain_output);
        }
    }
}

fn print_domain_policy_status(
    cfg: &Config,
    egress_name: &str,
    domain: &str,
    policy_enabled: bool,
    nft_chain_output: &str,
) {
    println!("    domain: {}", domain);

    let egress = cfg.egress_interfaces.iter().find(|egress| egress.name == egress_name);
    let Some(egress) = egress else {
        println!("    warning: egress not found in config");
        return;
    };

    match dns_cache::resolve_for_runtime(cfg, domain, false) {
        Ok(resolution) if resolution.ips.is_empty() => {
            println!("    resolution_source: {}", resolution.source.as_str());
            if resolution.source.as_str() == "live" && cfg.dns_cache.enabled && policy_enabled {
                println!("    warning: DNS cache had no fresh entry; status used live resolver. Run dns-refresh --apply to persist it.");
            }
            if let Some(err) = resolution.last_error.as_deref() {
                println!("    last_error: {err}");
            }
            println!("    resolved_ipv4: none");
            if policy_enabled {
                println!("    warning: enabled domain policy has no usable IPv4 addresses; fail_closed_unresolved={}", cfg.dns_cache.fail_closed_unresolved);
                if cfg.dns_cache.fail_closed_unresolved && !cfg.dns_cache.dns_interception_enabled {
                    println!("    warning: this is L3 soft fail-closed only; hard domain blocking requires DNS interception");
                }
            }
        }
        Ok(resolution) => {
            println!("    resolution_source: {}", resolution.source.as_str());
            if resolution.source.as_str() == "live" && cfg.dns_cache.enabled && policy_enabled {
                println!("    warning: DNS cache had no fresh entry; status used live resolver. Run dns-refresh --apply to persist it.");
            }
            if let Some(entry) = resolution.entry.as_ref() {
                let now = dns_cache::now_epoch();
                let freshness = cache_freshness_label(entry.expires_at_epoch, now);
                println!("    cache_state: {}", freshness);
                println!("    expires_at_epoch: {}", entry.expires_at_epoch);
                println!("    seconds_until_expiry: {}", entry.expires_at_epoch.saturating_sub(now));
                if freshness == "STALE" && policy_enabled {
                    println!("    warning: enabled domain policy is using stale DNS cache; run dns-refresh --apply or enable eve-net-dns-refresh.timer");
                }
                if let Some(err) = entry.last_error.as_deref() {
                    println!("    last_error: {err}");
                }
            }
            println!("    resolved_ipv4:");
            let mut missing = 0usize;
            for ip in resolution.ips {
                let nft_state = nft_rule_state(nft_chain_output, ip.as_str(), egress.fwmark);
                if policy_enabled && nft_state == "MISSING" {
                    missing += 1;
                }
                println!("      - {} [nft: {}]", ip, nft_state);
            }
            if policy_enabled && missing > 0 {
                println!(
                    "    warning: domain policy is enabled but {} resolved IP rule(s) are missing from nft; run: sudo /usr/local/bin/eve-net reconcile --config /etc/eve-net/policy.json --apply",
                    missing
                );
            }
        }
        Err(err) => {
            let label = cache_read_error_label(&err);
            println!("    resolution_source: unavailable");
            println!("    cache_state: {label}");
            println!("    resolved_ipv4: UNKNOWN");
            println!("    note: failed to inspect domain resolution/cache: {err}");
            if label == "PERMISSION_DENIED" {
                println!("    note: run status with sudo or use an isolated temp cache during preflight");
            }
            if policy_enabled {
                println!("    warning: enabled domain policy cannot be resolved right now");
                if cfg.dns_cache.fail_closed_unresolved && !cfg.dns_cache.dns_interception_enabled {
                    println!("    warning: no nft rule can be created without an IP; hard fail-closed requires DNS interception");
                }
            }
        }
    }
}


fn cache_read_error_label(err: &anyhow::Error) -> &'static str {
    let text = format!("{err:#}").to_lowercase();
    if text.contains("permission denied") || text.contains("os error 13") {
        "PERMISSION_DENIED"
    } else if text.contains("no such file") || text.contains("not found") {
        "MISSING"
    } else {
        "ERROR"
    }
}

fn nft_rule_state(chain_output: &str, ip: &str, fwmark: u32) -> &'static str {
    if chain_output.trim().is_empty() {
        return "UNKNOWN";
    }

    let mark_hex_padded = format!("0x{fwmark:08x}");
    let mark_hex_short = format!("0x{fwmark:x}");

    let ok = chain_output.lines().any(|line| {
        line.contains(&format!("ip daddr {ip}"))
            && line.contains("meta mark set")
            && (line.contains(&mark_hex_padded) || line.contains(&mark_hex_short) || line.contains(&fwmark.to_string()))
    });

    if ok { "OK" } else { "MISSING" }
}

fn nft_probe<const N: usize>(args: [&str; N]) -> ProbeState {
    let output = Command::new("nft").args(args).output();

    match output {
        Ok(output) if output.status.success() => ProbeState::Ok,
        Ok(output) => {
            let stderr = String::from_utf8_lossy(&output.stderr).to_lowercase();
            if stderr.contains("operation not permitted")
                || stderr.contains("permission denied")
                || stderr.contains("not enough privileges")
            {
                ProbeState::PermissionDenied
            } else if stderr.contains("no such file or directory")
                || stderr.contains("does not exist")
                || stderr.contains("not found")
            {
                ProbeState::Missing
            } else {
                ProbeState::Error
            }
        }
        Err(_) => ProbeState::Error,
    }
}

fn nft_stdout<const N: usize>(args: [&str; N]) -> Result<String, std::io::Error> {
    let output = Command::new("nft").args(args).output()?;
    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

fn interface_exists(name: &str) -> bool {
    fs::metadata(format!("/sys/class/net/{name}")).is_ok()
}

fn interface_state(name: &str) -> Option<String> {
    if !interface_exists(name) {
        return None;
    }
    fs::read_to_string(format!("/sys/class/net/{name}/operstate"))
        .ok()
        .map(|raw| raw.trim().to_string())
}

fn ok_bad(value: bool) -> &'static str {
    if value { "OK" } else { "MISSING" }
}

fn cache_freshness_label(expires_at_epoch: u64, now: u64) -> &'static str {
    if expires_at_epoch > now { "FRESH" } else { "STALE" }
}

fn yes_no(value: bool) -> &'static str {
    if value { "yes" } else { "no" }
}

fn hard_fail_closed_ready(cfg: &Config) -> bool {
    cfg.dns_interception.enabled
        && cfg.dns_cache.dns_interception_enabled
        && cfg.dns_cache.unresolved_domain_mode.trim() == "hard_fail_closed_dns_required"
}

fn display_opt(value: Option<&str>) -> &str {
    value.filter(|value| !value.trim().is_empty()).unwrap_or("none")
}
