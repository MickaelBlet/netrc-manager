#!/usr/bin/env bash
# netrc-check.sh — Test the validity of every credential in a .netrc file.
#
# ── Standalone usage ──────────────────────────────────────────────────────────
#   ./netrc-check.sh [machine]          # check all, or one machine
#   NETRC=/path/.netrc ./netrc-check.sh # use a custom netrc file
#
# ── Sourced usage (in another bash script) ────────────────────────────────────
#   source ./netrc-check.sh
#   check_netrc_connections          # check all machines → prints 🟢/🔴 lines
#   check_netrc_connections ftp.x.com # check a single machine
#   check_netrc_machine ftp.x.com user password  # low-level single test
#
# Exit code: 0 if all connections succeeded, 1 if any failed.
# ─────────────────────────────────────────────────────────────────────────────

NETRC_CHECK_NETRC_FILE="${NETRC:-$HOME/.netrc}"
NETRC_CHECK_TIMEOUT_CONNECT=8   # seconds
NETRC_CHECK_TIMEOUT_MAX=15      # seconds

# ── ANSI colours (only when output is a terminal) ─────────────────────────────
if [[ -t 1 ]]; then
    _NC_BOLD='\033[1m'; _NC_DIM='\033[2m'; _NC_NC='\033[0m'
    _NC_RED='\033[0;31m'; _NC_GREEN='\033[0;32m'; _NC_CYAN='\033[0;36m'
else
    _NC_BOLD=''; _NC_DIM=''; _NC_NC=''; _NC_RED=''; _NC_GREEN=''; _NC_CYAN=''
fi

# ── Parser ────────────────────────────────────────────────────────────────────
# Parses $NETRC_CHECK_NETRC_FILE into three parallel arrays:
#   _NC_MACHINES[]  _NC_LOGINS[]  _NC_PASSWORDS[]

declare -a _NC_MACHINES=()
declare -a _NC_LOGINS=()
declare -a _NC_PASSWORDS=()

_nc_parse_netrc() {
    _NC_MACHINES=(); _NC_LOGINS=(); _NC_PASSWORDS=()
    [[ -f "$NETRC_CHECK_NETRC_FILE" ]] || return 0

    local cur_m="" cur_l="" cur_p="" in_macdef=0

    _flush() {
        [[ -z "$cur_m" ]] && return
        _NC_MACHINES+=("$cur_m"); _NC_LOGINS+=("${cur_l:-}"); _NC_PASSWORDS+=("${cur_p:-}")
        cur_m=""; cur_l=""; cur_p=""
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
                machine)  _flush; (( i += 1 )); cur_m="${tokens[$i]:-}" ;;
                default)  _flush; cur_m="default" ;;
                login|user) (( i += 1 )); cur_l="${tokens[$i]:-}" ;;
                password)   (( i += 1 )); cur_p="${tokens[$i]:-}" ;;
            esac
            (( i += 1 ))
        done
    done < "$NETRC_CHECK_NETRC_FILE"

    _flush
    unset -f _flush
}

# ── Connection tester ─────────────────────────────────────────────────────────
# check_netrc_machine <machine> <login> <password>
# Prints one of:  success:<proto>:<detail>
#                 auth_fail:<proto>:<detail>
#                 connect_fail::<detail>
# Returns 0 on success, 1 on failure.

check_netrc_machine() {
    local machine="$1" login="${2:-}" _password="${3:-}"

    [[ "$machine" == "default" ]] && return 1

    local -a protos=("https" "http")
    # Prioritise FTP for hostnames that look like FTP servers
    [[ "$machine" =~ ^ftp[0-9]*\. ]] && protos=("ftp" "https" "http")

    local proto url curl_rc http_code

    for proto in "${protos[@]}"; do
        url="${proto}://${machine}/"

        if [[ "$proto" == "ftp" ]]; then
            # For FTP, rely on curl exit code (0 = logged in successfully)
            curl -s -o /dev/null \
                --netrc-file "$NETRC_CHECK_NETRC_FILE" \
                --connect-timeout "$NETRC_CHECK_TIMEOUT_CONNECT" \
                --max-time      "$NETRC_CHECK_TIMEOUT_MAX" \
                "$url" 2>/dev/null
            curl_rc=$?
            case $curl_rc in
                0)       echo "success:ftp:LOGIN_OK";       return 0 ;;
                67|9)    echo "auth_fail:ftp:LOGIN_DENIED"; return 1 ;;
                # 67=login denied, 9=FTP access denied
                6|7)     ;;  # DNS/connect failure — try next proto
                *)       ;;
            esac
            continue
        fi

        # HTTP / HTTPS
        http_code=$(curl -s -o /dev/null \
            -w "%{http_code}" \
            --netrc-file "$NETRC_CHECK_NETRC_FILE" \
            --connect-timeout "$NETRC_CHECK_TIMEOUT_CONNECT" \
            --max-time      "$NETRC_CHECK_TIMEOUT_MAX" \
            -L --max-redirs 5 \
            "$url" 2>/dev/null) || true

        curl_rc=$?

        # curl_rc != 0 means network-level failure; try next proto
        [[ $curl_rc -ne 0 ]] && continue

        if [[ "$http_code" =~ ^[0-9]+$ ]]; then
            local code=$((http_code))
            if   ((code >= 200 && code < 400)); then
                echo "success:${proto}:HTTP_${http_code}"; return 0
            elif ((code == 401 || code == 403)); then
                echo "auth_fail:${proto}:HTTP_${http_code}"; return 1
            elif ((code >= 400)); then
                # Other 4xx/5xx — still means we reached the server
                echo "success:${proto}:HTTP_${http_code}"; return 0
            fi
        fi
    done

    echo "connect_fail::UNREACHABLE"
    return 1
}

