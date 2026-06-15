#!/bin/bash
# Unit tests for version-from-tag.sh (shell test harness, mirrors Driver/tests/run-tests.sh style).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/version-from-tag.sh"
fail=0

assert_ok() { # tag expected_short expected_build
  local out short build
  if ! out=$("$SUT" "$1" 2>/dev/null); then
    echo "FAIL $1: expected success, got non-zero exit"; fail=1; return
  fi
  eval "$out"
  if [ "${short:-}" != "$2" ] || [ "${build:-}" != "$3" ]; then
    echo "FAIL $1: got SHORT=${short:-} BUILD=${build:-}, want $2 / $3"; fail=1
  else
    echo "ok   $1 -> $2 / $3"
  fi
}

assert_reject() { # tag
  if "$SUT" "$1" >/dev/null 2>&1; then
    echo "FAIL $1: expected rejection (non-zero exit)"; fail=1
  else
    echo "ok   $1 rejected"
  fi
}

assert_ok v1.0.0 1.0.0 1000000
assert_ok v1.2.0 1.2.0 1002000
assert_ok v1.2.3 1.2.3 1002003
assert_ok v1.2.5 1.2.5 1002005
assert_ok v2.0.0 2.0.0 2000000
assert_ok v1.10.0 1.10.0 1010000
assert_ok v1.999.999 1.999.999 1999999
assert_reject v1.2
assert_reject v1.2.3-beta.1
assert_reject 1.2.3
assert_reject vfoo
assert_reject v1.2.3.4
assert_reject v1.1000.0
assert_reject ""

if [ "$fail" -ne 0 ]; then echo "TESTS FAILED"; exit 1; fi
echo "ALL TESTS PASSED"
