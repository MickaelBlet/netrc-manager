#!/usr/bin/env bash
# netrc-manager — Manage ~/.netrc credentials

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd -P)"

NETRC_FILE="${NETRC:-${HOME}/.netrc}"
NETRC_CHECKER="${SCRIPT_DIR}/netrc-manager-check-machine.sh"
# shellcheck disable=SC1090
. "${NETRC_CHECKER}"

# ── ANSI colours (only when stdout is a terminal) ─────────────────────────────
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    CYAN=$'\033[0;36m'
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    NC=$'\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
    BOLD=''
    DIM=''
    NC=''
fi

# ── Configuration ─────────────────────────────────────────────────────────────
# Auto-refresh is disabled by default (0). Enable it via NETRC_REFRESH_INTERVAL
# or the -r/--refresh launch option.
REFRESH_INTERVAL="${NETRC_REFRESH_INTERVAL:-0}" # seconds between auto-refresh (0 = off)
export NETRC_CHECK_NETRC_FILE="${NETRC_FILE}"

usage() {
    cat << EOF
Usage: ${0##*/} [options]

Options:
  -r, --refresh SECONDS   Auto-refresh every SECONDS (0 disables, default: ${REFRESH_INTERVAL})
  -h, --help              Show this help and exit
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -r | --refresh)
                if [[ -z "${2:-}" || ! "${2}" =~ ^[0-9]+$ ]]; then
                    echo "netrc-manager: --refresh requires a non-negative integer." >&2
                    exit 1
                fi
                REFRESH_INTERVAL="$2"
                shift 2
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                echo "netrc-manager: unknown option '$1'" >&2
                usage >&2
                exit 1
                ;;
        esac
    done
}

STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/netrc-manager.XXXXXX")"
cleanup() {
    tput cnorm 2> /dev/null || true
    # Stop any in-flight background checks before removing their state dir.
    local pids
    pids="$(jobs -p 2> /dev/null)"
    if [[ -n "${pids}" ]]; then
        kill ${pids} 2> /dev/null || true
    fi
    wait 2> /dev/null || true
    if [[ -n "${STATE_DIR:-}" ]]; then
        rm -rf "${STATE_DIR}"
    fi
}
on_signal() {
    cleanup
    trap - EXIT
    exit 130
}
trap cleanup EXIT
trap on_signal INT TERM

# ── netrc parsing ─────────────────────────────────────────────────────────────
# Populates parallel arrays MACHINES[] and LOGINS[] from the netrc file.
declare -a MACHINES=()
declare -a LOGINS=()
declare -a PASSWORDS=()

parse_netrc() {
    MACHINES=()
    LOGINS=()
    PASSWORDS=()
    if [[ ! -f "${NETRC_FILE}" ]]; then
        return 0
    fi

    local token cur_machine="" cur_login="" cur_password="" in_macdef=0
    # Flatten file to a token stream (handles tokens spread across lines).
    while read -r -a tokens; do
        # An empty line terminates a macdef body.
        if [[ "${in_macdef}" -eq 1 ]]; then
            if [[ ${#tokens[@]} -eq 0 ]]; then
                in_macdef=0
            fi
            continue
        fi
        local i=0
        while [[ "${i}" -lt ${#tokens[@]} ]]; do
            token="${tokens[i]}"
            case "${token}" in
                machine)
                    # Flush previous entry.
                    if [[ -n "${cur_machine}" ]]; then
                        MACHINES+=("${cur_machine}")
                        LOGINS+=("${cur_login}")
                        PASSWORDS+=("${cur_password}")
                    fi
                    i=$(( i + 1 )); cur_machine="${tokens[i]:-}"; cur_login=""; cur_password=""
                    ;;
                default)
                    if [[ -n "${cur_machine}" ]]; then
                        MACHINES+=("${cur_machine}")
                        LOGINS+=("${cur_login}")
                        PASSWORDS+=("${cur_password}")
                    fi
                    cur_machine="default"; cur_login=""; cur_password=""
                    ;;
                login)   i=$(( i + 1 )); cur_login="${tokens[i]:-}" ;;
                password) i=$(( i + 1 )); cur_password="${tokens[i]:-}" ;;
                account) i=$(( i + 1 )) ;; # skip value
                macdef)  in_macdef=1; i=${#tokens[@]}; continue ;;
                *)        ;; # ignore unknown tokens
            esac
            i=$((i + 1))
        done
    done < "${NETRC_FILE}"

    if [[ -n "${cur_machine}" ]]; then
        MACHINES+=("${cur_machine}")
        LOGINS+=("${cur_login}")
        PASSWORDS+=("${cur_password}")
    fi

    sort_entries
}

