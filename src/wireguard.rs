use crate::config::{Config, EgressKind};
use anyhow::Result;
use std::fs;
use std::process::Command;

#[derive(Debug, Clone)]
struct WgIfaceStatus {
    name: String,
    enabled_in_config: bool,
    link_exists: bool,
    operstate: String,
    wg_configured: bool,
    peer_count: usize,
    note: String,
}

pub fn print_wireguard_status(cfg: &Config) -> Result<()> {
    println!("eve-net wireguard status");
    println!("wg command: {}", command_label("wg"));
    println!("wg-quick command: {}", command_label("wg-quick"));
    println!();

    match Command::new("wg").arg("--version").output() {
        Ok(output) if output.status.success() => {
            let stdout = String::from_utf8_lossy(&output.stdout);
            println!("wg_version: {}", stdout.trim());
        }
        Ok(output) => {
            let stderr = String::from_utf8_lossy(&output.stderr);
            println!("wg_version: unavailable ({})", stderr.trim());
        }
        Err(_) => println!("wg_version: unavailable"),
    }
    println!();

    let wireguard_egress: Vec<_> = cfg
        .egress_interfaces
        .iter()
        .filter(|egress| egress.kind == EgressKind::Wireguard)
        .collect();

    if wireguard_egress.is_empty() {
        println!("wireguard_egress: none in config");
        return Ok(());
    }

    println!("wireguard_egress:");
    for egress in wireguard_egress {
        let status = inspect_wg_interface(&egress.name, egress.enabled);
        println!("  - name: {}", status.name);
        println!("    enabled_in_config: {}", yes_no(status.enabled_in_config));
        println!("    link_exists: {}", yes_no(status.link_exists));
        println!("    operstate: {}", status.operstate);
        println!("    wg_configured: {}", yes_no(status.wg_configured));
        println!("    peers: {}", status.peer_count);
        println!("    table: {}", egress.table);
        println!("    fwmark: {}", egress.fwmark);
        println!("    rule_priority: {}", egress.rule_priority);
        println!("    healthcheck: {} -> {}", yes_no(egress.healthcheck.enabled), egress.healthcheck.target_ip);
        if !status.note.is_empty() {
            println!("    note: {}", status.note);
        }
    }

    Ok(())
}

pub fn wireguard_summary(name: &str) -> String {
    let status = inspect_wg_interface(name, false);
    if !status.link_exists {
        return "link missing".to_string();
    }
    if !status.wg_configured {
        return "link exists, wg not configured".to_string();
    }
    format!("configured, peers={}", status.peer_count)
}

fn inspect_wg_interface(name: &str, enabled_in_config: bool) -> WgIfaceStatus {
    let link_exists = interface_exists(name);
    let operstate = interface_state(name).unwrap_or_else(|| "missing".to_string());

    let mut wg_configured = false;
    let mut peer_count = 0usize;
    let mut note = String::new();

    match Command::new("wg").args(["show", name]).output() {
        Ok(output) if output.status.success() => {
            let stdout = String::from_utf8_lossy(&output.stdout);
            wg_configured = !stdout.trim().is_empty();
            peer_count = stdout
                .lines()
                .map(str::trim_start)
                .filter(|line| line.starts_with("peer:"))
                .count();
            if wg_configured && peer_count == 0 {
                note = "WireGuard interface exists but has no peers".to_string();
            }
        }
        Ok(output) => {
            let stderr = String::from_utf8_lossy(&output.stderr);
            let low = stderr.to_lowercase();
            if low.contains("no such device") || low.contains("not a wireguard interface") {
                note = "not currently managed by WireGuard".to_string();
            } else if low.contains("operation not permitted") || low.contains("permission denied") {
                note = "permission denied; try sudo".to_string();
            } else if !stderr.trim().is_empty() {
                note = stderr.trim().to_string();
            }
        }
        Err(_) => {
            note = "wg command missing".to_string();
        }
    }

    WgIfaceStatus {
        name: name.to_string(),
        enabled_in_config,
        link_exists,
        operstate,
        wg_configured,
        peer_count,
        note,
    }
}

fn command_label(program: &str) -> String {
    match Command::new("sh")
        .arg("-c")
        .arg(format!("command -v {}", program))
        .output()
    {
        Ok(output) if output.status.success() => {
            String::from_utf8_lossy(&output.stdout).trim().to_string()
        }
        _ => "missing".to_string(),
    }
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

fn yes_no(value: bool) -> &'static str {
    if value { "yes" } else { "no" }
}
