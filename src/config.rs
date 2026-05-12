use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs;
use std::net::SocketAddr;
use std::path::Path;

#[derive(Debug, Deserialize, Clone)]
pub struct Config {
    pub version: u32,
    #[serde(default)]
    pub runtime: RuntimeConfig,
    #[serde(default)]
    pub nft: NftConfig,
    #[serde(default)]
    pub dns_cache: DnsCacheConfig,
    #[serde(default)]
    pub dns_interception: DnsInterceptionConfig,
    pub wifi_underlay: WifiUnderlay,
    pub egress_interfaces: Vec<EgressInterface>,
    pub policies: Vec<Policy>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct RuntimeConfig {
    #[serde(default = "default_true")]
    pub dry_run: bool,
    #[serde(default = "default_interval_sec")]
    pub interval_sec: u64,
    #[serde(default = "default_true")]
    pub fail_closed: bool,
    #[serde(default = "default_true")]
    pub auto_refresh_direct_egress: bool,
}

impl Default for RuntimeConfig {
    fn default() -> Self {
        Self {
            dry_run: true,
            interval_sec: default_interval_sec(),
            fail_closed: true,
            auto_refresh_direct_egress: true,
        }
    }
}

#[derive(Debug, Deserialize, Clone)]
pub struct NftConfig {
    #[serde(default = "default_nft_table")]
    pub table: String,
    #[serde(default = "default_nft_chain")]
    pub output_chain: String,
}

impl Default for NftConfig {
    fn default() -> Self {
        Self {
            table: default_nft_table(),
            output_chain: default_nft_chain(),
        }
    }
}

#[derive(Debug, Deserialize, Clone)]
pub struct DnsCacheConfig {
    #[serde(default = "default_dns_cache_enabled")]
    pub enabled: bool,
    #[serde(default = "default_dns_cache_path")]
    pub path: String,
    #[serde(default = "default_dns_ttl_sec")]
    pub ttl_sec: u64,
    #[serde(default = "default_dns_stale_grace_sec")]
    pub stale_grace_sec: u64,
    #[serde(default = "default_true")]
    pub fail_closed_unresolved: bool,
    #[serde(default = "default_unresolved_domain_mode")]
    pub unresolved_domain_mode: String,
    #[serde(default)]
    pub dns_interception_enabled: bool,
}

impl Default for DnsCacheConfig {
    fn default() -> Self {
        Self {
            enabled: default_dns_cache_enabled(),
            path: default_dns_cache_path(),
            ttl_sec: default_dns_ttl_sec(),
            stale_grace_sec: default_dns_stale_grace_sec(),
            fail_closed_unresolved: true,
            unresolved_domain_mode: default_unresolved_domain_mode(),
            dns_interception_enabled: false,
        }
    }
}


#[derive(Debug, Deserialize, Clone)]
pub struct DnsInterceptionConfig {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default = "default_dns_proxy_listen_addr")]
    pub listen_addr: String,
    #[serde(default = "default_dns_proxy_upstream_addr")]
    pub upstream_addr: String,
    #[serde(default)]
    pub upstreams: Vec<String>,
    #[serde(default = "default_dns_proxy_timeout_ms")]
    pub timeout_ms: u64,
    #[serde(default = "default_true")]
    pub cache_answers: bool,
    #[serde(default = "default_true")]
    pub deny_unresolved_policy_domains: bool,
    #[serde(default = "default_true")]
    pub deny_aaaa_for_policy_domains: bool,
    #[serde(default = "default_true")]
    pub audit_log_queries: bool,
    #[serde(default)]
    pub auto_redirect_enabled: bool,
}

impl Default for DnsInterceptionConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            listen_addr: default_dns_proxy_listen_addr(),
            upstream_addr: default_dns_proxy_upstream_addr(),
            upstreams: Vec::new(),
            timeout_ms: default_dns_proxy_timeout_ms(),
            cache_answers: true,
            deny_unresolved_policy_domains: true,
            deny_aaaa_for_policy_domains: true,
            audit_log_queries: true,
            auto_redirect_enabled: false,
        }
    }
}

impl DnsInterceptionConfig {
    pub fn configured_upstream_entries(&self) -> Vec<String> {
        if !self.upstreams.is_empty() {
            self.upstreams.clone()
        } else if !self.upstream_addr.trim().is_empty() {
            vec![self.upstream_addr.clone()]
        } else {
            Vec::new()
        }
    }

    pub fn effective_upstreams(&self) -> Vec<SocketAddr> {
        let mut seen = HashSet::new();
        let mut upstreams = Vec::new();
        for entry in self.configured_upstream_entries() {
            let trimmed = entry.trim();
            if trimmed.is_empty() {
                continue;
            }
            if let Ok(addr) = trimmed.parse::<SocketAddr>() {
                if seen.insert(addr) {
                    upstreams.push(addr);
                }
            }
        }
        upstreams
    }

