#!/bin/bash

# This script adds variables to the job's environment by placing them in .bashrc.
# This ensures future steps within the same job have access to them.
#
# Why set specific tags or environment variables if this orb is generally concerned
# with *lists* of tags via a tags.txt file?
#
# It's often useful to have quick access to just one of the tags. For example,
# when signing an image that has multiple tags, all of the tags will have the
# exact same sha256 sum, so you only need to perform the operation on one of
# the tags. Cosign expects the image's sha256 sum rather than a specific tag,
# for example.
#
# This script will prefer and set the "most specific tag", for example :3.5.3 rather
# than :3 or :latest. An image's sha256 sum will be the same for all tags created
# from a single image. e.g., :3, :3.5, :3.5.3, :latest.
#
# Computation of the sha256 sum requires that the image first be pushed to a registry.

set -e

# ==========================================
# Handle Input 
# ==========================================

# Read command arguments
IMAGE=$(circleci env subst "${PARAM_IMAGE}")
IMAGE_URI_ENV_VAR=$(circleci env subst "${PARAM_IMAGE_URI_ENV_VAR}")
IMAGE_URI_DIGEST_ENV_VAR=$(circleci env subst "${PARAM_IMAGE_URI_DIGEST_ENV_VAR}")
TAG_ENV_VAR=$(circleci env subst "${PARAM_TAG_ENV_VAR}")

# Print arguments for debugging purposes
echo "Populating environment variables..."
echo "  IMAGE: ${IMAGE}"
echo "  IMAGE_URI_DIGEST_ENV_VAR: ${IMAGE_URI_DIGEST_ENV_VAR}"
echo "  IMAGE_URI_ENV_VAR: ${IMAGE_URI_ENV_VAR}"
echo "  TAG_ENV_VAR: ${TAG_ENV_VAR}"

# ==========================================
# Compute Values
# ==========================================
echo "Computing values..."

MOST_SPECIFIC_TAG=""
SHORT_REVISION=${CIRCLE_SHA1:0:8}

# Compute: TAG
if [[ "$CIRCLE_TAG" =~ v[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)[0-9]+)?$ ]]; then
    TAG="${CIRCLE_TAG#"${PACKAGE}/"}"
    MOST_SPECIFIC_TAG="${TAG#v}"
elif [ "$CIRCLE_BRANCH" = develop ] || [ "$CIRCLE_BRANCH" = main ] || [ "$CIRCLE_BRANCH" = master ]; then
    MOST_SPECIFIC_TAG="${CIRCLE_BRANCH}-${SHORT_REVISION}"
else
    MOST_SPECIFIC_TAG="dev-${SHORT_REVISION}"
fi
echo "  MOST_SPECIFIC_TAG=${MOST_SPECIFIC_TAG}"

# Compute: IMAGE_URI
IMAGE_URI="${IMAGE}:${MOST_SPECIFIC_TAG}"
echo "  IMAGE_URI=${IMAGE_URI}"

# Compute: IMAGE_DIGEST (only request if you've pushed your image already...)
IMAGE_DIGEST=""
if command -v crane 1> /dev/null; then
    echo "  TOOL: crane"

    # While docker inspect returns registry/image@sha256:hash, crane simply returns
    # sha256:hash. We need to add the registry/image@ prefix ourselves.
    DIGEST=$(crane digest "${IMAGE}") || true
    echo "  DIGEST=${IMAGE_URI}"

    if [[ -n ${DIGEST} ]]; then
        IMAGE_DIGEST="${IMAGE}@${DIGEST}"
        echo "  IMAGE_DIGEST=${IMAGE_DIGEST}"
    else
        echo "An non-fatal error occurred when trying to compute the image digest."
        echo "Ensure the image name is correct and that the image has already been pushed to the registry."
        echo "This command will fail if the image only exists locally."
        echo "Continuing without setting ${IMAGE_URI_DIGEST_ENV_VAR}..."
    fi
elif command -v docker 1> /dev/null; then
    echo "  TOOL: docker"

    # When pushing a single image to multiple registries, docker inspect always returns
    # a registry/image@sha256:hash value with the first registry you attempted to use, even if
    # $IMAGE is that of the second registry. Reconstruct the correct value ourselves.
    DIGEST_WITH_REGISTRY=$(docker inspect --format='{{index .RepoDigests 0}}' "${IMAGE_URI}") || true
    echo "  DIGEST_WITH_REGISTRY=${DIGEST_WITH_REGISTRY}"

    if [[ -n ${DIGEST_WITH_REGISTRY} ]]; then
        DIGEST=$(echo "${DIGEST_WITH_REGISTRY}" | cut -d '@' -f 2)
        echo "  DIGEST=${DIGEST}"
        IMAGE_DIGEST="${IMAGE}@${DIGEST}"
        echo "  IMAGE_DIGEST=${IMAGE_DIGEST}"
    else
        echo "An non-fatal error occurred when trying to compute the image digest."
        echo "Ensure the image name is correct and that the image has already been pushed to the registry."
        echo "This command will fail if the image only exists locally."
        echo "Continuing without setting ${IMAGE_URI_DIGEST_ENV_VAR}..."
    fi
elif [[ -n "${IMAGE_URI_DIGEST_ENV_VAR}" ]]; then
    echo "An non-fatal error occurred when trying to compute the image digest."
    echo "Requesting ${IMAGE_URI_DIGEST_ENV_VAR} requires that either crane or docker be installed."
    echo "Continuing without setting ${IMAGE_URI_DIGEST_ENV_VAR}..."
fi

# ==========================================
# Export to .bashrc
# ==========================================
echo "Exporting values..."

# Adds the most specific tag
#   e.g., export TAG=3.5.3
if [[ -n "${TAG_ENV_VAR}" ]]; then
    export "${TAG_ENV_VAR}"="${MOST_SPECIFIC_TAG}"
    echo "export ${TAG_ENV_VAR}=${MOST_SPECIFIC_TAG}" | tee -a "${BASH_ENV}"
fi

# Adds the full image URI to the .bashrc file, using the most specific tag.
#   e.g., export IMAGE_URI=ghcr.io/org/repo:3.5.3
if [[ -n "${IMAGE_URI_ENV_VAR}" ]]; then
    export "${IMAGE_URI_ENV_VAR}"="${IMAGE_URI}"
    echo "export ${IMAGE_URI_ENV_VAR}=${IMAGE_URI}" | tee -a "${BASH_ENV}"
fi

# Places the image URI and digest in the .bashrc file, often required by tools like Cosign.
#   e.g., export IMAGE_DIGEST=ghcr.io/org/repo@sha256:3d2b68dd6fa75bd4419533270698b27ab6a482aa2ac5ddb41435fe1fc1bab75c
if [[ -n "${IMAGE_URI_DIGEST_ENV_VAR}" ]]; then
    export "${IMAGE_URI_DIGEST_ENV_VAR}"="${IMAGE_DIGEST}"
    echo "export ${IMAGE_URI_DIGEST_ENV_VAR}=${IMAGE_DIGEST}" | tee -a "${BASH_ENV}"
fi

printf "Done setting environment variables."
