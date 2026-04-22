#!/usr/bin/env bash
# k8s-shell — Interactive TUI shell for Kubernetes automation scripts
#
# Usage:
#   ./k8s-shell.sh [path/to/inventory.ini]
#
# All automation scripts in this repository are accessible through this single
# interactive shell.  Type /help or press TAB at an empty prompt for a command
# listing.  Every script command accepts the active inventory file; change it
# at any time with /set-inventory.
#
# Requirements: bash 4.0+, tput

# Do NOT use set -e — the shell must stay alive after sub-script failures.
set -u

# ─── ANSI colour palette (256-colour) ────────────────────────────────────────
R=$'\033[0m'           # reset
BD=$'\033[1m'          # bold
OR=$'\033[38;5;208m'   # orange  — borders, accents
OB=$'\033[38;5;214m'   # bright orange — command names
GY=$'\033[38;5;245m'   # grey — hints / descriptions / dim content
WH=$'\033[97m'         # bright white

# ─── Unicode box-drawing ──────────────────────────────────────────────────────
TL='╭' TR='╮' BL='╰' BR='╯' H='─' V='│' BT='┴'

# ─── Constants ────────────────────────────────────────────────────────────────
readonly VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly HISTORY_FILE="${HOME}/.k8s_shell_history"

# ─── Runtime state ────────────────────────────────────────────────────────────
INVENTORY="${SCRIPT_DIR}/inventory.ini"   # may be overridden via /set-inventory

# ─── Command registry ─────────────────────────────────────────────────────────
# Parallel arrays indexed by position; CMD_ORDER drives display order.
declare -a CMD_ORDER=()
declare -A CMD_DESC=()
declare -A CMD_SCRIPT=()   # relative path from SCRIPT_DIR, or __builtin__

_register() {
    local name="$1" desc="$2" script="${3:-__builtin__}"
    CMD_ORDER+=("$name")
    CMD_DESC[$name]="$desc"
    CMD_SCRIPT[$name]="$script"
}

# ── Online scripts ──
_register "bootstrap"        "Bootstrap a K8s cluster on internet-connected nodes"            "bootstrap.sh"
_register "enable-proxy"     "Configure HTTP proxy on all cluster nodes"                       "enable-proxy.sh"
_register "install-longhorn" "Install Longhorn persistent storage (internet-connected)"        "install_longhorn_kubectl.sh"

# ── Airgapped scripts ──
_register "airgap-prep"      "Download all artifacts for an airgapped deployment"              "airgap/airgap-prep.sh"
_register "airgap-bootstrap" "Bootstrap K8s cluster from local bundle (no internet required)" "airgap/airgap-bootstrap.sh"
_register "airgap-longhorn"  "Install Longhorn storage from local bundle (no internet)"        "airgap/airgap-longhorn.sh"
_register "airgap-proxy"     "Apply or remove HTTP proxy settings on airgapped nodes"          "airgap/airgap-proxy-setup.sh"

# ── Built-in shell commands ──
_register "view-inventory"   "Print the active inventory.ini to the screen"
_register "edit-inventory"   "Open inventory.ini in \$EDITOR (default: vi)"
_register "set-inventory"    "Change the active inventory file:  /set-inventory <path>"
_register "help"             "Redraw the welcome screen and full command list"
_register "clear"            "Clear the screen and redraw"
_register "exit"             "Exit the shell"

# ─── Terminal helpers ─────────────────────────────────────────────────────────

# Current terminal width
_cols() { tput cols 2>/dev/null || echo 80; }

# Repeat string $2 exactly $1 times (loop-based to handle multi-byte UTF-8)
_rep() {
    local n="${1:-0}" c="${2:--}"
    (( n <= 0 )) && return 0
    local i
    for (( i = 0; i < n; i++ )); do
        printf '%s' "$c"
    done
}

# Return the visible (display) column width of a string that may contain ANSI
# escape codes.  Strips CSI sequences, then counts bytes (ASCII-safe; the repo
# uses ASCII labels everywhere).
_vlen() {
    printf '%s' "$1" \
        | sed $'s/\x1b\\[[0-9;]*[mJKHfABCDsupnrlh]//g; s/\x1b(B//g' \
        | wc -c \
        | tr -d ' '
}

# ─── Screen drawing ───────────────────────────────────────────────────────────

draw_header() {
    local w
    w=$(_cols)
    local title=" K8s Automation Shell v${VERSION} "
    local tlen
    tlen=$(_vlen "$title")
    # TL + H + title + right_fill + TR  →  total = w
    local fill=$(( w - 2 - tlen - 1 ))
    (( fill < 0 )) && fill=0

    printf '%b' "${OR}${TL}${H}${OB}${BD}"
    printf '%s' "$title"
    printf '%b' "${R}${OR}"
    _rep "$fill" "─"
    printf '%b\n' "${TR}${R}"
}