# Sort the parallel MACHINES[]/LOGINS[] arrays alphabetically by machine name.
sort_entries() {
    if [[ ${#MACHINES[@]} -lt 2 ]]; then
        return 0
    fi
    local i sorted rest
    # Pack each triple as "machine\tlogin\tpassword", sort by machine, unpack.
    mapfile -t sorted < <(
        for i in "${!MACHINES[@]}"; do
            printf '%s\t%s\t%s\n' "${MACHINES[i]}" "${LOGINS[i]}" "${PASSWORDS[i]}"
        done | LC_ALL=C sort -t $'\t' -k1,1
    )
    MACHINES=()
    LOGINS=()
    PASSWORDS=()
    for i in "${sorted[@]}"; do
        MACHINES+=("${i%%$'\t'*}")
        rest="${i#*$'\t'}"
        LOGINS+=("${rest%%$'\t'*}")
        PASSWORDS+=("${rest#*$'\t'}")
    done
}

# ── Parallel checks ───────────────────────────────────────────────────────────
# Launch a background check for every machine; result written to STATE_DIR.
launch_checks() {
    local idx machine
    for idx in "${!MACHINES[@]}"; do
        machine="${MACHINES[idx]}"
        if [[ "${machine}" == "default" ]]; then
            continue
        fi
        printf 'checking' > "${STATE_DIR}/${idx}.status"
        (
            result="$(netrc_manager_check_machine "${machine}" 2> /dev/null || true)"
            printf '%s' "${result:-connect_fail:UNREACHABLE}" > "${STATE_DIR}/${idx}.status"
        ) &
    done
}

read_status() {
    local idx="$1"
    local f="${STATE_DIR}/${idx}.status"
    if [[ -f "${f}" ]]; then
        cat "${f}"
    else
        printf ''
    fi
}

# ── Rendering ─────────────────────────────────────────────────────────────────
# Repeat a string $2 times.
repeat() {
    local s="$1" n="$2" out=''
    while [[ "${n}" -gt 0 ]]; do
        out+="$s"
        n=$(( n - 1 ))
    done
    printf '%s' "${out}"
}

# Strip ANSI escape sequences (for measuring visible width).
strip_ansi() {
    printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g'
}

status_cell() {
    local state="${1%%:*}" detail="${1#*:}"
    case "${state}" in
        success)      printf '%b' "${GREEN}● OK${NC}      ${DIM}${detail}${NC}" ;;
        auth_fail)    printf '%b' "${RED}● AUTH${NC}    ${DIM}${detail}${NC}" ;;
        connect_fail) printf '%b' "${YELLOW}● UNREACH${NC} ${DIM}${detail}${NC}" ;;
        checking)     printf '%b' "${CYAN}● CHECKING${NC} ${DIM}…${NC}" ;;
        *)            printf '%b' "${DIM}● n/a${NC}" ;;
    esac
}

# Display value for a password cell, honouring the global reveal toggle.
password_cell() {
    local pw="$1"
    if [[ -z "${pw}" ]]; then
        printf '%s' '-'
    elif [[ "${SHOW_PASSWORDS}" -eq 1 ]]; then
        printf '%s' "${pw}"
    else
        printf '%s' "••••••••"
    fi
}

SHOW_PASSWORDS=0
SELECTED=0
SCROLL_OFFSET=0
LAST_REFRESH=0
LAST_FRAME=''
LAST_LINES=0

