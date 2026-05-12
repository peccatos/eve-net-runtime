use crate::config::EgressInterface;
use crate::exec::Executor;
use std::fs;
use tracing::{debug, info, warn};

pub fn is_egress_healthy(egress: &EgressInterface, exec: &Executor) -> bool {
    if !egress.enabled {
        debug!(egress = %egress.name, "egress disabled by config");
        return false;
    }

    let exists = interface_exists(&egress.name);
    let usable = exists && interface_is_usable(&egress.name);

    if !exec.is_apply() {
        if exists {
            debug!(
                egress = %egress.name,
                kind = %egress.kind.as_str(),
                usable,
                "dry-run: inspected egress interface"
            );
        } else {
            warn!(
                egress = %egress.name,
                kind = %egress.kind.as_str(),
                "dry-run: configured egress interface does not exist on this host"
            );
        }
        return true;
    }

    if !exists {
        warn!(egress = %egress.name, kind = %egress.kind.as_str(), "interface does not exist");
        return false;
    }

    if !usable {
        warn!(egress = %egress.name, kind = %egress.kind.as_str(), "interface is not up/unknown");
        return false;
    }

    if !egress.healthcheck.enabled {
        info!(egress = %egress.name, kind = %egress.kind.as_str(), "egress healthy: interface is usable, healthcheck disabled");
        return true;
    }

    let timeout_sec = ((egress.healthcheck.timeout_ms + 999) / 1000).max(1).to_string();
    let ok = exec.status(
        "ping",
        [
            "-I",
            egress.name.as_str(),
            "-c",
            "1",
            "-W",
            timeout_sec.as_str(),
            egress.healthcheck.target_ip.as_str(),
        ],
    );

    if ok {
        info!(
            egress = %egress.name,
            kind = %egress.kind.as_str(),
            target = %egress.healthcheck.target_ip,
            "egress healthcheck passed"
        );
    } else {
        warn!(
            egress = %egress.name,
            kind = %egress.kind.as_str(),
            target = %egress.healthcheck.target_ip,
            "egress healthcheck ping failed"
        );
    }

    ok
}

fn interface_exists(name: &str) -> bool {
    fs::metadata(format!("/sys/class/net/{name}")).is_ok()
}

fn interface_is_usable(name: &str) -> bool {
    match fs::read_to_string(format!("/sys/class/net/{name}/operstate")) {
        Ok(raw) => {
            let state = raw.trim();
            matches!(state, "up" | "unknown")
        }
        Err(_) => false,
    }
}
