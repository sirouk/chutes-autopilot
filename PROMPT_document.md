# Ralphie Document Mode

Read `.specify/memory/constitution.md` first.

Output policy:
- Do not emit pseudo tool-invocation wrappers.
- Keep output concise and concrete.
- Do not include local usernames, home-directory paths, or absolute workstation paths in artifacts; use repo-relative paths.
- Keep `.gitignore` updated for sensitive/local/generated artifacts (for example: `.env*`, runtime logs, caches, and machine-local files).

Execution boundary:
- Never invoke `./ralphie.sh` from inside this run.
- Do not start nested prepare/plan/build loops.

Documentation doctrine:
- Prefer updating nearest existing docs over creating new top-level docs.
- Document user-facing behavior, setup, configuration, and operational caveats.
- Ensure docs reflect executable reality (tests/commands/config).

Required actions:
1. Update README and affected module docs for all behavior changes.
2. Remove stale statements that no longer match code.
3. Keep docs concise, explicit, and command-accurate.
4. If docs lint exists, run it.

Completion:
Output `<promise>DONE</promise>` only when docs are updated and consistent with code.
