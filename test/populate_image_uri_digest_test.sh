#!/usr/bin/env bash
# Digest publishing for src/scripts/populate_image_uri_digest.sh.
#
# Locks two failures:
#   localhost:5000/org/app:1.2.3 must keep the registry port
#   a failed crane/docker read must exit non-zero and leave BASH_ENV unchanged
#
# Run from a checkout:
#   bash test/populate_image_uri_digest_test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${DIGEST_SCRIPT:-${ROOT}/src/scripts/populate_image_uri_digest.sh}"
BASH_BIN="$(command -v bash)"

SHA256="$(printf 'a%.0s' {1..64})"
SHA384="$(printf 'b%.0s' {1..96})"
SHA512="$(printf 'c%.0s' {1..128})"
SHA256_UPPER="$(printf '%s' "$SHA256" | tr '[:lower:]' '[:upper:]')"

if [[ "${#SHA256}" -ne 64 || "${#SHA384}" -ne 96 || "${#SHA512}" -ne 128 ]]; then
  printf 'digest fixtures have the wrong length\n' >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ESSENTIALS="${TMP}/essentials"
BOTH="${TMP}/both"
DOCKER_ONLY="${TMP}/docker-only"
NEITHER="${TMP}/neither"
mkdir -p "$ESSENTIALS" "$BOTH" "$DOCKER_ONLY" "$NEITHER"

for cmd in bash mktemp cat rm tr; do
  ln -s "$(command -v "$cmd")" "${ESSENTIALS}/${cmd}"
done

cat > "${ESSENTIALS}/circleci" << 'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "env" && "${2:-}" == "subst" ]]; then
  printf '%s\n' "${3-}"
  exit 0
fi
printf 'unexpected circleci invocation: %s\n' "$*" >&2
exit 1
EOF

cat > "${BOTH}/crane" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -z "${CRANE_LOG:-}" ]]; then
  printf 'CRANE_LOG is unset\n' >&2
  exit 1
fi
printf '%s\n' "$*" >> "$CRANE_LOG"
if [[ -n "${CRANE_STDERR:-}" ]]; then
  printf '%s\n' "${CRANE_STDERR}" >&2
fi
if [[ "${CRANE_EXIT:-0}" != "0" ]]; then
  exit "${CRANE_EXIT}"
fi
printf '%s' "${CRANE_STDOUT-}"
EOF

cat > "${BOTH}/docker" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -z "${DOCKER_LOG:-}" ]]; then
  printf 'DOCKER_LOG is unset\n' >&2
  exit 1
fi
printf '%s\n' "$*" >> "$DOCKER_LOG"
if [[ "${1:-}" == "image" && "${2:-}" == "inspect" ]]; then
  if [[ "${DOCKER_LOCAL_EXIT:-0}" != "0" ]]; then
    printf '%s\n' "${DOCKER_LOCAL_STDERR:-Error: No such image: missing}" >&2
    exit "${DOCKER_LOCAL_EXIT}"
  fi
  exit 0
fi
if [[ "${1:-}" == "pull" ]]; then
  if [[ "${DOCKER_PULL_EXIT:-0}" != "0" ]]; then
    printf '%s\n' "${DOCKER_PULL_STDERR:-Error: pull access denied}" >&2
    exit "${DOCKER_PULL_EXIT}"
  fi
  exit 0
fi
if [[ "${1:-}" == "inspect" ]]; then
  if [[ "${DOCKER_INSPECT_EXIT:-0}" != "0" ]]; then
    printf '%s\n' "${DOCKER_INSPECT_STDERR:-Error: inspect failed}" >&2
    exit "${DOCKER_INSPECT_EXIT}"
  fi
  printf '%s\n' "${DOCKER_REPO_DIGEST-}"
  exit 0
fi
printf 'unexpected docker invocation: %s\n' "$*" >&2
exit 1
EOF
cp "${BOTH}/docker" "${DOCKER_ONLY}/docker"
chmod +x "${ESSENTIALS}/circleci" "${BOTH}/crane" "${BOTH}/docker" "${DOCKER_ONLY}/docker"

BASH_ENV_FILE="${TMP}/bash.env"
CRANE_LOG="${TMP}/crane.log"
DOCKER_LOG="${TMP}/docker.log"
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

