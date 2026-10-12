#!/bin/bash

set -e
set +o history

# Read command arguments
OUTFILE=$(circleci env subst "${PARAM_OUTFILE}")
PACKAGE=$(circleci env subst "${PARAM_PACKAGE}")
SOURCE_TAG_PARAM="${PARAM_SOURCE_TAG-}"
SOURCE_TAG=$(circleci env subst "${SOURCE_TAG_PARAM}")

# Print arguments for debugging purposes
echo "Input arguments for tag generation command:"
echo "  CIRCLE_BRANCH: ${CIRCLE_BRANCH}"
echo "  CIRCLE_BUILD_NUM: ${CIRCLE_BUILD_NUM}"
echo "  CIRCLE_SHA1: ${CIRCLE_SHA1}"
echo "  CIRCLE_TAG: ${CIRCLE_TAG}"
echo "  OUTFILE: ${OUTFILE}"
echo "  PACKAGE: ${PACKAGE}"
echo "  SOURCE_TAG: ${SOURCE_TAG}"
echo ""

# Supported release tags, after an optional package prefix:
#   v1.2.3
#   v1.2.3-rc1, v1.2.3-alpha1, v1.2.3-beta4
#   v1.2.3-rc, v1.2.3-alpha, v1.2.3-beta
#   v1.2.3-rc.1, v1.2.3-alpha.1, v1.2.3-beta.2
# A trailing dot (v1.2.3-rc.) is rejected: that would be an empty identifier.
RELEASE_TAG_RE='^v[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)([0-9]+|\.[0-9]+)?)?$'
RELEASE_TAG_HELP="Expected vMAJOR.MINOR.PATCH with an optional -alpha, -beta, or -rc suffix, for example v2.0.0, v2.0.0-rc1, v2.0.0-rc, or v2.0.0-rc.1."

# Pick the release identity. A set source_tag is the only identity: it must be
# a supported release tag, and nothing falls back to CIRCLE_TAG, CIRCLE_BRANCH,
# edge, or a sha tag. With a package it must be the full tag name,
# <package>/vX.Y.Z, because vX.Y.Z and <package>/vX.Y.Z are different git tags.
# A parameter that was set but expanded to nothing, such as ${RELEASE_TAG} when
# that variable is empty, is an error rather than "unset".
TAG=""
IDENTITY_SOURCE=""
if [[ -n "${SOURCE_TAG_PARAM}" ]]; then
    if [[ -z "${SOURCE_TAG}" ]]; then
        echo "Error: source_tag '${SOURCE_TAG_PARAM}' expanded to an empty value."
        echo "Refusing to fall back to CIRCLE_TAG, CIRCLE_BRANCH, edge, or dev tags."
        exit 1
    fi
    if [[ -n "${CIRCLE_TAG}" && "${CIRCLE_TAG}" != "${SOURCE_TAG}" ]]; then
        echo "Error: source_tag '${SOURCE_TAG}' does not match CIRCLE_TAG '${CIRCLE_TAG}'."
        echo "Refusing to choose between two release identities."
        exit 1
    fi
    if [[ -n "${PACKAGE}" ]]; then
        if [[ "${SOURCE_TAG}" != "${PACKAGE}/"* ]]; then
            echo "Error: source_tag '${SOURCE_TAG}' is not a tag of package '${PACKAGE}'."
            echo "With a package, source_tag must be the full tag name, ${PACKAGE}/vMAJOR.MINOR.PATCH."
            echo "Refusing to fall back to CIRCLE_TAG, CIRCLE_BRANCH, edge, or dev tags."
            exit 1
        fi
        TAG="${SOURCE_TAG#"${PACKAGE}/"}"
    else
        TAG="${SOURCE_TAG}"
    fi
    if [[ ! "${TAG}" =~ $RELEASE_TAG_RE ]]; then
        echo "Error: source_tag '${SOURCE_TAG}' is not a supported release tag."
        echo "${RELEASE_TAG_HELP}"
        echo "Refusing to fall back to CIRCLE_TAG, CIRCLE_BRANCH, edge, or dev tags."
        exit 1
    fi
    IDENTITY_SOURCE="source_tag"
    echo "Release identity: source_tag '${SOURCE_TAG}'. CIRCLE_TAG and CIRCLE_BRANCH are not used."
