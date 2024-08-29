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

# Print arguments for debugging purposes
echo "Populating TAG environment variable..."
echo "  PACKAGE: ${PACKAGE}"
echo "  TAG_ENV_VAR: ${TAG_ENV_VAR}"

# ==========================================
# Compute Values
# ==========================================
echo "Computing value..."

MOST_SPECIFIC_TAG=""
SHORT_REVISION=${CIRCLE_SHA1:0:8}

if [[ "$CIRCLE_TAG" =~ v[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)[0-9]+)?$ ]]; then
    TAG="${CIRCLE_TAG#"${PACKAGE}/"}"
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
