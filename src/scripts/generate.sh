#!/bin/bash

AVAILABLE_ARCHITECTURES="amd64 arm64"

# Determine branch. On tag builds, CIRCLE_BRANCH is not set, so we infer
# the branch by looking at the actual tag
if [ -n "${CIRCLE_TAG}" ]; then
    REAL_BRANCH="$(echo ${CIRCLE_TAG} | cut -d "/" -f2)"
else
    REAL_BRANCH="${CIRCLE_BRANCH}"
fi

# Is this an official build?
if [ "${CIRCLE_PROJECT_USERNAME}" == "FuriLabs" ]; then
    OFFICIAL_BUILD="yes"
fi

# Flatpak or Debian?
if [ -n "${CIRCLE_PROJECT_FLATPAK_MANIFEST_PATH}" ]; then
    MANIFEST_FILE="${CIRCLE_PROJECT_FLATPAK_MANIFEST_PATH}"

    if [[ "${MANIFEST_FILE}" == *.json ]]; then
        APP_ID="$(jq -r '.id' "${MANIFEST_FILE}")"
    else
        APP_ID="$(grep -m1 '^id:' "${MANIFEST_FILE}" | awk '{print $2}' | tr -d '"')"
    fi

    SUITE="$(echo ${REAL_BRANCH} | cut -d/ -f2)"

    cat > generated_config.yml <<EOF
version: 2.1

commands:
  flatpak-build:
    parameters:
      manifest:
        type: string
      architecture:
        type: string
        default: "amd64"
      suite:
        type: string
        default: "${SUITE}"
    steps:
      - run:
          name: <<parameters.architecture>> flatpak build
          no_output_timeout: 30m
          command: |
            mkdir -p /tmp/flatpak-results ; \\
            docker run \\
              --rm \\
              -e FLATPAK_MANIFEST="<<parameters.manifest>>" \\
              -e ARCH="<<parameters.architecture>>" \\
              -e FLATPAK_SUITE="<<parameters.suite>>" \\
              -e CI \\
              -e CIRCLECI \\
              -e CIRCLE_BRANCH="${REAL_BRANCH}" \\
              -e CIRCLE_SHA1 \\
              -e CIRCLE_TAG \\
              -e CIRCLE_PROJECT_USERNAME \\
              -e CIRCLE_PROJECT_REPONAME \\
              -v /tmp/flatpak-results:/tmp/flatpak-results \\
              -v "${PWD}":/buildd/sources \\
              -w /buildd/sources \\
              quay.io/furilabs/flatpak-builder:<<parameters.suite>> \\
              /bin/sh -c "releng-build-flatpak"

  flatpak-deploy:
    parameters:
      architecture:
        type: string
        default: "amd64"
      suite:
        type: string
        default: "${SUITE}"
      app_id:
        type: string
    steps:
      - run:
          name: <<parameters.architecture>> flatpak deploy
          no_output_timeout: 10m
          command: |
            docker run \\
              --rm \\
              -e FLATPAK_APP_ID="<<parameters.app_id>>" \\
              -e ARCH="<<parameters.architecture>>" \\
              -e FLATPAK_SUITE="<<parameters.suite>>" \\
              -e FLATPAK_REPO_DIR="/tmp/flatpak-results/repo" \\
              -e FLATPAK_GPG_KEY_ID="${GPG_STAGINGPRODUCTION_SIGNING_KEYID:-}" \\
              -e FLATPAK_REMOTE_TARGET="flatpak.furilabs.io:/repo/<<parameters.suite>>" \\
              -e CIRCLE_PROJECT_USERNAME \\
              -e CIRCLE_PROJECT_REPONAME \\
              -v /tmp/flatpak-results:/tmp/flatpak-results \\
              quay.io/furilabs/flatpak-builder:<<parameters.suite>> \\
              /bin/sh -c "releng-deploy-flatpak"

  deploy-offline:
    steps:
      - store_artifacts:
          path: /tmp/flatpak-results

