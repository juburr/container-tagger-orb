#!/bin/bash

set -e
set +o history

# Read command arguments
TAGS_FILE=$(printf '%s' "${PARAM_TAGS_FILE}" | circleci env subst)
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
