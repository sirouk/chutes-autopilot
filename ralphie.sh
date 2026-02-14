#!/usr/bin/env bash
#
# Ralphie - Unified autonomous loop for Codex and Claude Code.
# One script handles first-run setup, prompt generation, and iterative execution.
#

# Stream bootstrap:
# When executed via stdin (for example: curl ... | bash), persist the script into
# the current directory and re-exec from disk so relative paths work consistently.
if [ "${RALPHIE_LIB:-0}" != "1" ] && [ -z "${BASH_SOURCE[0]:-}" ]; then
    rb_target_script="$(pwd)/ralphie.sh"
    rb_tmp_script="${rb_target_script}.tmp.$$"
    if {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' '#'
        printf '%s\n' '# Ralphie - Unified autonomous loop for Codex and Claude Code.'
        printf '%s\n' '# Installed from stdin stream.'
        printf '%s\n' '#'
        cat
    } > "$rb_tmp_script"; then
        chmod +x "$rb_tmp_script" 2>/dev/null || true
        mv "$rb_tmp_script" "$rb_target_script"
        echo "Installed ralphie.sh to $rb_target_script"
        exec env RALPHIE_SKIP_AUTO_UPDATE=1 "$rb_target_script" "$@"
    else
        echo "Failed to persist streamed ralphie.sh to $rb_target_script" >&2
        rm -f "$rb_tmp_script"
        exit 1
    fi
fi

set -euo pipefail

SCRIPT_VERSION="1.0.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"

CONFIG_DIR="$PROJECT_DIR/.ralphie"
CONFIG_FILE="$CONFIG_DIR/config.env"
LOCK_FILE="$CONFIG_DIR/run.lock"
REASON_LOG_FILE="$CONFIG_DIR/reasons.log"
GATE_FEEDBACK_FILE="$CONFIG_DIR/last_gate_feedback.md"
STATE_FILE="$CONFIG_DIR/state.env"
DEFAULT_AUTO_UPDATE_URL="https://raw.githubusercontent.com/sirouk/ralphie/refs/heads/master/ralphie.sh"

SPECIFY_DIR="$PROJECT_DIR/.specify/memory"
CONSTITUTION_FILE="$SPECIFY_DIR/constitution.md"
SPECS_DIR="$PROJECT_DIR/specs"
RESEARCH_DIR="$PROJECT_DIR/research"
RESEARCH_SUMMARY_FILE="$RESEARCH_DIR/RESEARCH_SUMMARY.md"
CONSENSUS_DIR="$PROJECT_DIR/consensus"
LOG_DIR="$PROJECT_DIR/logs"
COMPLETION_LOG_DIR="$PROJECT_DIR/completion_log"
MAPS_DIR="$PROJECT_DIR/maps"
SUBREPOS_DIR_REL="subrepos"
AGENT_SOURCE_MAP_REL="maps/agent-source-map.yaml"
BINARY_STEERING_MAP_REL="maps/binary-steering-map.yaml"
SELF_IMPROVEMENT_LOG_REL="research/SELF_IMPROVEMENT_LOG.md"
SUBREPOS_DIR="$PROJECT_DIR/$SUBREPOS_DIR_REL"
AGENT_SOURCE_MAP_FILE="$PROJECT_DIR/$AGENT_SOURCE_MAP_REL"
BINARY_STEERING_MAP_FILE="$PROJECT_DIR/$BINARY_STEERING_MAP_REL"
SELF_IMPROVEMENT_LOG_FILE="$PROJECT_DIR/$SELF_IMPROVEMENT_LOG_REL"
READY_ARCHIVE_DIR="$CONFIG_DIR/ready-archives"
SETUP_SUBREPOS_SCRIPT="$PROJECT_DIR/scripts/setup-agent-subrepos.sh"

PROMPT_BUILD_FILE="$PROJECT_DIR/PROMPT_build.md"
PROMPT_PLAN_FILE="$PROJECT_DIR/PROMPT_plan.md"
PROMPT_PREPARE_FILE="$PROJECT_DIR/PROMPT_prepare.md"
PROMPT_TEST_FILE="$PROJECT_DIR/PROMPT_test.md"
PROMPT_REFACTOR_FILE="$PROJECT_DIR/PROMPT_refactor.md"
PROMPT_LINT_FILE="$PROJECT_DIR/PROMPT_lint.md"
PROMPT_DOCUMENT_FILE="$PROJECT_DIR/PROMPT_document.md"
PLAN_FILE="$PROJECT_DIR/IMPLEMENTATION_PLAN.md"
HUMAN_INSTRUCTIONS_REL="HUMAN_INSTRUCTIONS.md"
HUMAN_INSTRUCTIONS_FILE="$PROJECT_DIR/$HUMAN_INSTRUCTIONS_REL"

MODE="build"
MODE_EXPLICIT=false
MAX_ITERATIONS=0
ENGINE_OVERRIDE=""
FORCE_SETUP=false
SETUP_AND_RUN=false
SHOW_STATUS=false
NON_INTERACTIVE=false
BACKOFF_ENABLED=true
CONTEXT_FILE=""
PROMPT_OVERRIDE=""
REFRESH_PROMPTS=false
YOLO_OVERRIDE=""
DOCTOR_MODE=false
READY_MODE=false
READY_AND_RUN=false
CLEAN_MODE=false
CLEAN_DEEP_MODE=false
HUMAN_MODE=false
COMMAND_TIMEOUT_SECONDS="${COMMAND_TIMEOUT_SECONDS:-0}"
LOCK_WAIT_SECONDS="${LOCK_WAIT_SECONDS:-30}"
AUTO_CONTINUE_BUILD=false
FORCE_BUILD=false
BUILD_APPROVAL_POLICY="${BUILD_APPROVAL_POLICY:-upfront}"
CODEX_MODEL="${CODEX_MODEL:-}"
CLAUDE_MODEL="${CLAUDE_MODEL:-}"
AUTO_UPDATE_ENABLED="${AUTO_UPDATE_ENABLED:-true}"
AUTO_UPDATE_URL="${AUTO_UPDATE_URL:-$DEFAULT_AUTO_UPDATE_URL}"
AUTO_UPDATE_OVERRIDE=""
AUTO_UPDATE_URL_OVERRIDE=""
SKIP_BOOTSTRAP_NODE_TOOLCHAIN="${SKIP_BOOTSTRAP_NODE_TOOLCHAIN:-false}"
SKIP_BOOTSTRAP_CHUTES_CLAUDE="${SKIP_BOOTSTRAP_CHUTES_CLAUDE:-false}"
SKIP_BOOTSTRAP_CHUTES_CODEX="${SKIP_BOOTSTRAP_CHUTES_CODEX:-false}"
HUMAN_NOTIFY_CHANNEL="${HUMAN_NOTIFY_CHANNEL:-terminal}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
AUTO_PREPARE_BACKFILL_ON_IDLE_BUILD="${AUTO_PREPARE_BACKFILL_ON_IDLE_BUILD:-true}"
INTERRUPT_MENU_ENABLED="${INTERRUPT_MENU_ENABLED:-true}"
SWARM_ENABLED=true
SWARM_SIZE="${SWARM_SIZE:-3}"
SWARM_MAX_PARALLEL="${SWARM_MAX_PARALLEL:-2}"
# If a reviewer doesn't follow the required <score>/<verdict> tag format, retry them.
# This avoids silently treating malformed output as score=0.
SWARM_RETRY_INVALID_OUTPUT="${SWARM_RETRY_INVALID_OUTPUT:-1}"
MIN_CONSENSUS_SCORE="${MIN_CONSENSUS_SCORE:-80}"
CONSENSUS_MAX_REVIEWER_FAILURES="${CONSENSUS_MAX_REVIEWER_FAILURES:-0}"
CONFIDENCE_TARGET="${CONFIDENCE_TARGET:-85}"
CONFIDENCE_STAGNATION_LIMIT="${CONFIDENCE_STAGNATION_LIMIT:-3}"

NORMAL_WAIT=2
BACKOFF_LEVEL=0
BACKOFF_TIMES=(60 300 600 1200 3600)
MAX_CONSECUTIVE_FAILURES=3

ACTIVE_ENGINE=""
ACTIVE_CMD=""
SESSION_LOG=""
SESSION_LOG_FIFO=""
SESSION_LOG_TEE_PID=""
RUN_START_EPOCH="$(date +%s)"

INCOMPLETE_SPECS=()
HAS_PLAN_TASKS=false
HAS_GITHUB_ISSUES=false
HAS_HUMAN_REQUESTS=false
LAST_CONSENSUS_SCORE=0
LAST_CONSENSUS_PASS=false

LOCK_BACKEND=""
LOCK_BACKEND_LOGGED=false
LAST_CONSENSUS_GO_COUNT=0
LAST_CONSENSUS_HOLD_COUNT=0
LAST_CONSENSUS_REPORT=""
LAST_CONSENSUS_PANEL_FAILURES=0
LAST_DEEP_CLEANUP_BACKUP=""

LAST_REASON_CODE=""
LAST_REASON_MESSAGE=""
LAST_COMPLETION_SIGNAL=""

CAPABILITY_PROBED=false
CODEX_CAP_OUTPUT_LAST_MESSAGE=true
CODEX_CAP_YOLO_FLAG=true
CLAUDE_CAP_PRINT=true
CLAUDE_CAP_YOLO_FLAG="--dangerously-skip-permissions"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

print_help() {
    cat <<'EOF'
Ralphie - Unified autonomous code loop (Codex + Claude Code)

Usage:
  ./ralphie.sh                   # Default pipeline: prepare -> build -> test -> refactor -> test -> lint -> document
  ./ralphie.sh 20                # Build mode, max 20 iterations
  ./ralphie.sh plan              # Planning mode (default max=1)
  ./ralphie.sh prepare           # Deep prepare mode (research+spec+plan)
  ./ralphie.sh test              # Test-focused mode
  ./ralphie.sh refactor          # Refactor/simplify mode
  ./ralphie.sh lint              # Lint/format/static-check mode
  ./ralphie.sh document          # Documentation finalization mode
  ./ralphie.sh --setup           # Re-run first-time setup wizard
  ./ralphie.sh --setup-and-run   # Setup, then continue into selected mode
  ./ralphie.sh --ready           # Establish clean ready position and exit
  ./ralphie.sh --clean           # Clean runtime recursion artifacts and exit
  ./ralphie.sh --clean-deep      # Deep clean generated self-improvement artifacts (with backup)
  ./ralphie.sh --human           # Capture human priorities into HUMAN_INSTRUCTIONS.md
  ./ralphie.sh --status          # Show current configuration

Options:
  --engine codex|claude|auto|ask     Override configured engine
  --codex-model MODEL                Default codex model passed to agent invocations
  --claude-model MODEL               Default claude model passed to agent invocations
  --mode build|plan|prepare|test|refactor|lint|document
                                     Explicit mode
  --max N                            Max iterations (0 = unlimited)
  --context-file FILE                Add large external context file guidance
  --prompt FILE                      Use a custom prompt file
  --refresh-prompts                  Regenerate PROMPT_*.md files
  --ready                            Refresh maps/prompts, archive runtime artifacts, and reset loop state
  --ready-and-run                    Run --ready first, then continue into selected mode
  --clean                            Remove runtime recursion artifacts and leave durable repo files untouched
  --clean-deep                       Deep clean generated specs/research/maps/subrepos/prompts (backup tarball preserved)
  --human                            Interactive capture of one-by-one human priorities into HUMAN_INSTRUCTIONS.md
  --timeout SECONDS                  Kill an agent run after this many seconds (0=off)
  --wait-for-lock SECONDS            Wait for active run lock before failing (0=off)
  --auto-continue-build              In prepare mode, auto-enter build when approved
  --build-approval MODE              Build approval policy: upfront|on_ready
  --notify CHANNEL                   Human notification channel: none|terminal|telegram|discord
  --force-build                      Bypass strict build readiness gate
  --no-auto-prepare-backfill        Keep build mode idle behavior (do not auto-switch to prepare when queue is empty)
  --no-interrupt-menu               On Ctrl+C, exit immediately (disable resume/human-instruction submenu)
  --swarm-size N                     Number of panel reviewers for consensus
  --swarm-max-parallel N             Max concurrent panel reviewers
  --swarm-retry-invalid N            Retry malformed reviewer output N times (default: 1; 0 disables)
  --min-consensus N                  Minimum consensus score (0-100)
  --max-reviewer-failures N          Maximum failed reviewer runs allowed in consensus
  --no-swarm                         Disable panel/swarm consensus reviews
  --doctor                           Print readiness diagnostics and exit
  --yolo                             Force YOLO mode on
  --no-yolo                          Force YOLO mode off
  --auto-update                      Enable auto-update of ralphie.sh for this run
  --no-auto-update                   Disable auto-update of ralphie.sh for this run
  --update-url URL                   Override auto-update URL for this run
  --no-backoff                       Disable idle exponential backoff
  --non-interactive                  Use defaults when setup is required
  --help, -h                         Show help

Environment:
  CODEX_CMD     Codex command (default: codex)
  CLAUDE_CMD    Claude command (default: claude)
  CODEX_MODEL   Default codex model name (optional)
  CLAUDE_MODEL  Default claude model name (optional)
  COMMAND_TIMEOUT_SECONDS  Default timeout for one agent invocation
  LOCK_WAIT_SECONDS  Wait for active run lock before failing (default: 30)
  CONSENSUS_MAX_REVIEWER_FAILURES  Max failed reviewers allowed before consensus invalidates
  BUILD_APPROVAL_POLICY    upfront|on_ready (default: upfront)
  HUMAN_NOTIFY_CHANNEL     none|terminal|telegram|discord (default: terminal)
  AUTO_PREPARE_BACKFILL_ON_IDLE_BUILD   true|false (default: true)
  INTERRUPT_MENU_ENABLED   true|false (default: true)
  AUTO_UPDATE_ENABLED      true|false (default: true)
  AUTO_UPDATE_URL          Auto-update URL (default: upstream ralphie.sh raw github URL)
  RALPHIE_SKIP_AUTO_UPDATE true|false (default: false) internal guard to prevent update loops
  TELEGRAM_BOT_TOKEN       Telegram bot token for notify channel=telegram
  TELEGRAM_CHAT_ID         Telegram chat id for notify channel=telegram
  DISCORD_WEBHOOK_URL      Discord webhook URL for notify channel=discord
EOF
}

info() { echo -e "${BLUE}$*${NC}"; }
ok() { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}$*${NC}"; }
err() { echo -e "${RED}$*${NC}"; }

log_reason_code() {
    local code="$1"
    local message="${2:-}"
    local ts line
    ts="$(date '+%Y-%m-%d %H:%M:%S')"

    # Avoid leaking local identity/absolute paths into logs when possible.
    # Best-effort: redact project dir + home dir prefixes inside messages.
    if [ -n "$message" ]; then
        message="${message//$PROJECT_DIR/.}"
        message="${message//$HOME/~}"
    fi

    LAST_REASON_CODE="$code"
    LAST_REASON_MESSAGE="$message"

    if [ -n "$message" ]; then
        line="$(printf 'reason_code=%s message="%s"' "$code" "$message")"
    else
        line="$(printf 'reason_code=%s' "$code")"
    fi

    # Keep stdout behavior stable: reason codes are part of the observable contract.
    printf '%s\n' "$line"

    # Best-effort persistence for postmortem + prompt feedback loops.
    mkdir -p "$CONFIG_DIR" 2>/dev/null || true
    printf '[%s] mode=%s %s\n' "$ts" "${MODE:-unknown}" "$line" >>"$REASON_LOG_FILE" 2>/dev/null || true
}

to_lower() {
    # Lowercase and strip whitespace so config/env parsing is robust (e.g. $'\\ntrue').
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'
}

write_gate_feedback() {
    local stage="$1"
    shift

    mkdir -p "$CONFIG_DIR" 2>/dev/null || true

    local tmp_file
    tmp_file="${GATE_FEEDBACK_FILE}.tmp.$$"
    {
        echo "# Ralphie Gate Feedback"
        echo ""
        echo "- Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "- Mode: ${MODE:-unknown}"
        echo "- Stage: $stage"
        echo ""
        echo "## Blockers"
        if [ "$#" -gt 0 ]; then
            local entry
            for entry in "$@"; do
                echo "- $entry"
            done
        else
            echo "- (none captured)"
        fi
        echo ""
        echo "## Notes"
        echo "- This file is written by the orchestrator (not the agent)."
        echo "- Treat this as the source-of-truth for why a gate failed."
        echo "- Clear blockers before emitting \`<promise>DONE</promise>\` again."
    } >"$tmp_file" 2>/dev/null || {
        rm -f "$tmp_file" 2>/dev/null || true
        return 0
    }

    mv "$tmp_file" "$GATE_FEEDBACK_FILE" 2>/dev/null || rm -f "$tmp_file" 2>/dev/null || true
}

readiness_rubric_for_prompt() {
    # Keep this aligned with check_build_prerequisites() and plan_is_semantically_actionable().
    cat <<'EOF'
## Ralphie Readiness Rubric (Machine-Checked)

Do not emit `<promise>DONE</promise>` in plan/prepare unless these are true:

- `IMPLEMENTATION_PLAN.md` exists and is actionable:
  - Includes a goal/scope/objective signal.
  - Includes done criteria (validation/verification/definition-of-done/acceptance-criteria/readiness).
  - Includes actionable tasks (checkboxes preferred).
- `specs/` contains specs, and at least one spec file includes an "Acceptance Criteria" section.
- `research/RESEARCH_SUMMARY.md` exists and includes a `<confidence>NN</confidence>` tag.
- `research/CODEBASE_MAP.md`, `research/DEPENDENCY_RESEARCH.md`, and `research/COVERAGE_MATRIX.md` exist.
- Markdown artifacts contain no tool transcript leakage and no local identity/path leakage.
- `.gitignore` includes guardrails for local/sensitive/runtime artifacts (e.g. `.env*`, `logs/`, `consensus/`, `.ralphie/`).
EOF
}

is_number() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

is_true() {
    case "$(to_lower "${1:-}")" in
        true|1|yes|y|on) return 0 ;;
        *) return 1 ;;
    esac
}

is_valid_build_approval_policy() {
    case "$(to_lower "${1:-}")" in
        upfront|on_ready) return 0 ;;
        *) return 1 ;;
    esac
}

is_valid_notify_channel() {
    case "$(to_lower "${1:-}")" in
        none|terminal|telegram|discord) return 0 ;;
        *) return 1 ;;
    esac
}

is_interactive() {
    if is_true "$NON_INTERACTIVE"; then
        return 1
    fi
    if [ -t 0 ]; then
        return 0
    fi
    if [ -r /dev/tty ] && [ -w /dev/tty ]; then
        return 0
    fi
    return 1
}

