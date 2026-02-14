# 003 - Utilization Fetch + Ranking

## Context

Autopilot uses `https://api.chutes.ai/chutes/utilization` as a control-plane signal to rank available public chutes and drive deterministic selection and failover.

Important: the utilization feed includes public chutes that are not chat-capable LLM models (for example image or embedding chutes). AutoPilot selection for `POST /v1/chat/completions` MUST be constrained to an authoritative chat-model catalog.

## Requirements

- Maintain an in-memory allowlist of **eligible chat-capable model ids** sourced from the upstream OpenAI-style models endpoint:
  - `GET https://llm.chutes.ai/v1/models` (configurable via `MODELS_URL`)
  - Parse `data[].id` into `models_allowlist: HashSet<String>`
  - On fetch/parse failure, keep the last-known-good allowlist
- Refresh the model allowlist on a fixed interval (`MODELS_REFRESH_MS`).
- Fetch utilization from `UTILIZATION_URL` on a fixed interval (`UTILIZATION_REFRESH_MS`).
- Parse the response as a JSON array of chute objects.
- Filter candidates:
  - Exclude `name == "[private chute]"`
  - Require `active_instance_count > 0`
  - Require the chute name is present in the model allowlist when the allowlist is non-empty
  - If the allowlist is empty/unavailable (startup or prolonged outage), fall back to a conservative eligibility heuristic:
    - require `name` ends with `-TEE`
- Score each candidate:
  - Utilization:
    - `u5 = utilization_5m ?? utilization_current ?? 1.0`
    - `u15 = utilization_15m ?? u5`
    - `u1h = utilization_1h ?? u15`
    - `util = 0.6*u5 + 0.3*u15 + 0.1*u1h`
  - Rate limiting:
    - `r5 = rate_limit_ratio_5m ?? 0.0`
    - `r15 = rate_limit_ratio_15m ?? r5`
    - `r1h = rate_limit_ratio_1h ?? r15`
    - `rl = max(r5, 0.5*r15, 0.25*r1h)`
  - Score:
    - `free_capacity = active_instance_count * (1 - util)`
    - `scale_bonus = (scalable ? min(scale_allowance, 8) : 0) * 0.05`
    - `score = free_capacity + scale_bonus - (active_instance_count * rl * 2.0)`
- Sort deterministically (tie-breakers in order):
  1. `score` (desc)
  2. `active_instance_count` (desc)
  3. `utilization_current` (asc)
  4. `rate_limit_ratio_5m` (asc)
  5. `name` (asc)

### Policy Note: Rate Limiting Signals

- `rate_limit_ratio_*` is treated as a **chute-level throttling signal** that influences ranking only (pick chutes that are less likely to throttle).
- Upstream `429` responses are treated as **user-caused and non-retryable** and are proxied back to the client (no failover). See `specs/002-autopilot-mvp/spec.md`.

## Acceptance Criteria

1. Candidate ranking is deterministic for a fixed utilization input.
2. Filtering behaves exactly as specified.
3. If a refresh attempt fails (network error or invalid JSON), the last-known-good snapshot remains active.
4. Unit tests cover:
   - filtering rules
   - score calculation
   - deterministic sorting
5. Model allowlist behavior:
   - When a non-empty allowlist exists, only candidates in the allowlist are eligible (even if they match the `-TEE` suffix heuristic).
   - When the allowlist is empty, the `-TEE` suffix heuristic is used for eligibility.
6. Model allowlist refresh failure:
   - If a model allowlist refresh attempt fails, the last-known-good allowlist remains active.

## Status: COMPLETE
