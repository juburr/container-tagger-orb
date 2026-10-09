#!/usr/bin/env bash
# Tag selection battery for src/scripts/generate_tags.sh and populate_tag.sh.
#
# Golden cases are the spec, including the reported floating-tag failures:
#   v1.9.0 with v11.0.0 present must emit 1.9.0, 1.9, and 1
#   v1.2.9 with v1.23.0 present must emit 1.2.9 and 1.2
# An independent numeric oracle checks those goldens, then a generated matrix
# and a large tag set compare the script to that oracle.
#
# Run from a checkout:
#   bash test/generate_tags_test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/src/scripts/generate_tags.sh"
ORIGINAL_PATH="${PATH}"
REAL_GIT="$(command -v git)"
SHA="0123456789abcdef0123456789abcdef01234567"
SHORT_SHA="${SHA:0:8}"
ALT_SHA="abcdef0000000000000000000000000000000000"
ALT_SHORT="${ALT_SHA:0:8}"

TMP="$(mktemp -d)"
SERVER_PID=""
cleanup_test() {
  if [[ -n "${SERVER_PID}" ]]; then
    kill "${SERVER_PID}" 2>/dev/null || true
    wait "${SERVER_PID}" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup_test EXIT

FAKE_BIN="${TMP}/fake-bin"
CIRCLECI_ONLY="${TMP}/circleci-only"
mkdir -p "$FAKE_BIN" "$CIRCLECI_ONLY"

cat > "${FAKE_BIN}/circleci" << 'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "env" && "${2:-}" == "subst" ]]; then
  printf '%s\n' "${3-}"
  exit 0
fi
printf 'unexpected circleci invocation: %s\n' "$*" >&2
exit 1
EOF
cp "${FAKE_BIN}/circleci" "${CIRCLECI_ONLY}/circleci"

cat > "${FAKE_BIN}/git" << 'EOF'
#!/usr/bin/env bash
if [[ -n "${GIT_COMMAND_LOG:-}" ]]; then
  printf '%s\n' "$*" >> "$GIT_COMMAND_LOG"
fi
while [[ "${1:-}" == "-c" ]]; do
  shift
  shift || break
done
if [[ "${1:-}" == "--no-pager" ]]; then
  shift
fi
if [[ "${1:-}" == "rev-parse" && "${2:-}" == "--is-inside-work-tree" ]]; then
  case "${GIT_WORK_TREE:-true}" in
    true)
      printf 'true\n'
      exit 0
      ;;
    false)
      printf 'false\n'
      exit 0
      ;;
    *)
      echo "fatal: not a git repository (or any of the parent directories): .git" >&2
      exit 128
      ;;
  esac
fi
if [[ "${1:-}" == "remote" && "${2:-}" == "get-url" ]]; then
  if [[ -n "${GIT_REMOTE_GET_URL_EXIT:-}" && "${GIT_REMOTE_GET_URL_EXIT}" != "0" ]]; then
    echo "fatal: No such remote '${3:-}'" >&2
    exit "${GIT_REMOTE_GET_URL_EXIT}"
  fi
  if [[ -n "${GIT_REMOTE_URL:-}" ]]; then
    printf '%s\n' "${GIT_REMOTE_URL}"
  else
    printf '%s\n' "https://example.test/repo.git"
  fi
  exit 0
fi
if [[ "${1:-}" == "remote" && -z "${2:-}" ]]; then
  if [[ -n "${GIT_REMOTE_EXIT:-}" && "${GIT_REMOTE_EXIT}" != "0" ]]; then
    echo "fatal: git remote failed" >&2
    exit "${GIT_REMOTE_EXIT}"
  fi
  if [[ -n "${GIT_REMOTES:-}" ]]; then
    printf '%s\n' "${GIT_REMOTES}"
  fi
  exit 0
