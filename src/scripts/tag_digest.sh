#!/bin/bash

# Apply every tag in a tags file to an image that is already in a registry,
# named as REPOSITORY@sha256:DIGEST. `crane tag` re-PUTs the existing manifest
# under each tag, so a multi-platform index keeps its digest and every
# platform. No image content is pulled or pushed. The tag and push commands
# pull, retag, and push one platform, which would flatten such an index.
#
# Before writing, the current digest of every tag is read and logged in the
# "<tag> <digest|absent>" form that the optional expected digests file uses.
# If that file is given and any tag differs, nothing is written. After
# writing, every tag must resolve to the source digest.
#
# The expected-digest check is not atomic. Registries have no conditional tag
# write, so another writer between the check and the write is not detected.

set -e
set +o history

# ==========================================
# Handle Input
# ==========================================

IMAGE_DIGEST=$(circleci env subst "${PARAM_IMAGE_DIGEST}")
TAGS_FILE=$(circleci env subst "${PARAM_TAGS_FILE}")
EXPECTED_FILE=$(circleci env subst "${PARAM_EXPECTED_DIGESTS_FILE}")

echo "Tagging an image in its registry by digest..."
echo "  IMAGE_DIGEST: ${IMAGE_DIGEST}"
echo "  TAGS_FILE: ${TAGS_FILE}"
echo "  EXPECTED_DIGESTS_FILE: ${EXPECTED_FILE}"

# The OCI distribution spec's tag grammar.
TAG_RE='^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$'
DIGEST_RE='^sha256:[0-9a-f]{64}$'

err_file="$(mktemp)"
trap 'rm -f "$err_file"' EXIT

fail() {
    local line
    for line in "$@"; do
        echo "Error: ${line}"
    done
    exit 1
}

# Strip one trailing carriage return, so a tags file saved with CRLF works.
strip_cr() {
    printf '%s' "${1%$'\r'}"
}

if ! command -v crane >/dev/null 2>&1; then
    fail "crane was not found on PATH. tag_digest needs crane to tag an image in its registry." \
        "Install it before this step, from https://github.com/google/go-containerregistry/releases, and verify its checksum."
fi

if [[ -z "${IMAGE_DIGEST}" ]]; then
    fail "image_digest is empty. Pass REPOSITORY@sha256:DIGEST, for example \${IMAGE_URI_DIGEST} from populate_image_uri_digest."
fi
if [[ "${IMAGE_DIGEST}" == *[[:space:]]* ]]; then
    fail "image_digest '${IMAGE_DIGEST}' contains whitespace."
fi
if [[ "${IMAGE_DIGEST}" != *@* ]]; then
    fail "image_digest '${IMAGE_DIGEST}' is not REPOSITORY@sha256:DIGEST. A tag is not enough, because a tag can move."
fi
REPOSITORY="${IMAGE_DIGEST%@*}"
DIGEST="${IMAGE_DIGEST##*@}"
REPOSITORY_LAST="${REPOSITORY##*/}"
if [[ -z "${REPOSITORY}" || -z "${REPOSITORY_LAST}" || "${REPOSITORY}" == *@* ]]; then
    fail "image_digest '${IMAGE_DIGEST}' does not name a repository."
fi
# A colon is a tag separator only in the last path component; a registry port
# (localhost:5000/app) stays part of the name.
if [[ "${REPOSITORY_LAST}" == *:* ]]; then
    fail "image_digest '${IMAGE_DIGEST}' has both a tag and a digest. Pass REPOSITORY@sha256:DIGEST only."
fi
if [[ ! "${DIGEST}" =~ $DIGEST_RE ]]; then
    fail "image_digest '${IMAGE_DIGEST}' does not end in a sha256 digest (sha256: and 64 lowercase hex characters)."
fi
echo "  REPOSITORY: ${REPOSITORY}"
echo "  DIGEST: ${DIGEST}"

if [[ -z "${TAGS_FILE}" ]]; then
    fail "A tags file must be specified."
fi
if [[ ! -f "${TAGS_FILE}" ]]; then
    fail "Unable to find tags file: ${TAGS_FILE}"
