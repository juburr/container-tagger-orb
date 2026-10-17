#!/usr/bin/env bash
# Registry-side tagging for src/scripts/tag_digest.sh, against a fake crane.
#
# Locks these behaviours:
#   only `crane digest` and `crane tag` run, so no image content moves
#   every tag's current digest is logged before any write
#   an expected digests file that does not match stops every write
#   every tag must resolve to the source digest after writing
#
# test/tag_digest_registry_test.sh runs the real crane against registry:2.
#
# Run from a checkout:
#   bash test/tag_digest_test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/src/scripts/tag_digest.sh"
ORIGINAL_PATH="${PATH}"

REPO="registry.example:5000/org/app"
DIGEST="sha256:$(printf 'a%.0s' {1..64})"
OLD="sha256:$(printf 'b%.0s' {1..64})"
OTHER="sha256:$(printf 'c%.0s' {1..64})"
SOURCE="${REPO}@${DIGEST}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE_BIN="${TMP}/fake-bin"
NO_CRANE="${TMP}/no-crane"
mkdir -p "$FAKE_BIN" "$NO_CRANE"

# Like `circleci env subst`, expand ${NAME} references.
cat > "${FAKE_BIN}/circleci" << 'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "env" && "${2:-}" == "subst" ]]; then
  # The scripts pass values on stdin; as an argument, one starting with "-"
  # would be parsed as a flag by the real CLI.
  if [[ $# -gt 2 ]]; then
    printf 'circleci env subst: value passed as an argument: %s\n' "${*:3}" >&2
    exit 1
  fi
  input="$(cat)"
  output=""
  ref_re='^([^$]*)\$\{([A-Za-z_][A-Za-z0-9_]*)\}(.*)$'
  while [[ "$input" =~ $ref_re ]]; do
    name="${BASH_REMATCH[2]}"
    output+="${BASH_REMATCH[1]}${!name-}"
    input="${BASH_REMATCH[3]}"
  done
  printf '%s\n' "${output}${input}"
  exit 0
fi
printf 'unexpected circleci invocation: %s\n' "$*" >&2
exit 1
EOF
cp "${FAKE_BIN}/circleci" "${NO_CRANE}/circleci"

# A registry in a directory. manifests/<digest> marks a manifest that exists,
# and tags/<tag> holds the digest a tag points at. Every call is logged.
cat > "${FAKE_BIN}/crane" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_REGISTRY}/calls.log"
not_found() {
  printf '2026/01/01 00:00:00 HEAD request failed, falling back on GET: HEAD https://%s: unexpected status code 404 Not Found (HEAD responses have no body, use GET for details)\n' "$1" >&2
  printf 'Error: GET https://%s: MANIFEST_UNKNOWN: manifest unknown\n' "$1" >&2
  exit 1
}
cmd="${1:-}"
shift || true
case "$cmd" in
  digest)
    ref="$1"
    if [[ "$ref" == *@* ]]; then
      if [[ -n "${FAKE_SOURCE_ERROR:-}" ]]; then
        printf 'Error: %s\n' "$FAKE_SOURCE_ERROR" >&2
        exit 1
      fi
      digest="${ref##*@}"
      if [[ -n "${FAKE_SOURCE_DIGEST:-}" ]]; then
        printf '%s\n' "$FAKE_SOURCE_DIGEST"
        exit 0
      fi
      [[ -f "${FAKE_REGISTRY}/manifests/${digest}" ]] || not_found "$ref"
      printf '%s\n' "$digest"
      exit 0
    fi
    tag="${ref##*:}"
    if [[ -n "${FAKE_READ_ERROR_TAG:-}" && "$tag" == "$FAKE_READ_ERROR_TAG" ]]; then
      printf 'Error: GET https://%s: UNAUTHORIZED: authentication required\n' "$ref" >&2
      exit 1
    fi
    [[ -f "${FAKE_REGISTRY}/tags/${tag}" ]] || not_found "$ref"
    cat "${FAKE_REGISTRY}/tags/${tag}"
    ;;
  tag)
    src="$1"
    tag="$2"
    if [[ -n "${FAKE_TAG_ERROR_TAG:-}" && "$tag" == "$FAKE_TAG_ERROR_TAG" ]]; then
      printf 'Error: PUT https://registry.example: DENIED: requested access to the resource is denied\n' >&2
      exit 1
    fi
    digest="${src##*@}"
    [[ -f "${FAKE_REGISTRY}/manifests/${digest}" ]] || not_found "$src"
    # FAKE_TAG_STORES simulates a registry that stores a different manifest.
    printf '%s\n' "${FAKE_TAG_STORES:-$digest}" > "${FAKE_REGISTRY}/tags/${tag}"
    printf '%s:%s: digest: %s size: 1788\n' "${src%@*}" "$tag" "$digest" >&2
    ;;
  *)
    printf 'unexpected crane invocation: %s %s\n' "$cmd" "$*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${FAKE_BIN}/circleci" "${FAKE_BIN}/crane" "${NO_CRANE}/circleci"

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

