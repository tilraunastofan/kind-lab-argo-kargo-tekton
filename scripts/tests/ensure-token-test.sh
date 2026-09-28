#!/usr/bin/env bash
# Tests for ensure_token in scripts/lib.sh. Uses a throwaway TOKENS_FILE so it
# never touches the real ~/.tokens. Run: scripts/tests/ensure-token-test.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' EXIT

# 1. Unset var + missing file: generates a 48-char hex value, exports it,
#    and appends an `export` line to the file.
(
  export TOKENS_FILE="${tmp}/t1"
  unset T_ONE || true
  ensure_token T_ONE
  [ "${#T_ONE}" -eq 48 ] || fail "1: expected 48 chars, got '${T_ONE}'"
  grep -q "^export T_ONE=${T_ONE}\$" "${TOKENS_FILE}" || fail "1: line not appended"
  echo "${T_ONE}" > "${tmp}/t1.value"
)

# 2. A fresh shell (var unset) reads the SAME value back from the file.
(
  export TOKENS_FILE="${tmp}/t1"
  unset T_ONE || true
  ensure_token T_ONE
  [ "${T_ONE}" = "$(cat "${tmp}/t1.value")" ] || fail "2: value changed on second run"
  [ "$(grep -c '^export T_ONE=' "${TOKENS_FILE}")" -eq 1 ] || fail "2: duplicate line appended"
)

# 3. Var already in the environment wins and the file is left untouched.
(
  export TOKENS_FILE="${tmp}/t3"
  export T_THREE="from-env"
  ensure_token T_THREE
  [ "${T_THREE}" = "from-env" ] || fail "3: env value overwritten"
  [ ! -e "${TOKENS_FILE}" ] || fail "3: file created although env was set"
)

# 4. Commented-out lines and quoted values are handled.
(
  export TOKENS_FILE="${tmp}/t4"
  printf '#export T_FOUR=commented\nexport T_FOUR="quoted"\n' > "${TOKENS_FILE}"
  unset T_FOUR || true
  ensure_token T_FOUR
  [ "${T_FOUR}" = "quoted" ] || fail "4: expected 'quoted', got '${T_FOUR}'"
)

echo "ensure-token-test: all passed"
