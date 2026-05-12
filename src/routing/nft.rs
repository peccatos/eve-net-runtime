use crate::config::{Config, EgressInterface, MatchSpec, Policy};
use crate::exec::Executor;
use anyhow::{anyhow, Result};

pub fn ensure_table_and_chain(exec: &Executor, cfg: &Config) -> Result<()> {
    if !exec.is_apply() {
        exec.run("nft", ["add", "table", "inet", cfg.nft.table.as_str()])?;
        exec.run(
            "nft",
            [
                "add",
                "chain",
                "inet",
                cfg.nft.table.as_str(),
                cfg.nft.output_chain.as_str(),
                "{",
                "type",
                "route",
                "hook",
                "output",
                "priority",
                "mangle",
                ";",
                "policy",
                "accept",
                ";",
                "}",
            ],
        )?;
        return Ok(());
    }

    if exec.capture("nft", ["list", "table", "inet", cfg.nft.table.as_str()]).is_err() {
        exec.run("nft", ["add", "table", "inet", cfg.nft.table.as_str()])?;
    }

    if exec
        .capture(
            "nft",
            [
                "list",
                "chain",
                "inet",
                cfg.nft.table.as_str(),
                cfg.nft.output_chain.as_str(),
            ],
        )
        .is_err()
    {
        exec.run(
            "nft",
            [
                "add",
                "chain",
                "inet",
                cfg.nft.table.as_str(),
                cfg.nft.output_chain.as_str(),
                "{",
                "type",
                "route",
                "hook",
                "output",
                "priority",
                "mangle",
                ";",
                "policy",
                "accept",
                ";",
                "}",
            ],
        )?;
    }

    Ok(())
}

pub fn flush_policy_chain(exec: &Executor, cfg: &Config) -> Result<()> {
    exec.run(
        "nft",
        [
            "flush",
            "chain",
            "inet",
            cfg.nft.table.as_str(),
            cfg.nft.output_chain.as_str(),
        ],
    )
}

pub fn add_policy_rule(exec: &Executor, cfg: &Config, policy: &Policy, egress: &EgressInterface) -> Result<()> {
    if policy.match_spec.domain.is_some() {
        return Err(anyhow!(
            "policy {} uses domain match; call add_policy_rule_for_resolved_ip after DNS resolution",
            policy.id
        ));
    }

    add_policy_rule_with_match(exec, cfg, policy, egress, &policy.match_spec)
}

pub fn add_policy_rule_for_resolved_ip(
    exec: &Executor,
    cfg: &Config,
    policy: &Policy,
    egress: &EgressInterface,
    resolved_ip: &str,
) -> Result<()> {
    let mut spec = policy.match_spec.clone();
    spec.domain = None;
    spec.dest_ip = Some(resolved_ip.to_string());
    spec.dest_cidr = None;

    add_policy_rule_with_match(exec, cfg, policy, egress, &spec)
}

fn add_policy_rule_with_match(
    exec: &Executor,
    cfg: &Config,
    _policy: &Policy,
    egress: &EgressInterface,
    match_spec: &MatchSpec,
) -> Result<()> {
    let mut args = vec![
        "add".to_string(),
        "rule".to_string(),
        "inet".to_string(),
        cfg.nft.table.clone(),
        cfg.nft.output_chain.clone(),
    ];

    append_match(&mut args, match_spec)?;
    args.extend([
        "counter".to_string(),
        "meta".to_string(),
        "mark".to_string(),
        "set".to_string(),
        egress.fwmark.to_string(),
    ]);

    exec.run("nft", args)
}

fn append_match(args: &mut Vec<String>, spec: &MatchSpec) -> Result<()> {
    let dest = spec.dest_cidr.as_ref().or(spec.dest_ip.as_ref());

    if let Some(dest) = dest {
        args.extend(["ip".to_string(), "daddr".to_string(), dest.clone()]);
    }

    if let Some(uid) = spec.uid {
        args.extend(["meta".to_string(), "skuid".to_string(), uid.to_string()]);
    }

    if dest.is_none() && spec.uid.is_none() {
        return Err(anyhow!("only dest_ip, dest_cidr, resolved domain and uid matches are supported in v0.9"));
    }

    Ok(())
}