# Start each case with a registry holding the source manifest and OTHER.
# Arguments are tag=digest pairs that already exist.
reset_registry() {
  FAKE_REGISTRY="${TMP}/registry"
  rm -rf "$FAKE_REGISTRY"
  mkdir -p "${FAKE_REGISTRY}/manifests" "${FAKE_REGISTRY}/tags"
  : > "${FAKE_REGISTRY}/calls.log"
  touch "${FAKE_REGISTRY}/manifests/${DIGEST}" "${FAKE_REGISTRY}/manifests/${OTHER}"
  local pair
  for pair in "$@"; do
    printf '%s\n' "${pair#*=}" > "${FAKE_REGISTRY}/tags/${pair%%=*}"
  done
  export FAKE_REGISTRY
}

write_tags() {
  printf '%s\n' "$@" > "${TMP}/tags.txt"
}

# run_tag_digest IMAGE_DIGEST [EXPECTED_FILE] [PATH_DIR]
run_tag_digest() {
  local image_digest="$1"
  local expected="${2-}"
  local path_dir="${3:-$FAKE_BIN}"
  local status=0
  PARAM_IMAGE_DIGEST="$image_digest" \
    PARAM_TAGS_FILE="${TMP}/tags.txt" \
    PARAM_EXPECTED_DIGESTS_FILE="$expected" \
    PATH="${path_dir}:${ORIGINAL_PATH}" \
    bash "$SCRIPT" > "${TMP}/run.log" 2>&1 || status=$?
  printf '%s' "$status"
}

tag_value() {
  if [[ -f "${FAKE_REGISTRY}/tags/$1" ]]; then
    cat "${FAKE_REGISTRY}/tags/$1"
  else
    printf 'absent'
  fi
}

write_calls() {
  grep -c '^tag ' "${FAKE_REGISTRY}/calls.log" || true
}

expect_rejected() {
  local name="$1"
  local status="$2"
  local message="$3"
  if [[ "$status" -eq 0 ]]; then
    fail_case "$name" "expected a non-zero exit" "$(cat "${TMP}/run.log")"
    return 1
  fi
  if ! grep -F -- "$message" "${TMP}/run.log" >/dev/null; then
    fail_case "$name" "log is missing: ${message}" "$(cat "${TMP}/run.log")"
    return 1
  fi
  return 0
}

# Reject before writing anything, and leave every tag as it was.
check_rejected_without_writes() {
  local name="$1"
  local status="$2"
  local message="$3"
  expect_rejected "$name" "$status" "$message" || return 0
  if [[ "$(write_calls)" -ne 0 ]]; then
    fail_case "$name" "wrote a tag after rejecting the run" "$(cat "${FAKE_REGISTRY}/calls.log")"
    return
  fi
  pass_case
}

run_input_cases() {
  local status bad
  reset_registry
  write_tags 1.2.3

  status="$(run_tag_digest "$SOURCE" "" "$NO_CRANE")"
  check_rejected_without_writes "missing crane fails with a clear error" "$status" "crane was not found on PATH."

  status="$(run_tag_digest "")"
  check_rejected_without_writes "empty image_digest" "$status" "image_digest is empty."

  for bad in \
    "${REPO}:1.2.3" \
    "${REPO}:1.2.3@${DIGEST}" \
    "@${DIGEST}" \
    "${REPO}@sha256:abc" \
    "${REPO}@sha256:$(printf 'A%.0s' {1..64})" \
    "${REPO}@sha512:$(printf 'a%.0s' {1..128})" \
    "${REPO}@${DIGEST}@${DIGEST}" \
    "${REPO} @${DIGEST}" \
    "registry.example:5000@${DIGEST}"
  do
    reset_registry
    status="$(run_tag_digest "$bad")"
    check_rejected_without_writes "rejects image_digest '${bad}'" "$status" "image_digest '${bad}'"
  done

  reset_registry
  rm -f "${TMP}/tags.txt"
  status="$(run_tag_digest "$SOURCE")"
  check_rejected_without_writes "missing tags file" "$status" "Unable to find tags file"

  printf '\n\n' > "${TMP}/tags.txt"
  status="$(run_tag_digest "$SOURCE")"
  check_rejected_without_writes "tags file without tags" "$status" "does not contain any tags."

  for bad in ".hidden" "-lead" "has space" "a/b" "a:b" "a@b" "$(printf 'x%.0s' {1..129})"; do
    reset_registry
    write_tags 1.2.3 "$bad"
    status="$(run_tag_digest "$SOURCE")"
    check_rejected_without_writes "rejects tag '${bad:0:20}'" "$status" "is not a valid tag."
  done

  reset_registry
  write_tags 1.2.3 latest 1.2.3
  status="$(run_tag_digest "$SOURCE")"
  check_rejected_without_writes "rejects a duplicate tag" "$status" "'1.2.3' appears more than once"
}