render() {
    local now elapsed remaining
    now="$(date +%s)"
    elapsed=$(( now - LAST_REFRESH ))
    remaining=$(( REFRESH_INTERVAL - elapsed ))
    if [[ "${remaining}" -lt 0 ]]; then
        remaining=0
    fi

    # Build the whole frame into a buffer first so we can (a) skip redrawing
    # when nothing changed and (b) repaint by moving the cursor back up over the
    # previous frame and overwriting it in place — no full-screen clear and no
    # absolute cursor home, so the terminal scrollback is preserved.
    local frame idx marker

    # Compute column widths from the longest value (header included).
    local mwidth=7 lwidth=5 pwidth=8 swidth=6 val # MACHINE=7 LOGIN=5 PASSWORD=8 STATUS=6
    local -a statuses=() pwcells=()
    for idx in "${!MACHINES[@]}"; do
        val="${MACHINES[idx]}"
        if [[ ${#val} -gt "${mwidth}" ]]; then
            mwidth=${#val}
        fi
        val="${LOGINS[idx]:--}"
        if [[ ${#val} -gt "${lwidth}" ]]; then
            lwidth=${#val}
        fi
        pwcells[idx]="$(password_cell "${PASSWORDS[idx]}")"
        val="${pwcells[idx]}"
        # Wrap long passwords every 16 chars, so the column never grows past 16.
        if [[ ${#val} -gt 16 ]]; then
            val="${val:0:16}"
        fi
        if [[ ${#val} -gt "${pwidth}" ]]; then
            pwidth=${#val}
        fi
        statuses[idx]="$(status_cell "$(read_status "${idx}")")"
        val="$(strip_ansi "${statuses[idx]}")"
        if [[ ${#val} -gt "${swidth}" ]]; then
            swidth=${#val}
        fi
    done

    # Box-drawing helpers. Inner width = marker(1) + spacing.
    local h_m h_l h_p h_s
    h_m="$(repeat '─' $(( mwidth + 2 )))"
    h_l="$(repeat '─' $(( lwidth + 2 )))"
    h_p="$(repeat '─' $(( pwidth + 2 )))"
    h_s="$(repeat '─' $(( swidth + 2 )))"

    frame=""
    if [[ "${REFRESH_INTERVAL}" -gt 0 ]]; then
        frame+="$(printf '%b' "${DIM}auto-refresh ${REFRESH_INTERVAL}s (next in ${remaining}s) · ${#MACHINES[@]} machines${NC}")"$'\n'
    fi
    frame+=" ${DIM}╭${h_m}┬${h_l}┬${h_p}┬${h_s}╮${NC}"
    frame+=$'\n'" $(printf "${DIM}│${NC} ${BOLD}%-${mwidth}s${NC} ${DIM}│${NC} ${BOLD}%-${lwidth}s${NC} ${DIM}│${NC} ${BOLD}%-${pwidth}s${NC} ${DIM}│${NC} ${BOLD}%-${swidth}s${NC} ${DIM}│${NC}" 'MACHINE' 'LOGIN' 'PASSWORD' 'STATUS')"
    frame+=$'\n'" ${DIM}├${h_m}┼${h_l}┼${h_p}┼${h_s}┤${NC}"

    # ── Viewport ──────────────────────────────────────────────────────────────
    # Fit the data rows into the terminal height, always keeping the 3 header
    # lines (top border, titles, separator) plus the bottom border and footer
    # (and the auto-refresh line when enabled) on screen. Scroll the window so
    # the selected entry stays visible and draw a scrollbar when rows overflow.
    local total=${#MACHINES[@]}
    local term_lines fixed visible
    term_lines="$(tput lines 2> /dev/null || echo 24)"
    fixed=6 # top border + titles + separator + bottom border + footer + 1 spare
            # (trailing newline of the last printed line would otherwise scroll)
    if [[ "${REFRESH_INTERVAL}" -gt 0 ]]; then
        fixed=$(( fixed + 1 ))
    fi
    visible=$(( term_lines - fixed ))
    if [[ "${visible}" -lt 1 ]]; then
        visible=1
    fi

    local first last need_bar=0
    if [[ "${total}" -le "${visible}" ]]; then
        SCROLL_OFFSET=0
        first=0
        last=$(( total - 1 ))
    else
        need_bar=1
        # Keep SELECTED within [offset, offset+visible).
        if [[ "${SELECTED}" -lt "${SCROLL_OFFSET}" ]]; then
            SCROLL_OFFSET="${SELECTED}"
        elif [[ "${SELECTED}" -ge $(( SCROLL_OFFSET + visible )) ]]; then
            SCROLL_OFFSET=$(( SELECTED - visible + 1 ))
        fi
        if [[ "${SCROLL_OFFSET}" -gt $(( total - visible )) ]]; then
            SCROLL_OFFSET=$(( total - visible ))
        fi
        if [[ "${SCROLL_OFFSET}" -lt 0 ]]; then
            SCROLL_OFFSET=0
        fi
        first="${SCROLL_OFFSET}"
        last=$(( SCROLL_OFFSET + visible - 1 ))
    fi

    # Scrollbar thumb geometry (over the visible rows).
    local thumb_size thumb_start
    if [[ "${need_bar}" -eq 1 ]]; then
        thumb_size=$(( visible * visible / total ))
        if [[ "${thumb_size}" -lt 1 ]]; then
            thumb_size=1
        fi
        thumb_start=$(( SCROLL_OFFSET * (visible - thumb_size) / (total - visible) ))
    fi

    local row=0
    for idx in $(seq "${first}" "${last}"); do
        if [[ "${idx}" -eq "${SELECTED}" ]]; then
            marker="${BOLD}${CYAN}▶${NC}"
        else
            marker=' '
        fi
        # Pad status manually since it contains ANSI escapes.
        local spad pad
        spad="$(strip_ansi "${statuses[idx]}")"
        pad="$(repeat ' ' $(( swidth - ${#spad} )))"
        local bar=''
        if [[ "${need_bar}" -eq 1 ]]; then
            if [[ "${row}" -ge "${thumb_start}" && "${row}" -lt $(( thumb_start + thumb_size )) ]]; then
                bar="${CYAN}█${NC}"
            else
                bar="${DIM}│${NC}"
            fi
        fi
        # Split the password cell into 16-char chunks; first chunk shares the row,
        # extra chunks spill onto continuation lines with the other columns blank.
        local pwfull="${pwcells[idx]}" chunk ppad pchunk0="${pwcells[idx]:0:16}"
        ppad="$(repeat ' ' $(( pwidth - ${#pchunk0} )))"
        frame+=$'\n'"$(printf "%b${DIM}│${NC} %-${mwidth}s ${DIM}│${NC} %-${lwidth}s ${DIM}│${NC} %s%s ${DIM}│${NC} %b%s ${DIM}│${NC}%b" "${marker}" "${MACHINES[idx]}" "${LOGINS[idx]:--}" "${pchunk0}" "${ppad}" "${statuses[idx]}" "${pad}" "${bar}")"
        pwfull="${pwfull:16}"
        local spc_m spc_l spc_s
        spc_m="$(repeat ' ' "${mwidth}")"
        spc_l="$(repeat ' ' "${lwidth}")"
        spc_s="$(repeat ' ' "${swidth}")"
        while [[ -n "${pwfull}" ]]; do
            chunk="${pwfull:0:16}"
            ppad="$(repeat ' ' $(( pwidth - ${#chunk} )))"
            frame+=$'\n'"$(printf " ${DIM}│${NC} %s ${DIM}│${NC} %s ${DIM}│${NC} %s%s ${DIM}│${NC} %s ${DIM}│${NC}%b" "${spc_m}" "${spc_l}" "${chunk}" "${ppad}" "${spc_s}" "${bar}")"
            pwfull="${pwfull:16}"
        done
        row=$(( row + 1 ))
    done

    frame+=$'\n'" ${DIM}╰${h_m}┴${h_l}┴${h_p}┴${h_s}╯${NC}"
    frame+=$'\n'"$(printf '%b' "${DIM}↑/↓ k/j move · r refresh · a add · e edit · d delete · p show/hide pw · q quit${NC}")"

    # Nothing changed since last paint → don't touch the screen.
    if [[ "${frame}" == "${LAST_FRAME}" ]]; then
        return 0
    fi
    LAST_FRAME="${frame}"

    # Move the cursor up over the previously drawn frame (relative, not absolute)
    # so we overwrite it in place without clearing the whole screen. On the first
    # paint LAST_LINES is 0, so the frame is simply printed where the cursor sits.
    if [[ "${LAST_LINES}" -gt 0 ]]; then
        printf '\033[%dA' "${LAST_LINES}"
    fi
    local line lines=0
    while IFS= read -r line; do
        printf '%s\033[K\n' "${line}"
        lines=$(( lines + 1 ))
    done <<< "${frame}"
    # Clear any leftover lines from a previously taller frame.
    printf '\033[J'
    LAST_LINES="${lines}"
}

# ── Navigation (wrap-around) ──────────────────────────────────────────────────
move_up() {
    local n=${#MACHINES[@]}
    if [[ "${n}" -eq 0 ]]; then
        return 0
    fi
    SELECTED=$(( (SELECTED - 1 + n) % n ))
}
move_down() {
    local n=${#MACHINES[@]}
    if [[ "${n}" -eq 0 ]]; then
        return 0
    fi
    SELECTED=$(( (SELECTED + 1) % n ))
}

# ── Actions ───────────────────────────────────────────────────────────────────
# Move the selection to the entry matching $1 (no-op if not found).
select_machine() {
    local target="$1" idx
    for idx in "${!MACHINES[@]}"; do
        if [[ "${MACHINES[idx]}" == "${target}" ]]; then
            SELECTED="${idx}"
            return 0
        fi
    done
}

do_refresh() {
    parse_netrc
    launch_checks
    LAST_REFRESH="$(date +%s)"
    if [[ "${SELECTED}" -ge ${#MACHINES[@]} ]]; then
        SELECTED=$(( ${#MACHINES[@]} - 1 ))
    fi
    if [[ "${SELECTED}" -lt 0 ]]; then
        SELECTED=0
    fi
    return 0
}

# Force a fresh redraw after a prompt-driven action. prompt() reads input on a
# single reused line without ever emitting a newline, so the screen never
# scrolls and the cursor is left exactly where render expects it (just below the
# frame). We only need to invalidate the cached frame so render repaints.
repaint() {
    LAST_FRAME=''
}

prompt() {
    # $1 = prompt text; echoes the entered value. Reads raw, char by char, on the
    # current line only — no trailing newline — so the dashboard never scrolls
    # and the terminal scrollback above it is preserved.
    local reply='' ch saved=''
    saved="$(stty -g < /dev/tty 2> /dev/null || true)"
    stty -echo -icanon min 1 time 0 < /dev/tty 2> /dev/null || true
    printf '\r\033[K%b%s' "${BOLD}$1${NC}" "${reply}" > /dev/tty
    while IFS= read -rsn1 ch < /dev/tty; do
        case "${ch}" in
            '' | $'\n' | $'\r') break ;;                    # Enter → done
            $'\177' | $'\b') reply="${reply%?}" ;;          # Backspace
            *) reply+="${ch}" ;;
        esac
        printf '\r\033[K%b%s' "${BOLD}$1${NC}" "${reply}" > /dev/tty
    done
    if [[ -n "${saved}" ]]; then
        stty "${saved}" < /dev/tty 2> /dev/null || true
    fi
    # Wipe the prompt line; cursor stays on it (no newline) for render to reuse.
    printf '\r\033[K' > /dev/tty
    printf '%s' "${reply}"
}

add_machine() {
    local m l p
    m="$(prompt 'machine: ')"
    if [[ -z "${m}" ]]; then
        return 0
    fi
    l="$(prompt 'login:   ')"
    p="$(prompt 'password:')"
    {
        printf 'machine %s\n' "${m}"
        if [[ -n "${l}" ]]; then
            printf '    login %s\n' "${l}"
        fi
        if [[ -n "${p}" ]]; then
            printf '    password %s\n' "${p}"
        fi
    } >> "${NETRC_FILE}"
    chmod 600 "${NETRC_FILE}" 2> /dev/null || true
    do_refresh
    select_machine "${m}"
}

# Echo the stored password for the given machine (empty if none).
machine_password() {
    local target="$1"
    awk -v target="${target}" '
        function emit() { if (cur == target && pw != "") { print pw; exit } }
        $1 == "machine" { emit(); cur = $2; pw = "" }
        $1 == "default" { emit(); cur = "default"; pw = "" }
        {
            for (i = 1; i < NF; i++) {
                if ($i == "password") pw = $(i + 1)
            }
        }
        END { emit() }
    ' "${NETRC_FILE}"
}

# Rewrite the netrc file excluding the given machine entry.
remove_entry() {
    local target="$1" tmp
    tmp="$(mktemp "${STATE_DIR}/netrc.XXXXXX")"
    awk -v target="${target}" '
        # Default to keeping lines so any leading comments / blank lines (which
        # belong to no entry) are preserved instead of dropped.
        BEGIN { keep = 1 }
        function flush() { if (keep && buf != "") printf "%s", buf; buf=""; keep=1 }
        /^[[:space:]]*machine[[:space:]]/ {
            flush()
            keep = ($2 != target)
        }
        /^[[:space:]]*default([[:space:]]|$)/ {
            flush()
            keep = 1
        }
        { buf = buf $0 "\n" }
        END { flush() }
    ' "${NETRC_FILE}" > "${tmp}" || return 1
    # Atomic replace: only overwrite once awk succeeded and produced a file, so a
    # partial/empty run can never truncate the real netrc. Preserve mode.
    chmod 600 "${tmp}" 2> /dev/null || true
    mv -f "${tmp}" "${NETRC_FILE}"
}

delete_machine() {
    if [[ ${#MACHINES[@]} -eq 0 ]]; then
        return 0
    fi
    local m="${MACHINES[SELECTED]}"
    if [[ "${m}" == "default" ]]; then
        return 0
    fi
    local c
    c="$(prompt "delete '${m}'? [y/N] ")"
    if [[ "${c}" != "y" && "${c}" != "Y" ]]; then
        return 0
    fi
    remove_entry "${m}"
    do_refresh
}

edit_machine() {
    if [[ ${#MACHINES[@]} -eq 0 ]]; then
        return 0
    fi
    local m="${MACHINES[SELECTED]}" l p
    if [[ "${m}" == "default" ]]; then
        return 0
    fi
    l="$(prompt "edit (${m}) login (${LOGINS[SELECTED]:-none}): ")"
    p="$(prompt "edit (${m}) new password (blank=keep): ")"
    if [[ -z "${l}" && -z "${p}" ]]; then
        return 0
    fi
    # Keep existing values when fields left blank.
    if [[ -z "${l}" ]]; then
        l="${LOGINS[SELECTED]}"
    fi
    if [[ -z "${p}" ]]; then
        p="$(machine_password "${m}")"
    fi
    remove_entry "${m}"
    {
        printf 'machine %s\n' "${m}"
        if [[ -n "${l}" ]]; then
            printf '    login %s\n' "${l}"
        fi
        if [[ -n "${p}" ]]; then
            printf '    password %s\n' "${p}"
        fi
    } >> "${NETRC_FILE}"
    chmod 600 "${NETRC_FILE}" 2> /dev/null || true
    do_refresh
    select_machine "${m}"
}

# ── Main loop ─────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"
    if [[ ! -t 0 || ! -t 1 ]]; then
        echo "netrc-manager: interactive terminal required." >&2
        exit 1
    fi
    if ! command -v curl > /dev/null; then
        echo "netrc-manager: curl is required." >&2
        exit 1
    fi

    tput civis 2> /dev/null || true
    do_refresh

    local key rest
    while true; do
        render
        # Auto-refresh when the interval elapses; poll input every second.
        if read -rsn1 -t 1 key; then
            case "${key}" in
                q|Q) break ;;
                r|R) do_refresh ;;
                a|A) add_machine; repaint ;;
                e|E) edit_machine; repaint ;;
                d|D) delete_machine; repaint ;;
                p|P) SHOW_PASSWORDS=$(( 1 - SHOW_PASSWORDS )) ;;
                k|K) move_up ;;
                j|J) move_down ;;
                $'\033')
                    read -rsn2 -t 0.01 rest || rest=""
                    case "${rest}" in
                        '[A') move_up ;;
                        '[B') move_down ;;
                        *);;
                    esac
                    ;;
                *);;
            esac
        fi
        # Time-based auto-refresh (only when enabled).
        if [[ "${REFRESH_INTERVAL}" -gt 0 && $(( $(date +%s) - LAST_REFRESH )) -ge "${REFRESH_INTERVAL}" ]]; then
            do_refresh
        fi
    done
}

main "$@"
