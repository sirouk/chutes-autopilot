# Implementation Plan

## Goal
Deliver a production-ready Chutes Autopilot router with hardened control-plane freshness, request safety, observability, container supply-chain hygiene, and secret handling so it can ship confidently at scale.

## Acceptance Criteria
- `cargo fmt --check`, `cargo clippy -- -D warnings`, and `cargo test` stay green; new coverage spans readiness, failover, and property cases; latest results are recorded in `logs/baseline.md`.
- Secrets/hygiene scans (gitleaks + trufflehog) are documented in `logs/secrets.md`; `.gitignore` and `.env.example` cover new logs/cache artifacts without leaking credentials.
- `/readyz` fails when candidate snapshot, model allowlist, or utilization data is missing or stale beyond configured thresholds; observability surfaces snapshot ages and candidate counts.
- Streaming proxy honors no-retry-after-commit and handles connect/header/first-byte timeouts plus connection resets across alias, preference-list, and direct requests; proptest/fuzz covers model list parsing, stickiness, and request-size edges.
- Offline smoke harness (`make smoke`) exercises alias, ordered list, and direct modes against a stub upstream; artifacts live under `logs/smoke/` and are ignored by git.
- Live Chutes integration findings (auth, rate-limit, attestation evidence/TEE metadata) are captured in `research/COVERAGE_MATRIX.md` with matching offline fixtures and tests for parity.
- Container build is reproducible, minimal, and non-root; docker-compose healthcheck targets `/readyz`; README documents image/user expectations and any runtime caps.

## Tasks (ordered by dependency and impact)
- [ ] Secrets & repo hygiene: run gitleaks + trufflehog (working tree + history); summarize in `logs/secrets.md`; extend `.gitignore`/`.env.example` for new logs/cache outputs.
- [ ] Control-plane freshness gating: track allowlist/utilization timestamps and last-known-good; make `/readyz` fail on stale/empty datasets; add tests for fresh/stale/absent paths.
- [ ] Observability: add structured tracing/metrics for request id, selected model, snapshot ages, candidate counts, and failover reason; ensure sensitive headers/bodies are never logged.
- [ ] Property-based safety: add `proptest`/fuzz cases for model list parsing/dedup/limits, sticky key derivation (auth vs IP vs trusted proxy), and `MAX_REQUEST_BYTES` enforcement.
- [ ] Streaming failover coverage: extend Axum harness to cover connect timeout, connection reset, and ensure no retries after body commit across alias/preference/direct paths; assert debug header semantics.
- [ ] Offline smoke harness: build stub upstream + fixtures and a `make smoke` target (and CI hook) that exercises alias, preference list, and direct flows without external network; store outputs under `logs/smoke/`.
- [ ] Chutes live integration check (provider-specific): run against real backend to record auth requirements, rate-limit behavior, and `/chutes/{id}/evidence`/TEE metadata; document in `research/COVERAGE_MATRIX.md` and specs if behavior diverges.
- [ ] Parity fixtures for Chutes flows: capture/construct stub responses for auth errors, rate limits, and attestation evidence so tests and smoke runs mirror live findings without hitting Chutes.
- [ ] Container & compose hardening: refactor Dockerfile for cached deps, stripped binary, non-root user on minimal base with pinned certs; update docker-compose healthcheck to `/readyz`; document image size/runtime user in README.
- [ ] CI/runtime automation: add `make lint`/`make smoke` into a GitHub Actions workflow (or equivalent) to enforce fmt+clippy+tests+smoke on PRs; publish artifacts to `logs/` when failing.

## Completed
- [x] Baseline fmt/clippy/test run recorded (2026-02-18) in `logs/baseline.md`.
- [x] Core routing: candidate ranking from utilization + model allowlist, alias/direct/model-list modes, sticky rotation, streaming passthrough with pre-commit failover and OpenAI-shaped errors.