elif [[ -n "${CIRCLE_TAG}" ]]; then
    TAG="${CIRCLE_TAG#"${PACKAGE}/"}"
    if [[ ! "${TAG}" =~ $RELEASE_TAG_RE ]]; then
        echo "Error: CIRCLE_TAG '${CIRCLE_TAG}' is not a supported release tag."
        echo "${RELEASE_TAG_HELP}"
        echo "Refusing to publish a dev or edge tag for this tag."
        exit 1
    fi
    IDENTITY_SOURCE="CIRCLE_TAG"
    echo "Release identity: CIRCLE_TAG '${CIRCLE_TAG}'."
else
    echo "Release identity: none. CIRCLE_BRANCH '${CIRCLE_BRANCH}' selects edge or dev tags."
fi
echo ""

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

# ${var,,} is Bash 4; macOS executors still run Bash 3.2.
to_lower() {
    printf '%s' "$1" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz'
}

# 0 when a URL of any scheme has userinfo in its authority. This is the last
# check before the transport helper runs, so it does not trust the scheme.
# "@" in the path, query, or fragment does not count: the authority ends at
# the first "/", "?", or "#". Whitespace does not end it, because git passes
# a configured URL to the helper whole, spaces included.
url_has_userinfo() {
    local url="$1"
    local rest authority
    case "${url}" in
        *$'\n'*|*$'\r'*) return 0 ;;
        *://*) ;;
        *) return 1 ;;
    esac
    rest="${url#*://}"
    case "${rest}" in
        *[/?#]*) authority="${rest%%[/?#]*}" ;;
        *) authority="${rest}" ;;
    esac
    case "${authority}" in
        *"@"*) return 0 ;;
    esac
    return 1
}

# Classify an effective remote URL.
#   0  http(s) URL with userinfo; REMOTE_* describe how to shield it
#   1  nothing to shield
#   2  userinfo is present but cannot be moved safely
# Git splits userinfo on the first "@" inside the authority, then on the
# first ":" inside that userinfo. "%40" is decoded only after that split.
# Schemes are case-insensitive (RFC 3986), and a case-insensitive filesystem
# finds git-remote-http for HtTp://, so the scheme is lowercased first. The
# stripped URL uses the lowercase scheme, which every git can resolve.
classify_remote_url() {
    local url="$1"
    local scheme rest userinfo suffix authority hostport
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
    scheme=$(to_lower "${url%%://*}")
    rest="${url#*://}"
    case "${rest}" in
        *[/?#]*)
            authority="${rest%%[/?#]*}"
            suffix="${rest#"${authority}"}"
            ;;
        *)
            authority="${rest}"
            suffix=""
            ;;
    esac
    case "${authority}" in
        *"@"*) ;;
        *) return 1 ;;
    esac
    # Git hands a configured URL to the helper whole, so whitespace inside
    # the authority would carry the userinfo along. No valid URL has it.
    case "${authority}" in
        *[[:space:]]*) return 2 ;;
    esac
    userinfo="${authority%%@*}"
    hostport="${authority#*@}"
    case "${scheme}" in
        http|https) ;;
        *)
            # Other transports also get the URL as a helper or ssh argument,
            # and cannot take a password from a credential helper. A password
            # there cannot be moved. A bare username (ssh://git@host) is not
            # a secret and is left alone.
            case "${userinfo}" in
                *:*) return 2 ;;
            esac
            return 1
            ;;
    esac
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
    # A second "@" means the password was not encoded. Git then treats the
    # remainder as the host, so there is no safe URL to hand to the transport.
    case "${hostport}" in
        *"@"*) return 2 ;;
        *%00*|"") return 2 ;;
    esac
    REMOTE_STRIPPED_URL="${scheme}://${hostport}${suffix}"
    REMOTE_PROTOCOL="${scheme}"
    REMOTE_HOST=$(percent_decode "${hostport}") || return 2
    case "${REMOTE_HOST}" in
        *"@"*|*$'\n'*|*$'\r'*|"") return 2 ;;
    esac
    return 0
}

