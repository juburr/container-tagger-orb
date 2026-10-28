#!/usr/bin/env bash
# A leading ~ in tags_file and expected_digests_file means $HOME.
#
# Parameter values reach the scripts as literal strings, so the shell never
# expands ~ in them. A value such as ~/workspace/tags.txt must still name
# $HOME/workspace/tags.txt in every script that reads or writes these files:
#   generate_tags.sh, tag.sh, push.sh, and tag_digest.sh
# ~ alone is $HOME, and ~user is left alone.
#
# Run from a checkout:
#   bash test/tilde_test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="${ROOT}/src/scripts"
ORIGINAL_PATH="${PATH}"

DIGEST="sha256:$(printf 'a%.0s' {1..64})"
REPO="registry.example/org/app"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE_BIN="${TMP}/fake-bin"
FAKE_HOME="${TMP}/home"
WORK="${TMP}/work"
CALLS="${TMP}/calls.log"
mkdir -p "$FAKE_BIN" "$FAKE_HOME/workspace" "$WORK"

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

# docker records every call; image inspect succeeds, so tag.sh does not pull.
cat > "${FAKE_BIN}/docker" << 'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "${CALLS}"
exit 0
EOF

# crane: the source digest exists, and no tag does until crane tag writes it.
cat > "${FAKE_BIN}/crane" << 'EOF'
#!/usr/bin/env bash
printf 'crane %s\n' "$*" >> "${CALLS}"
case "${1:-}" in
  digest)
    ref="$2"
    if [[ "$ref" == *@* ]]; then
      printf '%s\n' "${ref##*@}"
      exit 0
    fi
    tag="${ref##*:}"
    if [[ -f "${CRANE_TAGS}/${tag}" ]]; then
      cat "${CRANE_TAGS}/${tag}"
      exit 0
    fi
    printf 'Error: GET https://%s: MANIFEST_UNKNOWN: manifest unknown\n' "$ref" >&2
    exit 1
    ;;
  tag)
    printf '%s\n' "${2##*@}" > "${CRANE_TAGS}/$3"
    ;;
esac
EOF
chmod +x "${FAKE_BIN}/circleci" "${FAKE_BIN}/docker" "${FAKE_BIN}/crane"
export CALLS

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

# run_in_work SCRIPT [NAME=VALUE ...]: run a script from WORK with HOME set to
# FAKE_HOME, so a path that was not expanded would land in WORK/~ instead.
run_in_work() {
  local script="$1"
  shift
  local status=0
  : > "$CALLS"
  (
    cd "$WORK" || exit 1
    env HOME="$FAKE_HOME" PATH="${FAKE_BIN}:${ORIGINAL_PATH}" "$@" \
      bash "${SCRIPTS}/${script}" > "${TMP}/run.log" 2>&1
  ) || status=$?
  printf '%s' "$status"
}

no_literal_tilde() {
  [[ ! -e "${WORK}/~" ]]
}

check_generate_tags() {
  local status
  rm -f "${FAKE_HOME}/workspace/tags.txt"
  status="$(run_in_work generate_tags.sh \
    PARAM_TAGS_FILE='~/workspace/tags.txt' PARAM_GIT_TAG_PREFIX="" PARAM_GIT_TAG="" \
    CIRCLE_TAG="" CIRCLE_BRANCH="feature/x" CIRCLE_SHA1="0123456789abcdef" CIRCLE_BUILD_NUM="1")"
  if [[ "$status" -ne 0 ]]; then
    fail_case "generate_tags writes ~/workspace/tags.txt" "exit ${status}" "$(cat "${TMP}/run.log")"
  elif [[ "$(cat "${FAKE_HOME}/workspace/tags.txt" 2>/dev/null)" != "dev-01234567" ]]; then
    fail_case "generate_tags writes ~/workspace/tags.txt" "missing \$HOME/workspace/tags.txt" "$(cat "${TMP}/run.log")"
  elif ! no_literal_tilde; then
    fail_case "generate_tags writes ~/workspace/tags.txt" "created a literal ~ directory"
  else
    pass_case
  fi
}

