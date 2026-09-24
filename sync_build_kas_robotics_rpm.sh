#!/bin/bash
set -ex

echo_usage() {
    cat <<'EOF'

Usage: ./sync_build_kas_robotics_rpm.sh [OPTIONS]

    Options:
        -h, --help             Displays this help
        -t, --target           Board target (e.g. iq-8275-evk or iq-9075-evk)
        -w, --workdir          Working directory
        -u, --jf-user          JFrog username
        -a, --jf-pass          JFrog password or token
        -r, --jf-url           JFrog Platform URL
        -g, --release-tag      Git tag or branch to clone the SDK at
        --upload-images        Stage and upload flashable images to Artifactory
        --upload-sdk           Build, stage and upload SDK to Artifactory
        --upload-rpm           Stage and upload RPMs to Artifactory

EOF
    exit 1
}

LONG_OPTS="help,target:,workdir:,jf-user:,jf-pass:,jf-url:,release-tag:,upload-images,upload-sdk,upload-rpm"
GETOPT_CMD=$(getopt -o ht:w:u:a:r:g: -l "$LONG_OPTS" -n "$(basename "$0")" -- "$@") || {
    echo "error parsing options."
    echo_usage
}
eval set -- "$GETOPT_CMD"

UPLOAD_IMAGES=0
UPLOAD_SDK=0
UPLOAD_RPM=0

while true; do
    case "$1" in
        -h|--help)        echo_usage ;;
        -t|--target)      TARGET="$2";       shift ;;
        -w|--workdir)     WORKDIR="$2";      shift ;;
        -u|--jf-user)     JF_USER="$2";      shift ;;
        -a|--jf-pass)     JF_PASS="$2";      shift ;;
        -r|--jf-url)      JF_URL="$2";       shift ;;
        -g|--release-tag) RELEASE_TAG="$2";  shift ;;
        --upload-images)  UPLOAD_IMAGES=1 ;;
        --upload-sdk)     UPLOAD_SDK=1 ;;
        --upload-rpm)     UPLOAD_RPM=1 ;;
        --) shift; break ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

[ -z "$TARGET" ]      && { echo "ERROR: --target is required"; echo_usage; }
[ -z "$RELEASE_TAG" ] && { echo "ERROR: --release-tag is required"; echo_usage; }
[ -z "$WORKDIR" ]     && WORKDIR="$(pwd)"


export SHELL=/bin/bash
export SDKMACHINE="aarch64"

SDK_REPO="meta-qcom-robotics-sdk"
SDK_GIT="https://github.com/qualcomm-linux/meta-qcom-robotics-sdk.git"

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${WORKDIR}/${TARGET}"
PUBLISH_DIR="${WORKDIR}/release"
LOGS_DIR="${WORKDIR}/logs"

# ─── Build functions ──────────────────────────────────────────────────────────

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
    time kas shell "${SDK_REPO}/ci/${TARGET}.yml:${SDK_REPO}/ci/linux-qcom-6.18.yml:${SDK_REPO}/ci/qcom-robotics-proprietary-image.yml:${SDK_REPO}/ci/qcom-robotics-distro.yml:${SDK_REPO}/ci/performance.yml" \
        -c "bitbake -q -c generate_qirp_sdk qcom-robotics-proprietary-image && bitbake -q -c populate_sdk_ext qcom-robotics-proprietary-image"
}

# ─── Notice function ──────────────────────────────────────────────────────────

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

# ─── Stage functions ──────────────────────────────────────────────────────────

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
        zip -r "${IMG_PUBLISH_DIR}/${RELEASE_TAG}-${IMAGE}.zip" "$STAGING_DIR"

        rm -rf "$STAGING_DIR"
    done
}

stage_sdk() {
    echo ">>> [5b] Staging SDK..."
    local SDK_PUBLISH_DIR="${PUBLISH_DIR}/sdk"
    local STAGING_DIR="${WORKDIR}/images/${TARGET}"
    mkdir -p "$SDK_PUBLISH_DIR" "$STAGING_DIR/sdk"

    cp "${TARGET_DIR}/NOTICE" "${TARGET_DIR}/NO.LOGIN.BINARY.LICENSE.QTI.pdf" "$STAGING_DIR"

    # eSDK
    cp "${TARGET_DIR}/build/tmp/deploy/sdk/"*-toolchain-ext-*.sh "$STAGING_DIR/sdk"
    zip -r "${SDK_PUBLISH_DIR}/${TARGET}-${RELEASE_TAG}-esdk.zip" "$STAGING_DIR"
    rm -f "$STAGING_DIR/sdk/"*-toolchain-ext-*.sh

    # Standard SDK (toolchain-*.sh matches both; remove ext again to isolate standard)
    cp "${TARGET_DIR}/build/tmp/deploy/sdk/"*-toolchain-*.sh "$STAGING_DIR/sdk"
    rm -f "$STAGING_DIR/sdk/"*-toolchain-ext-*.sh
    zip -r "${SDK_PUBLISH_DIR}/${TARGET}-${RELEASE_TAG}-standardsdk.zip" "$STAGING_DIR"

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

# ─── Upload functions ─────────────────────────────────────────────────────────

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
    local DST="qli-ci/flashable-binaries/meta-qcom-robotics-sdk/${TARGET}/{1}"
    jf rt u --detailed-summary --flat=false --include-dirs --recursive "$SRC" "$DST"
}

upload_sdk() {
    local SRC="${PUBLISH_DIR}/sdk/(**)"
    local DST="qli-ci/flashable-binaries/meta-qcom-robotics-sdk/${TARGET}/{1}"
    jf rt u --detailed-summary --flat=false --include-dirs --recursive "$SRC" "$DST"
}

upload_rpm() {
    local SRC="${PUBLISH_DIR}/rpm/(**)"
    local DST="qli-yocto-rpm-signed/${RELEASE_TAG}/rpm/{1}"
    jf rt u --detailed-summary --flat=false --include-dirs --recursive "$SRC" "$DST"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

# Cleanup stale artifacts from previous runs
rm -rf "${PUBLISH_DIR}" "${LOGS_DIR}" "${WORKDIR}/images"

# 1. Sync — clone SDK into target dir
echo ">>> [1] Syncing SDK into ${TARGET_DIR}..."
mkdir -p "$TARGET_DIR"
cd "$TARGET_DIR" && git clone -b "$RELEASE_TAG" "$SDK_GIT"

# 2. Build proprietary image (flashable image + RPMs)
build_proprietary_image
sleep 3

# 3. Build non-proprietary robotics image (flashable image + RPMs)
build_robotics_image
sleep 3

# 4. Generate SDK (only if SDK upload is requested)
if [[ "$UPLOAD_SDK" == "1" ]]; then
    build_sdk
fi

# 5. Aggregate notices
generate_notice

# 6. Configure JFrog if any upload is requested
if [[ "$UPLOAD_IMAGES" == "1" || "$UPLOAD_SDK" == "1" || "$UPLOAD_RPM" == "1" ]]; then
    configure_jf
fi

# 7. Stage and upload flashable images
if [[ "$UPLOAD_IMAGES" == "1" ]]; then
    stage_image
    upload_image
fi

# 8. Stage and upload SDK
if [[ "$UPLOAD_SDK" == "1" ]]; then
    stage_sdk
    upload_sdk
fi

# 9. Stage and upload RPMs
if [[ "$UPLOAD_RPM" == "1" ]]; then
    stage_rpm
    upload_rpm
fi

tree -L 3 "${PUBLISH_DIR}" || true
