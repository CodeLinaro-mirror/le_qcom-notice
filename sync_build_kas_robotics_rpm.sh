#!/bin/bash
set -e

usage() {
    cat <<'EOF'

Usage: ./sync_build_kas_robotics_rpm.sh [OPTIONS]

    Options:
        --help                 Displays this help
        --tag                  Git tag or branch to clone the SDK at
        --arch                 Target architecture: x86 or arm (required)
        --target               Board target (e.g. iq-8275-evk or iq-9075-evk)
        --workdir              Working directory
        --jf-user              JFrog username
        --jf-pass              JFrog password or token
        --jf-url               JFrog Platform URL
        --upload-images        Build, stage and upload flashable images to Artifactory
        --upload-sdk           Build, stage and upload SDK to Artifactory
        --upload-rpm           Stage and upload RPMs to Artifactory

EOF
    exit 1
}

parse_args() {
    UPLOAD_IMAGES=0
    UPLOAD_SDK=0
    UPLOAD_RPM=0
    SDK_REPO="meta-qcom-robotics-sdk"
    SDK_GIT="https://github.com/qualcomm-linux/meta-qcom-robotics-sdk.git"
    SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    while [ $# -gt 0 ]; do
        case "$1" in
            --help)           usage ;;
            --tag)            TAG="$2";          shift 2 ;;
            --arch)           ARCH="$2";         shift 2 ;;
            --target)         TARGET="$2";       shift 2 ;;
            --workdir)        WORKDIR="$2";      shift 2 ;;
            --jf-user)        JF_USER="$2";      shift 2 ;;
            --jf-pass)        JF_PASS="$2";      shift 2 ;;
            --jf-url)         JF_URL="$2";       shift 2 ;;
            --upload-images)  UPLOAD_IMAGES=1;  shift ;;
            --upload-sdk)     UPLOAD_SDK=1;     shift ;;
            --upload-rpm)     UPLOAD_RPM=1;     shift ;;
            --) shift; break ;;
            *) echo "Unknown option: $1"; exit 1 ;;
        esac
    done

    [ -z "$TAG" ]     && { echo "ERROR: --tag is required"; usage; }
    [ -z "$ARCH" ]    && { echo "ERROR: --arch is required (e.g. x86 or arm)"; usage; }
    [ -z "$TARGET" ]  && { echo "ERROR: --target is required"; usage; }
    [ -z "$WORKDIR" ] && WORKDIR="$(pwd)"

    TARGET_DIR="${WORKDIR}/${TARGET}"
    PUBLISH_DIR="${WORKDIR}/release"
    LOGS_DIR="${WORKDIR}/logs"
}

build_proprietary_image() {
    echo ">>> Building proprietary image for ${TARGET}..."
    cd "$TARGET_DIR"
    time kas shell "${SDK_REPO}/ci/${TARGET}.yml:${SDK_REPO}/ci/linux-qcom-6.18.yml:${SDK_REPO}/ci/qcom-robotics-proprietary-image.yml:${SDK_REPO}/ci/qcom-robotics-distro.yml:${SDK_REPO}/ci/performance.yml" \
        -c "bitbake -q -c build qcom-robotics-proprietary-image"
}

build_robotics_image() {
    echo ">>> Building robotics image for ${TARGET}..."
    cd "$TARGET_DIR"
    time kas shell "${SDK_REPO}/ci/${TARGET}.yml:${SDK_REPO}/ci/linux-qcom-6.18.yml:${SDK_REPO}/ci/qcom-robotics-image.yml:${SDK_REPO}/ci/qcom-robotics-distro.yml:${SDK_REPO}/ci/performance.yml" \
        -c "bitbake -q -c build qcom-robotics-image"
}

