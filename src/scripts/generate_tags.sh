#!/bin/bash

set -e

# Read command arguments
OUTFILE=$(circleci env subst "${PARAM_OUTFILE}")
PACKAGE=$(circleci env subst "${PARAM_PACKAGE}")

# Print arguments for debugging purposes
echo "Generating tags for container image..."
echo "  CIRCLE_BRANCH: ${CIRCLE_BRANCH}"
echo "  CIRCLE_BUILD_NUM: ${CIRCLE_BUILD_NUM}"
echo "  CIRCLE_SHA1: ${CIRCLE_SHA1}"
echo "  CIRCLE_TAG: ${CIRCLE_TAG}"
echo "  OUTFILE: ${OUTFILE}"
echo "  PACKAGE: ${PACKAGE}"

# Reset the output file, in case the script is ran multiple times.
truncate -s 0 "${OUTFILE}"

SHORT_REVISION=${CIRCLE_SHA1:0:8}

if [[ "$CIRCLE_TAG" =~ v[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)[0-9]+)?$ ]]; then
    TAG="${CIRCLE_TAG#"${PACKAGE}/"}"
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
else
    echo "dev-${SHORT_REVISION}" >> "${OUTFILE}"
fi

printf "\nThe following tags were generated:\n"
awk '{print "   :"$1}' "${OUTFILE}"
