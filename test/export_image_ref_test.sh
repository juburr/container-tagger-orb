#!/usr/bin/env bash
# Image reference exports for src/scripts/export_image_ref.sh.
#
# Locks these behaviours:
#   <image>:<tag> is exported under image_ref_env_var, read from tag_env_var
#   the BASH_ENV line is shell-quoted, so sourcing it returns the exact value
#     and never runs anything in it
#   a missing tag fails, names export_tag, and leaves BASH_ENV unchanged
#
# Run from a checkout:
#   bash test/export_image_ref_test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/src/scripts/export_image_ref.sh"
BASH_BIN="$(command -v bash)"
ORIGINAL_PATH="${PATH}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE_BIN="${TMP}/fake-bin"
mkdir -p "$FAKE_BIN"
# The scripts pass values on stdin, as with the real `circleci env subst`.
cat > "${FAKE_BIN}/circleci" << 'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "env" && "${2:-}" == "subst" && $# -eq 2 ]]; then
  cat
  exit 0
fi
printf 'unexpected circleci invocation: %s\n' "$*" >&2
exit 1
EOF
chmod +x "${FAKE_BIN}/circleci"

BASH_ENV_FILE="${TMP}/bash.env"
LOG="${TMP}/script.log"

PASSED=0
FAILED=0

fail_case() {
  local name="$1"
  shift
  FAILED=$((FAILED + 1))
  printf 'FAIL %s\n' "$name"
  printf '  %s\n' "$@"
}

pass_case() {
  PASSED=$((PASSED + 1))
}

# run_script IMAGE TAG_ENV_VAR TAG_VALUE IMAGE_REF_ENV_VAR
run_script() {
  local status=0
  printf 'export EXPORT_TEST_SENTINEL=1\n' > "$BASH_ENV_FILE"
  (
    cd "$TMP" || exit 1
    env BASH_ENV="$BASH_ENV_FILE" \
      PARAM_IMAGE="$1" \
      PARAM_TAG_ENV_VAR="$2" \
      "$2=$3" \
      PARAM_IMAGE_REF_ENV_VAR="$4" \
      PATH="${FAKE_BIN}:${ORIGINAL_PATH}" \
      "$BASH_BIN" "$SCRIPT" > "$LOG" 2>&1
  ) || status=$?
  printf '%s' "$status"
}

# Source BASH_ENV in a clean shell, as a later step would, and print one variable.
exported_value() {
  # shellcheck disable=SC2016 # $1 and $2 belong to the child bash, not this script.
  (cd "$TMP" && env -i "$BASH_BIN" --noprofile --norc -c 'source "$1"; printf "%s" "${!2}"' bash "$BASH_ENV_FILE" "$1")
}

expect_exported() {
  local name="$1" image="$2" tag_var="$3" tag="$4" ref_var="$5" expected="$6"
  local status got
  status="$(run_script "$image" "$tag_var" "$tag" "$ref_var")"
  if [[ "$status" -ne 0 ]]; then
    fail_case "$name" "exit ${status}" "$(cat "$LOG")"
    return
  fi
  got="$(exported_value "$ref_var")"
  if [[ "$got" != "$expected" ]]; then
    fail_case "$name" "expected ${expected}" "got ${got}" "$(cat "$BASH_ENV_FILE")"
    return
  fi
  if [[ "$(exported_value EXPORT_TEST_SENTINEL)" != "1" ]]; then
    fail_case "$name" "BASH_ENV was replaced instead of appended" "$(cat "$BASH_ENV_FILE")"
    return
  fi
  pass_case
}

expect_exported "exports IMAGE_REF from TAG" \
  "ghcr.io/org/app" "TAG" "1.2.3" "IMAGE_REF" "ghcr.io/org/app:1.2.3"
# %q leaves a plain reference as it is, so the logged line stays readable.
if ! grep -Fx "export IMAGE_REF=ghcr.io/org/app:1.2.3" "$BASH_ENV_FILE" > /dev/null ||
  ! grep -Fx "export IMAGE_REF=ghcr.io/org/app:1.2.3" "$LOG" > /dev/null; then
  fail_case "a plain reference is written and logged unquoted" "$(cat "$BASH_ENV_FILE")" "$(cat "$LOG")"
else
  pass_case
