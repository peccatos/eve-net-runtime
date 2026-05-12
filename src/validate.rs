use crate::config::{Config, EgressKind};
use crate::direct_egress;
use crate::dns;
use crate::dns_cache;
use anyhow::Result;
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::Path;

pub fn print_validate(cfg: &Config) -> Result<()> {
    println!("eve-net validate");
    println!("schema: OK");

    let mut warnings: Vec<String> = Vec::new();
    let mut notes: Vec<String> = Vec::new();

    validate_domain_policy_collisions(cfg, &mut warnings)?;
    validate_dns_fail_closed_semantics(cfg, &mut warnings, &mut notes);
    validate_dns_cache(cfg, &mut warnings)?;
    validate_dns_interception(cfg, &mut warnings, &mut notes);
    validate_egress_interfaces(cfg, &mut warnings, &mut notes);

    println!("warnings: {}", warnings.len());
    for warning in &warnings {
        println!("  - {warning}");
    }

    println!("notes: {}", notes.len());
    for note in &notes {
        println!("  - {note}");
    }

    println!("result: {}", if warnings.is_empty() { "PASS" } else { "WARN" });
    Ok(())
}

fn validate_domain_policy_collisions(cfg: &Config, warnings: &mut Vec<String>) -> Result<()> {
    let mut enabled_domains: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut all_domains: BTreeMap<String, Vec<String>> = BTreeMap::new();

    for policy in &cfg.policies {
        if let Some(domain) = policy.match_spec.domain.as_deref() {
            let normalized = dns::normalize_domain(domain)?;
            all_domains.entry(normalized.clone()).or_default().push(policy.id.clone());
            if policy.enabled {
                enabled_domains.entry(normalized).or_default().push(policy.id.clone());
            }
        }
    }

    for (domain, policies) in enabled_domains {
        if policies.len() > 1 {
            warnings.push(format!(
                "duplicate enabled domain policies for {domain}: {}. Only one active policy per domain is safe.",
                policies.join(", ")
            ));
        }
    }

    for (domain, policies) in all_domains {
        if policies.len() > 1 {
            warnings.push(format!(
                "multiple domain policy definitions for {domain}: {}. Keep templates disabled or remove dead duplicates.",
                policies.join(", ")
            ));
        }
    }

    Ok(())
}

fn validate_dns_fail_closed_semantics(cfg: &Config, warnings: &mut Vec<String>, notes: &mut Vec<String>) {
    let has_enabled_domain_policy = cfg
        .policies
        .iter()
        .any(|policy| policy.enabled && policy.match_spec.domain.is_some());

    if !has_enabled_domain_policy {
        return;
    }

    match cfg.dns_cache.unresolved_domain_mode.trim() {
        "soft_fail_closed_l3" => {
            notes.push(
                "domain unresolved mode is soft_fail_closed_l3: eve-net skips nft route rules for unresolved domains, but cannot hard-block future DNS answers without DNS interception".to_string(),
            );
        }
        "allow_stale" => {
            notes.push(
                "domain unresolved mode is allow_stale: stale cached IPs may be used during stale_grace_sec after live DNS failure".to_string(),
            );
        }
        "hard_fail_closed_dns_required" => {
            if cfg.dns_cache.dns_interception_enabled {
                notes.push(
                    "hard_fail_closed_dns_required requested and dns_interception_enabled=true; ensure a DNS deny/proxy layer is actually installed".to_string(),
                );
            } else {
                warnings.push(
                    "hard_fail_closed_dns_required requested but dns_interception_enabled=false".to_string(),
                );
            }
        }
        other => warnings.push(format!(
            "unsupported dns_cache.unresolved_domain_mode={other}"
        )),
    }

    if cfg.dns_cache.fail_closed_unresolved && !cfg.dns_cache.dns_interception_enabled {
        notes.push(
            "dns_cache.fail_closed_unresolved=true currently means L3 soft fail-closed only; true hard fail-closed for domains requires DNS interception".to_string(),
        );
    }
}

fn validate_dns_cache(cfg: &Config, warnings: &mut Vec<String>) -> Result<()> {
    let mut enabled_domains = BTreeSet::new();
    for policy in cfg.policies.iter().filter(|policy| policy.enabled) {
        if let Some(domain) = policy.match_spec.domain.as_deref() {
            enabled_domains.insert(dns::normalize_domain(domain)?);
        }
    }

    if enabled_domains.is_empty() {
        return Ok(());
    }

    if !cfg.dns_cache.enabled {
        warnings.push("enabled domain policies exist, but dns_cache.enabled=false".to_string());
        return Ok(());
    }

    let cache_path = Path::new(&cfg.dns_cache.path);
    let cache = match dns_cache::load_cache_or_empty(cache_path) {
        Ok(cache) => cache,
        Err(err) => {
            warnings.push(format!(
                "cannot read DNS cache at {}: {err}; run validate with sudo or fix cache permissions",
                cache_path.display()
            ));
            return Ok(());
        }
    };
    let now = dns_cache::now_epoch();

    for domain in enabled_domains {
        match cache.entries.iter().find(|entry| entry.domain == domain) {
            Some(entry) => {
                if entry.resolved_ipv4.is_empty() {
                    warnings.push(format!("domain {domain} has cache entry with zero IPv4 addresses"));
                }
                if entry.expires_at_epoch <= now {
                    let age = now.saturating_sub(entry.expires_at_epoch);
                    warnings.push(format!(
                        "domain {domain} cache is STALE by {age}s; run dns-refresh or wait for eve-net-dns-refresh.timer"
                    ));
                }
                if let Some(err) = entry.last_error.as_deref() {
                    warnings.push(format!("domain {domain} cache has last_error: {err}"));
                }
            }
            None => {
                warnings.push(format!(
                    "domain {domain} is enabled but missing from DNS cache; run dns-refresh --apply"
                ));
            }
        }
    }

    Ok(())
}


