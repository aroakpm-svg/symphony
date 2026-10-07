#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: security-audit.sh MIX_COMMAND" >&2
  exit 2
fi

if [ -n "${HEX_OFFLINE-}" ] || [ -n "${HEX_IGNORE_ADVISORIES-}" ] ||
   [ -n "${HEX_IGNORE_RETIREMENTS-}" ] || [ -n "${HEX_UNSAFE_REGISTRY-}" ] ||
   [ -n "${HEX_NO_VERIFY_REPO_ORIGIN-}" ]; then
  echo "security audit requires online, verified registry data without ignore settings" >&2
  exit 2
fi

audit_log=$(mktemp)
trap 'rm -f "$audit_log"' EXIT HUP INT TERM

if "$1" hex.audit >"$audit_log" 2>&1; then
  cat "$audit_log"
else
  audit_status=$?
  cat "$audit_log" >&2
  exit "$audit_status"
fi

# Hex 2.5.1 may use its cache after a registry request fails and still exit 0.
# A green audit must come from a successful online check, including HTTP 304.
if grep -Eq 'Failed to fetch record for .* from registry' "$audit_log" ||
   grep -Eq '^Ignored (retired|advisories):' "$audit_log"; then
  echo "security audit could not verify fresh, unignored registry findings" >&2
  exit 1
fi
