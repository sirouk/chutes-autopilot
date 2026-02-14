# Ralphie Plan Mode

Read `.specify/memory/constitution.md`.

Output policy:
- Do not emit pseudo tool-invocation wrappers (for example: `assistant to=...` or JSON tool-call envelopes).
- Write the plan file directly, then provide plain-text status.
- Do not include tool execution trace lines in the plan markdown.
- Do not include local usernames, home-directory paths, or absolute workstation paths in artifacts; use repo-relative paths.
- Keep `.gitignore` updated for sensitive/local/generated artifacts (for example: `.env*`, runtime logs, caches, and machine-local files).

Execution boundary:
- Never invoke `./ralphie.sh` from inside this run.
- Do not start nested prepare/plan/build loops.

Human queue:
- If `$HUMAN_INSTRUCTIONS_REL` exists, prioritize `Status: NEW` entries in planning.
- Convert one human request at a time into explicit checklist tasks.

Analysis doctrine:
- Be skeptical of local markdown/docs/comments and naming semantics until verified in code/config/runtime.
- Prefer first-principles reasoning plus primary-source references.
- If `research/COVERAGE_MATRIX.md` exists, prioritize uncovered code/config paths first.

Create or refresh `IMPLEMENTATION_PLAN.md` from current specs and code state.

Requirements:
1. Prioritize by dependency and impact.
2. Use actionable checkbox tasks (`- [ ]`).
3. Keep tasks small enough for one loop iteration.
4. Add a short "Completed" section for done items (`- [x]`).
5. If `maps/agent-source-map.yaml` exists, include at least one cross-engine improvement task for `ralphie.sh`.
6. For any provider-specific task, add a paired parity/fallback task.

When the plan is saved and coherent, output:
`<promise>DONE</promise>`