reset_outputs() {
  : > "$CRANE_LOG"
  : > "$DOCKER_LOG"
  printf 'export DIGEST_TEST_SENTINEL=1\n' > "$BASH_ENV_FILE"
}

clear_tool_env() {
  unset CRANE_EXIT CRANE_STDOUT CRANE_STDERR
  unset DOCKER_LOCAL_EXIT DOCKER_LOCAL_STDERR
  unset DOCKER_PULL_EXIT DOCKER_PULL_STDERR
  unset DOCKER_INSPECT_EXIT DOCKER_INSPECT_STDERR DOCKER_REPO_DIGEST
}

run_script() {
  local path_prefix="$1"
  local uri_var="$2"
  local uri="$3"
  local digest_var="$4"
  local keep_bash_env="${5:-}"
  if [[ -z "$keep_bash_env" ]]; then
    export BASH_ENV="$BASH_ENV_FILE"
  fi
  # shellcheck disable=SC2163
  export "${uri_var}=${uri}"
  export PARAM_IMAGE_URI_ENV_VAR="$uri_var"
  export PARAM_IMAGE_URI_DIGEST_ENV_VAR="$digest_var"
  export CRANE_LOG DOCKER_LOG
  export CRANE_EXIT="${CRANE_EXIT:-0}"
  export CRANE_STDOUT="${CRANE_STDOUT-}"
  export CRANE_STDERR="${CRANE_STDERR-}"
  export DOCKER_LOCAL_EXIT="${DOCKER_LOCAL_EXIT:-0}"
  export DOCKER_LOCAL_STDERR="${DOCKER_LOCAL_STDERR-}"
  export DOCKER_PULL_EXIT="${DOCKER_PULL_EXIT:-0}"
  export DOCKER_PULL_STDERR="${DOCKER_PULL_STDERR-}"
  export DOCKER_INSPECT_EXIT="${DOCKER_INSPECT_EXIT:-0}"
  export DOCKER_INSPECT_STDERR="${DOCKER_INSPECT_STDERR-}"
  export DOCKER_REPO_DIGEST="${DOCKER_REPO_DIGEST-}"
  local status=0
  PATH="${path_prefix}:${ESSENTIALS}" "$BASH_BIN" "$SCRIPT" >"$LOG" 2>&1 || status=$?
  printf '%s' "$status"
}

exported_value() {
  local var_name="$1"
  # shellcheck disable=SC2016 # $1 and $2 belong to the child bash, not this script.
  env -i "$BASH_BIN" --noprofile --norc -c 'source "$1"; printf "%s" "${!2}"' bash "$BASH_ENV_FILE" "$var_name"
}

assert_unchanged_env() {
  local name="$1"
  local actual
  actual="$(cat "$BASH_ENV_FILE")"
  if [[ "$actual" != "export DIGEST_TEST_SENTINEL=1" ]]; then
    fail_case "$name" "BASH_ENV changed:" "$actual"
    return 1
  fi
}

expect_published() {
  local name="$1"
  local path_prefix="$2"
  local uri="$3"
  local expected="$4"
  local uri_var="${5:-IMAGE_URI}"
  local digest_var="${6:-IMAGE_URI_DIGEST}"
  reset_outputs
  local status
  status="$(run_script "$path_prefix" "$uri_var" "$uri" "$digest_var")"
  if [[ "$status" -ne 0 ]]; then
    fail_case "$name" "exit ${status}" "$(cat "$LOG")"
    return
  fi
  if ! grep -F 'Done setting environment variable.' "$LOG" >/dev/null; then
    fail_case "$name" "missing done line" "$(cat "$LOG")"
    return
  fi
  if grep -E '^Error:' "$LOG" >/dev/null; then
    fail_case "$name" "success log contains an error" "$(cat "$LOG")"
    return
  fi
  local got sentinel
  got="$(exported_value "$digest_var")"
  sentinel="$(exported_value DIGEST_TEST_SENTINEL)"
  if [[ "$got" != "$expected" ]]; then
    fail_case "$name" "expected ${expected}" "got ${got}" "$(cat "$LOG")"
    return
  fi
  if [[ "$sentinel" != "1" ]]; then
    fail_case "$name" "BASH_ENV was replaced instead of appended" "$(cat "$BASH_ENV_FILE")"
    return
  fi
  if ! grep -F "  DIGEST=${expected##*@}" "$LOG" >/dev/null; then
    fail_case "$name" "digest was not logged" "$(cat "$LOG")"
    return
  fi
  if grep -F "  DIGEST=${uri}" "$LOG" >/dev/null; then
    fail_case "$name" "logged the image URI as the digest" "$(cat "$LOG")"
    return
  fi
  pass_case
}

