use crate::config::{Config, DnsCacheEntry, DnsCacheFile};
use crate::dns;
use anyhow::{Context, Result};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone)]
pub struct DomainResolution {
    pub domain: String,
    pub ips: Vec<String>,
    pub source: ResolutionSource,
    pub entry: Option<DnsCacheEntry>,
    pub last_error: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResolutionSource {
    Live,
    CacheFresh,
    CacheStale,
    Empty,
}

impl ResolutionSource {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Live => "live",
            Self::CacheFresh => "cache-fresh",
            Self::CacheStale => "cache-stale",
            Self::Empty => "empty",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RefreshMode {
    PreferFreshCache,
    ForceLive,
}

pub fn resolve_for_runtime(cfg: &Config, domain: &str, write_cache: bool) -> Result<DomainResolution> {
    resolve_with_mode(cfg, domain, write_cache, RefreshMode::PreferFreshCache)
}

pub fn refresh_domain(cfg: &Config, domain: &str, write_cache: bool) -> Result<DomainResolution> {
    resolve_with_mode(cfg, domain, write_cache, RefreshMode::ForceLive)
}

pub fn resolve_with_mode(
    cfg: &Config,
    domain: &str,
    write_cache: bool,
    mode: RefreshMode,
) -> Result<DomainResolution> {
    let domain = dns::normalize_domain(domain)?;

    if !cfg.dns_cache.enabled {
        let ips = dns::resolve_domain_v4(&domain)?;
        return Ok(DomainResolution {
            domain,
            ips,
            source: ResolutionSource::Live,
            entry: None,
            last_error: None,
        });
    }

    let now = now_epoch();
    let mut cache = load_cache_or_empty(Path::new(&cfg.dns_cache.path))?;
    let existing = cache.entries.iter().find(|entry| entry.domain == domain).cloned();

    if mode == RefreshMode::PreferFreshCache {
        if let Some(entry) = existing.as_ref() {
            if entry.expires_at_epoch > now && !entry.resolved_ipv4.is_empty() {
                return Ok(DomainResolution {
                    domain,
                    ips: entry.resolved_ipv4.clone(),
                    source: ResolutionSource::CacheFresh,
                    entry: Some(entry.clone()),
                    last_error: entry.last_error.clone(),
                });
            }
        }
    }

    match dns::resolve_domain_v4(&domain) {
        Ok(ips) if !ips.is_empty() => {
            let ips = unique_sorted(ips);
            let entry = DnsCacheEntry {
                domain: domain.clone(),
                resolved_ipv4: ips.clone(),
                resolved_at_epoch: now,
                expires_at_epoch: now.saturating_add(cfg.dns_cache.ttl_sec),
                source: "live".to_string(),
                last_error: None,
            };
            upsert_entry(&mut cache, entry.clone());
            if write_cache {
                save_cache(Path::new(&cfg.dns_cache.path), &cache)?;
            }
            Ok(DomainResolution {
                domain,
                ips,
                source: ResolutionSource::Live,
                entry: Some(entry),
                last_error: None,
            })
        }
        Ok(_) => fallback_after_live_failure(
            cfg,
            domain,
            existing,
            now,
            write_cache,
            &mut cache,
            "resolver returned zero IPv4 addresses".to_string(),
        ),
        Err(err) => fallback_after_live_failure(
            cfg,
            domain,
            existing,
            now,
            write_cache,
            &mut cache,
            err.to_string(),
        ),
    }
}

fn fallback_after_live_failure(
    cfg: &Config,
    domain: String,
    existing: Option<DnsCacheEntry>,
    now: u64,
    write_cache: bool,
    cache: &mut DnsCacheFile,
    error: String,
) -> Result<DomainResolution> {
    if let Some(mut entry) = existing {
        entry.last_error = Some(error.clone());
        let within_grace = entry.expires_at_epoch.saturating_add(cfg.dns_cache.stale_grace_sec) >= now;
        let allow_stale_mode = cfg.dns_cache.unresolved_domain_mode.trim() == "allow_stale";
        let can_use_stale = (allow_stale_mode || !cfg.dns_cache.fail_closed_unresolved)
            && within_grace
            && !entry.resolved_ipv4.is_empty();
        upsert_entry(cache, entry.clone());
        if write_cache {
            save_cache(Path::new(&cfg.dns_cache.path), cache)?;
        }
        if can_use_stale {
            return Ok(DomainResolution {
                domain,
                ips: entry.resolved_ipv4.clone(),
                source: ResolutionSource::CacheStale,
                entry: Some(entry),
                last_error: Some(error),
            });
        }
        return Ok(DomainResolution {
            domain,
            ips: Vec::new(),
            source: ResolutionSource::Empty,
            entry: Some(entry),
            last_error: Some(error),
        });
    }

    Ok(DomainResolution {
        domain,
        ips: Vec::new(),
        source: ResolutionSource::Empty,
        entry: None,
        last_error: Some(error),
    })
}

pub fn refresh_domain_policies(cfg: &Config, write_cache: bool) -> Result<Vec<DomainResolution>> {
    let mut domains = BTreeSet::new();
    for policy in cfg.policies.iter().filter(|policy| policy.enabled) {
        if let Some(domain) = policy.match_spec.domain.as_deref() {
            domains.insert(dns::normalize_domain(domain)?);
        }
    }

    let mut out = Vec::new();
    for domain in domains {
        out.push(refresh_domain(cfg, &domain, write_cache)?);
    }
    Ok(out)
}

pub fn load_cache_or_empty(path: &Path) -> Result<DnsCacheFile> {
    match fs::read_to_string(path) {
        Ok(raw) => {
            let mut cache: DnsCacheFile = serde_json::from_str(&raw)
                .with_context(|| format!("failed to parse DNS cache: {}", path.display()))?;
            cache.entries.sort_by(|a, b| a.domain.cmp(&b.domain));
            Ok(cache)
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(empty_cache()),
        Err(err) => Err(err).with_context(|| format!("failed to read DNS cache: {}", path.display())),
    }
}

pub fn save_cache(path: &Path, cache: &DnsCacheFile) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create DNS cache directory: {}", parent.display()))?;
    }
    let mut normalized = cache.clone();
    normalized.entries.sort_by(|a, b| a.domain.cmp(&b.domain));
    let raw = serde_json::to_string_pretty(&normalized)? + "\n";
    fs::write(path, raw).with_context(|| format!("failed to write DNS cache: {}", path.display()))
}

pub fn prune_cache_to_configured_domains(cfg: &Config, write_cache: bool) -> Result<(usize, usize)> {
    let path = Path::new(&cfg.dns_cache.path);
    let mut cache = load_cache_or_empty(path)?;
    let before = cache.entries.len();
    let keep: BTreeSet<String> = cfg
        .policies
        .iter()
        .filter_map(|policy| policy.match_spec.domain.as_deref())
        .filter_map(|domain| dns::normalize_domain(domain).ok())
        .collect();
    cache.entries.retain(|entry| keep.contains(&entry.domain));
    let after = cache.entries.len();
    if write_cache && before != after {
        save_cache(path, &cache)?;
    }
    Ok((before, after))
}

pub fn configured_domain_cache_snapshot(cfg: &Config) -> Result<BTreeMap<String, Option<DnsCacheEntry>>> {
    let cache = load_cache_or_empty(Path::new(&cfg.dns_cache.path))?;
    let mut map = BTreeMap::new();
    for policy in &cfg.policies {
        if let Some(domain) = policy.match_spec.domain.as_deref() {
            let normalized = dns::normalize_domain(domain)?;
            map.entry(normalized).or_insert(None);
        }
    }
    for entry in cache.entries {
        if map.contains_key(&entry.domain) {
            map.insert(entry.domain.clone(), Some(entry));
        }
    }
    Ok(map)
}

pub fn now_epoch() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_secs())
        .unwrap_or(0)
}

