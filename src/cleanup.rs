use crate::config::Config;
use crate::exec::Executor;
use anyhow::Result;
use tracing::info;

pub fn cleanup(cfg: &Config, apply: bool) -> Result<()> {
    let exec = Executor::new(apply);

    info!(apply = exec.is_apply(), "starting eve-net cleanup");

    delete_nft_table(cfg, &exec);
    delete_fwmark_rules(cfg, &exec);
    flush_existing_route_tables(cfg, &exec);

    info!(apply = exec.is_apply(), "cleanup finished");
    Ok(())
}

fn delete_nft_table(cfg: &Config, exec: &Executor) {
    if exec
        .capture("nft", ["list", "table", "inet", cfg.nft.table.as_str()])
        .is_ok()
        || !exec.is_apply()
    {
        exec.run_allow_fail("nft", ["delete", "table", "inet", cfg.nft.table.as_str()]);
    }
}

fn delete_fwmark_rules(cfg: &Config, exec: &Executor) {
    let rules = exec.capture_or_empty("ip", ["rule", "show"]);

    for egress in &cfg.egress_interfaces {
        let mark_hex = format!("fwmark 0x{:x}", egress.fwmark);
        let lookup = format!("lookup {}", egress.table);
        let exists = rules.lines().any(|line| line.contains(&mark_hex) && line.contains(&lookup));

        if exists || !exec.is_apply() {
            let fwmark = egress.fwmark.to_string();
            let table = egress.table.to_string();
            let priority = egress.rule_priority.to_string();

            exec.run_allow_fail(
                "ip",
                [
                    "rule",
                    "del",
                    "fwmark",
                    fwmark.as_str(),
                    "table",
                    table.as_str(),
                    "priority",
                    priority.as_str(),
                ],
            );
        }
    }
}

fn flush_existing_route_tables(cfg: &Config, exec: &Executor) {
    for egress in &cfg.egress_interfaces {
        let table = egress.table.to_string();
        let route_table = exec.capture_or_empty("ip", ["route", "show", "table", table.as_str()]);
        let has_routes = route_table.lines().any(|line| !line.trim().is_empty());

        if has_routes || !exec.is_apply() {
            exec.run_allow_fail("ip", ["route", "flush", "table", table.as_str()]);
        } else {
            info!(table = egress.table, egress = %egress.name, "route table already empty or missing");
        }
    }
}