fi
if [[ "${1:-}" == "ls-remote" && "${2:-}" == "--refs" && "${3:-}" == "--tags" ]]; then
  remote="${4:-}"
  if [[ "${remote}" == "--" ]]; then
    remote="${5:-}"
  fi
  if [[ "${GIT_TERMINAL_PROMPT:-}" != "0" ]]; then
    echo "fatal: GIT_TERMINAL_PROMPT was '${GIT_TERMINAL_PROMPT-<unset>}', prompts are not allowed" >&2
    exit 1
  fi
  if [[ -z "${remote}" ]]; then
    echo "fatal: missing remote" >&2
    exit 1
  fi
  if [[ "${GIT_LS_REMOTE_EXIT:-0}" != "0" ]]; then
    if [[ -n "${GIT_LS_REMOTE_STDERR:-}" ]]; then
      printf '%s\n' "${GIT_LS_REMOTE_STDERR}" >&2
    else
      echo "fatal: unable to read tags from '${remote}'" >&2
    fi
    exit "${GIT_LS_REMOTE_EXIT}"
  fi
  if [[ -n "${GIT_LS_REMOTE_STDERR:-}" ]]; then
    printf '%s\n' "${GIT_LS_REMOTE_STDERR}" >&2
  fi
  if [[ -n "${GIT_LS_REMOTE_TAGS_FILE:-}" && -f "${GIT_LS_REMOTE_TAGS_FILE}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ -z "${line}" ]] && continue
      if [[ "${line}" == refs/* ]]; then
        printf '1111111111111111111111111111111111111111\t%s\n' "${line}"
      else
        printf '1111111111111111111111111111111111111111\trefs/tags/%s\n' "${line}"
      fi
    done < "${GIT_LS_REMOTE_TAGS_FILE}"
  fi
  exit 0
fi
if [[ "${1:-}" == "tag" && -z "${2:-}" ]]; then
  if [[ "${GIT_TAG_EXIT:-0}" != "0" ]]; then
    echo "fatal: detected dubious ownership in repository at '${PWD}'" >&2
    exit "${GIT_TAG_EXIT}"
  fi
  if [[ -n "${GIT_TAGS_FILE:-}" && -f "${GIT_TAGS_FILE}" ]]; then
    cat "${GIT_TAGS_FILE}"
  fi
  exit 0
fi
printf 'unexpected git invocation: %s\n' "$*" >&2
exit 1
EOF
chmod +x "${FAKE_BIN}/circleci" "${FAKE_BIN}/git" "${CIRCLECI_ONLY}/circleci"

PASSED=0
FAILED=0
FAILURE_DETAILS=0
MAX_FAILURE_DETAILS=25

fail_case() {
  local name="$1"
  shift
  FAILED=$((FAILED + 1))
  if [[ "$FAILURE_DETAILS" -lt "$MAX_FAILURE_DETAILS" ]]; then
    FAILURE_DETAILS=$((FAILURE_DETAILS + 1))
    printf 'FAIL %s\n' "$name"
    printf '  %s\n' "$@"
  elif [[ "$FAILURE_DETAILS" -eq "$MAX_FAILURE_DETAILS" ]]; then
    FAILURE_DETAILS=$((FAILURE_DETAILS + 1))
    printf 'Further failures are counted without a full diff.\n'
  fi
}

pass_case() {
  PASSED=$((PASSED + 1))
}

version_cmp() {
  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<< "${1#v}"
  IFS=. read -r b1 b2 b3 <<< "${2#v}"
  if ((10#$a1 != 10#$b1)); then
    if ((10#$a1 > 10#$b1)); then
      printf '1\n'
    else
      printf -- '-1\n'
    fi
    return
  fi
  if ((10#$a2 != 10#$b2)); then
    if ((10#$a2 > 10#$b2)); then
      printf '1\n'
    else
      printf -- '-1\n'
    fi
    return
  fi
  if ((10#$a3 != 10#$b3)); then
    if ((10#$a3 > 10#$b3)); then
      printf '1\n'
    else
      printf -- '-1\n'
    fi
    return
  fi
  printf '0\n'
}

max_version() {
  local best="" candidate cmp
  for candidate in "$@"; do
    if [[ -z "$best" ]]; then
      best="$candidate"
      continue
    fi
    cmp="$(version_cmp "$candidate" "$best")"
    if [[ "$cmp" -eq 1 ]]; then
      best="$candidate"
    fi
  done
  printf '%s' "$best"
}

normalize_repo_tag() {
  local raw="$1"
  local package="$2"
  [[ -n "$raw" ]] || return 1
  if [[ -n "$package" ]]; then
    [[ "$raw" == "$package"* ]] || return 1
    raw="${raw/"${package}/"/}"
  fi
  printf '%s' "$raw"
}

local_tag_from_circle_tag() {
  local circle_tag="$1"
  local package="$2"
  printf '%s' "${circle_tag#"${package}/"}"
}

added_tag_for() {
  local circle_tag="$1"
  local package="$2"
  local tag
  tag="$(local_tag_from_circle_tag "$circle_tag" "$package")"
  if [[ -n "$package" ]]; then
    printf '%s' "${package}/${tag}"
  else
    printf '%s' "$tag"
  fi
}

is_final_semver() {
  local body major minor patch extra
  [[ "$1" == v* ]] || return 1
  body="${1#v}"
  extra=""
  IFS=. read -r major minor patch extra <<< "$body"
  [[ -n "$major" && -n "$minor" && -n "${patch:-}" && -z "${extra:-}" ]] || return 1
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ && "$patch" =~ ^[0-9]+$ ]] || return 1
  [[ "$body" == "${major}.${minor}.${patch}" ]]
}

is_prerelease() {
  local body version suffix major minor patch
  [[ "$1" == v* ]] || return 1
  body="${1#v}"
  [[ "$body" == *-* ]] || return 1
  version="${body%%-*}"
  suffix="${body#*-}"
  # alpha, alpha1, alpha.1, and the same three shapes for beta and rc.
  # A trailing dot (rc.) is not a pre-release: the numeric identifier would be empty.
  [[ "$suffix" =~ ^(alpha|beta|rc)([0-9]+|\.[0-9]+)?$ ]] || return 1
  IFS=. read -r major minor patch <<< "$version"
  [[ -n "$major" && -n "$minor" && -n "${patch:-}" ]] || return 1
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ && "$patch" =~ ^[0-9]+$ ]] || return 1
  [[ "$version" == "${major}.${minor}.${patch}" ]]
}

collect_finals() {
  local circle_tag="$1"
  local package="$2"
  shift 2
  local raw norm
  local -a inputs=()
  if [[ "$#" -gt 0 ]]; then
    inputs=("$@")
  fi
  inputs+=("$(added_tag_for "$circle_tag" "$package")")
  local -a finals=()
  for raw in "${inputs[@]}"; do
    if ! norm="$(normalize_repo_tag "$raw" "$package")"; then
      continue
    fi
    if is_final_semver "$norm"; then
      finals+=("$norm")
    fi
  done
  if [[ "${#finals[@]}" -eq 0 ]]; then
    return 0
  fi
  printf '%s\n' "${finals[@]}"
}

oracle_lines() {
  local circle_tag="$1"
  local package="$2"
  shift 2
  local tag major minor highest highest_major highest_minor
  local -a same_major=() same_minor=() finals=()
  tag="$(local_tag_from_circle_tag "$circle_tag" "$package")"
  major="$(printf '%s' "$tag" | cut -c 2- | cut -d . -f 1)"
  minor="$(printf '%s' "$tag" | cut -c 2- | cut -d . -f 2)"

  local -a lines=()
  lines+=("${tag#v}")
  if is_prerelease "$tag"; then
    printf '%s\n' "${lines[@]}"
    return
  fi

  mapfile -t finals < <(collect_finals "$circle_tag" "$package" "$@")
  highest="$(max_version "${finals[@]}")"
  local candidate candidate_body candidate_major candidate_minor
  for candidate in "${finals[@]}"; do
    candidate_body="${candidate#v}"
    candidate_major="$(printf '%s' "$candidate_body" | cut -d . -f 1)"
    candidate_minor="$(printf '%s' "$candidate_body" | cut -d . -f 2)"
    if [[ "$candidate_major" == "$major" ]]; then
      same_major+=("$candidate")
    fi
    if [[ "$candidate_major" == "$major" && "$candidate_minor" == "$minor" ]]; then
      same_minor+=("$candidate")
    fi
  done
  highest_major="$(max_version "${same_major[@]}")"
  highest_minor="$(max_version "${same_minor[@]}")"

  if [[ "$tag" == "$highest_minor" ]]; then
    lines+=("${major}.${minor}")
  fi
  if [[ "$tag" == "$highest_major" ]]; then
    lines+=("${major}")
  fi
  if [[ "$tag" == "$highest" ]]; then
    lines+=("latest")
  fi
  printf '%s\n' "${lines[@]}"
}

assert_sort_agrees_with_oracle() {
  local -a samples=(
    v0.9.0 v0.10.0 v1.2.9 v1.2.10 v1.9.0 v1.10.0 v1.23.0
    v2.0.0 v2.9.0 v2.10.0 v8.9.10 v8.10.0 v10.2.0 v10.20.1
    v11.0.0 v18.0.1 v99.0.0 v100.0.1 v102.3.4
  )
  local sorted oracle
  mapfile -t sorted < <(printf '%s\n' "${samples[@]}" | LC_ALL=C sort -r --version-sort)
  oracle="$(max_version "${samples[@]}")"
  if [[ "${sorted[0]}" != "$oracle" ]]; then
    printf 'version sort and the numeric oracle disagree: sort=%s oracle=%s\n' "${sorted[0]}" "$oracle" >&2
    exit 1
  fi
}

run_script() {
  local outfile="$1"
  local circle_tag="$2"
  local package="$3"
  local branch="$4"
  local sha="$5"
  local tags_file="$6"
  local path_prefix="$7"
  local log="${outfile}.log"

  export GIT_TAGS_FILE="$tags_file"
  export GIT_REMOTES="${GIT_REMOTES-}"
  export GIT_REMOTE_EXIT="${GIT_REMOTE_EXIT-}"
  export GIT_REMOTE_URL="${GIT_REMOTE_URL-}"
  export GIT_REMOTE_GET_URL_EXIT="${GIT_REMOTE_GET_URL_EXIT-}"
  export GIT_LS_REMOTE_EXIT="${GIT_LS_REMOTE_EXIT-}"
  export GIT_LS_REMOTE_STDERR="${GIT_LS_REMOTE_STDERR-}"
  export GIT_LS_REMOTE_TAGS_FILE="${GIT_LS_REMOTE_TAGS_FILE-}"
  export GIT_COMMAND_LOG="${GIT_COMMAND_LOG-}"
  export PARAM_OUTFILE="$outfile"
  export PARAM_PACKAGE="$package"
  export CIRCLE_TAG="$circle_tag"
  export CIRCLE_BRANCH="$branch"
  export CIRCLE_SHA1="$sha"
  export CIRCLE_BUILD_NUM="1"
  export LC_ALL=C

  local status=0
  PATH="${path_prefix}:${ORIGINAL_PATH}" bash "$SCRIPT" >"$log" 2>&1 || status=$?
  printf '%s' "$status"
}

check_output() {
  local name="$1"
  local outfile="$2"
  local log="$3"
  local status="$4"
  local expected="$5"

  if [[ "$status" -ne 0 ]]; then
    fail_case "$name" "script exited ${status}" "$(tail -n 20 "$log")"
    return
  fi
  local actual
  actual="$(cat "$outfile")"
  if [[ "$actual" != "$expected" ]]; then
    fail_case "$name" "expected:" "$expected" "actual:" "$actual"
    return
  fi
  pass_case
}

check_release() {
  local name="$1"
  local circle_tag="$2"
  local package="$3"
  local expected="$4"
  shift 4
  local tags_file="${TMP}/tags.txt"
  local outfile="${TMP}/out.txt"
  : > "$tags_file"
  if [[ "$#" -gt 0 ]]; then
    printf '%s\n' "$@" > "$tags_file"
  fi
  local status
  status="$(run_script "$outfile" "$circle_tag" "$package" "" "$SHA" "$tags_file" "$FAKE_BIN")"
  check_output "$name" "$outfile" "${outfile}.log" "$status" "$expected"
}

check_release_twice() {
  local name="$1"
  local circle_tag="$2"
  local package="$3"
  local expected="$4"
  shift 4
  local tags_file="${TMP}/tags.txt"
  local outfile="${TMP}/nested/custom-tags.txt"
  mkdir -p "${TMP}/nested"
  : > "$tags_file"
  if [[ "$#" -gt 0 ]]; then
    printf '%s\n' "$@" > "$tags_file"
  fi
  local status
  status="$(run_script "$outfile" "$circle_tag" "$package" "" "$SHA" "$tags_file" "$FAKE_BIN")"
  check_output "${name} (first run)" "$outfile" "${outfile}.log" "$status" "$expected"
  # A second run must truncate, not append.
  status="$(run_script "$outfile" "$circle_tag" "$package" "" "$SHA" "$tags_file" "$FAKE_BIN")"
  check_output "${name} (second run truncates)" "$outfile" "${outfile}.log" "$status" "$expected"
}

check_against_oracle() {
  local name="$1"
  local circle_tag="$2"
  local package="$3"
  shift 3
  local expected
  expected="$(oracle_lines "$circle_tag" "$package" "$@")"
  check_release "$name" "$circle_tag" "$package" "$expected" "$@"
}

golden() {
  local name="$1"
  local circle_tag="$2"
  local package="$3"
  local expected="$4"
  shift 4
  local oracle
  oracle="$(oracle_lines "$circle_tag" "$package" "$@")"
  if [[ "$oracle" != "$expected" ]]; then
    printf 'ORACLE MISMATCH %s\n  handwritten:\n%s\n  oracle:\n%s\n' "$name" "$expected" "$oracle" >&2
    exit 1
  fi
  check_release "$name" "$circle_tag" "$package" "$expected" "$@"
}

check_branch() {
  local name="$1"
  local branch="$2"
  local sha="$3"
  local expected="$4"
  local tags_file="${TMP}/tags.txt"
  local outfile="${TMP}/out.txt"
  printf 'v9.9.9\n' > "$tags_file"
  local status
  status="$(run_script "$outfile" "" "" "$branch" "$sha" "$tags_file" "$FAKE_BIN")"
  check_output "$name" "$outfile" "${outfile}.log" "$status" "$expected"
}

run_golden_cases() {
  golden "reported v1.9.0 vs v11.0.0 keeps the major tag" \
    "v1.9.0" "" $'1.9.0\n1.9\n1' \
    "v11.0.0"

  golden "reported v1.2.9 vs v1.23.0 keeps the minor tag" \
    "v1.2.9" "" $'1.2.9\n1.2' \
    "v1.23.0"

  golden "reported prefixes combined do not steal 1.2" \
    "v1.2.9" "" $'1.2.9\n1.2' \
    "v1.23.0" "v11.0.0" "v102.0.0" "v1.2.8" "v1.20.0"

  golden "v1.9.0 vs v1.19.0 keeps only the 1.9 line" \
    "v1.9.0" "" $'1.9.0\n1.9' \
    "v1.19.0" "v11.0.0"

  golden "readme hotfix v2.4.8 does not move 2 or latest" \
    "v2.4.8" "" $'2.4.8\n2.4' \
    "v2.4.7" "v2.5.2" "v2.5.1" "v1.9.0"

  golden "backport v4.4.7 does not take latest or the major tag" \
    "v4.4.7" "" $'4.4.7\n4.4' \
    "v4.4.6" "v4.5.0" "v5.0.0"

  golden "readme head v2.5.2 moves minor, major, and latest" \
    "v2.5.2" "" $'2.5.2\n2.5\n2\nlatest' \
    "v2.4.8" "v2.5.1"

  golden "first release publishes every floating tag" \
    "v1.0.0" "" $'1.0.0\n1.0\n1\nlatest'

  golden "readme prerelease rc1 does not move floating tags" \
    "v2.5.3-rc1" "" "2.5.3-rc1" \
    "v2.5.2" "v2.5.3"

  golden "bare rc prerelease does not move floating tags" \
    "v2.0.0-rc" "" "2.0.0-rc" \
    "v2.0.0" "v11.0.0" "v2.0.0-rc1"

  golden "dotted rc.1 prerelease does not move floating tags" \
    "v2.0.0-rc.1" "" "2.0.0-rc.1" \
    "v1.9.0" "v2.0.0-rc" "v2.0.0"

  golden "bare and dotted prereleases do not block a final release" \
    "v2.0.0" "" $'2.0.0\n2.0\n2\nlatest' \
    "v2.0.0-rc" "v2.0.0-rc.1" "v2.0.0-alpha" "v2.1.0-beta.1"

  golden "monorepo dotted prerelease stays on the exact tag" \
    "services/auth/v2.0.0-rc.1" "services/auth" "2.0.0-rc.1" \
    "services/auth/v2.0.0" "services/billing/v9.0.0" "v3.0.0"

  golden "readme prerelease alpha1 does not move floating tags" \
    "v2.5.3-alpha1" "" "2.5.3-alpha1"

  golden "readme prerelease beta4 does not move floating tags" \
    "v2.5.3-beta4" "" "2.5.3-beta4" \
    "v9.9.9"

  golden "prerelease rc10 stays off the minor tag" \
    "v1.2.4-rc10" "" "1.2.4-rc10" \
    "v1.2.3" "v1.2.4"

  golden "alpha of an existing final does not retarget latest" \
    "v1.2.3-alpha2" "" "1.2.3-alpha2" \
    "v1.2.3" "latest"

  golden "higher prereleases do not block a final release" \
    "v1.2.3" "" $'1.2.3\n1.2\n1\nlatest' \
    "v1.2.3-rc1" "v1.3.0-rc1" "v2.0.0-beta2" "v1.2.2"

  golden "version sort picks 1.10 over 1.9" \
    "v1.10.0" "" $'1.10.0\n1.10\n1\nlatest' \
    "v1.9.0" "v1.10.0-rc1"

  golden "v1.9.0 does not take the minor line from v1.10.0" \
    "v1.9.0" "" $'1.9.0\n1.9' \
    "v1.10.0"

  golden "patch 10 beats patch 9" \
    "v1.2.10" "" $'1.2.10\n1.2\n1\nlatest' \
    "v1.2.9"

  golden "older patch publishes only the exact tag" \
    "v1.2.9" "" "1.2.9" \
    "v1.2.10"

  golden "two-digit major is not swallowed by a three-digit major" \
    "v10.2.0" "" $'10.2.0\n10.2' \
    "v10.20.0" "v100.0.0"

  golden "highest two-digit minor still moves its major" \
    "v10.20.1" "" $'10.20.1\n10.20\n10' \
    "v10.20.0" "v10.2.0" "v100.0.0"

  golden "three-digit head publishes latest" \
    "v100.0.1" "" $'100.0.1\n100.0\n100\nlatest' \
    "v100.0.0" "v10.20.0" "v11.0.0"

  golden "v102 does not count as minor 1.2 or major 1" \
    "v1.2.9" "" $'1.2.9\n1.2\n1' \
    "v102.0.0"

  golden "v10 does not count as minor 1.0" \
    "v1.0.9" "" $'1.0.9\n1.0\n1' \
    "v10.0.0" "v1.0.8"

  golden "v20 does not count as minor 2.0" \
    "v2.0.1" "" $'2.0.1\n2.0\n2' \
    "v20.0.0" "v2.0.0"

  golden "monorepo minor prefix stays inside the package" \
    "services/auth/v1.2.9" "services/auth" $'1.2.9\n1.2' \
    "services/auth/v1.23.0" "services/auth/v1.2.8" "services/billing/v99.0.0" "v50.0.0"

  golden "monorepo major prefix stays inside the package" \
    "services/auth/v1.9.0" "services/auth" $'1.9.0\n1.9\n1' \
    "services/auth/v11.0.0" "services/billing/v1.9.9" "other/v80.0.0"

  golden "zero major minor prefix" \
    "v0.9.1" "" $'0.9.1\n0.9' \
    "v0.9.0" "v0.10.0"

  golden "zero major head" \
    "v0.10.2" "" $'0.10.2\n0.10\n0\nlatest' \
    "v0.9.9"

  golden "non-semver tags are ignored" \
    "v1.4.5" "" $'1.4.5\n1.4\n1\nlatest' \
    "latest" "edge" "v1" "v1.4" "1.9.0" "v1.4.5.1" "v1.4.4" "nightly" "v1.4.5-rc1"

  golden "a newer patch prerelease does not block the final" \
    "v2.0.0" "" $'2.0.0\n2.0\n2\nlatest' \
    "v1.9.9" "v2.0.1-rc1"

  golden "v1.15 is the 1.x head when v11 exists" \
    "v1.15.0" "" $'1.15.0\n1.15\n1' \
    "v1.2.9" "v11.2.0"

  golden "v8.9.10 keeps 8.9 when 8.10 and 18 exist" \
    "v8.9.10" "" $'8.9.10\n8.9' \
    "v8.9.9" "v8.10.0" "v18.0.0"

  golden "v8.10.0 moves major 8 but not latest" \
    "v8.10.0" "" $'8.10.0\n8.10\n8' \
    "v8.9.10" "v18.0.0"

  golden "v18.0.1 is the overall head" \
    "v18.0.1" "" $'18.0.1\n18.0\n18\nlatest' \
    "v18.0.0" "v8.10.0"

  golden "v2.10.0 sorts above v2.9.0" \
    "v2.10.0" "" $'2.10.0\n2.10\n2\nlatest' \
    "v2.1.0" "v2.9.0"

  golden "new minor becomes the major head" \
    "v1.6.0" "" $'1.6.0\n1.6\n1' \
    "v1.5.9" "v2.0.0"

  golden "older major hotfix stays on its minor" \
    "v1.4.8" "" $'1.4.8\n1.4' \
    "v1.4.7" "v1.5.0" "v2.0.0"

  golden "tag already present in git is not double counted into extra lines" \
    "v1.2.3" "" $'1.2.3\n1.2\n1\nlatest' \
    "v1.2.3" "v1.2.2"

  golden "current tag absent from git is still included" \
    "v1.2.3" "" $'1.2.3\n1.2\n1\nlatest' \
    "v1.2.2"

  check_release_twice "rerun truncates a custom outfile" \
    "v1.0.0" "" $'1.0.0\n1.0\n1\nlatest'
}

run_branch_cases() {
  check_branch "trunk main publishes edge and the sha tag" \
    "main" "$SHA" $'edge\n'"main-${SHORT_SHA}"
  check_branch "trunk master publishes edge and the sha tag" \
    "master" "$SHA" $'edge\n'"master-${SHORT_SHA}"
  check_branch "trunk develop publishes edge and the sha tag" \
    "develop" "$SHA" $'edge\n'"develop-${SHORT_SHA}"
  check_branch "feature branch publishes only a dev sha tag" \
    "feature/xyz" "$SHA" "dev-${SHORT_SHA}"
  check_branch "MAIN is not treated as trunk" \
    "MAIN" "$SHA" "dev-${SHORT_SHA}"
  check_branch "mainline is not treated as trunk" \
    "mainline" "$SHA" "dev-${SHORT_SHA}"
  check_branch "empty branch publishes a dev sha tag" \
    "" "$SHA" "dev-${SHORT_SHA}"
  check_branch "sha slice follows CIRCLE_SHA1" \
    "feature/other" "$ALT_SHA" "dev-${ALT_SHORT}"

  local expected
  expected="$(oracle_lines "v1.2.3" "" "v1.2.2")"
  local tags_file="${TMP}/tags.txt"
  local outfile="${TMP}/out.txt"
  printf 'v1.2.2\n' > "$tags_file"
  local status
  status="$(run_script "$outfile" "v1.2.3" "" "main" "$SHA" "$tags_file" "$FAKE_BIN")"
  check_output "semver tag wins over a main branch" "$outfile" "${outfile}.log" "$status" "$expected"

  expected="1.2.3-rc1"
  status="$(run_script "$outfile" "v1.2.3-rc1" "" "main" "$SHA" "$tags_file" "$FAKE_BIN")"
  check_output "prerelease tag wins over a main branch" "$outfile" "${outfile}.log" "$status" "$expected"
}

run_major_prefix_matrix() {
  local major suffix distractor
  for major in 1 2 3 4 5 6 7 8 9 10 11 12; do
    for suffix in 0 1 2 5 9; do
      distractor="${major}${suffix}"
      check_against_oracle \
        "major prefix ${major} against ${distractor}" \
        "v${major}.4.2" "" \
        "v${distractor}.0.0" \
        "v${major}.4.1" \
        "v${major}.3.9" \
        "v${major}.4.2-rc1" \
        "v${major}.4.3-alpha1" \
        "latest" \
        "edge"
    done
  done
}

run_minor_prefix_matrix() {
  local major minor suffix distractor
  for major in 1 2 8 10; do
    for minor in 1 2 3 4 5 6 7 8 9; do
      for suffix in 0 1 2 3 9; do
        distractor=$((10 * minor + suffix))
        check_against_oracle \
          "minor prefix ${major}.${minor} against ${major}.${distractor}" \
          "v${major}.${minor}.7" "" \
          "v${major}.${distractor}.0" \
          "v${major}.${minor}.6" \
          "v${major}.${minor}.7-rc2" \
          "v${major}.$((minor + 1)).0-beta1"
      done
    done
  done
}

run_cross_major_dot_matrix() {
  # Old minor patterns such as v1.2. also matched v102 because "." consumed a digit.
  local major minor digit other_major
  for major in 1 2 3 4 5 6 7 8 9; do
    for minor in 0 1 2 3 4 5 6 7 8 9; do
      for digit in 0 1 5 9; do
        other_major="${major}${digit}${minor}"
        check_against_oracle \
          "cross-major ${major}.${minor} against v${other_major}" \
          "v${major}.${minor}.4" "" \
          "v${other_major}.0.0" \
          "v${major}.${minor}.3"
      done
    done
  done
}

run_patch_matrix() {
  local patch
  for patch in 0 1 2 8 9 10 11 15; do
    check_against_oracle \
      "older patch v5.6.${patch} under v5.6.20" \
      "v5.6.${patch}" "" \
      "v5.6.20" "v5.7.0" "v6.0.0" "v5.6.${patch}-rc1"
  done
  check_against_oracle \
    "head of minor but not major" \
    "v5.6.20" "" \
    "v5.6.15" "v5.7.0" "v6.0.0"
  check_against_oracle \
    "head of major but not overall" \
    "v5.7.1" "" \
    "v5.7.0" "v5.6.20" "v6.0.0"
}

run_head_matrix() {
  local major minor patch
  local -a lower=()
  for major in 1 2 3 5 9 10 11 15 20; do
    for minor in 0 1 2 9 10 11; do
      for patch in 0 1 9 10; do
        lower=()
        if [[ "$patch" -gt 0 ]]; then
          lower+=("v${major}.${minor}.$((patch - 1))")
        fi
        if [[ "$minor" -gt 0 ]]; then
          lower+=("v${major}.$((minor - 1)).9")
        fi
        if [[ "$major" -gt 1 ]]; then
          lower+=("v$((major - 1)).9.9")
        fi
        lower+=("v${major}.${minor}.$((patch + 1))-rc1")
        check_against_oracle \
          "head v${major}.${minor}.${patch}" \
          "v${major}.${minor}.${patch}" "" \
          "${lower[@]}"
      done
    done
  done
}

run_monorepo_matrix() {
  local minor
  for minor in 1 2 5 9 10 12; do
    check_against_oracle \
      "monorepo auth v1.${minor}.4" \
      "services/auth/v1.${minor}.4" "services/auth" \
      "services/auth/v1.${minor}.3" \
      "services/auth/v1.$((minor + 10)).0" \
      "services/auth/v11.0.0" \
      "services/billing/v${minor}.99.0" \
      "services/billing/v99.0.0" \
      "other/v70.1.1" \
      "v80.0.0"
  done
}

run_prerelease_matrix() {
  local kind number
  for kind in alpha beta rc; do
    for number in 1 2 10; do
      check_against_oracle \
        "prerelease ${kind}${number} with a lower final" \
        "v4.5.6-${kind}${number}" "" \
        "v4.5.5" "v4.5.6" "v4.4.0" "v9.0.0"
      check_against_oracle \
        "prerelease ${kind}${number} alone" \
        "v4.5.6-${kind}${number}" ""
    done
    check_against_oracle \
      "bare prerelease ${kind} with a final present" \
      "v4.5.6-${kind}" "" \
      "v4.5.5" "v4.5.6" "v9.0.0"
    check_against_oracle \
      "bare prerelease ${kind} alone" \
      "v4.5.6-${kind}" ""
    for number in 0 1 2 10; do
      check_against_oracle \
        "dotted prerelease ${kind}.${number} with a lower final" \
        "v4.5.6-${kind}.${number}" "" \
        "v4.5.5" "v4.5.6" "v9.0.0"
      check_against_oracle \
        "dotted prerelease ${kind}.${number} alone" \
        "v4.5.6-${kind}.${number}" ""
    done
  done
}

check_unsupported() {
  local name="$1"
  local circle_tag="$2"
  local package="$3"
  local branch="$4"
  local tags_file="${TMP}/tags.txt"
  local outfile="${TMP}/reject-out.txt"
  local log="${outfile}.log"
  rm -f "$outfile" "$log"
  printf 'v1.2.3\nv2.0.0\n' > "$tags_file"
  local status
  status="$(run_script "$outfile" "$circle_tag" "$package" "$branch" "$SHA" "$tags_file" "$FAKE_BIN")"
  if [[ "$status" -eq 0 ]]; then
    local actual=""
    if [[ -f "$outfile" ]]; then
      actual="$(cat "$outfile")"
    fi
    fail_case "$name" "expected a non-zero exit" "tags:" "$actual"
    return
  fi
  if [[ -f "$outfile" ]]; then
    local actual
    actual="$(cat "$outfile")"
    if [[ -n "$actual" ]]; then
      fail_case "$name" "wrote tags after rejecting the release" "$actual"
      return
    fi
  fi
  if ! grep -F "CIRCLE_TAG '${circle_tag}' is not a supported release tag." "$log" >/dev/null; then
    fail_case "$name" "missing unsupported-tag error" "$(cat "$log")"
    return
  fi
  if grep -F "Added tag to output file: dev-" "$log" >/dev/null || grep -F "Added tag to output file: edge" "$log" >/dev/null; then
    fail_case "$name" "fell through to a branch tag" "$(cat "$log")"
    return
  fi
  pass_case
}

run_unsupported_tag_cases() {
  local tag branch
  for tag in \
    "v2.0.0-rc." \
    "v2.0.0-rc.1.2" \
    "v2.0.0-alpha.beta" \
    "v2.0.0-preview.1" \
    "v2.0.0-1" \
    "v2.0.0+build" \
    "v2.0.0-RC1" \
    "v2" \
    "v2.0" \
    "2.0.0" \
    "nightly"
  do
    check_unsupported "reject ${tag} on a tag pipeline" "$tag" "" ""
    check_unsupported "reject ${tag} even when branch is main" "$tag" "" "main"
  done

  check_unsupported "reject monorepo tag with an empty pre-release identifier" \
    "services/auth/v2.0.0-rc." "services/auth" ""
  check_unsupported "reject monorepo preview tag" \
    "services/auth/v2.0.0-preview.1" "services/auth" "main"
  check_unsupported "reject monorepo tag that is not a version" \
    "services/auth/nightly" "services/auth" ""

  local tags_file="${TMP}/tags.txt"
  local outfile="${TMP}/out.txt"
  local status expected
  printf 'v2.0.0\nv2.0.0-rc\n' > "$tags_file"
  expected="$(oracle_lines "v2.0.0-rc.1" "" "v2.0.0" "v2.0.0-rc")"
  status="$(run_script "$outfile" "v2.0.0-rc.1" "" "main" "$SHA" "$tags_file" "$FAKE_BIN")"
  check_output "dotted prerelease on main does not publish edge" \
    "$outfile" "${outfile}.log" "$status" "$expected"

  expected="$(oracle_lines "v2.0.0-rc" "" "v2.0.0")"
  status="$(run_script "$outfile" "v2.0.0-rc" "" "" "$SHA" "$tags_file" "$FAKE_BIN")"
  check_output "bare rc on an empty branch does not publish dev" \
    "$outfile" "${outfile}.log" "$status" "$expected"

  expected="$(oracle_lines "services/auth/v2.0.0-alpha" "services/auth" "services/auth/v2.0.0")"
  printf 'services/auth/v2.0.0\nservices/billing/v9.9.9\n' > "$tags_file"
  status="$(run_script "$outfile" "services/auth/v2.0.0-alpha" "services/auth" "main" "$SHA" "$tags_file" "$FAKE_BIN")"
  check_output "monorepo bare alpha does not publish edge" \
    "$outfile" "${outfile}.log" "$status" "$expected"
}

check_populate() {
  local name="$1"
  local circle_tag="$2"
  local package="$3"
  local branch="$4"
  local expected_status="$5"
  local expected_value="$6"
  local bash_env="${TMP}/bash.env"
  local log="${TMP}/populate.log"
  rm -f "$bash_env" "$log"
  export PARAM_PACKAGE="$package"
  export PARAM_TAG_ENV_VAR="TAG"
  export CIRCLE_TAG="$circle_tag"
  export CIRCLE_BRANCH="$branch"
  export CIRCLE_SHA1="$SHA"
  export CIRCLE_BUILD_NUM="1"
  export BASH_ENV="$bash_env"
  export LC_ALL=C
  local status=0
  PATH="${FAKE_BIN}:${ORIGINAL_PATH}" bash "${ROOT}/src/scripts/populate_tag.sh" >"$log" 2>&1 || status=$?
  if [[ "$status" -ne "$expected_status" ]]; then
    fail_case "$name" "exit ${status}, expected ${expected_status}" "$(cat "$log")"
    return
  fi
  local actual=""
  if [[ -f "$bash_env" ]]; then
    actual="$(cat "$bash_env")"
  fi
  if [[ "$expected_status" -eq 0 ]]; then
    local expected_line="export TAG=${expected_value}"
    if [[ "$actual" != "$expected_line" ]]; then
      fail_case "$name" "expected env:" "$expected_line" "actual:" "$actual"
      return
    fi
  elif [[ -n "$actual" ]]; then
    fail_case "$name" "wrote an env assignment for a rejected tag" "$actual"
    return
  elif ! grep -F "not a supported release tag" "$log" >/dev/null; then
    fail_case "$name" "missing unsupported-tag error" "$(cat "$log")"
    return
  fi
  pass_case
}

run_populate_tag_cases() {
  check_populate "populate exact final" "v2.0.0" "" "" 0 "2.0.0"
  check_populate "populate rc1" "v2.0.0-rc1" "" "" 0 "2.0.0-rc1"
  check_populate "populate bare rc" "v2.0.0-rc" "" "" 0 "2.0.0-rc"
  check_populate "populate dotted rc.1" "v2.0.0-rc.1" "" "main" 0 "2.0.0-rc.1"
  check_populate "populate monorepo alpha.2" "services/auth/v2.0.0-alpha.2" "services/auth" "" 0 "2.0.0-alpha.2"
  check_populate "populate trunk edge sha when there is no tag" "" "" "main" 0 "main-${SHORT_SHA}"
  check_populate "populate dev sha when there is no tag" "" "" "feature/xyz" 0 "dev-${SHORT_SHA}"
  check_populate "populate rejects v2.0.0-rc." "v2.0.0-rc." "" "" 1 ""
  check_populate "populate rejects preview.1 on main" "v2.0.0-preview.1" "" "main" 1 ""
  check_populate "populate rejects nightly" "nightly" "" "" 1 ""
  check_populate "populate rejects a bad monorepo tag" "services/auth/v2.0.0-rc." "services/auth" "main" 1 ""
}

run_stress_set() {
  local -a tags=()
  local major minor
  for major in {1..12}; do
    for minor in {0..15}; do
      tags+=("v${major}.${minor}.0" "v${major}.${minor}.1" "v${major}.${minor}.9" "v${major}.${minor}.10")
    done
  done
  tags+=(
    "v1.20.0" "v1.23.4" "v1.23.4-rc1" "v11.0.0" "v102.0.0"
    "latest" "edge" "nightly" "v1" "v1.2" "1.2.3"
  )
  local release
  for release in \
    v1.0.0 v1.2.9 v1.2.10 v1.15.10 v1.23.4 \
    v2.0.10 v7.8.9 v8.15.10 v10.0.0 v10.15.10 \
    v11.0.0 v12.15.10
  do
    check_against_oracle "stress ${release}" "$release" "" "${tags[@]}"
  done
}

assert_history_refused() {
  local name="$1"
  local circle_tag="$2"
  local work_tree="$3"
  local tag_exit="$4"
  local tags_file="${TMP}/tags.txt"
  local outfile="${TMP}/history-out.txt"
  local log="${outfile}.log"
  rm -f "$outfile" "$log"
  # Newer releases are available. If the failed git read is ignored, this tag
  # becomes the only candidate and takes :latest.
  printf 'v4.4.6\nv4.5.0\nv5.0.0\n' > "$tags_file"
  export GIT_WORK_TREE="$work_tree"
  export GIT_TAG_EXIT="$tag_exit"
  local status
  status="$(run_script "$outfile" "$circle_tag" "" "" "$SHA" "$tags_file" "$FAKE_BIN")"
  unset GIT_WORK_TREE GIT_TAG_EXIT
  if [[ "$status" -eq 0 ]]; then
    local actual=""
    if [[ -f "$outfile" ]]; then
      actual="$(cat "$outfile")"
    fi
    fail_case "$name" "expected a non-zero exit" "tags:" "$actual"
    return
  fi
  if [[ ! -f "$outfile" ]] || ! grep -Fxq -- "${circle_tag#v}" "$outfile"; then
    fail_case "$name" "missing exact tag ${circle_tag#v}" "$(cat "$outfile" 2>/dev/null || true)"
    return
  fi
  if [[ -f "$outfile" ]] && grep -qx 'latest' "$outfile"; then
    fail_case "$name" "wrote latest from an unreadable history" "$(cat "$outfile")"
    return
  fi
  if [[ -f "$outfile" ]] && grep -qx '4' "$outfile"; then
    fail_case "$name" "wrote the major tag from an unreadable history" "$(cat "$outfile")"
    return
  fi
  if [[ -f "$outfile" ]] && grep -qx '4.4' "$outfile"; then
    fail_case "$name" "wrote the minor tag from an unreadable history" "$(cat "$outfile")"
    return
  fi
  if ! grep -F "Refusing to publish latest" "$log" >/dev/null; then
    fail_case "$name" "missing refusal" "$(cat "$log")"
    return
  fi
  pass_case
}

run_unreadable_history_cases() {
  assert_history_refused "git tag failure does not publish latest for v4.4.7" "v4.4.7" "true" "128"
  assert_history_refused "missing git checkout does not publish latest for v4.4.7" "v4.4.7" "fail" "0"
  assert_history_refused "not a work tree does not publish latest for v4.4.7" "v4.4.7" "false" "0"

  local tags_file="${TMP}/tags.txt"
  local outfile="${TMP}/history-out.txt"
  local status
  printf 'v5.0.0\n' > "$tags_file"
  export GIT_WORK_TREE="fail"
  export GIT_TAG_EXIT="128"
  status="$(run_script "$outfile" "v4.4.7-rc1" "" "" "$SHA" "$tags_file" "$FAKE_BIN")"
  unset GIT_WORK_TREE GIT_TAG_EXIT
  check_output "prerelease does not need tag history" \
    "$outfile" "${outfile}.log" "$status" "4.4.7-rc1"
}

# Run generate_tags.sh with the real git binary. env keeps the CircleCI
# variables out of this shell, which also avoids exporting them from a subshell.
run_real_git_script() {
  local dir="$1"
  local outfile="$2"
  local circle_tag="$3"
  local branch="$4"
  (
    cd "$dir" || exit 1
    env \
      PARAM_OUTFILE="$outfile" \
      PARAM_PACKAGE="" \
      CIRCLE_TAG="$circle_tag" \
      CIRCLE_BRANCH="$branch" \
      CIRCLE_SHA1="$SHA" \
      CIRCLE_BUILD_NUM="1" \
      LC_ALL=C \
      GIT_PAGER=cat \
      GIT_TERMINAL_PROMPT=0 \
      PATH="${CIRCLECI_ONLY}:${ORIGINAL_PATH}" \
      bash "$SCRIPT" > "${outfile}.log" 2>&1
  )
}

init_real_repo() {
  local repo="$1"
  mkdir -p "$repo"
  "$REAL_GIT" -C "$repo" init -q
  "$REAL_GIT" -C "$repo" config user.email "tag-tests@example.com"
  "$REAL_GIT" -C "$repo" config user.name "Tag Tests"
  printf 'init\n' > "${repo}/README"
  "$REAL_GIT" -C "$repo" add README
  "$REAL_GIT" -C "$repo" commit -q -m init
}

# Failure must keep the immutable version and withhold every floating tag.
assert_withheld() {
  local name="$1"
  local outfile="$2"
  local status="$3"
  local exact="$4"
  local log="${outfile}.log"
  if [[ "$status" -eq 0 ]]; then
    fail_case "$name" "exit 0" "$(cat "$outfile" 2>/dev/null || true)"
    return
  fi
  if [[ ! -f "$outfile" ]] || ! grep -Fxq -- "$exact" "$outfile"; then
    fail_case "$name" "missing exact tag ${exact}" "$(cat "$outfile" 2>/dev/null || true)"
    return
  fi
  if grep -Exq 'latest|[0-9]+|[0-9]+\.[0-9]+' "$outfile"; then
    fail_case "$name" "wrote a floating tag" "$(cat "$outfile")"
    return
  fi
  if ! grep -F "Refusing to publish latest" "$log" >/dev/null; then
    fail_case "$name" "missing refusal" "$(cat "$log")"
    return
  fi
  pass_case
}

run_remote_tag_cases() {
  local remote_file="${TMP}/remote-tags.txt"
  local local_file="${TMP}/local-tags.txt"
  local outfile="${TMP}/remote-out.txt"
  local command_log="${TMP}/git-commands.log"
  local status remote_queries

  clear_remote_env() {
    unset GIT_REMOTES GIT_REMOTE_EXIT GIT_REMOTE_URL GIT_REMOTE_GET_URL_EXIT GIT_LS_REMOTE_EXIT GIT_LS_REMOTE_STDERR GIT_LS_REMOTE_TAGS_FILE GIT_COMMAND_LOG
  }
  clear_remote_env

  # Local history is only the tag being built, as in a depth-1 checkout of that tag.
  printf '%s\n' "v4.4.7" > "$local_file"
  printf '%s\n' "v4.4.6" "v4.4.7" "v4.5.0" "v5.0.0" "refs/tags/v5.0.0^{}" > "$remote_file"
  GIT_REMOTES="origin"
  GIT_LS_REMOTE_TAGS_FILE="$remote_file"
  GIT_COMMAND_LOG="$command_log"
  : > "$GIT_COMMAND_LOG"
  status="$(run_script "$outfile" "v4.4.7" "" "" "$SHA" "$local_file" "$FAKE_BIN")"
  check_output "remote tags keep a shallow v4.4.7 checkout off latest" \
    "$outfile" "${outfile}.log" "$status" $'4.4.7\n4.4'
  if ! grep -Fx -- "--no-pager ls-remote --refs --tags -- origin" "$command_log" >/dev/null; then
    fail_case "shallow v4.4.7 queries origin" "$(cat "$command_log")"
  elif grep -Eq '(^| )fetch( |$)' "$command_log"; then
    fail_case "shallow v4.4.7 does not fetch tag objects" "$(cat "$command_log")"
  else
    pass_case
  fi
  clear_remote_env

  # A higher tag that exists only in the local clone still counts.
  printf '%s\n' "v4.4.7" "v9.9.9" > "$local_file"
  printf '%s\n' "v4.4.7" > "$remote_file"
  GIT_REMOTES="origin"
  GIT_LS_REMOTE_TAGS_FILE="$remote_file"
  status="$(run_script "$outfile" "v4.4.7" "" "" "$SHA" "$local_file" "$FAKE_BIN")"
  check_output "local tag higher than the remote still blocks latest" \
    "$outfile" "${outfile}.log" "$status" $'4.4.7\n4.4\n4'
  clear_remote_env

  printf '%s\n' "v1.0.0" > "$local_file"
  : > "$remote_file"
  GIT_REMOTES="origin"
  GIT_LS_REMOTE_TAGS_FILE="$remote_file"
  status="$(run_script "$outfile" "v1.0.0" "" "" "$SHA" "$local_file" "$FAKE_BIN")"
  check_output "empty remote tag list still publishes latest" \
    "$outfile" "${outfile}.log" "$status" $'1.0.0\n1.0\n1\nlatest'
  clear_remote_env

  printf '%s\n' "v4.4.7" > "$local_file"
  printf '%s\n' "v5.0.0" > "$remote_file"
  GIT_REMOTES="upstream"
  GIT_LS_REMOTE_TAGS_FILE="$remote_file"
  GIT_COMMAND_LOG="$command_log"
  : > "$GIT_COMMAND_LOG"
  status="$(run_script "$outfile" "v4.4.7" "" "" "$SHA" "$local_file" "$FAKE_BIN")"
  check_output "the only remote is used when it is not named origin" \
    "$outfile" "${outfile}.log" "$status" $'4.4.7\n4.4\n4'
  if ! grep -Fx -- "--no-pager ls-remote --refs --tags -- upstream" "$command_log" >/dev/null; then
    fail_case "single remote name is upstream" "$(cat "$command_log")"
  else
    pass_case
  fi
  clear_remote_env

  printf '%s\n' "v4.4.7" > "$local_file"
  printf '%s\n' "v5.0.0" > "$remote_file"
  GIT_REMOTES=$'upstream\norigin\nfork'
  GIT_LS_REMOTE_TAGS_FILE="$remote_file"
  GIT_COMMAND_LOG="$command_log"
  : > "$GIT_COMMAND_LOG"
  status="$(run_script "$outfile" "v4.4.7" "" "" "$SHA" "$local_file" "$FAKE_BIN")"
  check_output "origin is used when other remotes exist" \
    "$outfile" "${outfile}.log" "$status" $'4.4.7\n4.4\n4'
  remote_queries="$(grep -c 'ls-remote' "$command_log" || true)"
  if ! grep -Fx -- "--no-pager ls-remote --refs --tags -- origin" "$command_log" >/dev/null; then
    fail_case "origin is queried by name when it is not the only remote" "$(cat "$command_log")"
  elif [[ "$remote_queries" -ne 1 ]]; then
    fail_case "origin is the only remote queried" "$(cat "$command_log")"
  else
    pass_case
  fi
  clear_remote_env

  printf '%s\n' "v4.4.7" > "$local_file"
  printf '%s\n' "v4.4.8" > "$remote_file"
  GIT_REMOTES="origin"
  GIT_LS_REMOTE_TAGS_FILE="$remote_file"
  status="$(run_script "$outfile" "v4.4.7" "" "" "$SHA" "$local_file" "$FAKE_BIN")"
  check_output "a higher remote patch blocks the minor tag" \
    "$outfile" "${outfile}.log" "$status" "4.4.7"
  clear_remote_env

  printf '%s\n' "v5.1.0" > "$local_file"
  printf '%s\n' "v4.9.9" "v5.0.0" > "$remote_file"
  GIT_REMOTES="origin"
  GIT_LS_REMOTE_TAGS_FILE="$remote_file"
  status="$(run_script "$outfile" "v5.1.0" "" "" "$SHA" "$local_file" "$FAKE_BIN")"
  check_output "a release newer than every remote tag publishes latest" \
    "$outfile" "${outfile}.log" "$status" $'5.1.0\n5.1\n5\nlatest'
  clear_remote_env

  printf '%s\n' "v1.9.0" > "$local_file"
  printf '%s\n' "v1.10.0" > "$remote_file"
  GIT_REMOTES="origin"
  GIT_LS_REMOTE_TAGS_FILE="$remote_file"
  status="$(run_script "$outfile" "v1.9.0" "" "" "$SHA" "$local_file" "$FAKE_BIN")"
  check_output "remote v1.10.0 blocks the major tag for v1.9.0" \
    "$outfile" "${outfile}.log" "$status" $'1.9.0\n1.9'
  clear_remote_env

  printf '%s\n' "v4.4.7" > "$local_file"
  printf '%s\n' "v4.4.6" "v4.4.8-rc1" "v4.4.7-rc.1" > "$remote_file"
  GIT_REMOTES="origin"
  GIT_LS_REMOTE_TAGS_FILE="$remote_file"
  status="$(run_script "$outfile" "v4.4.7" "" "" "$SHA" "$local_file" "$FAKE_BIN")"
  check_output "remote pre-releases do not block floating tags" \
    "$outfile" "${outfile}.log" "$status" $'4.4.7\n4.4\n4\nlatest'
  clear_remote_env

  printf '%s\n' "services/auth/v1.2.9" > "$local_file"
  printf '%s\n' "services/auth/v1.2.8" "services/auth/v1.23.0" "services/auth/v1.2.9" > "$remote_file"
  GIT_REMOTES="origin"
  GIT_LS_REMOTE_TAGS_FILE="$remote_file"
  status="$(run_script "$outfile" "services/auth/v1.2.9" "services/auth" "" "$SHA" "$local_file" "$FAKE_BIN")"
  check_output "remote monorepo tags keep the package prefix" \
    "$outfile" "${outfile}.log" "$status" $'1.2.9\n1.2'
  clear_remote_env

  printf '%s\n' "services/auth/v1.2.9" > "$local_file"
  printf '%s\n' "services/auth/v1.2.9" "v9.9.9" > "$remote_file"
  GIT_REMOTES="origin"
  GIT_LS_REMOTE_TAGS_FILE="$remote_file"
  status="$(run_script "$outfile" "services/auth/v1.2.9" "services/auth" "" "$SHA" "$local_file" "$FAKE_BIN")"
  check_output "an unprefixed remote tag does not affect a package release" \
    "$outfile" "${outfile}.log" "$status" $'1.2.9\n1.2\n1\nlatest'
  clear_remote_env

  printf '%s\n' "v4.4.7" > "$local_file"
  GIT_REMOTES="origin"
  GIT_LS_REMOTE_EXIT=128
  status="$(run_script "$outfile" "v4.4.7" "" "" "$SHA" "$local_file" "$FAKE_BIN")"
  assert_withheld "ls-remote failure does not fall back to local tags" "$outfile" "$status" "4.4.7"
  if ! grep -F "unable to read tags from 'origin'" "${outfile}.log" >/dev/null; then
    fail_case "ls-remote failure shows git's error" "$(cat "${outfile}.log")"
  else
    pass_case
  fi
  clear_remote_env

  printf '%s\n' "v4.4.7" > "$local_file"
  GIT_REMOTES="origin"
  GIT_LS_REMOTE_EXIT=128
  GIT_LS_REMOTE_STDERR="fatal: unable to access 'https://github.com/org/foo@bar see https://x-access-token:gh@s_secret*value@github.com/org/repo.git/': Could not resolve host"
  status="$(run_script "$outfile" "v4.4.7" "" "" "$SHA" "$local_file" "$FAKE_BIN")"
  assert_withheld "ls-remote failure redacts credentials in the remote URL" "$outfile" "$status" "4.4.7"
  if grep -F "gh@s_secret" "${outfile}.log" >/dev/null || grep -F "secret*value" "${outfile}.log" >/dev/null; then
    fail_case "ls-remote failure redacts credentials in the remote URL" "token was printed"
  elif ! grep -F "https://github.com/org/foo@bar" "${outfile}.log" >/dev/null; then
    fail_case "ls-remote failure redacts credentials in the remote URL" "path @ was removed" "$(cat "${outfile}.log")"
  elif ! grep -F "https://github.com/org/repo.git/" "${outfile}.log" >/dev/null; then
    fail_case "ls-remote failure redacts credentials in the remote URL" "host was removed" "$(cat "${outfile}.log")"
  else
    pass_case
  fi
  clear_remote_env

  printf '%s\n' "v1.0.0" > "$local_file"
  : > "$remote_file"
  GIT_REMOTES="origin"
  GIT_LS_REMOTE_TAGS_FILE="$remote_file"
  GIT_LS_REMOTE_STDERR="warning: https://github.com/org/foo@bar see https://x-access-token:gh@s_secret*value@github.com/org/repo.git/"
  status="$(run_script "$outfile" "v1.0.0" "" "" "$SHA" "$local_file" "$FAKE_BIN")"
  check_output "ls-remote warnings still allow a first release" \
    "$outfile" "${outfile}.log" "$status" $'1.0.0\n1.0\n1\nlatest'
  if grep -F "gh@s_secret" "${outfile}.log" >/dev/null || grep -F "secret*value" "${outfile}.log" >/dev/null; then
    fail_case "ls-remote warnings redact credentials" "token was printed"
  elif ! grep -F "https://github.com/org/repo.git/" "${outfile}.log" >/dev/null; then
    fail_case "ls-remote warnings redact credentials" "host was removed" "$(cat "${outfile}.log")"
  else
    pass_case
  fi
  clear_remote_env

  printf '%s\n' "v4.4.7" > "$local_file"
  GIT_REMOTES=$'upstream\nfork'
  GIT_COMMAND_LOG="$command_log"
  : > "$GIT_COMMAND_LOG"
  status="$(run_script "$outfile" "v4.4.7" "" "" "$SHA" "$local_file" "$FAKE_BIN")"
  assert_withheld "multiple remotes without origin do not publish latest" "$outfile" "$status" "4.4.7"
  if grep -q 'ls-remote' "$command_log"; then
    fail_case "multiple remotes without origin do not query a remote" "$(cat "$command_log")"
  else
    pass_case
  fi
  clear_remote_env

  printf '%s\n' "v4.4.7" > "$local_file"
  GIT_REMOTE_EXIT=128
  status="$(run_script "$outfile" "v4.4.7" "" "" "$SHA" "$local_file" "$FAKE_BIN")"
  assert_withheld "git remote failure does not publish latest" "$outfile" "$status" "4.4.7"
  clear_remote_env

  printf '%s\n' "v5.0.0" > "$remote_file"
  GIT_REMOTES="origin"
  GIT_LS_REMOTE_EXIT=128
  GIT_LS_REMOTE_TAGS_FILE="$remote_file"
  GIT_COMMAND_LOG="$command_log"
  : > "$GIT_COMMAND_LOG"
  status="$(run_script "$outfile" "v4.4.7-rc1" "" "" "$SHA" "$local_file" "$FAKE_BIN")"
  check_output "prerelease does not query remotes" \
    "$outfile" "${outfile}.log" "$status" "4.4.7-rc1"
  if [[ -s "$command_log" ]]; then
    fail_case "prerelease does not query git" "$(cat "$command_log")"
  else
    pass_case
  fi
  clear_remote_env

  GIT_REMOTES="origin"
  GIT_LS_REMOTE_EXIT=128
  GIT_COMMAND_LOG="$command_log"
  : > "$GIT_COMMAND_LOG"
  status="$(run_script "$outfile" "" "" "main" "$SHA" "$local_file" "$FAKE_BIN")"
  check_output "branch builds do not read tag history" \
    "$outfile" "${outfile}.log" "$status" $'edge\n'"main-${SHORT_SHA}"
  if [[ -s "$command_log" ]]; then
    fail_case "branch builds do not query git" "$(cat "$command_log")"
  else
    pass_case
  fi
  clear_remote_env

  printf '%s\n' "v4.4.7" > "$local_file"
  printf '%s\n' "v5.0.0" > "$remote_file"
  GIT_REMOTES="origin"
  GIT_REMOTE_URL="https://x-access-token:ghs_testtoken_not_real@example.test/org/repo.git"
  GIT_LS_REMOTE_TAGS_FILE="$remote_file"
  GIT_COMMAND_LOG="$command_log"
  : > "$GIT_COMMAND_LOG"
  status="$(run_script "$outfile" "v4.4.7" "" "" "$SHA" "$local_file" "$FAKE_BIN")"
  check_output "embedded credentials stay off the git command line" \
    "$outfile" "${outfile}.log" "$status" $'4.4.7\n4.4\n4'
  if grep -F "ghs_testtoken_not_real" "$command_log" >/dev/null || grep -F "ghs_testtoken_not_real" "${outfile}.log" >/dev/null; then
    fail_case "embedded credentials stay off the git command line" "token was visible"
  elif ! grep -F "ls-remote --refs --tags -- origin" "$command_log" >/dev/null; then
    fail_case "embedded credentials stay off the git command line" "missing ls-remote" "$(cat "$command_log")"
  else
    pass_case
  fi
  clear_remote_env

  printf '%s\n' "v4.4.7" > "$local_file"
  GIT_REMOTES="origin"
  GIT_REMOTE_GET_URL_EXIT=128
  status="$(run_script "$outfile" "v4.4.7" "" "" "$SHA" "$local_file" "$FAKE_BIN")"
  assert_withheld "git remote get-url failure does not publish latest" "$outfile" "$status" "4.4.7"
  clear_remote_env
}

run_real_git_remote_cases() {
  local remote="${TMP}/tags.git"
  local src="${TMP}/tags-src"
  local shallow="${TMP}/shallow-backport"
  local outfile="${TMP}/shallow-out.txt"
  local status=0
  local local_tags

  "$REAL_GIT" init -q --bare -b main "$remote"
  "$REAL_GIT" init -q -b main "$src"
  "$REAL_GIT" -C "$src" config user.email "tag-tests@example.com"
  "$REAL_GIT" -C "$src" config user.name "Tag Tests"
  "$REAL_GIT" -C "$src" remote add origin "$remote"
  local tag
  for tag in v4.4.6 v4.4.7 v4.5.0 v5.0.0; do
    printf '%s\n' "$tag" >> "${src}/README"
    "$REAL_GIT" -C "$src" add README
    "$REAL_GIT" -C "$src" commit -q -m "$tag"
    "$REAL_GIT" -C "$src" tag -a "$tag" -m "$tag"
  done
  "$REAL_GIT" -C "$src" push -q origin main
  "$REAL_GIT" -C "$src" push -q origin --tags

  "$REAL_GIT" -c advice.detachedHead=false clone -q --depth 1 --branch v4.4.7 "file://${remote}" "$shallow"
  local_tags="$("$REAL_GIT" -C "$shallow" tag)"
  if [[ "$("$REAL_GIT" -C "$shallow" rev-parse --is-shallow-repository)" != "true" ]]; then
    fail_case "shallow clone fixture is a shallow repository" \
      "$("$REAL_GIT" -C "$shallow" rev-parse --is-shallow-repository)"
  elif [[ "$local_tags" != "v4.4.7" ]]; then
    fail_case "shallow clone fixture only has v4.4.7" "local tags:" "$local_tags"
  else
    pass_case
  fi
  run_real_git_script "$shallow" "$outfile" "v4.4.7" "" || status=$?
  check_output "real shallow clone of v4.4.7 does not take latest" \
    "$outfile" "${outfile}.log" "$status" $'4.4.7\n4.4'
  if ! grep -F "Comparing local tags with origin." "${outfile}.log" >/dev/null; then
    fail_case "real shallow clone reads origin" "$(cat "${outfile}.log")"
  else
    pass_case
  fi

  local bare_first="${TMP}/first.git"
  local first_clone="${TMP}/first-clone"
  "$REAL_GIT" init -q --bare -b main "$bare_first"
  "$REAL_GIT" init -q -b main "${TMP}/first-src"
  "$REAL_GIT" -C "${TMP}/first-src" config user.email "tag-tests@example.com"
  "$REAL_GIT" -C "${TMP}/first-src" config user.name "Tag Tests"
  printf 'init\n' > "${TMP}/first-src/README"
  "$REAL_GIT" -C "${TMP}/first-src" add README
  "$REAL_GIT" -C "${TMP}/first-src" commit -q -m init
  "$REAL_GIT" -C "${TMP}/first-src" remote add origin "$bare_first"
  "$REAL_GIT" -C "${TMP}/first-src" push -q origin main
  "$REAL_GIT" clone -q "file://${bare_first}" "$first_clone"
  outfile="${TMP}/remote-first-out.txt"
  status=0
  run_real_git_script "$first_clone" "$outfile" "v1.0.0" "" || status=$?
  check_output "real remote with no tags still publishes latest" \
    "$outfile" "${outfile}.log" "$status" $'1.0.0\n1.0\n1\nlatest'

  local broken="${TMP}/broken-remote"
  init_real_repo "$broken"
  "$REAL_GIT" -C "$broken" remote add origin "${TMP}/missing-remote.git"
  outfile="${TMP}/broken-remote-out.txt"
  status=0
  run_real_git_script "$broken" "$outfile" "v4.4.7" "" || status=$?
  assert_withheld "real unreachable origin does not publish latest" "$outfile" "$status" "4.4.7"
}

# The transport helper must not receive a URL that still contains userinfo.
# A local HTTP server records the Authorization header so the credentials are
# proven to travel in the request rather than on the command line.
run_credential_argv_cases() {
  local libexec="${TMP}/git-exec"
  local argv_log="${TMP}/helper-argv.log"
  local auth_log="${TMP}/auth-header.log"
  local port_file="${TMP}/http-port"
  local server_py="${TMP}/auth-server.py"
  local real_exec real_http wrapper_http
  local repo outfile status

  real_exec="$("$REAL_GIT" --exec-path)"
  real_http="${real_exec}/git-remote-http"
  rm -rf "$libexec"
  mkdir -p "$libexec"
  local helper_name
  for helper_name in "$real_exec"/*; do
    ln -s "$helper_name" "$libexec/$(basename "$helper_name")"
  done
  rm -f "$libexec/git-remote-http" "$libexec/git-remote-https"
  wrapper_http=$(printf '%q' "$real_http")
  cat > "$libexec/git-remote-http" << EOF
#!/bin/bash
mark=CLEAN
for arg in "\$@"; do
  if [[ "\${arg}" == *"://"*@* ]]; then
    mark=LEAK
  fi
done
if [[ -n "\${ARGV_LOG:-}" ]]; then
  echo "\${mark}" >> "\${ARGV_LOG}"
fi
exec ${wrapper_http} "\$@"
EOF
  # The https wrapper must exec the real https helper, not the http one.
  local wrapper_https
  wrapper_https=$(printf '%q' "${real_exec}/git-remote-https")
  cat > "$libexec/git-remote-https" << EOF
#!/bin/bash
mark=CLEAN
for arg in "\$@"; do
  if [[ "\${arg}" == *"://"*@* ]]; then
    mark=LEAK
  fi
done
if [[ -n "\${ARGV_LOG:-}" ]]; then
  echo "\${mark}" >> "\${ARGV_LOG}"
fi
exec ${wrapper_https} "\$@"
EOF
  chmod +x "$libexec/git-remote-http" "$libexec/git-remote-https"

  cat > "$server_py" << 'PY'
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
log = os.environ["AUTH_LOG"]
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        auth = self.headers.get("Authorization", "")
        with open(log, "a") as handle:
            handle.write(auth + "\n")
        body = b"nope\n"
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="git"')
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, fmt, *args):
        return
ThreadingHTTPServer.allow_reuse_address = True
srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(os.environ["PORT_FILE"], "w") as handle:
    handle.write(str(srv.server_address[1]))
for _ in range(64):
    srv.handle_request()
PY
  : > "$auth_log"
  : > "$port_file"
  AUTH_LOG="$auth_log" PORT_FILE="$port_file" python3 "$server_py" &
  SERVER_PID=$!
  local spins=0
  while [[ ! -s "$port_file" && "$spins" -lt 50 ]]; do
    spins=$((spins + 1))
    sleep 0.05
  done
  if [[ ! -s "$port_file" ]]; then
    fail_case "credential argv fixture starts" "no port"
    return
  fi
  local port
  port="$(cat "$port_file")"

  assert_shielded_fetch() {
    local name="$1"
    local user="$2"
    local password="$3"
    local marker="$4"
    local auth_status=0
    if grep -F "LEAK" "$argv_log" >/dev/null; then
      fail_case "$name" "helper argv contained userinfo" "$(cat "$argv_log")"
      return
    fi
    if ! grep -Fxq "CLEAN" "$argv_log"; then
      fail_case "$name" "helper was not invoked" "$(cat "$argv_log")"
      return
    fi
    if grep -F "$marker" "${outfile}.log" >/dev/null || grep -F "$marker" "$argv_log" >/dev/null; then
      fail_case "$name" "credential material was written to the step log or helper argv"
      return
    fi
    python3 - "$auth_log" "$user" "$password" << 'PY' || auth_status=$?
import base64, pathlib, sys
log, user, password = sys.argv[1:]
wanted = f"{user}:{password}".encode()
for line in pathlib.Path(log).read_text().splitlines():
    if line.lower().startswith("basic "):
        try:
            got = base64.b64decode(line.split(" ", 1)[1])
        except Exception:
            continue
        if got == wanted:
            sys.exit(0)
sys.exit(1)
PY
    if [[ "$auth_status" -ne 0 ]]; then
      fail_case "$name" "request did not carry the embedded credentials"
      return
    fi
    pass_case
  }

  repo="${TMP}/cred-direct"
  outfile="${TMP}/cred-direct-out.txt"
  "$REAL_GIT" init -q -b main "$repo"
  "$REAL_GIT" -C "$repo" config user.email "tag-tests@example.com"
  "$REAL_GIT" -C "$repo" config user.name "Tag Tests"
  "$REAL_GIT" -C "$repo" remote add origin "http://x-access-token:ghs_testtoken_not_real@127.0.0.1:${port}/repo.git"
  cp "$repo/.git/config" "${TMP}/cred-direct-config"
  : > "$argv_log"
  : > "$auth_log"
  status=0
  run_credential_git "$repo" "$outfile" "v4.4.7" || status=$?
  assert_withheld "direct embedded credentials do not publish latest when the remote read fails" \
    "$outfile" "$status" "4.4.7"
  assert_shielded_fetch "direct embedded credentials stay off the transport command line" \
    "x-access-token" "ghs_testtoken_not_real" "ghs_testtoken_not_real"
  if ! cmp -s "$repo/.git/config" "${TMP}/cred-direct-config"; then
    fail_case "direct embedded credentials do not rewrite the stored remote" "config changed"
  else
    pass_case
  fi

  repo="${TMP}/cred-insteadof"
  outfile="${TMP}/cred-insteadof-out.txt"
  "$REAL_GIT" init -q -b main "$repo"
  "$REAL_GIT" -C "$repo" config user.email "tag-tests@example.com"
  "$REAL_GIT" -C "$repo" config user.name "Tag Tests"
  "$REAL_GIT" -C "$repo" remote add origin "http://127.0.0.1:${port}/repo.git"
  "$REAL_GIT" -C "$repo" config "url.http://x-access-token:ghs_testtoken_not_real@127.0.0.1:${port}/.insteadOf" "http://127.0.0.1:${port}/"
  : > "$argv_log"
  : > "$auth_log"
  status=0
  run_credential_git "$repo" "$outfile" "v4.4.7" || status=$?
  assert_withheld "insteadOf credentials do not publish latest when the remote read fails" \
    "$outfile" "$status" "4.4.7"
  assert_shielded_fetch "insteadOf credentials stay off the transport command line" \
    "x-access-token" "ghs_testtoken_not_real" "ghs_testtoken_not_real"

  repo="${TMP}/cred-percent"
  outfile="${TMP}/cred-percent-out.txt"
  "$REAL_GIT" init -q -b main "$repo"
  "$REAL_GIT" -C "$repo" config user.email "tag-tests@example.com"
  "$REAL_GIT" -C "$repo" config user.name "Tag Tests"
  "$REAL_GIT" -C "$repo" remote add origin "http://user:p%23ass*word@127.0.0.1:${port}/repo.git"
  : > "$argv_log"
  : > "$auth_log"
  status=0
  run_credential_git "$repo" "$outfile" "v4.4.7" || status=$?
  assert_withheld "encoded credentials do not publish latest when the remote read fails" \
    "$outfile" "$status" "4.4.7"
  assert_shielded_fetch "encoded credentials are decoded for the request and kept off the command line" \
    "user" 'p#ass*word' 'p%23ass*word'

  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""
}

run_credential_git() {
  local dir="$1"
  local outfile="$2"
  local circle_tag="$3"
  local argv_log="${TMP}/helper-argv.log"
  local exec_path="${TMP}/git-exec"
  (
    cd "$dir" || exit 1
    env \
      PARAM_OUTFILE="$outfile" \
      PARAM_PACKAGE="" \
      CIRCLE_TAG="$circle_tag" \
      CIRCLE_BRANCH="" \
      CIRCLE_SHA1="$SHA" \
      CIRCLE_BUILD_NUM="1" \
      LC_ALL=C \
      GIT_PAGER=cat \
      GIT_TERMINAL_PROMPT=0 \
      GIT_EXEC_PATH="$exec_path" \
      ARGV_LOG="$argv_log" \
      PATH="${CIRCLECI_ONLY}:${ORIGINAL_PATH}" \
      timeout 30 bash "$SCRIPT" > "${outfile}.log" 2>&1
  )
}

run_real_git_history_cases() {
  local outfile="${TMP}/real-history-out.txt"
  local status=0
  local dir="${TMP}/not-a-repo"
  mkdir -p "$dir"
  run_real_git_script "$dir" "$outfile" "v4.4.7" "" || status=$?
  assert_withheld "real git outside a repo refuses v4.4.7" "$outfile" "$status" "4.4.7"

  local repo="${TMP}/first-release"
  init_real_repo "$repo"
  outfile="${TMP}/first-release-out.txt"
  status=0
  run_real_git_script "$repo" "$outfile" "v1.0.0" "" || status=$?
  check_output "real git first release with an empty tag list still publishes latest" \
    "$outfile" "${outfile}.log" "$status" $'1.0.0\n1.0\n1\nlatest'
  if ! grep -F "No git remote; comparing local tags only." "${outfile}.log" >/dev/null; then
    fail_case "real git first release uses local tags when no remote is configured" "$(tail -n 40 "${outfile}.log")"
  else
    pass_case
  fi

  outfile="${TMP}/gitdir-out.txt"
  status=0
  run_real_git_script "${repo}/.git" "$outfile" "v4.4.7" "" || status=$?
  assert_withheld "real git inside .git is not a work tree" "$outfile" "$status" "4.4.7"

  local backport="${TMP}/backport"
  init_real_repo "$backport"
  "$REAL_GIT" -C "$backport" tag v4.4.6
  "$REAL_GIT" -C "$backport" tag v4.5.0
  "$REAL_GIT" -C "$backport" tag v5.0.0
  outfile="${TMP}/backport-out.txt"
  status=0
  run_real_git_script "$backport" "$outfile" "v4.4.7" "" || status=$?
  check_output "real git v4.4.7 backport does not take latest" \
    "$outfile" "${outfile}.log" "$status" $'4.4.7\n4.4'
}

run_real_git_smoke() {
  local repo="${TMP}/real-repo"
  init_real_repo "$repo"
  "$REAL_GIT" -C "$repo" tag v11.0.0
  "$REAL_GIT" -C "$repo" tag -a v1.8.0 -m "annotated older release"
  "$REAL_GIT" -C "$repo" tag v1.9.0-rc1

  local outfile="${TMP}/real-out.txt"
  local status=0
  run_real_git_script "$repo" "$outfile" "v1.9.0" "main" || status=$?
  check_output "real git v1.9.0 vs annotated v1.8.0 and v11.0.0" \
    "$outfile" "${outfile}.log" "$status" $'1.9.0\n1.9\n1'
}

main() {
  assert_sort_agrees_with_oracle
  run_golden_cases
  run_branch_cases
  run_major_prefix_matrix
  run_minor_prefix_matrix
  run_cross_major_dot_matrix
  run_patch_matrix
  run_head_matrix
  run_monorepo_matrix
  run_prerelease_matrix
  run_unsupported_tag_cases
  run_populate_tag_cases
  run_unreadable_history_cases
  run_remote_tag_cases
  run_stress_set
  run_real_git_remote_cases
  run_credential_argv_cases
  run_real_git_history_cases
  run_real_git_smoke

  printf 'passed=%s failed=%s\n' "$PASSED" "$FAILED"
  if [[ "$FAILED" -ne 0 ]]; then
    exit 1
  fi
}

main "$@"
