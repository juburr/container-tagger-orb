#!/bin/bash

# Export an image reference, <image>:<tag>, to the job's environment through
# BASH_ENV, so later steps in the same job can read it.

set -euo pipefail

# ==========================================
# Handle Input 
# ==========================================

# Read command arguments
IMAGE=$(printf '%s' "${PARAM_IMAGE}" | circleci env subst)
IMAGE_REF_ENV_VAR=$(printf '%s' "${PARAM_IMAGE_REF_ENV_VAR}" | circleci env subst)
TAG_ENV_VAR=$(printf '%s' "${PARAM_TAG_ENV_VAR}" | circleci env subst)

# Print arguments for debugging purposes
echo "Exporting the image reference environment variable..."
echo "  IMAGE: ${IMAGE}"
echo "  TAG_ENV_VAR: ${TAG_ENV_VAR}"
echo "  !TAG_ENV_VAR: ${!TAG_ENV_VAR:-}"
echo "  IMAGE_REF_ENV_VAR: ${IMAGE_REF_ENV_VAR}"

# ==========================================
# Compute Values
# ==========================================
echo "Computing value..."

if [[ -z "${TAG_ENV_VAR}" || -z "${!TAG_ENV_VAR:-}" ]]; then
    echo "ERROR: Expected the ${TAG_ENV_VAR} environment variable to be set already." >&2
    echo "Please run the export_tag command first." >&2
    exit 1
fi

IMAGE_REF="${IMAGE}:${!TAG_ENV_VAR}"

# ==========================================
# Export to BASH_ENV
# ==========================================
echo "Exporting value..."

# Adds the image reference, using the most specific tag, shell-quoted so
# BASH_ENV can source any value.
#   e.g., export IMAGE_REF=ghcr.io/org/repo:3.5.3
if [[ -n "${IMAGE_REF_ENV_VAR}" ]]; then
    if [[ -z "${BASH_ENV:-}" ]]; then
        echo "ERROR: BASH_ENV is unset, so ${IMAGE_REF_ENV_VAR} cannot be passed to later steps." >&2
        exit 1
    fi
    export "${IMAGE_REF_ENV_VAR}"="${IMAGE_REF}"
    printf 'export %s=%q\n' "${IMAGE_REF_ENV_VAR}" "${IMAGE_REF}" | tee -a "${BASH_ENV}"
fi

printf "Done setting environment variable."
