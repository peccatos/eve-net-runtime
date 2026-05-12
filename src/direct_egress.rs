use crate::config::{Config, EgressKind};
use anyhow::{anyhow, Context, Result};
use serde_json::Value;
use std::fs;
use std::path::Path;
use std::process::Command;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DirectEgressDrift {
    Ok,
    GatewayDrift,
    SourceIpDrift,
    BothDrift,
    MissingRuntimeDefaultRoute,
    MissingRuntimeIpv4,
}

impl DirectEgressDrift {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Ok => "OK",
            Self::GatewayDrift => "GATEWAY_DRIFT",
            Self::SourceIpDrift => "SOURCE_IP_DRIFT",
            Self::BothDrift => "BOTH_DRIFT",
            Self::MissingRuntimeDefaultRoute => "MISSING_RUNTIME_DEFAULT_ROUTE",
            Self::MissingRuntimeIpv4 => "MISSING_RUNTIME_IPV4",
        }
    }

    pub fn is_drift(self) -> bool {
        matches!(self, Self::GatewayDrift | Self::SourceIpDrift | Self::BothDrift)
    }
}

#[derive(Debug, Clone)]
pub struct DirectEgressRuntimeState {
    pub runtime_gateway: Option<String>,
    pub runtime_source_ip: Option<String>,
}

impl DirectEgressRuntimeState {
    pub fn drift(&self, configured_gateway: Option<&str>, configured_source_ip: Option<&str>) -> DirectEgressDrift {
        let Some(runtime_gateway) = self.runtime_gateway.as_deref() else {
            return DirectEgressDrift::MissingRuntimeDefaultRoute;
        };
        let Some(runtime_source_ip) = self.runtime_source_ip.as_deref() else {
            return DirectEgressDrift::MissingRuntimeIpv4;
        };

        let gateway_drift = configured_gateway
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(|value| value != runtime_gateway)
            .unwrap_or(false);
        let source_drift = configured_source_ip
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(|value| value != runtime_source_ip)
            .unwrap_or(false);

        match (gateway_drift, source_drift) {
            (false, false) => DirectEgressDrift::Ok,
            (true, false) => DirectEgressDrift::GatewayDrift,
            (false, true) => DirectEgressDrift::SourceIpDrift,
            (true, true) => DirectEgressDrift::BothDrift,
        }
    }
}

#[derive(Debug, Clone)]
pub struct DirectEgressRefreshPlan {
    pub name: String,
    pub configured_gateway: Option<String>,
    pub configured_source_ip: Option<String>,
    pub runtime_gateway: Option<String>,
    pub runtime_source_ip: Option<String>,
    pub drift: DirectEgressDrift,
}

impl DirectEgressRefreshPlan {
    pub fn needs_update(&self) -> bool {
        self.drift.is_drift()
    }
}

pub fn inspect_direct_egress(name: &str) -> Result<DirectEgressRuntimeState> {
    let route_json = command_stdout("ip", ["-j", "route", "show", "default", "dev", name])
        .with_context(|| format!("failed to inspect runtime default route for direct egress {name}"))?;
    let addr_json = command_stdout("ip", ["-j", "-4", "addr", "show", "dev", name])
        .with_context(|| format!("failed to inspect runtime IPv4 address for direct egress {name}"))?;

    let runtime_gateway = parse_default_route_gateway(&route_json)?;
    let runtime_source_ip = parse_primary_ipv4_addr(&addr_json)?.or_else(|| parse_default_route_prefsrc(&route_json).ok().flatten());

    Ok(DirectEgressRuntimeState {
        runtime_gateway,
        runtime_source_ip,
    })
}

pub fn plan_refresh(cfg: &Config) -> Vec<DirectEgressRefreshPlan> {
    cfg.egress_interfaces
        .iter()
        .filter(|egress| egress.enabled && egress.kind == EgressKind::Direct)
        .map(|egress| {
            let state = inspect_direct_egress(&egress.name).unwrap_or(DirectEgressRuntimeState {
                runtime_gateway: None,
                runtime_source_ip: None,
            });
            let drift = state.drift(egress.gateway.as_deref(), egress.source_ip.as_deref());
            DirectEgressRefreshPlan {
                name: egress.name.clone(),
                configured_gateway: egress.gateway.clone(),
                configured_source_ip: egress.source_ip.clone(),
                runtime_gateway: state.runtime_gateway,
                runtime_source_ip: state.runtime_source_ip,
                drift,
            }
        })
        .collect()
}