check_tag_and_push() {
  local status
  printf '1.2.3\nlatest\n' > "${FAKE_HOME}/workspace/tags.txt"

  status="$(run_in_work tag.sh \
    PARAM_TAGS_FILE='~/workspace/tags.txt' PARAM_SOURCE_IMAGE="local" \
    PARAM_TARGET_IMAGE="${REPO}" PARAM_TOOL="docker" PARAM_APPEND_TAGS_TO_SOURCE="0" PARAM_PUSH="0")"
  if [[ "$status" -ne 0 ]]; then
    fail_case "tag reads ~/workspace/tags.txt" "exit ${status}" "$(cat "${TMP}/run.log")"
  elif ! grep -Fx "docker tag local ${REPO}:1.2.3" "$CALLS" > /dev/null ||
    ! grep -Fx "docker tag local ${REPO}:latest" "$CALLS" > /dev/null; then
    fail_case "tag reads ~/workspace/tags.txt" "missing docker tag calls" "$(cat "$CALLS")"
  else
    pass_case
  fi

  status="$(run_in_work push.sh \
    PARAM_TAGS_FILE='~/workspace/tags.txt' PARAM_TARGET_IMAGE="${REPO}" PARAM_TOOL="docker")"
  if [[ "$status" -ne 0 ]]; then
    fail_case "push reads ~/workspace/tags.txt" "exit ${status}" "$(cat "${TMP}/run.log")"
  elif ! grep -Fx "docker push ${REPO}:1.2.3" "$CALLS" > /dev/null ||
    ! grep -Fx "docker push ${REPO}:latest" "$CALLS" > /dev/null; then
    fail_case "push reads ~/workspace/tags.txt" "missing docker push calls" "$(cat "$CALLS")"
  else
    pass_case
  fi

  # ~ alone is $HOME, which is a directory rather than a tags file.
  status="$(run_in_work tag.sh \
    PARAM_TAGS_FILE='~' PARAM_SOURCE_IMAGE="local" \
    PARAM_TARGET_IMAGE="${REPO}" PARAM_TOOL="docker" PARAM_APPEND_TAGS_TO_SOURCE="0" PARAM_PUSH="0")"
  if [[ "$status" -eq 0 ]] || ! grep -Fx "ERROR: Unable to find tags file: ${FAKE_HOME}" "${TMP}/run.log" > /dev/null; then
    fail_case "~ alone is expanded to \$HOME" "exit ${status}" "$(cat "${TMP}/run.log")"
  else
    pass_case
  fi

  # ~user is not this user's home, so it is left alone.
  status="$(run_in_work push.sh \
    PARAM_TAGS_FILE='~nobody/tags.txt' PARAM_TARGET_IMAGE="${REPO}" PARAM_TOOL="docker")"
  if [[ "$status" -eq 0 ]] || ! grep -Fx "ERROR: Unable to find tags file: ~nobody/tags.txt" "${TMP}/run.log" > /dev/null; then
    fail_case "~user is not expanded" "exit ${status}" "$(cat "${TMP}/run.log")"
  else
    pass_case
  fi
}

check_tag_digest() {
  local status
  export CRANE_TAGS="${TMP}/crane-tags"
  rm -rf "$CRANE_TAGS"
  mkdir -p "$CRANE_TAGS"
  printf '1.2.3\nlatest\n' > "${FAKE_HOME}/workspace/tags.txt"
  printf '1.2.3 absent\nlatest absent\n' > "${FAKE_HOME}/workspace/expected.txt"

  status="$(run_in_work tag_digest.sh \
    PARAM_IMAGE_DIGEST_REF="${REPO}@${DIGEST}" \
    PARAM_TAGS_FILE='~/workspace/tags.txt' \
    PARAM_EXPECTED_DIGESTS_FILE='~/workspace/expected.txt')"
  if [[ "$status" -ne 0 ]]; then
    fail_case "tag_digest reads ~/ tags and expected digests files" "exit ${status}" "$(cat "${TMP}/run.log")"
  elif [[ "$(cat "${CRANE_TAGS}/1.2.3" 2>/dev/null)" != "$DIGEST" || "$(cat "${CRANE_TAGS}/latest" 2>/dev/null)" != "$DIGEST" ]]; then
    fail_case "tag_digest reads ~/ tags and expected digests files" "tags were not written" "$(cat "$CALLS")"
  elif ! grep -F "Comparing with ${FAKE_HOME}/workspace/expected.txt" "${TMP}/run.log" > /dev/null; then
    fail_case "tag_digest reads ~/ tags and expected digests files" "expected digests file was not used" "$(cat "${TMP}/run.log")"
  else
    pass_case
  fi
}

main() {
  check_generate_tags
  check_tag_and_push
  check_tag_digest

  printf 'passed=%s failed=%s\n' "$PASSED" "$FAILED"
  if [[ "$FAILED" -ne 0 ]]; then
    exit 1
  fi
}

main "$@"