build_sdk() {
    echo ">>> Generating SDK for ${TARGET}..."
    cd "$TARGET_DIR"
    [[ $ARCH == "arm" ]] && export SDKMACHINE="aarch64"
    time kas shell "${SDK_REPO}/ci/${TARGET}.yml:${SDK_REPO}/ci/linux-qcom-6.18.yml:${SDK_REPO}/ci/qcom-robotics-proprietary-image.yml:${SDK_REPO}/ci/qcom-robotics-distro.yml:${SDK_REPO}/ci/performance.yml" \
        -c "bitbake -q -c generate_qirp_sdk qcom-robotics-proprietary-image && bitbake -q -c populate_sdk_ext qcom-robotics-proprietary-image"
}

generate_notice() {
    echo ">>> Generating notices..."
    cd "$TARGET_DIR"
    cp "${SCRIPT_PATH}/hwe/NO.LOGIN.BINARY.LICENSE.QTI.pdf" .
    cat "${SCRIPT_PATH}/hwe/NOTICE" \
        "${SCRIPT_PATH}/nhlos/NHLOS_NOTICE" \
        "${SCRIPT_PATH}/robotics/ROBOTICS_NOTICE" >> NOTICE
    find ./ -type f \( -iname "Notice" -o -iname "License" -o -iname "Copying" \
        -o -iname "Credits" -o -iname "Patent" -o -iname "copyright" \) \
        | xargs cat >> NOTICE_OSS
    cat NOTICE_OSS >> NOTICE
}

stage_image() {
    echo ">>> [5a] Staging flashable images..."
    local IMG_PUBLISH_DIR="${PUBLISH_DIR}/images"
    mkdir -p "$IMG_PUBLISH_DIR"

    for IMAGE in "qcom-robotics-image" "qcom-robotics-proprietary-image"; do
        local STAGING_DIR="${WORKDIR}/images/${TARGET}"
        local ARCHIVE="${TARGET_DIR}/build/tmp/deploy/images/${TARGET}/${IMAGE}-${TARGET}.rootfs.qcomflash.tar.gz"
        mkdir -p "$STAGING_DIR"

        tar -xzf "$ARCHIVE" --directory "$STAGING_DIR"
        cp "${TARGET_DIR}/NOTICE" "${TARGET_DIR}/NO.LOGIN.BINARY.LICENSE.QTI.pdf" "$STAGING_DIR"
        (cd "${WORKDIR}" && zip -r "${IMG_PUBLISH_DIR}/${TAG}-${IMAGE}.zip" "images/${TARGET}")
        rm -rf "$STAGING_DIR"
    done
}

stage_sdk() {
    echo ">>> [5b] Staging SDK..."
    local SDK_PUBLISH_DIR="${PUBLISH_DIR}/sdk"
    local STAGING_DIR="${WORKDIR}/images/${TARGET}"
    mkdir -p "$SDK_PUBLISH_DIR" "$STAGING_DIR/sdk" "$STAGING_DIR/qirpsdk_artifacts"

    cp "${TARGET_DIR}/NOTICE" "${TARGET_DIR}/NO.LOGIN.BINARY.LICENSE.QTI.pdf" "$STAGING_DIR"
    cp -r "${TARGET_DIR}/build/tmp/deploy/sdk/." "$STAGING_DIR/sdk/"
    cp -r "${TARGET_DIR}/build/tmp/deploy/qirpsdk_artifacts/." "$STAGING_DIR/qirpsdk_artifacts/"

    # eSDK
    (cd "${WORKDIR}" && zip -r "${SDK_PUBLISH_DIR}/${ARCH}-${TAG}-esdk.zip" "images/${TARGET}" \
        -i "images/${TARGET}/sdk/*-toolchain-ext-*.sh" \
        -i "images/${TARGET}/NOTICE" \
        -i "images/${TARGET}/NO.LOGIN.BINARY.LICENSE.QTI.pdf")

    # Standard SDK
    (cd "${WORKDIR}" && zip -r "${SDK_PUBLISH_DIR}/${ARCH}-${TAG}-standardsdk.zip" "images/${TARGET}" \
        -i "images/${TARGET}/sdk/*-toolchain-*.sh" \
        -x "images/${TARGET}/sdk/*-toolchain-ext-*.sh" \
        -i "images/${TARGET}/NOTICE" \
        -i "images/${TARGET}/NO.LOGIN.BINARY.LICENSE.QTI.pdf")

    # QIRP SDK artifacts
    (cd "${WORKDIR}" && zip -r "${SDK_PUBLISH_DIR}/${ARCH}-${TAG}-robotics-sdk-artifacts.zip" \
        "images/${TARGET}/qirpsdk_artifacts" \
        "images/${TARGET}/NOTICE" \
        "images/${TARGET}/NO.LOGIN.BINARY.LICENSE.QTI.pdf")

    rm -rf "$STAGING_DIR"
}

