#!/usr/bin/env bash
# Local image checks in src/scripts/tag.sh, against fake docker, podman and
# buildah that keep their images in one list.
#
# Locks these behaviours:
#   each tool checks for a local image with its own command: docker and
#     podman with `image inspect`, buildah with `inspect --type image`
#     (buildah has no image subcommand)
#   a local source image is tagged without a pull, under every tool
#   a missing source image is pulled once, then tagged
#   append_tags_to_source checks and tags source_image:<tag> for each tag
#
# Run from a checkout:
#   bash test/tag_test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/src/scripts/tag.sh"
ORIGINAL_PATH="${PATH}"

SOURCE="ghcr.io/org/app"
TARGET="registry.example/org/app"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE_BIN="${TMP}/fake-bin"
IMAGES="${TMP}/images.txt"
CALLS="${TMP}/calls.log"
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

# docker and podman: `image inspect`, `pull` and `tag` against IMAGES.
cat > "${FAKE_BIN}/docker" << 'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "${FAKE_CALLS}"
case "$1" in
  image)
    [[ "${2:-}" == "inspect" ]] || exit 1
    grep -Fxq -- "$3" "${FAKE_IMAGES}"
    ;;
  pull) printf '%s\n' "$2" >> "${FAKE_IMAGES}" ;;
  tag)
    grep -Fxq -- "$2" "${FAKE_IMAGES}" || { echo "no such image: $2" >&2; exit 1; }
    printf '%s\n' "$3" >> "${FAKE_IMAGES}"
    ;;
  *) echo "unexpected command: $*" >&2; exit 1 ;;
esac
EOF
cp "${FAKE_BIN}/docker" "${FAKE_BIN}/podman"

# buildah: no image subcommand, as in the real CLI; `inspect --type image`
# checks for a local image.
cat > "${FAKE_BIN}/buildah" << 'EOF'
#!/usr/bin/env bash
printf 'buildah %s\n' "$*" >> "${FAKE_CALLS}"
case "$1" in
  inspect)
    [[ "${2:-}" == "--type" && "${3:-}" == "image" ]] || exit 125
    grep -Fxq -- "$4" "${FAKE_IMAGES}" || exit 125
    ;;
  pull) printf '%s\n' "$2" >> "${FAKE_IMAGES}" ;;
  tag)
    grep -Fxq -- "$2" "${FAKE_IMAGES}" || { echo "no such image: $2" >&2; exit 125; }
    printf '%s\n' "$3" >> "${FAKE_IMAGES}"
    ;;
  *) echo "Error: unknown command \"$1\" for \"buildah\"" >&2; exit 125 ;;
esac
EOF
chmod +x "${FAKE_BIN}/circleci" "${FAKE_BIN}/docker" "${FAKE_BIN}/podman" "${FAKE_BIN}/buildah"

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

# run_tag TOOL APPEND [IMAGE ...]: run tag.sh with tags 1.2.3 and latest, and
# with only the given images present locally.
run_tag() {
  local tool="$1" append="$2"
  shift 2
  local status=0
  printf '1.2.3\nlatest\n' > "${TMP}/tags.txt"
  : > "$CALLS"
  : > "$IMAGES"
  if [[ $# -gt 0 ]]; then
    printf '%s\n' "$@" > "$IMAGES"
  fi
  env PATH="${FAKE_BIN}:${ORIGINAL_PATH}" FAKE_CALLS="$CALLS" FAKE_IMAGES="$IMAGES" \
    PARAM_APPEND_TAGS_TO_SOURCE="$append" PARAM_PUSH=0 PARAM_TAGS_FILE="${TMP}/tags.txt" \
    PARAM_SOURCE_IMAGE="$SOURCE" PARAM_TARGET_IMAGE="$TARGET" PARAM_TOOL="$tool" \
    bash "$SCRIPT" > "${TMP}/run.log" 2>&1 || status=$?
  printf '%s' "$status"
}

inspect_call() {
  if [[ "$1" == "buildah" ]]; then
    printf 'buildah inspect --type image %s' "$2"
  else
    printf '%s image inspect %s' "$1" "$2"
  fi
}

has_call() {
  grep -Fxq -- "$1" "$CALLS"
}

count_calls() {
  grep -c -- "$1" "$CALLS" || true
}

check_local_source() {
  local tool="$1" name="${1}: a local source image is tagged without a pull" status
  status="$(run_tag "$tool" 0 "$SOURCE")"
  if [[ "$status" -ne 0 ]]; then
    fail_case "$name" "exit ${status}" "$(cat "${TMP}/run.log")"
  elif ! has_call "$(inspect_call "$tool" "$SOURCE")"; then
    fail_case "$name" "expected: $(inspect_call "$tool" "$SOURCE")" "$(cat "$CALLS")"
  elif [[ "$(count_calls " pull ")" -ne 0 ]]; then
    fail_case "$name" "pulled a local image" "$(cat "$CALLS")"
  elif ! has_call "${tool} tag ${SOURCE} ${TARGET}:1.2.3" || ! has_call "${tool} tag ${SOURCE} ${TARGET}:latest"; then
    fail_case "$name" "missing tag calls" "$(cat "$CALLS")"
  elif ! grep -Fq "Source image exists locally: ${SOURCE}" "${TMP}/run.log"; then
    fail_case "$name" "did not report the local image" "$(cat "${TMP}/run.log")"
  else
    pass_case
  fi
}

check_missing_source() {
  local tool="$1" name="${1}: a missing source image is pulled once, then tagged" status
  status="$(run_tag "$tool" 0)"
  if [[ "$status" -ne 0 ]]; then
    fail_case "$name" "exit ${status}" "$(cat "${TMP}/run.log")"
  elif [[ "$(count_calls "^${tool} pull ${SOURCE}$")" -ne 1 ]]; then
    fail_case "$name" "expected one pull of ${SOURCE}" "$(cat "$CALLS")"
  elif ! has_call "${tool} tag ${SOURCE} ${TARGET}:1.2.3" || ! has_call "${tool} tag ${SOURCE} ${TARGET}:latest"; then
    fail_case "$name" "missing tag calls" "$(cat "$CALLS")"
  else
    pass_case
  fi
}

check_append_tags_to_source() {
  local tool="$1" name="${1}: append_tags_to_source tags source_image:<tag>" status
  status="$(run_tag "$tool" 1 "${SOURCE}:1.2.3" "${SOURCE}:latest")"
  if [[ "$status" -ne 0 ]]; then
    fail_case "$name" "exit ${status}" "$(cat "${TMP}/run.log")"
  elif [[ "$(count_calls " pull ")" -ne 0 ]]; then
    fail_case "$name" "pulled a local image" "$(cat "$CALLS")"
  elif ! has_call "$(inspect_call "$tool" "${SOURCE}:1.2.3")" ||
    ! has_call "${tool} tag ${SOURCE}:1.2.3 ${TARGET}:1.2.3" ||
    ! has_call "${tool} tag ${SOURCE}:latest ${TARGET}:latest"; then
    fail_case "$name" "missing per-tag inspect or tag calls" "$(cat "$CALLS")"
  else
    pass_case
  fi
}

main() {
  local tool
  for tool in docker podman buildah; do
    check_local_source "$tool"
    check_missing_source "$tool"
    check_append_tags_to_source "$tool"
  done

  printf 'passed=%s failed=%s\n' "$PASSED" "$FAILED"
  if [[ "$FAILED" -ne 0 ]]; then
    exit 1
  fi
}

main "$@"