path_for_display() {
    local path="$1"
    if [ -z "$path" ]; then
        echo ""
        return 0
    fi

    case "$path" in
        "$PROJECT_DIR")
            echo "."
            ;;
        "$PROJECT_DIR"/*)
            printf './%s\n' "${path#"$PROJECT_DIR"/}"
            ;;
        "$HOME")
            echo "~"
            ;;
        "$HOME"/*)
            printf '~/%s\n' "${path#"$HOME"/}"
            ;;
        *)
            echo "$path"
            ;;
    esac
}

write_state_snapshot() {
    local stage="${1:-}"
    local ts tmp_file

    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    tmp_file="${STATE_FILE}.tmp.$$"

    mkdir -p "$CONFIG_DIR" 2>/dev/null || true

    {
        echo "timestamp=$ts"
        echo "pid=$$"
        [ -n "$stage" ] && echo "stage=$stage"
        echo "mode=${MODE:-}"
        echo "engine=${ACTIVE_ENGINE:-}"
        echo "iteration=${iteration:-0}"
        [ -n "${prompt_file:-}" ] && echo "prompt_file=$(path_for_display "$prompt_file")"
        [ -n "${effective_prompt:-}" ] && echo "effective_prompt=$(path_for_display "$effective_prompt")"
        [ -n "${log_file:-}" ] && echo "iteration_log=$(path_for_display "$log_file")"
        [ -n "${output_file:-}" ] && echo "iteration_output=$(path_for_display "$output_file")"
        [ -n "${SESSION_LOG:-}" ] && echo "session_log=$(path_for_display "$SESSION_LOG")"
        [ -n "${LAST_COMPLETION_SIGNAL:-}" ] && echo "last_completion_signal=$LAST_COMPLETION_SIGNAL"
        [ -n "${LAST_REASON_CODE:-}" ] && echo "last_reason_code=$LAST_REASON_CODE"
        if [ -n "${LAST_REASON_MESSAGE:-}" ]; then
            echo "last_reason_message=$(printf '%s' "$LAST_REASON_MESSAGE" | tr '\n' ' ')"
        fi
        echo "consensus_score=${LAST_CONSENSUS_SCORE:-0}"
        echo "consensus_pass=${LAST_CONSENSUS_PASS:-false}"
        if [ -f "$GATE_FEEDBACK_FILE" ]; then
            echo "gate_feedback_present=true"
        else
            echo "gate_feedback_present=false"
        fi
    } >"$tmp_file" 2>/dev/null || {
        rm -f "$tmp_file" 2>/dev/null || true
        return 0
    }

    mv "$tmp_file" "$STATE_FILE" 2>/dev/null || rm -f "$tmp_file" 2>/dev/null || true
    return 0
}

read_state_value() {
    local key="$1"
    if [ -z "$key" ] || [ ! -f "$STATE_FILE" ]; then
        echo ""
        return 0
    fi
    sed -n "s/^${key}=//p" "$STATE_FILE" 2>/dev/null | tail -1 || true
}

require_arg_value() {
    local flag="$1"
    local value="${2:-}"
    if [ -z "$value" ] || [[ "$value" == --* ]]; then
        err "$flag requires a value."
        exit 1
    fi
}

duration_since_start() {
    local now elapsed
    now="$(date +%s)"
    elapsed=$((now - RUN_START_EPOCH))
    format_duration "$elapsed"
}

ensure_layout() {
    mkdir -p "$CONFIG_DIR" "$SPECIFY_DIR" "$SPECS_DIR" "$RESEARCH_DIR" "$CONSENSUS_DIR" "$LOG_DIR" "$COMPLETION_LOG_DIR" "$MAPS_DIR"
}

ensure_lock_dir() {
    mkdir -p "$CONFIG_DIR"
}

read_lock_timestamp() {
    if [ ! -f "$LOCK_FILE" ]; then
        echo ""
        return 0
    fi
    sed -n '2p' "$LOCK_FILE" 2>/dev/null || true
}

lock_timestamp_to_epoch() {
    local timestamp="$1"
    local epoch

    if [ -z "$timestamp" ]; then
        echo ""
        return 0
    fi

    if epoch="$(date -d "$timestamp" +%s 2>/dev/null)"; then
        echo "$epoch"
        return 0
    fi

    if epoch="$(date -j -f '%Y-%m-%d %H:%M:%S' "$timestamp" +%s 2>/dev/null)"; then
        echo "$epoch"
        return 0
    fi

    echo ""
    return 0
}

lock_holder_command() {
    local pid="$1"
    local holder_cmd=""

    if [ -z "$pid" ] || ! command -v ps >/dev/null 2>&1; then
        echo ""
        return 0
    fi

    holder_cmd="$(ps -p "$pid" -o command= 2>/dev/null | sed -E 's/^[[:space:]]+//' | head -1 || true)"
    if [ -z "$holder_cmd" ]; then
        holder_cmd="$(ps -p "$pid" -o args= 2>/dev/null | sed -E 's/^[[:space:]]+//' | head -1 || true)"
    fi

    echo "$holder_cmd"
}

emit_lock_diagnostics() {
    local holder_pid="$1"
    local holder_cmd lock_timestamp lock_epoch now age_seconds

    holder_cmd="$(lock_holder_command "$holder_pid")"
    if [ -n "$holder_cmd" ]; then
        warn "Lock holder command: $holder_cmd"
    else
        warn "Lock holder command: unavailable"
    fi

    lock_timestamp="$(read_lock_timestamp)"
    if [ -z "$lock_timestamp" ]; then
        warn "Lock age: unavailable"
        return 0
    fi

    lock_epoch="$(lock_timestamp_to_epoch "$lock_timestamp")"
    if ! is_number "$lock_epoch"; then
        warn "Lock age: unavailable (timestamp parse failed: $lock_timestamp)"
        return 0
    fi

    now="$(date +%s)"
    if ! is_number "$now"; then
        warn "Lock age: unavailable"
        return 0
    fi

    age_seconds=$((now - lock_epoch))
    if [ "$age_seconds" -lt 0 ]; then
        age_seconds=0
    fi

    warn "Lock age: ${age_seconds}s (started: $lock_timestamp)"
    return 0
}

effective_lock_wait_seconds() {
    local wait_seconds="${LOCK_WAIT_SECONDS:-0}"
    local timeout_seconds="${COMMAND_TIMEOUT_SECONDS:-0}"

    if ! is_number "$wait_seconds"; then
        wait_seconds=0
    fi
    if ! is_number "$timeout_seconds"; then
        timeout_seconds=0
    fi

    # If lock waiting is enabled and agent timeout is configured, keep wait
    # slightly above timeout so queued runs do not fail prematurely.
    if [ "$wait_seconds" -gt 0 ] && [ "$timeout_seconds" -gt 0 ]; then
        local min_wait
        min_wait=$((timeout_seconds + NORMAL_WAIT + 5))
        if [ "$wait_seconds" -lt "$min_wait" ]; then
            wait_seconds="$min_wait"
        fi
    fi

    echo "$wait_seconds"
}

log_lock_backend_once() {
    if is_true "${LOCK_BACKEND_LOGGED:-false}"; then
        return 0
    fi
    LOCK_BACKEND_LOGGED=true
    if [ -n "${LOCK_BACKEND:-}" ]; then
        info "Lock backend: $LOCK_BACKEND"
    fi
    return 0
}

is_pid_alive() {
    local pid="$1"

    if [ -z "$pid" ] || ! is_number "$pid"; then
        return 1
    fi

    if kill -0 "$pid" 2>/dev/null; then
        return 0
    fi

    # `kill -0` can fail with EPERM even when the process exists. Best-effort ps fallback.
    if command -v ps >/dev/null 2>&1; then
        if ps -p "$pid" -o pid= 2>/dev/null | grep -q '[0-9]'; then
            return 0
        fi
    fi

    return 1
}

write_lock_metadata() {
    local pid="$1"
    local lock_path="${2:-$LOCK_FILE}"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    {
        echo "$pid"
        echo "$ts"
    } > "$lock_path"
}

current_lock_pid() {
    # In bash, $$ remains the parent shell PID across subshells, but BASHPID is per-process.
    # We use BASHPID when available so subshells don't accidentally treat locks as re-entrant.
    case "${BASHPID:-}" in
        ''|*[!0-9]*) echo "$$" ;;
        *) echo "$BASHPID" ;;
    esac
}

try_acquire_lock_via_link() {
    if ! command -v ln >/dev/null 2>&1; then
        return 2
    fi

    local tmp_lock
    tmp_lock="$(mktemp "${LOCK_FILE}.tmp.XXXXXX" 2>/dev/null || echo "")"
    if [ -z "$tmp_lock" ]; then
        return 2
    fi

    if ! write_lock_metadata "$(current_lock_pid)" "$tmp_lock" 2>/dev/null; then
        rm -f "$tmp_lock" 2>/dev/null || true
        return 2
    fi

    if ln "$tmp_lock" "$LOCK_FILE" 2>/dev/null; then
        rm -f "$tmp_lock" 2>/dev/null || true
        return 0
    fi

    rm -f "$tmp_lock" 2>/dev/null || true
    if [ -e "$LOCK_FILE" ]; then
        return 1
    fi
    return 2
}

try_acquire_lock_via_noclobber() {
    if (set -C; write_lock_metadata "$(current_lock_pid)") 2>/dev/null; then
        return 0
    fi

    if [ -e "$LOCK_FILE" ]; then
        return 1
    fi

    return 2
}

try_acquire_lock_atomic() {
    local backend="${LOCK_BACKEND:-link}"
    local rc

    if [ "$backend" = "link" ]; then
        if try_acquire_lock_via_link; then
            LOCK_BACKEND="link"
            log_lock_backend_once
            return 0
        else
            rc=$?
            if [ "$rc" -eq 1 ]; then
                LOCK_BACKEND="link"
                log_lock_backend_once
                return 1
            fi

            # Backend failure: fall back to noclobber and continue.
            LOCK_BACKEND="noclobber"
            backend="noclobber"
        fi
    fi

    if [ "$backend" = "noclobber" ]; then
        if try_acquire_lock_via_noclobber; then
            LOCK_BACKEND="noclobber"
            log_lock_backend_once
            return 0
        else
            rc=$?
            LOCK_BACKEND="noclobber"
            log_lock_backend_once
            return "$rc"
        fi
    fi

    return 2
}

release_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local holder_pid
        holder_pid=$(sed -n '1p' "$LOCK_FILE" 2>/dev/null || true)
        if [ -n "$holder_pid" ] && [ "$holder_pid" = "$(current_lock_pid)" ]; then
            rm -f "$LOCK_FILE"
        fi
    fi
}

acquire_lock() {
    ensure_lock_dir
    local configured_wait effective_wait
    configured_wait="${LOCK_WAIT_SECONDS:-0}"
    effective_wait="$(effective_lock_wait_seconds)"
    local wait_seconds="$effective_wait"
    local display_lock_file
    display_lock_file="$(path_for_display "$LOCK_FILE")"

    if [ "$configured_wait" != "$wait_seconds" ]; then
        info "Adjusted lock wait to ${wait_seconds}s to cover configured timeout (${COMMAND_TIMEOUT_SECONDS}s)."
    fi

    local existing_pid=""
    if [ -f "$LOCK_FILE" ]; then
        existing_pid="$(sed -n '1p' "$LOCK_FILE" 2>/dev/null || true)"
        # Allow re-entrant acquisition when this process execs into a refreshed script.
        if [ -n "$existing_pid" ] && [ "$existing_pid" = "$(current_lock_pid)" ]; then
            write_lock_metadata "$(current_lock_pid)" 2>/dev/null || true
            return 0
        fi
    fi

    local wait_begin=""
    local warned_wait=false

    while true; do
        if try_acquire_lock_atomic; then
            return 0
        fi

        local rc=$?
        if [ "$rc" -eq 2 ]; then
            err "Failed to acquire lock due to an internal error: $display_lock_file"
            log_reason_code "RB_LOCK_ACQUIRE_ERROR" "lock=$display_lock_file"
            exit 1
        fi

        existing_pid="$(sed -n '1p' "$LOCK_FILE" 2>/dev/null || true)"
        if [ -n "$existing_pid" ] && [ "$existing_pid" = "$(current_lock_pid)" ]; then
            write_lock_metadata "$(current_lock_pid)" 2>/dev/null || true
            return 0
        fi

        if [ -n "$existing_pid" ] && is_pid_alive "$existing_pid"; then
            if [ "$wait_seconds" -gt 0 ]; then
                if ! is_true "$warned_wait"; then
                    warn "Another ralphie process is running (pid $existing_pid). Waiting up to ${wait_seconds}s for lock release..."
                    warned_wait=true
                fi
                if [ -z "$wait_begin" ]; then
                    wait_begin="$(date +%s)"
                fi
                local now elapsed
                now="$(date +%s)"
                elapsed=$((now - wait_begin))
                if [ "$elapsed" -ge "$wait_seconds" ]; then
                    emit_lock_diagnostics "$existing_pid"
                    err "Another ralphie process is running (pid $existing_pid)."
                    err "Timed out waiting ${wait_seconds}s for lock release: $display_lock_file"
                    log_reason_code "RB_LOCK_WAIT_TIMEOUT" "pid=$existing_pid waited=${wait_seconds}s lock=$display_lock_file"
                    exit 1
                fi
                sleep 1
                continue
            fi

            emit_lock_diagnostics "$existing_pid"
            err "Another ralphie process is running (pid $existing_pid)."
            err "Stop that process or remove stale lock: $display_lock_file"
            log_reason_code "RB_LOCK_ALREADY_HELD" "pid=$existing_pid wait=0 lock=$display_lock_file"
            exit 1
        fi

        if [ -n "$existing_pid" ] && is_number "$existing_pid" && ! is_pid_alive "$existing_pid"; then
            warn "Removing stale lock file: $display_lock_file"
            rm -f "$LOCK_FILE" 2>/dev/null || true
            continue
        fi

        # PID is missing/unparseable; treat as held to preserve atomicity.
        if [ "$wait_seconds" -gt 0 ]; then
            if ! is_true "$warned_wait"; then
                warn "Another ralphie process is running (pid unavailable). Waiting up to ${wait_seconds}s for lock release..."
                warned_wait=true
            fi
            if [ -z "$wait_begin" ]; then
                wait_begin="$(date +%s)"
            fi
            local now elapsed
            now="$(date +%s)"
            elapsed=$((now - wait_begin))
            if [ "$elapsed" -ge "$wait_seconds" ]; then
                emit_lock_diagnostics "$existing_pid"
                err "Another ralphie process is running (pid unavailable)."
                err "Timed out waiting ${wait_seconds}s for lock release: $display_lock_file"
                log_reason_code "RB_LOCK_WAIT_TIMEOUT" "pid=${existing_pid:-unknown} waited=${wait_seconds}s lock=$display_lock_file"
                exit 1
            fi
            sleep 1
            continue
        fi

        emit_lock_diagnostics "$existing_pid"
        err "Another ralphie process is running (pid unavailable)."
        err "Stop that process or remove stale lock: $display_lock_file"
        log_reason_code "RB_LOCK_ALREADY_HELD" "pid=${existing_pid:-unknown} wait=0 lock=$display_lock_file"
        exit 1
    done
}

start_session_logging() {
    local log_file="$1"

    if [ -z "$log_file" ]; then
        return 1
    fi
    if ! command -v mkfifo >/dev/null 2>&1; then
        warn "mkfifo not found; session logging disabled."
        return 1
    fi
    if ! command -v tee >/dev/null 2>&1; then
        warn "tee not found; session logging disabled."
        return 1
    fi

    SESSION_LOG_FIFO="$LOG_DIR/ralphie_session_${MODE}_$$.fifo"
    rm -f "$SESSION_LOG_FIFO" 2>/dev/null || true
    if ! mkfifo "$SESSION_LOG_FIFO" 2>/dev/null; then
        warn "Failed to create session log FIFO. Session logging disabled."
        SESSION_LOG_FIFO=""
        return 1
    fi

    # Preserve original stdout/stderr so the background tee can keep printing to the terminal.
    exec 3>&1 4>&2

    tee -a "$log_file" < "$SESSION_LOG_FIFO" >&3 &
    SESSION_LOG_TEE_PID=$!

    # Redirect orchestrator output into the FIFO. The tee process copies it to both terminal and log file.
    exec > "$SESSION_LOG_FIFO" 2>&1
    return 0
}

cleanup_session_logging() {
    if [ -z "${SESSION_LOG_FIFO:-}" ]; then
        return 0
    fi

    # Close the FIFO writer by restoring stdout/stderr, then give tee a moment to flush.
    exec 1>&3 2>&4 || true
    exec 3>&- 4>&- || true

    if [ -n "${SESSION_LOG_TEE_PID:-}" ]; then
        local i
        for i in 1 2 3 4 5; do
            if ! kill -0 "$SESSION_LOG_TEE_PID" 2>/dev/null; then
                break
            fi
            sleep 0.1
        done
        kill "$SESSION_LOG_TEE_PID" 2>/dev/null || true
        wait "$SESSION_LOG_TEE_PID" 2>/dev/null || true
    fi

    rm -f "$SESSION_LOG_FIFO" 2>/dev/null || true
    SESSION_LOG_FIFO=""
    SESSION_LOG_TEE_PID=""
    return 0
}

cleanup_exit() {
    cleanup_session_logging || true
    release_lock || true
    return 0
}

archive_and_reset_runtime_artifacts() {
    ensure_layout

    local has_runtime="false"
    local dir
    for dir in "$LOG_DIR" "$CONSENSUS_DIR" "$COMPLETION_LOG_DIR"; do
        if find "$dir" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
            has_runtime="true"
            break
        fi
    done

    if is_true "$has_runtime"; then
        local ts archive_file
        ts="$(date '+%Y%m%d_%H%M%S')"
        mkdir -p "$READY_ARCHIVE_DIR"
        archive_file="$READY_ARCHIVE_DIR/runtime_${ts}.tar.gz"

        if command -v tar >/dev/null 2>&1; then
            if tar -czf "$archive_file" -C "$PROJECT_DIR" logs consensus completion_log >/dev/null 2>&1; then
                info "Archived runtime artifacts: $archive_file"
            else
                warn "Failed to archive runtime artifacts. Proceeding with reset."
            fi
        else
            warn "tar not found; skipping runtime artifact archive."
        fi
    fi

    find "$LOG_DIR" "$CONSENSUS_DIR" "$COMPLETION_LOG_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    rm -f "$LOCK_FILE"
}

clean_recursive_artifacts() {
    ensure_layout

    info "Cleaning recursive-development runtime artifacts."

    find "$LOG_DIR" "$CONSENSUS_DIR" "$COMPLETION_LOG_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    rm -f "$LOCK_FILE"
    rm -f "$REASON_LOG_FILE" "$GATE_FEEDBACK_FILE" "$STATE_FILE" 2>/dev/null || true

    ok "Cleanup complete."
    info "Kept durable repo artifacts (specs, research, maps, prompts, subrepos, config, backups)."
}

create_deep_cleanup_backup() {
    ensure_layout
    LAST_DEEP_CLEANUP_BACKUP=""

    local targets=()
    [ -d "$MAPS_DIR" ] && targets+=("maps")
    [ -d "$SUBREPOS_DIR" ] && targets+=("subrepos")
    [ -d "$RESEARCH_DIR" ] && targets+=("research")
    [ -d "$SPECS_DIR" ] && targets+=("specs")
    [ -f "$PROMPT_BUILD_FILE" ] && targets+=("PROMPT_build.md")
    [ -f "$PROMPT_PLAN_FILE" ] && targets+=("PROMPT_plan.md")
    [ -f "$PROMPT_PREPARE_FILE" ] && targets+=("PROMPT_prepare.md")
    [ -f "$PROMPT_TEST_FILE" ] && targets+=("PROMPT_test.md")
    [ -f "$PROMPT_REFACTOR_FILE" ] && targets+=("PROMPT_refactor.md")
    [ -f "$PROMPT_LINT_FILE" ] && targets+=("PROMPT_lint.md")
    [ -f "$PROMPT_DOCUMENT_FILE" ] && targets+=("PROMPT_document.md")

    if [ "${#targets[@]}" -eq 0 ]; then
        return 0
    fi

    if ! command -v tar >/dev/null 2>&1; then
        warn "tar not found; deep cleanup backup archive cannot be created."
        return 0
    fi

    local ts archive_file
    ts="$(date '+%Y%m%d_%H%M%S')"
    mkdir -p "$READY_ARCHIVE_DIR"
    archive_file="$READY_ARCHIVE_DIR/deep_cleanup_${ts}.tar.gz"

    if tar -czf "$archive_file" -C "$PROJECT_DIR" "${targets[@]}" >/dev/null 2>&1; then
        LAST_DEEP_CLEANUP_BACKUP="$archive_file"
        info "Deep cleanup backup created: $archive_file"
        return 0
    fi

    warn "Deep cleanup backup failed; proceeding without new archive."
    return 0
}

clean_deep_artifacts() {
    ensure_layout

    info "Running deep cleanup of generated self-improvement artifacts."
    create_deep_cleanup_backup

    find "$LOG_DIR" "$CONSENSUS_DIR" "$COMPLETION_LOG_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    find "$MAPS_DIR" "$SUBREPOS_DIR" "$RESEARCH_DIR" "$SPECS_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    rm -f "$PROMPT_BUILD_FILE" "$PROMPT_PLAN_FILE" "$PROMPT_PREPARE_FILE" "$PROMPT_TEST_FILE" "$PROMPT_REFACTOR_FILE" "$PROMPT_LINT_FILE" "$PROMPT_DOCUMENT_FILE"
    rm -f "$CONFIG_DIR/PROMPT_prepare_once.md"
    rm -f "$LOCK_FILE"
    rm -f "$REASON_LOG_FILE" "$GATE_FEEDBACK_FILE" "$STATE_FILE" 2>/dev/null || true

    ok "Deep cleanup complete."
    if [ -n "$LAST_DEEP_CLEANUP_BACKUP" ] && [ -f "$LAST_DEEP_CLEANUP_BACKUP" ]; then
        info "Backup preserved: $LAST_DEEP_CLEANUP_BACKUP"
    else
        info "Backup directory preserved: $READY_ARCHIVE_DIR"
    fi
}

refresh_subrepos_and_maps() {
    if [ ! -f "$SETUP_SUBREPOS_SCRIPT" ]; then
        warn "Subrepo setup script not found: $SETUP_SUBREPOS_SCRIPT"
        return 1
    fi

    if bash "$SETUP_SUBREPOS_SCRIPT"; then
        return 0
    fi

    warn "Subrepo/map refresh failed. Continuing with existing artifacts."
    return 1
}

ready_position() {
    ensure_layout

    info "Preparing ready position for self-improvement."
    refresh_subrepos_and_maps || true
    local previous_refresh_prompts="$REFRESH_PROMPTS"
    REFRESH_PROMPTS=true
    write_prompt_files
    REFRESH_PROMPTS="$previous_refresh_prompts"
    create_bootstrap_spec_if_needed
    create_self_improvement_spec_if_needed
    archive_and_reset_runtime_artifacts

    append_self_improvement_log \
        "Ready position established" \
        "- Source map: $AGENT_SOURCE_MAP_REL\n- Binary steering map: $BINARY_STEERING_MAP_REL\n- Runtime artifacts: archived + reset\n- Prompts: refreshed\n- Specs: self-improvement seed ensured"

    ok "Ready position complete."
}

detect_project_type() {
    local file_count
    file_count=$(find "$PROJECT_DIR" -mindepth 1 -maxdepth 2 -type f \
        ! -path "*/.git/*" \
        ! -path "*/node_modules/*" \
        ! -path "*/.ralphie/*" \
        ! -path "*/logs/*" \
        2>/dev/null | wc -l | tr -d ' ')

    if [ "${file_count:-0}" -gt 8 ]; then
        echo "existing"
    else
        echo "new"
    fi
}

normalize_project_type() {
    local raw="$1"
    case "$(to_lower "$raw")" in
        new) echo "new" ;;
        existing) echo "existing" ;;
        *) echo "$2" ;;
    esac
}

detect_stack_summary() {
    local stacks=()

    [ -f "$PROJECT_DIR/package.json" ] && stacks+=("Node.js/JavaScript")
    [ -f "$PROJECT_DIR/tsconfig.json" ] && stacks+=("TypeScript")
    [ -f "$PROJECT_DIR/pyproject.toml" ] && stacks+=("Python")
    [ -f "$PROJECT_DIR/requirements.txt" ] && stacks+=("Python")
    [ -f "$PROJECT_DIR/go.mod" ] && stacks+=("Go")
    [ -f "$PROJECT_DIR/Cargo.toml" ] && stacks+=("Rust")
    [ -f "$PROJECT_DIR/Gemfile" ] && stacks+=("Ruby")
    [ -f "$PROJECT_DIR/pom.xml" ] && stacks+=("Java")
    [ -f "$PROJECT_DIR/build.gradle" ] && stacks+=("Java/Kotlin")

    if find "$PROJECT_DIR" -maxdepth 2 \( -name "*.csproj" -o -name "*.sln" \) | grep -q . 2>/dev/null; then
        stacks+=(".NET/C#")
    fi

    if [ "${#stacks[@]}" -eq 0 ]; then
        echo "Not yet detected"
        return
    fi

    local out=""
    local item
    for item in "${stacks[@]}"; do
        if [ -z "$out" ]; then
            out="$item"
        elif ! printf '%s' "$out" | grep -qF "$item"; then
            out="$out, $item"
        fi
    done
    echo "$out"
}

guess_github_repo_from_remote() {
    if ! command -v git >/dev/null 2>&1; then
        echo ""
        return
    fi
    if ! git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
        echo ""
        return
    fi

    local url repo
    url=$(git -C "$PROJECT_DIR" config --get remote.origin.url 2>/dev/null || true)
    if [ -z "$url" ]; then
        echo ""
        return
    fi

    repo=$(printf '%s\n' "$url" | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')
    if printf '%s' "$repo" | grep -q '/'; then
        echo "$repo"
    else
        echo ""
    fi
}

prompt_line() {
    local prompt="$1"
    local default="$2"
    local input

    # When installed via `curl ... | bash`, stdin is consumed by the stream bootstrap.
    # Read from the controlling terminal when available so interactive setup works.
    if ! read_user_line "$prompt [$default]: " input; then
        input=""
    fi
    if [ -z "$input" ]; then
        echo "$default"
    else
        echo "$input"
    fi
}

read_user_line() {
    local prompt="$1"
    local _outvar="$2"
    local input=""

    # In library mode (tests), always honor stdin redirections and never block on /dev/tty.
    if [ "${RALPHIE_LIB:-0}" = "1" ]; then
        if ! read -r -p "$prompt" input; then
            input=""
        fi
        printf -v "$_outvar" '%s' "$input"
        return 0
    fi

    if [ -t 0 ]; then
        if ! read -r -p "$prompt" input; then
            input=""
        fi
        printf -v "$_outvar" '%s' "$input"
        return 0
    fi

    if [ -r /dev/tty ]; then
        if ! read -r -p "$prompt" input </dev/tty; then
            input=""
        fi
        printf -v "$_outvar" '%s' "$input"
        return 0
    fi

    if ! read -r -p "$prompt" input; then
        input=""
    fi
    printf -v "$_outvar" '%s' "$input"
    return 0
}

prompt_yes_no() {
    local prompt="$1"
    local default="$2"
    local answer normalized

    case "$(to_lower "$default")" in
        y|yes|true|1|on) default="y" ;;
        *) default="n" ;;
    esac

    while true; do
        answer=""
        read_user_line "$prompt [y/n] ($default): " answer
        answer="${answer:-$default}"
        normalized="$(to_lower "$answer")"
        # Accept common punctuation/whitespace variants like "y." or "n,".
        normalized="$(printf '%s' "$normalized" | tr -d '[:space:].,;:!')"
        case "$normalized" in
            y|yes) echo "true"; return 0 ;;
            n|no) echo "false"; return 0 ;;
        esac
        echo "Please answer y or n."
    done
}

prompt_optional_line() {
    local prompt="$1"
    local default="$2"
    local input shown_default
    shown_default="${default:-none}"
    if ! read_user_line "$prompt [$shown_default]: " input; then
        input=""
    fi
    if [ -z "$input" ]; then
        echo "$default"
    else
        echo "$input"
    fi
}

install_node_toolchain_with_nvm_latest() {
    local tmpdir script_file
    tmpdir="$(mktemp -d)"
    script_file="$tmpdir/install-node-toolchain.sh"

    cat > "$script_file" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

nvm_tag="$(curl -fsSL https://api.github.com/repos/nvm-sh/nvm/releases/latest | grep tag_name | cut -d : -f 2 | tr -d ' ",')"
if [ -z "$nvm_tag" ]; then
    echo "Unable to resolve latest nvm release tag." >&2
    exit 1
fi

curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${nvm_tag}/install.sh" | bash
# shellcheck disable=SC1090
source "$HOME/.nvm/nvm.sh"
nvm install node
nvm use node
npm install -g npm@latest
EOF

    if bash "$script_file"; then
        rm -rf "$tmpdir"
        return 0
    fi

    rm -rf "$tmpdir"
    return 1
}

run_chutes_bootstrap_script() {
    local script_name="$1"
    local url="https://chutes.ai/${script_name}"
    local tmpdir script_file
    tmpdir="$(mktemp -d)"
    script_file="$tmpdir/$script_name"

    if ! curl -fsSL -o "$script_file" "$url"; then
        rm -rf "$tmpdir"
        return 1
    fi

    if bash "$script_file"; then
        rm -rf "$tmpdir"
        return 0
    fi

    rm -rf "$tmpdir"
    return 1
}

refresh_runtime_paths() {
    if [ -s "$HOME/.nvm/nvm.sh" ]; then
        # shellcheck disable=SC1090
        source "$HOME/.nvm/nvm.sh" >/dev/null 2>&1 || true
    fi
    hash -r || true
}

offer_binary_bootstrap_setup() {
    if ! is_interactive; then
        return
    fi

    echo ""
    echo "Optional binary bootstrap:"
    echo "- Node.js toolchain (nvm + latest node + npm)"
    echo "- Chutes Codex environment script"
    echo "- Chutes Claude Code environment script"
    echo "Skip choices are remembered in $(path_for_display "$CONFIG_FILE")."
    echo ""

    local answer default_choice

    if ! is_true "$SKIP_BOOTSTRAP_NODE_TOOLCHAIN"; then
        if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
            default_choice="n"
        else
            default_choice="y"
        fi
        answer="$(prompt_yes_no "Install/update Node.js toolchain now?" "$default_choice")"
        if is_true "$answer"; then
            info "Running Node.js toolchain bootstrap..."
            if install_node_toolchain_with_nvm_latest; then
                ok "Node.js toolchain bootstrap completed."
                SKIP_BOOTSTRAP_NODE_TOOLCHAIN="false"
            else
                warn "Node.js toolchain bootstrap failed. Continuing setup."
                log_reason_code "RB_BOOTSTRAP_NODE_FAILED" "node/nvm installer command failed"
            fi
        else
            SKIP_BOOTSTRAP_NODE_TOOLCHAIN="true"
            info "Will skip Node.js bootstrap prompt in future setup runs."
        fi
    fi

    if ! is_true "$SKIP_BOOTSTRAP_CHUTES_CODEX"; then
        if command -v "${CODEX_CMD:-codex}" >/dev/null 2>&1; then
            default_choice="n"
        else
            default_choice="y"
        fi
        answer="$(prompt_yes_no "Run Chutes Codex installer now?" "$default_choice")"
        if is_true "$answer"; then
            info "Running Chutes Codex installer..."
            if run_chutes_bootstrap_script "chutes_codex_env.sh"; then
                ok "Chutes Codex installer completed."
                SKIP_BOOTSTRAP_CHUTES_CODEX="false"
            else
                warn "Chutes Codex installer failed. Continuing setup."
                log_reason_code "RB_BOOTSTRAP_CHUTES_CODEX_FAILED" "chutes_codex_env.sh failed"
            fi
        else
            SKIP_BOOTSTRAP_CHUTES_CODEX="true"
            info "Will skip Chutes Codex installer prompt in future setup runs."
        fi
    fi

    if ! is_true "$SKIP_BOOTSTRAP_CHUTES_CLAUDE"; then
        if command -v "${CLAUDE_CMD:-claude}" >/dev/null 2>&1; then
            default_choice="n"
        else
            default_choice="y"
        fi
        answer="$(prompt_yes_no "Run Chutes Claude Code installer now?" "$default_choice")"
        if is_true "$answer"; then
            info "Running Chutes Claude Code installer..."
            if run_chutes_bootstrap_script "chutes_claude_code_env.sh"; then
                ok "Chutes Claude Code installer completed."
                SKIP_BOOTSTRAP_CHUTES_CLAUDE="false"
            else
                warn "Chutes Claude Code installer failed. Continuing setup."
                log_reason_code "RB_BOOTSTRAP_CHUTES_CLAUDE_FAILED" "chutes_claude_code_env.sh failed"
            fi
        else
            SKIP_BOOTSTRAP_CHUTES_CLAUDE="true"
            info "Will skip Chutes Claude installer prompt in future setup runs."
        fi
    fi

    refresh_runtime_paths
    CAPABILITY_PROBED=false
}

save_config() {
    ensure_layout
    {
        echo "# Generated by ralphie.sh"
        echo "RALPHIE_VERSION=$(printf '%q' "$SCRIPT_VERSION")"
        printf "PROJECT_NAME=%q\n" "$PROJECT_NAME"
        printf "PROJECT_VISION=%q\n" "$PROJECT_VISION"
        printf "PRINCIPLE_1=%q\n" "$PRINCIPLE_1"
        printf "PRINCIPLE_2=%q\n" "$PRINCIPLE_2"
        printf "PRINCIPLE_3=%q\n" "$PRINCIPLE_3"
        printf "PROJECT_TYPE=%q\n" "$PROJECT_TYPE"
        printf "STACK_SUMMARY=%q\n" "$STACK_SUMMARY"
        printf "ENGINE_PREF=%q\n" "$ENGINE_PREF"
        printf "CODEX_MODEL=%q\n" "$CODEX_MODEL"
        printf "CLAUDE_MODEL=%q\n" "$CLAUDE_MODEL"
        printf "AUTO_UPDATE_ENABLED=%q\n" "$AUTO_UPDATE_ENABLED"
        printf "AUTO_UPDATE_URL=%q\n" "$AUTO_UPDATE_URL"
        printf "YOLO_MODE=%q\n" "$YOLO_MODE"
        printf "GIT_AUTONOMY=%q\n" "$GIT_AUTONOMY"
        printf "BUILD_APPROVAL_POLICY=%q\n" "$BUILD_APPROVAL_POLICY"
        printf "SKIP_BOOTSTRAP_NODE_TOOLCHAIN=%q\n" "$SKIP_BOOTSTRAP_NODE_TOOLCHAIN"
        printf "SKIP_BOOTSTRAP_CHUTES_CLAUDE=%q\n" "$SKIP_BOOTSTRAP_CHUTES_CLAUDE"
        printf "SKIP_BOOTSTRAP_CHUTES_CODEX=%q\n" "$SKIP_BOOTSTRAP_CHUTES_CODEX"
        printf "INTERRUPT_MENU_ENABLED=%q\n" "$INTERRUPT_MENU_ENABLED"
        printf "AUTO_PREPARE_BACKFILL_ON_IDLE_BUILD=%q\n" "$AUTO_PREPARE_BACKFILL_ON_IDLE_BUILD"
        printf "HUMAN_NOTIFY_CHANNEL=%q\n" "$HUMAN_NOTIFY_CHANNEL"
        printf "ENABLE_GITHUB_ISSUES=%q\n" "$ENABLE_GITHUB_ISSUES"
        printf "GITHUB_REPO=%q\n" "$GITHUB_REPO"
        printf "LOCK_WAIT_SECONDS=%q\n" "$LOCK_WAIT_SECONDS"
        printf "SWARM_ENABLED=%q\n" "$SWARM_ENABLED"
        printf "SWARM_SIZE=%q\n" "$SWARM_SIZE"
        printf "SWARM_MAX_PARALLEL=%q\n" "$SWARM_MAX_PARALLEL"
        printf "SWARM_RETRY_INVALID_OUTPUT=%q\n" "$SWARM_RETRY_INVALID_OUTPUT"
        printf "MIN_CONSENSUS_SCORE=%q\n" "$MIN_CONSENSUS_SCORE"
        printf "CONSENSUS_MAX_REVIEWER_FAILURES=%q\n" "$CONSENSUS_MAX_REVIEWER_FAILURES"
        printf "CONFIDENCE_TARGET=%q\n" "$CONFIDENCE_TARGET"
        printf "CREATED_AT=%q\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$CONFIG_FILE"
}

load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        return 1
    fi
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    PROJECT_NAME="${PROJECT_NAME:-$(basename "$PROJECT_DIR")}"
    PROJECT_VISION="${PROJECT_VISION:-Build high-quality software with autonomous loops.}"
    PRINCIPLE_1="${PRINCIPLE_1:-Correctness first}"
    PRINCIPLE_2="${PRINCIPLE_2:-Keep changes reviewable}"
    PRINCIPLE_3="${PRINCIPLE_3:-Prefer simple solutions}"
    PROJECT_TYPE="${PROJECT_TYPE:-$(detect_project_type)}"
    PROJECT_TYPE="$(normalize_project_type "$PROJECT_TYPE" "$(detect_project_type)")"
    STACK_SUMMARY="${STACK_SUMMARY:-$(detect_stack_summary)}"
    ENGINE_PREF="${ENGINE_PREF:-auto}"
    CODEX_MODEL="${CODEX_MODEL:-}"
    CLAUDE_MODEL="${CLAUDE_MODEL:-}"
    AUTO_UPDATE_ENABLED="${AUTO_UPDATE_ENABLED:-true}"
    AUTO_UPDATE_URL="${AUTO_UPDATE_URL:-$DEFAULT_AUTO_UPDATE_URL}"
    YOLO_MODE="${YOLO_MODE:-true}"
    GIT_AUTONOMY="${GIT_AUTONOMY:-true}"
    BUILD_APPROVAL_POLICY="${BUILD_APPROVAL_POLICY:-upfront}"
    SKIP_BOOTSTRAP_NODE_TOOLCHAIN="${SKIP_BOOTSTRAP_NODE_TOOLCHAIN:-false}"
    SKIP_BOOTSTRAP_CHUTES_CLAUDE="${SKIP_BOOTSTRAP_CHUTES_CLAUDE:-false}"
    SKIP_BOOTSTRAP_CHUTES_CODEX="${SKIP_BOOTSTRAP_CHUTES_CODEX:-false}"
    INTERRUPT_MENU_ENABLED="${INTERRUPT_MENU_ENABLED:-true}"
    AUTO_PREPARE_BACKFILL_ON_IDLE_BUILD="${AUTO_PREPARE_BACKFILL_ON_IDLE_BUILD:-true}"
    HUMAN_NOTIFY_CHANNEL="${HUMAN_NOTIFY_CHANNEL:-terminal}"
    ENABLE_GITHUB_ISSUES="${ENABLE_GITHUB_ISSUES:-false}"
    GITHUB_REPO="${GITHUB_REPO:-$(guess_github_repo_from_remote)}"
    LOCK_WAIT_SECONDS="${LOCK_WAIT_SECONDS:-30}"
    SWARM_ENABLED="${SWARM_ENABLED:-true}"
    SWARM_SIZE="${SWARM_SIZE:-3}"
    SWARM_MAX_PARALLEL="${SWARM_MAX_PARALLEL:-2}"
    SWARM_RETRY_INVALID_OUTPUT="${SWARM_RETRY_INVALID_OUTPUT:-1}"
    MIN_CONSENSUS_SCORE="${MIN_CONSENSUS_SCORE:-80}"
    CONSENSUS_MAX_REVIEWER_FAILURES="${CONSENSUS_MAX_REVIEWER_FAILURES:-0}"
    CONFIDENCE_TARGET="${CONFIDENCE_TARGET:-85}"
    BUILD_APPROVAL_POLICY="$(to_lower "$BUILD_APPROVAL_POLICY")"
    HUMAN_NOTIFY_CHANNEL="$(to_lower "$HUMAN_NOTIFY_CHANNEL")"
    if ! is_valid_build_approval_policy "$BUILD_APPROVAL_POLICY"; then
        BUILD_APPROVAL_POLICY="upfront"
    fi
    if ! is_valid_notify_channel "$HUMAN_NOTIFY_CHANNEL"; then
        HUMAN_NOTIFY_CHANNEL="terminal"
    fi
    return 0
}

write_constitution() {
    ensure_layout

    cat > "$CONSTITUTION_FILE" <<EOF
# $PROJECT_NAME Constitution

> $PROJECT_VISION

**Version:** 1.0.0
**Generated:** $(date '+%Y-%m-%d')

---

## Ralphie

**Script:** \`ralphie.sh\`
**Version:** $SCRIPT_VERSION

---

## Core Principles

### I. $PRINCIPLE_1

### II. $PRINCIPLE_2

### III. $PRINCIPLE_3

---

## Project Context

- **Project type:** $PROJECT_TYPE
- **Stack summary:** $STACK_SUMMARY

---

## Autonomy

- **Default Engine:** $ENGINE_PREF
- **Codex Model Override:** ${CODEX_MODEL:-"(default)"}
- **Claude Model Override:** ${CLAUDE_MODEL:-"(default)"}
- **YOLO Mode:** $(is_true "$YOLO_MODE" && echo "ENABLED" || echo "DISABLED")
- **Git Autonomy:** $(is_true "$GIT_AUTONOMY" && echo "ENABLED" || echo "DISABLED")
- **Build Approval Policy:** $BUILD_APPROVAL_POLICY
- **Human Notify Channel:** $HUMAN_NOTIFY_CHANNEL
- **GitHub Issues:** $(is_true "$ENABLE_GITHUB_ISSUES" && echo "ENABLED" || echo "DISABLED")
$( [ -n "$GITHUB_REPO" ] && echo "- **GitHub Repo:** $GITHUB_REPO" )

---

## Execution Model

### Phase 1: Prepare

- Build deep understanding with recursive planning and critique.
- Research each major component using reputable sources when available.
- Produce specs, research docs, and implementation plan.
- Track confidence and ask humans only for critical clarification.

### Phase 2: Build

- Requires plan + specs + research artifacts.
- Runs consensus checks before entering autonomous build loops.
- Implements one scoped item at a time and verifies before completion.

---

## Completion Signal

Only output \`<promise>DONE</promise>\` when the current mode's acceptance criteria are met:
1. **Prepare/Plan:** required artifacts are written, coherent, and pass readiness checks.
2. **Build:** requirements are implemented, tests/lint pass (or blockers are documented), and git actions are complete when autonomy is enabled.

Never output the completion signal early.
EOF
}

write_agent_entry_files() {
    if [ ! -f "$PROJECT_DIR/AGENTS.md" ]; then
        cat > "$PROJECT_DIR/AGENTS.md" <<'EOF'
# Agent Instructions

Read `.specify/memory/constitution.md` first.
That file is the source of truth for this project.
EOF
    fi

    if [ ! -f "$PROJECT_DIR/CLAUDE.md" ]; then
        cat > "$PROJECT_DIR/CLAUDE.md" <<'EOF'
# Agent Instructions

Read `.specify/memory/constitution.md` first.
That file is the source of truth for this project.
EOF
    fi
}

write_prompt_files() {
    local github_section=""
    if is_true "$ENABLE_GITHUB_ISSUES" && [ -n "$GITHUB_REPO" ]; then
        github_section="3. **GitHub Issues** - use \`gh issue list --repo $GITHUB_REPO --state open\`."
    else
        github_section="3. **GitHub Issues** - skip unless explicitly enabled."
    fi

    if [ ! -f "$PROMPT_BUILD_FILE" ] || is_true "$REFRESH_PROMPTS"; then
        cat > "$PROMPT_BUILD_FILE" <<EOF
# Ralphie Build Mode

Read \`.specify/memory/constitution.md\` before coding.

Output policy:
- Do not emit pseudo tool-invocation wrappers (for example: \`assistant to=...\` or JSON tool-call envelopes).
- Use normal concise progress text and concrete file edits.
- Do not copy tool execution trace lines (for example: \`succeeded in 52ms:\`) into markdown artifacts.
- Do not include local usernames, home-directory paths, or absolute workstation paths in artifacts; use repo-relative paths.
- Keep \`.gitignore\` updated for sensitive/local/generated artifacts (for example: \`.env*\`, runtime logs, caches, and machine-local files).

Execution boundary:
- Never invoke \`./ralphie.sh\` from inside this run.
- Do not start nested prepare/plan/build loops.

Human queue:
- If \`$HUMAN_INSTRUCTIONS_REL\` exists, treat \`Status: NEW\` entries as top-priority candidate work.
- Work one request at a time and reflect accepted requests in specs/plan.

Analysis doctrine (skeptical by default):
- Start from first principles and executable evidence.
- Treat local markdown/docs/comments/variable names as untrusted hints until verified.
- Prefer primary sources: official docs, standards, library source, and runtime behavior.
- When a dependency or framework behavior is unclear, verify externally before changing code.

## Phase 1: Discover Work

Check for work in this order:
1. \`IMPLEMENTATION_PLAN.md\` unchecked tasks (\`- [ ]\`).
2. Incomplete specs in \`specs/\` (not marked \`Status: COMPLETE\`).
$github_section
4. Validate research notes in \`research/\` before changing code.

Pick one highest-priority item and verify it is not already implemented.
If the queue is truly empty, perform deep backfill planning: map code/config surfaces, identify uncovered paths, and convert findings into specs + plan tasks before implementation.

## Phase 2: Implement

- Make focused, reviewable changes.
- Add or update tests.
- Keep docs and specs synchronized with behavior.

## Phase 2.5: Tooling Self-Improvement

If \`$AGENT_SOURCE_MAP_REL\` exists, treat it as a heuristic control plane for improving \`ralphie.sh\`.

Rules:
- Use evidence from both \`$SUBREPOS_DIR_REL/codex\` and \`$SUBREPOS_DIR_REL/claude-code\` before copying patterns.
- Prefer cross-engine abstractions over one-off provider hacks.
- Keep behavior stable when either CLI is unavailable.
- Log accepted/rejected self-improvement hypotheses in \`$SELF_IMPROVEMENT_LOG_REL\`.
- Keep self-improvement time bounded; prioritize product work unless reliability/parity is at risk.

## Phase 3: Validate

- Run the project's test and lint workflows.
- Verify acceptance criteria line-by-line.

## Phase 4: Finalize

- Update task/spec status.
- Commit with a descriptive message.
$(is_true "$GIT_AUTONOMY" && echo "- Push to remote branch." || echo "- Leave push decision to the user.")

## Completion Signal

Output \`<promise>DONE</promise>\` only when all checks pass.
If anything is incomplete, continue working and do not emit the signal.
EOF
    fi

    if [ ! -f "$PROMPT_PLAN_FILE" ] || is_true "$REFRESH_PROMPTS"; then
        cat > "$PROMPT_PLAN_FILE" <<'EOF'
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
EOF
    fi

    if [ ! -f "$PROMPT_PREPARE_FILE" ] || is_true "$REFRESH_PROMPTS"; then
        cat > "$PROMPT_PREPARE_FILE" <<'EOF'
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
EOF
    fi

    if [ ! -f "$PROMPT_TEST_FILE" ] || is_true "$REFRESH_PROMPTS"; then
        cat > "$PROMPT_TEST_FILE" <<'EOF'
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
EOF
    fi

    if [ ! -f "$PROMPT_REFACTOR_FILE" ] || is_true "$REFRESH_PROMPTS"; then
        cat > "$PROMPT_REFACTOR_FILE" <<'EOF'
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
EOF
    fi

    if [ ! -f "$PROMPT_LINT_FILE" ] || is_true "$REFRESH_PROMPTS"; then
        cat > "$PROMPT_LINT_FILE" <<'EOF'
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
EOF
    fi

    if [ ! -f "$PROMPT_DOCUMENT_FILE" ] || is_true "$REFRESH_PROMPTS"; then
        cat > "$PROMPT_DOCUMENT_FILE" <<'EOF'
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
EOF
    fi
}

create_bootstrap_spec_if_needed() {
    if [ -f "$PLAN_FILE" ]; then
        return
    fi
    if is_true "$ENABLE_GITHUB_ISSUES"; then
        return
    fi

    local has_specs=false
    if find "$SPECS_DIR" -maxdepth 2 -type f \( -name "spec.md" -o -name "*.md" \) 2>/dev/null | grep -q .; then
        has_specs=true
    fi

    if is_true "$has_specs"; then
        return
    fi

    local spec_dir spec_file title criteria
    spec_dir="$SPECS_DIR/001-project-foundation"
    spec_file="$spec_dir/spec.md"
    mkdir -p "$spec_dir"

    if [ "$PROJECT_TYPE" = "new" ]; then
        title="Bootstrap initial project foundation"
        criteria='1. A runnable baseline project exists.
2. Core tooling is configured (tests + lint or equivalent).
3. README explains how to run and validate the project.'
    else
        title="Stabilize existing codebase baseline"
        criteria='1. Existing project runs locally.
2. Critical tests (or smoke checks) pass.
3. One prioritized improvement task is identified and documented.'
    fi

    cat > "$spec_file" <<EOF
# 001 - $title

## Context

$PROJECT_VISION

## Requirements

- Create or harden the project foundation for autonomous iteration.
- Preserve existing behavior unless explicitly changed.

## Acceptance Criteria

$criteria

## Status: INCOMPLETE
EOF

    warn "No specs were found. Created starter spec: $spec_file"
}

create_self_improvement_spec_if_needed() {
    if [ ! -f "$AGENT_SOURCE_MAP_FILE" ]; then
        return
    fi

    local spec_dir spec_file
    spec_dir="$SPECS_DIR/000-ralphie-self-improvement"
    spec_file="$spec_dir/spec.md"

    if [ -f "$spec_file" ]; then
        return
    fi

    mkdir -p "$spec_dir"

    cat > "$spec_file" <<EOF
# 000 - Map-Guided Ralphy Self-Improvement

## Context

This repository includes external source references for Codex and Claude Code:
\`$AGENT_SOURCE_MAP_REL\`

## Requirements

- Improve \`ralphie.sh\` using map-guided, evidence-based changes.
- Preserve cross-engine behavior (Codex and Claude) and graceful degradation.
- Avoid overfitting to one provider's output format or flags.
- Document hypotheses and outcomes in \`$SELF_IMPROVEMENT_LOG_REL\`.

## Acceptance Criteria

1. At least one measurable reliability or observability improvement is implemented.
2. Engine-specific behavior is gated behind explicit checks/fallbacks.
3. Prompt and orchestration changes are validated against both engines where possible.
4. \`$SELF_IMPROVEMENT_LOG_REL\` records what was tried, what changed, and why.

## Status: INCOMPLETE
EOF

    info "Created self-improvement spec from source map: $spec_file"
}

run_setup_wizard() {
    ensure_layout

    local detected_type detected_stack suggested_repo
    detected_type="$(detect_project_type)"
    detected_stack="$(detect_stack_summary)"
    suggested_repo="$(guess_github_repo_from_remote)"

    if is_interactive; then
        echo ""
        echo -e "${PURPLE}Ralphie - First-Time Setup${NC}"
        echo "This creates a reusable configuration for this repository."
        echo ""

        PROJECT_NAME="$(prompt_line "Project name" "$(basename "$PROJECT_DIR")")"
        if [ "$detected_type" = "existing" ]; then
            PROJECT_TYPE="$(prompt_line "Project type (new/existing)" "existing")"
            PROJECT_TYPE="$(normalize_project_type "$PROJECT_TYPE" "existing")"
            PROJECT_VISION="$(prompt_line "One-line project vision" "Improve and extend the existing codebase with reliable autonomous loops.")"
        else
            PROJECT_TYPE="$(prompt_line "Project type (new/existing)" "new")"
            PROJECT_TYPE="$(normalize_project_type "$PROJECT_TYPE" "new")"
            PROJECT_VISION="$(prompt_line "One-line project vision" "Build a production-quality project from scratch.")"
        fi

        PRINCIPLE_1="$(prompt_line "Core principle #1" "Correctness first")"
        PRINCIPLE_2="$(prompt_line "Core principle #2" "Keep changes reviewable")"
        PRINCIPLE_3="$(prompt_line "Core principle #3" "Prefer simple solutions")"

        echo ""
        echo "Default engine:"
        echo "  1) auto (recommended)"
        echo "  2) codex"
        echo "  3) claude"
        echo "  4) ask (prompt on each run)"
        local engine_choice
        engine_choice="$(prompt_line "Pick engine number" "1")"
        case "$engine_choice" in
            2) ENGINE_PREF="codex" ;;
            3) ENGINE_PREF="claude" ;;
            4) ENGINE_PREF="ask" ;;
            *) ENGINE_PREF="auto" ;;
        esac

        YOLO_MODE="$(prompt_yes_no "Enable YOLO mode for autonomous command execution?" "y")"
        GIT_AUTONOMY="$(prompt_yes_no "Enable Git autonomy (commit/push in loop)?" "y")"
        BUILD_APPROVAL_POLICY="$(to_lower "$(prompt_line "Build approval policy (upfront/on_ready)" "upfront")")"
        HUMAN_NOTIFY_CHANNEL="$(to_lower "$(prompt_line "Human notify channel (none/terminal/telegram/discord)" "terminal")")"
        ENABLE_GITHUB_ISSUES="$(prompt_yes_no "Enable GitHub issue integration?" "y")"
        if is_true "$ENABLE_GITHUB_ISSUES"; then
            GITHUB_REPO="$(prompt_line "GitHub repo (owner/name)" "${suggested_repo:-}")"
        else
            GITHUB_REPO=""
        fi

        STACK_SUMMARY="$(prompt_line "Stack summary" "$detected_stack")"
        CODEX_MODEL="$(prompt_optional_line "Default Codex model override (blank keeps codex default)" "${CODEX_MODEL:-}")"
        CLAUDE_MODEL="$(prompt_optional_line "Default Claude model override (blank keeps claude default)" "${CLAUDE_MODEL:-}")"
        AUTO_UPDATE_ENABLED="$(prompt_yes_no "Enable ralphie.sh auto-update from upstream on each run?" "y")"
        if is_true "$AUTO_UPDATE_ENABLED"; then
            AUTO_UPDATE_URL="$(prompt_optional_line "Auto-update URL" "$DEFAULT_AUTO_UPDATE_URL")"
        else
            AUTO_UPDATE_URL="$DEFAULT_AUTO_UPDATE_URL"
        fi
        offer_binary_bootstrap_setup
    else
        PROJECT_NAME="$(basename "$PROJECT_DIR")"
        PROJECT_TYPE="$detected_type"
        PROJECT_VISION="Build maintainable software with autonomous loops."
        PRINCIPLE_1="Correctness first"
        PRINCIPLE_2="Keep changes reviewable"
        PRINCIPLE_3="Prefer simple solutions"
        ENGINE_PREF="auto"
        YOLO_MODE="true"
        GIT_AUTONOMY="true"
        BUILD_APPROVAL_POLICY="upfront"
        HUMAN_NOTIFY_CHANNEL="terminal"
        ENABLE_GITHUB_ISSUES="false"
        GITHUB_REPO="$suggested_repo"
        STACK_SUMMARY="$detected_stack"
        CODEX_MODEL="${CODEX_MODEL:-}"
        CLAUDE_MODEL="${CLAUDE_MODEL:-}"
        AUTO_UPDATE_ENABLED="${AUTO_UPDATE_ENABLED:-true}"
        AUTO_UPDATE_URL="${AUTO_UPDATE_URL:-$DEFAULT_AUTO_UPDATE_URL}"
        SKIP_BOOTSTRAP_NODE_TOOLCHAIN="${SKIP_BOOTSTRAP_NODE_TOOLCHAIN:-false}"
        SKIP_BOOTSTRAP_CHUTES_CLAUDE="${SKIP_BOOTSTRAP_CHUTES_CLAUDE:-false}"
        SKIP_BOOTSTRAP_CHUTES_CODEX="${SKIP_BOOTSTRAP_CHUTES_CODEX:-false}"
    fi

    save_config
    write_constitution
    write_agent_entry_files
    write_prompt_files
    create_bootstrap_spec_if_needed
    create_self_improvement_spec_if_needed

    ok "Setup complete."
    info "Configuration saved: $(path_for_display "$CONFIG_FILE")"
    info "Constitution: $(path_for_display "$CONSTITUTION_FILE")"
}

collect_incomplete_specs() {
    INCOMPLETE_SPECS=()
    if [ ! -d "$SPECS_DIR" ]; then
        return
    fi

    local spec_list
    spec_list="$(find "$SPECS_DIR" -maxdepth 2 -type f \( -name "spec.md" -o -name "*.md" \) 2>/dev/null | sort || true)"
    while IFS= read -r spec_file; do
        [ -n "$spec_file" ] || continue
        if ! grep -qiE 'status[[:space:]]*:[[:space:]]*complete' "$spec_file" 2>/dev/null; then
            INCOMPLETE_SPECS+=("$spec_file")
        fi
    done <<< "$spec_list"
}

check_plan_tasks() {
    HAS_PLAN_TASKS=false
    if [ ! -f "$PLAN_FILE" ]; then
        return
    fi

    local task_count
    task_count="$(plan_task_count "$PLAN_FILE")"
    if is_number "$task_count" && [ "$task_count" -gt 0 ]; then
        HAS_PLAN_TASKS=true
    fi
}

gh_ready() {
    if ! is_true "$ENABLE_GITHUB_ISSUES"; then
        return 1
    fi
    if [ -z "${GITHUB_REPO:-}" ]; then
        return 1
    fi
    if ! command -v gh >/dev/null 2>&1; then
        return 1
    fi
    if ! gh auth status >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

check_github_issues() {
    HAS_GITHUB_ISSUES=false
    if ! gh_ready; then
        return
    fi

    local count
    count=$(gh issue list --repo "$GITHUB_REPO" --state open --limit 1 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
    if [ "${count:-0}" -gt 0 ]; then
        HAS_GITHUB_ISSUES=true
    fi
}

count_pending_human_requests() {
    if [ ! -f "$HUMAN_INSTRUCTIONS_FILE" ]; then
        echo "0"
        return
    fi
    grep -ciE 'status[[:space:]]*:[[:space:]]*new' "$HUMAN_INSTRUCTIONS_FILE" 2>/dev/null || echo "0"
}

check_human_requests() {
    HAS_HUMAN_REQUESTS=false
    if [ ! -f "$HUMAN_INSTRUCTIONS_FILE" ]; then
        return
    fi
    if [ "$(count_pending_human_requests)" -gt 0 ]; then
        HAS_HUMAN_REQUESTS=true
    fi
}

has_work_items() {
    collect_incomplete_specs
    check_plan_tasks
    check_github_issues
    check_human_requests

    if [ "${#INCOMPLETE_SPECS[@]}" -gt 0 ]; then
        return 0
    fi
    if is_true "$HAS_PLAN_TASKS"; then
        return 0
    fi
    if is_true "$HAS_GITHUB_ISSUES"; then
        return 0
    fi
    if is_true "$HAS_HUMAN_REQUESTS"; then
        return 0
    fi
    return 1
}

capture_human_priorities() {
    ensure_layout

    if ! is_interactive; then
        err "--human requires an interactive terminal."
        log_reason_code "RB_HUMAN_MODE_NON_INTERACTIVE" "run without --non-interactive to capture human priorities"
        return 1
    fi

    if [ ! -f "$HUMAN_INSTRUCTIONS_FILE" ]; then
        cat > "$HUMAN_INSTRUCTIONS_FILE" <<EOF
# Human Instructions Queue

Add one request at a time.
Each request should include:
- Request
- Priority (high|medium|low)
- Status (NEW|IN_PROGRESS|DONE)
EOF
    fi

    echo ""
    echo "Human priority capture"
    echo "One request at a time. Keep each request specific."

    local added_count=0
    while true; do
        local request reason priority add_more
        request=""
        read_user_line "Request (leave empty to finish): " request
        if [ -z "$request" ]; then
            break
        fi

        reason=""
        read_user_line "Why it matters (optional): " reason
        priority="$(prompt_line "Priority (high/medium/low)" "high")"
        priority="$(to_lower "$priority")"
        case "$priority" in
            high|medium|low) ;;
            *) priority="high" ;;
        esac

        {
            echo ""
            echo "## $(date '+%Y-%m-%d %H:%M:%S')"
            echo "- Request: $request"
            if [ -n "$reason" ]; then
                echo "- Why: $reason"
            fi
            echo "- Priority: $priority"
            echo "- Status: NEW"
        } >> "$HUMAN_INSTRUCTIONS_FILE"

        added_count=$((added_count + 1))

        while true; do
            add_more=""
            read_user_line "Add another request? [y/n] (n): " add_more
            case "$(to_lower "${add_more:-n}")" in
                y|yes) break ;;
                n|no)
                    ok "Captured $added_count human request(s): $HUMAN_INSTRUCTIONS_REL"
                    info "Active loops will pick this up on the next iteration."
                    return 0
                    ;;
                *) echo "Please answer y or n." ;;
            esac
        done
    done

    if [ "$added_count" -gt 0 ]; then
        ok "Captured $added_count human request(s): $HUMAN_INSTRUCTIONS_REL"
        info "Active loops will pick this up on the next iteration."
    else
        info "No new human requests captured."
    fi
    return 0
}

format_duration() {
    local seconds="$1"
    if [ "$seconds" -lt 60 ]; then
        printf '%ss' "$seconds"
    elif [ "$seconds" -lt 3600 ]; then
        printf '%sm' "$((seconds / 60))"
    else
        printf '%sh %sm' "$((seconds / 3600))" "$((seconds % 3600 / 60))"
    fi
}

get_backoff_wait() {
    if ! is_true "$BACKOFF_ENABLED"; then
        echo "$NORMAL_WAIT"
        return
    fi
    if [ "$BACKOFF_LEVEL" -le 0 ]; then
        echo "$NORMAL_WAIT"
        return
    fi
    local idx=$((BACKOFF_LEVEL - 1))
    if [ "$idx" -ge "${#BACKOFF_TIMES[@]}" ]; then
        idx=$((${#BACKOFF_TIMES[@]} - 1))
    fi
    echo "${BACKOFF_TIMES[$idx]}"
}

get_timeout_command() {
    if command -v gtimeout >/dev/null 2>&1; then
        echo "gtimeout"
        return
    fi
    if command -v timeout >/dev/null 2>&1; then
        echo "timeout"
        return
    fi
    echo ""
}

engine_command_for() {
    local engine="$1"
    case "$engine" in
        codex) echo "${CODEX_CMD:-codex}" ;;
        claude) echo "${CLAUDE_CMD:-claude}" ;;
        *) echo "" ;;
    esac
}

mode_fallback_order() {
    local mode="$1"
    local default_order="codex claude"

    if [ ! -f "$BINARY_STEERING_MAP_FILE" ]; then
        echo "$default_order"
        return
    fi

    local line in_mode=false raw=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]{2}${mode}:[[:space:]]*$ ]]; then
            in_mode=true
            continue
        fi

        if is_true "$in_mode"; then
            if [[ "$line" =~ ^[[:space:]]{2}[a-zA-Z0-9_-]+:[[:space:]]*$ ]]; then
                break
            fi
            if [[ "$line" =~ fallback_order:[[:space:]]*\[(.*)\] ]]; then
                raw="${BASH_REMATCH[1]}"
                raw="${raw//\"/}"
                raw="${raw//,/ }"
                raw="$(printf '%s\n' "$raw" | xargs)"
                if [ -n "$raw" ]; then
                    echo "$raw"
                    return
                fi
                break
            fi
        fi
    done < "$BINARY_STEERING_MAP_FILE"

    echo "$default_order"
}

pick_fallback_engine() {
    local mode="$1"
    local current_engine="$2"
    local order candidate cmd

    order="$(mode_fallback_order "$mode")"
    for candidate in $order; do
        if [ "$candidate" = "$current_engine" ]; then
            continue
        fi

        cmd="$(engine_command_for "$candidate")"
        if [ -z "$cmd" ]; then
            continue
        fi
        if ! command -v "$cmd" >/dev/null 2>&1; then
            continue
        fi

        echo "$candidate"
        return 0
    done

    echo ""
    return 1
}

switch_active_engine() {
    local target_engine="$1"
    local reason="$2"
    local cmd previous_engine

    cmd="$(engine_command_for "$target_engine")"
    if [ -z "$cmd" ] || ! command -v "$cmd" >/dev/null 2>&1; then
        return 1
    fi

    previous_engine="$ACTIVE_ENGINE"
    ACTIVE_ENGINE="$target_engine"
    ACTIVE_CMD="$cmd"
    warn "Engine failover: ${previous_engine} -> ${ACTIVE_ENGINE} (${reason})"
    return 0
}

resolve_engine() {
    local selected="$1"
    local codex_cmd="${CODEX_CMD:-codex}"
    local claude_cmd="${CLAUDE_CMD:-claude}"

    case "$selected" in
        ask)
            local codex_ok=false
            local claude_ok=false
            if command -v "$codex_cmd" >/dev/null 2>&1; then
                codex_ok=true
            fi
            if command -v "$claude_cmd" >/dev/null 2>&1; then
                claude_ok=true
            fi

            if is_true "$codex_ok" && ! is_true "$claude_ok"; then
                ACTIVE_ENGINE="codex"
                ACTIVE_CMD="$codex_cmd"
                return 0
            fi
            if is_true "$claude_ok" && ! is_true "$codex_ok"; then
                ACTIVE_ENGINE="claude"
                ACTIVE_CMD="$claude_cmd"
                return 0
            fi
            if is_true "$codex_ok" && is_true "$claude_ok"; then
                if is_interactive; then
                    echo ""
                    echo "Both Codex and Claude are available."
                    echo "  1) codex"
                    echo "  2) claude"
                    local choice
                    choice="$(prompt_line "Pick engine number for this run" "1")"
                    case "$choice" in
                        2) ACTIVE_ENGINE="claude"; ACTIVE_CMD="$claude_cmd" ;;
                        *) ACTIVE_ENGINE="codex"; ACTIVE_CMD="$codex_cmd" ;;
                    esac
                    return 0
                fi

                # Non-interactive fallback mirrors auto selection.
                ACTIVE_ENGINE="codex"
                ACTIVE_CMD="$codex_cmd"
                return 0
            fi
            ;;
        auto)
            if command -v "$codex_cmd" >/dev/null 2>&1; then
                ACTIVE_ENGINE="codex"
                ACTIVE_CMD="$codex_cmd"
                return 0
            fi
            if command -v "$claude_cmd" >/dev/null 2>&1; then
                ACTIVE_ENGINE="claude"
                ACTIVE_CMD="$claude_cmd"
                return 0
            fi
            ;;
        codex)
            if command -v "$codex_cmd" >/dev/null 2>&1; then
                ACTIVE_ENGINE="codex"
                ACTIVE_CMD="$codex_cmd"
                return 0
            fi
            if command -v "$claude_cmd" >/dev/null 2>&1; then
                warn "Codex CLI not found; falling back to Claude CLI."
                ACTIVE_ENGINE="claude"
                ACTIVE_CMD="$claude_cmd"
                return 0
            fi
            ;;
        claude)
            if command -v "$claude_cmd" >/dev/null 2>&1; then
                ACTIVE_ENGINE="claude"
                ACTIVE_CMD="$claude_cmd"
                return 0
            fi
            if command -v "$codex_cmd" >/dev/null 2>&1; then
                warn "Claude CLI not found; falling back to Codex CLI."
                ACTIVE_ENGINE="codex"
                ACTIVE_CMD="$codex_cmd"
                return 0
            fi
            ;;
    esac

    return 1
}

probe_engine_capabilities() {
    if is_true "$CAPABILITY_PROBED"; then
        return
    fi
    CAPABILITY_PROBED=true

    local codex_cmd claude_cmd codex_help claude_help
    codex_cmd="${CODEX_CMD:-codex}"
    claude_cmd="${CLAUDE_CMD:-claude}"

    if command -v "$codex_cmd" >/dev/null 2>&1; then
        codex_help="$("$codex_cmd" exec --help 2>/dev/null || true)"

        if printf '%s' "$codex_help" | grep -q -- '--output-last-message'; then
            CODEX_CAP_OUTPUT_LAST_MESSAGE=true
        else
            CODEX_CAP_OUTPUT_LAST_MESSAGE=false
            warn "Codex capability probe: missing --output-last-message support."
            log_reason_code "RB_CAP_CDX_OUTPUT_LAST_MESSAGE_MISSING" "codex exec help does not include --output-last-message"
        fi

        if printf '%s' "$codex_help" | grep -q -- '--dangerously-bypass-approvals-and-sandbox'; then
            CODEX_CAP_YOLO_FLAG=true
        else
            CODEX_CAP_YOLO_FLAG=false
            warn "Codex capability probe: missing YOLO flag; will run without dangerous bypass flag."
            log_reason_code "RB_CAP_CDX_YOLO_FLAG_MISSING" "codex exec help does not include --dangerously-bypass-approvals-and-sandbox"
        fi
    fi

    if command -v "$claude_cmd" >/dev/null 2>&1; then
        claude_help="$("$claude_cmd" --help 2>/dev/null || true)"

        if printf '%s' "$claude_help" | grep -q -- '--print'; then
            CLAUDE_CAP_PRINT=true
        else
            CLAUDE_CAP_PRINT=false
            warn "Claude capability probe: missing --print/-p support."
            log_reason_code "RB_CAP_CLA_PRINT_MISSING" "claude --help does not expose print mode"
        fi

        if printf '%s' "$claude_help" | grep -q -- '--dangerously-skip-permissions'; then
            CLAUDE_CAP_YOLO_FLAG="--dangerously-skip-permissions"
        elif printf '%s' "$claude_help" | grep -q -- '--allow-dangerously-skip-permissions'; then
            CLAUDE_CAP_YOLO_FLAG="--allow-dangerously-skip-permissions"
        else
            CLAUDE_CAP_YOLO_FLAG=""
            warn "Claude capability probe: no dangerous permission bypass flag found; YOLO flag will be omitted."
            log_reason_code "RB_CAP_CLA_YOLO_FLAG_MISSING" "claude --help does not include a dangerous skip-permissions flag"
        fi
    fi
}

preflight_runtime_checks() {
    if is_true "$GIT_AUTONOMY"; then
        if ! command -v git >/dev/null 2>&1 || ! git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
            warn "Git autonomy enabled but this is not a git repository. Disabling git push for this run."
            GIT_AUTONOMY="false"
        fi
    fi

    local gitignore_missing=()
    local missing_entry missing_joined missing_output
    missing_output="$(gitignore_missing_required_entries || true)"
    while IFS= read -r missing_entry; do
        [ -n "$missing_entry" ] && gitignore_missing+=("$missing_entry")
    done <<< "$missing_output"
    if [ "${#gitignore_missing[@]}" -gt 0 ]; then
        warn ".gitignore is missing guardrail entries for local/sensitive/runtime artifacts:"
        for missing_entry in "${gitignore_missing[@]}"; do
            warn "  - $missing_entry"
        done
        missing_joined="$(printf '%s,' "${gitignore_missing[@]}" | sed 's/,$//')"
        log_reason_code "RB_GITIGNORE_GUARDRAIL_MISSING" "file=$(path_for_display "$PROJECT_DIR/.gitignore") missing=$missing_joined"
    fi

    if is_true "$ENABLE_GITHUB_ISSUES"; then
        if ! gh_ready; then
            warn "GitHub issue integration is enabled but gh is not ready/authenticated."
            warn "Issue polling will be skipped until gh auth is available."
        fi
    fi

    if [ "$COMMAND_TIMEOUT_SECONDS" -gt 0 ]; then
        if [ -z "$(get_timeout_command)" ]; then
            warn "Timeout requested but no timeout binary found (timeout/gtimeout). Disabling timeout."
            COMMAND_TIMEOUT_SECONDS=0
        fi
    fi

    probe_engine_capabilities
}

gitignore_required_entries() {
    cat <<'EOF'
.env
.env.*
logs/
consensus/
completion_log/
.ralphie/
HUMAN_INSTRUCTIONS.md
research/HUMAN_FEEDBACK.md
coverage/
.nyc_output/
htmlcov/
EOF
}

gitignore_missing_required_entries() {
    local gitignore_file="$PROJECT_DIR/.gitignore"
    local entry

    if [ ! -f "$gitignore_file" ]; then
        gitignore_required_entries
        return 0
    fi

    local required_entries
    required_entries="$(gitignore_required_entries)"
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        if ! grep -qxF "$entry" "$gitignore_file"; then
            echo "$entry"
        fi
    done <<< "$required_entries"
}

extract_tag_value() {
    local tag="$1"
    shift
    local candidate value

    for candidate in "$@"; do
        if [ ! -f "$candidate" ]; then
            continue
        fi
        value=$(grep -oE "<${tag}>[^<]+</${tag}>" "$candidate" 2>/dev/null | tail -1 | sed -E "s#<${tag}>([^<]+)</${tag}>#\1#" || true)
        if [ -n "$value" ]; then
            echo "$value"
            return 0
        fi
    done
    echo ""
    return 0
}

extract_confidence_value() {
    local output_file="$1"
    local log_file="$2"
    local confidence
    confidence="$(extract_tag_value "confidence" "$output_file" "$log_file")"
    if ! is_number "$confidence"; then
        echo "0"
        return
    fi
    if [ "$confidence" -lt 0 ]; then
        confidence=0
    fi
    if [ "$confidence" -gt 100 ]; then
        confidence=100
    fi
    echo "$confidence"
}

extract_needs_human_flag() {
    local output_file="$1"
    local log_file="$2"
    local val
    val="$(to_lower "$(extract_tag_value "needs_human" "$output_file" "$log_file")")"
    if [ "$val" = "true" ] || [ "$val" = "yes" ] || [ "$val" = "1" ]; then
        echo "true"
    else
        echo "false"
    fi
}

extract_human_question() {
    local output_file="$1"
    local log_file="$2"
    extract_tag_value "human_question" "$output_file" "$log_file"
}

output_has_tool_wrapper_leakage() {
    local output_file="$1"
    if [ ! -f "$output_file" ]; then
        return 1
    fi

    if grep -qiE 'assistant[[:space:]]+to=|to=functions\.[a-z_]+|recipient_name"[[:space:]]*:[[:space:]]*"functions\.' "$output_file"; then
        return 0
    fi
    return 1
}

output_has_prepare_status_tags() {
    local output_file="$1"
    if [ ! -f "$output_file" ]; then
        return 1
    fi

    if ! grep -qE '<confidence>[0-9]{1,3}</confidence>' "$output_file"; then
        return 1
    fi
    if ! grep -qE '<needs_human>(true|false)</needs_human>' "$output_file"; then
        return 1
    fi
    if ! grep -qE '<human_question>[^<]*</human_question>' "$output_file"; then
        return 1
    fi
    return 0
}

file_has_local_identity_leakage() {
    local candidate_file="$1"
    if [ ! -f "$candidate_file" ]; then
        return 1
    fi

    local home_dir local_user
    home_dir="${HOME:-}"
    local_user="${USER:-}"
    if [ -z "$local_user" ] && command -v id >/dev/null 2>&1; then
        local_user="$(id -un 2>/dev/null || true)"
    fi

    if [ -n "$home_dir" ] && grep -qF "$home_dir" "$candidate_file" 2>/dev/null; then
        return 0
    fi
    if grep -qiE '(/Users/[A-Za-z0-9._-]+/)|(/home/[A-Za-z0-9._-]+/)|(\\Users\\[A-Za-z0-9._-]+\\)' "$candidate_file" 2>/dev/null; then
        return 0
    fi
    if [ -n "$local_user" ] && [ "${#local_user}" -ge 4 ] && grep -qiF "$local_user" "$candidate_file" 2>/dev/null; then
        return 0
    fi

    return 1
}

output_has_local_identity_leakage() {
    local output_file="$1"
    file_has_local_identity_leakage "$output_file"
}

count_running_pids() {
    local count=0
    local pid
    for pid in "$@"; do
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            count=$((count + 1))
        fi
    done
    echo "$count"
}

extract_reviewer_score() {
    local output_file="$1"
    local _log_file="${2:-}"
    local score
    score="$(extract_tag_value "score" "$output_file")"
    if ! is_number "$score"; then
        if [ -f "$output_file" ]; then
            score=$(grep -oE '"score"[[:space:]]*:[[:space:]]*[0-9]{1,3}' "$output_file" 2>/dev/null | head -1 | grep -oE '[0-9]{1,3}' || true)
        fi
    fi
    if ! is_number "$score"; then
        score="0"
    fi
    if [ "$score" -gt 100 ]; then
        score=100
    fi
    echo "$score"
}

extract_reviewer_verdict() {
    local output_file="$1"
    local _log_file="${2:-}"
    local verdict
    verdict="$(to_lower "$(extract_tag_value "verdict" "$output_file")")"
    case "$verdict" in
        go|pass|ready) echo "GO" ;;
        hold|block|stop|no) echo "HOLD" ;;
        *)
            if grep -qiE '\b(HOLD|BLOCK|STOP)\b' "$output_file" 2>/dev/null; then
                echo "HOLD"
            elif grep -qiE '\bGO\b' "$output_file" 2>/dev/null; then
                echo "GO"
            else
                echo "HOLD"
            fi
            ;;
    esac
}

reviewer_output_has_required_tags() {
    # Consensus reviewers are required to emit structured tags so scoring is stable.
    # Without this check, malformed output is treated as score=0 and can distort consensus.
    local output_file="$1"
    local score verdict

    score="$(extract_tag_value "score" "$output_file")"
    verdict="$(to_lower "$(extract_tag_value "verdict" "$output_file")")"

    if ! is_number "$score"; then
        return 1
    fi
    if [ "$score" -lt 0 ] || [ "$score" -gt 100 ]; then
        return 1
    fi

    case "$verdict" in
        go|hold|pass|ready|block|stop|no) return 0 ;;
        *) return 1 ;;
    esac
}

run_agent_with_prompt() {
    local prompt_file="$1"
    local log_file="$2"
    local output_file="$3"
    local yolo_effective="$4"
    local timeout_cmd=""
    local exit_code=0

    if [ "$COMMAND_TIMEOUT_SECONDS" -gt 0 ]; then
        timeout_cmd="$(get_timeout_command)"
    fi

    probe_engine_capabilities

    if [ "$ACTIVE_ENGINE" = "codex" ]; then
        if ! is_true "$CODEX_CAP_OUTPUT_LAST_MESSAGE"; then
            err "Codex capability missing: --output-last-message is required by this orchestrator."
            log_reason_code "RB_RUN_CDX_OUTPUT_FILE_UNSUPPORTED" "codex output-last-message capability probe failed"
            return 2
        fi

        local -a codex_cmd
        codex_cmd=("$ACTIVE_CMD" "exec")
        if [ -n "$CODEX_MODEL" ]; then
            codex_cmd+=("--model" "$CODEX_MODEL")
        fi
        if is_true "$yolo_effective" && is_true "$CODEX_CAP_YOLO_FLAG"; then
            codex_cmd+=("--dangerously-bypass-approvals-and-sandbox")
        elif is_true "$yolo_effective" && ! is_true "$CODEX_CAP_YOLO_FLAG"; then
            warn "YOLO requested, but Codex dangerous bypass flag is unsupported. Continuing without it."
            log_reason_code "RB_RUN_CDX_YOLO_UNSUPPORTED" "requested codex yolo flag is unavailable"
        fi

        if [ -n "$timeout_cmd" ]; then
            if cat "$prompt_file" | "$timeout_cmd" "$COMMAND_TIMEOUT_SECONDS" "${codex_cmd[@]}" - --output-last-message "$output_file" 2>&1 | tee "$log_file"; then
                exit_code=0
            else
                exit_code=$?
            fi
        else
            if cat "$prompt_file" | "${codex_cmd[@]}" - --output-last-message "$output_file" 2>&1 | tee "$log_file"; then
                exit_code=0
            else
                exit_code=$?
            fi
        fi
    else
        if ! is_true "$CLAUDE_CAP_PRINT"; then
            err "Claude capability missing: print mode (-p/--print) is required by this orchestrator."
            log_reason_code "RB_RUN_CLA_PRINT_UNSUPPORTED" "claude print capability probe failed"
            return 2
        fi

        local -a claude_cmd
        claude_cmd=("$ACTIVE_CMD" "-p")
        if [ -n "$CLAUDE_MODEL" ]; then
            claude_cmd+=("--model" "$CLAUDE_MODEL")
        fi
        if is_true "$yolo_effective"; then
            if [ -n "$CLAUDE_CAP_YOLO_FLAG" ]; then
                claude_cmd+=("$CLAUDE_CAP_YOLO_FLAG")
            else
                warn "YOLO requested, but Claude dangerous skip-permissions flag is unsupported. Continuing without it."
                log_reason_code "RB_RUN_CLA_YOLO_UNSUPPORTED" "requested claude yolo flag is unavailable"
            fi
        fi

        if [ -n "$timeout_cmd" ]; then
            if cat "$prompt_file" | "$timeout_cmd" "$COMMAND_TIMEOUT_SECONDS" "${claude_cmd[@]}" 2>>"$log_file" | tee "$output_file" >> "$log_file"; then
                exit_code=0
            else
                exit_code=$?
            fi
        else
            if cat "$prompt_file" | "${claude_cmd[@]}" 2>>"$log_file" | tee "$output_file" >> "$log_file"; then
                exit_code=0
            else
                exit_code=$?
            fi
        fi
    fi

    return "$exit_code"
}

append_self_improvement_log() {
    local title="$1"
    local details="$2"
    mkdir -p "$RESEARCH_DIR"
    {
        echo "## $(date '+%Y-%m-%d %H:%M:%S') - $title"
        printf '%b\n' "$details"
        echo ""
    } >> "$SELF_IMPROVEMENT_LOG_FILE"
}

self_heal_codex_reasoning_effort_xhigh() {
    local codex_config="$HOME/.codex/config.toml"
    local backup_file tmp_file

    if [ ! -f "$codex_config" ]; then
        return 1
    fi

    if ! grep -qE '^[[:space:]]*model_reasoning_effort[[:space:]]*=[[:space:]]*"xhigh"[[:space:]]*$' "$codex_config"; then
        return 1
    fi

    backup_file="$codex_config.bak.$(date '+%Y%m%d_%H%M%S')"
    cp "$codex_config" "$backup_file"

    tmp_file="$codex_config.tmp.$$"
    sed -E 's/^([[:space:]]*model_reasoning_effort[[:space:]]*=[[:space:]]*)"xhigh"/\1"high"/' "$codex_config" > "$tmp_file"
    mv "$tmp_file" "$codex_config"

    ok "Self-heal applied: updated $(path_for_display "$codex_config") (xhigh -> high)"
    append_self_improvement_log \
        "Self-heal: Codex config compatibility" \
        "- Trigger: Codex failed to parse model_reasoning_effort='xhigh'.\n- Action: Rewrote model_reasoning_effort to 'high'.\n- Backup: $(path_for_display "$backup_file")\n- Outcome: Ready to retry agent loop."
    return 0
}

try_self_heal_agent_failure() {
    local log_file="$1"
    local output_file="$2"

    if grep -qE 'Error loading config\.toml: unknown variant `xhigh`' "$log_file" "$output_file" 2>/dev/null \
        && grep -qE 'model_reasoning_effort' "$log_file" "$output_file" 2>/dev/null; then
        if self_heal_codex_reasoning_effort_xhigh; then
            return 0
        fi
    fi

    return 1
}

is_fatal_agent_config_error() {
    local log_file="$1"
    local output_file="$2"

    if grep -qE 'Error loading config\.toml' "$log_file" "$output_file" 2>/dev/null; then
        return 0
    fi
    return 1
}

print_fatal_agent_config_help() {
    local log_file="$1"
    local output_file="$2"
    local codex_config="$HOME/.codex/config.toml"

    err "Fatal agent configuration error detected. Stopping loop."

    if grep -qE 'model_reasoning_effort|unknown variant' "$log_file" "$output_file" 2>/dev/null; then
        err "Codex config has an unsupported 'model_reasoning_effort' value for this CLI build."
        warn "Valid values for this build are: none, minimal, low, medium, high"
        warn "Update: $(path_for_display "$codex_config")"
        warn "Example: model_reasoning_effort = \"high\""
    fi

    warn "You can bypass Codex for now with: ./ralphie.sh --engine claude prepare"
}

json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e ':a;N;$!ba;s/\n/\\n/g'
}

notify_human() {
    local title="$1"
    local body="${2:-}"
    local raw_channel="${HUMAN_NOTIFY_CHANNEL:-terminal}"
    local channel
    channel="$(to_lower "$raw_channel")"

    case "$channel" in
        none)
            return 0
            ;;
        terminal)
            warn "$title"
            [ -n "$body" ] && warn "$body"
            return 0
            ;;
        telegram)
            if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
                warn "Telegram notify selected, but TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID are missing"
                return 1
            fi
            if ! command -v curl >/dev/null 2>&1; then
                warn "curl is required for Telegram notifications"
                return 1
            fi
            local project_name="${PROJECT_NAME:-$(basename "$PROJECT_DIR")}"
            local mode_name="${MODE:-unknown}"
            local message="[$project_name][$mode_name] $title"
            if [ -n "$body" ]; then
                message="${message}\n${body}"
            fi
            if ! curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
                --data-urlencode "text=${message}" >/dev/null 2>&1; then
                warn "Failed to send Telegram notification"
                return 1
            fi
            return 0
            ;;
        discord)
            if [ -z "$DISCORD_WEBHOOK_URL" ]; then
                warn "Discord notify selected, but DISCORD_WEBHOOK_URL is missing"
                return 1
            fi
            if ! command -v curl >/dev/null 2>&1; then
                warn "curl is required for Discord notifications"
                return 1
            fi
            local project_name="${PROJECT_NAME:-$(basename "$PROJECT_DIR")}"
            local mode_name="${MODE:-unknown}"
            local message="[$project_name][$mode_name] $title"
            if [ -n "$body" ]; then
                message="${message}\n${body}"
            fi
            local payload
            payload="$(json_escape "$message")"
            if ! curl -fsS -X POST "$DISCORD_WEBHOOK_URL" \
                -H 'Content-Type: application/json' \
                -d "{\"content\":\"${payload}\"}" >/dev/null 2>&1; then
                warn "Failed to send Discord notification"
                return 1
            fi
            return 0
            ;;
        *)
            warn "Unknown HUMAN_NOTIFY_CHANNEL: $raw_channel"
            return 1
            ;;
    esac
}

secure_build_approval_upfront() {
    if [ "$MODE" != "prepare" ]; then
        return 0
    fi
    if is_true "$AUTO_CONTINUE_BUILD"; then
        return 0
    fi
    if [ "$(to_lower "$BUILD_APPROVAL_POLICY")" != "upfront" ]; then
        return 0
    fi

    if ! is_interactive; then
        warn "Build approval policy is 'upfront' but this run is non-interactive."
        warn "Use --auto-continue-build or run with --build-approval on_ready."
        log_reason_code "RB_APPROVAL_UPFRONT_NON_INTERACTIVE" "upfront approval requires interactive mode or auto-continue-build"
        notify_human \
            "Build approval needed before prepare run" \
            "Re-run interactively to approve upfront, or use --auto-continue-build."
        return 1
    fi

    local answer
    while true; do
        answer=""
        read_user_line "Secure build approval now? Auto-enter build if prepare passes [y/n] (n): " answer
        case "$(to_lower "${answer:-n}")" in
            y|yes)
                AUTO_CONTINUE_BUILD=true
                ok "Upfront approval captured. Build will auto-start after prepare consensus."
                return 0
                ;;
            n|no)
                BUILD_APPROVAL_POLICY="on_ready"
                warn "Upfront approval skipped. Approval will be requested at prepare completion."
                return 0
                ;;
            *)
                echo "Please answer y or n."
                ;;
        esac
    done
}

request_build_permission() {
    if is_true "$AUTO_CONTINUE_BUILD"; then
        return 0
    fi

    if ! is_interactive; then
        warn "Prepare phase is complete, but human approval is required to enter build mode."
        warn "Run again with --auto-continue-build or restart in build mode manually."
        log_reason_code "RB_PREPARE_BUILD_APPROVAL_REQUIRED" "interactive approval required to transition from prepare to build"
        notify_human \
            "Build approval required" \
            "Prepare is complete. Approve with --auto-continue-build or run build manually."
        return 1
    fi

    local answer
    while true; do
        answer=""
        read_user_line "Preparation is complete. Begin build mode now? [y/n] (n): " answer
        case "$(to_lower "${answer:-n}")" in
            y|yes) return 0 ;;
            n|no)
                log_reason_code "RB_PREPARE_BUILD_APPROVAL_DECLINED" "human declined build transition"
                notify_human \
                    "Build approval declined" \
                    "Prepare completed but build was not approved in this run."
                return 1
                ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

markdown_artifacts_are_clean() {
    local leakage_pattern='succeeded in [0-9]+ms:|assistant[[:space:]]+to=|recipient_name"[[:space:]]*:|tokens used|mcp startup:'
    local file bad=0
    local files=()

    [ -f "$PLAN_FILE" ] && files+=("$PLAN_FILE")
    [ -f "$PROJECT_DIR/README.md" ] && files+=("$PROJECT_DIR/README.md")

    local research_files spec_files
    research_files="$(find "$RESEARCH_DIR" -maxdepth 2 -type f -name "*.md" 2>/dev/null || true)"
    while IFS= read -r file; do
        [ -n "$file" ] && files+=("$file")
    done <<< "$research_files"

    spec_files="$(find "$SPECS_DIR" -maxdepth 3 -type f -name "*.md" 2>/dev/null || true)"
    while IFS= read -r file; do
        [ -n "$file" ] && files+=("$file")
    done <<< "$spec_files"

    for file in "${files[@]}"; do
        [ -f "$file" ] || continue
        if grep -qiE "$leakage_pattern" "$file"; then
            warn "Detected tool transcript leakage in markdown artifact: $(path_for_display "$file")"
            bad=1
        fi
        if file_has_local_identity_leakage "$file"; then
            warn "Detected local identity/path leakage in markdown artifact: $(path_for_display "$file")"
            bad=1
        fi
    done

    [ "$bad" -eq 0 ]
}

plan_is_semantically_actionable() {
    local plan_file="$1"
    [ -f "$plan_file" ] || return 1

    # Keep this intentionally permissive: many repos already have a viable plan structure
    # ("Goal", "Definition of Done", task bullets) but not the exact headings used by
    # earlier validators. Brittleness here causes false negatives and loop thrash.
    local has_goal=false
    local has_validation=false
    local task_count=0

    if grep -qiE '(^|#{1,6}[[:space:]]*)(goal|scope|objectives?|overview|context)\b' "$plan_file" \
        || grep -qiE '^[[:space:]]*(goal|scope|objectives?|overview|context)[[:space:]]*:' "$plan_file"; then
        has_goal=true
    fi

    # Accept multiple common "done criteria" patterns.
    if grep -qiE '(^|#{1,6}[[:space:]]*)(validation|verification|acceptance criteria|success criteria|definition of done|readiness|qa|testing)\b' "$plan_file" \
        || grep -qiE '^[[:space:]]*(validation|verification|acceptance criteria|success criteria|definition of done|readiness|qa|testing)[[:space:]]*:' "$plan_file" \
        || grep -qiE '\b(build[- ]readiness|definition of done|acceptance criteria)\b' "$plan_file"; then
        has_validation=true
    fi

    task_count="$(plan_task_count "$plan_file")"

    if is_true "$has_goal" && is_true "$has_validation" && [ "${task_count:-0}" -ge 1 ]; then
        return 0
    fi
    return 1
}

plan_task_count() {
    local plan_file="$1"
    if [ ! -f "$plan_file" ]; then
        echo "0"
        return 0
    fi
    local count
    # grep returns exit code 1 when there are zero matches, even though -c prints 0.
    # Avoid echoing a second 0 via "|| echo 0" which would produce "0\\n0".
    count="$(grep -cE '^[[:space:]]*([0-9]+\.[[:space:]]|-[[:space:]]\[[ x]\][[:space:]]|-[[:space:]](Run|Add|Update|Implement|Fix|Verify|Test|Document|Research|Decide|Refactor|Remove|Deprecate)[[:space:]])' "$plan_file" 2>/dev/null || true)"
    if ! is_number "$count"; then
        count="0"
    fi
    echo "$count"
}

check_build_prerequisites() {
    local missing=()
    local spec_count=0
    local research_count=0
    local has_acceptance=false
    local spec_file missing_entry

    spec_count=$(find "$SPECS_DIR" -maxdepth 2 -type f \( -name "spec.md" -o -name "*.md" \) 2>/dev/null | wc -l | tr -d ' ')
    if [ "${spec_count:-0}" -eq 0 ]; then
        missing+=("spec files under specs/")
    else
        local spec_candidates
        spec_candidates="$(find "$SPECS_DIR" -maxdepth 3 -type f \( -name "spec.md" -o -name "*.md" \) 2>/dev/null || true)"
        while IFS= read -r spec_file; do
            if [ -n "$spec_file" ] && grep -qi 'acceptance criteria' "$spec_file" 2>/dev/null; then
                has_acceptance=true
                break
            fi
        done <<< "$spec_candidates"
        if ! is_true "$has_acceptance"; then
            missing+=("specs must include Acceptance Criteria sections")
        fi
    fi

    if [ ! -f "$PLAN_FILE" ]; then
        missing+=("IMPLEMENTATION_PLAN.md")
    elif ! plan_is_semantically_actionable "$PLAN_FILE"; then
        missing+=("IMPLEMENTATION_PLAN.md must include Goal + Done/Validation criteria + actionable tasks (checkboxes preferred)")
    fi

    research_count=$(find "$RESEARCH_DIR" -maxdepth 2 -type f -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
    if [ ! -f "$RESEARCH_SUMMARY_FILE" ] && [ "${research_count:-0}" -eq 0 ]; then
        missing+=("research notes (e.g. research/RESEARCH_SUMMARY.md)")
    elif [ -f "$RESEARCH_SUMMARY_FILE" ] && ! grep -qE '<confidence>[0-9]{1,3}</confidence>' "$RESEARCH_SUMMARY_FILE"; then
        missing+=("research/RESEARCH_SUMMARY.md must include a <confidence> tag")
    fi
    if [ ! -f "$RESEARCH_DIR/CODEBASE_MAP.md" ]; then
        missing+=("research/CODEBASE_MAP.md")
    fi
    if [ ! -f "$RESEARCH_DIR/DEPENDENCY_RESEARCH.md" ]; then
        missing+=("research/DEPENDENCY_RESEARCH.md")
    fi
    if [ ! -f "$RESEARCH_DIR/COVERAGE_MATRIX.md" ]; then
        missing+=("research/COVERAGE_MATRIX.md")
    fi

    if ! markdown_artifacts_are_clean; then
        missing+=("markdown artifacts must not contain tool transcript leakage or local identity/path leakage")
    fi

    local gitignore_missing=()
    local gitignore_missing_lines missing_entry
    gitignore_missing_lines="$(gitignore_missing_required_entries || true)"
    while IFS= read -r missing_entry; do
        [ -n "$missing_entry" ] && gitignore_missing+=("$missing_entry")
    done <<< "$gitignore_missing_lines"
    if [ "${#gitignore_missing[@]}" -gt 0 ]; then
        local missing_joined
        missing_joined="$(printf '%s,' "${gitignore_missing[@]}" | sed 's/,$//')"
        missing+=(".gitignore must include local/sensitive/runtime guardrails (missing: $missing_joined)")
    fi

    if [ "${#missing[@]}" -gt 0 ]; then
        warn "Build prerequisites are incomplete:"
        local entry
        for entry in "${missing[@]}"; do
            warn "  - $entry"
        done
        log_reason_code "RB_BUILD_PREREQ_MISSING" "one or more build prerequisites failed"
        write_gate_feedback "build-prerequisites" "${missing[@]}"
        return 1
    fi

    rm -f "$GATE_FEEDBACK_FILE" 2>/dev/null || true
    return 0
}

make_swarm_reviewer_prompt() {
    local stage="$1"
    local reviewer_index="$2"
    local reviewer_total="$3"
    local prompt_path="$4"
    local stage_goal

    case "$stage" in
        prepare-gate)
            stage_goal="Decide if preparation/research/specification is complete enough to start build mode."
            ;;
        build-gate)
            stage_goal="Decide if this repository is ready to enter autonomous build mode now."
            ;;
        test-gate)
            stage_goal="Decide if implementation quality/readiness justifies entering dedicated test-hardening mode."
            ;;
        refactor-gate)
            stage_goal="Decide if the codebase is stable enough to enter behavior-preserving refactor/simplification mode."
            ;;
        lint-gate)
            stage_goal="Decide if the repository is ready for lint/static analysis/documentation-quality finalization."
            ;;
        document-gate)
            stage_goal="Decide if the project is ready for final documentation updates and closure."
            ;;
        *)
            stage_goal="Evaluate project readiness and risk."
            ;;
    esac

    cat > "$prompt_path" <<EOF
# Independent Reviewer $reviewer_index/$reviewer_total

You are an independent reviewer in a multi-agent panel.
Goal: $stage_goal

## Review Inputs

Inspect these project artifacts:
- \`$CONSTITUTION_FILE\` (if present)
- \`$PLAN_FILE\` (if present)
- \`$SPECS_DIR\` (all specs)
- \`$RESEARCH_DIR\` (all research notes)
- \`README.md\` and other docs if present

When internet is available, you may verify approaches against reputable sources.
If internet is unavailable, continue with best-effort reasoning and explicitly note uncertainty.

## Evaluation Rules

1. Judge independently; do not assume other reviewers agree.
2. Score readiness from 0 to 100.
3. Use verdict GO only if major risks are controlled.
4. Use verdict HOLD when critical gaps remain.
5. Keep feedback concise and concrete.

## Required Output Format

Output exactly these tags:

\`<score>NN</score>\`
\`<verdict>GO|HOLD</verdict>\`
\`<summary>one short paragraph</summary>\`
\`<gaps>comma-separated critical gaps, or none</gaps>\`
\`<promise>DONE</promise>\`
EOF
}

run_swarm_consensus() {
    local stage="$1"
    local yolo_effective="$2"
    local swarm_size="${SWARM_SIZE:-1}"
    local swarm_parallel="${SWARM_MAX_PARALLEL:-1}"
    local retry_invalid="${SWARM_RETRY_INVALID_OUTPUT:-0}"
    local ts
    ts="$(date '+%Y%m%d_%H%M%S')"

    LAST_CONSENSUS_SCORE=0
    LAST_CONSENSUS_PASS=false
    LAST_CONSENSUS_GO_COUNT=0
    LAST_CONSENSUS_HOLD_COUNT=0
    LAST_CONSENSUS_REPORT=""
    LAST_CONSENSUS_PANEL_FAILURES=0

    if ! is_true "$SWARM_ENABLED"; then
        swarm_size=1
        swarm_parallel=1
    fi

    if ! is_number "$swarm_size" || [ "$swarm_size" -lt 1 ]; then
        swarm_size=1
    fi
    if ! is_number "$swarm_parallel" || [ "$swarm_parallel" -lt 1 ]; then
        swarm_parallel=1
    fi
    if [ "$swarm_parallel" -gt "$swarm_size" ]; then
        swarm_parallel="$swarm_size"
    fi
    if ! is_number "$retry_invalid"; then
        retry_invalid=0
    fi
    if [ "$retry_invalid" -lt 0 ]; then
        retry_invalid=0
    fi

    mkdir -p "$CONSENSUS_DIR"
    local prompts=()
    local logs=()
    local outputs=()
    local pids=()
    local i=1

    info "Running consensus panel for stage '$stage' (reviewers=$swarm_size, parallel=$swarm_parallel)"

    while [ "$i" -le "$swarm_size" ]; do
        local running_jobs
        running_jobs="$(count_running_pids "${pids[@]:-}")"
        while [ "${running_jobs:-0}" -ge "$swarm_parallel" ]; do
            sleep 0.1
            running_jobs="$(count_running_pids "${pids[@]:-}")"
        done

        local pfile lfile ofile
        pfile="$CONSENSUS_DIR/${stage}_${ts}_reviewer_${i}_prompt.md"
        lfile="$CONSENSUS_DIR/${stage}_${ts}_reviewer_${i}.log"
        ofile="$CONSENSUS_DIR/${stage}_${ts}_reviewer_${i}.out"
        make_swarm_reviewer_prompt "$stage" "$i" "$swarm_size" "$pfile"
        : > "$lfile"
        : > "$ofile"

        prompts+=("$pfile")
        logs+=("$lfile")
        outputs+=("$ofile")

        (
            run_agent_with_prompt "$pfile" "$lfile" "$ofile" "$yolo_effective"
        ) &
        pids+=("$!")

        i=$((i + 1))
    done

    local panel_failures=0
    local max_reviewer_failures="${CONSENSUS_MAX_REVIEWER_FAILURES:-0}"
    if ! is_number "$max_reviewer_failures"; then
        max_reviewer_failures=0
    fi
    local pid
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            panel_failures=$((panel_failures + 1))
        fi
    done

    # Retry reviewers that did not follow the required tagged output format.
    # Without this, malformed output becomes score=0 and distorts consensus.
    if [ "$retry_invalid" -gt 0 ]; then
        local idx attempt reviewer_no
        for idx in "${!outputs[@]}"; do
            reviewer_no=$((idx + 1))
            if reviewer_output_has_required_tags "${outputs[$idx]}"; then
                continue
            fi
            warn "Reviewer $reviewer_no output missing required tags; retrying up to $retry_invalid time(s)."
            attempt=1
            while [ "$attempt" -le "$retry_invalid" ]; do
                : > "${outputs[$idx]}"
                if run_agent_with_prompt "${prompts[$idx]}" "${logs[$idx]}" "${outputs[$idx]}" "$yolo_effective"; then
                    if reviewer_output_has_required_tags "${outputs[$idx]}"; then
                        break
                    fi
                fi
                attempt=$((attempt + 1))
            done
            if ! reviewer_output_has_required_tags "${outputs[$idx]}"; then
                panel_failures=$((panel_failures + 1))
                warn "Reviewer $reviewer_no still produced invalid output after retries; counting as panel failure."
            fi
        done
    fi

    local total_score=0
    local go_count=0
    local hold_count=0
    local reviewer_count=0
    local report_file="$CONSENSUS_DIR/${stage}_${ts}_consensus.md"

    {
        echo "# Consensus Report - $stage"
        echo ""
        echo "- Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "- Reviewers: $swarm_size"
        echo "- Parallel: $swarm_parallel"
        echo "- Panel failures (command or malformed output): $panel_failures"
        echo ""
        echo "## Reviewer Results"
        echo ""
    } > "$report_file"

    for i in "${!outputs[@]}"; do
        local reviewer_no score verdict summary gaps
        reviewer_no=$((i + 1))
        score="$(extract_reviewer_score "${outputs[$i]}" "${logs[$i]}")"
        verdict="$(extract_reviewer_verdict "${outputs[$i]}" "${logs[$i]}")"
        summary="$(extract_tag_value "summary" "${outputs[$i]}" "${logs[$i]}")"
        gaps="$(extract_tag_value "gaps" "${outputs[$i]}" "${logs[$i]}")"

        reviewer_count=$((reviewer_count + 1))
        total_score=$((total_score + score))
        if [ "$verdict" = "GO" ]; then
            go_count=$((go_count + 1))
        else
            hold_count=$((hold_count + 1))
        fi

        {
            echo "### Reviewer $reviewer_no"
            echo "- Score: $score"
            echo "- Verdict: $verdict"
            if [ -n "$summary" ]; then
                echo "- Summary: $summary"
            fi
            if [ -n "$gaps" ]; then
                echo "- Gaps: $gaps"
            fi
            echo ""
        } >> "$report_file"
    done

    local avg_score=0
    if [ "$reviewer_count" -gt 0 ]; then
        avg_score=$((total_score / reviewer_count))
    fi

    LAST_CONSENSUS_SCORE="$avg_score"
    LAST_CONSENSUS_GO_COUNT="$go_count"
    LAST_CONSENSUS_HOLD_COUNT="$hold_count"
    LAST_CONSENSUS_REPORT="$report_file"
    LAST_CONSENSUS_PANEL_FAILURES="$panel_failures"

    if [ "$panel_failures" -gt "$max_reviewer_failures" ]; then
        LAST_CONSENSUS_PASS=false
        warn "Consensus invalidated due to reviewer command failures: $panel_failures > $max_reviewer_failures"
        log_reason_code "RB_CONSENSUS_PANEL_FAILURE_THRESHOLD" "panel_failures=$panel_failures max_allowed=$max_reviewer_failures"
    elif [ "$avg_score" -ge "$MIN_CONSENSUS_SCORE" ] && [ "$go_count" -gt "$hold_count" ]; then
        LAST_CONSENSUS_PASS=true
    else
        LAST_CONSENSUS_PASS=false
    fi

    {
        echo "## Final Consensus"
        echo ""
        echo "- Average score: $avg_score"
        echo "- GO votes: $go_count"
        echo "- HOLD votes: $hold_count"
        echo "- Threshold: $MIN_CONSENSUS_SCORE"
        echo "- Max reviewer failures: $max_reviewer_failures"
        echo "- Reviewer failures observed: $panel_failures"
        echo "- Pass: $LAST_CONSENSUS_PASS"
    } >> "$report_file"

    if is_true "$LAST_CONSENSUS_PASS"; then
        rm -f "$GATE_FEEDBACK_FILE" 2>/dev/null || true
    else
        write_gate_feedback "consensus:${stage}" \
            "average score: ${avg_score} (threshold: ${MIN_CONSENSUS_SCORE})" \
            "GO votes: ${go_count}" \
            "HOLD votes: ${hold_count}" \
            "panel failures: ${panel_failures} (max allowed: ${max_reviewer_failures})" \
            "report: $(path_for_display "$report_file")"
    fi

    info "Consensus score: $LAST_CONSENSUS_SCORE (GO=$LAST_CONSENSUS_GO_COUNT HOLD=$LAST_CONSENSUS_HOLD_COUNT)"
    info "Consensus report: $(path_for_display "$LAST_CONSENSUS_REPORT")"
}

enforce_build_gate() {
    local yolo_effective="$1"

    if is_true "$FORCE_BUILD"; then
        warn "Build gate bypassed with --force-build."
        log_reason_code "RB_BUILD_GATE_FORCE_BYPASS" "force-build bypassed gate checks"
        return 0
    fi

    if ! check_build_prerequisites; then
        err "Build mode requires specs + research + implementation plan."
        err "Run './ralphie.sh prepare' to generate these artifacts."
        log_reason_code "RB_BUILD_GATE_PREREQ_FAILED" "build prerequisites failed"
        return 1
    fi

    run_swarm_consensus "build-gate" "$yolo_effective"
    if is_true "$LAST_CONSENSUS_PASS"; then
        ok "Build gate passed (score: $LAST_CONSENSUS_SCORE)."
        return 0
    fi

    warn "Build gate did not reach consensus threshold."
    warn "Score: $LAST_CONSENSUS_SCORE (threshold: $MIN_CONSENSUS_SCORE)"
    log_reason_code "RB_BUILD_GATE_CONSENSUS_FAILED" "consensus score=$LAST_CONSENSUS_SCORE go=$LAST_CONSENSUS_GO_COUNT hold=$LAST_CONSENSUS_HOLD_COUNT panel_failures=$LAST_CONSENSUS_PANEL_FAILURES"
    if [ -n "$LAST_CONSENSUS_REPORT" ]; then
        warn "Review report: $(path_for_display "$LAST_CONSENSUS_REPORT")"
    fi

    if ! is_interactive; then
        return 1
    fi

    local answer
    while true; do
        answer=""
        read_user_line "Consensus is low. Proceed anyway? [y/n] (n): " answer
        case "$(to_lower "${answer:-n}")" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

maybe_collect_human_feedback() {
    local iteration="$1"
    local confidence="$2"
    local stagnation="$3"
    local needs_human="$4"
    local human_question="$5"
    local last_escalation="$6"

    if ! is_interactive; then
        echo "$last_escalation"
        return
    fi

    local should_ask=false
    if is_true "$needs_human"; then
        should_ask=true
    elif [ "$confidence" -lt "$CONFIDENCE_TARGET" ] && [ "$stagnation" -ge "$CONFIDENCE_STAGNATION_LIMIT" ]; then
        if [ $((iteration - last_escalation)) -ge "$CONFIDENCE_STAGNATION_LIMIT" ]; then
            should_ask=true
        fi
    fi

    if ! is_true "$should_ask"; then
        echo "$last_escalation"
        return
    fi

    mkdir -p "$RESEARCH_DIR"
    local prompt
    if [ -n "$human_question" ]; then
        prompt="$human_question"
    else
        prompt="Planner confidence has stalled. Add one clarifying note (or press Enter to skip):"
    fi

    echo ""
    warn "Planner requests focused human input."
    echo "$prompt"
    local note
    note=""
    read_user_line "> " note
    if [ -n "$note" ]; then
        {
            echo "## $(date '+%Y-%m-%d %H:%M:%S')"
            echo "$note"
            echo ""
        } >> "$RESEARCH_DIR/HUMAN_FEEDBACK.md"
        ok "Saved feedback to $RESEARCH_DIR/HUMAN_FEEDBACK.md"
    fi
    echo "$iteration"
}

effective_yolo_mode() {
    if [ -n "$YOLO_OVERRIDE" ]; then
        echo "$YOLO_OVERRIDE"
    else
        echo "$YOLO_MODE"
    fi
}

effective_auto_update_enabled() {
    if [ -n "$AUTO_UPDATE_OVERRIDE" ]; then
        echo "$AUTO_UPDATE_OVERRIDE"
    else
        echo "$AUTO_UPDATE_ENABLED"
    fi
}

effective_auto_update_url() {
    if [ -n "$AUTO_UPDATE_URL_OVERRIDE" ]; then
        echo "$AUTO_UPDATE_URL_OVERRIDE"
    elif [ -n "$AUTO_UPDATE_URL" ]; then
        echo "$AUTO_UPDATE_URL"
    else
        echo "$DEFAULT_AUTO_UPDATE_URL"
    fi
}

download_url_to_file() {
    local url="$1"
    local dest="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 2 --max-time 10 "$url" -o "$dest"
        return $?
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q -O "$dest" "$url"
        return $?
    fi
    return 127
}

auto_update_candidate_is_valid() {
    local file="$1"
    [ -f "$file" ] || return 1
    if ! head -n 1 "$file" 2>/dev/null | grep -qE '^#!/usr/bin/env[[:space:]]+bash'; then
        return 1
    fi
    if ! grep -qF 'Ralphie - Unified autonomous loop for Codex and Claude Code' "$file" 2>/dev/null; then
        return 1
    fi
    return 0
}

maybe_auto_update_self() {
    # Best-effort, never block the run on update failures.
    if [ "${RALPHIE_LIB:-0}" = "1" ]; then
        return 0
    fi
    if is_true "${RALPHIE_SKIP_AUTO_UPDATE:-false}"; then
        return 0
    fi

    local enabled url
    enabled="$(effective_auto_update_enabled)"
    if ! is_true "$enabled"; then
        return 0
    fi

    url="$(effective_auto_update_url)"
    url="$(printf '%s' "$url" | tr -d '[:space:]')"
    if [ -z "$url" ]; then
        return 0
    fi

    local self_base self_dir self_path
    self_base="${BASH_SOURCE[0]:-$0}"
    if [ -z "$self_base" ]; then
        return 0
    fi
    self_dir="$(cd "$(dirname "$self_base")" 2>/dev/null && pwd)"
    self_path="$self_dir/$(basename "$self_base")"
    if [ ! -f "$self_path" ]; then
        return 0
    fi

    mkdir -p "$CONFIG_DIR" "$READY_ARCHIVE_DIR" 2>/dev/null || true
    local tmp_file
    tmp_file="$(mktemp "$CONFIG_DIR/ralphie_update.XXXXXX" 2>/dev/null || mktemp 2>/dev/null || echo "")"
    if [ -z "$tmp_file" ]; then
        return 0
    fi

    local fetch_rc=0
    if download_url_to_file "$url" "$tmp_file" >/dev/null 2>&1; then
        fetch_rc=0
    else
        fetch_rc=$?
    fi
    if [ "$fetch_rc" -eq 127 ]; then
        warn "Auto-update enabled but neither curl nor wget is available; skipping."
        rm -f "$tmp_file" 2>/dev/null || true
        return 0
    fi
    if [ "$fetch_rc" -ne 0 ]; then
        rm -f "$tmp_file" 2>/dev/null || true
        return 0
    fi

    if ! auto_update_candidate_is_valid "$tmp_file"; then
        warn "Auto-update downloaded unexpected content; skipping."
        rm -f "$tmp_file" 2>/dev/null || true
        return 0
    fi

    if cmp -s "$tmp_file" "$self_path" 2>/dev/null; then
        rm -f "$tmp_file" 2>/dev/null || true
        return 0
    fi

    local ts backup_file
    ts="$(date '+%Y%m%d_%H%M%S')"
    backup_file="$READY_ARCHIVE_DIR/ralphie_sh_backup_${ts}.sh"
    if ! cp "$self_path" "$backup_file" 2>/dev/null; then
        warn "Auto-update could not write backup; skipping."
        rm -f "$tmp_file" 2>/dev/null || true
        return 0
    fi

    chmod +x "$tmp_file" 2>/dev/null || true
    if ! mv "$tmp_file" "$self_path" 2>/dev/null; then
        warn "Auto-update could not replace script; skipping."
        rm -f "$tmp_file" 2>/dev/null || true
        return 0
    fi

    info "Auto-update applied; re-executing latest ralphie.sh."
    exec env RALPHIE_SKIP_AUTO_UPDATE=1 "$self_path" "$@"
}

prompt_file_for_mode() {
    local mode="$1"
    case "$mode" in
        build) echo "$PROMPT_BUILD_FILE" ;;
        plan) echo "$PROMPT_PLAN_FILE" ;;
        prepare) echo "$PROMPT_PREPARE_FILE" ;;
        test) echo "$PROMPT_TEST_FILE" ;;
        refactor) echo "$PROMPT_REFACTOR_FILE" ;;
        lint) echo "$PROMPT_LINT_FILE" ;;
        document) echo "$PROMPT_DOCUMENT_FILE" ;;
        *) echo "" ;;
    esac
}

consensus_stage_for_mode() {
    local mode="$1"
    case "$mode" in
        build) echo "build-gate" ;;
        test) echo "test-gate" ;;
        refactor) echo "refactor-gate" ;;
        lint) echo "lint-gate" ;;
        document) echo "document-gate" ;;
        *) echo "" ;;
    esac
}

switch_mode_with_prompt() {
    local target_mode="$1"
    local target_prompt
    target_prompt="$(prompt_file_for_mode "$target_mode")"
    if [ -z "$target_prompt" ] || [ ! -f "$target_prompt" ]; then
        err "Prompt file not found for mode '$target_mode': $(path_for_display "$target_prompt")"
        return 1
    fi
    MODE="$target_mode"
    prompt_file="$target_prompt"
    return 0
}

gate_transition_or_rewind() {
    local from_mode="$1"
    local to_mode="$2"
    local yolo_effective="$3"
    local stage

    stage="$(consensus_stage_for_mode "$to_mode")"
    if [ -z "$stage" ]; then
        return 0
    fi

    info "Consensus gate before transition: $from_mode -> $to_mode"
    run_swarm_consensus "$stage" "$yolo_effective"
    if is_true "$LAST_CONSENSUS_PASS"; then
        return 0
    fi

    warn "Consensus gate failed for transition $from_mode -> $to_mode. Returning to $from_mode."
    log_reason_code "RB_PHASE_TRANSITION_CONSENSUS_FAILED" "from=$from_mode to=$to_mode score=$LAST_CONSENSUS_SCORE go=$LAST_CONSENSUS_GO_COUNT hold=$LAST_CONSENSUS_HOLD_COUNT panel_failures=$LAST_CONSENSUS_PANEL_FAILURES"
    switch_mode_with_prompt "$from_mode" || return 1
    return 1
}

run_bootstrap_scripts_if_applicable() {
    local bootstrap_scripts=()
    local script

    if [ -d "$PROJECT_DIR/scripts" ]; then
        local scripts_list
        scripts_list="$(find "$PROJECT_DIR/scripts" -maxdepth 1 -type f -name 'bootstrap*.sh' 2>/dev/null | sort || true)"
        while IFS= read -r script; do
            [ -n "$script" ] && bootstrap_scripts+=("$script")
        done <<< "$scripts_list"
    fi

    if [ "${#bootstrap_scripts[@]}" -eq 0 ]; then
        info "No bootstrap scripts detected; skipping bootstrap phase."
        return 0
    fi

    for script in "${bootstrap_scripts[@]}"; do
        info "Running bootstrap script: $(path_for_display "$script")"
        if ! bash "$script"; then
            err "Bootstrap script failed: $(path_for_display "$script")"
            log_reason_code "RB_BOOTSTRAP_SCRIPT_FAILURE" "script=$(path_for_display "$script")"
            return 1
        fi
    done

    ok "Bootstrap scripts completed."
    return 0
}

prepare_prompt_for_iteration() {
    local base_prompt="$1"
    local iteration="$2"
    local out="$base_prompt"
    local needs_augmented_prompt=false
    local context_reference=""
    if [ -n "$CONTEXT_FILE" ]; then
        context_reference="$(path_for_display "$CONTEXT_FILE")"
    fi

    if [ -n "$CONTEXT_FILE" ] || [ -f "$AGENT_SOURCE_MAP_FILE" ] || [ -f "$BINARY_STEERING_MAP_FILE" ] || [ -f "$HUMAN_INSTRUCTIONS_FILE" ] || [ -f "$GATE_FEEDBACK_FILE" ]; then
        needs_augmented_prompt=true
    fi

    if is_true "$needs_augmented_prompt"; then
        out="$LOG_DIR/ralphie_prompt_iter_${iteration}_$(date '+%Y%m%d_%H%M%S').md"
        cat "$base_prompt" > "$out"
    fi

    if { [ "${MODE:-}" = "prepare" ] || [ "${MODE:-}" = "plan" ]; } && is_true "$needs_augmented_prompt"; then
        cat >>"$out" <<EOF

---
$(readiness_rubric_for_prompt)
EOF
    fi

    if [ -f "$GATE_FEEDBACK_FILE" ] && is_true "$needs_augmented_prompt"; then
        cat >>"$out" <<EOF

---
## Last Gate Feedback

The orchestrator wrote the following gate feedback. Use it to fix blockers before emitting \`<promise>DONE</promise>\`:
EOF
        # Keep prompt size bounded (best-effort).
        tail -n 120 "$GATE_FEEDBACK_FILE" >>"$out" 2>/dev/null || true
    fi

    if [ -n "$CONTEXT_FILE" ]; then
        cat >> "$out" <<EOF

---
## External Context

You have an external context file at:
\`$context_reference\`

Privacy guard:
- Never copy absolute workstation paths or local usernames into durable artifacts.

Treat it as environment data. Inspect only relevant slices with tools like:
- \`rg -n "pattern" "$context_reference"\`
- \`sed -n 'START,ENDp' "$context_reference"\`
EOF
    fi

    if [ -f "$AGENT_SOURCE_MAP_FILE" ]; then
        cat >> "$out" <<EOF

---
## Source Map Heuristics

A source map with heuristic tools is available at:
\`$AGENT_SOURCE_MAP_REL\`

Use it to improve \`ralphie.sh\` without overfitting:
- Read scoring dimensions and anti-overfit rules before proposing script changes.
- Sample evidence from both \`$SUBREPOS_DIR_REL/codex\` and \`$SUBREPOS_DIR_REL/claude-code\`.
- Keep self-improvement bounded by the map's iteration policy.
- Write concise hypothesis/result entries to \`$SELF_IMPROVEMENT_LOG_REL\`.
EOF
    fi

    if [ -f "$BINARY_STEERING_MAP_FILE" ]; then
        cat >> "$out" <<EOF

---
## Binary Steering References

A binary steering map is available at:
\`$BINARY_STEERING_MAP_REL\`

Use it to steer engine-specific invocations safely:
- Validate command/flag assumptions against the mapped source references.
- Keep mode behavior portable between Codex and Claude.
- Prefer neutral orchestration; isolate engine-specific flags to execution boundaries.
EOF
    fi

    if [ -f "$HUMAN_INSTRUCTIONS_FILE" ]; then
        cat >> "$out" <<EOF

---
## Human Priority Queue

A human priority file is available at:
\`$HUMAN_INSTRUCTIONS_REL\`

Rules:
- Treat entries with \`Status: NEW\` as highest-priority candidate work.
- Process one request at a time.
- Reflect accepted requests in specs/plan before implementation.
- If a request is ambiguous, ask one concise clarification.

Current human queue:

EOF
        cat "$HUMAN_INSTRUCTIONS_FILE" >> "$out"
    fi

    echo "$out"
}

run_idle_plan_refresh() {
    local yolo_effective="$1"
    local build_iteration="$2"

    if [ ! -f "$PROMPT_PLAN_FILE" ]; then
        warn "Idle plan refresh skipped: prompt file not found: $PROMPT_PLAN_FILE"
        log_reason_code "RB_IDLE_PLAN_PROMPT_MISSING" "prompt=$PROMPT_PLAN_FILE"
        return 1
    fi

    local plan_log_file plan_output_file plan_prompt exit_code signal
    plan_log_file="$LOG_DIR/ralphie_plan_idle_from_build_${build_iteration}_$(date '+%Y%m%d_%H%M%S').log"
    plan_output_file="$LOG_DIR/ralphie_plan_idle_output_from_build_${build_iteration}_$(date '+%Y%m%d_%H%M%S').txt"
    touch "$plan_log_file" "$plan_output_file"

    info "No work items found. Running one planning iteration to refresh work queue."
    plan_prompt="$(prepare_prompt_for_iteration "$PROMPT_PLAN_FILE" "idle-plan-${build_iteration}")"

    if run_agent_with_prompt "$plan_prompt" "$plan_log_file" "$plan_output_file" "$yolo_effective"; then
        signal="$(detect_completion_signal "$plan_log_file" "$plan_output_file" || true)"
        if [ -z "$signal" ]; then
            warn "Idle plan refresh finished without completion signal."
            log_reason_code "RB_IDLE_PLAN_NO_COMPLETION_SIGNAL" "build_iteration=$build_iteration"
            return 1
        fi
        if [ ! -f "$PLAN_FILE" ]; then
            warn "Idle plan refresh reported DONE but plan file is missing: $PLAN_FILE"
            log_reason_code "RB_IDLE_PLAN_PLAN_MISSING" "build_iteration=$build_iteration plan=$PLAN_FILE"
            return 1
        fi

        ok "Idle plan refresh complete: $signal"
        return 0
    fi

    exit_code=$?
    if [ "$exit_code" -eq 124 ] || [ "$exit_code" -eq 137 ]; then
        warn "Idle plan refresh timed out after ${COMMAND_TIMEOUT_SECONDS}s (exit $exit_code)."
        log_reason_code "RB_IDLE_PLAN_TIMEOUT" "build_iteration=$build_iteration exit_code=$exit_code timeout=${COMMAND_TIMEOUT_SECONDS}s"
    else
        warn "Idle plan refresh failed (exit $exit_code)."
        log_reason_code "RB_IDLE_PLAN_EXEC_FAILURE" "build_iteration=$build_iteration exit_code=$exit_code"
    fi
    return 1
}

detect_completion_signal() {
    local _log_file="${1:-}"
    local output_file="$2"
    local signal=""

    if [ -f "$output_file" ] && grep -qE '^[[:space:]]*<promise>(ALL_)?DONE</promise>[[:space:]]*$' "$output_file"; then
        signal=$(grep -oE '<promise>(ALL_)?DONE</promise>' "$output_file" | tail -1)
        echo "$signal"
        return 0
    fi

    echo ""
    return 1
}

guess_work_item_name() {
    if [ "${#INCOMPLETE_SPECS[@]}" -gt 0 ]; then
        basename "$(dirname "${INCOMPLETE_SPECS[0]}")"
        return
    fi
    echo "work-item"
}

write_completion_log() {
    local iteration="$1"
    local signal="$2"
    local item
    item="$(guess_work_item_name)"

    local timestamp safe_item file
    timestamp=$(date '+%Y-%m-%d--%H-%M-%S')
    safe_item=$(printf '%s' "$item" | sed 's/[^a-zA-Z0-9_-]/-/g; s/--*/-/g')
    file="$COMPLETION_LOG_DIR/${timestamp}--${safe_item}.md"

    cat > "$file" <<EOF