expect_refused() {
  local name="$1"
  local path_prefix="$2"
  local uri="$3"
  local needle="$4"
  local uri_var="${5:-IMAGE_URI}"
  local digest_var="${6:-IMAGE_URI_DIGEST}"
  local keep_bash_env="${7:-}"
  reset_outputs
  local status
  status="$(run_script "$path_prefix" "$uri_var" "$uri" "$digest_var" "$keep_bash_env")"
  if [[ "$status" -eq 0 ]]; then
    fail_case "$name" "expected a non-zero exit" "$(cat "$LOG")"
    return
  fi
  if grep -F 'Done setting environment variable.' "$LOG" >/dev/null; then
    fail_case "$name" "published after a failed read" "$(cat "$LOG")"
    return
  fi
  if ! grep -F "$needle" "$LOG" >/dev/null; then
    fail_case "$name" "missing [${needle}]" "$(cat "$LOG")"
    return
  fi
  if [[ -z "$keep_bash_env" ]] && ! assert_unchanged_env "$name"; then
    return
  fi
  pass_case
}

crane_was_called_with() {
  local uri="$1"
  local actual
  actual="$(cat "$CRANE_LOG")"
  [[ "$actual" == "digest ${uri}" ]]
}

run_reference_cases() {
  local -a cases=(
    "ghcr.io/org/repo:1.2.3|ghcr.io/org/repo"
    "ghcr.io/org/repo:latest|ghcr.io/org/repo"
    "localhost:5000/org/app:1.2.3|localhost:5000/org/app"
    "localhost:5000/org/app|localhost:5000/org/app"
    "127.0.0.1:5000/org/app:1.2.3|127.0.0.1:5000/org/app"
    "myregistry:5000/foo/bar|myregistry:5000/foo/bar"
    "registry.example.com:443/a/b/c:latest|registry.example.com:443/a/b/c"
    "ubuntu:22.04|ubuntu"
    "ubuntu|ubuntu"
    "docker.io/library/ubuntu:22.04|docker.io/library/ubuntu"
    "[::1]:5000/org/app:1.2.3|[::1]:5000/org/app"
  )
  local entry uri name
  for entry in "${cases[@]}"; do
    uri="${entry%%|*}"
    name="${entry#*|}"
    clear_tool_env
    CRANE_STDOUT="sha256:${SHA256}"
    expect_published "crane ${uri}" "$BOTH" "$uri" "${name}@sha256:${SHA256}"
    if ! crane_was_called_with "$uri"; then
      fail_case "crane argv ${uri}" "got [$(cat "$CRANE_LOG")]"
    else
      pass_case
    fi
    if [[ -s "$DOCKER_LOG" ]]; then
      fail_case "crane preferred over docker for ${uri}" "$(cat "$DOCKER_LOG")"
    else
      pass_case
    fi
  done

  # Docker treats a colon with no repository path as a tag.
  clear_tool_env
  CRANE_STDOUT="sha256:${SHA256}"
  expect_published "crane localhost:5000 is name localhost tag 5000" "$BOTH" "localhost:5000" "localhost@sha256:${SHA256}"

  local digested="ghcr.io/org/repo@sha256:${SHA256}"
  clear_tool_env
  CRANE_STDOUT="sha256:${SHA256}"
  expect_published "crane digest reference keeps the repository" "$BOTH" "$digested" "ghcr.io/org/repo@sha256:${SHA256}"
  if ! crane_was_called_with "$digested"; then
    fail_case "crane argv digest reference" "got [$(cat "$CRANE_LOG")]"
  else
    pass_case
  fi

  local tagged_digest="localhost:5000/org/app:1.2.3@sha256:${SHA256}"
  clear_tool_env
  CRANE_STDOUT="sha384:${SHA384}"
  expect_published "crane tag and digest reference keeps the port" "$BOTH" "$tagged_digest" "localhost:5000/org/app@sha384:${SHA384}"
}

