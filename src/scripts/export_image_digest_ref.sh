#!/bin/bash

# Export an image digest reference, REPOSITORY@DIGEST, for later steps in this
# job. The digest is read for the image reference (<image>:<tag>) held in the
# variable that export_image_ref wrote.
#
# crane digest is used when crane is installed, because it reads the registry.
# Otherwise docker's RepoDigests is used. The step fails when that read fails,
# when neither tool exists, or when the result is not a sha256, sha384, or
# sha512 digest. BASH_ENV is left unchanged on failure.
#
# A colon is a tag separator only in the last path component, so a registry
# port stays part of the name:
#   localhost:5000/org/app:1.2.3 -> localhost:5000/org/app

set -e
set +o history

# Name without a tag or digest. "${ref%:*}" strips the last colon-suffix, which
# is the tag once we know the last path component contains one.
repository_name() {
    local ref="${1%@*}"
    local last="${ref##*/}"
    if [[ "$last" == *:* ]]; then
        ref="${ref%:*}"
    fi
    printf '%s\n' "$ref"
}

# Tools print either "sha256:..." or "registry/name@sha256:...".
normalize_digest() {
    local raw="$1"
    raw="${raw//$'\r'/}"
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
    if [[ "$raw" == *@* ]]; then
        raw="${raw##*@}"
    fi
    # ${var,,} is Bash 4. This command runs with the executor's /bin/bash, which
    # is still Bash 3.2 on CircleCI macOS. tr is locale-independent for A-Z.
    raw="$(tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz' <<< "$raw")"
    printf '%s' "$raw"
}

