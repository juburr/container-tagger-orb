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

# Decode %HH the way git decodes userinfo: the split on "@" happens first, then
# each component is decoded. "%40" therefore stays inside a password.
percent_decode() {
    local rest="$1"
    local out="" hex byte hex_re
    # No capture group: bash 3.2 leaves BASH_REMATCH[1] empty, so take the
    # two digits the match already proved are present.
    hex_re='^[0-9A-Fa-f][0-9A-Fa-f]'
    while [[ "${rest}" == *%* ]]; do
        # "%" is literal; the unquoted * is the glob. Quoting the whole
        # pattern would look for a percent sign followed by a star.
        out="${out}${rest%%"%"*}"
        rest="${rest#*"%"}"
        if [[ "${rest}" =~ $hex_re ]]; then
            hex="${rest:0:2}"
            # %b interprets the hex escape; the format string itself is fixed.
            printf -v byte '%b' "\\x${hex}"
            out="${out}${byte}"
            rest="${rest:2}"
        else
            out="${out}%"
        fi
    done
    printf '%s' "${out}${rest}"
}

git_config_quote() {
    local value="$1"
    case "${value}" in
        *$'\n'*) return 1 ;;
    esac
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '%s' "${value}"
}

# Classify an effective remote URL.
#   0  http(s) URL with userinfo; REMOTE_* describe how to shield it
#   1  nothing to shield
#   2  userinfo is present but cannot be moved safely
# Git splits userinfo on the first "@", then on the first ":" inside that.
classify_remote_url() {
    local url="$1"
    local scheme rest userinfo after authority
    REMOTE_STRIPPED_URL=""
    REMOTE_USERNAME=""
    REMOTE_PASSWORD=""
    REMOTE_HAS_PASSWORD=0
    REMOTE_PROTOCOL=""
    REMOTE_HOST=""
    case "${url}" in
        *$'\n'*|*$'\r'*) return 2 ;;
    esac
    case "${url}" in
        *://*) ;;
        *) return 1 ;;
    esac
    scheme="${url%%://*}"
    rest="${url#*://}"
    case "${scheme}" in
        http|https|HTTP|HTTPS) ;;
        *) return 1 ;;
    esac
    case "${rest}" in
        *"@"*) ;;
        *) return 1 ;;
    esac
    userinfo="${rest%%@*}"
    after="${rest#*@}"
    case "${userinfo}" in
        *%00*) return 2 ;;
    esac
    if [[ "${userinfo}" == *:* ]]; then
        REMOTE_HAS_PASSWORD=1
        REMOTE_USERNAME=$(percent_decode "${userinfo%%:*}") || return 2
        REMOTE_PASSWORD=$(percent_decode "${userinfo#*:}") || return 2
    else
        REMOTE_USERNAME=$(percent_decode "${userinfo}") || return 2
    fi
    case "${REMOTE_USERNAME}${REMOTE_PASSWORD}" in
        *$'\n'*|*$'\r'*) return 2 ;;
    esac
    REMOTE_STRIPPED_URL="${scheme}://${after}"
    REMOTE_PROTOCOL=$(printf '%s' "${scheme}" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz')
    authority="${after}"
    case "${authority}" in
        *[[:space:]/?#]*)
            authority="${authority%%[[:space:]/?#]*}"
            ;;
    esac
    case "${authority}" in
        *%00*) return 2 ;;
    esac
    REMOTE_HOST=$(percent_decode "${authority}") || return 2
    case "${REMOTE_HOST}" in
        *$'\n'*|*$'\r'*|"") return 2 ;;
    esac
    return 0
}

