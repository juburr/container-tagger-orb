#!/usr/bin/env bash
# End-to-end check of src/scripts/tag_digest.sh with the real crane and a real
# registry. A public multi-platform image is copied by digest into the local
# registry, tagged in place, and every tag must still be the same index with
# every platform.
#
# Needs crane and jq on PATH, a registry:2 at $REGISTRY (default
# localhost:5000), and network access to the source image.
#
# Run from a checkout, with a registry running:
#   docker run -d -p 5000:5000 registry:2.8.3
#   bash test/tag_digest_registry_test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/src/scripts/tag_digest.sh"
REGISTRY="${REGISTRY:-localhost:5000}"
# gcr.io/distroless/static, an OCI index for six platforms.
SOURCE_IMAGE="${SOURCE_IMAGE:-gcr.io/distroless/static@sha256:58133991db06659feaabe0f4e97a35cebf15ef4ea08f8a4c6d2ee5f75e4aa6a0}"
DIGEST="${SOURCE_IMAGE##*@}"
REPO="${REGISTRY}/tagger-test/static-$$"
INDEX_TYPES='application/vnd.oci.image.index.v1+json application/vnd.docker.distribution.manifest.list.v2+json'

for cmd in crane jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf '%s is required for this test.\n' "$cmd" >&2
    exit 1
  fi
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/circleci" << 'EOF'
#!/usr/bin/env bash
# The scripts pass values on stdin, as with the real `circleci env subst`.
cat
EOF
chmod +x "${TMP}/bin/circleci"

fail() {
  printf 'FAIL %s\n' "$1" >&2
  shift
  printf '  %s\n' "$@" >&2
  exit 1
}

run_tag_digest() {
  local expected="${1-}"
  PARAM_IMAGE_DIGEST="${REPO}@${DIGEST}" \
    PARAM_TAGS_FILE="${TMP}/tags.txt" \
    PARAM_EXPECTED_DIGESTS_FILE="$expected" \
    PATH="${TMP}/bin:${PATH}" \
    bash "$SCRIPT" > "${TMP}/run.log" 2>&1
}

# Print os/architecture[/variant] for every manifest in an index.
platforms() {
  crane manifest "$1" | jq -r '.manifests[] | select(.platform != null) | .platform | [.os, .architecture, .variant // empty] | join("/")' | sort
}

media_type() {
  crane manifest "$1" | jq -r '.mediaType'
}

printf 'Copying %s to %s@%s...\n' "$SOURCE_IMAGE" "$REPO" "$DIGEST"
crane copy "$SOURCE_IMAGE" "${REPO}@${DIGEST}"

SOURCE_PLATFORMS="$(platforms "$SOURCE_IMAGE")"
if [[ "$(crane digest "${REPO}@${DIGEST}")" != "$DIGEST" ]]; then
  fail "the copy keeps the index digest" "$(crane digest "${REPO}@${DIGEST}")"
fi
if [[ " ${INDEX_TYPES} " != *" $(media_type "${REPO}@${DIGEST}") "* ]]; then
  fail "the source is a multi-platform index" "$(media_type "${REPO}@${DIGEST}")"
fi
for platform in linux/amd64 linux/arm64; do
  if ! grep -q "^${platform}" <<< "$SOURCE_PLATFORMS"; then
    fail "the source has ${platform}" "$SOURCE_PLATFORMS"
  fi
done

# latest starts on one platform's manifest, as a flattened push would leave it.
CHILD="$(crane manifest "${REPO}@${DIGEST}" | jq -r '[.manifests[] | select(.platform.architecture == "amd64")][0].digest')"
crane tag "${REPO}@${CHILD}" latest
printf '1.2.3\n1.2\n1\nlatest\n' > "${TMP}/tags.txt"

# A stale expected digest stops every write.
printf '1.2.3 absent\n1.2 absent\n1 absent\nlatest absent\n' > "${TMP}/stale.txt"
if run_tag_digest "${TMP}/stale.txt"; then
  fail "a stale expected digests file stops the run" "$(cat "${TMP}/run.log")"
fi
if [[ "$(crane digest "${REPO}:latest")" != "$CHILD" ]]; then
  fail "a stale expected digests file leaves latest unchanged" "$(crane digest "${REPO}:latest")"
fi
if crane digest "${REPO}:1.2.3" > /dev/null 2>&1; then
  fail "a stale expected digests file does not create 1.2.3"
fi
printf 'ok   a stale expected digests file writes nothing\n'

printf '1.2.3 absent\n1.2 absent\n1 absent\nlatest %s\n' "$CHILD" > "${TMP}/expected.txt"
if ! run_tag_digest "${TMP}/expected.txt"; then
  fail "tag_digest succeeds against registry:2" "$(cat "${TMP}/run.log")"
fi
if ! grep -Fx "  latest ${CHILD}" "${TMP}/run.log" > /dev/null; then
  fail "the previous latest digest is logged" "$(cat "${TMP}/run.log")"
fi
printf 'ok   tag_digest tagged 1.2.3, 1.2, 1, and latest\n'

for tag in 1.2.3 1.2 1 latest; do
  ref="${REPO}:${tag}"
  if [[ "$(crane digest "$ref")" != "$DIGEST" ]]; then
    fail "${tag} resolves to the index digest" "$(crane digest "$ref")"
  fi
  if [[ " ${INDEX_TYPES} " != *" $(media_type "$ref") "* ]]; then
    fail "${tag} is still an index" "$(media_type "$ref")"
  fi
  if [[ "$(platforms "$ref")" != "$SOURCE_PLATFORMS" ]]; then
    fail "${tag} keeps every platform" "expected:" "$SOURCE_PLATFORMS" "actual:" "$(platforms "$ref")"
  fi
  printf 'ok   %s is index %s with %s platforms\n' "$tag" "$DIGEST" "$(wc -l <<< "$SOURCE_PLATFORMS" | tr -d ' ')"
done

if [[ "$(crane digest "${REPO}@${DIGEST}")" != "$DIGEST" ]]; then
  fail "the source index digest is unchanged"
fi

# A second run is a no-op that still verifies.
if ! run_tag_digest; then
  fail "a second run succeeds" "$(cat "${TMP}/run.log")"
fi
if [[ "$(grep -c 'not rewritten' "${TMP}/run.log")" -ne 4 ]]; then
  fail "a second run rewrites nothing" "$(cat "${TMP}/run.log")"
fi
printf 'ok   a second run rewrites nothing\n'

printf 'passed: tag_digest keeps %s and its platforms on every tag\n' "$DIGEST"
