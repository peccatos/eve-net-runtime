use crate::config::Config;
use crate::dns_cache;
use anyhow::{anyhow, Context, Result};
use std::collections::BTreeSet;
use std::net::{SocketAddr, ToSocketAddrs};

pub fn resolve_domain_v4(domain: &str) -> Result<Vec<String>> {
    let domain = normalize_domain(domain)?;
    let addrs = (domain.as_str(), 0)
        .to_socket_addrs()
        .with_context(|| format!("failed to resolve domain: {domain}"))?;

    let mut ips = BTreeSet::new();
    for addr in addrs {
        if let SocketAddr::V4(v4) = addr {
            ips.insert(v4.ip().to_string());
        }
    }

    Ok(ips.into_iter().collect())
}

pub fn normalize_domain(domain: &str) -> Result<String> {
    let value = domain.trim().trim_end_matches('.').to_lowercase();

    if value.is_empty() {
        return Err(anyhow!("domain cannot be empty"));
    }
    if value.contains("://") || value.contains('/') || value.contains(' ') {
        return Err(anyhow!(
            "domain must be a bare hostname, not URL/path: {value}. Example: example.com"
        ));
    }
    if value.len() > 253 {
        return Err(anyhow!("domain is too long: {value}"));
    }
    if !value
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || ch == '-' || ch == '.')
    {
        return Err(anyhow!("domain contains unsupported characters: {value}"));
    }
    if value.split('.').any(|label| label.is_empty() || label.len() > 63) {
        return Err(anyhow!("domain has invalid labels: {value}"));
    }

    Ok(value)
}

pub fn print_domain_resolve(cfg: &Config, domain: Option<&str>) -> Result<()> {
    println!("eve-net domain resolve");

    if let Some(domain) = domain {
        print_one_live(domain, None)?;
        return Ok(());
    }

    let mut found = false;
    for policy in &cfg.policies {
        if let Some(domain) = policy.match_spec.domain.as_deref() {
            found = true;
            print_one_live(domain, Some((policy.id.as_str(), policy.action.egress.as_str(), policy.enabled)))?;
        }
    }

    if !found {
        println!("domain_policies: none");
    }

    Ok(())
}

pub fn refresh_cache_command(cfg: &Config, apply: bool) -> Result<()> {
    println!("eve-net dns refresh");
    println!("cache_enabled: {}", yes_no(cfg.dns_cache.enabled));
    println!("cache_path: {}", cfg.dns_cache.path);
    println!("write_cache: {}", yes_no(apply));

    let results = dns_cache::refresh_domain_policies(cfg, apply)?;
    if results.is_empty() {
        println!("domain_policies: none");
        return Ok(());
    }

    for result in results {
        println!("domain: {}", result.domain);
        println!("  source: {}", result.source.as_str());
        if let Some(err) = result.last_error.as_deref() {
            println!("  last_error: {err}");
        }
        if result.ips.is_empty() {
            println!("  ipv4: none");
        } else {
            println!("  ipv4:");
            for ip in &result.ips {
                println!("    - {ip}");
            }
        }
        if let Some(entry) = result.entry.as_ref() {
            println!("  resolved_at_epoch: {}", entry.resolved_at_epoch);
            println!("  expires_at_epoch: {}", entry.expires_at_epoch);
        }
    }

    if !apply {
        println!("note: dry-run; rerun with --apply to write cache to disk");
    }
    Ok(())
}

pub fn prune_cache_command(cfg: &Config, apply: bool) -> Result<()> {
    println!("eve-net dns prune");
    println!("cache_path: {}", cfg.dns_cache.path);
    println!("write_cache: {}", yes_no(apply));
    let (before, after) = dns_cache::prune_cache_to_configured_domains(cfg, apply)?;
    println!("entries_before: {before}");
    println!("entries_after: {after}");
    println!("removed: {}", before.saturating_sub(after));
    if !apply {
        println!("note: dry-run; rerun with --apply to write pruned cache to disk");
    }
    Ok(())
}

fn print_one_live(domain: &str, policy: Option<(&str, &str, bool)>) -> Result<()> {
    let normalized = normalize_domain(domain)?;
    if let Some((id, egress, enabled)) = policy {
        println!("policy: {id}");
        println!("  enabled: {}", if enabled { "yes" } else { "no" });
        println!("  egress: {egress}");
        println!("  domain: {normalized}");
    } else {
        println!("domain: {normalized}");
    }

    let ips = resolve_domain_v4(&normalized)?;
    if ips.is_empty() {
        println!("  ipv4: none");
    } else {
        println!("  ipv4:");
        for ip in ips {
            println!("    - {ip}");
        }
    }
    Ok(())
}

fn yes_no(value: bool) -> &'static str {
    if value { "yes" } else { "no" }
}
