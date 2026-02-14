use std::collections::hash_map::DefaultHasher;
use std::collections::{HashMap, HashSet};
use std::hash::{Hash, Hasher};
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::body::{Body, Bytes};
use axum::extract::rejection::{BytesRejection, FailedToBufferBody};
use axum::extract::{ConnectInfo, DefaultBodyLimit, State};
use axum::http::header::HeaderName;
use axum::http::{HeaderMap, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use futures_util::{stream, StreamExt};
use ipnet::IpNet;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::sync::RwLock;

#[derive(Clone)]
pub struct AppState {
    runtime: Arc<RwLock<RuntimeState>>,
    config: AppConfig,
    http_client: Client,
}

#[derive(Clone, Debug)]
pub struct AppConfig {
    pub readyz_max_snapshot_age: Duration,
    pub max_request_bytes: usize,
    pub max_model_list_items: usize,
    pub backend_base_url: String,
    pub chutes_list_url: String,
    pub chutes_list_refresh_ms: Duration,
    pub utilization_url: String,
    pub utilization_refresh_ms: Duration,
    pub upstream_connect_timeout: Duration,
    pub upstream_header_timeout: Duration,
    pub upstream_first_body_byte_timeout: Duration,
    pub sticky_ttl: Duration,
    pub sticky_max_entries: usize,
    pub trust_proxy_headers: bool,
    pub trusted_proxy_cidrs: Vec<IpNet>,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            readyz_max_snapshot_age: Duration::from_millis(20_000),
            max_request_bytes: 1_048_576,
            max_model_list_items: 8,
            backend_base_url: "https://llm.chutes.ai".to_string(),
            chutes_list_url: "https://api.chutes.ai/chutes/?limit=1000".to_string(),
            chutes_list_refresh_ms: Duration::from_millis(300_000),
            utilization_url: "https://api.chutes.ai/chutes/utilization".to_string(),
            utilization_refresh_ms: Duration::from_millis(5_000),
            upstream_connect_timeout: Duration::from_millis(2_000),
            upstream_header_timeout: Duration::from_millis(10_000),
            upstream_first_body_byte_timeout: Duration::from_millis(120_000),
            sticky_ttl: Duration::from_secs(1_800),
            sticky_max_entries: 10_000,
            trust_proxy_headers: false,
            trusted_proxy_cidrs: Vec::new(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct Readiness {
    pub has_candidates: bool,
    pub snapshot_at: Option<Instant>,
}

#[derive(Debug, Default)]
struct RuntimeState {
    candidates: Vec<RankedCandidate>,
    tee_allowlist: HashSet<String>,
    snapshot_at: Option<Instant>,
    sticky_models: HashMap<String, StickyModelSelection>,
}

#[derive(Clone, Debug)]
struct StickyModelSelection {
    model: String,
    last_used_at: Instant,
}

impl AppState {
    pub fn new(config: AppConfig) -> Self {
        let http_client = Client::builder()
            .connect_timeout(config.upstream_connect_timeout)
            .build()
            .expect("failed to build reqwest client");
        Self {
            runtime: Arc::new(RwLock::new(RuntimeState::default())),
            config,
            http_client,
        }
    }

    async fn readiness(&self) -> Readiness {
        let runtime = self.runtime.read().await;
        Readiness {
            has_candidates: !runtime.candidates.is_empty(),
            snapshot_at: runtime.snapshot_at,
        }
    }

    async fn update_candidate_snapshot(&self, candidates: anyhow::Result<Vec<RankedCandidate>>) {
        let Ok(candidates) = candidates else {
            return;
        };

        let mut runtime = self.runtime.write().await;
        runtime.candidates = candidates;
        runtime.snapshot_at = Some(Instant::now());
    }

    async fn tee_allowlist(&self) -> HashSet<String> {
        self.runtime.read().await.tee_allowlist.clone()
    }

    async fn candidate_models(&self) -> Vec<String> {
        self.runtime
            .read()
            .await
            .candidates
            .iter()
            .map(|candidate| candidate.name.clone())
            .collect()
    }

    async fn sticky_model(&self, key: &str) -> Option<String> {
        let mut runtime = self.runtime.write().await;
        Self::evict_expired_sticky(&mut runtime, self.config.sticky_ttl);

        let now = Instant::now();
        match runtime.sticky_models.get(key) {
            Some(selection)
                if now.duration_since(selection.last_used_at) <= self.config.sticky_ttl =>
            {
                Some(selection.model.clone())
            }
            Some(_) => {
                runtime.sticky_models.remove(key);
                None
            }
            None => None,
        }
    }

    async fn set_sticky_model(&self, key: String, model: String) {
        let mut runtime = self.runtime.write().await;
        runtime.sticky_models.insert(
            key,
            StickyModelSelection {
                model,
                last_used_at: Instant::now(),
            },
        );
        Self::enforce_sticky_cap(&mut runtime, self.config.sticky_max_entries);
    }

    async fn clear_sticky_model(&self, key: &str) {
        self.runtime.write().await.sticky_models.remove(key);
    }

    async fn rotate_sticky_model(&self, key: &str, candidates: &[String], failed_model: &str) {
        let mut runtime = self.runtime.write().await;
        Self::evict_expired_sticky(&mut runtime, self.config.sticky_ttl);

        let Some(selection) = runtime.sticky_models.get_mut(key) else {
            return;
        };

        if selection.model != failed_model {
            return;
        }

        if let Some(idx) = candidates
            .iter()
            .position(|candidate| candidate == failed_model)
        {
            if let Some(next) = candidates.get(idx + 1) {
                selection.model = next.clone();
                selection.last_used_at = Instant::now();
            } else {
                runtime.sticky_models.remove(key);
            }
        } else {
            runtime.sticky_models.remove(key);
        }
    }

    fn evict_expired_sticky(runtime: &mut RuntimeState, ttl: Duration) {
        if ttl.is_zero() {
            runtime.sticky_models.clear();
            return;
        }

        let now = Instant::now();
        runtime
            .sticky_models
            .retain(|_, selection| now.duration_since(selection.last_used_at) <= ttl);
    }

    fn enforce_sticky_cap(runtime: &mut RuntimeState, max_entries: usize) {
        if max_entries == 0 {
            runtime.sticky_models.clear();
            return;
        }

        while runtime.sticky_models.len() > max_entries {
            let oldest_key = runtime
                .sticky_models
                .iter()
                .min_by_key(|(_, selection)| selection.last_used_at)
                .map(|(key, _)| key.clone());

            if let Some(key) = oldest_key {
                runtime.sticky_models.remove(&key);
            } else {
                break;
            }
        }
    }
}

/// Starts background tasks that keep chute routing data fresh.
///
/// The service tolerates transient refresh failures by keeping the last-known-good
/// candidates/allowlist in memory.
pub fn spawn_control_plane_refresh(state: AppState) {
    tokio::spawn(refresh_tee_allowlist(state.clone()));
    tokio::spawn(refresh_candidates(state));
}

pub fn app(state: AppState) -> Router {
    let max_request_bytes = state.config.max_request_bytes;
    Router::new()
        .route("/healthz", get(healthz))
        .route("/readyz", get(readyz))
        .route("/v1/chat/completions", post(chat_completions))
        .layer(DefaultBodyLimit::max(max_request_bytes))
        .with_state(state)
}

async fn healthz() -> impl IntoResponse {
    (StatusCode::OK, "ok")
}

async fn readyz(State(state): State<AppState>) -> Response {
    let r = state.readiness().await;

    let Some(snapshot_at) = r.snapshot_at else {
        return openai_error_response(
            StatusCode::SERVICE_UNAVAILABLE,
            "not_ready",
            "service not ready: no candidate snapshot",
            None,
            Some("not_ready"),
        );
    };

    if !r.has_candidates {
        return openai_error_response(
            StatusCode::SERVICE_UNAVAILABLE,
            "not_ready",
            "service not ready: no eligible candidates",
            None,
            Some("not_ready"),
        );
    }

    let age = snapshot_at.elapsed();
    if age > state.config.readyz_max_snapshot_age {
        return openai_error_response(
            StatusCode::SERVICE_UNAVAILABLE,
            "not_ready",
            "service not ready: candidate snapshot is stale",
            None,
            Some("stale_snapshot"),
        );
    }

    (StatusCode::OK, "ready").into_response()
}

async fn chat_completions(
    State(state): State<AppState>,
    connect_info: Option<ConnectInfo<SocketAddr>>,
    headers: HeaderMap,
    body: Result<Bytes, BytesRejection>,
) -> Response {
    let body = match body {
        Ok(body) => body,
        Err(rejection) => {
            return match rejection {
                BytesRejection::FailedToBufferBody(FailedToBufferBody::LengthLimitError(_)) => {
                    openai_error_response(
                        StatusCode::PAYLOAD_TOO_LARGE,
                        "invalid_request_error",
                        "request body too large",
                        None,
                        Some("request_too_large"),
                    )
                }
                BytesRejection::FailedToBufferBody(FailedToBufferBody::UnknownBodyError(_)) => {
                    openai_error_response(
                        StatusCode::BAD_REQUEST,
                        "invalid_request_error",
                        "failed to read request body",
                        None,
                        Some("invalid_body"),
                    )
                }
                _ => openai_error_response(
                    StatusCode::BAD_REQUEST,
                    "invalid_request_error",
                    "failed to read request body",
                    None,
                    Some("invalid_body"),
                ),
            };
        }
    };

    let mut v: serde_json::Value = match serde_json::from_slice(&body) {
        Ok(v) => v,
        Err(_) => {
            return openai_error_response(
                StatusCode::BAD_REQUEST,
                "invalid_request_error",
                "invalid JSON body",
                None,
                Some("invalid_json"),
            );
        }
    };

    if !v.is_object() {
        return openai_error_response(
            StatusCode::BAD_REQUEST,
            "invalid_request_error",
            "request body must be a JSON object",
            None,
            Some("invalid_body"),
        );
    }

    let Some(model) = v.get("model").and_then(Value::as_str) else {
        return openai_error_response(
            StatusCode::BAD_REQUEST,
            "invalid_request_error",
            "missing required field: model",
            Some("model"),
            Some("missing_model"),
        );
    };

    let routing_mode = routing_mode_for_model(model);
    let routed_request = matches!(
        routing_mode,
        RoutingMode::AutoPilotAlias | RoutingMode::ExplicitModelList
    );
    let add_selected_header = routed_request;
    let apply_stickiness = routed_request;

    let mut candidates: Vec<String> = match routing_mode {
        RoutingMode::AutoPilotAlias => state.candidate_models().await,
        RoutingMode::ExplicitModelList | RoutingMode::Direct => {
            let tee_allowlist = state.tee_allowlist().await;

            let models = if routing_mode == RoutingMode::Direct {
                vec![model.to_string()]
            } else {
                match parse_model_preference_list(model, state.config.max_model_list_items) {
                    Ok(models) => models,
                    Err(e) => {
                        return openai_error_response(
                            StatusCode::BAD_REQUEST,
                            "invalid_request_error",
                            &e.message,
                            Some("model"),
                            Some(&e.code),
                        );
                    }
                }
            };

            let non_tee: Vec<String> = models
                .iter()
                .filter(|m| !is_tee_eligible(m, &tee_allowlist))
                .cloned()
                .collect();
            if !non_tee.is_empty() {
                let message = if models.len() == 1 {
                    "model is not TEE-eligible".to_string()
                } else {
                    format!(
                        "model list contains non-TEE model(s): {}",
                        non_tee.join(", ")
                    )
                };
                return openai_error_response(
                    StatusCode::BAD_REQUEST,
                    "invalid_request_error",
                    message.as_str(),
                    Some("model"),
                    Some("model_not_tee"),
                );
            }

            models
        }
    };

    if candidates.is_empty() {
        return openai_error_response(
            StatusCode::SERVICE_UNAVAILABLE,
            "server_error",
            "no eligible candidates available",
            Some("model"),
            Some("no_candidates"),
        );
    }

    let client_key = if apply_stickiness {
        derive_sticky_key(&state.config, &headers, &connect_info)
    } else {
        None
    };

    if let Some(client_key) = client_key.as_ref() {
        if let Some(sticky_model) = state.sticky_model(client_key).await {
            if let Some(pos) = candidates
                .iter()
                .position(|candidate| candidate == &sticky_model)
            {
                let sticky = candidates.remove(pos);
                candidates.insert(0, sticky);
            } else {
                state.clear_sticky_model(client_key).await;
            }
        }
    }

    proxy_chat_completions_with_failover(
        &state,
        &headers,
        &mut v,
        &candidates,
        add_selected_header,
        client_key.as_ref(),
    )
    .await
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum RoutingMode {
    AutoPilotAlias,
    ExplicitModelList,
    Direct,
}

fn routing_mode_for_model(model: &str) -> RoutingMode {
    if is_autopilot_alias(model) {
        RoutingMode::AutoPilotAlias
    } else if model.contains(',') {
        RoutingMode::ExplicitModelList
    } else {
        RoutingMode::Direct
    }
}

fn upstream_chat_completions_url(config: &AppConfig) -> String {
    format!(
        "{}/v1/chat/completions",
        config.backend_base_url.trim_end_matches('/')
    )
}

fn is_hop_by_hop_header(name: &HeaderName) -> bool {
    use axum::http::header;

    name == header::CONNECTION
        || name.as_str() == "keep-alive"
        || name == header::PROXY_AUTHENTICATE
        || name == header::PROXY_AUTHORIZATION
        || name == header::TE
        || name == header::TRAILER
        || name == header::TRANSFER_ENCODING
        || name == header::UPGRADE
}

fn filter_upstream_request_headers(headers: &HeaderMap) -> HeaderMap {
    use axum::http::header;

    let mut out = HeaderMap::new();
    for (name, value) in headers.iter() {
        if is_hop_by_hop_header(name) {
            continue;
        }
        if name == header::HOST || name == header::CONTENT_LENGTH {
            continue;
        }
        out.append(name, value.clone());
    }
    out
}

fn copy_upstream_response_headers(from: &HeaderMap, to: &mut HeaderMap) {
    for (name, value) in from.iter() {
        if is_hop_by_hop_header(name) {
            continue;
        }
        to.append(name, value.clone());
    }
}

fn map_reqwest_stream_error(err: reqwest::Error) -> std::io::Error {
    std::io::Error::other(err)
}

fn streaming_response<S>(
    status: StatusCode,
    upstream_headers: &HeaderMap,
    stream: S,
    selected_model: Option<&str>,
) -> Response
where
    S: futures_util::Stream<Item = Result<Bytes, std::io::Error>> + Send + 'static,
{
    let mut resp = Response::new(Body::from_stream(stream));
    *resp.status_mut() = status;
    copy_upstream_response_headers(upstream_headers, resp.headers_mut());
    if let Some(model_name) = selected_model {
        if let Ok(value) = HeaderValue::from_str(model_name) {
            resp.headers_mut()
                .insert("x-chutes-autopilot-selected", value);
        }
    }
    resp
}

fn log_selected_model(
    add_selected_header: bool,
    model_name: &str,
    attempt_idx: usize,
    candidates_total: usize,
    status: StatusCode,
    snapshot_age_ms: Option<u64>,
) {
    if !add_selected_header {
        return;
    }

    tracing::info!(
        selected_model = %model_name,
        attempt_idx,
        candidates_total,
        upstream_status = status.as_u16(),
        snapshot_age_ms = ?snapshot_age_ms,
        "selected upstream chute"
    );
}

async fn maybe_set_sticky_model(
    state: &AppState,
    client_key: Option<&String>,
    status: StatusCode,
    model_name: &str,
) {
    let Some(key) = client_key else {
        return;
    };
    if status == StatusCode::TOO_MANY_REQUESTS || status == StatusCode::SERVICE_UNAVAILABLE {
        return;
    }

    state
        .set_sticky_model(key.clone(), model_name.to_owned())
        .await;
}

async fn proxy_chat_completions_with_failover(
    state: &AppState,
    headers: &HeaderMap,
    body_json: &mut Value,
    candidates: &[String],
    add_selected_header: bool,
    client_key: Option<&String>,
) -> Response {
    let url = upstream_chat_completions_url(&state.config);
    let upstream_headers = filter_upstream_request_headers(headers);
    let snapshot_age_ms = state
        .runtime
        .read()
        .await
        .snapshot_at
        .map(|instant| instant.elapsed().as_millis() as u64);

    for (idx, model_name) in candidates.iter().enumerate() {
        let Some(map) = body_json.as_object_mut() else {
            return openai_error_response(
                StatusCode::BAD_REQUEST,
                "invalid_request_error",
                "request body must be a JSON object",
                None,
                Some("invalid_body"),
            );
        };
        map.insert("model".to_string(), json!(model_name));

        let body_bytes = match serde_json::to_vec(body_json) {
            Ok(bytes) => bytes,
            Err(_) => {
                return openai_error_response(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "server_error",
                    "failed to serialize request body",
                    None,
                    Some("serialization_error"),
                );
            }
        };

        let req = state
            .http_client
            .post(&url)
            .headers(upstream_headers.clone())
            .body(body_bytes);

        let upstream =
            match tokio::time::timeout(state.config.upstream_header_timeout, req.send()).await {
                Err(_) => {
                    if let Some(key) = client_key {
                        state.rotate_sticky_model(key, candidates, model_name).await;
                    }

                    if idx + 1 < candidates.len() {
                        tracing::warn!(
                            failed_model = %model_name,
                            attempt_idx = idx,
                            candidates_total = candidates.len(),
                            snapshot_age_ms = ?snapshot_age_ms,
                            reason = "upstream_header_timeout",
                            "retryable upstream failure; attempting failover"
                        );
                        continue;
                    }

                    return openai_error_response(
                        StatusCode::GATEWAY_TIMEOUT,
                        "server_error",
                        "upstream timeout waiting for response headers",
                        None,
                        Some("upstream_header_timeout"),
                    );
                }
                Ok(Err(_)) => {
                    if let Some(key) = client_key {
                        state.rotate_sticky_model(key, candidates, model_name).await;
                    }

                    if idx + 1 < candidates.len() {
                        tracing::warn!(
                            failed_model = %model_name,
                            attempt_idx = idx,
                            candidates_total = candidates.len(),
                            snapshot_age_ms = ?snapshot_age_ms,
                            reason = "upstream_connect_error",
                            "retryable upstream failure; attempting failover"
                        );
                        continue;
                    }

                    return openai_error_response(
                        StatusCode::BAD_GATEWAY,
                        "server_error",
                        "upstream request failed",
                        None,
                        Some("upstream_connect_error"),
                    );
                }
                Ok(Ok(resp)) => resp,
            };

        let status = upstream.status();
        let upstream_resp_headers = upstream.headers().clone();

        // Retryable upstream status before committing bytes.
        if status == StatusCode::SERVICE_UNAVAILABLE && idx + 1 < candidates.len() {
            if let Some(key) = client_key {
                state.rotate_sticky_model(key, candidates, model_name).await;
            }
            tracing::warn!(
                failed_model = %model_name,
                attempt_idx = idx,
                candidates_total = candidates.len(),
                snapshot_age_ms = ?snapshot_age_ms,
                reason = "upstream_503",
                "retryable upstream failure; attempting failover"
            );
            continue;
        }

        // For successful responses where we could fail over, delay commitment until we see the
        // first body chunk (or abandon due to timeout).
        if status.is_success() && idx + 1 < candidates.len() {
            let mut body_stream = upstream.bytes_stream();
            match tokio::time::timeout(
                state.config.upstream_first_body_byte_timeout,
                body_stream.next(),
            )
            .await
            {
                Err(_) | Ok(None) => {
                    if let Some(key) = client_key {
                        state.rotate_sticky_model(key, candidates, model_name).await;
                    }
                    tracing::warn!(
                        failed_model = %model_name,
                        attempt_idx = idx,
                        candidates_total = candidates.len(),
                        snapshot_age_ms = ?snapshot_age_ms,
                        reason = "upstream_first_body_byte_timeout",
                        "retryable upstream failure; attempting failover"
                    );
                    continue;
                }
                Ok(Some(Err(_))) => {
                    if let Some(key) = client_key {
                        state.rotate_sticky_model(key, candidates, model_name).await;
                    }
                    tracing::warn!(
                        failed_model = %model_name,
                        attempt_idx = idx,
                        candidates_total = candidates.len(),
                        snapshot_age_ms = ?snapshot_age_ms,
                        reason = "upstream_first_body_byte_error",
                        "retryable upstream failure; attempting failover"
                    );
                    continue;
                }
                Ok(Some(Ok(first_chunk))) => {
                    maybe_set_sticky_model(state, client_key, status, model_name).await;

                    let rest = body_stream.map(|item| item.map_err(map_reqwest_stream_error));
                    let combined =
                        stream::once(async move { Ok::<Bytes, std::io::Error>(first_chunk) })
                            .chain(rest);

                    let selected_model_header = add_selected_header.then_some(model_name.as_str());
                    let resp = streaming_response(
                        status,
                        &upstream_resp_headers,
                        combined,
                        selected_model_header,
                    );
                    log_selected_model(
                        add_selected_header,
                        model_name,
                        idx,
                        candidates.len(),
                        status,
                        snapshot_age_ms,
                    );
                    return resp;
                }
            }
        }

        maybe_set_sticky_model(state, client_key, status, model_name).await;

        let stream = upstream
            .bytes_stream()
            .map(|item| item.map_err(map_reqwest_stream_error));

        let selected_model_header = add_selected_header.then_some(model_name.as_str());
        let resp = streaming_response(
            status,
            &upstream_resp_headers,
            stream,
            selected_model_header,
        );
        log_selected_model(
            add_selected_header,
            model_name,
            idx,
            candidates.len(),
            status,
            snapshot_age_ms,
        );
        return resp;
    }

    openai_error_response(
        StatusCode::SERVICE_UNAVAILABLE,
        "server_error",
        "no eligible candidates available",
        Some("model"),
        Some("no_candidates"),
    )
}

fn parse_leftmost_x_forwarded_for(headers: &HeaderMap) -> Option<IpAddr> {
    let raw = headers.get("x-forwarded-for")?.to_str().ok()?;
    let first = raw.split(',').next()?.trim();
    if first.is_empty() {
        return None;
    }
    if let Ok(ip) = first.parse::<IpAddr>() {
        return Some(ip);
    }
    if let Ok(addr) = first.parse::<SocketAddr>() {
        return Some(addr.ip());
    }
    None
}

fn is_trusted_proxy(peer_ip: IpAddr, trusted: &[IpNet]) -> bool {
    trusted.iter().any(|net| net.contains(&peer_ip))
}

fn requester_ip_for_stickiness(
    config: &AppConfig,
    headers: &HeaderMap,
    connect_info: &Option<ConnectInfo<SocketAddr>>,
) -> Option<IpAddr> {
    let peer_ip = connect_info.as_ref().map(|ConnectInfo(addr)| addr.ip())?;

    if !config.trust_proxy_headers {
        return Some(peer_ip);
    }

    if !is_trusted_proxy(peer_ip, &config.trusted_proxy_cidrs) {
        return Some(peer_ip);
    }

    Some(parse_leftmost_x_forwarded_for(headers).unwrap_or(peer_ip))
}

fn derive_sticky_key(
    config: &AppConfig,
    headers: &HeaderMap,
    connect_info: &Option<ConnectInfo<SocketAddr>>,
) -> Option<String> {
    if let Some(auth) = headers
        .get("authorization")
        .and_then(|value| value.to_str().ok())
    {
        let token = auth.trim().strip_prefix("Bearer").unwrap_or(auth).trim();

        if !token.is_empty() {
            let mut hasher = DefaultHasher::new();
            token.hash(&mut hasher);
            return Some(format!("auth:{:016x}", hasher.finish()));
        }
    }

    requester_ip_for_stickiness(config, headers, connect_info).map(|ip| format!("ip:{ip}"))
}

fn is_autopilot_alias(model: &str) -> bool {
    matches!(model, "chutesai/AutoPilot" | "chutesai-routing/AutoPilot")
}

fn is_tee_eligible(model: &str, tee_allowlist: &HashSet<String>) -> bool {
    if tee_allowlist.is_empty() {
        model.ends_with("-TEE")
    } else {
        tee_allowlist.contains(model)
    }
}

async fn refresh_tee_allowlist(state: AppState) {
    let client = state.http_client.clone();
    loop {
        if let Ok(allowlist) = fetch_tee_allowlist(&client, &state.config.chutes_list_url).await {
            let mut runtime = state.runtime.write().await;
            runtime.tee_allowlist = allowlist;
        }

        tokio::time::sleep(state.config.chutes_list_refresh_ms).await;
    }
}

async fn refresh_candidates(state: AppState) {
    let client = state.http_client.clone();
    loop {
        let tee_allowlist = state.runtime.read().await.tee_allowlist.clone();

        let candidates =
            fetch_ranked_candidates(&client, &state.config.utilization_url, &tee_allowlist).await;
        state.update_candidate_snapshot(candidates).await;

        tokio::time::sleep(state.config.utilization_refresh_ms).await;
    }
}

async fn fetch_tee_allowlist(client: &Client, url: &str) -> anyhow::Result<HashSet<String>> {
    let response = client.get(url).send().await?.error_for_status()?;
    let payload = response.json::<serde_json::Value>().await?;

    let items_value = payload.get("items").cloned().unwrap_or(payload);

    let items: Vec<ChuteCatalogItem> = serde_json::from_value(items_value)?;
    let allowlist = items
        .into_iter()
        .filter(|item| item.tee && item.public)
        .map(|item| item.name)
        .collect();

    Ok(allowlist)
}

async fn fetch_ranked_candidates(
    client: &Client,
    url: &str,
    tee_allowlist: &HashSet<String>,
) -> anyhow::Result<Vec<RankedCandidate>> {
    let utilizations: Vec<UtilizationRecord> = client
        .get(url)
        .send()
        .await?
        .error_for_status()?
        .json::<Vec<UtilizationRecord>>()
        .await?;

    Ok(rank_candidates(utilizations, tee_allowlist))
}

fn rank_candidates(
    records: Vec<UtilizationRecord>,
    tee_allowlist: &HashSet<String>,
) -> Vec<RankedCandidate> {
    let mut ranked: Vec<RankedCandidate> = records
        .into_iter()
        .filter(|record| !record.is_private_chute())
        .filter(|record| record.active_instance_count > 0)
        .filter(|record| is_tee_eligible(&record.name, tee_allowlist))
        .map(RankedCandidate::from)
        .collect();

    sort_ranked_candidates(&mut ranked);

    ranked
}

fn sort_ranked_candidates(ranked: &mut [RankedCandidate]) {
    ranked.sort_by(|a, b| {
        b.score
            .total_cmp(&a.score)
            .then_with(|| b.active_instance_count.cmp(&a.active_instance_count))
            .then_with(|| a.utilization_current.total_cmp(&b.utilization_current))
            .then_with(|| a.rate_limit_ratio_5m.total_cmp(&b.rate_limit_ratio_5m))
            .then_with(|| a.name.cmp(&b.name))
    });
}

#[derive(Debug, Clone)]
struct RankedCandidate {
    name: String,
    active_instance_count: u64,
    utilization_current: f64,
    rate_limit_ratio_5m: f64,
    score: f64,
}

impl From<UtilizationRecord> for RankedCandidate {
    fn from(record: UtilizationRecord) -> Self {
        let u5 = record
            .utilization_5m
            .or(record.utilization_current)
            .unwrap_or(1.0);
        let u15 = record.utilization_15m.unwrap_or(u5);
        let u1h = record.utilization_1h.unwrap_or(u15);
        let utilization_current = record.utilization_current.unwrap_or(u5);
        let util = 0.6 * u5 + 0.3 * u15 + 0.1 * u1h;

        let rate_limit_ratio_5m = record.rate_limit_ratio_5m.unwrap_or(0.0);
        let rate_limit_ratio_15m = record.rate_limit_ratio_15m.unwrap_or(rate_limit_ratio_5m);
        let rate_limit_ratio_1h = record.rate_limit_ratio_1h.unwrap_or(rate_limit_ratio_15m);

        let free_capacity = record.active_instance_count as f64 * (1.0 - util).max(0.0);
        let scale_allowance = if record.scalable {
            record.scale_allowance.unwrap_or(0.0).min(8.0) * 0.05
        } else {
            0.0
        };
        let throttle_signal = rate_limit_ratio_5m
            .max(0.5 * rate_limit_ratio_15m)
            .max(0.25 * rate_limit_ratio_1h);
        let score = free_capacity + scale_allowance
            - (record.active_instance_count as f64 * throttle_signal * 2.0);

        Self {
            name: record.name,
            active_instance_count: record.active_instance_count,
            utilization_current,
            rate_limit_ratio_5m,
            score,
        }
    }
}

#[derive(Debug, Deserialize)]
struct ChuteCatalogItem {
    name: String,
    #[serde(default)]
    tee: bool,
    #[serde(default)]
    public: bool,
}

#[derive(Debug, Deserialize)]
struct UtilizationRecord {
    name: String,
    #[serde(default)]
    active_instance_count: u64,
    #[serde(default)]
    utilization_current: Option<f64>,
    #[serde(default)]
    utilization_5m: Option<f64>,
    #[serde(default)]
    utilization_15m: Option<f64>,
    #[serde(default)]
    utilization_1h: Option<f64>,
    #[serde(default)]
    rate_limit_ratio_5m: Option<f64>,
    #[serde(default)]
    rate_limit_ratio_15m: Option<f64>,
    #[serde(default)]
    rate_limit_ratio_1h: Option<f64>,
    #[serde(default)]
    scalable: bool,
    #[serde(default)]
    scale_allowance: Option<f64>,
}

impl UtilizationRecord {
    fn is_private_chute(&self) -> bool {
        self.name == "[private chute]"
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ModelListError {
    code: String,
    message: String,
}

fn parse_model_preference_list(
    model: &str,
    max_items: usize,
) -> Result<Vec<String>, ModelListError> {
    let mut out: Vec<String> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();

    for raw in model.split(',') {
        let item = raw.trim_matches(|c: char| c.is_ascii_whitespace());
        if item.is_empty() {
            continue;
        }
        if seen.insert(item.to_string()) {
            out.push(item.to_string());
        }
    }

    if out.is_empty() {
        return Err(ModelListError {
            code: "invalid_model_list".to_string(),
            message: "model list is empty".to_string(),
        });
    }

    if out.len() > max_items {
        return Err(ModelListError {
            code: "invalid_model_list".to_string(),
            message: format!("model list exceeds MAX_MODEL_LIST_ITEMS ({max_items})"),
        });
    }

    Ok(out)
}

#[derive(Debug, Serialize, Deserialize)]
pub struct OpenAiErrorResponse {
    pub error: OpenAiError,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct OpenAiError {
    pub message: String,
    #[serde(rename = "type")]
    pub error_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub param: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
}

pub fn openai_error_response(
    status: StatusCode,
    error_type: &str,
    message: &str,
    param: Option<&str>,
    code: Option<&str>,
) -> Response {
    let body = OpenAiErrorResponse {
        error: OpenAiError {
            message: message.to_string(),
            error_type: error_type.to_string(),
            param: param.map(ToString::to_string),
            code: code.map(ToString::to_string),
        },
    };
    (status, Json(body)).into_response()
}

#[cfg(test)]
mod tests {
    use super::*;

    use axum::body::Body;
    use axum::routing::post;
    use axum::{Json, Router};
    use http::Request;
    use http_body_util::BodyExt;
    use std::sync::{Arc, Mutex};
    use tokio::net::TcpListener;
    use tower::ServiceExt;

    async fn spawn_upstream(app: Router) -> (String, tokio::task::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let base_url = format!("http://{addr}");

        let handle = tokio::spawn(async move {
            axum::serve(listener, app.into_make_service())
                .await
                .unwrap();
        });

        (base_url, handle)
    }

    fn test_config(backend_base_url: String) -> AppConfig {
        let mut cfg = AppConfig::default();
        cfg.backend_base_url = backend_base_url;
        cfg.upstream_connect_timeout = Duration::from_millis(200);
        cfg.upstream_header_timeout = Duration::from_millis(200);
        cfg.upstream_first_body_byte_timeout = Duration::from_millis(50);
        cfg
    }

    #[test]
    fn parse_model_list_basic() {
        let got = parse_model_preference_list("a,b,c", 8).unwrap();
        assert_eq!(got, vec!["a", "b", "c"]);
    }

    #[test]
    fn parse_model_list_trims_and_dedups_preserving_order() {
        let got = parse_model_preference_list(" a , b , b ", 8).unwrap();
        assert_eq!(got, vec!["a", "b"]);
    }

    #[test]
    fn parse_model_list_discards_empty_items() {
        let got = parse_model_preference_list("a,,b,", 8).unwrap();
        assert_eq!(got, vec!["a", "b"]);
    }

    #[test]
    fn parse_model_list_empty_returns_400_code() {
        let err = parse_model_preference_list(",", 8).unwrap_err();
        assert_eq!(err.code, "invalid_model_list");
    }

    #[test]
    fn parse_model_list_enforces_max_items() {
        let err = parse_model_preference_list("a,b,c", 2).unwrap_err();
        assert_eq!(err.code, "invalid_model_list");
    }

    #[test]
    fn derive_sticky_key_ignores_xff_by_default() {
        let cfg = AppConfig::default();
        let mut headers = HeaderMap::new();
        headers.insert(
            "x-forwarded-for",
            HeaderValue::from_static("198.51.100.7, 203.0.113.10"),
        );
        let connect_info = Some(ConnectInfo(
            "203.0.113.10:1234".parse::<SocketAddr>().unwrap(),
        ));

        let got = derive_sticky_key(&cfg, &headers, &connect_info).unwrap();
        assert_eq!(got, "ip:203.0.113.10");
    }

    #[test]
    fn derive_sticky_key_does_not_use_xff_when_peer_is_not_trusted() {
        let mut cfg = AppConfig::default();
        cfg.trust_proxy_headers = true;
        cfg.trusted_proxy_cidrs = vec!["192.0.2.0/24".parse::<IpNet>().unwrap()];

        let mut headers = HeaderMap::new();
        headers.insert("x-forwarded-for", HeaderValue::from_static("198.51.100.7"));
        let connect_info = Some(ConnectInfo(
            "203.0.113.10:1234".parse::<SocketAddr>().unwrap(),
        ));

        let got = derive_sticky_key(&cfg, &headers, &connect_info).unwrap();
        assert_eq!(got, "ip:203.0.113.10");
    }

    #[test]
    fn derive_sticky_key_uses_xff_when_peer_is_trusted() {
        let mut cfg = AppConfig::default();
        cfg.trust_proxy_headers = true;
        cfg.trusted_proxy_cidrs = vec!["203.0.113.0/24".parse::<IpNet>().unwrap()];

        let mut headers = HeaderMap::new();
        headers.insert(
            "x-forwarded-for",
            HeaderValue::from_static("198.51.100.7, 203.0.113.10"),
        );
        let connect_info = Some(ConnectInfo(
            "203.0.113.10:1234".parse::<SocketAddr>().unwrap(),
        ));

        let got = derive_sticky_key(&cfg, &headers, &connect_info).unwrap();
        assert_eq!(got, "ip:198.51.100.7");
    }

    #[test]
    fn rank_candidates_uses_tee_suffix_without_allowlist() {
        let ranked = rank_candidates(
            vec![
                UtilizationRecord {
                    name: "model-A-TEE".to_string(),
                    active_instance_count: 1,
                    utilization_current: Some(0.1),
                    utilization_5m: Some(0.1),
                    utilization_15m: Some(0.1),
                    utilization_1h: Some(0.1),
                    rate_limit_ratio_5m: Some(0.0),
                    rate_limit_ratio_15m: Some(0.0),
                    rate_limit_ratio_1h: Some(0.0),
                    scalable: false,
                    scale_allowance: Some(0.0),
                },
                UtilizationRecord {
                    name: "model-B".to_string(),
                    active_instance_count: 10,
                    utilization_current: Some(0.1),
                    utilization_5m: Some(0.1),
                    utilization_15m: Some(0.1),
                    utilization_1h: Some(0.1),
                    rate_limit_ratio_5m: Some(0.0),
                    rate_limit_ratio_15m: Some(0.0),
                    rate_limit_ratio_1h: Some(0.0),
                    scalable: false,
                    scale_allowance: Some(0.0),
                },
            ],
            &HashSet::new(),
        );

        assert_eq!(ranked.len(), 1);
        assert_eq!(ranked[0].name, "model-A-TEE");
    }

    #[test]
    fn rank_candidates_filters_by_tee_allowlist_when_present() {
        let allowlist =
            HashSet::from(["allow/Model-TEE".to_string(), "keep/Model-TEE".to_string()]);
        let ranked = rank_candidates(
            vec![
                UtilizationRecord {
                    name: "allow/Model-TEE".to_string(),
                    active_instance_count: 2,
                    utilization_current: Some(0.2),
                    utilization_5m: Some(0.2),
                    utilization_15m: Some(0.2),
                    utilization_1h: Some(0.2),
                    rate_limit_ratio_5m: Some(0.0),
                    rate_limit_ratio_15m: Some(0.0),
                    rate_limit_ratio_1h: Some(0.0),
                    scalable: false,
                    scale_allowance: Some(0.0),
                },
                UtilizationRecord {
                    name: "blocked/Model-TEE".to_string(),
                    active_instance_count: 100,
                    utilization_current: Some(0.0),
                    utilization_5m: Some(0.0),
                    utilization_15m: Some(0.0),
                    utilization_1h: Some(0.0),
                    rate_limit_ratio_5m: Some(0.0),
                    rate_limit_ratio_15m: Some(0.0),
                    rate_limit_ratio_1h: Some(0.0),
                    scalable: false,
                    scale_allowance: Some(0.0),
                },
            ],
            &allowlist,
        );

        assert_eq!(ranked.len(), 1);
        assert_eq!(ranked[0].name, "allow/Model-TEE");
    }

    #[test]
    fn rank_candidates_fixture_filters_and_orders_candidates() {
        let records: Vec<UtilizationRecord> =
            serde_json::from_str(include_str!("../testdata/utilization_fixture.json")).unwrap();

        let ranked = rank_candidates(records, &HashSet::new());
        let names: Vec<String> = ranked.into_iter().map(|c| c.name).collect();
        assert_eq!(names, vec!["alpha-TEE", "beta-TEE", "gamma-TEE"]);
    }

    #[test]
    fn ranked_candidate_score_matches_spec_formula() {
        let record = UtilizationRecord {
            name: "score-TEE".to_string(),
            active_instance_count: 4,
            utilization_current: Some(0.5),
            utilization_5m: Some(0.5),
            utilization_15m: Some(0.25),
            utilization_1h: None,
            rate_limit_ratio_5m: Some(0.25),
            rate_limit_ratio_15m: Some(0.5),
            rate_limit_ratio_1h: Some(1.0),
            scalable: true,
            scale_allowance: Some(8.0),
        };

        let ranked = RankedCandidate::from(record);
        let expected = 0.8;
        assert!(
            (ranked.score - expected).abs() < 1e-6,
            "got {}, expected {}",
            ranked.score,
            expected
        );
    }

    #[test]
    fn sort_ranked_candidates_tiebreaks_by_active_instance_count_desc() {
        let mut ranked = vec![
            RankedCandidate {
                name: "low-active".to_string(),
                active_instance_count: 1,
                utilization_current: 0.0,
                rate_limit_ratio_5m: 0.0,
                score: 1.0,
            },
            RankedCandidate {
                name: "high-active".to_string(),
                active_instance_count: 2,
                utilization_current: 0.0,
                rate_limit_ratio_5m: 0.0,
                score: 1.0,
            },
        ];

        sort_ranked_candidates(&mut ranked);
        assert_eq!(ranked[0].name, "high-active");
    }

    #[test]
    fn sort_ranked_candidates_tiebreaks_by_utilization_current_asc() {
        let mut ranked = vec![
            RankedCandidate {
                name: "higher-util".to_string(),
                active_instance_count: 1,
                utilization_current: 0.5,
                rate_limit_ratio_5m: 0.0,
                score: 1.0,
            },
            RankedCandidate {
                name: "lower-util".to_string(),
                active_instance_count: 1,
                utilization_current: 0.25,
                rate_limit_ratio_5m: 0.0,
                score: 1.0,
            },
        ];

        sort_ranked_candidates(&mut ranked);
        assert_eq!(ranked[0].name, "lower-util");
    }

    #[test]
    fn sort_ranked_candidates_tiebreaks_by_rate_limit_ratio_5m_asc() {
        let mut ranked = vec![
            RankedCandidate {
                name: "higher-rl".to_string(),
                active_instance_count: 1,
                utilization_current: 0.0,
                rate_limit_ratio_5m: 0.5,
                score: 1.0,
            },
            RankedCandidate {
                name: "lower-rl".to_string(),
                active_instance_count: 1,
                utilization_current: 0.0,
                rate_limit_ratio_5m: 0.25,
                score: 1.0,
            },
        ];

        sort_ranked_candidates(&mut ranked);
        assert_eq!(ranked[0].name, "lower-rl");
    }

    #[test]
    fn sort_ranked_candidates_tiebreaks_by_name_asc() {
        let mut ranked = vec![
            RankedCandidate {
                name: "b".to_string(),
                active_instance_count: 1,
                utilization_current: 0.0,
                rate_limit_ratio_5m: 0.0,
                score: 1.0,
            },
            RankedCandidate {
                name: "a".to_string(),
                active_instance_count: 1,
                utilization_current: 0.0,
                rate_limit_ratio_5m: 0.0,
                score: 1.0,
            },
        ];

        sort_ranked_candidates(&mut ranked);
        assert_eq!(ranked[0].name, "a");
    }

    #[tokio::test]
    async fn candidate_snapshot_keeps_last_known_good_on_error() {
        let state = AppState::new(AppConfig::default());
        let snapshot_at = Instant::now() - Duration::from_secs(60);
        {
            let mut runtime = state.runtime.write().await;
            runtime.candidates = vec![RankedCandidate {
                name: "keep".to_string(),
                active_instance_count: 1,
                utilization_current: 0.0,
                rate_limit_ratio_5m: 0.0,
                score: 1.0,
            }];
            runtime.snapshot_at = Some(snapshot_at);
        }

        state
            .update_candidate_snapshot(Err(anyhow::anyhow!("boom")))
            .await;

        let runtime = state.runtime.read().await;
        assert_eq!(runtime.candidates.len(), 1);
        assert_eq!(runtime.candidates[0].name, "keep");
        assert_eq!(runtime.snapshot_at, Some(snapshot_at));
    }

    #[tokio::test]
    async fn chat_completions_prefers_sticky_model_for_autopilot() {
        let attempts: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let upstream_attempts = attempts.clone();
        let upstream = Router::new().route(
            "/v1/chat/completions",
            post(move |Json(v): Json<Value>| {
                let upstream_attempts = upstream_attempts.clone();
                async move {
                    let model = v
                        .get("model")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string();
                    upstream_attempts.lock().unwrap().push(model);
                    (StatusCode::OK, "ok")
                }
            }),
        );
        let (base_url, upstream_handle) = spawn_upstream(upstream).await;

        let state = AppState::new(test_config(base_url));
        {
            let mut runtime = state.runtime.write().await;
            runtime.candidates = vec![
                RankedCandidate {
                    name: "first/TEE-Model".to_string(),
                    active_instance_count: 10,
                    utilization_current: 0.2,
                    rate_limit_ratio_5m: 0.0,
                    score: 8.0,
                },
                RankedCandidate {
                    name: "second/TEE-Model".to_string(),
                    active_instance_count: 1,
                    utilization_current: 0.1,
                    rate_limit_ratio_5m: 0.0,
                    score: 1.0,
                },
            ];
        }
        let mut auth_headers = HeaderMap::new();
        auth_headers.insert(
            "authorization",
            HeaderValue::from_static("Bearer sticky-api-token"),
        );
        let no_connect_info: Option<ConnectInfo<SocketAddr>> = None;

        state
            .set_sticky_model(
                derive_sticky_key(&state.config, &auth_headers, &no_connect_info).unwrap(),
                "second/TEE-Model".to_string(),
            )
            .await;

        let app = app(state);
        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/chat/completions")
                    .header("authorization", "Bearer sticky-api-token")
                    .header("content-type", "application/json")
                    .body(Body::from(r#"{"model":"chutesai/AutoPilot"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
        assert_eq!(
            resp.headers().get("x-chutes-autopilot-selected").unwrap(),
            &axum::http::header::HeaderValue::from_static("second/TEE-Model")
        );

        let got_attempts = attempts.lock().unwrap().clone();
        assert_eq!(got_attempts, vec!["second/TEE-Model".to_string()]);

        let _ = resp.into_body().collect().await.unwrap();
        upstream_handle.abort();
    }

    #[tokio::test]
    async fn chat_completions_prefers_fresh_candidate_when_sticky_is_not_valid() {
        let attempts: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let upstream_attempts = attempts.clone();
        let upstream = Router::new().route(
            "/v1/chat/completions",
            post(move |Json(v): Json<Value>| {
                let upstream_attempts = upstream_attempts.clone();
                async move {
                    let model = v
                        .get("model")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string();
                    upstream_attempts.lock().unwrap().push(model);
                    (StatusCode::OK, "ok")
                }
            }),
        );
        let (base_url, upstream_handle) = spawn_upstream(upstream).await;

        let state = AppState::new(test_config(base_url));
        {
            let mut runtime = state.runtime.write().await;
            runtime.candidates = vec![RankedCandidate {
                name: "only/TEE-Model".to_string(),
                active_instance_count: 2,
                utilization_current: 0.1,
                rate_limit_ratio_5m: 0.0,
                score: 4.0,
            }];
        }

        let mut auth_headers = HeaderMap::new();
        auth_headers.insert(
            "authorization",
            HeaderValue::from_static("Bearer stale-sticky-key"),
        );
        let no_connect_info: Option<ConnectInfo<SocketAddr>> = None;
        state
            .set_sticky_model(
                derive_sticky_key(&state.config, &auth_headers, &no_connect_info).unwrap(),
                "missing/TEE-Model".to_string(),
            )
            .await;

        let app = app(state);
        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/chat/completions")
                    .header("authorization", "Bearer stale-sticky-key")
                    .header("content-type", "application/json")
                    .body(Body::from(r#"{"model":"chutesai/AutoPilot"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
        assert_eq!(
            resp.headers().get("x-chutes-autopilot-selected").unwrap(),
            &axum::http::header::HeaderValue::from_static("only/TEE-Model")
        );

        let got_attempts = attempts.lock().unwrap().clone();
        assert_eq!(got_attempts, vec!["only/TEE-Model".to_string()]);

        let _ = resp.into_body().collect().await.unwrap();
        upstream_handle.abort();
    }

    #[tokio::test]
    async fn rotate_sticky_model_moves_to_next_candidate() {
        let state = AppState::new(AppConfig::default());
        state
            .set_sticky_model("client-key".to_string(), "first".to_string())
            .await;

        let candidates = vec![
            "first".to_string(),
            "second".to_string(),
            "third".to_string(),
        ];

        state
            .rotate_sticky_model("client-key", &candidates, "first")
            .await;
        assert_eq!(
            state.sticky_model("client-key").await,
            Some("second".to_string())
        );

        state
            .rotate_sticky_model("client-key", &candidates, "second")
            .await;
        assert_eq!(
            state.sticky_model("client-key").await,
            Some("third".to_string())
        );
    }

    #[tokio::test]
    async fn sticky_map_evicts_oldest_entries_when_over_cap() {
        let mut cfg = AppConfig::default();
        cfg.sticky_max_entries = 2;

        let state = AppState::new(cfg);
        let now = Instant::now();

        {
            let mut runtime = state.runtime.write().await;
            runtime.sticky_models.insert(
                "old".to_string(),
                StickyModelSelection {
                    model: "old-model".to_string(),
                    last_used_at: now - Duration::from_secs(10),
                },
            );
            runtime.sticky_models.insert(
                "mid".to_string(),
                StickyModelSelection {
                    model: "mid-model".to_string(),
                    last_used_at: now - Duration::from_secs(5),
                },
            );
            runtime.sticky_models.insert(
                "new".to_string(),
                StickyModelSelection {
                    model: "new-model".to_string(),
                    last_used_at: now,
                },
            );

            AppState::enforce_sticky_cap(&mut runtime, state.config.sticky_max_entries);
            assert_eq!(runtime.sticky_models.len(), 2);
            assert!(!runtime.sticky_models.contains_key("old"));
            assert!(runtime.sticky_models.contains_key("mid"));
            assert!(runtime.sticky_models.contains_key("new"));
        }
    }

    #[tokio::test]
    async fn chat_completions_allows_autopilot_alias_without_tee_suffix_when_ranked_model_exists() {
        let attempts: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let upstream_attempts = attempts.clone();
        let upstream = Router::new().route(
            "/v1/chat/completions",
            post(move |Json(v): Json<Value>| {
                let upstream_attempts = upstream_attempts.clone();
                async move {
                    let model = v
                        .get("model")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string();
                    upstream_attempts.lock().unwrap().push(model);
                    (StatusCode::OK, "ok")
                }
            }),
        );
        let (base_url, upstream_handle) = spawn_upstream(upstream).await;

        let state = AppState::new(test_config(base_url));
        {
            let mut runtime = state.runtime.write().await;
            runtime.candidates = vec![
                RankedCandidate {
                    name: "chosen/TEE-Model".to_string(),
                    active_instance_count: 10,
                    utilization_current: 0.2,
                    rate_limit_ratio_5m: 0.0,
                    score: 8.0,
                },
                RankedCandidate {
                    name: "fallback/TEE-Model".to_string(),
                    active_instance_count: 1,
                    utilization_current: 0.1,
                    rate_limit_ratio_5m: 0.0,
                    score: 1.0,
                },
            ];
        }

        let app = app(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/chat/completions")
                    .header("content-type", "application/json")
                    .body(Body::from(r#"{"model":"chutesai/AutoPilot"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);

        assert_eq!(
            resp.headers().get("x-chutes-autopilot-selected").unwrap(),
            &axum::http::header::HeaderValue::from_static("chosen/TEE-Model")
        );

        let got_attempts = attempts.lock().unwrap().clone();
        assert_eq!(got_attempts, vec!["chosen/TEE-Model".to_string()]);

        let _ = resp.into_body().collect().await.unwrap();
        upstream_handle.abort();
    }

    #[tokio::test]
    async fn healthz_ok() {
        let state = AppState::new(AppConfig::default());
        let app = app(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/healthz")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn readyz_defaults_to_503() {
        let state = AppState::new(AppConfig::default());
        let app = app(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/readyz")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::SERVICE_UNAVAILABLE);
    }

    #[tokio::test]
    async fn readyz_returns_200_when_snapshot_is_fresh_and_non_empty() {
        let state = AppState::new(AppConfig::default());
        {
            let mut runtime = state.runtime.write().await;
            runtime.candidates = vec![RankedCandidate {
                name: "ready/TEE-Model".to_string(),
                active_instance_count: 1,
                utilization_current: 0.0,
                rate_limit_ratio_5m: 0.0,
                score: 1.0,
            }];
            runtime.snapshot_at = Some(Instant::now());
        }
        let app = app(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/readyz")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn readyz_returns_503_when_snapshot_is_stale() {
        let mut cfg = AppConfig::default();
        cfg.readyz_max_snapshot_age = Duration::from_millis(1);

        let state = AppState::new(cfg);
        {
            let mut runtime = state.runtime.write().await;
            runtime.candidates = vec![RankedCandidate {
                name: "stale/TEE-Model".to_string(),
                active_instance_count: 1,
                utilization_current: 0.0,
                rate_limit_ratio_5m: 0.0,
                score: 1.0,
            }];
            runtime.snapshot_at = Some(Instant::now() - Duration::from_secs(1));
        }
        let app = app(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/readyz")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::SERVICE_UNAVAILABLE);

        let bytes = resp.into_body().collect().await.unwrap().to_bytes();
        let parsed: OpenAiErrorResponse = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(parsed.error.code.as_deref(), Some("stale_snapshot"));
    }

    #[tokio::test]
    async fn chat_completions_direct_mode_proxies_upstream_without_selected_header() {
        let attempts: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let upstream_attempts = attempts.clone();
        let upstream = Router::new().route(
            "/v1/chat/completions",
            post(move |Json(v): Json<Value>| {
                let upstream_attempts = upstream_attempts.clone();
                async move {
                    let model = v
                        .get("model")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string();
                    upstream_attempts.lock().unwrap().push(model);
                    (StatusCode::CREATED, "direct-ok")
                }
            }),
        );
        let (base_url, upstream_handle) = spawn_upstream(upstream).await;

        let state = AppState::new(test_config(base_url));
        let app = app(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/chat/completions")
                    .header("content-type", "application/json")
                    .body(Body::from(r#"{"model":"direct-TEE"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::CREATED);
        assert!(resp.headers().get("x-chutes-autopilot-selected").is_none());

        let got_attempts = attempts.lock().unwrap().clone();
        assert_eq!(got_attempts, vec!["direct-TEE".to_string()]);

        let body = resp.into_body().collect().await.unwrap().to_bytes();
        assert_eq!(body, Bytes::from_static(b"direct-ok"));

        upstream_handle.abort();
    }

    #[tokio::test]
    async fn chat_completions_streams_upstream_body_without_buffering() {
        let upstream = Router::new().route(
            "/v1/chat/completions",
            post(|Json(_): Json<Value>| async move {
                let first = stream::once(async move {
                    Ok::<Bytes, std::io::Error>(Bytes::from_static(b"first"))
                });
                let second = stream::once(async move {
                    tokio::time::sleep(Duration::from_millis(200)).await;
                    Ok::<Bytes, std::io::Error>(Bytes::from_static(b"second"))
                });
                let combined = first.chain(second);

                let mut resp = Response::new(Body::from_stream(combined));
                *resp.status_mut() = StatusCode::OK;
                resp
            }),
        );
        let (upstream_url, upstream_handle) = spawn_upstream(upstream).await;

        let state = AppState::new(test_config(upstream_url));
        let router = app(state);
        let (autopilot_url, autopilot_handle) = spawn_upstream(router).await;

        let resp = reqwest::Client::new()
            .post(format!("{autopilot_url}/v1/chat/completions"))
            .header("content-type", "application/json")
            .body(r#"{"model":"direct-TEE"}"#)
            .send()
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);

        let mut body_stream = resp.bytes_stream();
        let first = tokio::time::timeout(Duration::from_millis(100), body_stream.next())
            .await
            .expect("timed out waiting for first body chunk")
            .expect("upstream response ended early")
            .expect("upstream chunk error");
        assert_eq!(first, Bytes::from_static(b"first"));

        let mut rest: Vec<u8> = Vec::new();
        while let Some(item) = body_stream.next().await {
            let chunk = item.expect("upstream chunk error");
            rest.extend_from_slice(chunk.as_ref());
        }

        let mut combined: Vec<u8> = Vec::new();
        combined.extend_from_slice(first.as_ref());
        combined.extend_from_slice(&rest);
        assert_eq!(combined, b"firstsecond");

        autopilot_handle.abort();
        upstream_handle.abort();
    }

    #[tokio::test]
    async fn chat_completions_returns_openai_error_shape() {
        let state = AppState::new(AppConfig::default());
        let app = app(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/chat/completions")
                    .header("content-type", "application/json")
                    .body(Body::from(r#"{"model":"chutesai/AutoPilot"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::SERVICE_UNAVAILABLE);

        let bytes = resp.into_body().collect().await.unwrap().to_bytes();
        let parsed: OpenAiErrorResponse = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(parsed.error.error_type, "server_error");
        assert_eq!(parsed.error.param.as_deref(), Some("model"));
        assert_eq!(parsed.error.code.as_deref(), Some("no_candidates"));
    }

    #[tokio::test]
    async fn chat_completions_rejects_model_list_items_not_in_allowlist_when_present() {
        let state = AppState::new(AppConfig::default());
        {
            let mut runtime = state.runtime.write().await;
            runtime.tee_allowlist = HashSet::from([
                "allowed/TEE-Model".to_string(),
                "other/TEE-Model".to_string(),
            ]);
        }

        let app = app(state);
        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/chat/completions")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        r#"{"model":"allowed/TEE-Model,missing/TEE-Model"}"#,
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

        let bytes = resp.into_body().collect().await.unwrap().to_bytes();
        let parsed: OpenAiErrorResponse = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(parsed.error.error_type, "invalid_request_error");
        assert_eq!(parsed.error.param.as_deref(), Some("model"));
        assert_eq!(parsed.error.code.as_deref(), Some("model_not_tee"));
    }

    #[tokio::test]
    async fn chat_completions_model_list_failover_on_503() {
        let attempts: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let upstream_attempts = attempts.clone();
        let upstream = Router::new().route(
            "/v1/chat/completions",
            post(move |Json(v): Json<Value>| {
                let upstream_attempts = upstream_attempts.clone();
                async move {
                    let model = v
                        .get("model")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string();
                    upstream_attempts.lock().unwrap().push(model.clone());

                    if model == "first-TEE" {
                        return (StatusCode::SERVICE_UNAVAILABLE, "try later").into_response();
                    }

                    (StatusCode::OK, "ok").into_response()
                }
            }),
        );
        let (base_url, upstream_handle) = spawn_upstream(upstream).await;

        let state = AppState::new(test_config(base_url));
        let app = app(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/chat/completions")
                    .header("content-type", "application/json")
                    .body(Body::from(r#"{"model":"first-TEE,second-TEE"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
        assert_eq!(
            resp.headers().get("x-chutes-autopilot-selected").unwrap(),
            &axum::http::header::HeaderValue::from_static("second-TEE")
        );

        let got_attempts = attempts.lock().unwrap().clone();
        assert_eq!(
            got_attempts,
            vec!["first-TEE".to_string(), "second-TEE".to_string()]
        );

        let _ = resp.into_body().collect().await.unwrap();
        upstream_handle.abort();
    }

    #[tokio::test]
    async fn chat_completions_model_list_failover_on_header_timeout() {
        let attempts: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let upstream_attempts = attempts.clone();
        let upstream = Router::new().route(
            "/v1/chat/completions",
            post(move |Json(v): Json<Value>| {
                let upstream_attempts = upstream_attempts.clone();
                async move {
                    let model = v
                        .get("model")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string();
                    upstream_attempts.lock().unwrap().push(model.clone());

                    if model == "slow-TEE" {
                        tokio::time::sleep(Duration::from_millis(200)).await;
                        return (StatusCode::OK, "slow").into_response();
                    }

                    (StatusCode::OK, "fast").into_response()
                }
            }),
        );
        let (base_url, upstream_handle) = spawn_upstream(upstream).await;

        let mut cfg = test_config(base_url);
        cfg.upstream_header_timeout = Duration::from_millis(50);
        let state = AppState::new(cfg);
        let app = app(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/chat/completions")
                    .header("content-type", "application/json")
                    .body(Body::from(r#"{"model":"slow-TEE,fast-TEE"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
        assert_eq!(
            resp.headers().get("x-chutes-autopilot-selected").unwrap(),
            &axum::http::header::HeaderValue::from_static("fast-TEE")
        );

        let got_attempts = attempts.lock().unwrap().clone();
        assert_eq!(
            got_attempts,
            vec!["slow-TEE".to_string(), "fast-TEE".to_string()]
        );

        let body = resp.into_body().collect().await.unwrap().to_bytes();
        assert_eq!(body, Bytes::from_static(b"fast"));

        upstream_handle.abort();
    }

    #[tokio::test]
    async fn chat_completions_model_list_does_not_retry_on_429() {
        let attempts: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let upstream_attempts = attempts.clone();
        let upstream = Router::new().route(
            "/v1/chat/completions",
            post(move |Json(v): Json<Value>| {
                let upstream_attempts = upstream_attempts.clone();
                async move {
                    let model = v
                        .get("model")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string();
                    upstream_attempts.lock().unwrap().push(model.clone());

                    if model == "first-TEE" {
                        return (StatusCode::TOO_MANY_REQUESTS, "rate limited").into_response();
                    }

                    (StatusCode::OK, "ok").into_response()
                }
            }),
        );
        let (base_url, upstream_handle) = spawn_upstream(upstream).await;

        let state = AppState::new(test_config(base_url));
        let app = app(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/chat/completions")
                    .header("content-type", "application/json")
                    .body(Body::from(r#"{"model":"first-TEE,second-TEE"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::TOO_MANY_REQUESTS);
        assert_eq!(
            resp.headers().get("x-chutes-autopilot-selected").unwrap(),
            &axum::http::header::HeaderValue::from_static("first-TEE")
        );

        let got_attempts = attempts.lock().unwrap().clone();
        assert_eq!(got_attempts, vec!["first-TEE".to_string()]);

        let _ = resp.into_body().collect().await.unwrap();
        upstream_handle.abort();
    }

    #[tokio::test]
    async fn chat_completions_model_list_failover_on_first_body_timeout() {
        let attempts: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let upstream_attempts = attempts.clone();
        let upstream = Router::new().route(
            "/v1/chat/completions",
            post(move |Json(v): Json<Value>| {
                let upstream_attempts = upstream_attempts.clone();
                async move {
                    let model = v
                        .get("model")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string();
                    upstream_attempts.lock().unwrap().push(model.clone());

                    if model == "stall-TEE" {
                        let delayed = stream::once(async move {
                            tokio::time::sleep(Duration::from_millis(200)).await;
                            Ok::<Bytes, std::io::Error>(Bytes::from_static(b"late"))
                        });
                        let mut resp = Response::new(Body::from_stream(delayed));
                        *resp.status_mut() = StatusCode::OK;
                        return resp;
                    }

                    (StatusCode::OK, "ok").into_response()
                }
            }),
        );
        let (base_url, upstream_handle) = spawn_upstream(upstream).await;

        let state = AppState::new(test_config(base_url));
        let app = app(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/chat/completions")
                    .header("content-type", "application/json")
                    .body(Body::from(r#"{"model":"stall-TEE,second-TEE"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
        assert_eq!(
            resp.headers().get("x-chutes-autopilot-selected").unwrap(),
            &axum::http::header::HeaderValue::from_static("second-TEE")
        );

        let got_attempts = attempts.lock().unwrap().clone();
        assert_eq!(
            got_attempts,
            vec!["stall-TEE".to_string(), "second-TEE".to_string()]
        );

        let body = resp.into_body().collect().await.unwrap().to_bytes();
        assert_eq!(body, Bytes::from_static(b"ok"));

        upstream_handle.abort();
    }

    #[tokio::test]
    async fn chat_completions_model_list_does_not_retry_after_committing_body_bytes() {
        let attempts: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let upstream_attempts = attempts.clone();
        let upstream = Router::new().route(
            "/v1/chat/completions",
            post(move |Json(v): Json<Value>| {
                let upstream_attempts = upstream_attempts.clone();
                async move {
                    let model = v
                        .get("model")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string();
                    upstream_attempts.lock().unwrap().push(model.clone());

                    if model == "first-TEE" {
                        let first = stream::once(async move {
                            Ok::<Bytes, std::io::Error>(Bytes::from_static(b"first"))
                        });
                        let second = stream::once(async move {
                            tokio::time::sleep(Duration::from_millis(10)).await;
                            Err::<Bytes, std::io::Error>(std::io::Error::other("boom"))
                        });
                        let combined = first.chain(second);

                        let mut resp = Response::new(Body::from_stream(combined));
                        *resp.status_mut() = StatusCode::OK;
                        return resp;
                    }

                    (StatusCode::OK, "ok").into_response()
                }
            }),
        );
        let (upstream_url, upstream_handle) = spawn_upstream(upstream).await;

        let state = AppState::new(test_config(upstream_url));
        let router = app(state);
        let (autopilot_url, autopilot_handle) = spawn_upstream(router).await;

        let resp = reqwest::Client::new()
            .post(format!("{autopilot_url}/v1/chat/completions"))
            .header("content-type", "application/json")
            .body(r#"{"model":"first-TEE,second-TEE"}"#)
            .send()
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
        assert_eq!(
            resp.headers()
                .get("x-chutes-autopilot-selected")
                .unwrap()
                .to_str()
                .unwrap(),
            "first-TEE"
        );

        let mut body_stream = resp.bytes_stream();
        let first = tokio::time::timeout(Duration::from_millis(100), body_stream.next())
            .await
            .expect("timed out waiting for first body chunk")
            .expect("body ended early")
            .expect("chunk error");
        assert_eq!(first, Bytes::from_static(b"first"));

        tokio::time::sleep(Duration::from_millis(50)).await;

        let got_attempts = attempts.lock().unwrap().clone();
        assert_eq!(got_attempts, vec!["first-TEE".to_string()]);

        autopilot_handle.abort();
        upstream_handle.abort();
    }

    #[tokio::test]
    async fn chat_completions_invalid_model_list_returns_400_openai_shape() {
        let state = AppState::new(AppConfig::default());
        let app = app(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/chat/completions")
                    .header("content-type", "application/json")
                    .body(Body::from(r#"{"model":","}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

        let bytes = resp.into_body().collect().await.unwrap().to_bytes();
        let parsed: OpenAiErrorResponse = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(parsed.error.error_type, "invalid_request_error");
        assert_eq!(parsed.error.param.as_deref(), Some("model"));
        assert_eq!(parsed.error.code.as_deref(), Some("invalid_model_list"));
    }

    #[tokio::test]
    async fn chat_completions_rejects_non_tee_items_in_model_list() {
        let state = AppState::new(AppConfig::default());
        let app = app(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/chat/completions")
                    .header("content-type", "application/json")
                    .body(Body::from(r#"{"model":"a-TEE,b"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

        let bytes = resp.into_body().collect().await.unwrap().to_bytes();
        let parsed: OpenAiErrorResponse = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(parsed.error.error_type, "invalid_request_error");
        assert_eq!(parsed.error.param.as_deref(), Some("model"));
        assert_eq!(parsed.error.code.as_deref(), Some("model_not_tee"));
    }

    #[tokio::test]
    async fn chat_completions_rejects_single_non_tee_model() {
        let state = AppState::new(AppConfig::default());
        let app = app(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/chat/completions")
                    .header("content-type", "application/json")
                    .body(Body::from(r#"{"model":"moonshotai/Kimi-K2.5"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

        let bytes = resp.into_body().collect().await.unwrap().to_bytes();
        let parsed: OpenAiErrorResponse = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(parsed.error.error_type, "invalid_request_error");
        assert_eq!(parsed.error.param.as_deref(), Some("model"));
        assert_eq!(parsed.error.code.as_deref(), Some("model_not_tee"));
    }

    #[test]
    fn derive_sticky_key_parses_xff_socketaddr_when_peer_is_trusted() {
        let mut cfg = AppConfig::default();
        cfg.trust_proxy_headers = true;
        cfg.trusted_proxy_cidrs = vec!["203.0.113.0/24".parse::<IpNet>().unwrap()];

        let mut headers = HeaderMap::new();
        headers.insert(
            "x-forwarded-for",
            HeaderValue::from_static("198.51.100.7:1234, 203.0.113.10"),
        );
        let connect_info = Some(ConnectInfo(
            "203.0.113.10:5678".parse::<SocketAddr>().unwrap(),
        ));

        let got = derive_sticky_key(&cfg, &headers, &connect_info).unwrap();
        assert_eq!(got, "ip:198.51.100.7");
    }

    #[tokio::test]
    async fn chat_completions_rejects_body_over_max_request_bytes_with_openai_shape() {
        let mut cfg = AppConfig::default();
        cfg.max_request_bytes = 32;

        let state = AppState::new(cfg);
        let app = app(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/chat/completions")
                    .header("content-type", "application/json")
                    .body(Body::from(vec![b'a'; 128]))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::PAYLOAD_TOO_LARGE);

        let bytes = resp.into_body().collect().await.unwrap().to_bytes();
        let parsed: OpenAiErrorResponse = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(parsed.error.error_type, "invalid_request_error");
        assert_eq!(parsed.error.code.as_deref(), Some("request_too_large"));
        assert_eq!(parsed.error.message, "request body too large");
    }
}