fn validate_dns_interception(cfg: &Config, warnings: &mut Vec<String>, notes: &mut Vec<String>) {
    let effective_upstreams = cfg.dns_interception.effective_upstreams();
    for entry in cfg.dns_interception.malformed_upstream_entries() {
        warnings.push(format!("dns_interception upstream entry is malformed and will be ignored: {entry}"));
    }

    if !cfg.dns_interception.enabled {
        notes.push("dns_interception.enabled=false: DNS proxy is installed but disabled by default; this is the safe v0.10 posture".to_string());
        return;
    }

    notes.push(format!(
        "dns_interception.enabled=true: local DNS proxy will listen on {} and forward to {} upstream(s)",
        cfg.dns_interception.listen_addr,
        effective_upstreams.len()
    ));

    if cfg.dns_interception.upstreams.is_empty() && cfg.dns_interception.upstream_addr.trim().is_empty() {
        warnings.push("dns_interception.enabled=true but dns_interception.upstreams is empty and upstream_addr is missing".to_string());
    }
    if effective_upstreams.is_empty() {
        warnings.push("dns_interception.enabled=true but no valid DNS upstream is configured".to_string());
    } else if effective_upstreams.len() == 1 {
        notes.push("dns_interception has only one valid upstream; failover is not active".to_string());
    } else {
        notes.push(format!(
            "dns_interception upstream failover active: primary={}, fallback_count={}",
            effective_upstreams[0],
            effective_upstreams.len().saturating_sub(1)
        ));
    }

    if !cfg.dns_cache.dns_interception_enabled {
        warnings.push("dns_interception.enabled=true but dns_cache.dns_interception_enabled=false; hard fail-closed semantics are not fully declared".to_string());
    }
    if cfg.dns_cache.unresolved_domain_mode != "hard_fail_closed_dns_required" {
        notes.push(format!(
            "dns_interception is enabled but unresolved_domain_mode={} ; strict hard fail-closed uses hard_fail_closed_dns_required",
            cfg.dns_cache.unresolved_domain_mode
        ));
    }
    if cfg.dns_interception.auto_redirect_enabled {
        warnings.push("dns_interception.auto_redirect_enabled=true is only a declaration in v0.10; host-wide DNS redirect is not installed automatically".to_string());
    }
}

fn validate_egress_interfaces(cfg: &Config, warnings: &mut Vec<String>, notes: &mut Vec<String>) {
    for egress in cfg.egress_interfaces.iter().filter(|egress| egress.enabled) {
        let link_path = format!("/sys/class/net/{}", egress.name);
        let link_exists = fs::metadata(&link_path).is_ok();
        if !link_exists {
            warnings.push(format!("enabled egress {} is missing from /sys/class/net", egress.name));
            continue;
        }

        let state = fs::read_to_string(format!("{link_path}/operstate"))
            .map(|raw| raw.trim().to_string())
            .unwrap_or_else(|_| "unknown".to_string());

        match egress.kind {
            EgressKind::Direct if state != "up" => warnings.push(format!(
                "direct egress {} state is {state}; expected up",
                egress.name
            )),
            EgressKind::Direct => match direct_egress::inspect_direct_egress(&egress.name) {
                Ok(runtime_state) => {
                    let drift = runtime_state.drift(egress.gateway.as_deref(), egress.source_ip.as_deref());
                    if drift.is_drift() {
                        warnings.push(format!(
                            "direct egress {} has {}: configured gateway/source_ip={}/{} runtime gateway/source_ip={}/{}; run refresh-direct-egress --apply or keep runtime.auto_refresh_direct_egress=true",
                            egress.name,
                            drift.as_str(),
                            display_opt(egress.gateway.as_deref()),
                            display_opt(egress.source_ip.as_deref()),
                            display_opt(runtime_state.runtime_gateway.as_deref()),
                            display_opt(runtime_state.runtime_source_ip.as_deref())
                        ));
                    } else if drift != direct_egress::DirectEgressDrift::Ok {
                        warnings.push(format!(
                            "direct egress {} runtime state incomplete: {}",
                            egress.name,
                            drift.as_str()
                        ));
                    }
                }
                Err(err) => notes.push(format!(
                    "direct egress {} runtime drift check unavailable: {err}",
                    egress.name
                )),
            },
            EgressKind::Tunnel if state == "unknown" => notes.push(format!(
                "tunnel egress {} reports operstate=unknown; this is normal for many tun devices",
                egress.name
            )),
            EgressKind::Wireguard if state == "unknown" => notes.push(format!(
                "wireguard egress {} reports operstate=unknown; verify with wg show",
                egress.name
            )),
            _ => {}
        }
    }
}

fn display_opt(value: Option<&str>) -> &str {
    value.filter(|value| !value.trim().is_empty()).unwrap_or("none")
}
