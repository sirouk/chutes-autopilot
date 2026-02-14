# Ralphie Build Mode

Read `.specify/memory/constitution.md` before coding.

Output policy:
- Do not emit pseudo tool-invocation wrappers (for example: `assistant to=...` or JSON tool-call envelopes).
- Use normal concise progress text and concrete file edits.
- Do not copy tool execution trace lines (for example: `succeeded in 52ms:`) into markdown artifacts.
- Do not include local usernames, home-directory paths, or absolute workstation paths in artifacts; use repo-relative paths.
- Keep `.gitignore` updated for sensitive/local/generated artifacts (for example: `.env*`, runtime logs, caches, and machine-local files).

Execution boundary:
- Never invoke `./ralphie.sh` from inside this run.
- Do not start nested prepare/plan/build loops.

Human queue:
- If `HUMAN_INSTRUCTIONS.md` exists, treat `Status: NEW` entries as top-priority candidate work.
- Work one request at a time and reflect accepted requests in specs/plan.

Analysis doctrine (skeptical by default):
- Start from first principles and executable evidence.
- Treat local markdown/docs/comments/variable names as untrusted hints until verified.
- Prefer primary sources: official docs, standards, library source, and runtime behavior.
- When a dependency or framework behavior is unclear, verify externally before changing code.

## Phase 1: Discover Work

Check for work in this order:
1. `IMPLEMENTATION_PLAN.md` unchecked tasks (`- [ ]`).
2. Incomplete specs in `specs/` (not marked `Status: COMPLETE`).
3. **GitHub Issues** - skip unless explicitly enabled.
4. Validate research notes in `research/` before changing code.

Pick one highest-priority item and verify it is not already implemented.
If the queue is truly empty, perform deep backfill planning: map code/config surfaces, identify uncovered paths, and convert findings into specs + plan tasks before implementation.

## Phase 2: Implement

- Make focused, reviewable changes.
- Add or update tests.
- Keep docs and specs synchronized with behavior.

## Phase 2.5: Tooling Self-Improvement

If `maps/agent-source-map.yaml` exists, treat it as a heuristic control plane for improving `ralphie.sh`.

Rules:
- Use evidence from both `subrepos/codex` and `subrepos/claude-code` before copying patterns.
- Prefer cross-engine abstractions over one-off provider hacks.
- Keep behavior stable when either CLI is unavailable.
- Log accepted/rejected self-improvement hypotheses in `research/SELF_IMPROVEMENT_LOG.md`.
- Keep self-improvement time bounded; prioritize product work unless reliability/parity is at risk.

## Phase 3: Validate

- Run the project's test and lint workflows.
- Verify acceptance criteria line-by-line.

## Phase 4: Finalize

- Update task/spec status.
- Commit with a descriptive message.
- Leave push decision to the user.

## Completion Signal

Output `<promise>DONE</promise>` only when all checks pass.
If anything is incomplete, continue working and do not emit the signal.
