#!/bin/bash

set -ex

DIR=`realpath $(dirname "${0}")`

BUILD_DIRECTORY="${SNAPCRAFT_PART_BUILD:-${DIR}/.build}"
INSTALL_DIRECTORY="${SNAPCRAFT_PART_INSTALL:-${DIR}/.install}"

mkdir -p "${BUILD_DIRECTORY}" "${INSTALL_DIRECTORY}"

COMPONENT_NAME="${1}"
COMPONENT_DIRECTORY="${DIR}/components/${COMPONENT_NAME}"

GIT_REPOSITORY="$(cat "${COMPONENT_DIRECTORY}/repository")"
GIT_TAG="$(cat "${COMPONENT_DIRECTORY}/version")"

COMPONENT_BUILD_DIRECTORY="${BUILD_DIRECTORY}/${COMPONENT_NAME}"

# cleanup git repository if we cannot git checkout to the build tag
if [ -d "${COMPONENT_BUILD_DIRECTORY}" ]; then
  cd "${COMPONENT_BUILD_DIRECTORY}"
  if ! git reset --hard "${GIT_TAG}"; then
    cd "${BUILD_DIRECTORY}"
    rm -rf "${COMPONENT_BUILD_DIRECTORY}"
  fi
fi

if [ ! -d "${COMPONENT_BUILD_DIRECTORY}" ]; then
  if [[ "${GIT_TAG}" =~ ^[0-9a-f]{40}$ ]]; then
    # Pinned to a full commit SHA (e.g. k8sd, which tracks no tag): clone -b
    # cannot take a SHA, so fetch it directly. Requires the remote to allow
    # reachable SHA fetches (GitHub does).
    mkdir -p "${COMPONENT_BUILD_DIRECTORY}"
    (
      cd "${COMPONENT_BUILD_DIRECTORY}"
      git init -q
      git remote add origin "${GIT_REPOSITORY}"
      git fetch -q --depth 1 origin "${GIT_TAG}"
      git checkout -q FETCH_HEAD
    )
  else
    git clone "${GIT_REPOSITORY}" --depth 1 -b "${GIT_TAG}" "${COMPONENT_BUILD_DIRECTORY}"
  fi
fi

cd "${COMPONENT_BUILD_DIRECTORY}"
echo "Building ${COMPONENT_NAME} at commit $(git rev-parse HEAD)"
git config user.name "K8s builder bot"
git config user.email "k8s-bot@canonical.com"

if [ -e "${COMPONENT_DIRECTORY}/pre-patch.sh" ]; then
  bash -xe "${COMPONENT_DIRECTORY}/pre-patch.sh"
fi

for patch in $(python3 "${DIR}/print-patches-for.py" "${COMPONENT_NAME}" "${GIT_TAG}"); do
  git am "${patch}"
done

bash -xe "${COMPONENT_DIRECTORY}/build.sh" "${INSTALL_DIRECTORY}" "${GIT_TAG}"
