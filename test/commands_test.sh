#!/usr/bin/env bash
#
# Tests the command scripts the way the GitHub Actions run them: with no
# circleci CLI on the PATH, and GitHub's variables in place of CircleCI's. It
# checks that:
#
#   - without the CLI, values reach the scripts as they are: "$NAME" is not
#     expanded, and a value starting with "-" stays a value
#   - generate_tags and export_tag take the build's tag, branch and commit
#     from GITHUB_REF, GITHUB_REF_NAME and GITHUB_SHA: a tag push is a
#     release, a push to main gets edge, and a pull request, even one whose
#     GITHUB_REF_NAME is main (pull_request_target), only gets a dev tag
#   - git_tag must match GITHUB_REF_NAME on a tag push, and a tag that isn't a
#     release fails
#   - tool, append_tags_to_source and push take what the action passes (true
#     or false) and CircleCI's 1 or 0, and anything else fails before a
#     container tool runs
#   - variable name inputs that aren't names fail
#
# Run from a checkout:
#   bash <this file>

set -uo pipefail

# Find the repository root, the directory that holds src/@orb.yml.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
until [[ -f "${ROOT}/src/@orb.yml" ]]; do
    if [[ "${ROOT}" == "/" ]]; then
        echo "FAIL: no src/@orb.yml above ${BASH_SOURCE[0]}"
        exit 1
    fi
    ROOT=$(dirname "${ROOT}")
done
SCRIPTS="${ROOT}/src/scripts"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

# The PATH the scripts run with: stand-ins first, then links to every command
# on this PATH but circleci, which CircleCI's images have in /bin and /usr/bin.
STANDINS="${WORK}/standins"
TOOLS="${WORK}/tools"
mkdir -p "${STANDINS}" "${TOOLS}"
IFS=: read -r -a PATH_DIRS <<< "${PATH}"
for dir in "${PATH_DIRS[@]}"; do
    for tool in "${dir}"/*; do
        name=${tool##*/}
        if [[ "${name}" != circleci && -x "${tool}" && ! -e "${TOOLS}/${name}" ]]; then
            ln -s "${tool}" "${TOOLS}/${name}"
        fi
    done
done
RUN_PATH="${STANDINS}:${TOOLS}"

# A container tool and crane that record their arguments, one call per line.
# crane digest prints a fixed digest.
DIGEST="sha256:$(printf '%064d' 0 | tr 0 a)"
for tool in buildah docker podman crane; do
    cat > "${STANDINS}/${tool}" << EOF
#!/usr/bin/env bash
printf '%s\n' "${tool} \$*" >> "${WORK}/calls"
if [[ "\$1" == digest ]]; then
    echo "${DIGEST}"
fi
EOF
    chmod +x "${STANDINS}/${tool}"
done

# A checkout with one earlier release, and no remote, so a final release
# compares local tags only.
REPO="${WORK}/repo"
git init -q "${REPO}"
git -C "${REPO}" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m one
git -C "${REPO}" tag v1.0.0
SHA=$(git -C "${REPO}" rev-parse HEAD)
SHORT_SHA=${SHA:0:8}

FAILURES=0
RC=0
OUTPUT=""

# run SCRIPT [VAR=value ...]: runs a script from src/scripts in the checkout,
# with the PATH above, a fresh BASH_ENV, and the given variables. Sets RC and
# OUTPUT.
run() {
    local script=$1
    shift
    rm -f "${WORK}/calls"
    : > "${WORK}/bash-env"
    OUTPUT=$(cd "${REPO}" && env -i HOME="${WORK}" PATH="${RUN_PATH}" BASH_ENV="${WORK}/bash-env" "$@" \
        bash "${SCRIPTS}/${script}.sh" < /dev/null 2>&1)
    RC=$?
}

