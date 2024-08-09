#!/bin/bash

set -e

# Read command arguments
PUSH=$(circleci env subst "${PARAM_PUSH}")
TAGS_FILE=$(circleci env subst "${PARAM_TAGS_FILE}")
SOURCE_IMAGE=$(circleci env subst "${PARAM_SOURCE_IMAGE}")
TARGET_IMAGE=$(circleci env subst "${PARAM_TARGET_IMAGE}")
TOOL="${PARAM_TOOL}"

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
    echo "Tagging image: ${TARGET_IMAGE}:${TAG}..."
    "${TOOL}" tag "${SOURCE_IMAGE}" "${TARGET_IMAGE}:${TAG}"

    if [[ "${PUSH}" == "true" ]]; then
        echo "Pushing image: ${TARGET_IMAGE}:${TAG}..."
        "${TOOL}" push "${TARGET_IMAGE}:${TAG}"
    fi
done < "${TAGS_FILE}"