stage_rpm() {
    echo ">>> [5c] Staging RPMs..."
    local RPM_PUBLISH_DIR="${PUBLISH_DIR}/rpm"
    local RPM_LOGS_DIR="${LOGS_DIR}/rpm"
    mkdir -p "$RPM_PUBLISH_DIR" "$RPM_LOGS_DIR"
    bash "${SCRIPT_PATH}/prune_rpms_robotics.sh" \
        --image-dir "${TARGET_DIR}/build/tmp/deploy/images" \
        --repo-dir  "${TARGET_DIR}/build/tmp/deploy/rpm" \
        --outdir    "$RPM_PUBLISH_DIR" \
        --workdir   "$RPM_LOGS_DIR"
}

configure_jf() {
    jf c add clo-art \
        --url="$JF_URL" \
        --user="$JF_USER" \
        --password="$JF_PASS" \
        --basic-auth-only \
        --interactive=false \
        --overwrite
}

upload_image() {
    local SRC="${PUBLISH_DIR}/images/(**)"
    local DST="qli-ci/flashable-binaries/meta-qcom-robotics/qcom-robotics-distro/${TARGET}/{1}"
    jf rt u --detailed-summary --flat=false --include-dirs --recursive "$SRC" "$DST"
}

upload_sdk() {
    local SRC="${PUBLISH_DIR}/sdk/(**)"
    local DST="qli-ci/flashable-binaries/meta-qcom-robotics/qcom-robotics-distro/${TARGET}/{1}"
    jf rt u --detailed-summary --flat=false --include-dirs --recursive "$SRC" "$DST"
}

upload_rpm() {
    local SRC="${PUBLISH_DIR}/rpm/(**)"
    local DST="qli-robotics-yocto-rpm-signed/${TAG}/rpm/{1}"
    jf rt u --detailed-summary --flat=false --include-dirs --recursive "$SRC" "$DST"
}

main() {
  parse_args $@

  [[ "$UPLOAD_IMAGES" == "1" || "$UPLOAD_RPM" == "1" || "$UPLOAD_SDK" == "1" ]] && configure_jf

  set -x

  mkdir -p "$TARGET_DIR" && cd "$TARGET_DIR"

  git clone -b "$TAG" "$SDK_GIT"

  if [[ "$UPLOAD_IMAGES" == "1" || "$UPLOAD_RPM" == "1" ]]; then
      build_robotics_image
      build_proprietary_image
  fi

  if [[ "$UPLOAD_SDK" == "1" ]]; then
      build_sdk
  fi

  [[ "$UPLOAD_IMAGES" == "1" || "$UPLOAD_RPM" == "1" || "$UPLOAD_SDK" == "1" ]] && generate_notice

  if [[ "$UPLOAD_IMAGES" == "1" ]]; then
      stage_image
      upload_image
  fi

  if [[ "$UPLOAD_RPM" == "1" ]]; then
      stage_rpm
      upload_rpm
  fi

  if [[ "$UPLOAD_SDK" == "1" ]]; then
      stage_sdk
      upload_sdk
  fi
}

main "$@"
