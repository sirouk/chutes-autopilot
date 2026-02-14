# Chutes Autopilot

Chutes Autopilot is a high-performance OpenAI-compatible router for Chutes LLM models. You send requests to a single endpoint and it routes via either live-utilization ranking (`chutesai/AutoPilot`), an explicit comma-separated preference list, or direct passthrough to a specific model, while keeping responses fully streamed.

This stays intentionally simple:
- It does not transform prompts/messages.
- It does not implement product logic.
- It only selects a chute, rewrites `model`, and proxies the request with true streaming passthrough.

## User Journey

1. Point your OpenAI client at the Autopilot base URL (example): `https://autopilot.chutes.ai`.
2. Set `model` to `chutesai/AutoPilot` (automatic selection), a comma-separated preference list of model ids (explicit failover order), or a specific model id (direct passthrough).
3. Send your normal `POST /v1/chat/completions` request.
4. When Autopilot is selecting between multiple candidates (alias mode or a preference list), the chosen model is sticky per client (keyed by auth token when present, otherwise requester IP) until there are signs of failure, at which point it rotates.
5. The response streams back to you as-is. For debugging, Autopilot can return headers like `x-chutes-autopilot-selected: <chute name>`.

### Example (curl)

```bash
curl -N https://autopilot.chutes.ai/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $CHUTES_API_KEY" \
  -d '{
    "model": "chutesai/AutoPilot",
    "messages": [{"role":"user","content":"Hello"}],
    "stream": true
  }'
```

### Example (OpenAI SDK)

```python
from openai import OpenAI

client = OpenAI(
  base_url="https://autopilot.chutes.ai/v1",
  api_key="YOUR_CHUTES_API_KEY",
)

resp = client.chat.completions.create(
  model="chutesai/AutoPilot",
  messages=[{"role": "user", "content": "Hello"}],
)
print(resp.choices[0].message.content)
```

## Method (How It Works)

Autopilot has two loops: a background refresh loop and the request hot path.

### 1) Background Refresh (Control Plane)

Every ~5 seconds, Autopilot fetches current chute utilization:
- Source: `GET https://api.chutes.ai/chutes/utilization`
- It skips private chutes (the utilization feed includes entries with `name` equal to `[private chute]`).
- It builds an in-memory ranked list of public candidates using cheap fields like:
  `active_instance_count`, `utilization_{5m,15m,1h}`, `rate_limit_ratio_{5m,15m,1h}`, `scalable`, `scale_allowance`, `name`.

Model catalog allowlist:
- Autopilot maintains an in-memory allowlist of eligible chat-capable model ids from `GET https://llm.chutes.ai/v1/models` (configurable via `MODELS_URL`).
- On allowlist refresh failure, it keeps the last-known-good allowlist.
- When the allowlist is empty (for example at startup), ranking falls back to a conservative eligibility heuristic: `-TEE` suffix only.

### 2) Request Handling (Data Plane)

For each incoming `POST /v1/chat/completions` request:
1. Parse the JSON body just enough to read `model`.
2. Determine the ordered candidate list: if `model` is `chutesai/AutoPilot` (or `chutesai-routing/AutoPilot`), use the global ranked list; if it contains `,`, parse it as a preference list (order is respected); otherwise treat it as a direct single-model request.
3. If a non-empty model allowlist is available, validate direct and explicit-list models against it (fail fast on typos/unknown models). If the allowlist is empty/unavailable, proxy upstream and let the upstream enforce.
4. Apply stickiness: compute a client key (prefer `Authorization: Bearer …`, otherwise requester IP); if a sticky model exists for this key and is present in the current candidate set, try it first.
5. Select the first healthy candidate; rewrite `model` to the selected chute `name` (the Autopilot alias is never forwarded upstream).
6. Proxy upstream with streaming passthrough (no buffering) to the configured backend base URL (example: `https://llm.chutes.ai`).

Failover rules (kept simple and safe for streaming):
- If the upstream connection fails, times out before emitting any bytes, or returns 503 before streaming begins, retry the next best candidate.
- If the upstream returns 429 (rate limiting), proxy the 429 back to the client and do not retry (rate limiting is treated as user-caused).
- Once any response bytes have been sent to the client, do not retry.

### Ranking (Deterministic + “Smart”)

Autopilot produces a definitive, deterministic ordering of candidates. The hot path always selects the first candidate in this ordered list, and uses the next items for failover.

Inputs come from `https://api.chutes.ai/chutes/utilization` and look like:
- `name` (includes `-TEE` suffix for TEE chutes; private chutes appear as `[private chute]`)
- `active_instance_count`
- `utilization_current`, `utilization_5m`, `utilization_15m`, `utilization_1h`
- `rate_limit_ratio_5m`, `rate_limit_ratio_15m`, `rate_limit_ratio_1h`
- `scalable`, `scale_allowance`

