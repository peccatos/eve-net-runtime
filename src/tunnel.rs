use anyhow::Result;
use std::fs;
use std::path::Path;

#[derive(Debug, Clone)]
struct InterfaceInfo {
    name: String,
    operstate: String,
    kind_hint: String,
}

pub fn print_tunnel_detect() -> Result<()> {
    println!("eve-net tunnel detect");

    let interfaces = detect_interfaces()?;
    if interfaces.is_empty() {
        println!("tunnels: none");
        return Ok(());
    }

    println!("tunnels:");
    for iface in interfaces {
        println!("  - name: {}", iface.name);
        println!("    state: {}", iface.operstate);
        println!("    hint: {}", iface.kind_hint);
    }

    Ok(())
}

fn detect_interfaces() -> Result<Vec<InterfaceInfo>> {
    let mut out = Vec::new();
    let root = Path::new("/sys/class/net");

    for entry in fs::read_dir(root)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().to_string();
        let lower = name.to_lowercase();

        let hint = if lower.starts_with("amn") {
            Some("amnezia/tun")
        } else if lower.starts_with("tun") {
            Some("tun")
        } else if lower.starts_with("wg") {
            Some("wireguard")
        } else if lower.starts_with("vpn") {
            Some("vpn")
        } else {
            None
        };

        if let Some(kind_hint) = hint {
            let operstate = fs::read_to_string(root.join(&name).join("operstate"))
                .unwrap_or_else(|_| "unknown".to_string())
                .trim()
                .to_string();
            out.push(InterfaceInfo {
                name,
                operstate,
                kind_hint: kind_hint.to_string(),
            });
        }
    }

    out.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(out)
}
