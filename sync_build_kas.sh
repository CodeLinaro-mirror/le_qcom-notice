#!/bin/bash
set -euo pipefail
# **************************************************************************
#
# Copyright (c) 2023 Qualcomm Innovation Center, Inc. All rights reserved.
# SPDX-License-Identifier: BSD-3-Clause
#
# **************************************************************************
usage()
{
    cat <<'END_OF_USAGE'
Usage:
  ./sync_build_kas.sh [OPTIONS]

  Options:
    --help
        Displays this help list

    --tag
        branch name (Eg: qli-2.0)

    --machine
        machine (Eg: rb3gen2-core-kit)

    --distro
        distro (Eg: qcom-distro)

    --arch
        runner architecture (Eg: arm)

    --art-url
        artifactory url (Eg: arm)

    --art-user
        artifactory user (Eg: arm)

    --art-pass
        artifactory password (Eg: arm)

    --upload
        enable artifactory uploads
END_OF_USAGE
    exit 1
}

parse_args() {
    UPLOAD=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
           --help)     usage ;;
           --tag)      TAG="$2";      shift 2 ;;
           --arch)     ARCH="$2";     shift 2 ;;
           --machine)  MACHINE="$2";  shift 2 ;;
           --distro)   DISTRO="$2";   shift 2 ;;
           --art-url)  ART_URL="$2";  shift 2 ;;
           --art-user) ART_USER="$2"; shift 2 ;;
           --art-pass) ART_PASS="$2"; shift 2 ;;
           --upload)   UPLOAD=1;      shift   ;;
           *)          echo "Error: unrecognized option $1" >&2; usage ;;
        esac
    done

    if [[ -z "$TAG" || -z "$MACHINE" || -z "$ARCH" || -z "$DISTRO" ]]; then
        echo "Error: --tag, --machine, --arch and --distro are required." >&2
        usage
    fi

    if [[ "$UPLOAD" == 1 && ( -z "$ART_URL" || -z "$ART_USER" || -z "$ART_PASS" ) ]]; then
        echo "Error: --art-url, --art-user and --art-pass are required when --upload is set." >&2
        usage
    fi
}

build_image() {
  local MACHINE="$1"
  local DISTRO="$2"
  time kas build meta-qcom/ci/${MACHINE}.yml:meta-qcom/ci/${DISTRO}.yml:meta-qcom/ci/performance.yml
  time kas shell meta-qcom/ci/${MACHINE}.yml:meta-qcom/ci/${DISTRO}.yml:meta-qcom/ci/performance.yml -c "bitbake package-index"
}

build_sdk() {
  local MACHINE="$1"
  local DISTRO="$2"
  [[ "$ARCH" =~ "arm" ]] && export SDKMACHINE=aarch64
  time kas shell meta-qcom/ci/${MACHINE}.yml:meta-qcom/ci/${DISTRO}.yml:meta-qcom/ci/performance.yml -c "bitbake -c populate_sdk qcom-multimedia-proprietary-image && bitbake -c populate_sdk_ext qcom-multimedia-proprietary-image"
}

build_downloads() {
  local MACHINE="$1"
  local DISTRO="$2"
  time kas build meta-qcom/ci/${MACHINE}.yml:meta-qcom/ci/${DISTRO}.yml:meta-qcom/ci/mirror-tarballs.yml:meta-qcom/ci/performance.yml
}

generate_notice() {
  cp hwe/NO.LOGIN.BINARY.LICENSE.QTI.pdf .
  cat hwe/NOTICE nhlos/NHLOS_NOTICE >> NOTICE
  find ./ -type f \( -iname "Notice" -o -iname "License" -o -iname "Copying" \
    -o -iname "Credits" -o -iname "Patent" -o -iname "copyright" \) \
    | xargs cat >> NOTICE
}

stage_image() {
  local MACHINE="$1"
  local DISTRO="$2"
  local PUBLISH_DIR="/staging/images/${DISTRO}/${MACHINE}"
  mkdir -p $PUBLISH_DIR
  for IMAGE in "qcom-multimedia-image" "qcom-multimedia-proprietary-image"; do
    local STAGING_DIR=$(mktemp -d)
    local ARCHIVE=$(readlink "build/tmp/deploy/images/${MACHINE}/${IMAGE}-${MACHINE}.rootfs.qcomflash.tar.gz")
    cp $ARCHIVE $STAGING_DIR
    tar -xzvf "$ARCHIVE" -C $STAGING_DIR
    cp NOTICE NO.LOGIN.BINARY.LICENSE.QTI.pdf $STAGING_DIR
    zip -r "${PUBLISH_DIR}/${TAG}-${IMAGE}.zip" \
      "${STAGING_DIR}/NOTICE" \
      "${STAGING_DIR}/NO.LOGIN.BINARY.LICENSE.QTI.pdf" \
      "${STAGING_DIR}/${IMAGE}-${MACHINE}"
    rm -rf $STAGING_DIR
  done
}