draw_panels() {
    local w
    w=$(_cols)

    # Left panel inner width (characters between the two V chars on the left).
    # Right panel inner width fills the rest.
    local lw=42
    local rw=$(( w - lw - 3 ))   # w = V + lw + V + rw + V  →  lw+rw = w-3
    (( rw < 10 )) && rw=10

    local inv_disp="${INVENTORY/#$HOME/~}"
    local dir_disp="${SCRIPT_DIR/#$HOME/~}"

    # ── left panel lines (plain strings; ANSI codes embedded) ──────────────
    local -a L=(
        ""
        "  ${OB}${BD}Welcome to K8s Automation Shell!${R}"
        ""
        "  ${GY}Kubernetes Automation Toolkit${R}"
        ""
        "  ${WH}Inventory:${R} ${GY}${inv_disp}${R}"
        "  ${WH}Scripts:  ${R} ${GY}${dir_disp}${R}"
        ""
    )

    local inv_status
    if [[ -f "${INVENTORY}" ]]; then
        inv_status="  ${GY}[ok] inventory.ini found${R}"
    else
        inv_status="  ${OR}[!!] inventory.ini not found — run /set-inventory${R}"
    fi

    # ── right panel lines ───────────────────────────────────────────────────
    local -a Rp=(
        ""
        "  ${OR}${BD}Tips for getting started${R}"
        "  Type ${OB}/help${R} to list all commands."
        "  Edit ${OB}inventory.ini${R} before running any script."
        "  Use ${OB}/set-inventory <path>${R} to switch files."
        ""
        "  ${OR}${BD}Inventory status${R}"
        "$inv_status"
        ""
    )

    local nrows=${#L[@]}
    (( ${#Rp[@]} > nrows )) && nrows=${#Rp[@]}

    local i
    for (( i = 0; i < nrows; i++ )); do
        local ll="${L[$i]:-}"
        local rl="${Rp[$i]:-}"

        local lvis rvis lpad rpad
        lvis=$(_vlen "$ll")
        rvis=$(_vlen "$rl")
        lpad=$(( lw - lvis ));   (( lpad < 0 )) && lpad=0
        rpad=$(( rw - rvis ));   (( rpad < 0 )) && rpad=0

        printf '%b' "${OR}${V}${R}"
        printf '%b' "$ll"
        printf '%*s' "$lpad" ''
        printf '%b' "${OR}${V}${R}"
        printf '%b' "$rl"
        printf '%*s' "$rpad" ''
        printf '%b\n' "${OR}${V}${R}"
    done
}

draw_panel_bottom() {
    local w
    w=$(_cols)
    local lw=42
    local rw=$(( w - lw - 3 ))
    (( rw < 10 )) && rw=10

    printf '%b' "${OR}${BL}"
    _rep "$lw" "─"
    printf '%b' "${BT}"
    _rep "$rw" "─"
    printf '%b\n' "${BR}${R}"
}

draw_commands() {
    local w
    w=$(_cols)
    local cmd_col=20   # width of the command-name column

    printf '\n'
    local name
    for name in "${CMD_ORDER[@]}"; do
        local desc="${CMD_DESC[$name]}"
        printf '%b' "  ${OB}${BD}"
        printf '/%-*s' "$cmd_col" "$name"
        printf '%b' "${R}  ${GY}"
        printf '%s' "$desc"
        printf '%b\n' "${R}"
    done
    printf '\n'
}

draw_screen() {
    clear
    draw_header
    draw_panels
    draw_panel_bottom
    draw_commands
}

# ─── Built-in command implementations ────────────────────────────────────────

_cmd_help()  { draw_screen; }
_cmd_clear() { draw_screen; }

_cmd_view_inventory() {
    if [[ ! -f "${INVENTORY}" ]]; then
        printf '%b\n' "  ${OR}File not found: ${INVENTORY}${R}"
        return 1
    fi
    printf '\n%b\n\n' "  ${OR}${BD}${INVENTORY}${R}"
    nl -ba "${INVENTORY}" | sed 's/^/  /'
    printf '\n'
}

_cmd_edit_inventory() {
    local ed="${EDITOR:-vi}"
    printf '%b\n' "  ${OR}Opening ${INVENTORY} with ${ed} …${R}"
    "$ed" "${INVENTORY}" 2>/dev/null || {
        printf '%b\n' "  ${OR}Could not launch '${ed}'.  Set \$EDITOR to your preferred editor.${R}"
        return 1
    }
}

_cmd_set_inventory() {
    local path="${1:-}"
    if [[ -z "$path" ]]; then
        printf '%b\n' "  ${OR}Usage: /set-inventory <path>${R}"
        return 1
    fi
    [[ "$path" != /* ]] && path="${SCRIPT_DIR}/${path}"
    INVENTORY="$path"
    printf '%b\n' "  ${GY}Inventory set to: ${INVENTORY}${R}"
    if [[ ! -f "${INVENTORY}" ]]; then
        printf '%b\n' "  ${OR}Warning: that file does not exist yet.${R}"
    fi
}

# ─── Script runner ────────────────────────────────────────────────────────────

_run_script() {
    local name="$1"
    shift
    local extra_args=("$@")

    local rel="${CMD_SCRIPT[$name]}"
    local script="${SCRIPT_DIR}/${rel}"

    if [[ ! -f "$script" ]]; then
        printf '%b\n' "  ${OR}Script not found: ${script}${R}"
        return 1
    fi

    chmod +x "$script" 2>/dev/null || true

    local w sep
    w=$(_cols)
    sep=$(_rep $(( w - 4 )) "─")

    printf '\n%b\n' "  ${OR}${BD}▶  $(basename "$script") ${INVENTORY} ${extra_args[*]:-}${R}"
    printf '%b\n\n' "  ${GY}${sep}${R}"

    bash "$script" "${INVENTORY}" "${extra_args[@]:-}"
    local rc=$?

    printf '\n%b\n' "  ${GY}${sep}${R}"
    if (( rc == 0 )); then
        printf '%b\n\n' "  ${OR}✔  Completed successfully (exit 0)${R}"
    else
        printf '%b\n\n' "  ${OR}✘  Script exited with code ${rc}${R}"
    fi
    return "$rc"
}

# ─── TAB completion (readline via bind -x) ───────────────────────────────────

_k8s_complete() {
    local cur="${READLINE_LINE}"
    local -a matches=()
    local name

    for name in "${CMD_ORDER[@]}"; do
        local candidate="/${name}"
        [[ "$candidate" == "${cur}"* ]] && matches+=("$candidate")
    done

    case ${#matches[@]} in
        0)  # No match — leave line unchanged
            ;;
        1)  # Unique match — complete in-place
            READLINE_LINE="${matches[0]} "
            READLINE_POINT=${#READLINE_LINE}
            ;;
        *)  # Multiple matches — print list and restore prompt
            printf '\n'
            for m in "${matches[@]}"; do
                printf '%b\n' "  ${OB}${m}${R}"
            done
            printf '%b%s' "${OR}${BD}> ${R}" "$cur"
            READLINE_POINT=${#READLINE_LINE}
            ;;
    esac
}

# ─── Dispatcher ───────────────────────────────────────────────────────────────

dispatch() {
    local raw="${1:-}"
    shift || true
    local -a extra=("$@")

    # Bare "/" shows the command list before we strip the slash.
    if [[ "$raw" == "/" ]]; then
        draw_commands
        return 0
    fi

    # Strip leading slash so both "/help" and "help" work.
    local name="${raw#/}"

    case "$name" in
        help)              _cmd_help ;;
        clear)             _cmd_clear ;;
        view-inventory)    _cmd_view_inventory ;;
        edit-inventory)    _cmd_edit_inventory ;;
        set-inventory)     _cmd_set_inventory "${extra[@]:-}" ;;
        exit|quit|q)
            printf '%b\n\n' "\n  ${GY}Goodbye!${R}"
            exit 0
            ;;
        "")
            # Empty input — do nothing, redisplay the prompt.
            ;;
        *)
            if [[ -n "${CMD_SCRIPT[$name]:-}" ]] \
               && [[ "${CMD_SCRIPT[$name]}" != "__builtin__" ]]; then
                _run_script "$name" "${extra[@]:-}"
            else
                printf '%b\n' \
                    "  ${OR}Unknown command: /${name}${R}  (type /help for the full list)"
            fi
            ;;
    esac
}

# ─── Main REPL ────────────────────────────────────────────────────────────────

main() {
    # Resolve inventory argument
    local inv_arg="${1:-}"
    if [[ -n "$inv_arg" ]]; then
        [[ "$inv_arg" != /* ]] && inv_arg="${SCRIPT_DIR}/${inv_arg}"
        INVENTORY="$inv_arg"
    fi

    # Readline history
    HISTFILE="${HISTORY_FILE}"
    HISTSIZE=1000
    HISTFILESIZE=2000
    history -r "${HISTORY_FILE}" 2>/dev/null || true

    # Bind TAB to our custom completer (works when read -e is active)
    bind -x '"\t":_k8s_complete' 2>/dev/null || true

    # Ctrl-C should not kill the shell — just cancel the current line.
    trap 'printf "\n%b\n" "  ${GY}(Ctrl-C — type /exit to quit)${R}"' INT

    draw_screen

    local line
    while true; do
        # read -e activates readline (history, cursor movement, TAB binding).
        if ! IFS= read -r -e -p "${OR}${BD}> ${R}" line; then
            # EOF (Ctrl-D)
            printf '%b\n\n' "\n  ${GY}Goodbye!${R}"
            exit 0
        fi

        # Trim leading / trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        [[ -z "$line" ]] && continue

        # Persist to history
        history -s "$line"
        history -w "${HISTORY_FILE}" 2>/dev/null || true

        # Tokenise: first token is the command, the rest are arguments.
        local -a tokens
        read -r -a tokens <<< "$line"
        local cmd="${tokens[0]:-}"
        local rest=("${tokens[@]:1}")

        dispatch "$cmd" "${rest[@]:-}"
    done
}

main "$@"
