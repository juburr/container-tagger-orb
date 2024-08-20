#!/bin/bash

# This script adds an image URI to the job's environment by placing it in .bashrc.
# This ensures future steps within the same job have access to it.

set -e

# ==========================================
# Handle Input 
# ==========================================

# Read command arguments
IMAGE=$(circleci env subst "${PARAM_IMAGE}")
IMAGE_URI_ENV_VAR=$(circleci env subst "${PARAM_IMAGE_URI_ENV_VAR}")
TAG_ENV_VAR=$(circleci env subst "${PARAM_TAG_ENV_VAR}")

# Print arguments for debugging purposes
echo "Populating IMAGE_URI environment variable..."
echo "  IMAGE: ${IMAGE}"
echo "  TAG_ENV_VAR: ${TAG_ENV_VAR}"
echo "  !TAG_ENV_VAR: ${!TAG_ENV_VAR}"
echo "  IMAGE_URI_ENV_VAR: ${IMAGE_URI_ENV_VAR}"

# ==========================================
# Compute Values
# ==========================================
echo "Computing value..."

if [[ -z "${TAG_ENV_VAR}" || -z "${!TAG_ENV_VAR}" ]]; then
    echo "Expected the ${TAG_ENV_VAR} environment variable to be set already."
    echo "Please run the populate_tag_env command first."
    exit 1
fi

IMAGE_URI="${IMAGE}:${!TAG_ENV_VAR}"

# ==========================================
# Export to .bashrc
# ==========================================
echo "Exporting value..."

# Adds the full image URI to the .bashrc file, using the most specific tag.
#   e.g., export IMAGE_URI=ghcr.io/org/repo:3.5.3
if [[ -n "${IMAGE_URI_ENV_VAR}" ]]; then
    export "${IMAGE_URI_ENV_VAR}"="${IMAGE_URI}"
    echo "export ${IMAGE_URI_ENV_VAR}=${IMAGE_URI}" | tee -a "${BASH_ENV}"
fi

printf "Done setting environment variable."