# Completion Log

- Timestamp: $(date '+%Y-%m-%d %H:%M:%S')
- Iteration: $iteration
- Item: $item
- Signal: $signal
- Engine: $ACTIVE_ENGINE
EOF
}

push_if_ahead() {
    if ! is_true "$GIT_AUTONOMY"; then
        return
    fi
    if ! command -v git >/dev/null 2>&1; then
        return
    fi
    if ! git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
        return
    fi

    local branch
    branch=$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null || true)
    if [ -z "$branch" ]; then
        return
    fi

    git -C "$PROJECT_DIR" push origin "$branch" >/dev/null 2>&1 || {
        git -C "$PROJECT_DIR" push -u origin "$branch" >/dev/null 2>&1 || true
    }
}

show_status() {
    local pending_human
    pending_human="$(count_pending_human_requests)"
    echo ""
    echo "Ralphie Status"
    echo "  Script:            $SCRIPT_VERSION"
    echo "  Config:            $(path_for_display "$CONFIG_FILE") ($( [ -f "$CONFIG_FILE" ] && echo present || echo missing ))"
    echo "  Project:           $PROJECT_NAME"
    echo "  Type:              $PROJECT_TYPE"
    echo "  Stack:             $STACK_SUMMARY"
    echo "  Engine (default):  $ENGINE_PREF"
    echo "  Codex model:       ${CODEX_MODEL:-default}"
    echo "  Claude model:      ${CLAUDE_MODEL:-default}"
    echo "  Auto update:       $(effective_auto_update_enabled)"
    echo "  Update url:        $(effective_auto_update_url)"
    echo "  YOLO:              $YOLO_MODE"
    echo "  Git autonomy:      $GIT_AUTONOMY"
    echo "  Build approval:    $BUILD_APPROVAL_POLICY"
    echo "  Auto backfill:     $AUTO_PREPARE_BACKFILL_ON_IDLE_BUILD"
    echo "  Interrupt menu:    $INTERRUPT_MENU_ENABLED"
    echo "  Notify channel:    $HUMAN_NOTIFY_CHANNEL"
    echo "  Lock wait:         ${LOCK_WAIT_SECONDS}s"
    echo "  GitHub issues:     $ENABLE_GITHUB_ISSUES"
    echo "  Swarm enabled:     $SWARM_ENABLED"
    echo "  Swarm size:        $SWARM_SIZE"
    echo "  Swarm max parallel:$SWARM_MAX_PARALLEL"
    echo "  Swarm retry invalid:$SWARM_RETRY_INVALID_OUTPUT"
    echo "  Min consensus:     $MIN_CONSENSUS_SCORE"
    echo "  Max reviewer fail: $CONSENSUS_MAX_REVIEWER_FAILURES"
    echo "  Confidence target: $CONFIDENCE_TARGET"
    echo "  Human file:        $HUMAN_INSTRUCTIONS_REL ($( [ -f "$HUMAN_INSTRUCTIONS_FILE" ] && echo present || echo missing ))"
    echo "  Human pending:     $pending_human"
    echo "  Skip node prompt:  $SKIP_BOOTSTRAP_NODE_TOOLCHAIN"
    echo "  Skip codex prompt: $SKIP_BOOTSTRAP_CHUTES_CODEX"
    echo "  Skip claude prompt:$SKIP_BOOTSTRAP_CHUTES_CLAUDE"
    if [ -n "${GITHUB_REPO:-}" ]; then
        echo "  GitHub repo:       $GITHUB_REPO"
    fi
    echo "  Constitution:      $(path_for_display "$CONSTITUTION_FILE") ($( [ -f "$CONSTITUTION_FILE" ] && echo present || echo missing ))"
    echo "  Build prompt:      $(path_for_display "$PROMPT_BUILD_FILE") ($( [ -f "$PROMPT_BUILD_FILE" ] && echo present || echo missing ))"
    echo "  Plan prompt:       $(path_for_display "$PROMPT_PLAN_FILE") ($( [ -f "$PROMPT_PLAN_FILE" ] && echo present || echo missing ))"
    echo "  Prepare prompt:    $(path_for_display "$PROMPT_PREPARE_FILE") ($( [ -f "$PROMPT_PREPARE_FILE" ] && echo present || echo missing ))"
    echo "  Test prompt:       $(path_for_display "$PROMPT_TEST_FILE") ($( [ -f "$PROMPT_TEST_FILE" ] && echo present || echo missing ))"
    echo "  Refactor prompt:   $(path_for_display "$PROMPT_REFACTOR_FILE") ($( [ -f "$PROMPT_REFACTOR_FILE" ] && echo present || echo missing ))"
    echo "  Lint prompt:       $(path_for_display "$PROMPT_LINT_FILE") ($( [ -f "$PROMPT_LINT_FILE" ] && echo present || echo missing ))"
    echo "  Document prompt:   $(path_for_display "$PROMPT_DOCUMENT_FILE") ($( [ -f "$PROMPT_DOCUMENT_FILE" ] && echo present || echo missing ))"
    echo "  Source map:        $AGENT_SOURCE_MAP_REL ($( [ -f "$AGENT_SOURCE_MAP_FILE" ] && echo present || echo missing ))"
    echo "  Steering map:      $BINARY_STEERING_MAP_REL ($( [ -f "$BINARY_STEERING_MAP_FILE" ] && echo present || echo missing ))"
    echo "  Subrepos dir:      $SUBREPOS_DIR_REL ($( [ -d "$SUBREPOS_DIR" ] && echo present || echo missing ))"
    echo ""
}