# ── Public API ────────────────────────────────────────────────────────────────
# check_netrc_connections [machine]
# Prints a 🟢/🔴 line for each entry and a summary line.
# Returns 0 if all OK, 1 if any failed.

check_netrc_connections() {
    local target="${1:-}"

    _nc_parse_netrc

    if [[ ${#_NC_MACHINES[@]} -eq 0 ]]; then
        echo "No entries found in $NETRC_CHECK_NETRC_FILE"
        return 0
    fi

    local total=0 passed=0 failed=0
    local max_machine=7   # minimum column width

    # Pre-compute column width
    local i
    for i in "${!_NC_MACHINES[@]}"; do
        local m="${_NC_MACHINES[$i]}"
        [[ -n "$target" && "$m" != "$target" ]] && continue
        [[ "$m" == "default" ]] && continue
        (( ${#m} > max_machine )) && max_machine=${#m}
    done
    (( max_machine += 2 ))

    printf '\n%bChecking connections in %s…%b\n\n' \
        "$_NC_BOLD" "$NETRC_CHECK_NETRC_FILE" "$_NC_NC"

    for i in "${!_NC_MACHINES[@]}"; do
        local machine="${_NC_MACHINES[$i]}"
        local login="${_NC_LOGINS[$i]:-}"

        [[ -n "$target" && "$machine" != "$target" ]] && continue
        [[ "$machine" == "default" ]] && continue

        (( total += 1 ))

        local result
        result=$(check_netrc_machine "$machine" "$login" "${_NC_PASSWORDS[$i]:-}")
        local rc=$?

        local proto detail
        proto="${result#*:}"; proto="${proto%%:*}"
        detail="${result##*:}"

        local proto_label=""
        [[ -n "$proto" ]] && proto_label="$(printf '%s' "$proto" | tr '[:lower:]' '[:upper:]')"

        if [[ $rc -eq 0 ]]; then
            (( passed += 1 ))
            printf '🟢  %-*s  %-20s  %b%s %s%b\n' \
                "$max_machine" "$machine" "${login:-<no login>}" \
                "$_NC_DIM" "$proto_label" "$detail" "$_NC_NC"
        else
            (( failed += 1 ))
            printf '🔴  %-*s  %-20s  %b%s %s%b\n' \
                "$max_machine" "$machine" "${login:-<no login>}" \
                "$_NC_RED" "$proto_label" "$detail" "$_NC_NC"
        fi
    done

    if [[ $total -eq 0 ]]; then
        if [[ -n "$target" ]]; then
            echo "No entry found for '$target' in $NETRC_CHECK_NETRC_FILE"
        else
            echo "No entries to check."
        fi
        return 0
    fi

    printf '\n%b─────────────────────────────────────%b\n' "$_NC_DIM" "$_NC_NC"
    if [[ $failed -eq 0 ]]; then
        printf '%b✓ All %d/%d connections valid%b\n\n' \
            "$_NC_GREEN" "$passed" "$total" "$_NC_NC"
    else
        printf '%b✗ %d/%d connections failed%b  (%d/%d valid)\n\n' \
            "$_NC_RED" "$failed" "$total" "$_NC_NC" "$passed" "$total"
    fi

    return $((failed > 0 ? 1 : 0))
}

# ── Standalone entry point ────────────────────────────────────────────────────
# Only runs when the script is executed directly (not sourced).

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    command -v curl &>/dev/null || { echo "error: 'curl' is required but not installed" >&2; exit 1; }
    check_netrc_connections "${1:-}"
fi
