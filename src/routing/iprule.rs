use crate::config::EgressInterface;
use crate::exec::Executor;
use anyhow::Result;
use tracing::info;

pub fn ensure_route_table_default(exec: &Executor, egress: &EgressInterface) -> Result<()> {
    let table = egress.table.to_string();
    let mut args = vec![
        "route".to_string(),
        "replace".to_string(),
        "default".to_string(),
    ];

    if let Some(gateway) = egress.gateway.as_deref().filter(|value| !value.trim().is_empty()) {
        args.push("via".to_string());
        args.push(gateway.to_string());
    }

    args.push("dev".to_string());
    args.push(egress.name.clone());

    if let Some(source_ip) = egress.source_ip.as_deref().filter(|value| !value.trim().is_empty()) {
        args.push("src".to_string());
        args.push(source_ip.to_string());
    }

    args.push("table".to_string());
    args.push(table);

    exec.run("ip", args)
}

pub fn ensure_fwmark_rule(exec: &Executor, egress: &EgressInterface) -> Result<()> {
    if !exec.is_apply() {
        let fwmark = egress.fwmark.to_string();
        let table = egress.table.to_string();
        let priority = egress.rule_priority.to_string();
        return exec.run(
            "ip",
            [
                "rule",
                "add",
                "fwmark",
                fwmark.as_str(),
                "table",
                table.as_str(),
                "priority",
                priority.as_str(),
            ],
        );
    }

    let rules = exec.capture("ip", ["rule", "show"])?;
    let mark_hex = format!("fwmark 0x{:x}", egress.fwmark);
    let lookup = format!("lookup {}", egress.table);

    if rules.lines().any(|line| line.contains(&mark_hex) && line.contains(&lookup)) {
        info!(egress = %egress.name, fwmark = egress.fwmark, table = egress.table, "fwmark rule already exists");
        return Ok(());
    }

    let fwmark = egress.fwmark.to_string();
    let table = egress.table.to_string();
    let priority = egress.rule_priority.to_string();

    exec.run(
        "ip",
        [
            "rule",
            "add",
            "fwmark",
            fwmark.as_str(),
            "table",
            table.as_str(),
            "priority",
            priority.as_str(),
        ],
    )
}