show_doctor() {
    local codex_cmd claude_cmd timeout_cmd
    local pending_human
    codex_cmd="${CODEX_CMD:-codex}"
    claude_cmd="${CLAUDE_CMD:-claude}"
    timeout_cmd="$(get_timeout_command)"
    pending_human="$(count_pending_human_requests)"

    echo ""
    echo "Ralphie Doctor"
    echo "  Script version:   $SCRIPT_VERSION"
    echo "  Project dir:      $(path_for_display "$PROJECT_DIR")"
    echo "  Config present:   $( [ -f "$CONFIG_FILE" ] && echo yes || echo no )"
    echo "  Constitution:     $( [ -f "$CONSTITUTION_FILE" ] && echo yes || echo no )"
    echo "  Build prompt:     $( [ -f "$PROMPT_BUILD_FILE" ] && echo yes || echo no )"
    echo "  Plan prompt:      $( [ -f "$PROMPT_PLAN_FILE" ] && echo yes || echo no )"
    echo "  Prepare prompt:   $( [ -f "$PROMPT_PREPARE_FILE" ] && echo yes || echo no )"
    echo "  Test prompt:      $( [ -f "$PROMPT_TEST_FILE" ] && echo yes || echo no )"
    echo "  Refactor prompt:  $( [ -f "$PROMPT_REFACTOR_FILE" ] && echo yes || echo no )"
    echo "  Lint prompt:      $( [ -f "$PROMPT_LINT_FILE" ] && echo yes || echo no )"
    echo "  Document prompt:  $( [ -f "$PROMPT_DOCUMENT_FILE" ] && echo yes || echo no )"
    echo "  Build approval:   $BUILD_APPROVAL_POLICY"
    echo "  Auto backfill:    $AUTO_PREPARE_BACKFILL_ON_IDLE_BUILD"
    echo "  Interrupt menu:   $INTERRUPT_MENU_ENABLED"
    echo "  Auto update:      $(effective_auto_update_enabled)"
    echo "  Update url:       $(effective_auto_update_url)"
    echo "  Codex model:      ${CODEX_MODEL:-default}"
    echo "  Claude model:     ${CLAUDE_MODEL:-default}"
    echo "  Notify channel:   $HUMAN_NOTIFY_CHANNEL"
    echo "  Lock wait:        ${LOCK_WAIT_SECONDS}s"
    echo "  Plan file:        $( [ -f "$PLAN_FILE" ] && echo yes || echo no )"
    echo "  Research summary: $( [ -f "$RESEARCH_SUMMARY_FILE" ] && echo yes || echo no )"
    echo "  Source map:       $( [ -f "$AGENT_SOURCE_MAP_FILE" ] && echo yes || echo no )"
    echo "  Steering map:     $( [ -f "$BINARY_STEERING_MAP_FILE" ] && echo yes || echo no )"
    echo "  Human file:       $( [ -f "$HUMAN_INSTRUCTIONS_FILE" ] && echo yes || echo no )"
    echo "  Human pending:    $pending_human"
    echo "  Skip node prompt: $SKIP_BOOTSTRAP_NODE_TOOLCHAIN"
    echo "  Skip codex prompt:$SKIP_BOOTSTRAP_CHUTES_CODEX"
    echo "  Skip claude prompt:$SKIP_BOOTSTRAP_CHUTES_CLAUDE"
    echo "  Codex subrepo:    $( [ -d "$SUBREPOS_DIR/codex" ] && echo yes || echo no )"
    echo "  Claude subrepo:   $( [ -d "$SUBREPOS_DIR/claude-code" ] && echo yes || echo no )"
    echo "  Spec files:       $(find "$SPECS_DIR" -maxdepth 2 -type f \( -name "spec.md" -o -name "*.md" \) 2>/dev/null | wc -l | tr -d ' ')"
    echo "  Codex CLI:        $( command -v "$codex_cmd" >/dev/null 2>&1 && echo "yes ($codex_cmd)" || echo "no" )"
    echo "  Claude CLI:       $( command -v "$claude_cmd" >/dev/null 2>&1 && echo "yes ($claude_cmd)" || echo "no" )"
    echo "  Git CLI:          $( command -v git >/dev/null 2>&1 && echo yes || echo no )"
    echo "  Git repo:         $( git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1 && echo yes || echo no )"
    echo "  GH CLI:           $( command -v gh >/dev/null 2>&1 && echo yes || echo no )"
    echo "  GH auth:          $( command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 && echo yes || echo no )"
    echo "  Timeout support:  $( [ -n "$timeout_cmd" ] && echo "$timeout_cmd" || echo no )"
    echo "  Current lock:     $( [ -f "$LOCK_FILE" ] && path_for_display "$LOCK_FILE" || echo none )"
    echo "  State file:       $( [ -f "$STATE_FILE" ] && echo "yes ($(path_for_display "$STATE_FILE"))" || echo no )"
    if [ -f "$STATE_FILE" ]; then
        echo "  Last mode:        $(read_state_value mode)"
        echo "  Last stage:       $(read_state_value stage)"
        echo "  Last reason:      $(read_state_value last_reason_code)"
    fi
    echo "  Swarm retry invalid:$SWARM_RETRY_INVALID_OUTPUT"
    echo "  Max reviewer fail:$CONSENSUS_MAX_REVIEWER_FAILURES"
    echo ""
}