valid_digest() {
    local digest="$1"
    if [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        return 0
    fi
    if [[ "$digest" =~ ^sha384:[0-9a-f]{96}$ ]]; then
        return 0
    fi
    if [[ "$digest" =~ ^sha512:[0-9a-f]{128}$ ]]; then
        return 0
    fi
    return 1
}

image_is_missing() {
    local text="$1"
    if [[ "$text" == *"No such image"* || "$text" == *"no such image"* ]]; then
        return 0
    fi
    return 1
}

IMAGE_REF_ENV_VAR=$(printf '%s' "${PARAM_IMAGE_REF_ENV_VAR}" | circleci env subst)
IMAGE_DIGEST_REF_ENV_VAR=$(printf '%s' "${PARAM_IMAGE_DIGEST_REF_ENV_VAR}" | circleci env subst)

echo "Exporting the image digest reference environment variable..."
echo "  IMAGE_REF_ENV_VAR: ${IMAGE_REF_ENV_VAR}"
echo "  IMAGE_DIGEST_REF_ENV_VAR: ${IMAGE_DIGEST_REF_ENV_VAR}"

if [[ ! "${IMAGE_REF_ENV_VAR}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "Error: image_ref_env_var '${IMAGE_REF_ENV_VAR}' is not a shell identifier."
    exit 1
fi
if [[ ! "${IMAGE_DIGEST_REF_ENV_VAR}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "Error: image_digest_ref_env_var '${IMAGE_DIGEST_REF_ENV_VAR}' is not a shell identifier."
    exit 1
fi
if [[ -z "${BASH_ENV:-}" ]]; then
    echo "Error: BASH_ENV is unset, so the digest cannot be passed to later steps."
    exit 1
fi

# The name matched the identifier pattern above, so this indirect expansion is safe.
IMAGE_REF="${!IMAGE_REF_ENV_VAR-}"
echo "  IMAGE_REF: ${IMAGE_REF}"

if [[ -z "${IMAGE_REF}" ]]; then
    echo "Error: ${IMAGE_REF_ENV_VAR} is empty."
    echo "Run export_image_ref before export_image_digest_ref."
    exit 1
fi
if [[ "${IMAGE_REF}" == *[[:space:]]* ]]; then
    echo "Error: ${IMAGE_REF_ENV_VAR} contains whitespace, so the registry digest cannot be read."
    exit 1
fi

IMAGE="$(repository_name "${IMAGE_REF}")"
IMAGE_LAST="${IMAGE##*/}"
echo "  IMAGE: ${IMAGE}"
if [[ -z "${IMAGE}" || -z "${IMAGE_LAST}" || "${IMAGE}" == *@* || "${IMAGE_LAST}" == *:* ]]; then
    echo "Error: could not parse a repository name from '${IMAGE_REF}', so the registry digest cannot be read."
    exit 1
fi

err_file="$(mktemp)"
trap 'rm -f "$err_file"' EXIT

if command -v crane >/dev/null 2>&1; then
    echo "  TOOL: crane"
    # A failing crane is fatal. Falling through to a local docker image would
    # publish a different digest and hide the registry failure.
    if ! DIGEST="$(crane digest "${IMAGE_REF}" 2>"$err_file")"; then
        echo "Error: crane digest failed for '${IMAGE_REF}', so the registry digest cannot be read."
        cat "$err_file"
        exit 1
    fi
    if [[ -s "$err_file" ]]; then
        echo "  crane stderr:"
        cat "$err_file"
    fi
elif command -v docker >/dev/null 2>&1; then
    echo "  TOOL: docker"
    if docker image inspect "${IMAGE_REF}" >/dev/null 2>"$err_file"; then
        echo "The image exists locally."
    elif image_is_missing "$(cat "$err_file")"; then
        echo "The image does not exist locally. Pulling ${IMAGE_REF}..."
        if ! docker pull "${IMAGE_REF}" 2>"$err_file"; then
            echo "Error: docker pull failed for '${IMAGE_REF}', so the registry digest cannot be read."
            cat "$err_file"
            exit 1
        fi
    else
        echo "Error: docker image inspect failed for '${IMAGE_REF}', so the registry digest cannot be read."
        cat "$err_file"
        exit 1
    fi

    # RepoDigests names whichever registry this daemon stored first. Keep that
    # digest, and attach it to the repository name we were asked for. An empty
    # list renders as an empty string instead of a template error.
    if ! DIGEST="$(docker inspect --format='{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "${IMAGE_REF}" 2>"$err_file")"; then
        echo "Error: docker inspect failed for '${IMAGE_REF}', so the registry digest cannot be read."
        cat "$err_file"
        exit 1
    fi
else
    echo "Error: neither crane nor docker is available, so the registry digest cannot be read."
    exit 1
fi

DIGEST="$(normalize_digest "${DIGEST}")"
echo "  DIGEST=${DIGEST}"

if [[ -z "${DIGEST}" || "${DIGEST}" == "<no value>" ]]; then
    echo "Error: no registry digest was returned for '${IMAGE_REF}', so the registry digest cannot be read."
    echo "crane reads the registry. docker can only use a RepoDigest already stored for a pulled or pushed image."
    exit 1
fi
if ! valid_digest "${DIGEST}"; then
    echo "Error: digest '${DIGEST}' for '${IMAGE_REF}' is not a sha256, sha384, or sha512 digest, so the registry digest cannot be read."
    exit 1
fi

IMAGE_DIGEST_REF="${IMAGE}@${DIGEST}"
echo "  IMAGE_DIGEST_REF=${IMAGE_DIGEST_REF}"
echo "Exporting value..."

# Write the file ourselves. A pipeline into tee would report the status of
# printf, so a BASH_ENV that cannot be written would still exit 0.
export "${IMAGE_DIGEST_REF_ENV_VAR}=${IMAGE_DIGEST_REF}"
export_line="$(printf 'export %s=%q' "${IMAGE_DIGEST_REF_ENV_VAR}" "${IMAGE_DIGEST_REF}")"
printf '%s\n' "${export_line}"
printf '%s\n' "${export_line}" >> "${BASH_ENV}"
printf 'Done setting environment variable.\n'
