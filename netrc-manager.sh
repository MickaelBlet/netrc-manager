#!/usr/bin/env bash
# netrc-manager — Manage ~/.netrc credentials
#
# Usage: netrc-manager.sh <command> [options]
# Run 'netrc-manager.sh help' for full documentation.

set -euo pipefail

VERSION="1.0.0"
NETRC_FILE="${NETRC:-$HOME/.netrc}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── ANSI colours (only when stdout is a terminal) ─────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; DIM=''; NC=''
fi

# ── helpers ───────────────────────────────────────────────────────────────────
die()     { echo -e "${RED}error:${NC} $*" >&2; exit 1; }
info()    { echo -e "${CYAN}→${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}!${NC} $*"; }

require_cmd() { command -v "$1" &>/dev/null || die "'$1' is required but not installed"; }

ensure_netrc() {
    if [[ ! -f "$NETRC_FILE" ]]; then
        touch "$NETRC_FILE"
        chmod 600 "$NETRC_FILE"
        info "Created $NETRC_FILE"
    fi
    local perms
    perms=$(stat -c "%a" "$NETRC_FILE" 2>/dev/null || stat -f "%OLp" "$NETRC_FILE" 2>/dev/null || echo "unknown")
    if [[ "$perms" != "600" && "$perms" != "unknown" ]]; then
        warn "Fixing permissions on $NETRC_FILE (was $perms, setting to 600)"
        chmod 600 "$NETRC_FILE"
    fi
}

# ── netrc parser ──────────────────────────────────────────────────────────────
# Global parallel arrays filled by parse_netrc()
declare -a MACHINES=()
declare -a LOGINS=()
declare -a PASSWORDS=()

parse_netrc() {
    MACHINES=(); LOGINS=(); PASSWORDS=()
    [[ -f "$NETRC_FILE" ]] || return 0

    local cur_machine="" cur_login="" cur_password="" in_macdef=0

    _flush() {
        [[ -z "$cur_machine" ]] && return
        MACHINES+=("$cur_machine")
        LOGINS+=("${cur_login:-}")
        PASSWORDS+=("${cur_password:-}")
        cur_machine=""; cur_login=""; cur_password=""
    }

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        if [[ "$line" =~ ^[[:space:]]*macdef[[:space:]] ]]; then
            _flush; in_macdef=1; continue
        fi
        if ((in_macdef)); then
            [[ -z "${line// }" ]] && in_macdef=0
            continue
        fi

        local -a tokens=()
        read -ra tokens <<< "$line"
        local i=0
        while ((i < ${#tokens[@]})); do
            case "${tokens[$i]}" in
                machine)
                    _flush; (( i += 1 )); cur_machine="${tokens[$i]:-}"
                    ;;
                default)
                    _flush; cur_machine="default"
                    ;;
                login|user)
                    (( i += 1 )); cur_login="${tokens[$i]:-}"
                    ;;
                password)
                    (( i += 1 )); cur_password="${tokens[$i]:-}"
                    ;;
            esac
            (( i += 1 ))
        done
    done < "$NETRC_FILE"

    _flush
    unset -f _flush
}

# Returns the index of machine in MACHINES[], or -1 if not found
find_machine_index() {
    local target="$1"
    local i
    for i in "${!MACHINES[@]}"; do
        [[ "${MACHINES[$i]}" == "$target" ]] && echo "$i" && return 0
    done
    echo "-1"
}

# Write MACHINES/LOGINS/PASSWORDS back to the netrc file (atomic)
write_netrc() {
    local tmpfile
    tmpfile=$(mktemp)
    chmod 600 "$tmpfile"

    local i
    for i in "${!MACHINES[@]}"; do
        if [[ "${MACHINES[$i]}" == "default" ]]; then
            printf 'default\n' >> "$tmpfile"
        else
            printf 'machine %s\n' "${MACHINES[$i]}" >> "$tmpfile"
        fi
        [[ -n "${LOGINS[$i]:-}"    ]] && printf '    login %s\n'    "${LOGINS[$i]}"    >> "$tmpfile"
        [[ -n "${PASSWORDS[$i]:-}" ]] && printf '    password %s\n' "${PASSWORDS[$i]}" >> "$tmpfile"
        printf '\n' >> "$tmpfile"
    done

    mv "$tmpfile" "$NETRC_FILE"
}

# ── commands ──────────────────────────────────────────────────────────────────