handle_sigterm() {
    echo ""
    warn "Termination signal received. Releasing lock and exiting."
    release_lock
    exit 143
}

handle_interrupt() {
    echo ""

    if ! is_true "$INTERRUPT_MENU_ENABLED" || ! is_interactive; then
        warn "Interrupted. Releasing lock and exiting."
        release_lock
        exit 130
    fi

    trap - INT
    while true; do
        echo "Interrupt menu: [r]esume, [h]uman instructions, [s]tatus, [q]uit"
        local choice
        choice=""
        read_user_line "Choice [r]: " choice
        choice="${choice:-r}"
        case "$(to_lower "${choice:-r}")" in
            ''|r|resume)
                ok "Resuming loop."
                trap handle_interrupt INT
                return 0
                ;;
            h|human|instruction|instructions)
                capture_human_priorities || warn "Unable to capture human priorities from interrupt menu."
                ;;
            s|status)
                show_status
                ;;
            q|quit|exit)
                warn "Interrupted. Releasing lock and exiting."
                release_lock
                exit 130
                ;;
            *)
                echo "Please choose r, h, s, or q."
                ;;
        esac
    done
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            prepare)
                MODE="prepare"
                MODE_EXPLICIT=true
                if [ "${2:-}" != "" ] && is_number "${2:-}"; then
                    MAX_ITERATIONS="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            plan)
                MODE="plan"
                MODE_EXPLICIT=true
                if [ "${2:-}" != "" ] && is_number "${2:-}"; then
                    MAX_ITERATIONS="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            build)
                MODE="build"
                MODE_EXPLICIT=true
                shift
                ;;
            test)
                MODE="test"
                MODE_EXPLICIT=true
                if [ "${2:-}" != "" ] && is_number "${2:-}"; then
                    MAX_ITERATIONS="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            refactor)
                MODE="refactor"
                MODE_EXPLICIT=true
                if [ "${2:-}" != "" ] && is_number "${2:-}"; then
                    MAX_ITERATIONS="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            lint)
                MODE="lint"
                MODE_EXPLICIT=true
                if [ "${2:-}" != "" ] && is_number "${2:-}"; then
                    MAX_ITERATIONS="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            document)
                MODE="document"
                MODE_EXPLICIT=true
                if [ "${2:-}" != "" ] && is_number "${2:-}"; then
                    MAX_ITERATIONS="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            --mode)
                require_arg_value "--mode" "${2:-}"
                MODE="${2:-}"
                MODE_EXPLICIT=true
                shift 2
                ;;
            --max)
                require_arg_value "--max" "${2:-}"
                MAX_ITERATIONS="${2:-0}"
                shift 2
                ;;
            --engine)
                require_arg_value "--engine" "${2:-}"
                ENGINE_OVERRIDE="${2:-}"
                shift 2
                ;;
            --codex-model)
                require_arg_value "--codex-model" "${2:-}"
                CODEX_MODEL="${2:-}"
                shift 2
                ;;
            --claude-model)
                require_arg_value "--claude-model" "${2:-}"
                CLAUDE_MODEL="${2:-}"
                shift 2
                ;;
            --setup)
                FORCE_SETUP=true
                shift
                ;;
            --setup-and-run)
                FORCE_SETUP=true
                SETUP_AND_RUN=true
                shift
                ;;
            --ready)
                READY_MODE=true
                shift
                ;;
            --ready-and-run)
                READY_MODE=true
                READY_AND_RUN=true
                shift
                ;;
            --clean)
                CLEAN_MODE=true
                shift
                ;;
            --clean-deep)
                CLEAN_DEEP_MODE=true
                shift
                ;;
            --human)
                HUMAN_MODE=true
                shift
                ;;
            --status)
                SHOW_STATUS=true
                shift
                ;;
            --context-file|--rlm-context|--rlm)
                require_arg_value "$1" "${2:-}"
                CONTEXT_FILE="${2:-}"
                shift 2
                ;;
            --prompt)
                require_arg_value "--prompt" "${2:-}"
                PROMPT_OVERRIDE="${2:-}"
                shift 2
                ;;
            --refresh-prompts)
                REFRESH_PROMPTS=true
                shift
                ;;
            --auto-continue-build)
                AUTO_CONTINUE_BUILD=true
                shift
                ;;
            --build-approval)
                require_arg_value "--build-approval" "${2:-}"
                BUILD_APPROVAL_POLICY="$(to_lower "${2:-}")"
                shift 2
                ;;
            --notify)
                require_arg_value "--notify" "${2:-}"
                HUMAN_NOTIFY_CHANNEL="$(to_lower "${2:-}")"
                shift 2
                ;;
            --force-build)
                FORCE_BUILD=true
                shift
                ;;
            --no-auto-prepare-backfill)
                AUTO_PREPARE_BACKFILL_ON_IDLE_BUILD=false
                shift
                ;;
            --no-interrupt-menu)
                INTERRUPT_MENU_ENABLED=false
                shift
                ;;
            --swarm-size)
                require_arg_value "--swarm-size" "${2:-}"
                SWARM_SIZE="${2:-1}"
                shift 2
                ;;
            --swarm-max-parallel)
                require_arg_value "--swarm-max-parallel" "${2:-}"
                SWARM_MAX_PARALLEL="${2:-1}"
                shift 2
                ;;
            --swarm-retry-invalid)
                require_arg_value "--swarm-retry-invalid" "${2:-}"
                SWARM_RETRY_INVALID_OUTPUT="${2:-1}"
                shift 2
                ;;
            --min-consensus)
                require_arg_value "--min-consensus" "${2:-}"
                MIN_CONSENSUS_SCORE="${2:-80}"
                shift 2
                ;;
            --max-reviewer-failures)
                require_arg_value "--max-reviewer-failures" "${2:-}"
                CONSENSUS_MAX_REVIEWER_FAILURES="${2:-0}"
                shift 2
                ;;
            --no-swarm)
                SWARM_ENABLED=false
                shift
                ;;
            --timeout)
                require_arg_value "--timeout" "${2:-}"
                COMMAND_TIMEOUT_SECONDS="${2:-0}"
                shift 2
                ;;
            --wait-for-lock)
                require_arg_value "--wait-for-lock" "${2:-}"
                LOCK_WAIT_SECONDS="${2:-0}"
                shift 2
                ;;
            --doctor)
                DOCTOR_MODE=true
                shift
                ;;
            --yolo)
                YOLO_OVERRIDE="true"
                shift
                ;;
            --no-yolo)
                YOLO_OVERRIDE="false"
                shift
                ;;
            --auto-update)
                AUTO_UPDATE_OVERRIDE="true"
                shift
                ;;
            --no-auto-update)
                AUTO_UPDATE_OVERRIDE="false"
                shift
                ;;
            --update-url)
                require_arg_value "--update-url" "${2:-}"
                AUTO_UPDATE_URL_OVERRIDE="${2:-}"
                shift 2
                ;;
            --no-backoff)
                BACKOFF_ENABLED=false
                shift
                ;;
            --non-interactive)
                NON_INTERACTIVE=true
                shift
                ;;
            -h|--help)
                print_help
                exit 0
                ;;
            *)
                if is_number "$1"; then
                    MODE="build"
                    MODE_EXPLICIT=true
                    MAX_ITERATIONS="$1"
                    shift
                else
                    err "Unknown argument: $1"
                    print_help
                    exit 1
                fi
                ;;
        esac
    done

    if [ "$MODE" != "build" ] && [ "$MODE" != "plan" ] && [ "$MODE" != "prepare" ] && [ "$MODE" != "test" ] && [ "$MODE" != "refactor" ] && [ "$MODE" != "lint" ] && [ "$MODE" != "document" ]; then
        err "Invalid mode: $MODE"
        exit 1
    fi
    if ! is_number "$MAX_ITERATIONS"; then
        err "--max expects a non-negative integer"
        exit 1
    fi
    if ! is_number "$COMMAND_TIMEOUT_SECONDS"; then
        err "--timeout expects a non-negative integer"
        exit 1
    fi
    if ! is_number "$LOCK_WAIT_SECONDS"; then
        err "--wait-for-lock expects a non-negative integer"
        exit 1
    fi
    if ! is_number "$SWARM_SIZE"; then
        err "--swarm-size expects a non-negative integer"
        exit 1
    fi
    if ! is_number "$SWARM_MAX_PARALLEL"; then
        err "--swarm-max-parallel expects a non-negative integer"
        exit 1
    fi
    if ! is_number "$SWARM_RETRY_INVALID_OUTPUT"; then
        err "--swarm-retry-invalid expects a non-negative integer"
        exit 1
    fi
    if ! is_number "$MIN_CONSENSUS_SCORE"; then
        err "--min-consensus expects a non-negative integer"
        exit 1
    fi
    if ! is_number "$CONSENSUS_MAX_REVIEWER_FAILURES"; then
        err "--max-reviewer-failures expects a non-negative integer"
        exit 1
    fi
    if ! is_number "$CONFIDENCE_TARGET"; then
        err "CONFIDENCE_TARGET must be a non-negative integer"
        exit 1
    fi
    if ! is_valid_build_approval_policy "$BUILD_APPROVAL_POLICY"; then
        err "BUILD_APPROVAL_POLICY must be one of: upfront, on_ready"
        exit 1
    fi
    if ! is_valid_notify_channel "$HUMAN_NOTIFY_CHANNEL"; then
        err "HUMAN_NOTIFY_CHANNEL must be one of: none, terminal, telegram, discord"
        exit 1
    fi
    if [ "$SWARM_SIZE" -lt 1 ]; then
        SWARM_SIZE=1
    fi
    if [ "$LOCK_WAIT_SECONDS" -lt 0 ]; then
        LOCK_WAIT_SECONDS=0
    fi
    if [ "$SWARM_MAX_PARALLEL" -lt 1 ]; then
        SWARM_MAX_PARALLEL=1
    fi
    if [ "$SWARM_RETRY_INVALID_OUTPUT" -lt 0 ]; then
        SWARM_RETRY_INVALID_OUTPUT=0
    fi
    if [ "$MIN_CONSENSUS_SCORE" -gt 100 ]; then
        MIN_CONSENSUS_SCORE=100
    fi
    if [ "$CONSENSUS_MAX_REVIEWER_FAILURES" -lt 0 ]; then
        CONSENSUS_MAX_REVIEWER_FAILURES=0
    fi
    if [ "$CONFIDENCE_TARGET" -gt 100 ]; then
        CONFIDENCE_TARGET=100
    fi
    if { [ "$MODE" = "plan" ] || [ "$MODE" = "test" ] || [ "$MODE" = "refactor" ] || [ "$MODE" = "lint" ] || [ "$MODE" = "document" ]; } && [ "$MAX_ITERATIONS" -eq 0 ]; then
        MAX_ITERATIONS=1
    fi
    if [ -n "$ENGINE_OVERRIDE" ]; then
        case "$ENGINE_OVERRIDE" in
            auto|codex|claude|ask) ;;
            *)
                err "Invalid --engine value: $ENGINE_OVERRIDE"
                exit 1
                ;;
        esac
    fi
}