# Rewrite this one invocation so git-remote-http receives a URL with no
# userinfo. The checkout's stored remote is not modified. Credential material
# stays in mode-600 files; it is not placed on a command line.
write_auth_shield() {
    local dir="$1"
    local effective="$2"
    (
        # The caller is `if ! load_git_tags`, which disables set -e for this
        # whole call stack. Turn it back on so a partial shield is not used.
        set -e
        umask 077
        printf '%s' "${REMOTE_USERNAME}" > "${dir}/username"
        printf '%s' "${REMOTE_PROTOCOL}" > "${dir}/protocol"
        printf '%s' "${REMOTE_HOST}" > "${dir}/host"
        if [[ "${REMOTE_HAS_PASSWORD}" -eq 1 ]]; then
            printf '%s' "${REMOTE_PASSWORD}" > "${dir}/password"
        fi
        quoted_base=$(git_config_quote "${REMOTE_STRIPPED_URL}") || exit 1
        quoted_effective=$(git_config_quote "${effective}") || exit 1
        {
            printf '[url "%s"]\n' "${quoted_base}"
            printf '\tinsteadOf = "%s"\n' "${quoted_effective}"
            printf '\tinsteadOf = "%s"\n' "${quoted_base}"
        } > "${dir}/rewrite"
        cat > "${dir}/helper" << 'EOF'
#!/bin/sh
# Credential helper for one ls-remote. The secret values live in files.
[ "${1:-}" = "get" ] || exit 0
proto=""
host=""
while IFS= read -r line; do
    [ -z "${line}" ] && break
    case "${line}" in
        protocol=*) proto=${line#protocol=} ;;
        host=*) host=${line#host=} ;;
    esac
done
[ "${proto}" = "$(cat "${CRED_DIR}/protocol")" ] || exit 0
[ "${host}" = "$(cat "${CRED_DIR}/host")" ] || exit 0
printf 'username=%s\n' "$(cat "${CRED_DIR}/username")"
if [ -f "${CRED_DIR}/password" ]; then
    printf 'password=%s\n' "$(cat "${CRED_DIR}/password")"
fi
printf '\n'
exit 0
EOF
        chmod 700 "${dir}/helper"
    )
}

# Read tag names from the remote. On success, set remote_raw.
fetch_remote_tag_text() {
    local tag_remote="$1"
    local err_file="$2"
    local remote_url classify_status shield_dir ls_status
    # classify_remote_url writes these and write_auth_shield reads them.
    # shellcheck disable=SC2034
    local REMOTE_STRIPPED_URL REMOTE_USERNAME REMOTE_PASSWORD REMOTE_HAS_PASSWORD REMOTE_PROTOCOL REMOTE_HOST
    if ! remote_url=$(git --no-pager remote get-url "${tag_remote}" 2>"${err_file}"); then
        refuse_history "git remote get-url failed for '${tag_remote}', so existing release tags cannot be compared." "${err_file}"
        return 1
    fi
    classify_remote_url "${remote_url}"
    classify_status=$?
    if [[ "${classify_status}" -eq 2 ]]; then
        refuse_history "the remote URL for '${tag_remote}' cannot be read without exposing embedded credentials, so existing release tags cannot be compared." "${err_file}"
        return 1
    fi
    if [[ "${classify_status}" -eq 0 ]]; then
        shield_dir=$(mktemp -d) || {
            echo "Error: could not create a temporary directory, so existing release tags cannot be compared."
            echo "Refusing to publish latest, major, or minor tags from an incomplete history."
            return 1
        }
        chmod 700 "${shield_dir}"
        if ! write_auth_shield "${shield_dir}" "${remote_url}"; then
            rm -rf "${shield_dir}"
            refuse_history "the remote URL for '${tag_remote}' cannot be read without exposing embedded credentials, so existing release tags cannot be compared." "${err_file}"
            return 1
        fi
        ls_status=0
        # include.path rewrites the URL before git-remote-http is spawned.
        # The empty credential.helper value clears inherited helpers so the
        # credentials that were embedded in the URL remain the ones that are used.
        remote_raw=$(
            CRED_DIR="${shield_dir}" \
            GIT_TERMINAL_PROMPT=0 \
            git -c "include.path=${shield_dir}/rewrite" \
                -c 'credential.helper=' \
                -c "credential.helper=${shield_dir}/helper" \
                --no-pager ls-remote --refs --tags -- "${tag_remote}" \
                2>"${err_file}"
        ) || ls_status=$?
        rm -rf "${shield_dir}"
        if [[ "${ls_status}" -ne 0 ]]; then
            refuse_history "git ls-remote failed for '${tag_remote}', so existing release tags cannot be compared." "${err_file}"
            return 1
        fi
        return 0
    fi
    if ! remote_raw=$(GIT_TERMINAL_PROMPT=0 git --no-pager ls-remote --refs --tags -- "${tag_remote}" 2>"${err_file}"); then
        refuse_history "git ls-remote failed for '${tag_remote}', so existing release tags cannot be compared." "${err_file}"
        return 1
    fi
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
        if ! fetch_remote_tag_text "${tag_remote}" "${err_file}"; then
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