jobs:
EOF

    enabled_architectures=""
    for arch in ${AVAILABLE_ARCHITECTURES}; do
        resource_class="large"
        if [ "${arch}" == "arm64" ]; then
            resource_class="arm.large"
        fi

        cat >> generated_config.yml <<EOF
  build-${arch}:
    machine:
      image: ubuntu-2004:current
      resource_class: ${resource_class}
    steps:
      - flatpak-build:
          manifest: "${MANIFEST_FILE}"
          architecture: "${arch}"
          suite: "${SUITE}"
EOF

        if [ "${OFFICIAL_BUILD}" == "yes" ]; then
            cat >> generated_config.yml <<EOF
      - flatpak-deploy:
          architecture: "${arch}"
          suite: "${SUITE}"
          app_id: "${APP_ID}"

EOF
        else
            cat >> generated_config.yml <<EOF
      - deploy-offline

EOF
        fi

        enabled_architectures="${enabled_architectures} ${arch}"
    done

    cat >> generated_config.yml <<EOF
workflows:
  build:
    jobs:
EOF

    for arch in ${enabled_architectures}; do
        cat >> generated_config.yml <<EOF
      - build-${arch}:
          filters:
            tags:
              only: /^furios\/.*\/.*/
          context:
            - furilabs-buildd
EOF
    done

    sed -i 's|_escapeme_<|\\<|g' generated_config.yml
    exit 0
fi

cat > generated_config.yml <<EOF
version: 2.1

commands:
  debian-build:
    parameters:
      suite:
        type: string
        default: "forky"
      architecture:
        type: string
        default: "arm64"
      full_build:
        type: string # yes or no
        default: "yes"
      extra_repos:
        type: string
        default: ""
      extra_packages:
        type: string
        default: ""
      force_staging:
        type: string
        default: ""
      host_arch:
        type: string
        default: ""
    steps:
      - run:
          name: <<parameters.architecture>> build
          no_output_timeout: 20m
          command: |
            mkdir -p /tmp/buildd-results ; \\
            git clone --recurse-submodules -b "${REAL_BRANCH}" "${CIRCLE_REPOSITORY_URL//git@github.com:/https:\/\/github.com\/}" sources ; \\
            if [ -n "${CIRCLE_TAG}" ]; then \\
              cd sources ; \\
              git fetch --tags ; \\
              git checkout "${CIRCLE_TAG}" ; \\
              git submodule update --init --recursive ; \\
              cd .. ; \\
            fi ; \\
            docker run \\
              --rm \\
              -e CI \\
              -e CIRCLECI \\
              -e CIRCLE_BRANCH="${REAL_BRANCH}" \\
              -e CIRCLE_SHA1 \\
              -e CIRCLE_TAG \\
              -e EXTRA_REPOS="<<parameters.extra_repos>>" \\
              -e EXTRA_PACKAGES="<<parameters.extra_packages>>" \\
              -e FORCE_STAGING="<<parameters.force_staging>>" \\
              -e RELENG_FULL_BUILD="<<parameters.full_build>>" \\
              -e RELENG_HOST_ARCH="<<parameters.host_arch>>" \\
              -v /tmp/buildd-results:/buildd \\
              -v ${PWD}/sources:/buildd/sources \\
              --cap-add=SYS_ADMIN \\
              --security-opt apparmor:unconfined \\
              --security-opt seccomp=unconfined \\
              quay.io/furilabs/build-essential:<<parameters.suite>>-<<parameters.architecture>> \\
              /bin/sh -c "cd /buildd/sources ; releng-build-package"

  deploy-offline:
    steps:
      - store_artifacts:
          path: /tmp/buildd-results

  deploy:
    parameters:
      suite:
        type: string
        default: "bookworm"
      architecture:
        type: string
        default: "arm64"
    steps:
      - run:
          name: <<parameters.architecture>> deploy
          command: |
            docker run \\
              --rm \\
              -e CI \\
              -e CIRCLECI \\
              -e CIRCLE_BRANCH="${REAL_BRANCH}" \\
              -e CIRCLE_SHA1 \\
              -e CIRCLE_PROJECT_USERNAME \\
              -e CIRCLE_PROJECT_REPONAME \\
              -e CIRCLE_TAG \\
              -e GPG_STAGINGPRODUCTION_SIGNING_KEY \\
              -e GPG_STAGINGPRODUCTION_SIGNING_KEYID \\
              -e INTAKE_SSH_USER \\
              -e INTAKE_SSH_KEY \\
              -v /tmp/buildd-results:/tmp/buildd-results \\
              quay.io/furilabs/build-essential:<<parameters.suite>>-<<parameters.architecture>> \\
              /bin/sh -c "cd /tmp/buildd-results ; repo-furios-sign.sh ; repo-furios-deploy.sh"