main() {
    parse_args "$@"

    local needs_lock=true
    if (is_true "$DOCTOR_MODE" || is_true "$SHOW_STATUS" || is_true "$HUMAN_MODE") && ! is_true "$FORCE_SETUP"; then
        needs_lock=false
    fi

    if is_true "$needs_lock"; then
        trap cleanup_exit EXIT
        trap handle_interrupt INT
        trap handle_sigterm TERM
        acquire_lock
    fi

    local config_loaded=false
    if load_config; then
        config_loaded=true
    fi

    if is_true "$FORCE_SETUP"; then
        run_setup_wizard
        load_config || {
            err "Failed to load configuration after setup."
            exit 1
        }
        config_loaded=true

        if ! is_true "$SETUP_AND_RUN" && ! is_true "$DOCTOR_MODE" && ! is_true "$SHOW_STATUS"; then
            ok "Setup finished."
            info "Next step: run './ralphie.sh prepare' for deep planning, then approve build mode."
            exit 0
        fi
    fi

    if ! is_true "$config_loaded"; then
        if is_true "$DOCTOR_MODE" || is_true "$SHOW_STATUS" || is_true "$HUMAN_MODE"; then
            PROJECT_NAME="$(basename "$PROJECT_DIR")"
            PROJECT_TYPE="$(detect_project_type)"
            STACK_SUMMARY="$(detect_stack_summary)"
            ENGINE_PREF="auto"
            CODEX_MODEL=""
            CLAUDE_MODEL=""
            YOLO_MODE="true"
            GIT_AUTONOMY="false"
            BUILD_APPROVAL_POLICY="upfront"
            SKIP_BOOTSTRAP_NODE_TOOLCHAIN="false"
            SKIP_BOOTSTRAP_CHUTES_CLAUDE="false"
            SKIP_BOOTSTRAP_CHUTES_CODEX="false"
            HUMAN_NOTIFY_CHANNEL="terminal"
            ENABLE_GITHUB_ISSUES="false"
            GITHUB_REPO="$(guess_github_repo_from_remote)"
            CONSENSUS_MAX_REVIEWER_FAILURES="0"
        else
            run_setup_wizard
            load_config || {
                err "Failed to load configuration after setup."
                exit 1
            }
            config_loaded=true

            if ! is_true "$MODE_EXPLICIT" && ! is_true "$FORCE_SETUP"; then
                MODE="prepare"
                info "First-run default: entering prepare mode."
            fi
        fi
    fi

    maybe_auto_update_self "$@"

    local auto_phase_pipeline=false
    if ! is_true "$MODE_EXPLICIT" \
        && ! is_true "$HUMAN_MODE" \
        && ! is_true "$DOCTOR_MODE" \
        && ! is_true "$SHOW_STATUS" \
        && ! is_true "$CLEAN_MODE" \
        && ! is_true "$CLEAN_DEEP_MODE" \
        && ! is_true "$READY_MODE"; then
        auto_phase_pipeline=true
        if [ "$MODE" = "build" ]; then
            MODE="prepare"
        fi
        info "Default pipeline enabled: prepare -> build -> test -> refactor -> test -> lint -> document"
    fi

    if is_true "$HUMAN_MODE"; then
        if ! capture_human_priorities; then
            exit 1
        fi
        if is_true "$SHOW_STATUS"; then
            show_status
        fi
        exit 0
    fi

    if is_true "$DOCTOR_MODE"; then
        show_doctor
        exit 0
    fi

    if is_true "$SHOW_STATUS"; then
        show_status
        exit 0
    fi

    if is_true "$CLEAN_DEEP_MODE"; then
        clean_deep_artifacts
        show_status
        exit 0
    fi

    if is_true "$CLEAN_MODE"; then
        clean_recursive_artifacts
        show_status
        exit 0
    fi

    if is_true "$READY_MODE"; then
        ready_position
        if ! is_true "$READY_AND_RUN"; then
            show_status
            exit 0
        fi
    fi

    if is_true "$REFRESH_PROMPTS"; then
        write_prompt_files
    else
        # Ensure prompt files exist at least once.
        write_prompt_files
    fi
    create_self_improvement_spec_if_needed

    if [ -n "$CONTEXT_FILE" ] && [ ! -f "$CONTEXT_FILE" ]; then
        err "Context file not found: $(path_for_display "$CONTEXT_FILE")"
        exit 1
    fi

    preflight_runtime_checks

    local selected_engine
    selected_engine="${ENGINE_OVERRIDE:-$ENGINE_PREF}"
    if ! resolve_engine "$selected_engine"; then
        if is_interactive; then
            warn "No supported agent CLI found in PATH. Launching binary bootstrap prompts."
            offer_binary_bootstrap_setup
            save_config
            if ! resolve_engine "$selected_engine"; then
                err "No supported agent CLI found after bootstrap. Install Codex or Claude CLI first."
                exit 1
            fi
        else
            err "No supported agent CLI found. Install Codex or Claude CLI first."
            exit 1
        fi
    fi

    local yolo_effective
    yolo_effective="$(effective_yolo_mode)"

    if ! secure_build_approval_upfront; then
        err "Unable to secure required build approval policy before starting."
        exit 1
    fi

    local prompt_file
    if [ -n "$PROMPT_OVERRIDE" ]; then
        prompt_file="$PROMPT_OVERRIDE"
    else
        prompt_file="$(prompt_file_for_mode "$MODE")"
    fi

    if [ ! -f "$prompt_file" ]; then
        err "Prompt file not found: $prompt_file"
        exit 1
    fi

    if [ "$MODE" = "build" ]; then
        if ! enforce_build_gate "$yolo_effective"; then
            err "Build gate not satisfied. Exiting before build execution."
            exit 1
        fi
    elif [ "$MODE" = "test" ] || [ "$MODE" = "refactor" ] || [ "$MODE" = "lint" ] || [ "$MODE" = "document" ]; then
        if ! check_build_prerequisites; then
            err "Mode '$MODE' requires completed prepare artifacts first."
            err "Run './ralphie.sh prepare' before '$MODE'."
            exit 1
        fi
    fi

    ensure_layout
    SESSION_LOG="$LOG_DIR/ralphie_${MODE}_session_$(date '+%Y%m%d_%H%M%S').log"
    if ! start_session_logging "$SESSION_LOG"; then
        warn "Session logging disabled (mkfifo/tee unavailable). Continuing without a session log."
        SESSION_LOG=""
    fi

    write_state_snapshot "run_start"

    local branch
    branch="$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null || echo "n/a")"

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}                    RALPHIE STARTING                         ${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Mode:${NC}        $MODE"
    echo -e "${BLUE}Pipeline:${NC}    $(is_true "$auto_phase_pipeline" && echo "ENABLED (auto phase chain)" || echo "DISABLED")"
    echo -e "${BLUE}Engine:${NC}      $ACTIVE_ENGINE ($ACTIVE_CMD)"
    if [ "$ACTIVE_ENGINE" = "codex" ]; then
        echo -e "${BLUE}Model:${NC}       ${CODEX_MODEL:-default}"
    elif [ "$ACTIVE_ENGINE" = "claude" ]; then
        echo -e "${BLUE}Model:${NC}       ${CLAUDE_MODEL:-default}"
    fi
    echo -e "${BLUE}Prompt:${NC}      $(path_for_display "$prompt_file")"
    echo -e "${BLUE}Branch:${NC}      $branch"
    echo -e "${BLUE}YOLO:${NC}        $(is_true "$yolo_effective" && echo "ENABLED" || echo "DISABLED")"
    echo -e "${BLUE}Git Autonomy:${NC} $(is_true "$GIT_AUTONOMY" && echo "ENABLED" || echo "DISABLED")"
    echo -e "${BLUE}Approval:${NC}    $BUILD_APPROVAL_POLICY (auto-continue: $(is_true "$AUTO_CONTINUE_BUILD" && echo "ENABLED" || echo "DISABLED"))"
    echo -e "${BLUE}Notify:${NC}      $HUMAN_NOTIFY_CHANNEL"
    if [ "$COMMAND_TIMEOUT_SECONDS" -gt 0 ]; then
        echo -e "${BLUE}Timeout:${NC}     ${COMMAND_TIMEOUT_SECONDS}s per iteration"
    fi
    echo -e "${BLUE}Session Log:${NC} $(path_for_display "$SESSION_LOG")"
    [ "$MAX_ITERATIONS" -gt 0 ] && echo -e "${BLUE}Max Iterations:${NC} $MAX_ITERATIONS"
    echo -e "${BLUE}Swarm:${NC}       $(is_true "$SWARM_ENABLED" && echo "ENABLED ($SWARM_SIZE reviewers, max $SWARM_MAX_PARALLEL parallel)" || echo "DISABLED")"
    echo -e "${BLUE}Consensus Min:${NC} $MIN_CONSENSUS_SCORE"
    echo -e "${BLUE}Reviewer Fail Max:${NC} $CONSENSUS_MAX_REVIEWER_FAILURES"
    if [ -n "$CONTEXT_FILE" ]; then
        echo -e "${BLUE}Context File:${NC} $(path_for_display "$CONTEXT_FILE")"
    fi
    echo ""
    echo -e "${CYAN}Completion signal required: <promise>DONE</promise>${NC}"
    echo ""

    local iteration=0
    local consecutive_failures=0
    local completed_iterations=0
    local failed_iterations=0
    local prepare_last_confidence=0
    local prepare_stagnation=0
    local prepare_last_human_escalation=0
    local auto_engine_failovers=0
    local auto_engine_failover_limit=1
    local idle_auto_prepare_attempted=false
    local pipeline_test_completions=0
    local allow_auto_failover=false
    if [ -z "$ENGINE_OVERRIDE" ] || [ "$ENGINE_OVERRIDE" = "auto" ]; then
        allow_auto_failover=true
    fi
    local run_exit_code=0

    while true; do
        if [ "$MAX_ITERATIONS" -gt 0 ] && [ "$iteration" -ge "$MAX_ITERATIONS" ]; then
            ok "Reached max iterations: $MAX_ITERATIONS"
            break
        fi

        if [ "$MODE" = "build" ]; then
            if ! has_work_items; then
                if [ "$BACKOFF_LEVEL" -eq 0 ]; then
                    if is_true "$AUTO_PREPARE_BACKFILL_ON_IDLE_BUILD" && ! is_true "$idle_auto_prepare_attempted"; then
                        warn "No work items found in build mode. Switching to prepare mode for deep backfill."
                        log_reason_code "RB_BUILD_IDLE_AUTO_PREPARE" "switched from build to prepare due to empty work queue"
                        if ! switch_mode_with_prompt "prepare"; then
                            run_exit_code=1
                            break
                        fi
                        idle_auto_prepare_attempted=true
                        continue
                    else
                        run_idle_plan_refresh "$yolo_effective" "$iteration" || true
                        if has_work_items; then
                            ok "Work detected after idle plan refresh."
                            continue
                        fi
                    fi
                fi

                BACKOFF_LEVEL=$((BACKOFF_LEVEL + 1))
                local idle_wait idle_human
                idle_wait="$(get_backoff_wait)"
                idle_human="$(format_duration "$idle_wait")"

                echo -e "${YELLOW}No work items found. Backoff level $BACKOFF_LEVEL; waiting $idle_human.${NC}"
                sleep "$idle_wait"
                continue
            fi
            if [ "$BACKOFF_LEVEL" -gt 0 ]; then
                ok "Work detected; backoff reset."
                BACKOFF_LEVEL=0
            fi
            idle_auto_prepare_attempted=false
        fi

        iteration=$((iteration + 1))
        local ts log_file output_file effective_prompt
        ts="$(date '+%Y-%m-%d %H:%M:%S')"
        log_file="$LOG_DIR/ralphie_${MODE}_iter_${iteration}_$(date '+%Y%m%d_%H%M%S').log"
        output_file="$LOG_DIR/ralphie_output_iter_${iteration}_$(date '+%Y%m%d_%H%M%S').txt"
        touch "$log_file" "$output_file"

        effective_prompt="$(prepare_prompt_for_iteration "$prompt_file" "$iteration")"
        write_state_snapshot "iteration_start"

        echo ""
        echo -e "${PURPLE}════════════════════ LOOP $iteration ════════════════════${NC}"
        echo -e "${BLUE}[$ts]${NC} Running iteration $iteration"
        echo -e "${BLUE}Engine:${NC} $ACTIVE_ENGINE"
        echo -e "${BLUE}Command:${NC} $ACTIVE_CMD"

        local exit_code=0
        if run_agent_with_prompt "$effective_prompt" "$log_file" "$output_file" "$yolo_effective"; then
            exit_code=0
        else
            exit_code=$?
        fi

        if [ "$exit_code" -eq 0 ]; then
            local signal
            signal="$(detect_completion_signal "$log_file" "$output_file" || true)"
            if [ -n "$signal" ]; then
                ok "Completion signal detected: $signal"
                LAST_COMPLETION_SIGNAL="$signal"
                write_state_snapshot "completion_signal"
                consecutive_failures=0
                completed_iterations=$((completed_iterations + 1))

                case "$MODE" in
                    build)
                        write_completion_log "$iteration" "$signal"
                        if is_true "$auto_phase_pipeline"; then
                            if ! gate_transition_or_rewind "build" "test" "$yolo_effective"; then
                                failed_iterations=$((failed_iterations + 1))
                                continue
                            fi
                            if ! switch_mode_with_prompt "test"; then
                                run_exit_code=1
                                break
                            fi
                            continue
                        fi
                        ;;
                    plan)
                        if [ ! -f "$PLAN_FILE" ]; then
                            warn "Planning completion signal ignored because $PLAN_FILE is missing."
                            failed_iterations=$((failed_iterations + 1))
                            continue
                        fi
                        ok "Planning completed."
                        if is_true "$auto_phase_pipeline"; then
                            if ! gate_transition_or_rewind "plan" "build" "$yolo_effective"; then
                                failed_iterations=$((failed_iterations + 1))
                                continue
                            fi
                            if ! switch_mode_with_prompt "build"; then
                                run_exit_code=1
                                break
                            fi
                            if ! enforce_build_gate "$yolo_effective"; then
                                err "Build gate failed after plan phase."
                                log_reason_code "RB_BUILD_GATE_FAILED_AFTER_PLAN" "build gate failed after plan->build transition"
                                switch_mode_with_prompt "plan" || true
                                failed_iterations=$((failed_iterations + 1))
                            fi
                            continue
                        fi
                        break
                        ;;
                    prepare)
                        if ! check_build_prerequisites; then
                            warn "Prepare completion signal ignored because readiness artifacts are incomplete."
                            log_reason_code "RB_PREPARE_SIGNAL_IGNORED_PREREQ" "prepare emitted DONE but readiness artifacts failed checks"
                            failed_iterations=$((failed_iterations + 1))
                            continue
                        fi
                        ok "Prepare phase reports readiness. Running panel consensus..."
                        run_swarm_consensus "prepare-gate" "$yolo_effective"
                        if ! is_true "$LAST_CONSENSUS_PASS"; then
                            warn "Prepare consensus below threshold; continuing preparation."
                            log_reason_code "RB_PREPARE_CONSENSUS_FAILED" "prepare consensus score=$LAST_CONSENSUS_SCORE go=$LAST_CONSENSUS_GO_COUNT hold=$LAST_CONSENSUS_HOLD_COUNT panel_failures=$LAST_CONSENSUS_PANEL_FAILURES"
                            failed_iterations=$((failed_iterations + 1))
                            continue
                        fi

                        if ! request_build_permission; then
                            warn "Build permission not granted. Exiting at end of prepare phase."
                            log_reason_code "RB_PREPARE_BUILD_NOT_APPROVED" "human approval not granted after prepare success"
                            break
                        fi

                        ok "Switching from prepare phase to build phase."
                        if ! switch_mode_with_prompt "build"; then
                            run_exit_code=1
                            break
                        fi
                        pipeline_test_completions=0
                        if ! enforce_build_gate "$yolo_effective"; then
                            err "Build gate failed after prepare phase. Continue prepare mode to improve readiness."
                            log_reason_code "RB_BUILD_GATE_FAILED_AFTER_PREPARE" "build gate failed after prepare->build transition"
                            switch_mode_with_prompt "prepare" || true
                            failed_iterations=$((failed_iterations + 1))
                        fi
                        continue
                        ;;
                    test)
                        ok "Testing phase completed."
                        if is_true "$auto_phase_pipeline"; then
                            local next_mode=""
                            pipeline_test_completions=$((pipeline_test_completions + 1))
                            if [ "$pipeline_test_completions" -eq 1 ]; then
                                next_mode="refactor"
                            else
                                next_mode="lint"
                            fi
                            if ! gate_transition_or_rewind "test" "$next_mode" "$yolo_effective"; then
                                failed_iterations=$((failed_iterations + 1))
                                continue
                            fi
                            if ! switch_mode_with_prompt "$next_mode"; then
                                run_exit_code=1
                                break
                            fi
                            continue
                        fi
                        break
                        ;;
                    refactor)
                        ok "Refactor phase completed."
                        if is_true "$auto_phase_pipeline"; then
                            if ! gate_transition_or_rewind "refactor" "test" "$yolo_effective"; then
                                failed_iterations=$((failed_iterations + 1))
                                continue
                            fi
                            if ! switch_mode_with_prompt "test"; then
                                run_exit_code=1
                                break
                            fi
                            continue
                        fi
                        break
                        ;;
                    lint)
                        ok "Lint phase completed."
                        if is_true "$auto_phase_pipeline"; then
                            if ! run_bootstrap_scripts_if_applicable; then
                                warn "Bootstrap phase failed. Returning to lint phase."
                                failed_iterations=$((failed_iterations + 1))
                                continue
                            fi
                            if ! gate_transition_or_rewind "lint" "document" "$yolo_effective"; then
                                failed_iterations=$((failed_iterations + 1))
                                continue
                            fi
                            if ! switch_mode_with_prompt "document"; then
                                run_exit_code=1
                                break
                            fi
                            continue
                        fi
                        break
                        ;;
                    document)
                        ok "Documentation phase completed."
                        break
                        ;;
                esac
            else
                if [ "$MODE" = "prepare" ]; then
                    local confidence needs_human human_question new_last_escalation contract_issue failover_reason fallback_engine
                    confidence="$(extract_confidence_value "$output_file" "$log_file")"
                    if [ "$confidence" -gt "$prepare_last_confidence" ]; then
                        prepare_stagnation=0
                    else
                        prepare_stagnation=$((prepare_stagnation + 1))
                    fi
                    prepare_last_confidence="$confidence"

                    needs_human="$(extract_needs_human_flag "$output_file" "$log_file")"
                    human_question="$(extract_human_question "$output_file" "$log_file")"
                    new_last_escalation="$(maybe_collect_human_feedback "$iteration" "$confidence" "$prepare_stagnation" "$needs_human" "$human_question" "$prepare_last_human_escalation")"
                    if is_number "$new_last_escalation"; then
                        prepare_last_human_escalation="$new_last_escalation"
                    fi

                    info "Prepare confidence: $confidence (target: $CONFIDENCE_TARGET, stagnation: $prepare_stagnation)"

                    contract_issue=""
                    if output_has_tool_wrapper_leakage "$output_file"; then
                        contract_issue="tool-wrapper leakage in prepare output"
                    fi
                    if ! output_has_prepare_status_tags "$output_file"; then
                        if [ -n "$contract_issue" ]; then
                            contract_issue="${contract_issue}; missing required prepare tags"
                        else
                            contract_issue="missing required prepare tags"
                        fi
                    fi
                    if output_has_local_identity_leakage "$output_file"; then
                        if [ -n "$contract_issue" ]; then
                            contract_issue="${contract_issue}; local identity/path leakage in prepare output"
                        else
                            contract_issue="local identity/path leakage in prepare output"
                        fi
                    fi
                    if [ -n "$contract_issue" ]; then
                        warn "Prepare output contract issue: $contract_issue"
                        log_reason_code "RB_PREPARE_OUTPUT_CONTRACT" "$contract_issue"
                        write_gate_feedback "prepare-output-contract" "$contract_issue"
                    fi

                    failover_reason=""
                    if [ -n "$contract_issue" ]; then
                        failover_reason="prepare output contract violation"
                    elif [ "$prepare_stagnation" -ge "$CONFIDENCE_STAGNATION_LIMIT" ] && [ "$confidence" -lt "$CONFIDENCE_TARGET" ]; then
                        failover_reason="prepare confidence stagnation"
                    fi

                    if [ -n "$failover_reason" ] && is_true "$allow_auto_failover" && [ "$auto_engine_failovers" -lt "$auto_engine_failover_limit" ]; then
                        fallback_engine="$(pick_fallback_engine "prepare" "$ACTIVE_ENGINE" || true)"
                        if [ -n "$fallback_engine" ] && switch_active_engine "$fallback_engine" "$failover_reason"; then
                            auto_engine_failovers=$((auto_engine_failovers + 1))
                            prepare_stagnation=0
                            prepare_last_confidence=0
                            consecutive_failures=0
                            log_reason_code "RB_PREPARE_AUTO_FAILOVER" "engine switched to $ACTIVE_ENGINE due to $failover_reason"
                            info "Auto failover engaged for prepare mode; continuing with $ACTIVE_ENGINE."
                        fi
                    fi
                    if [ -z "$contract_issue" ]; then
                        log_reason_code "RB_PREPARE_NO_COMPLETION_SIGNAL" "prepare iteration ended without DONE signal"
                    fi
                else
                    warn "No completion signal detected. Retrying next iteration."
                    log_reason_code "RB_NO_COMPLETION_SIGNAL" "mode=$MODE iteration=$iteration"
                fi
                consecutive_failures=$((consecutive_failures + 1))
                failed_iterations=$((failed_iterations + 1))
            fi
        else
            if [ "$exit_code" -eq 124 ] || [ "$exit_code" -eq 137 ]; then
                err "Agent invocation timed out after ${COMMAND_TIMEOUT_SECONDS}s (exit $exit_code)."
                log_reason_code "RB_AGENT_TIMEOUT" "engine=$ACTIVE_ENGINE exit_code=$exit_code timeout=${COMMAND_TIMEOUT_SECONDS}s"
            else
                err "Agent execution failed (exit $exit_code)."
                log_reason_code "RB_AGENT_EXEC_FAILURE" "engine=$ACTIVE_ENGINE exit_code=$exit_code"
            fi
            warn "Iteration log: $(path_for_display "$log_file")"
            write_gate_feedback "agent-run" \
                "mode=$MODE engine=$ACTIVE_ENGINE exit_code=$exit_code timeout=${COMMAND_TIMEOUT_SECONDS}s" \
                "log: $(path_for_display "$log_file")" \
                "output: $(path_for_display "$output_file")"

            if try_self_heal_agent_failure "$log_file" "$output_file"; then
                info "Known issue was auto-remediated. Retrying loop."
                consecutive_failures=0
                failed_iterations=$((failed_iterations + 1))
                echo -e "${BLUE}Waiting ${NORMAL_WAIT}s before retry...${NC}"
                sleep "$NORMAL_WAIT"
                continue
            fi

            if is_fatal_agent_config_error "$log_file" "$output_file"; then
                print_fatal_agent_config_help "$log_file" "$output_file"
                log_reason_code "RB_FATAL_AGENT_CONFIG" "fatal agent configuration error detected"
                failed_iterations=$((failed_iterations + 1))
                run_exit_code=1
                break
            fi

            consecutive_failures=$((consecutive_failures + 1))
            failed_iterations=$((failed_iterations + 1))
        fi

        if [ "$consecutive_failures" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
            warn "$MAX_CONSECUTIVE_FAILURES consecutive failed/incomplete iterations."
            warn "Review logs under $LOG_DIR for blockers."
            consecutive_failures=0
        fi

        push_if_ahead
        echo -e "${BLUE}Waiting ${NORMAL_WAIT}s before next iteration...${NC}"
        sleep "$NORMAL_WAIT"
    done

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}                    RALPHIE FINISHED                         ${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Runtime:${NC}      $(duration_since_start)"
    echo -e "${BLUE}Iterations:${NC}   $iteration"
    echo -e "${BLUE}Completions:${NC}  $completed_iterations"
    echo -e "${BLUE}Failures:${NC}     $failed_iterations"

    return "$run_exit_code"
}

if [ "${RALPHIE_LIB:-0}" = "1" ]; then
    return 0 2>/dev/null || true
fi

main "$@"
