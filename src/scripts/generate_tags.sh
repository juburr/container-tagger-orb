#!/bin/bash

set -e

OUTFILE=$(circleci env subst "${PARAM_OUTFILE}")
PACKAGE=$(circleci env subst "${PARAM_PACKAGE}")

echo "Generating tags for container image..."
echo "  CIRCLE_BRANCH: ${CIRCLE_BRANCH}"
echo "  CIRCLE_BUILD_NUM: ${CIRCLE_BUILD_NUM}"
echo "  CIRCLE_SHA1: ${CIRCLE_SHA1}"
echo "  CIRCLE_TAG: ${CIRCLE_TAG}"
echo "  OUTFILE: ${OUTFILE}"
echo "  PACKAGE: ${PACKAGE}"
echo "  PARAM_TAG_ENV_VAR: ${PARAM_TAG_ENV_VAR}"

# Reset the output file, in case the script is ran multiple times.
truncate -s 0 "${OUTFILE}"

MOST_SPECIFIC_TAG=""
SHORT_REVISION=${CIRCLE_SHA1:0:8}

if [[ "$CIRCLE_TAG" =~ v[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)[0-9]+)?$ ]]; then
    TAG="${CIRCLE_TAG#"${PACKAGE}/"}"
    MOST_SPECIFIC_TAG="${TAG#v}"
    echo "${TAG#v}" >> "${OUTFILE}"

    MAJOR_VER=$(echo "${TAG}" | cut -c 2- | cut -d . -f 1)
    MINOR_VER=$(echo "${TAG}" | cut -c 2- | cut -d . -f 2)
    if [[ "${TAG}" =~ -(alpha|beta|rc)[0-9]+$ ]]; then
        PRERELEASE_VER=$(echo "${TAG}" | cut -d '-' -f 2 | cut -c 3-)
    fi

    ADDED_TAG=$TAG
    if [[ -n "$PACKAGE" ]]; then
        ADDED_TAG="${PACKAGE}/${TAG}"
    fi

    HIGHEST_VERSION=$({ git tag; echo "${ADDED_TAG}"; } | grep "^${PACKAGE}" |  sed "s#${PACKAGE}/##" | grep -E -i 'v[0-9]+\.[0-9]+\.[0-9]+$' | sort -r --version-sort | head -n 1)
    HIGHEST_WITH_SAME_MAJOR=$({ git tag; echo "${ADDED_TAG}"; } | grep "^${PACKAGE}" | sed "s#${PACKAGE}/##" | grep -E -i 'v[0-9]+\.[0-9]+\.[0-9]+$' | grep -i "v${MAJOR_VER}." | sort -r --version-sort | head -n 1)
    HIGHEST_WITH_SAME_MINOR=$({ git tag; echo "${ADDED_TAG}"; } | grep "^${PACKAGE}" | sed "s#${PACKAGE}/##" | grep -E -i 'v[0-9]+\.[0-9]+\.[0-9]+$' | grep -i "v${MAJOR_VER}.${MINOR_VER}." | sort -r --version-sort | head -n 1)

    if [[ -z ${PRERELEASE_VER} ]]; then
        if [[ ${TAG} == "${HIGHEST_WITH_SAME_MINOR}" ]] ; then
	        echo "${MAJOR_VER}.${MINOR_VER}" >> "${OUTFILE}"
        fi

        if [[ ${TAG} == "${HIGHEST_WITH_SAME_MAJOR}" ]] ; then
	        echo "${MAJOR_VER}" >> "${OUTFILE}"
        fi

        if [[ ${TAG} == "${HIGHEST_VERSION}" ]] ; then
	        echo "latest" >> "${OUTFILE}"
        fi
    fi
elif [ "$CIRCLE_BRANCH" = develop ] || [ "$CIRCLE_BRANCH" = main ] || [ "$CIRCLE_BRANCH" = master ]; then
    echo "edge" >> "${OUTFILE}"
    echo "${CIRCLE_BRANCH}-${SHORT_REVISION}" >> "${OUTFILE}"
    MOST_SPECIFIC_TAG="${CIRCLE_BRANCH}-${SHORT_REVISION}"
else
    echo "dev-${SHORT_REVISION}" >> "${OUTFILE}"
    MOST_SPECIFIC_TAG="dev-${SHORT_REVISION}"
fi

# Add the most specific tag to the job's environment. It's often useful
# to have quick access to just one of the tags. For example, when signing
# an image that has multiple tags, all of the tags will have the exact same
# sha256 sum, so you only need to perform the operation on one of the tags.
if [[ -n "$PARAM_TAG_ENV_VAR" ]]; then
    echo "${PARAM_TAG_ENV_VAR}=${MOST_SPECIFIC_TAG}" >> "${BASH_ENV}"
fi

printf "\nThe following tags were generated:\n"
awk '{print "   :"$1}' "${OUTFILE}"