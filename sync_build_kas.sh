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
        machine one or more space-separated values (Eg: rb3gen2-core-kit, iq-9075-evk)

    --distro
        distro, one or more space-separated values (Eg: qcom-distro qcom-distro-sota)

    --arch
        runner architecture (Eg: arm)

    --art-url
        artifactory url (Eg: )

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
    MACHINES=()
    DISTROS=()
    SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    while [[ $# -gt 0 ]]; do
        case "$1" in
           --help)     usage ;;
           --tag)      TAG="$2";      shift 2 ;;
           --arch)     ARCH="$2";     shift 2 ;;
           --machine)
               shift
               while [[ $# -gt 0 && "$1" != --* ]]; do
                   MACHINES+=("$1")
                   shift
               done
               ;;
           --distro)
               shift
               while [[ $# -gt 0 && "$1" != --* ]]; do
                   DISTROS+=("$1")
                   shift
               done
               ;;
           --art-url)  ART_URL="$2";  shift 2 ;;
           --art-user) ART_USER="$2"; shift 2 ;;
           --art-pass) ART_PASS="$2"; shift 2 ;;
           --upload)   UPLOAD=1;      shift   ;;
           *)          echo "Error: unrecognized option $1" >&2; usage ;;
        esac
    done

    if [[ -z "$TAG" || "${#MACHINES[@]}" -eq 0 || -z "$ARCH" || "${#DISTROS[@]}" -eq 0 ]]; then
        echo "Error: --tag, --machine, --arch and --distro are required." >&2
        usage
    fi

    if [[ "$UPLOAD" == 1 && ( -z "$ART_URL" || -z "$ART_USER" || -z "$ART_PASS" ) ]]; then
        echo "Error: --art-url, --art-user and --art-pass are required when --upload is set." >&2
        usage
    fi
}

configure_jf() {
  jf c add clo-art \
    --url="$ART_URL" \
    --user="$ART_USER" \
    --password="$ART_PASS" \
    --basic-auth-only \
    --interactive=false \
    --overwrite
}

build_image() {
  local MACHINE="$1"
  local DISTRO="$2"
  time kas build meta-qcom/ci/$MACHINE.yml:meta-qcom/ci/$DISTRO.yml:meta-qcom/ci/performance.yml
  time kas shell meta-qcom/ci/$MACHINE.yml:meta-qcom/ci/$DISTRO.yml:meta-qcom/ci/performance.yml -c "bitbake package-index"
}

build_sdk() {
  local MACHINE="$1"
  local DISTRO="$2"
  local ARCH="$3"
  [[ "$ARCH" == "arm" ]] && export SDKMACHINE=aarch64
  time kas shell meta-qcom/ci/$MACHINE.yml:meta-qcom/ci/$DISTRO.yml:meta-qcom/ci/performance.yml -c "bitbake -c populate_sdk qcom-multimedia-proprietary-image && bitbake -c populate_sdk_ext qcom-multimedia-proprietary-image"
}

build_downloads() {
  local MACHINE="$1"
  local DISTRO="$2"
  time kas build meta-qcom/ci/$MACHINE.yml:meta-qcom/ci/$DISTRO.yml:meta-qcom/ci/mirror-tarballs.yml:meta-qcom/ci/performance.yml
}

generate_notice() {
  cp $SCRIPT_PATH/hwe/NO.LOGIN.BINARY.LICENSE.QTI.pdf .
  cat $SCRIPT_PATH/hwe/NOTICE $SCRIPT_PATH/nhlos/NHLOS_NOTICE >> NOTICE
  find ./ -type f \( -iname "Notice" -o -iname "License" -o -iname "Copying" \
    -o -iname "Credits" -o -iname "Patent" -o -iname "copyright" \) \
    | xargs cat >> NOTICE_OSS
  cat NOTICE_OSS >> NOTICE
}

stage_image() {
  local MACHINE="$1"
  local DISTRO="$2"
  local PUBLISH_DIR="release/images"
  mkdir -p "$PUBLISH_DIR"

  for IMAGE in "qcom-multimedia-image" "qcom-multimedia-proprietary-image"; do
    local STAGING_DIR="images/$MACHINE"
    local ARCHIVE="build/tmp/deploy/images/$MACHINE/$IMAGE-$MACHINE.rootfs.qcomflash.tar.gz"
    mkdir -p "$STAGING_DIR"

    tar -xzf "$ARCHIVE" --directory "$STAGING_DIR"
    cp NOTICE NO.LOGIN.BINARY.LICENSE.QTI.pdf "$STAGING_DIR"
    zip -r "$PUBLISH_DIR/$TAG-$IMAGE.zip" "$STAGING_DIR"

    rm -rf "$STAGING_DIR"
  done
}

