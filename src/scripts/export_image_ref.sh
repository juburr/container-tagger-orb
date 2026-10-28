#!/bin/bash

# Export an image reference, <image>:<tag>, to the job's environment through
# BASH_ENV, so later steps in the same job can read it.

set -euo pipefail

# ==========================================
# Handle Input 
# ==========================================

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
IMAGE=$(subst "${PARAM_IMAGE}")
IMAGE_REF_ENV_VAR=$(subst "${PARAM_IMAGE_REF_ENV_VAR}")
TAG_ENV_VAR=$(subst "${PARAM_TAG_ENV_VAR}")

# CircleCI checks env_var_name parameters before the step runs; the GitHub
# Action passes any string.
for name in image_ref_env_var:"${IMAGE_REF_ENV_VAR}" tag_env_var:"${TAG_ENV_VAR}"; do
    if [[ -n "${name#*:}" && ! "${name#*:}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "ERROR: ${name%%:*} must be the name of an environment variable, not '${name#*:}'." >&2
        exit 1
    fi
done

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