stage_rpm() {
  local MACHINE="$1"
  local DISTRO="$2"
  prune_rpm.sh \
    --image-dir "build/tmp/deploy/images" \
    --repo-dir "build/tmp/deploy/rpm" \
    --outdir "output" \
    --workdir "$PWD"

  local PUBLISH_DIR="/staging/yocto-rpm-signed/${TAG}/rpm/"
  mkdir -p $PUBLISH_DIR
  cp -r build/tmp/deploy/rpm/${MACHINE} $PUBLISH_DIR
}

stage_sdk() {
  local MACHINE="$1"
  local DISTRO="$2"
  local PUBLISH_DIR="/staging/sdk/"
  mkdir -p $PUBLISH_DIR
  zip -r "${PUBLISH_DIR}/${ARCH}-${TAG}-esdk.zip" \
    "NOTICE" \
    "NO.LOGIN.BINARY.LICENSE.QTI.pdf" \
    "build/tmp/deploy/sdk/"*-toolchain-ext-*.sh
  zip -r "${PUBLISH_DIR}/${ARCH}-${TAG}-standardsdk.zip" \
    "NOTICE" \
    "NO.LOGIN.BINARY.LICENSE.QTI.pdf" \
    "build/tmp/deploy/sdk/"*-toolchain-*.sh \
    -x "build/tmp/deploy/sdk/*-toolchain-ext-*.sh"
}

stage_downloads() {
  local PUBLISH_DIR="/staging/downloads/"
  mkdir -p $PUBLISH_DIR
  cp -r build/downloads $PUBLISH_DIR
}

upload_image() {
  local SRC="/staging/images/(**)"
  local DST="qli-ci/flashable-binaries/meta-qcom/${DISTRO}/${MACHINE}/{1}"
  jf rt u --detailed-summary --flat=false --include-dirs --recursive "$SRC" "$DST"
}

upload_rpm() {
  local SRC="/staging/yocto-rpm-signed/${TAG}/rpm/(**)"
  local DST="qli-yocto-rpm-signed/$TAG/rpm/{1}"
  jf rt u --detailed-summary --flat=false --include-dirs --recursive "$SRC" "$DST"
}

upload_sdk() {
  local SRC="/staging/sdk/(**)"
  local DST="qli-ci/flashable-binaries/meta-qcom/${DISTRO}/${MACHINE}/{1}"
  jf rt u --detailed-summary --flat=false --include-dirs --recursive "$SRC" "$DST"
}

upload_downloads() {
  local SRC="/staging/downloads/(**)"
  local DST="qli-ci/downloads/2.x/{1}"
  jf rt u --detailed-summary --flat=false --include-dirs --recursive "$SRC" "$DST"
}

main() {
  parse_args "$@"

  git clone https://github.com/qualcomm-linux/meta-qcom -b "$TAG"

  build_image "$MACHINE" "$DISTRO"
  generate_notice
  stage_image "$MACHINE" "$DISTRO"
  [[ "$UPLOAD" == "1" ]] && upload_image "$DISTRO" "$MACHINE"

  # rpms are only generated for qcom-distro variant
  if [[ $DISTRO == "qcom-distro" ]]; then
    stage_rpm "$MACHINE" "$DISTRO"
    [[ "$UPLOAD" == "1" ]] && upload_rpm "$DISTRO" "$MACHINE"
  fi

  # sdks needs to be generated for the generic target only
  if [[ $MACHINE = "qcom-armv8a" ]]; then
    build_sdk "$MACHINE" "$DISTRO"
    stage_sdk "$MACHINE" "$DISTRO"
    [[ "$UPLOAD" == "1" ]] && upload_sdk $MACHINE $DISTRO
  fi

  # downloads server needs to be populated only once
  if [[ $MACHINE = "qcom-armv8a" ]] && [[ $DISTRO == "qcom-distro" ]] && [[ $ARCH = "x64" ]]; then
    build_downloads "$MACHINE" qcom-distro-catchall
    stage_downloads
    [[ "$UPLOAD" == "1" ]] && upload_downloads $MACHINE $DISTRO
  fi
}

main "$@"
