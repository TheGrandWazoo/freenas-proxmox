#!/bin/bash
# Regression test for restart_pve_services() in packaging/DEBIAN/postinst
# and postrm. Ref: #179 — pve-ha-lrm/pve-ha-crm don't support a `restart`
# subcommand (only pvedaemon/pveproxy/pvestatd do), so calling it directly
# aborts the maintainer script under `set -e` and breaks every future
# install/upgrade/remove. The stubs in tests/stubs/ mimic the real PVE
# binaries closely enough to catch that class of regression without needing
# a live PVE cluster (see .claude/cos/runbooks for the real-cluster check).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
STUB_DIR="${SCRIPT_DIR}/stubs"

export PATH="${STUB_DIR}:${PATH}"

run_case() {
    local script="$1"
    local label="$2"

    echo "==> Testing restart_pve_services() in ${label}"

    local log_out
    log_out="$(bash -c "
        set -euo pipefail
        source '${script}'
        # postinst/postrm's own log() writes to /var/log via tee — override
        # after sourcing so the test doesn't need root.
        log() { echo \"[log] \$*\"; }
        restart_pve_services
    ")"

    printf '    %s\n' "${log_out//$'\n'/$'\n'    }"

    for expected in "pvedaemon restarted" "pveproxy restarted" "pvestatd restarted" "pve-ha-lrm, pve-ha-crm restarted"; do
        if ! grep -qF "${expected}" <<<"${log_out}"; then
            echo "FAIL: ${label} — expected log line containing '${expected}' not found" >&2
            exit 1
        fi
    done

    echo "PASS: ${label}"
}

run_case "${REPO_ROOT}/packaging/DEBIAN/postinst" "postinst"
run_case "${REPO_ROOT}/packaging/DEBIAN/postrm"   "postrm"

# Failure-propagation check: a failing restart must abort the function (and
# thus the maintainer script under `set -e`), not be silently swallowed.
# This is what `cmd && log "..."` got wrong — set -e does not fire on the
# left side of `&&` — and what the current bare-statement form fixes.
run_failure_case() {
    local script="$1"
    local label="$2"

    echo "==> Testing failure propagation in ${label}"

    local rc=0
    local log_out
    log_out="$(PATH="${SCRIPT_DIR}/fail-stubs:${STUB_DIR}:${PATH}" bash -c "
        set -euo pipefail
        source '${script}'
        log() { echo \"[log] \$*\"; }
        restart_pve_services
    " 2>&1)" || rc=$?

    if [[ "${rc}" -eq 0 ]]; then
        echo "FAIL: ${label} — restart_pve_services() returned 0 despite a failing restart:" >&2
        printf '    %s\n' "${log_out//$'\n'/$'\n'    }" >&2
        exit 1
    fi

    if grep -qF "Done. Refresh" <<<"${log_out}"; then
        echo "FAIL: ${label} — function ran to completion after a failing restart" >&2
        exit 1
    fi

    echo "PASS: ${label} (aborted with rc=${rc}, as expected)"
}

run_failure_case "${REPO_ROOT}/packaging/DEBIAN/postinst" "postinst"
run_failure_case "${REPO_ROOT}/packaging/DEBIAN/postrm"   "postrm"

echo "All restart_pve_services() tests passed."