    pub fn malformed_upstream_entries(&self) -> Vec<String> {
        self.configured_upstream_entries()
            .into_iter()
            .filter_map(|entry| {
                let trimmed = entry.trim();
                if trimmed.is_empty() {
                    return None;
                }
                if trimmed.parse::<SocketAddr>().is_err() {
                    Some(entry)
                } else {
                    None
                }
            })
            .collect()
    }

    pub fn active_fallback_count(&self) -> usize {
        self.effective_upstreams().len().saturating_sub(1)
    }
}


#[derive(Debug, Deserialize, Clone)]
pub struct WifiUnderlay {
    pub interface: String,
    #[serde(default)]
    pub allowed_bands: Vec<String>,
    #[serde(default)]
    pub note: String,
}

#[derive(Debug, Deserialize, Clone)]
pub struct EgressInterface {
    #[serde(default = "default_true")]
    pub enabled: bool,
    pub name: String,
    pub kind: EgressKind,
    #[serde(default)]
    pub gateway: Option<String>,
    #[serde(default)]
    pub source_ip: Option<String>,
    pub table: u32,
    pub fwmark: u32,
    #[serde(default = "default_priority")]
    pub rule_priority: u32,
    #[serde(default)]
    pub healthcheck: HealthCheck,
}

#[derive(Debug, Deserialize, Clone, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum EgressKind {
    Direct,
    Wireguard,
    Tunnel,
}

impl EgressKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Direct => "direct",
            Self::Wireguard => "wireguard",
            Self::Tunnel => "tunnel",
        }
    }
}

#[derive(Debug, Deserialize, Clone)]
pub struct HealthCheck {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default = "default_health_target")]
    pub target_ip: String,
    #[serde(default = "default_timeout_ms")]
    pub timeout_ms: u64,
}

impl Default for HealthCheck {
    fn default() -> Self {
        Self {
            enabled: false,
            target_ip: default_health_target(),
            timeout_ms: default_timeout_ms(),
        }
    }
}

#[derive(Debug, Deserialize, Clone)]
pub struct Policy {
    pub id: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(rename = "match")]
    pub match_spec: MatchSpec,
    pub action: ActionSpec,
}

#[derive(Debug, Deserialize, Clone, Default)]
pub struct MatchSpec {
    pub dest_ip: Option<String>,
    pub dest_cidr: Option<String>,
    pub uid: Option<u32>,
    pub domain: Option<String>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct ActionSpec {
    pub egress: String,
}

impl Config {
    pub fn load(path: &Path) -> Result<Self> {
        let raw = fs::read_to_string(path)
            .with_context(|| format!("failed to read config: {}", path.display()))?;
        serde_json::from_str(&raw).with_context(|| format!("failed to parse JSON config: {}", path.display()))
    }

