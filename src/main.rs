mod cleanup;
mod config;
mod direct_egress;
mod dns;
mod dns_cache;
mod dns_proxy;
mod exec;
mod health;
mod routing;
mod runtime;
mod status;
mod tunnel;
mod validate;
mod wifi;
// TODO: проверить комменты
// FIXME: проверить ошибку
// HACK: временное решение
mod wireguard;

use anyhow::{anyhow, Result};
use clap::{Parser, Subcommand};
use std::path::PathBuf;
use tracing_subscriber::EnvFilter;

#[derive(Debug, Parser)]
#[command(name = "eve-net")]
#[command(about = "Policy-based Linux egress routing runtime")]
struct Args {
    /// Path to JSON policy config.
    #[arg(long, global = true, default_value = "/etc/eve-net/policy.json")]
    config: PathBuf,

    /// Actually mutate nftables/ip routes. Without this flag, mutating commands are dry-run.
    #[arg(long, global = true)]
    apply: bool,

    /// Apply current config once and exit. Legacy flag; equivalent to: eve-net run --once.
    #[arg(long, global = true)]
    once: bool,

    /// Override runtime loop interval in seconds.
    #[arg(long, global = true)]
    interval_sec: Option<u64>,

    /// More logs.
    #[arg(short, long, global = true)]
    verbose: bool,

    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Debug, Clone, Subcommand)]
enum Command {
    /// Reconcile routes/rules/policies. This is the default command.
    Run,
    /// Reconcile routes/rules/policies once and exit. Explicit one-shot alias for automation.
    Reconcile,
    /// Print current runtime/network status without mutation.
    Status,
    /// Print WireGuard tooling/interface/provider status.
    #[command(name = "wg-status")]
    WgStatus,
    /// Resolve one domain or all domain policies to current IPv4 addresses.
    #[command(name = "domain-resolve")]
    DomainResolve {
        /// Optional bare hostname. If omitted, resolves all domain policies from config.
        domain: Option<String>,
    },
    /// Print DNS cache entries and freshness for configured domain policies.
    #[command(name = "dns-cache")]
    DnsCache,
    /// Force refresh DNS cache for enabled domain policies.
    #[command(name = "dns-refresh")]
    DnsRefresh,
    /// Remove cache entries for domains that are no longer present in config.
    #[command(name = "dns-prune")]
    DnsPrune,
    /// Detect likely tunnel interfaces such as amn0, tun0, wg0.
    #[command(name = "tunnel-detect")]
    TunnelDetect,
    /// Run local UDP DNS proxy for hard domain fail-closed experiments. Disabled by default in config.
    #[command(name = "dns-proxy")]
    DnsProxy,
    /// Print DNS interception/proxy readiness without mutation.
    #[command(name = "dns-intercept-status")]
    DnsInterceptStatus,
    /// Validate config, DNS cache state, domain-policy collisions, and enabled egress links.
    Validate,
    /// Refresh configured direct egress gateway/source_ip from current host state.
    #[command(name = "refresh-direct-egress")]
    RefreshDirectEgress,
    /// Remove eve-net nft table, fwmark rules, and route-table entries.
    Cleanup,
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();

    let default_filter = if args.verbose { "debug" } else { "info" };
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new(default_filter)),
        )
        .init();

    let mut cfg = config::Config::load(&args.config)?;
    cfg.validate()?;

    if let Some(interval_sec) = args.interval_sec {
        cfg.runtime.interval_sec = interval_sec;
    }

    match args.command.unwrap_or(Command::Run) {
        Command::Run => {
            let apply = guarded_apply(args.apply, cfg.runtime.dry_run)?;
            runtime::Runtime::new(cfg, apply, args.once).run().await
        }
        Command::Reconcile => {
            let apply = guarded_apply(args.apply, cfg.runtime.dry_run)?;
            runtime::Runtime::new(cfg, apply, true).run().await
        }
        Command::Status => status::print_status(&cfg),
        Command::WgStatus => wireguard::print_wireguard_status(&cfg),
        Command::DomainResolve { domain } => dns::print_domain_resolve(&cfg, domain.as_deref()),
        Command::DnsCache => status::print_dns_cache_status(&cfg),
        Command::DnsRefresh => dns::refresh_cache_command(&cfg, args.apply),
        Command::DnsPrune => dns::prune_cache_command(&cfg, args.apply),
        Command::TunnelDetect => tunnel::print_tunnel_detect(),
        Command::DnsProxy => dns_proxy::run_dns_proxy(&cfg, args.apply).await,
        Command::DnsInterceptStatus => dns_proxy::print_dns_intercept_status(&cfg),
        Command::Validate => validate::print_validate(&cfg),
        Command::RefreshDirectEgress => {
            direct_egress::print_refresh_direct_egress(&args.config, args.apply)
        }
        Command::Cleanup => cleanup::cleanup(&cfg, args.apply),
    }
}

fn guarded_apply(apply_flag: bool, config_dry_run: bool) -> Result<bool> {
    // Safety gate: real mutation requires BOTH:
    // 1) CLI flag: --apply
    // 2) config flag: runtime.dry_run=false
    if apply_flag && config_dry_run {
        return Err(anyhow!(
            "--apply was passed, but config runtime.dry_run=true. Set runtime.dry_run=false in the JSON config, then rerun with --apply."
        ));
    }

    Ok(apply_flag && !config_dry_run)
}
