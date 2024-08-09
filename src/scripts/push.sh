#!/bin/bash

set -e

# Read command arguments
TAGS_FILE=$(circleci env subst "${PARAM_TAGS_FILE}")
TARGET_IMAGE=$(circleci env subst "${PARAM_TARGET_IMAGE}")
TOOL="${PARAM_TOOL}"

# Print arguments for debugging purposes
echo "Running tagger with arguments:"
echo "  TAGS_FILE: ${TAGS_FILE}"
echo "  TARGET_IMAGE: ${TARGET_IMAGE}"
echo "  TOOL: ${TOOL}"

# Input Validation
if [[ -z "${TAGS_FILE}" ]]; then
    echo "A tags file must be specified."
    exit 1
fi
if [[ ! -f "${TAGS_FILE}" ]]; then
    echo "Unable to find tags file: ${TAGS_FILE}"
    exit 1
fi
if [[ -z "${TARGET_IMAGE}" ]]; then
    echo "A target image must be specified."
    exit 1
fi

# Push all tagged images
while read -r TAG; do
    echo "Pushing image: ${TARGET_IMAGE}:${TAG}..."
    "${TOOL}" push "${TARGET_IMAGE}:${TAG}"
done < "${TAGS_FILE}"