cmd_list() {
    parse_netrc

    if [[ ${#MACHINES[@]} -eq 0 ]]; then
        info "No entries found in $NETRC_FILE"
        return 0
    fi

    printf '\n%bEntries in %s:%b\n\n' "$BOLD" "$NETRC_FILE" "$NC"
    printf '  %-32s %-22s %s\n' "MACHINE" "LOGIN" "PASSWORD"
    printf '  %-32s %-22s %s\n' \
        "$(printf '%.0s─' {1..32})" \
        "$(printf '%.0s─' {1..22})" \
        "$(printf '%.0s─' {1..16})"

    local i
    for i in "${!MACHINES[@]}"; do
        printf '  %-32s %-22s %b%s%b\n' \
            "${MACHINES[$i]}" \
            "${LOGINS[$i]:-<none>}" \
            "$DIM" "●●●●●●●●" "$NC"
    done
    printf '\n'
}

cmd_add() {
    local machine="${1:-}"

    ensure_netrc
    parse_netrc

    if [[ -z "$machine" ]]; then
        read -r -p "Machine (hostname): " machine
    fi
    [[ -z "$machine" ]] && die "Machine cannot be empty"

    local idx
    idx=$(find_machine_index "$machine")
    if [[ "$idx" -ge 0 ]]; then
        warn "An entry for '$machine' already exists — use 'edit' to modify it."
        exit 1
    fi

    local login="" password=""
    read -r  -p "Login:    " login
    read -rs -p "Password: " password && printf '\n'

    MACHINES+=("$machine")
    LOGINS+=("${login:-}")
    PASSWORDS+=("${password:-}")

    write_netrc
    success "Added entry for '$machine'"
}

cmd_remove() {
    local machine="${1:-}"
    [[ -z "$machine" ]] && die "Usage: $(basename "$0") remove <machine>"

    parse_netrc

    local idx
    idx=$(find_machine_index "$machine")
    [[ "$idx" -lt 0 ]] && die "No entry found for '$machine'"

    read -r -p "Remove credentials for '$machine'? [y/N] " confirm
    [[ "${confirm,,}" != "y" ]] && { info "Aborted."; exit 0; }

    local nm=() nl=() np=()
    local i
    for i in "${!MACHINES[@]}"; do
        [[ $i -eq $idx ]] && continue
        nm+=("${MACHINES[$i]}"); nl+=("${LOGINS[$i]}"); np+=("${PASSWORDS[$i]}")
    done
    MACHINES=("${nm[@]+"${nm[@]}"}"); LOGINS=("${nl[@]+"${nl[@]}"}"); PASSWORDS=("${np[@]+"${np[@]}"}")

    write_netrc
    success "Removed entry for '$machine'"
}

cmd_edit() {
    local machine="${1:-}"
    [[ -z "$machine" ]] && die "Usage: $(basename "$0") edit <machine>"

    ensure_netrc
    parse_netrc

    local idx
    idx=$(find_machine_index "$machine")
    [[ "$idx" -lt 0 ]] && die "No entry found for '$machine' — use 'add' to create it."

    printf '\n%bEditing entry for %s%b\n' "$BOLD" "$machine" "$NC"
    printf '%b(press Enter to keep the current value)%b\n\n' "$DIM" "$NC"

    local new_login="" new_password=""
    read -r  -p "Login    [${LOGINS[$idx]:-<none>}]: "       new_login
    read -rs -p "Password (leave blank to keep current): "   new_password && printf '\n'

    [[ -n "$new_login"    ]] && LOGINS[$idx]="$new_login"
    [[ -n "$new_password" ]] && PASSWORDS[$idx]="$new_password"

    write_netrc
    success "Updated entry for '$machine'"
}

cmd_show() {
    local machine="${1:-}"
    [[ -z "$machine" ]] && die "Usage: $(basename "$0") show <machine>"

    parse_netrc

    local idx
    idx=$(find_machine_index "$machine")
    [[ "$idx" -lt 0 ]] && die "No entry found for '$machine'"

    printf '\n%bCredentials for %s:%b\n' "$BOLD" "$machine" "$NC"
    printf '  Machine:  %b%s%b\n' "$CYAN" "${MACHINES[$idx]}" "$NC"
    printf '  Login:    %b%s%b\n' "$CYAN" "${LOGINS[$idx]:-<none>}" "$NC"

    read -r -p "  Reveal password? [y/N] " confirm
    if [[ "${confirm,,}" == "y" ]]; then
        printf '  Password: %b%s%b\n' "$YELLOW" "${PASSWORDS[$idx]:-<none>}" "$NC"
    else
        printf '  Password: %b●●●●●●●●%b\n' "$DIM" "$NC"
    fi
    printf '\n'
}

cmd_check() {
    require_cmd curl

    local checker="$SCRIPT_DIR/netrc-check.sh"
    [[ -f "$checker" ]] || die "netrc-check.sh not found in $SCRIPT_DIR"

    NETRC="$NETRC_FILE" bash "$checker" "${@}"
}

# ── usage ─────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF

${BOLD}netrc-manager v${VERSION}${NC} — Manage ~/.netrc credentials

${BOLD}USAGE${NC}
    $(basename "$0") [-f <netrc>] <command> [args]

${BOLD}COMMANDS${NC}
    list                  List all entries (passwords masked)
    add   [machine]       Add a new credential entry (interactive)
    remove <machine>      Remove a credential entry
    edit  <machine>       Edit login or password for an entry
    show  <machine>       Display an entry (optional password reveal)
    check [machine]       Test connection validity  🟢 / 🔴
    help                  Show this help

${BOLD}OPTIONS${NC}
    -f, --file <path>     Use a custom netrc file instead of ~/.netrc

${BOLD}ENVIRONMENT${NC}
    NETRC                 Override the default netrc file path

${BOLD}EXAMPLES${NC}
    $(basename "$0") list
    $(basename "$0") add api.example.com
    $(basename "$0") edit api.example.com
    $(basename "$0") remove old.server.com
    $(basename "$0") check
    $(basename "$0") check api.example.com
    $(basename "$0") -f /srv/.netrc check

EOF
}

# ── main ──────────────────────────────────────────────────────────────────────

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--file)
                shift
                [[ -z "${1:-}" ]] && die "-f requires a file path"
                NETRC_FILE="$1"; shift
                ;;
            -v|--version)
                echo "netrc-manager v${VERSION}"; exit 0
                ;;
            -h|--help)
                usage; exit 0
                ;;
            *) break ;;
        esac
    done

    local cmd="${1:-help}"; shift || true

    case "$cmd" in
        list|ls)                  cmd_list   "$@" ;;
        add)                      cmd_add    "$@" ;;
        remove|rm|delete|del)     cmd_remove "$@" ;;
        edit)                     cmd_edit   "$@" ;;
        show)                     cmd_show   "$@" ;;
        check)                    cmd_check  "$@" ;;
        help|--help|-h)           usage ;;
        *) die "Unknown command: '$cmd'. Run '$(basename "$0") help' for usage." ;;
    esac
}

main "$@"