fi
expect_exported "custom env var names" \
  "localhost:5000/org/app" "RELEASE_TAG" "main-01234567" "DEPLOY_REF" "localhost:5000/org/app:main-01234567"

# shellcheck disable=SC2016 # the value must reach the script unexpanded
hostile='ghcr.io/org/app $(touch pwned) `touch pwned2`; touch pwned3'
expect_exported "a value with shell syntax round-trips through BASH_ENV" \
  "$hostile" "TAG" "1.2.3" "IMAGE_REF" "${hostile}:1.2.3"
if [[ -e "${TMP}/pwned" || -e "${TMP}/pwned2" || -e "${TMP}/pwned3" ]]; then
  fail_case "sourcing BASH_ENV does not run the value" "$(ls "$TMP")"
else
  pass_case
fi

status="$(run_script "ghcr.io/org/app" "TAG" "" "IMAGE_REF")"
if [[ "$status" -eq 0 ]]; then
  fail_case "a missing tag fails" "exit 0" "$(cat "$LOG")"
elif ! grep -F "Please run the export_tag command first." "$LOG" > /dev/null; then
  fail_case "a missing tag names export_tag" "$(cat "$LOG")"
elif [[ "$(cat "$BASH_ENV_FILE")" != "export EXPORT_TEST_SENTINEL=1" ]]; then
  fail_case "a missing tag leaves BASH_ENV unchanged" "$(cat "$BASH_ENV_FILE")"
else
  pass_case
fi

# A tag variable that was never set fails the same way under set -u, with the
# error on stderr and nothing on stdout that looks like one.
printf 'export EXPORT_TEST_SENTINEL=1\n' > "$BASH_ENV_FILE"
status=0
(
  cd "$TMP" || exit 1
  env -u TAG BASH_ENV="$BASH_ENV_FILE" PARAM_IMAGE="ghcr.io/org/app" PARAM_TAG_ENV_VAR="TAG" \
    PARAM_IMAGE_REF_ENV_VAR="IMAGE_REF" PATH="${FAKE_BIN}:${ORIGINAL_PATH}" \
    "$BASH_BIN" "$SCRIPT" > "$LOG" 2> "${LOG}.stderr"
) || status=$?
if [[ "$status" -eq 0 ]]; then
  fail_case "an unset tag variable fails" "exit 0" "$(cat "$LOG")"
elif ! grep -Fx "ERROR: Expected the TAG environment variable to be set already." "${LOG}.stderr" > /dev/null ||
  ! grep -Fx "Please run the export_tag command first." "${LOG}.stderr" > /dev/null; then
  fail_case "an unset tag variable names export_tag on stderr" "stderr:" "$(cat "${LOG}.stderr")"
elif grep -F "export_tag" "$LOG" > /dev/null || grep -F "ERROR:" "$LOG" > /dev/null; then
  fail_case "an unset tag variable's error is not on stdout" "$(cat "$LOG")"
elif [[ "$(cat "$BASH_ENV_FILE")" != "export EXPORT_TEST_SENTINEL=1" ]]; then
  fail_case "an unset tag variable leaves BASH_ENV unchanged" "$(cat "$BASH_ENV_FILE")"
else
  pass_case
fi

# Without BASH_ENV there is nowhere to export to: fail and say so.
status=0
(
  cd "$TMP" || exit 1
  env -u BASH_ENV PARAM_IMAGE="ghcr.io/org/app" PARAM_TAG_ENV_VAR="TAG" TAG="1.2.3" \
    PARAM_IMAGE_REF_ENV_VAR="IMAGE_REF" PATH="${FAKE_BIN}:${ORIGINAL_PATH}" \
    "$BASH_BIN" "$SCRIPT" > "$LOG" 2> "${LOG}.stderr"
) || status=$?
if [[ "$status" -eq 0 ]]; then
  fail_case "an unset BASH_ENV fails" "exit 0" "$(cat "$LOG")"
elif ! grep -Fx "ERROR: BASH_ENV is unset, so IMAGE_REF cannot be passed to later steps." "${LOG}.stderr" > /dev/null; then
  fail_case "an unset BASH_ENV says so on stderr" "stderr:" "$(cat "${LOG}.stderr")"
else
  pass_case
fi

printf 'passed=%s failed=%s\n' "$PASSED" "$FAILED"
if [[ "$FAILED" -ne 0 ]]; then
  exit 1
fi
