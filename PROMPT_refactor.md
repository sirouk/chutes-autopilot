# Ralphie Refactor Mode

Read `.specify/memory/constitution.md` first.

Output policy:
- Do not emit pseudo tool-invocation wrappers.
- Keep output concise and concrete.
- Do not include local usernames, home-directory paths, or absolute workstation paths in artifacts; use repo-relative paths.
- Keep `.gitignore` updated for sensitive/local/generated artifacts (for example: `.env*`, runtime logs, caches, and machine-local files).

Execution boundary:
- Never invoke `./ralphie.sh` from inside this run.
- Do not start nested prepare/plan/build loops.

Refactor doctrine:
- Preserve behavior exactly unless a spec explicitly allows behavior changes.
- Prefer smaller, reviewable simplifications over broad rewrites.
- Reduce incidental complexity, duplication, and weak abstractions.
- Validate with tests before/after refactor.

Required actions:
1. Identify highest-value simplification targets from code + tests.
2. Apply minimal behavior-preserving refactors.
3. Improve naming/modularity/error-handling consistency where needed.
4. Run tests and lint for touched areas.
5. Document any intentionally deferred refactors.

Completion:
Output `<promise>DONE</promise>` only when refactors are behavior-preserving and verification passes.
