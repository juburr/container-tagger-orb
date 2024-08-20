#!/bin/bash

# This script adds an image URI with a digest to the job's environment by
# placing it in .bashrc. This ensures future steps within the same job
# have access to it.

set -e

# ==========================================
# Handle Input 
# ==========================================

# Read command arguments
IMAGE_URI_ENV_VAR=$(circleci env subst "${PARAM_IMAGE_URI_ENV_VAR}")
IMAGE_URI="${!IMAGE_URI_ENV_VAR}"
IMAGE_URI_DIGEST_ENV_VAR=$(circleci env subst "${PARAM_IMAGE_URI_DIGEST_ENV_VAR}")

# Print arguments for debugging purposes
echo "Populating IMAGE_URI environment variable..."
echo "  IMAGE_URI_ENV_VAR: ${IMAGE_URI_ENV_VAR}"
echo "  IMAGE_URI: ${IMAGE_URI}"
echo "  IMAGE_URI_DIGEST_ENV_VAR: ${IMAGE_URI_DIGEST_ENV_VAR}"

IMAGE=$(echo "${IMAGE_URI}" | cut -d ':' -f 1)
echo "  IMAGE: ${IMAGE}"

# ==========================================
# Compute Values
# ==========================================
echo "Computing value..."

if [[ -z "${IMAGE_URI_ENV_VAR}" || -z "${IMAGE_URI}" ]]; then
    echo "Expected the ${IMAGE_URI_ENV_VAR} environment variable to be set already."
    echo "Please run the populate_image_uri_env command first."
    exit 1
fi

if [[ -z "${IMAGE}" ]]; then
    echo "Expected the IMAGE environment variable to be set already."
    echo "Is your ${IMAGE_URI_ENV_VAR} variable formatted correctly?"
    exit 1
fi

# Compute: IMAGE_DIGEST
IMAGE_DIGEST=""
if command -v crane 1> /dev/null; then
    echo "  TOOL: crane"
    # While docker inspect returns registry/image@sha256:hash, crane simply returns
    # sha256:hash. We need to add the registry/image@ prefix ourselves.
    DIGEST=$(crane digest "${IMAGE_URI}") || true
    echo "  DIGEST=${IMAGE_URI}"
    IMAGE_DIGEST="${IMAGE}@${DIGEST}"
    echo "  IMAGE_DIGEST=${IMAGE_DIGEST}"
elif command -v docker 1> /dev/null; then
    echo "  TOOL: docker"

    # Docker requires the image to exist locally in order for
    # the "docker inspect" command to return the digest. It
    # fails with a hard error otherwise.
    if docker image inspect "${IMAGE_URI}" > /dev/null 2>&1; then
        echo "The image exists locally."
    else
        echo "The image does not exist locally, but is needed by Docker to compute the digest."
        echo "Pulling image ${IMAGE_URI}..."
        docker pull "${IMAGE_URI}"
    fi

    # When pushing a single image to multiple registries, docker inspect always returns
    # a registry/image@sha256:hash value with the first registry you attempted to use, even if
    # $IMAGE is that of the second registry. Reconstruct the correct value ourselves.
    DIGEST_WITH_REGISTRY=$(docker inspect --format='{{index .RepoDigests 0}}' "${IMAGE_URI}") || true
    echo "  DIGEST_WITH_REGISTRY=${DIGEST_WITH_REGISTRY}"
    DIGEST=$(echo "${DIGEST_WITH_REGISTRY}" | cut -d '@' -f 2)
    echo "  DIGEST=${DIGEST}"
    IMAGE_DIGEST="${IMAGE}@${DIGEST}"
    echo "  IMAGE_DIGEST=${IMAGE_DIGEST}"
fi

# ==========================================
# Export to .bashrc
# ==========================================
echo "Exporting value..."

# Places the image URI and digest in the .bashrc file, often required by tools like Cosign.
#   e.g., export IMAGE_DIGEST=ghcr.io/org/repo@sha256:3d2b68dd6fa75bd4419533270698b27ab6a482aa2ac5ddb41435fe1fc1bab75c
if [[ -n "${IMAGE_URI_DIGEST_ENV_VAR}" ]]; then
    export "${IMAGE_URI_DIGEST_ENV_VAR}"="${IMAGE_DIGEST}"
    echo "export ${IMAGE_URI_DIGEST_ENV_VAR}=${IMAGE_DIGEST}" | tee -a "${BASH_ENV}"
fi

printf "Done setting environment variable."
