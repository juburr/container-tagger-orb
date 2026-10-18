#!/bin/bash

# Export the most specific container tag to the job's environment through
# BASH_ENV, so later steps in the same job can read it.

set -e
set +o history

# ==========================================
# Handle Input 
# ==========================================

# Read command arguments
GIT_TAG_PREFIX=$(printf '%s' "${PARAM_GIT_TAG_PREFIX}" | circleci env subst)
TAG_ENV_VAR=$(printf '%s' "${PARAM_TAG_ENV_VAR}" | circleci env subst)
GIT_TAG_PARAM="${PARAM_GIT_TAG-}"
GIT_TAG=$(printf '%s' "${GIT_TAG_PARAM}" | circleci env subst)

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
SHORT_REVISION=${CIRCLE_SHA1:0:8}
RELEASE_TAG_RE='^v[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)([0-9]+|\.[0-9]+)?)?$'
RELEASE_TAG_HELP="Expected vMAJOR.MINOR.PATCH with an optional -alpha, -beta, or -rc suffix, for example v2.0.0, v2.0.0-rc1, v2.0.0-rc, or v2.0.0-rc.1."

# Same supported forms and the same identity rules as generate_tags: a set
# git_tag is the only identity, with no fallback to CIRCLE_TAG, CIRCLE_BRANCH,
# or a sha tag. With a git_tag_prefix it must be the full <prefix>/vX.Y.Z tag name.
TAG=""
if [[ -n "${GIT_TAG_PARAM}" ]]; then
    if [[ -z "${GIT_TAG}" ]]; then
        echo "Error: git_tag '${GIT_TAG_PARAM}' expanded to an empty value."
        echo "Refusing to fall back to CIRCLE_TAG, CIRCLE_BRANCH, edge, or dev tags."
        exit 1
    fi
    if [[ -n "${CIRCLE_TAG}" && "${CIRCLE_TAG}" != "${GIT_TAG}" ]]; then
        echo "Error: git_tag '${GIT_TAG}' does not match CIRCLE_TAG '${CIRCLE_TAG}'."
        echo "Refusing to choose between two release identities."
        exit 1
    fi
    if [[ -n "${GIT_TAG_PREFIX}" ]]; then
        if [[ "${GIT_TAG}" != "${GIT_TAG_PREFIX}/"* ]]; then
            echo "Error: git_tag '${GIT_TAG}' is not in the git_tag_prefix '${GIT_TAG_PREFIX}' namespace."
            echo "With a git_tag_prefix, git_tag must be the full tag name, ${GIT_TAG_PREFIX}/vMAJOR.MINOR.PATCH."
            echo "Refusing to fall back to CIRCLE_TAG, CIRCLE_BRANCH, edge, or dev tags."
            exit 1
        fi
        TAG="${GIT_TAG#"${GIT_TAG_PREFIX}/"}"
    else
        TAG="${GIT_TAG}"
    fi
    if [[ ! "${TAG}" =~ $RELEASE_TAG_RE ]]; then
        echo "Error: git_tag '${GIT_TAG}' is not a supported release tag."
        echo "${RELEASE_TAG_HELP}"
        echo "Refusing to fall back to CIRCLE_TAG, CIRCLE_BRANCH, edge, or dev tags."
        exit 1
    fi
    echo "  Release identity: git_tag '${GIT_TAG}'. CIRCLE_TAG and CIRCLE_BRANCH are not used."
elif [[ -n "${CIRCLE_TAG}" ]]; then
    TAG="${CIRCLE_TAG#"${GIT_TAG_PREFIX}/"}"
    if [[ ! "${TAG}" =~ $RELEASE_TAG_RE ]]; then
        echo "Error: CIRCLE_TAG '${CIRCLE_TAG}' is not a supported release tag."
        echo "${RELEASE_TAG_HELP}"
        echo "Refusing to publish a dev or edge tag for this tag."
        exit 1
    fi
    echo "  Release identity: CIRCLE_TAG '${CIRCLE_TAG}'."
else
    echo "  Release identity: none. CIRCLE_BRANCH '${CIRCLE_BRANCH}' selects the tag."
fi

if [[ -n "${TAG}" ]]; then
    MOST_SPECIFIC_TAG="${TAG#v}"
elif [ "$CIRCLE_BRANCH" = develop ] || [ "$CIRCLE_BRANCH" = main ] || [ "$CIRCLE_BRANCH" = master ]; then
    MOST_SPECIFIC_TAG="${CIRCLE_BRANCH}-${SHORT_REVISION}"
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
    export "${TAG_ENV_VAR}"="${MOST_SPECIFIC_TAG}"
    printf 'export %s=%q\n' "${TAG_ENV_VAR}" "${MOST_SPECIFIC_TAG}" | tee -a "${BASH_ENV}"
fi

printf "Done setting environment variable."
