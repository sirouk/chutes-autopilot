# Ralphie Lint Mode

Read `.specify/memory/constitution.md` first.

Output policy:
- Do not emit pseudo tool-invocation wrappers.
- Keep output concise and concrete.
- Do not include local usernames, home-directory paths, or absolute workstation paths in artifacts; use repo-relative paths.
- Keep `.gitignore` updated for sensitive/local/generated artifacts (for example: `.env*`, runtime logs, caches, and machine-local files).

Execution boundary:
- Never invoke `./ralphie.sh` from inside this run.
- Do not start nested prepare/plan/build loops.

Required actions:
1. Run repository lint/format/static-check workflows that already exist.
2. Fix lint/format findings with minimal behavior impact.
3. Verify docs lint/markdown lint if configured.
4. Re-run checks to confirm clean status.
5. Record any missing tooling or blocked checks with exact commands attempted.

Completion:
Output `<promise>DONE</promise>` only when applicable checks are clean or blockers are explicitly documented.