# Rewrite this one invocation so git-remote-http receives a URL with no
# userinfo. The checkout's stored remote is not modified. Credential material
# stays in mode-600 files; it is not placed on a command line.
# ls-remote is given the stripped URL, not the remote name, so a shorthand
# such as "work:repo.git" is never the string insteadOf starts from. The
# stripped URL maps to itself, which outranks any shorter configured rule
# that would put credentials back, and the caller probes the final URL.
write_auth_shield() {
    local dir="$1"
    local effective="$2"
    (
        # The caller is `if ! load_git_tags`, which disables set -e for this
        # whole call stack. Turn it back on so a partial shield is not used.
        set -e
        umask 077
        quoted_base=$(git_config_quote "${REMOTE_STRIPPED_URL}") || exit 1
        quoted_effective=$(git_config_quote "${effective}") || exit 1
        {
            # No embedded password: keep inherited helpers, and give them the
            # username from this file instead of from the transport URL.
            if [[ "${REMOTE_HAS_PASSWORD}" -eq 0 ]]; then
                quoted_user=$(git_config_quote "${REMOTE_USERNAME}") || exit 1
                printf '[credential]\n'
                printf '\tusername = "%s"\n' "${quoted_user}"
            fi
            printf '[url "%s"]\n' "${quoted_base}"
            printf '\tinsteadOf = "%s"\n' "${quoted_effective}"
            printf '\tinsteadOf = "%s"\n' "${quoted_base}"
        } > "${dir}/rewrite"
        # Without an embedded password this is a fallback after inherited
        # helpers. It answers with an empty password, which is what git itself
        # sends for https://TOKEN@host when no helper has one.
        printf '%s' "${REMOTE_USERNAME}" > "${dir}/username"
        printf '%s' "${REMOTE_PROTOCOL}" > "${dir}/protocol"
        printf '%s' "${REMOTE_HOST}" > "${dir}/host"
        printf '%s' "${REMOTE_PASSWORD}" > "${dir}/password"
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

# Single-quote a value for /bin/sh. Git runs a credential helper through the
# shell, so the helper path must survive a TMPDIR that contains spaces.
sh_quote() {
    local value="$1"
    local escaped="'\\''"
    printf "'%s'" "${value//\'/${escaped}}"
}

# Run git with the shield config. With an embedded password, inherited
# helpers are cleared so the URL's own credentials stay authoritative.
# With only a username, inherited helpers run first and can supply the
# password; the shield's helper is appended last as the empty-password fallback.
shielded_git() {
    local shield_dir="$1"
    local helper
    shift
    # "!" runs the rest as a shell command, quoted, instead of a bare path.
    helper="!$(sh_quote "${shield_dir}/helper")"
    if [[ "${REMOTE_HAS_PASSWORD}" -eq 1 ]]; then
        CRED_DIR="${shield_dir}" \
        GIT_TERMINAL_PROMPT=0 \
        git -c "include.path=${shield_dir}/rewrite" \
            -c 'credential.helper=' \
            -c "credential.helper=${helper}" \
            "$@"
        return
    fi
    CRED_DIR="${shield_dir}" \
    GIT_TERMINAL_PROMPT=0 \
    git -c "include.path=${shield_dir}/rewrite" \
        -c "credential.helper=${helper}" \
        "$@"
}

# The shield directory holds the credentials while ls-remote runs. Remove it
# on every exit, including INT and TERM from a cancelled step, so the token
# is not left in $TMPDIR on a persistent executor. A trap set while a child
# runs fires once that child exits.
SHIELD_DIR=""
remove_shield_dir() {
    if [[ -n "${SHIELD_DIR}" ]]; then
        rm -rf "${SHIELD_DIR}"
        SHIELD_DIR=""
    fi
}
trap remove_shield_dir EXIT
trap 'remove_shield_dir; exit 130' INT
trap 'remove_shield_dir; exit 143' TERM

# Read tag names from the remote. On success, set remote_raw.
fetch_remote_tag_text() {
    local tag_remote="$1"
    local err_file="$2"
    local remote_url classify_status shield_dir ls_status probed_url
    # classify_remote_url writes these and write_auth_shield reads them.
    # shellcheck disable=SC2034
    local REMOTE_STRIPPED_URL REMOTE_USERNAME REMOTE_PASSWORD REMOTE_HAS_PASSWORD REMOTE_PROTOCOL REMOTE_HOST
    if ! remote_url=$(git --no-pager remote get-url -- "${tag_remote}" 2>"${err_file}"); then
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
        SHIELD_DIR=$(mktemp -d) || {
            echo "Error: could not create a temporary directory, so existing release tags cannot be compared."
            echo "Refusing to publish latest, major, or minor tags from an incomplete history."
            return 1
        }
        shield_dir="${SHIELD_DIR}"
        chmod 700 "${shield_dir}"
        if ! write_auth_shield "${shield_dir}" "${remote_url}"; then
            remove_shield_dir
            refuse_history "the remote URL for '${tag_remote}' cannot be read without exposing embedded credentials, so existing release tags cannot be compared." "${err_file}"
            return 1
        fi
        # Ask git which URL it will actually use. ls-remote is given the
        # stripped URL, not the remote name, so a shorthand alias is not the
        # string insteadOf starts from. If rewriting still leaves userinfo,
        # refuse instead of spawning the transport helper.
        ls_status=0
        probed_url=$(
            shielded_git "${shield_dir}" --no-pager ls-remote --get-url -- "${REMOTE_STRIPPED_URL}" 2>"${err_file}"
        ) || ls_status=$?
        if [[ "${ls_status}" -ne 0 || -z "${probed_url}" ]] || url_has_userinfo "${probed_url}"; then
            remove_shield_dir
            refuse_history "the remote URL for '${tag_remote}' cannot be read without exposing embedded credentials, so existing release tags cannot be compared." "${err_file}"
            return 1
        fi
        ls_status=0
        remote_raw=$(
            shielded_git "${shield_dir}" --no-pager ls-remote --refs --tags -- "${REMOTE_STRIPPED_URL}" 2>"${err_file}"
        ) || ls_status=$?
        remove_shield_dir
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

# Print the final releases in this package's namespace, one vX.Y.Z per line.
# A package owns exactly "<package>/vX.Y.Z". No package owns tags without a
# slash. The old filter built grep and sed patterns from the package, so an
# empty package turned into s#/## and stripped the first slash of any tag, and
# its unanchored version match also kept tags such as wip-v5.0.0. Either could
# outrank this release and take :latest. The prefix is now removed by literal
# string match, so a package name is never read as a pattern.
package_final_versions() {
    local name version
    while IFS= read -r name; do
        if [[ -n "${PACKAGE}" ]]; then
            [[ "${name}" == "${PACKAGE}/"* ]] || continue
            version="${name#"${PACKAGE}/"}"
        else
            [[ "${name}" != */* ]] || continue
            version="${name}"
        fi
        if [[ "${version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            printf '%s\n' "${version}"
        fi
    done
}

echo "Generating tags:"
SHORT_REVISION=$(echo "${CIRCLE_SHA1}" | cut -c 1-8)
echo "  SHORT_REVISION: ${SHORT_REVISION}"
echo "  TAG: ${TAG}"

if [[ -n "${IDENTITY_SOURCE}" ]]; then
    echo "  Processing release as a new tag. ${IDENTITY_SOURCE} contained a supported release tag."
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

        RELEASED_VERSIONS=$(printf '%s\n' "${GIT_TAGS}" "${ADDED_TAG}" | package_final_versions)
        HIGHEST_VERSION=$(printf '%s\n' "${RELEASED_VERSIONS}" | sort -r --version-sort | head -n 1)
        echo "  HIGHEST_VERSION: ${HIGHEST_VERSION}"
        # Match a whole numeric component. An unescaped "." matches any character,
        # so "v1." also matched v11 and "v1.2." also matched v1.23.
        HIGHEST_WITH_SAME_MAJOR=$(printf '%s\n' "${RELEASED_VERSIONS}" | grep -E "^v${MAJOR_VER}\.[0-9]+\.[0-9]+$" | sort -r --version-sort | head -n 1)
        echo "  HIGHEST_WITH_SAME_MAJOR: ${HIGHEST_WITH_SAME_MAJOR}"
        HIGHEST_WITH_SAME_MINOR=$(printf '%s\n' "${RELEASED_VERSIONS}" | grep -E "^v${MAJOR_VER}\.${MINOR_VER}\.[0-9]+$" | sort -r --version-sort | head -n 1)
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
