use crate::config::WifiUnderlay;
use std::fs;
use tracing::{info, warn};

pub fn inspect_underlay(wifi: &WifiUnderlay, apply: bool) {
    let path = format!("/sys/class/net/{}", wifi.interface);
    let exists = fs::metadata(&path).is_ok();

    if apply && !exists {
        warn!(interface = %wifi.interface, "Wi-Fi underlay interface was not found");
        return;
    }

    if !exists {
        warn!(interface = %wifi.interface, "configured Wi-Fi underlay interface does not exist on this host");
    }

    if wifi.allowed_bands.is_empty() {
        info!(interface = %wifi.interface, "Wi-Fi underlay configured; band is managed outside routing runtime");
    } else {
        info!(
            interface = %wifi.interface,
            bands = ?wifi.allowed_bands,
            note = %wifi.note,
            "Wi-Fi underlay configured; 2.4/5 GHz selection remains NetworkManager/driver responsibility"
        );
    }
}