run_digest_shape_cases() {
  clear_tool_env
  CRANE_STDOUT=$' \tsha256:'"${SHA256}"$'\r\n'
  expect_published "crane trims whitespace around a digest" "$BOTH" "ghcr.io/org/repo:1.2.3" "ghcr.io/org/repo@sha256:${SHA256}"

  clear_tool_env
  CRANE_STDOUT="sha256:${SHA256_UPPER}"
  expect_published "crane lowercases a hex digest" "$BOTH" "ghcr.io/org/repo:1.2.3" "ghcr.io/org/repo@sha256:${SHA256}"

  clear_tool_env
  CRANE_STDOUT="sha384:${SHA384}"
  expect_published "crane accepts sha384" "$BOTH" "ubuntu:22.04" "ubuntu@sha384:${SHA384}"

  clear_tool_env
  CRANE_STDOUT="sha512:${SHA512}"
  expect_published "crane accepts sha512" "$BOTH" "ubuntu:22.04" "ubuntu@sha512:${SHA512}"

  clear_tool_env
  CRANE_STDOUT="sha256:${SHA256}"
  CRANE_STDERR="warning: using an insecure registry"
  expect_published "crane warning on success still publishes" "$BOTH" "ghcr.io/org/repo:1" "ghcr.io/org/repo@sha256:${SHA256}"
  if ! grep -F "warning: using an insecure registry" "$LOG" >/dev/null; then
    fail_case "crane warning is visible" "$(cat "$LOG")"
  else
    pass_case
  fi

  clear_tool_env
  CRANE_STDOUT="sha256:${SHA256}"
  expect_published "custom env var names" "$BOTH" "localhost:5000/org/app:9" "localhost:5000/org/app@sha256:${SHA256}" "DEPLOY_IMAGE" "COSIGN_REF"
}

run_docker_cases() {
  local uri="localhost:5000/org/app:1.2.3"
  clear_tool_env
  DOCKER_LOCAL_EXIT=0
  DOCKER_REPO_DIGEST="docker.io/library/app@sha256:${SHA256_UPPER}"
  expect_published "docker rebuilds the requested name and lowercases the digest" "$DOCKER_ONLY" "$uri" "localhost:5000/org/app@sha256:${SHA256}"
  if grep -F "pull ${uri}" "$DOCKER_LOG" >/dev/null; then
    fail_case "docker does not pull an image that is already local" "$(cat "$DOCKER_LOG")"
  else
    pass_case
  fi
  if ! grep -F "image inspect ${uri}" "$DOCKER_LOG" >/dev/null; then
    fail_case "docker inspects the original reference" "$(cat "$DOCKER_LOG")"
  else
    pass_case
  fi
  if ! grep -F -- "--format={{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}" "$DOCKER_LOG" >/dev/null; then
    fail_case "docker digest inspect format" "$(cat "$DOCKER_LOG")"
  else
    pass_case
  fi

  clear_tool_env
  DOCKER_LOCAL_EXIT=1
  DOCKER_LOCAL_STDERR="Error: No such image: ${uri}"
  DOCKER_PULL_EXIT=0
  DOCKER_REPO_DIGEST="example.com:5000/mirror/app@sha256:${SHA256}"
  expect_published "docker pulls a missing image and still keeps the port" "$DOCKER_ONLY" "$uri" "localhost:5000/org/app@sha256:${SHA256}"
  if ! grep -F "pull ${uri}" "$DOCKER_LOG" >/dev/null; then
    fail_case "docker pull was not called" "$(cat "$DOCKER_LOG")"
  else
    pass_case
  fi

  clear_tool_env
  DOCKER_LOCAL_EXIT=1
  DOCKER_LOCAL_STDERR="error: no such image: ${uri}"
  DOCKER_REPO_DIGEST="localhost:5000/org/app@sha256:${SHA256}"
  expect_published "docker accepts a lowercase missing-image error" "$DOCKER_ONLY" "$uri" "localhost:5000/org/app@sha256:${SHA256}"
}

