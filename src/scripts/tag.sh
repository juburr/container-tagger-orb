#!/bin/bash

set -e
set +o history

# Read command arguments
APPEND_TAGS_TO_SOURCE="${PARAM_APPEND_TAGS_TO_SOURCE}"
TAGS_FILE=$(circleci env subst "${PARAM_TAGS_FILE}")
SOURCE_IMAGE=$(circleci env subst "${PARAM_SOURCE_IMAGE}")
TARGET_IMAGE=$(circleci env subst "${PARAM_TARGET_IMAGE}")
TOOL="${PARAM_TOOL}"

# Print arguments for debugging purposes
echo "Running tagger with arguments:"
echo "  TAGS_FILE: ${TAGS_FILE}"
echo "  SOURCE_IMAGE: ${SOURCE_IMAGE}"
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
if [[ -z "${SOURCE_IMAGE}" ]]; then
    echo "A source image must be specified."
    exit 1
fi
if [[ -z "${TARGET_IMAGE}" ]]; then
    echo "A target image must be specified."
    exit 1
fi

# Apply all tags
while read -r TAG; do
    INNER_SOURCE_IMAGE="${SOURCE_IMAGE}"
    if [[ "${APPEND_TAGS_TO_SOURCE}" == "1" ]]; then
        INNER_SOURCE_IMAGE="${SOURCE_IMAGE}:${TAG}"
    fi

    # Pull down source image if it doesn't exist locally
    if "${TOOL}" image inspect "${INNER_SOURCE_IMAGE}" > /dev/null 2>&1; then
        echo "Source image exists locally: ${INNER_SOURCE_IMAGE}"
    else
        echo "Source image does not exist. Attempting to pull: ${INNER_SOURCE_IMAGE}..."
        "${TOOL}" pull "${INNER_SOURCE_IMAGE}"
    fi

    echo "Tagging image: ${TARGET_IMAGE}:${TAG}..."
    "${TOOL}" tag "${INNER_SOURCE_IMAGE}" "${TARGET_IMAGE}:${TAG}"
done < "${TAGS_FILE}"