# GitHub's variables for a push of REF, or a pull request when HEAD_REF is set.
github() {
    local ref=$1 head_ref=${2:-}
    local name=${ref#refs/*/}
    if [[ "${ref}" == refs/pull/* ]]; then
        name=${ref#refs/pull/}
    fi
    printf '%s\n' GITHUB_ACTIONS=true "GITHUB_REF=${ref}" "GITHUB_REF_NAME=${name}" \
        "GITHUB_HEAD_REF=${head_ref}" "GITHUB_SHA=${SHA}"
}

# check DESCRIPTION COMMAND...: records a failure, with the output, unless
# COMMAND succeeds.
check() {
    local description=$1
    shift
    if "$@"; then
        printf 'ok: %s\n' "${description}"
    else
        printf 'FAIL: %s\n' "${description}"
        printf '    | %s\n' "${OUTPUT}"
        FAILURES=$((FAILURES + 1))
    fi
}
rc_is_zero() { [[ "${RC}" -eq 0 ]]; }
rc_is_nonzero() { [[ "${RC}" -ne 0 ]]; }
output_has() { grep -qF -- "$1" <<< "${OUTPUT}"; }
output_lacks() { ! grep -qF -- "$1" <<< "${OUTPUT}"; }
tags_are() { [[ "$(cat "${REPO}/tags.txt" 2> /dev/null)" == "$(printf '%s\n' "$@")" ]]; }
bash_env_is() { [[ "$(cat "${WORK}/bash-env")" == "$1" ]]; }
no_calls() { [[ ! -f "${WORK}/calls" ]]; }
calls_are() { [[ -f "${WORK}/calls" && "$(cat "${WORK}/calls")" == "$(printf '%s\n' "$@")" ]]; }

check "the scripts run with no circleci CLI on the PATH" \
    bash -c "! PATH='${RUN_PATH}' command -v circleci"

# ---------------------------------------------------------- generate_tags
GENERATE=(PARAM_TAGS_FILE=tags.txt PARAM_GIT_TAG_PREFIX="" PARAM_GIT_TAG="")
mapfile -t ENV < <(github refs/tags/v1.2.3)
run generate_tags "${ENV[@]}" "${GENERATE[@]}"
check "generate_tags: a tag push is a release" tags_are 1.2.3 1.2 1 latest
check "generate_tags: named after GITHUB_REF_NAME" output_has "Release identity: GITHUB_REF_NAME 'v1.2.3'."

mapfile -t ENV < <(github refs/tags/v1.2.3-rc1)
run generate_tags "${ENV[@]}" "${GENERATE[@]}"
check "generate_tags: a pre-release tag push gets no floating tags" tags_are 1.2.3-rc1

mapfile -t ENV < <(github refs/heads/main)
run generate_tags "${ENV[@]}" "${GENERATE[@]}"
check "generate_tags: a push to main gets edge and main-<sha>" tags_are edge "main-${SHORT_SHA}"

mapfile -t ENV < <(github refs/heads/feature/x)
run generate_tags "${ENV[@]}" "${GENERATE[@]}"
check "generate_tags: a push to another branch gets dev-<sha>" tags_are "dev-${SHORT_SHA}"

mapfile -t ENV < <(github refs/pull/7/merge main)
run generate_tags "${ENV[@]}" "${GENERATE[@]}"
check "generate_tags: a pull request gets dev-<sha>" tags_are "dev-${SHORT_SHA}"
check "generate_tags: and says it is a pull request" output_has "GITHUB_HEAD_REF 'main' is set, so this is a pull request"

mapfile -t ENV < <(github refs/heads/main feature)
run generate_tags "${ENV[@]}" "${GENERATE[@]}"
check "generate_tags: pull_request_target on main gets dev-<sha>, not edge" tags_are "dev-${SHORT_SHA}"

mapfile -t ENV < <(github refs/tags/nightly)
run generate_tags "${ENV[@]}" "${GENERATE[@]}"
check "generate_tags: a tag push that isn't a release fails" rc_is_nonzero
check "generate_tags: naming GITHUB_REF_NAME" output_has "ERROR: GITHUB_REF_NAME 'nightly' is not a supported release tag."

mapfile -t ENV < <(github refs/tags/v1.2.4)
run generate_tags "${ENV[@]}" PARAM_TAGS_FILE=tags.txt PARAM_GIT_TAG_PREFIX="" PARAM_GIT_TAG=v1.2.3
check "generate_tags: git_tag that differs from the pushed tag fails" rc_is_nonzero
check "generate_tags: saying so" output_has "ERROR: git_tag 'v1.2.3' does not match GITHUB_REF_NAME 'v1.2.4'."

mapfile -t ENV < <(github refs/heads/release)
run generate_tags "${ENV[@]}" PARAM_TAGS_FILE=tags.txt PARAM_GIT_TAG_PREFIX=svc PARAM_GIT_TAG=svc/v2.0.0
check "generate_tags: git_tag from a branch build is the release" tags_are 2.0.0 2.0 2 latest
check "generate_tags: and the branch is not used" output_has "GITHUB_REF_NAME is not used."

# shellcheck disable=SC2016 # the value is passed as it is
run generate_tags "${ENV[@]}" PARAM_TAGS_FILE='$HOME.txt' PARAM_GIT_TAG_PREFIX="" PARAM_GIT_TAG=""
# shellcheck disable=SC2016 # the file name is literal
check "generate_tags: tags_file is used as it is, \$HOME included" test -s "${REPO}/\$HOME.txt"

# ------------------------------------------------------------- export_tag
EXPORT=(PARAM_GIT_TAG_PREFIX="" PARAM_GIT_TAG="" PARAM_TAG_ENV_VAR=TAG)
mapfile -t ENV < <(github refs/tags/v3.4.5)
run export_tag "${ENV[@]}" "${EXPORT[@]}"
check "export_tag: a tag push exports the version" bash_env_is "export TAG=3.4.5"
mapfile -t ENV < <(github refs/heads/main)
run export_tag "${ENV[@]}" "${EXPORT[@]}"
check "export_tag: a push to main exports main-<sha>" bash_env_is "export TAG=main-${SHORT_SHA}"
mapfile -t ENV < <(github refs/heads/main feature)
run export_tag "${ENV[@]}" "${EXPORT[@]}"
check "export_tag: pull_request_target on main exports dev-<sha>" bash_env_is "export TAG=dev-${SHORT_SHA}"
run export_tag "${ENV[@]}" PARAM_GIT_TAG_PREFIX="" PARAM_GIT_TAG="" PARAM_TAG_ENV_VAR='TAG; touch pwned'
check "export_tag: a tag_env_var that isn't a name fails" rc_is_nonzero
check "export_tag: saying so" output_has "ERROR: tag_env_var must be the name of an environment variable"
check "export_tag: and writes nothing" bash_env_is ""

# ------------------------------------------------------- export_image_ref
# shellcheck disable=SC2016 # the value is passed as it is
run export_image_ref TAG=1.2.3 PARAM_IMAGE='-ghcr.io/org/$app' PARAM_IMAGE_REF_ENV_VAR=IMAGE_REF PARAM_TAG_ENV_VAR=TAG
# shellcheck disable=SC2016 # the value is passed as it is
check "export_image_ref: uses the image as it is" bash_env_is "$(printf 'export %s=%q' IMAGE_REF '-ghcr.io/org/$app:1.2.3')"
run export_image_ref TAG=1.2.3 PARAM_IMAGE=ghcr.io/org/app PARAM_IMAGE_REF_ENV_VAR='IMAGE REF' PARAM_TAG_ENV_VAR=TAG
check "export_image_ref: an image_ref_env_var that isn't a name fails" output_has \
    "ERROR: image_ref_env_var must be the name of an environment variable, not 'IMAGE REF'."
run export_image_ref TAG=1.2.3 PARAM_IMAGE=ghcr.io/org/app PARAM_IMAGE_REF_ENV_VAR=IMAGE_REF PARAM_TAG_ENV_VAR='1TAG'
check "export_image_ref: a tag_env_var that isn't a name fails" output_has \
    "ERROR: tag_env_var must be the name of an environment variable, not '1TAG'."
check "export_image_ref: and writes nothing" bash_env_is ""

# ------------------------------------------------ export_image_digest_ref
run export_image_digest_ref IMAGE_REF=localhost:5000/org/app:1.2.3 PARAM_IMAGE_REF_ENV_VAR=IMAGE_REF \
    PARAM_IMAGE_DIGEST_REF_ENV_VAR=IMAGE_DIGEST_REF
check "export_image_digest_ref: exports the digest crane reads" \
    bash_env_is "export IMAGE_DIGEST_REF=localhost:5000/org/app@${DIGEST}"

# ------------------------------------------------------------- tag_digest
printf '1.2.3\n' > "${REPO}/tags.txt"
run tag_digest PARAM_IMAGE_DIGEST_REF="-localhost:5000/org/app@${DIGEST}" PARAM_TAGS_FILE=tags.txt \
    PARAM_EXPECTED_DIGESTS_FILE=""
check "tag_digest: passes image_digest_ref as it is" output_has "REPOSITORY: -localhost:5000/org/app"

# -------------------------------------------------------------------- tag
TAG=(PARAM_TAGS_FILE=tags.txt PARAM_SOURCE_IMAGE=local/app PARAM_TARGET_IMAGE=ghcr.io/org/app)
printf '1.2.3\n' > "${REPO}/tags.txt"
for value in true 1; do
    run tag "${TAG[@]}" PARAM_TOOL=podman PARAM_APPEND_TAGS_TO_SOURCE="${value}" PARAM_PUSH=false
    check "tag: append_tags_to_source ${value} tags the source's tag" calls_are \
        "podman image inspect local/app:1.2.3" "podman tag local/app:1.2.3 ghcr.io/org/app:1.2.3"
done
for value in false 0; do
    run tag "${TAG[@]}" PARAM_TOOL=docker PARAM_APPEND_TAGS_TO_SOURCE="${value}" PARAM_PUSH="${value}"
    check "tag: append_tags_to_source ${value} tags the source" calls_are \
        "docker image inspect local/app" "docker tag local/app ghcr.io/org/app:1.2.3"
done
run tag "${TAG[@]}" PARAM_TOOL=docker PARAM_APPEND_TAGS_TO_SOURCE=yes PARAM_PUSH=false
check "tag: append_tags_to_source yes fails" output_has "ERROR: append_tags_to_source must be true or false, not 'yes'."
check "tag: before a container tool runs" no_calls
run tag "${TAG[@]}" PARAM_TOOL=docker PARAM_APPEND_TAGS_TO_SOURCE=false PARAM_PUSH=on
check "tag: push on fails" output_has "ERROR: push must be true or false, not 'on'."
check "tag: before a container tool runs" no_calls
run tag "${TAG[@]}" PARAM_TOOL=nerdctl PARAM_APPEND_TAGS_TO_SOURCE=false PARAM_PUSH=false
check "tag: another tool fails" output_has "ERROR: tool must be buildah, docker, or podman, not 'nerdctl'."
check "tag: before it runs" no_calls

# ------------------------------------------------------------------- push
run push PARAM_TAGS_FILE=tags.txt PARAM_TARGET_IMAGE='-ghcr.io/org/app' PARAM_TOOL=buildah
check "push: passes the target as it is" calls_are "buildah push -ghcr.io/org/app:1.2.3"
run push PARAM_TAGS_FILE=tags.txt PARAM_TARGET_IMAGE=ghcr.io/org/app PARAM_TOOL='docker --debug'
check "push: another tool fails" output_has "ERROR: tool must be buildah, docker, or podman, not 'docker --debug'."
check "push: before it runs" no_calls

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} failure(s)"
    exit 1
fi
echo "All command script tests passed."