pub fn print_refresh_direct_egress(config_path: &Path, apply: bool) -> Result<()> {
    let cfg = Config::load(config_path)?;
    let plans = plan_refresh(&cfg);

    println!("eve-net refresh direct egress");
    println!("config: {}", config_path.display());

    if plans.is_empty() {
        println!("direct_egress: none enabled");
        println!("result: PASS");
        return Ok(());
    }

    for plan in &plans {
        println!("egress: {}", plan.name);
        println!(
            "  gateway: {} -> {}",
            display_opt(plan.configured_gateway.as_deref()),
            display_opt(plan.runtime_gateway.as_deref())
        );
        println!(
            "  source_ip: {} -> {}",
            display_opt(plan.configured_source_ip.as_deref()),
            display_opt(plan.runtime_source_ip.as_deref())
        );
        println!("  drift: {}", plan.drift.as_str());
        let status = if plan.runtime_gateway.is_none() || plan.runtime_source_ip.is_none() {
            "skipped_missing_runtime_state"
        } else if !plan.needs_update() {
            "unchanged"
        } else if apply {
            "updated"
        } else {
            "planned"
        };
        println!("  status: {status}");
    }

    if apply {
        apply_refresh(config_path, &plans)?;
    }

    println!("result: PASS");
    Ok(())
}

fn apply_refresh(config_path: &Path, plans: &[DirectEgressRefreshPlan]) -> Result<()> {
    let raw = fs::read_to_string(config_path)
        .with_context(|| format!("failed to read config: {}", config_path.display()))?;
    let mut value: Value = serde_json::from_str(&raw)
        .with_context(|| format!("failed to parse JSON config: {}", config_path.display()))?;

    let egresses = value
        .get_mut("egress_interfaces")
        .and_then(Value::as_array_mut)
        .ok_or_else(|| anyhow!("config egress_interfaces must be an array"))?;

    for plan in plans.iter().filter(|plan| plan.needs_update()) {
        let (Some(runtime_gateway), Some(runtime_source_ip)) = (&plan.runtime_gateway, &plan.runtime_source_ip) else {
            continue;
        };
        for egress in egresses.iter_mut() {
            if egress.get("name").and_then(Value::as_str) == Some(plan.name.as_str())
                && egress.get("kind").and_then(Value::as_str) == Some("direct")
            {
                egress["gateway"] = Value::String(runtime_gateway.clone());
                egress["source_ip"] = Value::String(runtime_source_ip.clone());
            }
        }
    }

    fs::write(config_path, serde_json::to_string_pretty(&value)? + "\n")
        .with_context(|| format!("failed to write config: {}", config_path.display()))?;
    Ok(())
}

fn command_stdout<const N: usize>(program: &str, args: [&str; N]) -> Result<String> {
    let output = Command::new(program)
        .args(args)
        .output()
        .with_context(|| format!("failed to spawn {program}"))?;
    if !output.status.success() {
        return Err(anyhow!("command failed: {} {}", program, args.join(" ")));
    }
    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

fn parse_default_route_gateway(raw: &str) -> Result<Option<String>> {
    let value: Value = serde_json::from_str(raw)?;
    let Some(routes) = value.as_array() else {
        return Ok(None);
    };
    Ok(routes
        .iter()
        .find_map(|route| route.get("gateway").and_then(Value::as_str).map(str::to_string)))
}

fn parse_default_route_prefsrc(raw: &str) -> Result<Option<String>> {
    let value: Value = serde_json::from_str(raw)?;
    let Some(routes) = value.as_array() else {
        return Ok(None);
    };
    Ok(routes
        .iter()
        .find_map(|route| route.get("prefsrc").and_then(Value::as_str).map(str::to_string)))
}

fn parse_primary_ipv4_addr(raw: &str) -> Result<Option<String>> {
    let value: Value = serde_json::from_str(raw)?;
    let Some(links) = value.as_array() else {
        return Ok(None);
    };
    for link in links {
        if let Some(addrs) = link.get("addr_info").and_then(Value::as_array) {
            for addr in addrs {
                if addr.get("family").and_then(Value::as_str) == Some("inet") {
                    if let Some(local) = addr.get("local").and_then(Value::as_str) {
                        return Ok(Some(local.to_string()));
                    }
                }
            }
        }
    }
    Ok(None)
}

fn display_opt(value: Option<&str>) -> &str {
    value.filter(|value| !value.trim().is_empty()).unwrap_or("none")
}
