#!/bin/bash

set -euo pipefail

# Read command arguments
APPEND_TAGS_TO_SOURCE="${PARAM_APPEND_TAGS_TO_SOURCE}"
TAGS_FILE=$(printf '%s' "${PARAM_TAGS_FILE}" | circleci env subst)
SOURCE_IMAGE=$(printf '%s' "${PARAM_SOURCE_IMAGE}" | circleci env subst)
TARGET_IMAGE=$(printf '%s' "${PARAM_TARGET_IMAGE}" | circleci env subst)
TOOL="${PARAM_TOOL}"

# The shell expands ~ only in words it parses itself, so a parameter value such
# as ~/workspace/tags.txt arrives with a literal ~. Expand ~ and ~/ the way a
# shell would; ~user is left alone.
case "${TAGS_FILE}" in
    \~) TAGS_FILE="${HOME}" ;;
    \~/*) TAGS_FILE="${HOME}/${TAGS_FILE#"~/"}" ;;
esac

# Print arguments for debugging purposes
echo "Running tagger with arguments:"
echo "  TAGS_FILE: ${TAGS_FILE}"
echo "  SOURCE_IMAGE: ${SOURCE_IMAGE}"
echo "  TARGET_IMAGE: ${TARGET_IMAGE}"
echo "  TOOL: ${TOOL}"

# Input Validation
if [[ -z "${TAGS_FILE}" ]]; then
    echo "ERROR: A tags file must be specified." >&2
    exit 1
fi
if [[ ! -f "${TAGS_FILE}" ]]; then
    echo "ERROR: Unable to find tags file: ${TAGS_FILE}" >&2
    exit 1
fi
if [[ -z "${SOURCE_IMAGE}" ]]; then
    echo "ERROR: A source image must be specified." >&2
    exit 1
fi
if [[ -z "${TARGET_IMAGE}" ]]; then
    echo "ERROR: A target image must be specified." >&2
    exit 1
fi

# Docker and Podman inspect a local image with "image inspect". buildah has no
# image subcommand and uses "inspect --type image" instead.
if [[ "${TOOL}" == "buildah" ]]; then
    INSPECT_IMAGE=(buildah inspect --type image)
else
    INSPECT_IMAGE=("${TOOL}" image inspect)
fi

# Apply all tags
while read -r TAG; do
    INNER_SOURCE_IMAGE="${SOURCE_IMAGE}"
    if [[ "${APPEND_TAGS_TO_SOURCE}" == "1" ]]; then
        INNER_SOURCE_IMAGE="${SOURCE_IMAGE}:${TAG}"
    fi

    # Pull down source image if it doesn't exist locally
    if "${INSPECT_IMAGE[@]}" "${INNER_SOURCE_IMAGE}" > /dev/null 2>&1; then
        echo "Source image exists locally: ${INNER_SOURCE_IMAGE}"
    else
        echo "Source image does not exist. Attempting to pull: ${INNER_SOURCE_IMAGE}..."
        "${TOOL}" pull "${INNER_SOURCE_IMAGE}"
    fi

    echo "Tagging image: ${TARGET_IMAGE}:${TAG}..."
    "${TOOL}" tag "${INNER_SOURCE_IMAGE}" "${TARGET_IMAGE}:${TAG}"
done < "${TAGS_FILE}"