fn empty_cache() -> DnsCacheFile {
    DnsCacheFile {
        version: 1,
        generated_by: "eve-net".to_string(),
        entries: Vec::new(),
    }
}

fn upsert_entry(cache: &mut DnsCacheFile, entry: DnsCacheEntry) {
    if let Some(existing) = cache.entries.iter_mut().find(|existing| existing.domain == entry.domain) {
        *existing = entry;
    } else {
        cache.entries.push(entry);
    }
}

fn unique_sorted(values: Vec<String>) -> Vec<String> {
    values.into_iter().collect::<BTreeSet<_>>().into_iter().collect()
}

pub fn upsert_live_ips_from_proxy(cfg: &Config, domain: &str, ips: Vec<String>, write_cache: bool) -> Result<Option<DnsCacheEntry>> {
    let domain = dns::normalize_domain(domain)?;
    let ips = unique_sorted(ips);
    if ips.is_empty() {
        return Ok(None);
    }
    if !cfg.dns_cache.enabled {
        return Ok(None);
    }

    let path = Path::new(&cfg.dns_cache.path);
    let mut cache = load_cache_or_empty(path)?;
    let now = now_epoch();
    let entry = DnsCacheEntry {
        domain,
        resolved_ipv4: ips,
        resolved_at_epoch: now,
        expires_at_epoch: now.saturating_add(cfg.dns_cache.ttl_sec),
        source: "dns-proxy".to_string(),
        last_error: None,
    };
    upsert_entry(&mut cache, entry.clone());
    if write_cache {
        save_cache(path, &cache)?;
    }
    Ok(Some(entry))
}