run_failure_cases() {
  local uri="localhost:5000/org/app:1.2.3"

  clear_tool_env
  CRANE_EXIT=1
  CRANE_STDERR="fatal: registry unreachable"
  DOCKER_REPO_DIGEST="localhost:5000/org/app@sha256:${SHA256}"
  expect_refused "crane failure does not publish" "$BOTH" "$uri" "crane digest failed for '${uri}'"
  if [[ -s "$DOCKER_LOG" ]]; then
    fail_case "crane failure does not fall through to docker" "$(cat "$DOCKER_LOG")"
  else
    pass_case
  fi
  if ! grep -F "fatal: registry unreachable" "$LOG" >/dev/null; then
    fail_case "crane stderr is shown" "$(cat "$LOG")"
  else
    pass_case
  fi

  clear_tool_env
  CRANE_EXIT=0
  CRANE_STDOUT=""
  expect_refused "crane empty stdout does not publish" "$BOTH" "$uri" "no registry digest was returned"

  clear_tool_env
  CRANE_STDOUT="sha256:${SHA256:0:63}"
  expect_refused "crane short digest does not publish" "$BOTH" "$uri" "is not a sha256, sha384, or sha512 digest"

  clear_tool_env
  CRANE_STDOUT="<no value>"
  expect_refused "crane <no value> does not publish" "$BOTH" "$uri" "no registry digest was returned"

  clear_tool_env
  CRANE_STDOUT="$uri"
  expect_refused "crane image URI is not a digest" "$BOTH" "$uri" "is not a sha256, sha384, or sha512 digest"

  clear_tool_env
  CRANE_STDOUT="sha256:${SHA256} trailing"
  expect_refused "crane trailing junk does not publish" "$BOTH" "$uri" "is not a sha256, sha384, or sha512 digest"

  clear_tool_env
  CRANE_STDOUT=$'sha256:'"${SHA256}"$'\nsha256:'"${SHA256}"
  expect_refused "crane multiline digest does not publish" "$BOTH" "$uri" "is not a sha256, sha384, or sha512 digest"

  clear_tool_env
  expect_refused "neither crane nor docker does not publish" "$NEITHER" "$uri" "neither crane nor docker is available"

  clear_tool_env
  CRANE_STDOUT="sha256:${SHA256}"
  expect_refused "empty image URI does not publish" "$BOTH" "" "Run populate_image_uri before populate_image_uri_digest."

  clear_tool_env
  CRANE_STDOUT="sha256:${SHA256}"
  expect_refused "whitespace in the image URI does not publish" "$BOTH" "ghcr.io/org/repo:1.2.3 extra" "contains whitespace"

  clear_tool_env
  CRANE_STDOUT="sha256:${SHA256}"
  expect_refused "a second tag colon does not publish" "$BOTH" "repo:tag:extra" "could not parse a repository name"

  clear_tool_env
  CRANE_STDOUT="sha256:${SHA256}"
  expect_refused "trailing slash does not publish" "$BOTH" "localhost:5000/" "could not parse a repository name"

  clear_tool_env
  CRANE_STDOUT="sha256:${SHA256}"
  reset_outputs
  local status
  status="$(run_script "$BOTH" "IMAGE_URI" "$uri" "bad-name")"
  if [[ "$status" -eq 0 ]]; then
    fail_case "bad digest env var name" "exit 0" "$(cat "$LOG")"
  elif ! grep -F "is not a shell identifier" "$LOG" >/dev/null; then
    fail_case "bad digest env var name" "$(cat "$LOG")"
  elif ! assert_unchanged_env "bad digest env var name"; then
    :
  elif [[ -s "$CRANE_LOG" ]]; then
    fail_case "bad digest env var name called crane" "$(cat "$CRANE_LOG")"
  else
    pass_case
  fi

  clear_tool_env
  CRANE_STDOUT="sha256:${SHA256}"
  reset_outputs
  unset BASH_ENV
  status="$(run_script "$BOTH" "IMAGE_URI" "$uri" "IMAGE_URI_DIGEST" keep)"
  if [[ "$status" -eq 0 ]]; then
    fail_case "unset BASH_ENV" "exit 0" "$(cat "$LOG")"
  elif ! grep -F "BASH_ENV is unset" "$LOG" >/dev/null; then
    fail_case "unset BASH_ENV" "$(cat "$LOG")"
  elif [[ -s "$CRANE_LOG" ]]; then
    fail_case "unset BASH_ENV called crane" "$(cat "$CRANE_LOG")"
  else
    pass_case
  fi

  # chmod a-w does not stop root: uid 0 bypasses the mode bits. A directory
  # cannot be opened for append by any user, so the write fails either way.
  clear_tool_env
  reset_outputs
  local env_dir="${TMP}/bash-env-is-a-directory"
  mkdir -p "$env_dir"
  CRANE_STDOUT="sha256:${SHA256}"
  export BASH_ENV="$env_dir"
  status="$(run_script "$BOTH" "IMAGE_URI" "$uri" "IMAGE_URI_DIGEST" keep)"
  unset BASH_ENV
  if [[ "$status" -eq 0 ]]; then
    fail_case "unwritable BASH_ENV" "exit 0" "$(cat "$LOG")"
  elif ! grep -F "export IMAGE_URI_DIGEST=" "$LOG" >/dev/null; then
    fail_case "unwritable BASH_ENV" "did not reach the export" "$(cat "$LOG")"
  elif grep -F 'Done setting environment variable.' "$LOG" >/dev/null; then
    fail_case "unwritable BASH_ENV still finished" "$(cat "$LOG")"
  elif [[ -n "$(ls -A "$env_dir")" ]]; then
    fail_case "unwritable BASH_ENV" "wrote into the directory" "$(ls -A "$env_dir")"
  elif ! assert_unchanged_env "unwritable BASH_ENV"; then
    :
  else
    pass_case
  fi

  clear_tool_env
  DOCKER_LOCAL_EXIT=1
  DOCKER_LOCAL_STDERR="Cannot connect to the Docker daemon at unix:///var/run/docker.sock"
  DOCKER_REPO_DIGEST="localhost:5000/org/app@sha256:${SHA256}"
  expect_refused "docker daemon failure does not pull" "$DOCKER_ONLY" "$uri" "docker image inspect failed"
  if grep -F "pull ${uri}" "$DOCKER_LOG" >/dev/null; then
    fail_case "docker daemon failure still pulled" "$(cat "$DOCKER_LOG")"
  else
    pass_case
  fi

  clear_tool_env
  DOCKER_LOCAL_EXIT=1
  DOCKER_LOCAL_STDERR="Error: No such image: ${uri}"
  DOCKER_PULL_EXIT=1
  DOCKER_PULL_STDERR="Error: pull access denied for ${uri}"
  expect_refused "docker pull failure does not publish" "$DOCKER_ONLY" "$uri" "docker pull failed"
  if grep -E '^inspect ' "$DOCKER_LOG" >/dev/null; then
    fail_case "docker pull failure still inspected a digest" "$(cat "$DOCKER_LOG")"
  else
    pass_case
  fi
  if ! grep -F "pull access denied" "$LOG" >/dev/null; then
    fail_case "docker pull stderr is shown" "$(cat "$LOG")"
  else
    pass_case
  fi

  clear_tool_env
  DOCKER_LOCAL_EXIT=0
  DOCKER_INSPECT_EXIT=1
  DOCKER_INSPECT_STDERR="Error: inspect failed: daemon disconnected"
  expect_refused "docker inspect failure does not publish" "$DOCKER_ONLY" "$uri" "docker inspect failed"

  clear_tool_env
  DOCKER_LOCAL_EXIT=0
  DOCKER_INSPECT_EXIT=0
  DOCKER_REPO_DIGEST=""
  expect_refused "docker empty RepoDigest does not publish" "$DOCKER_ONLY" "$uri" "no registry digest was returned"

  clear_tool_env
  DOCKER_LOCAL_EXIT=0
  DOCKER_REPO_DIGEST="<no value>"
  expect_refused "docker <no value> RepoDigest does not publish" "$DOCKER_ONLY" "$uri" "no registry digest was returned"

  clear_tool_env
  DOCKER_LOCAL_EXIT=0
  DOCKER_REPO_DIGEST="localhost:5000/org/app@sha256:${SHA256:0:10}"
  expect_refused "docker short RepoDigest does not publish" "$DOCKER_ONLY" "$uri" "is not a sha256, sha384, or sha512 digest"
}

main() {
  run_reference_cases
  run_digest_shape_cases
  run_docker_cases
  run_failure_cases
  printf 'passed=%s failed=%s\n' "$PASSED" "$FAILED"
  if [[ "$FAILED" -ne 0 ]]; then
    exit 1
  fi
}

main "$@"
