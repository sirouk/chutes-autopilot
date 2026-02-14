# 002 - Autopilot Router MVP

## Context

Implement a high-performance, OpenAI-compatible router that selects an upstream "chute" model based on live utilization and proxies requests with streaming passthrough.

## Requirements

- Provide an HTTP service that supports:
  - `POST /v1/chat/completions`
  - `GET /healthz`
  - `GET /readyz`
- Maintain a background snapshot of ranked chute candidates refreshed on an interval.
- If the incoming request `model` is an AutoPilot alias, choose the top-ranked chute and proxy upstream.
- If the incoming request `model` is a comma-separated ordered list of models, treat it as an explicit failover order (see `specs/004-user-model-preference-list/spec.md`).
- If the incoming request `model` is neither an alias nor a comma-separated list:
  - If a non-empty model allowlist is available (from `specs/003-utilization-and-ranking/spec.md`), the `model` MUST be present in that allowlist.
    - If not present: return `400` (do not proxy upstream) with OpenAI `ErrorResponse` JSON and `error.code == "unknown_model"`.
  - If the allowlist is empty/unavailable, proxy upstream without local eligibility validation (let the upstream enforce).
- Apply sticky selection + rotation per `specs/005-sticky-selection-and-rotation/spec.md`.
- Stream upstream responses back to the client without buffering the full response.
- Failover to the next candidate only when Autopilot has not committed any bytes to the client.
- Never log request bodies or auth headers.
- When Autopilot returns an error directly (i.e., it does not proxy an upstream response), the error response MUST be JSON and MUST conform to the OpenAI `ErrorResponse` shape:
  - Body: `{"error":{"type":"...","message":"...","param":null_or_string,"code":null_or_string}}`
  - `Content-Type: application/json`
  - The response MUST NOT include sensitive data (request body, auth, client IP).

### Retry / Failover Policy

Definitions:
- **Committed bytes**: Autopilot has sent any response bytes to the client (HTTP status line + headers and/or any body bytes).
- **Retryable failure**: an upstream attempt failed in a way that suggests trying a different chute/model could succeed.

Rules:
- Autopilot MUST NOT retry/fail over once committed bytes have been sent.
- Autopilot MUST treat upstream `429` responses as **non-retryable** and proxy them back to the client (no failover), to avoid using multiple chutes to bypass user-caused rate limiting.
- For upstream 2xx responses where Autopilot has additional candidates available for failover, Autopilot MUST delay committing response bytes to the client until at least one upstream body chunk has been received (or the attempt is abandoned due to `UPSTREAM_FIRST_BODY_BYTE_TIMEOUT_MS`).
- Retryable failures (eligible for failover) are:
  - connection errors (DNS/TCP/TLS) to the upstream backend
  - upstream response header timeout (no response headers within `UPSTREAM_HEADER_TIMEOUT_MS`)
  - upstream `503 Service Unavailable` before any committed bytes
  - upstream "no body bytes yet" timeout for a successful response:
    - if the upstream returned a 2xx response but Autopilot has not received any upstream body bytes within `UPSTREAM_FIRST_BODY_BYTE_TIMEOUT_MS`, treat the attempt as retryable (as long as Autopilot has not committed bytes to the client yet)

## Acceptance Criteria

1. **Endpoint compatibility**
   - `POST /v1/chat/completions` accepts JSON requests and returns upstream status codes and bodies unchanged, except:
     - the `model` field is rewritten when alias routing or model-list routing is used
     - response header `x-chutes-autopilot-selected` is added when alias routing or model-list routing is used
2. **Alias routing**
   - The service treats `chutesai/AutoPilot` and `chutesai-routing/AutoPilot` as aliases.
3. **Health**
   - `GET /healthz` always returns `200`.
   - `GET /readyz` returns `200` only if the candidate snapshot is non-empty and not older than `READYZ_MAX_SNAPSHOT_AGE_MS`.
4. **Streaming**
   - When upstream responds with a streaming body, the service forwards bytes as they arrive (no full buffering) and flushes to the client.
5. **Failover**
   - If an upstream attempt fails to connect, times out before response headers, returns `503`, or hits `UPSTREAM_FIRST_BODY_BYTE_TIMEOUT_MS` for a 2xx response before any committed bytes, the service retries the next candidate.
   - If an upstream attempt returns `429`, the service proxies the `429` response and does not retry.
   - If any bytes were written to the client, the service does not retry.
6. **Model eligibility validation**
   - Non-TEE models are allowed.
   - When a non-empty model allowlist is available, requests that target a model not present in the allowlist are rejected with `400`.
   - For these `400` responses, `error.param == "model"` and `error.code == "unknown_model"`.
7. **Stickiness**
   - Sticky selection and rotation behavior matches `specs/005-sticky-selection-and-rotation/spec.md`.
8. **Error shape**
   - When Autopilot rejects a request before proxying upstream, it returns a JSON body matching the OpenAI `ErrorResponse` schema.

## Status: COMPLETE
