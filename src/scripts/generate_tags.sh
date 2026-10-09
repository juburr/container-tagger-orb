#!/bin/bash

set -e
set +o history

# Read command arguments
OUTFILE=$(circleci env subst "${PARAM_OUTFILE}")
PACKAGE=$(circleci env subst "${PARAM_PACKAGE}")

# Print arguments for debugging purposes
echo "Input arguments for tag generation command:"
echo "  CIRCLE_BRANCH: ${CIRCLE_BRANCH}"
echo "  CIRCLE_BUILD_NUM: ${CIRCLE_BUILD_NUM}"
echo "  CIRCLE_SHA1: ${CIRCLE_SHA1}"
echo "  CIRCLE_TAG: ${CIRCLE_TAG}"
echo "  OUTFILE: ${OUTFILE}"
echo "  PACKAGE: ${PACKAGE}"
echo ""

# Supported release tags, after an optional package prefix:
#   v1.2.3
#   v1.2.3-rc1, v1.2.3-alpha1, v1.2.3-beta4
#   v1.2.3-rc, v1.2.3-alpha, v1.2.3-beta
#   v1.2.3-rc.1, v1.2.3-alpha.1, v1.2.3-beta.2
# A trailing dot (v1.2.3-rc.) is rejected: that would be an empty identifier.
TAG="${CIRCLE_TAG#"${PACKAGE}/"}"
RELEASE_TAG_RE='^v[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)([0-9]+|\.[0-9]+)?)?$'
if [[ -n "${CIRCLE_TAG}" ]] && [[ ! "${TAG}" =~ $RELEASE_TAG_RE ]]; then
    echo "Error: CIRCLE_TAG '${CIRCLE_TAG}' is not a supported release tag."
    echo "Expected vMAJOR.MINOR.PATCH with an optional -alpha, -beta, or -rc suffix, for example v2.0.0, v2.0.0-rc1, v2.0.0-rc, or v2.0.0-rc.1."
    echo "Refusing to publish a dev or edge tag for this tag."
    exit 1
fi

echo "Computing absolute path for output tag file..."
OUTFILE=$(realpath --no-symlinks "${OUTFILE}")
echo "  OUTFILE: ${OUTFILE}"
echo ""

# Reset the output file, in case the script is ran multiple times.
echo "Truncating ${OUTFILE}..."
truncate -s 0 "${OUTFILE}"
echo "  Done."
echo ""