run_happy_cases() {
  local status
  reset_registry "latest=${OLD}" "1=${DIGEST}"
  write_tags 1.2.3 1.2 1 latest
  status="$(run_tag_digest "$SOURCE")"
  if [[ "$status" -ne 0 ]]; then
    fail_case "tags every alias" "exit ${status}" "$(cat "${TMP}/run.log")"
    return
  fi
  local tag
  for tag in 1.2.3 1.2 1 latest; do
    if [[ "$(tag_value "$tag")" != "$DIGEST" ]]; then
      fail_case "tags every alias: ${tag}" "points at $(tag_value "$tag")"
      return
    fi
  done
  pass_case

  # The record before any write, in expected_digests_file form.
  local before
  before="$(sed -n '/^Current digests, before writing/,/^Writing tags/p' "${TMP}/run.log")"
  if ! grep -Fx "  latest ${OLD}" <<< "$before" >/dev/null ||
    ! grep -Fx "  1.2.3 absent" <<< "$before" >/dev/null ||
    ! grep -Fx "  1 ${DIGEST}" <<< "$before" >/dev/null; then
    fail_case "logs every current digest before writing" "$(cat "${TMP}/run.log")"
  else
    pass_case
  fi

  # Only reads and in-place tag writes, against the right repository.
  if grep -Ev "^(digest ${REPO}(@${DIGEST}|:(1\.2\.3|1\.2|1|latest))|tag ${SOURCE} (1\.2\.3|1\.2|latest))$" \
    "${FAKE_REGISTRY}/calls.log" >/dev/null; then
    fail_case "runs only crane digest and crane tag on the source repository" "$(cat "${FAKE_REGISTRY}/calls.log")"
  else
    pass_case
  fi

  # An alias that already points at the digest is not rewritten.
  if grep -Fx "tag ${SOURCE} 1" "${FAKE_REGISTRY}/calls.log" >/dev/null; then
    fail_case "does not rewrite an alias that already points at the digest" "$(cat "${FAKE_REGISTRY}/calls.log")"
  else
    pass_case
  fi

  reset_registry
  printf '1.2.3\r\nlatest\r\n' > "${TMP}/tags.txt"
  status="$(run_tag_digest "$SOURCE")"
  if [[ "$status" -ne 0 || "$(tag_value latest)" != "$DIGEST" || "$(tag_value 1.2.3)" != "$DIGEST" ]]; then
    fail_case "accepts a tags file with CRLF line endings" "$(cat "${TMP}/run.log")"
  else
    pass_case
  fi

  reset_registry
  write_tags 1.2.3
  # shellcheck disable=SC2016 # the reference is expanded by the fake circleci
  status="$(export IMAGE_URI_DIGEST="$SOURCE"; run_tag_digest '${IMAGE_URI_DIGEST}')"
  if [[ "$status" -ne 0 || "$(tag_value 1.2.3)" != "$DIGEST" ]]; then
    fail_case "expands image_digest from an environment variable" "$(cat "${TMP}/run.log")"
  else
    pass_case
  fi
}

