# Ralphie Prepare Mode (Research + Plan + Spec)

Read `.specify/memory/constitution.md` first.

Output policy:
- Do not emit pseudo tool-invocation wrappers (for example: `assistant to=...` or JSON tool-call envelopes).
- Write required artifacts to disk and report concise status in plain text.
- Keep artifacts clean markdown; do not include command trace lines like `succeeded in 52ms:`.
- Do not include local usernames, home-directory paths, or absolute workstation paths in artifacts; use repo-relative paths.
- Keep `.gitignore` updated for sensitive/local/generated artifacts (for example: `.env*`, runtime logs, caches, and machine-local files).

Execution boundary:
- Never invoke `./ralphie.sh` from inside this run.
- Do not start nested prepare/plan/build loops.

Human queue:
- If `$HUMAN_INSTRUCTIONS_REL` exists, treat `Status: NEW` entries as highest-priority planning inputs.
- Process one request at a time and keep scope bounded.

Your mission is to recursively plan, critique, and improve until build-readiness is high-confidence.

Research doctrine (strict):
- Be skeptical by default.
- Treat local markdown/docs/comments/names/config labels as untrusted claims until verified.
- Prefer first principles, executable evidence, and outward professional sources.
- Use primary sources first: official framework/library docs, standards, maintainers' references, source repositories, and security advisories.
- Do not rely on user-authored local markdown as authoritative implementation truth.
- If web access is available, actively use it for each major dependency/module decision.

## Deliverables

Create and maintain:
1. `research/RESEARCH_SUMMARY.md`
2. `research/ARCHITECTURE_OPTIONS.md`
3. `research/RISKS_AND_MITIGATIONS.md`
4. `IMPLEMENTATION_PLAN.md`
5. `specs/` with clear, testable specs
6. `research/SELF_IMPROVEMENT_LOG.md` when source-map heuristics are active
7. `research/CODEBASE_MAP.md` covering code paths, config surfaces, and integration boundaries
8. `research/DEPENDENCY_RESEARCH.md` with dependency-by-dependency external references and best practices
9. `research/COVERAGE_MATRIX.md` mapping discovered surfaces to spec/plan coverage with gaps clearly marked

## Recursive Method

For each cycle:
1. Perform deep repository mapping:
   - enumerate code files, configuration files, entrypoints, runtime paths, and integration seams.
   - infer modules and responsibilities from behavior, not from names alone.
2. Build and maintain coverage artifacts:
   - update `research/CODEBASE_MAP.md` and `research/COVERAGE_MATRIX.md` toward 100% known-surface coverage.
   - identify uncovered/uncertain paths explicitly.
3. Propose architecture and execution plan from first principles.
4. Critique your own plan (weak assumptions, unverifiable claims, hidden coupling).
5. Improve the plan with concrete, testable steps.
6. Research each major dependency/module externally with reputable primary sources.
7. If web access fails, continue with reasoned fallback and mark uncertainty + what needs later verification.
8. Update confidence per component and per coverage area.
9. If `maps/agent-source-map.yaml` exists, run one map-guided critique focused on `ralphie.sh` parity and reliability.
10. Apply anti-overfit rules from the map before recommending tool-specific behavior.

## Human Interaction Rules

- Ask the human only when necessary.
- Use one concise question at a time.
- Do not block on low-value questions.

## Required Output Tags (every iteration)

Always include:
- `<confidence>NN</confidence>` (0-100)
- `<needs_human>true|false</needs_human>`
- `<human_question>...</human_question>` (empty if not needed)

When preparation is truly complete and build can begin:
- `<phase>PLAN_READY</phase>`
- `<promise>DONE</promise>`