# Read every tag name we can prove exists, and keep each command's exit status.
# The old `{ git tag; echo ...; }` group hid a failing `git tag`: echo still
# succeeded, so the tag being built looked like the only release and took
# :latest. A shallow checkout has the same result with a successful `git tag`:
# the command exits 0 and lists only the tags inside that shallow history.
# When a remote exists, its tag names come from `git ls-remote` (names only,
# not `git fetch --tags`, which would download every tagged commit). If that
# read fails, local tags are not used instead. An empty list is a first release.
# Called from `if !`, so `set -e` does not apply in these functions. Every git
# command checks its own status.
#
# Git error text can echo the remote URL, and a CircleCI token often sits in
# that URL's userinfo. Strip userinfo before printing.
redact_userinfo() {
    local line="$1"
    local out="" rest authority after_auth host
    rest="${line}"
    while [[ "${rest}" == *"://"* ]]; do
        out="${out}${rest%%"://"*}"
        rest="${rest#*"://"}"
        # The authority ends at the path, query, fragment, or whitespace.
        # Userinfo is everything before the last "@" in that authority, which
        # is where git and curl split even if a password itself contains "@".
        if [[ "${rest}" == *[[:space:]/?#]* ]]; then
            authority="${rest%%[[:space:]/?#]*}"
            after_auth="${rest#"${authority}"}"
        else
            authority="${rest}"
            after_auth=""
        fi
        if [[ -n "${authority}" && "${authority}" == *"@"* ]]; then
            host="${authority##*"@"}"
            out="${out}://${host}"
        else
            out="${out}://${authority}"
        fi
        rest="${after_auth}"
    done
    printf '%s\n' "${out}${rest}"
}

print_redacted_file() {
    local err_file="$1"
    local line
    if [[ -z "${err_file}" || ! -s "${err_file}" ]]; then
        return 0
    fi
    while IFS= read -r line || [[ -n "${line}" ]]; do
        redact_userinfo "${line}"
    done < "${err_file}"
}

refuse_history() {
    local message="$1"
    local err_file="$2"
    echo "Error: ${message}"
    print_redacted_file "${err_file}"
    echo "Refusing to publish latest, major, or minor tags from an incomplete history."
    rm -f "${err_file}"
}

append_known_tag() {
    local name="$1"
    if [[ -z "${name}" ]]; then
        return 0
    fi
    if [[ -n "${GIT_TAGS}" ]]; then
        GIT_TAGS+=$'\n'"${name}"
    else
        GIT_TAGS="${name}"
    fi
}

# ls-remote lines are "<oid><whitespace>refs/tags/<name>". Annotated tags also
# appear as refs/tags/<name>^{}; those are the same tag and are skipped.
add_remote_tag_names() {
    local raw="$1"
    local line oid ref name
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -z "${line}" ]] && continue
        oid="${line%%[[:space:]]*}"
        ref="${line#"${oid}"}"
        ref="${ref#"${ref%%[![:space:]]*}"}"
        if [[ -z "${ref}" || "${ref}" == *'^{}' ]]; then
            continue
        fi
        if [[ "${ref}" != refs/tags/* ]]; then
            continue
        fi
        name="${ref#refs/tags/}"
        append_known_tag "${name}"
    done <<< "${raw}"
}

load_git_tags() {
    local err_file work_tree remotes line remote_count only_remote saw_origin tag_remote remote_raw
    err_file=$(mktemp) || {
        echo "Error: could not create a temporary file, so existing release tags cannot be compared."
        echo "Refusing to publish latest, major, or minor tags from an incomplete history."
        return 1
    }
    if ! work_tree=$(git rev-parse --is-inside-work-tree 2>"${err_file}"); then
        refuse_history "git cannot read this checkout, so existing release tags cannot be compared." "${err_file}"
        return 1
    fi
    # `rev-parse` exits 0 and prints "false" inside a .git directory. That is
    # not a checkout this command can trust, even though the command succeeded.
    if [[ "${work_tree}" != "true" ]]; then
        refuse_history "this directory is not a git work tree, so existing release tags cannot be compared." "${err_file}"
        return 1
    fi
    if ! remotes=$(git --no-pager remote 2>"${err_file}"); then
        refuse_history "git remote failed, so existing release tags cannot be compared." "${err_file}"
        return 1
    fi

    remote_count=0
    only_remote=""
    saw_origin=0
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -z "${line}" ]] && continue
        remote_count=$((remote_count + 1))
        only_remote="${line}"
        if [[ "${line}" == "origin" ]]; then
            saw_origin=1
        fi
    done <<< "${remotes}"

    tag_remote=""
    if [[ "${saw_origin}" -eq 1 ]]; then
        tag_remote="origin"
    elif [[ "${remote_count}" -eq 0 ]]; then
        tag_remote=""
    elif [[ "${remote_count}" -eq 1 ]]; then
        tag_remote="${only_remote}"
    else
        refuse_history "this checkout has multiple git remotes and none is named origin, so existing release tags cannot be compared." "${err_file}"
        return 1
    fi

    if ! GIT_TAGS=$(git --no-pager tag 2>"${err_file}"); then
        refuse_history "git tag failed, so existing release tags cannot be compared." "${err_file}"
        return 1
    fi

    if [[ -n "${tag_remote}" ]]; then
        echo "  Comparing local tags with ${tag_remote}."
        # Names only. `--` keeps a remote name from being parsed as an option.
        # Do not prompt: a missing credential must fail the release, not hang the job.
        # The remote name is passed, not its URL, so a token in the URL stays out of the process list.
        if ! remote_raw=$(GIT_TERMINAL_PROMPT=0 git --no-pager ls-remote --refs --tags -- "${tag_remote}" 2>"${err_file}"); then
            refuse_history "git ls-remote failed for '${tag_remote}', so existing release tags cannot be compared." "${err_file}"
            return 1
        fi
        if [[ -s "${err_file}" ]]; then
            echo "  git ls-remote stderr:"
            print_redacted_file "${err_file}"
        fi
        add_remote_tag_names "${remote_raw}"
    else
        echo "  No git remote; comparing local tags only."
    fi
    rm -f "${err_file}"
}

echo "Generating tags:"
SHORT_REVISION=$(echo "${CIRCLE_SHA1}" | cut -c 1-8)
echo "  SHORT_REVISION: ${SHORT_REVISION}"
echo "  TAG: ${TAG}"

if [[ -n "${CIRCLE_TAG}" ]]; then
    echo "  Processing release as a new tag. The CIRCLE_TAG env var contained a supported release tag."
    echo "${TAG#v}" >> "${OUTFILE}"
    echo "  Added tag to file: ${TAG#v}"

    MAJOR_VER=$(echo "${TAG}" | cut -c 2- | cut -d . -f 1)
    echo "  MAJOR_VER: ${MAJOR_VER}"
    MINOR_VER=$(echo "${TAG}" | cut -c 2- | cut -d . -f 2)
    echo "  MINOR_VER: ${MINOR_VER}"
    PRERELEASE_VER=""
    PRERELEASE_RE='-(alpha|beta|rc)([0-9]+|\.[0-9]+)?$'
    if [[ "${TAG}" =~ $PRERELEASE_RE ]]; then
        PRERELEASE_VER="${BASH_REMATCH[0]#-}"
    fi
    echo "  PRERELEASE_VER: ${PRERELEASE_VER}"

    ADDED_TAG=$TAG
    if [[ -n "$PACKAGE" ]]; then
        ADDED_TAG="${PACKAGE}/${TAG}"
    fi
    echo "  ADDED_TAG: ${ADDED_TAG}"

    if [[ -z ${PRERELEASE_VER} ]]; then
        echo "  This is a final release. Generating latest, major, and minor tags..."
        # A pre-release never moves floating tags, so it does not read this list.
        # An empty list is a first release and still publishes the floating tags.
        GIT_TAGS=""
        if ! load_git_tags; then
            exit 1
        fi

        HIGHEST_VERSION=$(printf '%s\n' "${GIT_TAGS}" "${ADDED_TAG}" | grep "^${PACKAGE}" |  sed "s#${PACKAGE}/##" | grep -E -i 'v[0-9]+\.[0-9]+\.[0-9]+$' | sort -r --version-sort | head -n 1)
        echo "  HIGHEST_VERSION: ${HIGHEST_VERSION}"
        # Match a whole numeric component. An unescaped "." matches any character,
        # so "v1." also matched v11 and "v1.2." also matched v1.23.
        HIGHEST_WITH_SAME_MAJOR=$(printf '%s\n' "${GIT_TAGS}" "${ADDED_TAG}" | grep "^${PACKAGE}" | sed "s#${PACKAGE}/##" | grep -E -i 'v[0-9]+\.[0-9]+\.[0-9]+$' | grep -E "^v${MAJOR_VER}\.[0-9]+\.[0-9]+$" | sort -r --version-sort | head -n 1)
        echo "  HIGHEST_WITH_SAME_MAJOR: ${HIGHEST_WITH_SAME_MAJOR}"
        HIGHEST_WITH_SAME_MINOR=$(printf '%s\n' "${GIT_TAGS}" "${ADDED_TAG}" | grep "^${PACKAGE}" | sed "s#${PACKAGE}/##" | grep -E -i 'v[0-9]+\.[0-9]+\.[0-9]+$' | grep -E "^v${MAJOR_VER}\.${MINOR_VER}\.[0-9]+$" | sort -r --version-sort | head -n 1)
        echo "  HIGHEST_WITH_SAME_MINOR: ${HIGHEST_WITH_SAME_MINOR}"


        if [[ ${TAG} == "${HIGHEST_WITH_SAME_MINOR}" ]] ; then
	        echo "${MAJOR_VER}.${MINOR_VER}" >> "${OUTFILE}"
            echo "  Added tag to output file: ${MAJOR_VER}.${MINOR_VER}"
        fi

        if [[ ${TAG} == "${HIGHEST_WITH_SAME_MAJOR}" ]] ; then
	        echo "${MAJOR_VER}" >> "${OUTFILE}"
            echo "  Added tag to output file: ${MAJOR_VER}"
        fi

        if [[ ${TAG} == "${HIGHEST_VERSION}" ]] ; then
	        echo "latest" >> "${OUTFILE}"
            echo "  Added tag to output file: latest"
        fi
    else
        echo "  This is a pre-release. Not creating latest, major, or minor tags."
    fi
elif [ "$CIRCLE_BRANCH" = develop ] || [ "$CIRCLE_BRANCH" = main ] || [ "$CIRCLE_BRANCH" = master ]; then
    echo "  Processing as a merged pull request. The CIRCLE_BRANCH was set to a known trunk branch."
    echo "edge" >> "${OUTFILE}"
    echo "${CIRCLE_BRANCH}-${SHORT_REVISION}" >> "${OUTFILE}"
    echo "  Added tag to output file: ${CIRCLE_BRANCH}-${SHORT_REVISION}"
else
    echo "  Processing as a commit to a development branch."
    echo "dev-${SHORT_REVISION}" >> "${OUTFILE}"
    echo "  Added tag to output file: dev-${SHORT_REVISION}"
fi
echo "  Done."
echo ""

echo "The following tags were generated and written to ${OUTFILE}:"
awk '{print "  :"$1}' "${OUTFILE}"