run_expected_cases() {
  local status expected="${TMP}/expected.txt"

  reset_registry "latest=${OLD}"
  write_tags 1.2.3 latest
  printf '# recorded by the plan job\nlatest %s\n\n1.2.3 absent\n' "$OLD" > "$expected"
  status="$(run_tag_digest "$SOURCE" "$expected")"
  if [[ "$status" -ne 0 || "$(tag_value latest)" != "$DIGEST" || "$(tag_value 1.2.3)" != "$DIGEST" ]]; then
    fail_case "writes when every expected digest matches" "$(cat "${TMP}/run.log")"
  else
    pass_case
  fi

  reset_registry "latest=${OTHER}"
  status="$(run_tag_digest "$SOURCE" "$expected")"
  check_rejected_without_writes "a moved tag stops every write" "$status" "latest: expected ${OLD}, found ${OTHER}"
  if [[ "$(tag_value latest)" != "$OTHER" || "$(tag_value 1.2.3)" != "absent" ]]; then
    fail_case "a moved tag leaves the registry unchanged" "latest=$(tag_value latest) 1.2.3=$(tag_value 1.2.3)"
  else
    pass_case
  fi

  reset_registry "latest=${OLD}" "1.2.3=${OTHER}"
  status="$(run_tag_digest "$SOURCE" "$expected")"
  check_rejected_without_writes "a tag expected absent that exists stops every write" "$status" "1.2.3: expected absent, found ${OTHER}"

  reset_registry "latest=${OLD}"
  printf 'latest %s\n' "$OLD" > "$expected"
  status="$(run_tag_digest "$SOURCE" "$expected")"
  check_rejected_without_writes "every tag needs an expected digest" "$status" "has no expected digest for tag '1.2.3'"

  printf 'latest %s\n1.2.3 absent\nedge absent\n' "$OLD" > "$expected"
  status="$(run_tag_digest "$SOURCE" "$expected")"
  check_rejected_without_writes "an expected tag must be in the tags file" "$status" "lists tag 'edge', which is not in"

  local bad
  for bad in "latest" "latest sha256:abc" "latest ${OLD} extra" "latest missing" "-bad absent"; do
    printf '%s\n1.2.3 absent\n' "$bad" > "$expected"
    status="$(run_tag_digest "$SOURCE" "$expected")"
    check_rejected_without_writes "rejects expected line '${bad:0:24}'" "$status" "is not '<tag> <sha256:digest>' or '<tag> absent'."
  done

  printf 'latest %s\nlatest %s\n1.2.3 absent\n' "$OLD" "$OLD" > "$expected"
  status="$(run_tag_digest "$SOURCE" "$expected")"
  check_rejected_without_writes "rejects a duplicate expected tag" "$status" "'latest' appears more than once"

  status="$(run_tag_digest "$SOURCE" "${TMP}/no-such-expected.txt")"
  check_rejected_without_writes "missing expected digests file" "$status" "Unable to find expected digests file"
}

run_registry_failure_cases() {
  local status
  reset_registry "latest=${OLD}"
  write_tags 1.2.3 latest

  status="$(export FAKE_READ_ERROR_TAG=latest; run_tag_digest "$SOURCE")"
  check_rejected_without_writes "an unreadable tag is not treated as absent" "$status" "UNAUTHORIZED: authentication required"
  if ! grep -F "No tag was written." "${TMP}/run.log" >/dev/null; then
    fail_case "an unreadable tag says nothing was written" "$(cat "${TMP}/run.log")"
  else
    pass_case
  fi

  rm -f "${FAKE_REGISTRY}/manifests/${DIGEST}"
  status="$(run_tag_digest "$SOURCE")"
  check_rejected_without_writes "a source digest that is not in the registry" "$status" "was not found in the registry."

  reset_registry
  status="$(export FAKE_SOURCE_ERROR="GET https://registry.example: UNAUTHORIZED: authentication required"; run_tag_digest "$SOURCE")"
  check_rejected_without_writes "an unreadable source digest" "$status" "could not read '${SOURCE}' from the registry."

  status="$(export FAKE_SOURCE_DIGEST="$OTHER"; run_tag_digest "$SOURCE")"
  check_rejected_without_writes "a registry that answers with another digest" "$status" "The registry returned ${OTHER}"

  reset_registry "latest=${OLD}"
  status="$(export FAKE_TAG_STORES="$OTHER"; run_tag_digest "$SOURCE")"
  if expect_rejected "verification catches a tag that does not resolve to the source" "$status" \
    "tag(s) do not point at ${DIGEST} after writing."; then
    pass_case
  fi

  reset_registry "latest=${OLD}"
  write_tags 1.2.3 latest 1
  status="$(export FAKE_TAG_ERROR_TAG=latest; run_tag_digest "$SOURCE")"
  if expect_rejected "a failed write reports the tags already written" "$status" \
    "These tags were already written: 1.2.3."; then
    if [[ "$(tag_value 1)" != "absent" ]]; then
      fail_case "a failed write stops before later tags" "1=$(tag_value 1)"
    else
      pass_case
    fi
  fi
}

main() {
  run_input_cases
  run_happy_cases
  run_expected_cases
  run_registry_failure_cases

  printf 'passed=%s failed=%s\n' "$PASSED" "$FAILED"
  if [[ "$FAILED" -ne 0 ]]; then
    exit 1
  fi
}

main "$@"
