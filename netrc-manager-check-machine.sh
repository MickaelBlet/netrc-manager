#!/usr/bin/env bash

# This script is a library and must be sourced, not executed directly.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: ${BASH_SOURCE[0]} must be sourced, not executed." >&2
    exit 1
fi

NETRC_CHECK_NETRC_FILE="${NETRC_CHECK_NETRC_FILE:-${HOME}/.netrc}"
NETRC_CHECK_TIMEOUT_CONNECT="${NETRC_CHECK_TIMEOUT_CONNECT:-8}" # seconds
NETRC_CHECK_TIMEOUT_MAX="${NETRC_CHECK_TIMEOUT_MAX:-15}" # seconds

# Check if machine is reachable and if the credentials in the .netrc file are valid for that machine.
#   Parameters:
#     $1 - The name of the machine to check in the .netrc file.
#   Echoes:
#     success:<code> - If the machine is reachable and credentials are valid.
#     auth_fail:<code> - If the machine is reachable but credentials are invalid.
#     connect_fail:<code> - If the machine is unreachable or returned an unexpected
#   Returns:
#     0 - If checking the machine was successful.
#     1 - If checking the machine failed.
netrc_manager_check_machine() {
    local machine="$1"
    local test_url=""
    local http_code=""

    if [[ "${machine}" == "default" ]]; then
        return 1
    fi

    if [[ "amazon.com" == "${machine}" ]]; then
        test_url="https://www.amazon.com/login"
        http_code="$(curl -s -o /dev/null \
            -w "%{http_code}" \
            --netrc-file "${NETRC_CHECK_NETRC_FILE}" \
            --connect-timeout "${NETRC_CHECK_TIMEOUT_CONNECT}" \
            --max-time "${NETRC_CHECK_TIMEOUT_MAX}" \
            -L --max-redirs 5 \
            "${test_url}" 2>/dev/null)" || true
    else
        test_url="https://${machine}/"
        http_code="$(curl -s -o /dev/null \
            -w "%{http_code}" \
            --netrc-file "${NETRC_CHECK_NETRC_FILE}" \
            --connect-timeout "${NETRC_CHECK_TIMEOUT_CONNECT}" \
            --max-time "${NETRC_CHECK_TIMEOUT_MAX}" \
            -L --max-redirs 5 \
            "${test_url}" 2>/dev/null)" || true
    fi

    if [[ "${http_code}" =~ ^[0-9]+$ ]]; then
        case "${http_code}" in
            200|301|302|303|307|308)
                echo "success:${http_code}"
                return 0
                ;;
            401|403)
                echo "auth_fail:${http_code}"
                return 1
                ;;
            *)
                echo "connect_fail:${http_code}"
                return 1
                ;;
        esac
    else
        echo "connect_fail:UNREACHABLE"
        return 1
    fi
}