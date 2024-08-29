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

# Reset the output file, in case the script is ran multiple times.
echo "Truncating ${OUTFILE}..."
truncate -s 0 "${OUTFILE}"
echo "  Done."
echo ""

echo "Generating tags:"
SHORT_REVISION=$(echo "${CIRCLE_SHA1}" | cut -c 1-8)
echo "  SHORT_REVISION: ${SHORT_REVISION}"
TAG="${CIRCLE_TAG#"${PACKAGE}/"}"
echo "  TAG: ${TAG}"

if [[ "$CIRCLE_TAG" =~ v[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)[0-9]+)?$ ]]; then
    echo "  Processing release as a new tag. The CIRCLE_TAG env var contained a valid semantic version."
    echo "${TAG#v}" >> "${OUTFILE}"
    echo "  Added tag to file: ${TAG#v}"

    MAJOR_VER=$(echo "${TAG}" | cut -c 2- | cut -d . -f 1)
    echo "  MAJOR_VER: ${MAJOR_VER}"
    MINOR_VER=$(echo "${TAG}" | cut -c 2- | cut -d . -f 2)
    echo "  MINOR_VER: ${MINOR_VER}"
    if [[ "${TAG}" =~ -(alpha|beta|rc)[0-9]+$ ]]; then
        PRERELEASE_VER=$(echo "${TAG}" | cut -d '-' -f 2 | cut -c 3-)
    fi
    echo "  PRERELEASE_VER: ${PRERELEASE_VER}"

    ADDED_TAG=$TAG
    if [[ -n "$PACKAGE" ]]; then
        ADDED_TAG="${PACKAGE}/${TAG}"
    fi
    echo "  ADDED_TAG: ${ADDED_TAG}"

    HIGHEST_VERSION=$({ git tag; echo "${ADDED_TAG}"; } | grep "^${PACKAGE}" |  sed "s#${PACKAGE}/##" | grep -E -i 'v[0-9]+\.[0-9]+\.[0-9]+$' | sort -r --version-sort | head -n 1)
    echo "  HIGHEST_VERSION: ${HIGHEST_VERSION}"
    HIGHEST_WITH_SAME_MAJOR=$({ git tag; echo "${ADDED_TAG}"; } | grep "^${PACKAGE}" | sed "s#${PACKAGE}/##" | grep -E -i 'v[0-9]+\.[0-9]+\.[0-9]+$' | grep -i "v${MAJOR_VER}." | sort -r --version-sort | head -n 1)
    echo "  HIGHEST_WITH_SAME_MAJOR: ${HIGHEST_WITH_SAME_MAJOR}"
    HIGHEST_WITH_SAME_MINOR=$({ git tag; echo "${ADDED_TAG}"; } | grep "^${PACKAGE}" | sed "s#${PACKAGE}/##" | grep -E -i 'v[0-9]+\.[0-9]+\.[0-9]+$' | grep -i "v${MAJOR_VER}.${MINOR_VER}." | sort -r --version-sort | head -n 1)
    echo "  HIGHEST_WITH_SAME_MINOR: ${HIGHEST_WITH_SAME_MINOR}"

    if [[ -z ${PRERELEASE_VER} ]]; then
        echo "  This is a final release. Generating latest, major, and minor tags..."

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

printf "\nThe following tags were generated:\n"
awk '{print "  :"$1}' "${OUTFILE}"
