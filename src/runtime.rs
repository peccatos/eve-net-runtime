use crate::config::{Config, EgressInterface};
use crate::direct_egress;
use crate::dns_cache;
use crate::exec::Executor;
use crate::health;
use crate::routing::{iprule, nft};
use crate::wifi;
use anyhow::{anyhow, Result};
use std::collections::HashMap;
use std::time::Duration;
use tokio::time;
use tracing::{info, warn};

pub struct Runtime {
    cfg: Config,
    exec: Executor,
    once: bool,
}

impl Runtime {
    pub fn new(cfg: Config, apply: bool, once: bool) -> Self {
        Self {
            cfg,
            exec: Executor::new(apply),
            once,
        }
    }

    pub async fn run(self) -> Result<()> {
        info!(apply = self.exec.is_apply(), "starting eve-net runtime");
        wifi::inspect_underlay(&self.cfg.wifi_underlay, self.exec.is_apply());

        // Explicit first reconcile. Do not depend on tokio interval first-tick semantics;
        // service startup must materialize rules immediately and predictably.
        self.reconcile_once()?;

        if self.once {
            return Ok(());
        }

        loop {
            tokio::select! {
                _ = time::sleep(Duration::from_secs(self.cfg.runtime.interval_sec)) => {
                    if let Err(err) = self.reconcile_once() {
                        warn!(error = %err, "reconcile failed");
                    }
                }
                _ = tokio::signal::ctrl_c() => {
                    info!("shutdown requested");
                    break;
                }
            }
        }

        Ok(())
    }

    fn reconcile_once(&self) -> Result<()> {
        nft::ensure_table_and_chain(&self.exec, &self.cfg)?;

        let healthy = self.healthy_egress_map()?;
        if healthy.is_empty() && self.cfg.runtime.fail_closed {
            warn!("no healthy egress interfaces; flushing policy chain because fail_closed=true");
            nft::flush_policy_chain(&self.exec, &self.cfg)?;
            return Ok(());
        }

        for egress in healthy.values() {
            iprule::ensure_route_table_default(&self.exec, egress)?;
            iprule::ensure_fwmark_rule(&self.exec, egress)?;
        }

        nft::flush_policy_chain(&self.exec, &self.cfg)?;

        for policy in self.cfg.policies.iter().filter(|policy| policy.enabled) {
            match healthy.get(policy.action.egress.as_str()) {
                Some(egress) => {
                    if let Some(domain) = policy.match_spec.domain.as_deref() {
                        let resolution = match dns_cache::resolve_for_runtime(&self.cfg, domain, self.exec.is_apply()) {
                            Ok(resolution) => resolution,
                            Err(err) => {
                                warn!(policy = %policy.id, domain = %domain, error = %err, "domain policy skipped because cache/resolve failed");
                                continue;
                            }
                        };

                        if resolution.ips.is_empty() {
                            warn!(
                                policy = %policy.id,
                                domain = %domain,
                                source = %resolution.source.as_str(),
                                error = ?resolution.last_error,
                                "domain policy skipped because no usable IPv4 addresses are available"
                            );
                            continue;
                        }

                        for ip in resolution.ips {
                            nft::add_policy_rule_for_resolved_ip(&self.exec, &self.cfg, policy, egress, &ip)?;
                            info!(
                                policy = %policy.id,
                                domain = %resolution.domain,
                                resolved_ip = %ip,
                                source = %resolution.source.as_str(),
                                egress = %egress.name,
                                kind = %egress.kind.as_str(),
                                "domain policy applied"
                            );
                        }
                    } else {
                        nft::add_policy_rule(&self.exec, &self.cfg, policy, egress)?;
                        info!(
                            policy = %policy.id,
                            egress = %egress.name,
                            kind = %egress.kind.as_str(),
                            "policy applied"
                        );
                    }
                }
                None => {
                    warn!(policy = %policy.id, egress = %policy.action.egress, "policy skipped because egress is unhealthy or disabled");
                }
            }
        }

        Ok(())
    }

    fn healthy_egress_map(&self) -> Result<HashMap<String, EgressInterface>> {
        let mut healthy = HashMap::new();

        for egress in &self.cfg.egress_interfaces {
            if !health::is_egress_healthy(egress, &self.exec) {
                continue;
            }

            let mut runtime_egress = egress.clone();
            if egress.kind == crate::config::EgressKind::Direct {
                self.apply_direct_egress_runtime_state(&mut runtime_egress)?;
            }
            healthy.insert(runtime_egress.name.clone(), runtime_egress);
        }

        Ok(healthy)
    }

    fn apply_direct_egress_runtime_state(&self, egress: &mut EgressInterface) -> Result<()> {
        if !self.exec.is_apply() {
            return Ok(());
        }

        let state = direct_egress::inspect_direct_egress(&egress.name)?;
        let drift = state.drift(egress.gateway.as_deref(), egress.source_ip.as_deref());

        if drift == direct_egress::DirectEgressDrift::MissingRuntimeDefaultRoute
            || drift == direct_egress::DirectEgressDrift::MissingRuntimeIpv4
        {
            return Err(anyhow!(
                "direct egress {} runtime state is incomplete: {}; cannot safely apply route table",
                egress.name,
                drift.as_str()
            ));
        }

        if !drift.is_drift() {
            return Ok(());
        }

        let runtime_gateway = state.runtime_gateway.as_deref().unwrap_or("none");
        let runtime_source_ip = state.runtime_source_ip.as_deref().unwrap_or("none");

        if !self.cfg.runtime.auto_refresh_direct_egress {
            return Err(anyhow!(
                "direct egress {} has stale gateway/source_ip {}/{}; runtime is {}/{}; run refresh-direct-egress --apply or set runtime.auto_refresh_direct_egress=true",
                egress.name,
                egress.gateway.as_deref().unwrap_or("none"),
                egress.source_ip.as_deref().unwrap_or("none"),
                runtime_gateway,
                runtime_source_ip
            ));
        }

        warn!(
            egress = %egress.name,
            configured_gateway = ?egress.gateway,
            configured_source_ip = ?egress.source_ip,
            runtime_gateway = %runtime_gateway,
            runtime_source_ip = %runtime_source_ip,
            drift = %drift.as_str(),
            "direct egress config drift detected; using runtime host state for this reconcile"
        );
        egress.gateway = state.runtime_gateway;
        egress.source_ip = state.runtime_source_ip;
        Ok(())
    }
}