fi

TAGS=()
while IFS= read -r line || [[ -n "${line}" ]]; do
    line="$(strip_cr "${line}")"
    if [[ -z "${line}" ]]; then
        continue
    fi
    if [[ ! "${line}" =~ $TAG_RE ]]; then
        fail "'${line}' in ${TAGS_FILE} is not a valid tag."
    fi
    for existing in "${TAGS[@]}"; do
        if [[ "${existing}" == "${line}" ]]; then
            fail "'${line}' appears more than once in ${TAGS_FILE}."
        fi
    done
    TAGS+=("${line}")
done < "${TAGS_FILE}"
if [[ "${#TAGS[@]}" -eq 0 ]]; then
    fail "${TAGS_FILE} does not contain any tags."
fi

# Expected digests: one "<tag> <sha256:...|absent>" line per tag in the tags
# file. Blank lines and lines starting with # are ignored.
EXPECTED_TAGS=()
EXPECTED_VALUES=()
if [[ -n "${EXPECTED_FILE}" ]]; then
    if [[ ! -f "${EXPECTED_FILE}" ]]; then
        fail "Unable to find expected digests file: ${EXPECTED_FILE}"
    fi
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="$(strip_cr "${line}")"
        if [[ -z "${line//[[:space:]]/}" || "${line}" == \#* ]]; then
            continue
        fi
        tag=""
        value=""
        extra=""
        read -r tag value extra <<< "${line}"
        if [[ ! "${tag}" =~ $TAG_RE || -n "${extra}" ]] || { [[ "${value}" != "absent" ]] && [[ ! "${value}" =~ $DIGEST_RE ]]; }; then
            fail "'${line}' in ${EXPECTED_FILE} is not '<tag> <sha256:digest>' or '<tag> absent'."
        fi
        for existing in "${EXPECTED_TAGS[@]}"; do
            if [[ "${existing}" == "${tag}" ]]; then
                fail "'${tag}' appears more than once in ${EXPECTED_FILE}."
            fi
        done
        EXPECTED_TAGS+=("${tag}")
        EXPECTED_VALUES+=("${value}")
    done < "${EXPECTED_FILE}"
fi

# Print the expected value for a tag, or return 1 when the file has none.
expected_value() {
    local tag="$1" i
    for i in "${!EXPECTED_TAGS[@]}"; do
        if [[ "${EXPECTED_TAGS[$i]}" == "${tag}" ]]; then
            printf '%s' "${EXPECTED_VALUES[$i]}"
            return 0
        fi
    done
    return 1
}

if [[ -n "${EXPECTED_FILE}" ]]; then
    for tag in "${TAGS[@]}"; do
        if ! expected_value "${tag}" >/dev/null; then
            fail "${EXPECTED_FILE} has no expected digest for tag '${tag}'. Every tag needs one, so no tag is written unchecked."
        fi
    done
    for tag in "${EXPECTED_TAGS[@]}"; do
        found=0
        for existing in "${TAGS[@]}"; do
            if [[ "${existing}" == "${tag}" ]]; then
                found=1
            fi
        done
        if [[ "${found}" -eq 0 ]]; then
            fail "${EXPECTED_FILE} lists tag '${tag}', which is not in ${TAGS_FILE}."
        fi
    done
fi

# ==========================================
# Registry Reads
# ==========================================

# Print the digest a reference points at, or "absent" when the registry says
# it does not exist. Any other failure, such as auth or network, returns 1.
# crane logs a failed HEAD first, so only its final line describes the error.
current_digest() {
    local ref="$1" out last
    if out="$(crane digest "${ref}" 2>"$err_file")"; then
        out="${out//[[:space:]]/}"
        if [[ ! "${out}" =~ $DIGEST_RE ]]; then
            echo "crane digest returned '${out}' for '${ref}', which is not a sha256 digest." >> "$err_file"
            return 1
        fi
        printf '%s' "${out}"
        return 0
    fi
    last="$(grep -v '^[[:space:]]*$' "$err_file" | tail -n 1)"
    case "${last}" in
        *MANIFEST_UNKNOWN*|*NAME_UNKNOWN*|*NOT_FOUND*|*"404 Not Found"*)
            printf 'absent'
            return 0
            ;;
    esac
    return 1
}

echo "Checking the source image..."
if ! SOURCE_CURRENT="$(current_digest "${IMAGE_DIGEST}")"; then
    echo "Error: could not read '${IMAGE_DIGEST}' from the registry."
    cat "$err_file"
    exit 1
fi
if [[ "${SOURCE_CURRENT}" == "absent" ]]; then
    fail "'${IMAGE_DIGEST}' was not found in the registry. tag_digest only tags an image that is already there."
fi
if [[ "${SOURCE_CURRENT}" != "${DIGEST}" ]]; then
    fail "The registry returned ${SOURCE_CURRENT} for '${IMAGE_DIGEST}'."
fi
echo "  Found ${IMAGE_DIGEST}"

# Record every tag before any write, so a failed or unwanted run can be undone
# by tagging the logged digests again.
echo "Current digests, before writing (expected_digests_file format):"
CURRENT_VALUES=()
for tag in "${TAGS[@]}"; do
    if ! current="$(current_digest "${REPOSITORY}:${tag}")"; then
        echo "Error: could not read the current digest of '${REPOSITORY}:${tag}'. No tag was written."
        cat "$err_file"
        exit 1
    fi
    CURRENT_VALUES+=("${current}")
    echo "  ${tag} ${current}"
done

if [[ -n "${EXPECTED_FILE}" ]]; then
    echo "Comparing with ${EXPECTED_FILE}..."
    mismatches=0
    for i in "${!TAGS[@]}"; do
        expected="$(expected_value "${TAGS[$i]}")"
        if [[ "${CURRENT_VALUES[$i]}" != "${expected}" ]]; then
            echo "  ${TAGS[$i]}: expected ${expected}, found ${CURRENT_VALUES[$i]}"
            mismatches=$((mismatches + 1))
        fi
    done
    if [[ "${mismatches}" -ne 0 ]]; then
        fail "${mismatches} tag(s) no longer match ${EXPECTED_FILE}. No tag was written."
    fi
    echo "  Every tag matches."
fi

# ==========================================
# Registry Writes
# ==========================================

echo "Writing tags..."
WRITTEN=()
for i in "${!TAGS[@]}"; do
    tag="${TAGS[$i]}"
    if [[ "${CURRENT_VALUES[$i]}" == "${DIGEST}" ]]; then
        echo "  ${REPOSITORY}:${tag} already points at ${DIGEST}; not rewritten."
        continue
    fi
    echo "  ${REPOSITORY}:${tag} -> ${DIGEST} (was ${CURRENT_VALUES[$i]})"
    if ! crane tag "${IMAGE_DIGEST}" "${tag}" 2>"$err_file"; then
        echo "Error: crane tag failed for '${REPOSITORY}:${tag}'."
        cat "$err_file"
        if [[ "${#WRITTEN[@]}" -gt 0 ]]; then
            echo "These tags were already written: ${WRITTEN[*]}. Their previous digests are logged above."
        else
            echo "No tag was written."
        fi
        exit 1
    fi
    WRITTEN+=("${tag}")
done

# ==========================================
# Verification
# ==========================================

echo "Verifying every tag resolves to ${DIGEST}..."
failures=0
for tag in "${TAGS[@]}"; do
    if ! current="$(current_digest "${REPOSITORY}:${tag}")"; then
        echo "  ${tag}: could not be read"
        cat "$err_file"
        failures=$((failures + 1))
    elif [[ "${current}" != "${DIGEST}" ]]; then
        echo "  ${tag}: points at ${current}"
        failures=$((failures + 1))
    else
        echo "  ${tag}: ok"
    fi
done
if [[ "${failures}" -ne 0 ]]; then
    fail "${failures} tag(s) do not point at ${DIGEST} after writing."
fi

echo "Done. ${#TAGS[@]} tag(s) on ${REPOSITORY} point at ${DIGEST}."
