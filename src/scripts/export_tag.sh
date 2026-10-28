#!/bin/bash

# Export the most specific container tag to the job's environment through
# BASH_ENV, so later steps in the same job can read it.

set -euo pipefail

# ==========================================
# Handle Input 
# ==========================================

# subst VALUE: expands environment variables in VALUE with the CircleCI CLI,
# which reads it on stdin. Without the CLI, as in GitHub Actions or a local
# run, the value is used as it is.
subst() {
    if command -v circleci > /dev/null 2>&1; then
        printf '%s' "$1" | circleci env subst
    else
        printf '%s\n' "$1"
    fi
}

# Read command arguments
GIT_TAG_PREFIX=$(subst "${PARAM_GIT_TAG_PREFIX}")
TAG_ENV_VAR=$(subst "${PARAM_TAG_ENV_VAR}")
GIT_TAG_PARAM="${PARAM_GIT_TAG-}"
GIT_TAG=$(subst "${GIT_TAG_PARAM}")

# CircleCI checks an env_var_name parameter before the step runs; the GitHub
# Action passes any string.
if [[ -n "${TAG_ENV_VAR}" && ! "${TAG_ENV_VAR}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "ERROR: tag_env_var must be the name of an environment variable, not '${TAG_ENV_VAR}'." >&2
    exit 1
fi

# The build's git tag, branch, and commit, chosen as generate_tags chooses them:
# CIRCLE_TAG, CIRCLE_BRANCH, and CIRCLE_SHA1 on CircleCI, and on GitHub Actions
# GITHUB_REF_NAME, a tag when GITHUB_REF is refs/tags/..., and GITHUB_SHA. A
# pull request (GITHUB_HEAD_REF is set) is never a trunk build.
BUILD_TAG="${CIRCLE_TAG:-}"
BUILD_TAG_VAR="CIRCLE_TAG"
BUILD_BRANCH="${CIRCLE_BRANCH:-}"
BUILD_BRANCH_VAR="CIRCLE_BRANCH"
BUILD_REF_VARS="CIRCLE_TAG, CIRCLE_BRANCH"
BUILD_REF_VARS_UNUSED="CIRCLE_TAG and CIRCLE_BRANCH are not used."
BUILD_SHA="${CIRCLE_SHA1:-}"
PULL_REQUEST_BRANCH=""
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    BUILD_TAG=""
    BUILD_BRANCH=""
    case "${GITHUB_REF:-}" in
        refs/tags/*) BUILD_TAG="${GITHUB_REF_NAME:-}" ;;
        *) BUILD_BRANCH="${GITHUB_REF_NAME:-}" ;;
    esac
    BUILD_TAG_VAR="GITHUB_REF_NAME"
    BUILD_BRANCH_VAR="GITHUB_REF_NAME"
    BUILD_REF_VARS="GITHUB_REF_NAME"
    BUILD_REF_VARS_UNUSED="GITHUB_REF_NAME is not used."
    BUILD_SHA="${GITHUB_SHA:-}"
    PULL_REQUEST_BRANCH="${GITHUB_HEAD_REF:-}"
fi
TRUNK_BUILD=0
if [[ -z "${PULL_REQUEST_BRANCH}" ]]; then
    case "${BUILD_BRANCH}" in
        develop | main | master) TRUNK_BUILD=1 ;;
    esac
fi

# Print arguments for debugging purposes
echo "Exporting the tag environment variable..."
echo "  GIT_TAG_PREFIX: ${GIT_TAG_PREFIX}"
echo "  TAG_ENV_VAR: ${TAG_ENV_VAR}"
echo "  GIT_TAG: ${GIT_TAG}"

# ==========================================
# Compute Values
# ==========================================
echo "Computing value..."

MOST_SPECIFIC_TAG=""
SHORT_REVISION="${BUILD_SHA}"
SHORT_REVISION="${SHORT_REVISION:0:8}"
RELEASE_TAG_RE='^v[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)([0-9]+|\.[0-9]+)?)?$'
RELEASE_TAG_HELP="Expected vMAJOR.MINOR.PATCH with an optional -alpha, -beta, or -rc suffix, for example v2.0.0, v2.0.0-rc1, v2.0.0-rc, or v2.0.0-rc.1."

# Same supported forms and the same identity rules as generate_tags: a set
# git_tag is the only identity, with no fallback to the build's tag or branch,
# or a sha tag. With a git_tag_prefix it must be the full <prefix>/vX.Y.Z tag name.
TAG=""
if [[ -n "${GIT_TAG_PARAM}" ]]; then
    if [[ -z "${GIT_TAG}" ]]; then
        echo "ERROR: git_tag '${GIT_TAG_PARAM}' expanded to an empty value." >&2
        echo "Refusing to fall back to ${BUILD_REF_VARS}, edge, or dev tags." >&2
        exit 1
    fi
    if [[ -n "${BUILD_TAG}" && "${BUILD_TAG}" != "${GIT_TAG}" ]]; then
        echo "ERROR: git_tag '${GIT_TAG}' does not match ${BUILD_TAG_VAR} '${BUILD_TAG}'." >&2
        echo "Refusing to choose between two release identities." >&2
        exit 1
    fi
    if [[ -n "${GIT_TAG_PREFIX}" ]]; then
        if [[ "${GIT_TAG}" != "${GIT_TAG_PREFIX}/"* ]]; then
            echo "ERROR: git_tag '${GIT_TAG}' is not in the git_tag_prefix '${GIT_TAG_PREFIX}' namespace." >&2
            echo "With a git_tag_prefix, git_tag must be the full tag name, ${GIT_TAG_PREFIX}/vMAJOR.MINOR.PATCH." >&2
            echo "Refusing to fall back to ${BUILD_REF_VARS}, edge, or dev tags." >&2
            exit 1
        fi
        TAG="${GIT_TAG#"${GIT_TAG_PREFIX}/"}"
    else
        TAG="${GIT_TAG}"
    fi
    if [[ ! "${TAG}" =~ $RELEASE_TAG_RE ]]; then
        echo "ERROR: git_tag '${GIT_TAG}' is not a supported release tag." >&2
        echo "${RELEASE_TAG_HELP}" >&2
        echo "Refusing to fall back to ${BUILD_REF_VARS}, edge, or dev tags." >&2
        exit 1
    fi
    echo "  Release identity: git_tag '${GIT_TAG}'. ${BUILD_REF_VARS_UNUSED}"
elif [[ -n "${BUILD_TAG}" ]]; then
    TAG="${BUILD_TAG#"${GIT_TAG_PREFIX}/"}"
    if [[ ! "${TAG}" =~ $RELEASE_TAG_RE ]]; then
        echo "ERROR: ${BUILD_TAG_VAR} '${BUILD_TAG}' is not a supported release tag." >&2
        echo "${RELEASE_TAG_HELP}" >&2
        echo "Refusing to publish a dev or edge tag for this tag." >&2
        exit 1
    fi
    echo "  Release identity: ${BUILD_TAG_VAR} '${BUILD_TAG}'."
else
    echo "  Release identity: none. ${BUILD_BRANCH_VAR} '${BUILD_BRANCH}' selects the tag."
    if [[ -n "${PULL_REQUEST_BRANCH}" ]]; then
        echo "  GITHUB_HEAD_REF '${PULL_REQUEST_BRANCH}' is set, so this is a pull request, which gets a dev tag."
    fi
fi

if [[ -n "${TAG}" ]]; then
    MOST_SPECIFIC_TAG="${TAG#v}"
elif [[ "${TRUNK_BUILD}" -eq 1 ]]; then
    MOST_SPECIFIC_TAG="${BUILD_BRANCH}-${SHORT_REVISION}"
else
    MOST_SPECIFIC_TAG="dev-${SHORT_REVISION}"
fi
echo "  MOST_SPECIFIC_TAG=${MOST_SPECIFIC_TAG}"

# ==========================================
# Export to BASH_ENV
# ==========================================
echo "Exporting value..."

# Adds the most specific tag, shell-quoted so BASH_ENV can source any value.
#   e.g., export TAG=3.5.3
if [[ -n "${TAG_ENV_VAR}" ]]; then
    if [[ -z "${BASH_ENV:-}" ]]; then
        echo "ERROR: BASH_ENV is unset, so ${TAG_ENV_VAR} cannot be passed to later steps." >&2
        exit 1
    fi
    export "${TAG_ENV_VAR}"="${MOST_SPECIFIC_TAG}"
    printf 'export %s=%q\n' "${TAG_ENV_VAR}" "${MOST_SPECIFIC_TAG}" | tee -a "${BASH_ENV}"
fi

printf "Done setting environment variable."
