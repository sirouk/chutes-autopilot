# 004 - User-Specified Model Preference List

## Context

Some clients want to explicitly control failover order instead of using AutoPilot ranking. Since the upstream API expects a single `model` string, this feature encodes a preference list inside the `model` field and lets Autopilot rewrite `model` per attempt.

Example input proposed by humans:

```text
moonshotai/Kimi-K2.5-TEE,Qwen/Qwen3-Coder-Next,zai-org/GLM-5-FP8
```

Note:
- Non-TEE models are allowed.
- Humans may send misspelled or unknown model names (as in the example above). Autopilot must fail fast with a clear `400` explaining which items are invalid, rather than silently routing to an unintended model.
- When the authoritative model allowlist is available (see `specs/003-utilization-and-ranking/spec.md`), Autopilot should validate list items against it to catch typos and non-existent names.

Valid example:

```text
deepseek-ai/DeepSeek-V3.2-TEE,deepseek-ai/DeepSeek-V3-0324-TEE
```

## Requirements

- If the incoming request JSON contains a `model` string containing `,`, treat it as an explicit ordered list of model names.
- Parse the list as follows:
  - Split on `,`
  - Trim ASCII whitespace around each item
  - Discard empty items
  - De-duplicate items while preserving first-seen order
  - Enforce a maximum list length `MAX_MODEL_LIST_ITEMS` (default: `8`; if exceeded: return `400`)
- If the parsed list is empty, return `400` (do not proxy upstream).
- Every item in the list MUST be present in the authoritative model allowlist when the allowlist is non-empty (see `specs/003-utilization-and-ranking/spec.md`).
  - If the allowlist is non-empty and any item is not present: return `400` (do not proxy upstream).
  - If the allowlist is empty/unavailable, do not locally validate items (proxy upstream and let the upstream enforce).
- Attempt upstream proxy in list order:
  - For attempt `i`, rewrite the request body `model` to the `i`th list item (all other JSON fields MUST be preserved).
  - Failover to the next item only under the same retry boundary as AutoPilot:
    - connection failure, OR
    - upstream returns `503`
    - upstream times out before response headers (`UPSTREAM_HEADER_TIMEOUT_MS`)
    - upstream returns a 2xx response but does not emit any body bytes within `UPSTREAM_FIRST_BODY_BYTE_TIMEOUT_MS`
    - AND Autopilot has not written any response bytes to the client yet
  - If the upstream returns `429`, Autopilot MUST proxy the `429` response back to the client and MUST NOT attempt later items (rate limiting is treated as user-caused and non-retryable).
- On success (first attempt that returns a response), add response header:
  - `x-chutes-autopilot-selected: <model>`
- Never log request bodies or auth headers.
- All `400` responses produced by this feature MUST use the OpenAI `ErrorResponse` JSON shape, with:
  - `error.type = "invalid_request_error"`
  - `error.param = "model"`
  - `error.message` describing the parsing/validation failure and listing invalid items when relevant
  - `error.code` set to a stable string (recommended values below):
    - `invalid_model_list` (list parsing/validation failures)
    - `unknown_model` (one or more list items are not present in the authoritative model allowlist)

## Acceptance Criteria

1. **Parsing**
   - `model="a,b,c"` results in the attempt order `["a","b","c"]`.
   - `model=" a , b , b "` results in the attempt order `["a","b"]`.
   - `model="a,,b,"` results in the attempt order `["a","b"]`.
   - `model=","` returns `400` with `error.code == "invalid_model_list"`.
   - `model` with more than `MAX_MODEL_LIST_ITEMS` items returns `400`.
2. **Allowlist validation**
   - Non-TEE models are allowed.
   - When an authoritative model allowlist is available and non-empty, any list containing an item not present in the allowlist returns `400` and does not proxy upstream.
   - For these `400` responses, `error.param == "model"` and `error.code == "unknown_model"`.
3. **Failover**
   - If attempt 1 fails to connect, attempt 2 is tried.
   - If attempt 1 returns `503` before any response bytes are sent to the client, attempt 2 is tried.
   - If attempt 1 returns `429`, no further attempts occur and the `429` response is proxied to the client.
   - If attempt 1 writes any response bytes to the client, no further attempts occur.
4. **Selection header**
   - On success, `x-chutes-autopilot-selected` equals the model that produced the response.

## Status: COMPLETE