stage_rpm() {
  local MACHINE="$1"
  local DISTRO="$2"
  local PUBLISH_DIR="release/rpm"
  local LOGS_DIR="logs/rpm"
  $SCRIPT_PATH/prune_rpm.sh \
    --image-dir "build/tmp/deploy/images" \
    --repo-dir "build/tmp/deploy/rpm" \
    --outdir "$PUBLISH_DIR" \
    --workdir "$LOGS_DIR"
}

stage_sdk() {
  local MACHINE="$1"
  local DISTRO="$2"
  local PUBLISH_DIR="release/sdk"
  local STAGING_DIR="images/$MACHINE"
  mkdir -p "$PUBLISH_DIR" "$STAGING_DIR/sdk"

  cp NOTICE NO.LOGIN.BINARY.LICENSE.QTI.pdf "$STAGING_DIR"

  cp build/tmp/deploy/sdk/*-toolchain-ext-*.sh "$STAGING_DIR/sdk"
  zip -r "$PUBLISH_DIR/$ARCH-$TAG-esdk.zip" "$STAGING_DIR"
  rm -f "$STAGING_DIR/sdk"/*-toolchain-ext-*.sh

  cp build/tmp/deploy/sdk/*-toolchain-*.sh "$STAGING_DIR/sdk"
  rm -f "$STAGING_DIR/sdk"/*-toolchain-ext-*.sh
  zip -r "$PUBLISH_DIR/$ARCH-$TAG-standardsdk.zip" "$STAGING_DIR"

  rm -rf "$STAGING_DIR"
}

stage_downloads() {
  local PUBLISH_DIR="release/downloads/"
  mkdir -p $PUBLISH_DIR
  cp -r build/downloads $PUBLISH_DIR
}

upload_image() {
  local SRC="release/images/(**)"
  local DST="qli-ci/flashable-binaries/meta-qcom/$DISTRO/$MACHINE/{1}"
  jf rt u --detailed-summary --flat=false --include-dirs --recursive "$SRC" "$DST"
}

upload_rpm() {
  local SRC="release/rpm/(**)"
  local DST="qli-yocto-rpm-signed/$TAG/rpm/{1}"
  jf rt u --detailed-summary --flat=false --include-dirs --recursive "$SRC" "$DST"
}

upload_sdk() {
  local SRC="release/sdk/(**)"
  local DST="qli-ci/flashable-binaries/meta-qcom/$DISTRO/$MACHINE/{1}"
  jf rt u --detailed-summary --flat=false --include-dirs --recursive "$SRC" "$DST"
}

upload_downloads() {
  local SRC="release/downloads/(**)"
  local DST="qli-ci/downloads/2.x/{1}"
  jf rt u --detailed-summary --flat=false --include-dirs --recursive "$SRC" "$DST"
}

cleanup() {
  rm -rf release logs images build/tmp
  rm -rf NOTICE NOTICE_OSS NO.LOGIN.BINARY.LICENSE.QTI.pdf
}

build_task() {
  cleanup

  build_image "$MACHINE" "$DISTRO"
  generate_notice

  # prebuilt images are identical for x86 and ARM architectures, only upload once
  if [[ $ARCH == "x86" ]]; then
    stage_image "$MACHINE" "$DISTRO"
    [[ "$UPLOAD" == "1" ]] && upload_image "$DISTRO" "$MACHINE"
  fi

  # rpms are only generated for qcom-distro variant
  if [[ $DISTRO == "qcom-distro" ]] && [[ $ARCH == "x86" ]]; then
    stage_rpm "$MACHINE" "$DISTRO"
    [[ "$UPLOAD" == "1" ]] && upload_rpm "$MACHINE" "$DISTRO"
  fi

  # sdks needs to be generated for the generic target only
  if [[ $MACHINE == "qcom-armv8a" ]]; then
    build_sdk "$MACHINE" "$DISTRO" "$ARCH"
    stage_sdk "$MACHINE" "$DISTRO"
    [[ "$UPLOAD" == "1" ]] && upload_sdk $MACHINE $DISTRO
  fi

  # downloads server needs to be populated only once
  if [[ $MACHINE == "qcom-armv8a" ]] && [[ $DISTRO == "qcom-distro" ]] && [[ $ARCH == "x86" ]]; then
    build_downloads "$MACHINE" qcom-distro-catchall
    stage_downloads
    [[ "$UPLOAD" == "1" ]] && upload_downloads $MACHINE $DISTRO
  fi
}

main() {
  parse_args "$@"
  [[ "$UPLOAD" == 1 ]] && configure_jf

  git clone https://github.com/qualcomm-linux/meta-qcom -b "$TAG"

  for MACHINE in "${MACHINES[@]}"; do
    for DISTRO in "${DISTROS[@]}"; do
      build_task $MACHINE $DISTRO
    done
  done
}

main "$@"
