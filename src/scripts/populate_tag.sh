#!/bin/bash

# This script adds a tag to the job's environment by placing it in .bashrc.
# This ensures future steps within the same job have access to it.

set -e
set +o history

# ==========================================
# Handle Input 
# ==========================================

# Read command arguments
PACKAGE=$(circleci env subst "${PARAM_PACKAGE}")
TAG_ENV_VAR=$(circleci env subst "${PARAM_TAG_ENV_VAR}")
SOURCE_TAG_PARAM="${PARAM_SOURCE_TAG-}"
SOURCE_TAG=$(circleci env subst "${SOURCE_TAG_PARAM}")

# Print arguments for debugging purposes
echo "Populating TAG environment variable..."
echo "  PACKAGE: ${PACKAGE}"
echo "  TAG_ENV_VAR: ${TAG_ENV_VAR}"
echo "  SOURCE_TAG: ${SOURCE_TAG}"

# ==========================================
# Compute Values
# ==========================================
echo "Computing value..."

MOST_SPECIFIC_TAG=""
SHORT_REVISION=${CIRCLE_SHA1:0:8}
RELEASE_TAG_RE='^v[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)([0-9]+|\.[0-9]+)?)?$'
RELEASE_TAG_HELP="Expected vMAJOR.MINOR.PATCH with an optional -alpha, -beta, or -rc suffix, for example v2.0.0, v2.0.0-rc1, v2.0.0-rc, or v2.0.0-rc.1."

# Same supported forms and the same identity rules as generate_tags: a set
# source_tag is the only identity, with no fallback to CIRCLE_TAG, CIRCLE_BRANCH,
# or a sha tag. With a package it must be the full <package>/vX.Y.Z tag name.
TAG=""
if [[ -n "${SOURCE_TAG_PARAM}" ]]; then
    if [[ -z "${SOURCE_TAG}" ]]; then
        echo "Error: source_tag '${SOURCE_TAG_PARAM}' expanded to an empty value."
        echo "Refusing to fall back to CIRCLE_TAG, CIRCLE_BRANCH, edge, or dev tags."
        exit 1
    fi
    if [[ -n "${CIRCLE_TAG}" && "${CIRCLE_TAG}" != "${SOURCE_TAG}" ]]; then
        echo "Error: source_tag '${SOURCE_TAG}' does not match CIRCLE_TAG '${CIRCLE_TAG}'."
        echo "Refusing to choose between two release identities."
        exit 1
    fi
    if [[ -n "${PACKAGE}" ]]; then
        if [[ "${SOURCE_TAG}" != "${PACKAGE}/"* ]]; then
            echo "Error: source_tag '${SOURCE_TAG}' is not a tag of package '${PACKAGE}'."
            echo "With a package, source_tag must be the full tag name, ${PACKAGE}/vMAJOR.MINOR.PATCH."
            echo "Refusing to fall back to CIRCLE_TAG, CIRCLE_BRANCH, edge, or dev tags."
            exit 1
        fi
        TAG="${SOURCE_TAG#"${PACKAGE}/"}"
    else
        TAG="${SOURCE_TAG}"
    fi
    if [[ ! "${TAG}" =~ $RELEASE_TAG_RE ]]; then
        echo "Error: source_tag '${SOURCE_TAG}' is not a supported release tag."
        echo "${RELEASE_TAG_HELP}"
        echo "Refusing to fall back to CIRCLE_TAG, CIRCLE_BRANCH, edge, or dev tags."
        exit 1
    fi
    echo "  Release identity: source_tag '${SOURCE_TAG}'. CIRCLE_TAG and CIRCLE_BRANCH are not used."
elif [[ -n "${CIRCLE_TAG}" ]]; then
    TAG="${CIRCLE_TAG#"${PACKAGE}/"}"
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
# Export to .bashrc
# ==========================================
echo "Exporting value..."

# Adds the most specific tag
#   e.g., export TAG=3.5.3
if [[ -n "${TAG_ENV_VAR}" ]]; then
    export "${TAG_ENV_VAR}"="${MOST_SPECIFIC_TAG}"
    echo "export ${TAG_ENV_VAR}=${MOST_SPECIFIC_TAG}" | tee -a "${BASH_ENV}"
fi

printf "Done setting environment variable."