jobs:
EOF

# Get source package name
SOURCE_NAME="$(grep 'Source:' debian/control | cut -d ' ' -f2-)"

# Determine which architectures to build
ARCHITECTURES="$(grep 'Architecture:' debian/control | cut -d ' ' -f2- | sed -s 's| |\n|g' | sort -u | grep -v all)" || true
if echo "${ARCHITECTURES}" | grep -q "any"; then
    ARCHITECTURES="${AVAILABLE_ARCHITECTURES}"
elif [ -z "${ARCHITECTURES}" ]; then
    # Default to amd64
    ARCHITECTURES="amd64"
fi

# Host arch specified?
HOST_ARCH="$(grep 'XS-FuriOS-Host-Arch:' debian/control | head -n 1 | awk '{ print $2 }')" || true
BUILD_ON="$(grep 'XS-FuriOS-Build-On:' debian/control | head -n 1 | awk '{ print $2 }')" || true
if [ -n "${HOST_ARCH}" ] && [ -n "${BUILD_ON}" ]; then
    ARCHITECTURES="${BUILD_ON}"
elif [ -n "${HOST_ARCH}" ]; then
    echo "Both XS-FuriOS-Host-Arch and XS-FuriOS-Build-On must be specified to allow crossbuilds" >&2
    exit 1
fi

# Retrieve EXTRA_REPOS
EXTRA_REPOS="$(grep 'XS-FuriOS-Extra-Repos:' debian/control | cut -d ' ' -f2-)" || true

SUITE="$(echo ${REAL_BRANCH} | cut -d/ -f2)"

# Extra packages to install (such as apt config)?
EXTRA_PACKAGES="$(grep 'XS-FuriOS-Extra-Packages:' debian/control | cut -d ' ' -f2-)" || true

# Should package be forced to build against staging even if tagged or feature?
FORCE_STAGING="$(grep 'XS-FuriOS-Force-Staging:' debian/control | cut -d ' ' -f2-)" || true

full_build="yes"
enabled_architectures=""
for arch in ${ARCHITECTURES}; do
    if ! echo "${AVAILABLE_ARCHITECTURES}" | grep -q ${arch}; then
        continue
    else
        enabled_architectures="${enabled_architectures} ${arch}"
    fi

    if [ "${arch}" == "amd64" ]; then
        resource_class="large"
    else
        resource_class="arm.large"
    fi

    prepare=""

    cat >> generated_config.yml <<EOF
  build-${arch}:
    machine:
      image: ubuntu-2004:current
      resource_class: ${resource_class}
    steps:
      ${prepare}
      - debian-build:
          suite: "${SUITE}"
          architecture: "${arch}"
          full_build: "${full_build}"
          host_arch: "${HOST_ARCH}"
          extra_repos: "${EXTRA_REPOS}"
          extra_packages: "${EXTRA_PACKAGES}"
          force_staging: "${FORCE_STAGING}"
EOF

    if [ "${OFFICIAL_BUILD}" == "yes" ]; then
        cat >> generated_config.yml <<EOF
      - deploy:
          suite: "${SUITE}"
          architecture: "${arch}"

EOF
    else
        cat >> generated_config.yml <<EOF
      - deploy-offline

EOF
    fi

    full_build="no"
done

cat >> generated_config.yml <<EOF
workflows:
  build:
    jobs:
EOF

for arch in ${enabled_architectures}; do
    cat >> generated_config.yml <<EOF
      - build-${arch}:
          filters:
            tags:
              only: /^furios\/.*\/.*/
          context:
            - furilabs-buildd
EOF
done

# Workaround for circleci import() misbehaviour
sed -i 's|_escapeme_<|\\<|g' generated_config.yml