Algorithm (per refresh):

1. Filter (eligibility): exclude `name == "[private chute]"`; require `active_instance_count > 0`; require `name` is in the model allowlist when the allowlist is non-empty; otherwise fall back to `-TEE` suffix only.

2. Normalize utilization (smooth noisy signals):

```text
u5  = utilization_5m  ?? utilization_current ?? 1.0
u15 = utilization_15m ?? u5
u1h = utilization_1h  ?? u15
util = 0.6*u5 + 0.3*u15 + 0.1*u1h
```

3. Normalize rate limiting (avoid chutes that are currently or recently throttling):

```text
r5  = rate_limit_ratio_5m  ?? 0.0
r15 = rate_limit_ratio_15m ?? r5
r1h = rate_limit_ratio_1h  ?? r15
rl = max(r5, 0.5*r15, 0.25*r1h)
```

4. Score (higher is better):

```text
free_capacity = active_instance_count * (1 - util)
scale_bonus = (scalable ? min(scale_allowance, 8) : 0) * 0.05
score = free_capacity + scale_bonus - (active_instance_count * rl * 2.0)
```

5. Sort (deterministic tie-breakers): sort by `score` (desc), then `active_instance_count` (desc), then `utilization_current` (asc), then `rate_limit_ratio_5m` (asc), then `name` (asc).

## API Compatibility

Supported:
- `POST /v1/chat/completions`

Optional future support (only if it stays pure passthrough):
- `POST /v1/completions`

## Configuration

Environment variables:
- `LISTEN_ADDR` (default: `0.0.0.0:8080`)
- `BACKEND_BASE_URL` (default: `https://llm.chutes.ai`)
- `MODELS_URL` (default: `https://llm.chutes.ai/v1/models`)
- `MODELS_REFRESH_MS` (default: `300000`)
- `UTILIZATION_URL` (default: `https://api.chutes.ai/chutes/utilization`)
- `UTILIZATION_REFRESH_MS` (default: `5000`)
- `CONTROL_PLANE_TIMEOUT_MS` (default: `10000`)
- `READYZ_MAX_SNAPSHOT_AGE_MS` (default: `20000`)
- `RUST_LOG` (default: `info`)
- `STICKY_TTL_SECS` (default: `1800`)
- `STICKY_MAX_ENTRIES` (default: `10000`)
- `TRUST_PROXY_HEADERS` (default: `false`)
- `TRUSTED_PROXY_CIDRS` (default: empty; comma-separated CIDRs)
- `MAX_REQUEST_BYTES` (default: `1048576`)
- `MAX_MODEL_LIST_ITEMS` (default: `8`)
- `UPSTREAM_CONNECT_TIMEOUT_MS` (default: `2000`)
- `UPSTREAM_HEADER_TIMEOUT_MS` (default: `10000`)
- `UPSTREAM_FIRST_BODY_BYTE_TIMEOUT_MS` (default: `120000`)

## Deployment

Recommended production setup is the same pattern as our prior proxies:
- Run the Autopilot service behind Caddy for TLS and clean domain routing.
- Keep the data plane hot path minimal (streaming passthrough) and do all decisioning via an in-memory snapshot.

### From Source (Local Dev)

This repo includes:
- `.env.example` (documented defaults)
- `.env` (a safe local test configuration; no secrets)

Run with `.env` loaded:

```bash
make run-env
```

Then test:

```bash
curl -sS http://127.0.0.1:8082/healthz
curl -sS http://127.0.0.1:8082/readyz
```

### Docker Compose (Service + Caddy)

This repo includes `docker-compose.yaml`, `Dockerfile`, `Caddyfile`, and `caddy-entrypoint.sh` in the same pattern as `claude-proxy`.

```bash
docker-compose up -d
docker-compose logs -f
```

Configure via environment variables (or a `.env` file):
- `HOST_PORT` (default: `8080`) maps host `HOST_PORT` -> container `8080`
- `CADDY_TLS` (default: `true`)
- `CADDY_DOMAIN` (optional; when set and `CADDY_TLS=true`, enables auto-HTTPS)
- `CADDY_PORT` (default: `443`)

## Development

Prereqs for linting (if using `rustup`):

```bash
rustup component add rustfmt clippy
```

Run:

```bash
cargo run
# override the bind address:
# LISTEN_ADDR=127.0.0.1:8080 cargo run
```

Test:

```bash
cargo test
```

Lint/format:

```bash
cargo fmt --check
cargo clippy -- -D warnings
```
