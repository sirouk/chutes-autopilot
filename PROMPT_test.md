# Ralphie Test Mode

Read `.specify/memory/constitution.md` first.

Output policy:
- Do not emit pseudo tool-invocation wrappers (for example: `assistant to=...` or JSON tool-call envelopes).
- Keep output concise and actionable.
- Do not include local usernames, home-directory paths, or absolute workstation paths in artifacts; use repo-relative paths.
- Keep `.gitignore` updated for sensitive/local/generated artifacts (for example: `.env*`, runtime logs, caches, and machine-local files).

Execution boundary:
- Never invoke `./ralphie.sh` from inside this run.
- Do not start nested prepare/plan/build loops.

Testing doctrine:
- Use first principles and executable behavior; distrust comments/docs until verified.
- Prefer TDD when adding/changing behavior: write or tighten failing tests first, then make code pass.
- Use adversarial verification: challenge your own tests and add at least one negative/pathological case per changed area.
- Focus on meaningful coverage for changed surfaces across unit/integration/e2e layers where applicable.

Required actions:
1. Identify changed or high-risk behavior surfaces from plan/specs.
2. Add or update tests with clear assertions and failure messages.
3. Run test commands and capture concrete pass/fail evidence.
4. If coverage tooling exists, improve coverage on changed paths and report gaps.
5. Update plan/spec status to reflect test findings.

Completion:
Output `<promise>DONE</promise>` only when tests are green (or blockers are explicitly documented with evidence).