    pub fn validate(&self) -> Result<()> {
        if self.version == 0 {
            return Err(anyhow!("config.version must be >= 1"));
        }
        if self.runtime.interval_sec == 0 {
            return Err(anyhow!("runtime.interval_sec must be >= 1"));
        }
        if self.dns_cache.ttl_sec == 0 {
            return Err(anyhow!("dns_cache.ttl_sec must be >= 1"));
        }
        if self.dns_cache.path.trim().is_empty() {
            return Err(anyhow!("dns_cache.path cannot be empty"));
        }
        if self.dns_interception.timeout_ms == 0 {
            return Err(anyhow!("dns_interception.timeout_ms must be >= 1"));
        }
        if self.dns_interception.listen_addr.parse::<std::net::SocketAddr>().is_err() {
            return Err(anyhow!(
                "dns_interception.listen_addr must be a valid socket address, example: 127.0.0.1:5533"
            ));
        }
        let unresolved_mode = self.dns_cache.unresolved_domain_mode.trim();
        let allowed_unresolved_modes = ["soft_fail_closed_l3", "allow_stale", "hard_fail_closed_dns_required"];
        if !allowed_unresolved_modes.contains(&unresolved_mode) {
            return Err(anyhow!(
                "dns_cache.unresolved_domain_mode must be one of: soft_fail_closed_l3, allow_stale, hard_fail_closed_dns_required"
            ));
        }
        if unresolved_mode == "hard_fail_closed_dns_required" && !self.dns_cache.dns_interception_enabled {
            return Err(anyhow!(
                "dns_cache.unresolved_domain_mode=hard_fail_closed_dns_required requires dns_cache.dns_interception_enabled=true"
            ));
        }
        if unresolved_mode == "hard_fail_closed_dns_required" && !self.dns_interception.enabled {
            return Err(anyhow!(
                "dns_cache.unresolved_domain_mode=hard_fail_closed_dns_required requires dns_interception.enabled=true"
            ));
        }
        if self.wifi_underlay.interface.trim().is_empty() {
            return Err(anyhow!("wifi_underlay.interface cannot be empty"));
        }
        if self.egress_interfaces.is_empty() {
            return Err(anyhow!("egress_interfaces cannot be empty"));
        }

        let mut names = HashSet::new();
        let mut tables = HashSet::new();
        let mut marks = HashSet::new();

        for egress in &self.egress_interfaces {
            if egress.name.trim().is_empty() {
                return Err(anyhow!("egress interface name cannot be empty"));
            }
            if !names.insert(egress.name.as_str()) {
                return Err(anyhow!("duplicate egress interface name: {}", egress.name));
            }
            if !tables.insert(egress.table) {
                return Err(anyhow!("duplicate route table: {}", egress.table));
            }
            if !marks.insert(egress.fwmark) {
                return Err(anyhow!("duplicate fwmark: {}", egress.fwmark));
            }
            if egress.table == 0 || egress.fwmark == 0 {
                return Err(anyhow!("egress {} must use non-zero table and fwmark", egress.name));
            }
            if egress.kind == EgressKind::Direct && egress.gateway.as_deref().unwrap_or_default().trim().is_empty() {
                return Err(anyhow!(
                    "direct egress {} should define gateway; example: gateway=192.168.0.1",
                    egress.name
                ));
            }
        }

        let enabled_names: HashSet<&str> = self
            .egress_interfaces
            .iter()
            .filter(|egress| egress.enabled)
            .map(|egress| egress.name.as_str())
            .collect();

        let mut policy_ids = HashSet::new();
        let mut domain_policy_keys = HashSet::new();
        for policy in &self.policies {
            if policy.id.trim().is_empty() {
                return Err(anyhow!("policy id cannot be empty"));
            }
            if !policy_ids.insert(policy.id.as_str()) {
                return Err(anyhow!("duplicate policy id: {}", policy.id));
            }
            if let Some(domain) = policy.match_spec.domain.as_deref() {
                let normalized = domain.trim().trim_end_matches('.').to_ascii_lowercase();
                if normalized.is_empty() {
                    return Err(anyhow!("policy {} has empty domain match", policy.id));
                }
                if policy.enabled && !domain_policy_keys.insert(normalized.clone()) {
                    return Err(anyhow!(
                        "duplicate enabled domain policy for domain: {}. Use one active domain policy per domain to avoid fwmark conflicts",
                        normalized
                    ));
                }
            }
            if !names.contains(policy.action.egress.as_str()) {
                return Err(anyhow!(
                    "policy {} references unknown egress {}",
                    policy.id,
                    policy.action.egress
                ));
            }
            if policy.enabled && !enabled_names.contains(policy.action.egress.as_str()) {
                return Err(anyhow!(
                    "policy {} references disabled egress {}; disable the policy or enable the egress",
                    policy.id,
                    policy.action.egress
                ));
            }
            let has_any_match = policy.match_spec.dest_ip.is_some()
                || policy.match_spec.dest_cidr.is_some()
                || policy.match_spec.uid.is_some()
                || policy.match_spec.domain.is_some();
            if !has_any_match {
                return Err(anyhow!("policy {} has empty match block", policy.id));
            }
        }

        Ok(())
    }
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct DnsCacheFile {
    pub version: u32,
    pub generated_by: String,
    pub entries: Vec<DnsCacheEntry>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct DnsCacheEntry {
    pub domain: String,
    pub resolved_ipv4: Vec<String>,
    pub resolved_at_epoch: u64,
    pub expires_at_epoch: u64,
    pub source: String,
    pub last_error: Option<String>,
}

fn default_true() -> bool { true }
fn default_interval_sec() -> u64 { 15 }
fn default_nft_table() -> String { "eve_net".to_string() }
fn default_nft_chain() -> String { "output_mangle".to_string() }
fn default_health_target() -> String { "1.1.1.1".to_string() }
fn default_timeout_ms() -> u64 { 1500 }
fn default_priority() -> u32 { 1000 }
fn default_dns_cache_enabled() -> bool { true }
fn default_dns_cache_path() -> String { "/var/lib/eve-net/dns-cache.json".to_string() }
fn default_dns_ttl_sec() -> u64 { 300 }
fn default_dns_stale_grace_sec() -> u64 { 3600 }
fn default_unresolved_domain_mode() -> String { "soft_fail_closed_l3".to_string() }

fn default_dns_proxy_listen_addr() -> String { "127.0.0.1:5533".to_string() }
fn default_dns_proxy_upstream_addr() -> String { "1.1.1.1:53".to_string() }
fn default_dns_proxy_timeout_ms() -> u64 { 1500 }
