use std::net::SocketAddr;
use std::time::Duration;

use ipnet::IpNet;
use tokio::net::TcpListener;
use tracing_subscriber::EnvFilter;

fn env_u64(name: &str) -> Option<u64> {
    std::env::var(name).ok()?.trim().parse::<u64>().ok()
}

fn env_usize(name: &str) -> Option<usize> {
    std::env::var(name).ok()?.trim().parse::<usize>().ok()
}

fn env_string(name: &str) -> Option<String> {
    std::env::var(name).ok().map(|v| v.trim().to_string())
}

fn env_bool(name: &str) -> anyhow::Result<Option<bool>> {
    let Ok(raw) = std::env::var(name) else {
        return Ok(None);
    };
    let s = raw.trim();
    if s.is_empty() {
        return Ok(None);
    }

    let normalized = s.to_ascii_lowercase();
    let value = match normalized.as_str() {
        "1" | "true" | "yes" | "on" => true,
        "0" | "false" | "no" | "off" => false,
        _ => {
            return Err(anyhow::anyhow!(
                "invalid boolean value for {name}: {raw:?} (expected true/false)"
            ));
        }
    };

    Ok(Some(value))
}

fn parse_trusted_proxy_cidrs(raw: &str) -> anyhow::Result<Vec<IpNet>> {
    let mut out = Vec::new();
    for part in raw.split(',') {
        for token in part.split_whitespace() {
            if token.is_empty() {
                continue;
            }
            let net = token.parse::<IpNet>().map_err(|e| {
                anyhow::anyhow!("invalid CIDR in TRUSTED_PROXY_CIDRS: {token:?}: {e}")
            })?;
            out.push(net);
        }
    }
    Ok(out)
}

fn config_from_env() -> anyhow::Result<chutes_autopilot::AppConfig> {
    let mut cfg = chutes_autopilot::AppConfig::default();

    if let Some(ms) = env_u64("READYZ_MAX_SNAPSHOT_AGE_MS") {
        cfg.readyz_max_snapshot_age = Duration::from_millis(ms);
    }
    if let Some(value) = env_usize("MAX_REQUEST_BYTES") {
        cfg.max_request_bytes = value;
    }
    if let Some(value) = env_usize("MAX_MODEL_LIST_ITEMS") {
        cfg.max_model_list_items = value;
    }
    if let Some(url) = env_string("BACKEND_BASE_URL") {
        cfg.backend_base_url = url;
    }
    if let Some(url) = env_string("CHUTES_LIST_URL") {
        cfg.chutes_list_url = url;
    }
    if let Some(ms) = env_u64("CHUTES_LIST_REFRESH_MS") {
        cfg.chutes_list_refresh_ms = Duration::from_millis(ms);
    }
    if let Some(url) = env_string("UTILIZATION_URL") {
        cfg.utilization_url = url;
    }
    if let Some(ms) = env_u64("UTILIZATION_REFRESH_MS") {
        cfg.utilization_refresh_ms = Duration::from_millis(ms);
    }
    if let Some(ms) = env_u64("UPSTREAM_CONNECT_TIMEOUT_MS") {
        cfg.upstream_connect_timeout = Duration::from_millis(ms);
    }
    if let Some(ms) = env_u64("UPSTREAM_HEADER_TIMEOUT_MS") {
        cfg.upstream_header_timeout = Duration::from_millis(ms);
    }
    if let Some(ms) = env_u64("UPSTREAM_FIRST_BODY_BYTE_TIMEOUT_MS") {
        cfg.upstream_first_body_byte_timeout = Duration::from_millis(ms);
    }
    if let Some(secs) = env_u64("STICKY_TTL_SECS") {
        cfg.sticky_ttl = Duration::from_secs(secs);
    }
    if let Some(max_entries) = env_usize("STICKY_MAX_ENTRIES") {
        cfg.sticky_max_entries = max_entries;
    }

    if let Some(trust) = env_bool("TRUST_PROXY_HEADERS")? {
        cfg.trust_proxy_headers = trust;
    }
    if cfg.trust_proxy_headers {
        if let Some(raw) = env_string("TRUSTED_PROXY_CIDRS") {
            cfg.trusted_proxy_cidrs = parse_trusted_proxy_cidrs(&raw)?;
        }
    }

    Ok(cfg)
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env())
        .init();

    let listen: SocketAddr = std::env::var("LISTEN_ADDR")
        .unwrap_or_else(|_| "0.0.0.0:8080".to_string())
        .parse()?;

    let state = chutes_autopilot::AppState::new(config_from_env()?);
    chutes_autopilot::spawn_control_plane_refresh(state.clone());
    let app = chutes_autopilot::app(state);

    let listener = TcpListener::bind(listen).await?;
    tracing::info!(%listen, "listening");
    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .await?;

    Ok(())
}
