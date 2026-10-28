#!/bin/bash

set -euo pipefail

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
TAGS_FILE=$(subst "${PARAM_TAGS_FILE}")
TARGET_IMAGE=$(subst "${PARAM_TARGET_IMAGE}")
TOOL="${PARAM_TOOL}"

# CircleCI checks the command's enum before the step runs; the GitHub
# Action passes any string.
case "${TOOL}" in
    buildah | docker | podman) ;;
    *)
        echo "ERROR: tool must be buildah, docker, or podman, not '${TOOL}'." >&2
        exit 1
        ;;
esac

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
    echo "ERROR: A tags file must be specified." >&2
    exit 1
fi
if [[ ! -f "${TAGS_FILE}" ]]; then
    echo "ERROR: Unable to find tags file: ${TAGS_FILE}" >&2
    exit 1
fi
if [[ -z "${TARGET_IMAGE}" ]]; then
    echo "ERROR: A target image must be specified." >&2
    exit 1
fi

# Push all tagged images
while read -r TAG; do
    echo "Pushing image: ${TARGET_IMAGE}:${TAG}..."
    "${TOOL}" push "${TARGET_IMAGE}:${TAG}"
done < "${TAGS_FILE}"
