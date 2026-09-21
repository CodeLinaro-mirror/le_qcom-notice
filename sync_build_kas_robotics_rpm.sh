#!/bin/bash
set -ex

echo_usage() {
    cat <<'EOF'

Usage: ./sync_build_kas_robotics_rpm.sh [OPTIONS]

    Options:
        -h, --help         Displays this help
        -t, --target       Board target (e.g. iq-8275-evk or iq-9075-evk)
        -w, --workdir      Working directory
        -u, --jf-user      JFrog username
        -a, --jf-pass      JFrog password or token
        -r, --jf-url       JFrog Platform URL
        -g, --release-tag  Git tag or branch to clone the SDK at

EOF
    exit 1
}

LONG_OPTS="help,target:,workdir:,jf-user:,jf-pass:,jf-url:,release-tag:"
GETOPT_CMD=$(getopt -o ht:w:u:a:r:g: -l "$LONG_OPTS" -n "$(basename "$0")" -- "$@") || {
    echo "error parsing options."
    echo_usage
}
eval set -- "$GETOPT_CMD"

while true; do
    case "$1" in
        -h|--help)        echo_usage ;;
        -t|--target)      TARGET="$2";       shift ;;
        -w|--workdir)     WORKDIR="$2";      shift ;;
        -u|--jf-user)     JF_USER="$2";      shift ;;
        -a|--jf-pass)     JF_PASS="$2";      shift ;;
        -r|--jf-url)      JF_URL="$2";       shift ;;
        -g|--release-tag) RELEASE_TAG="$2";  shift ;;
        --) shift; break ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

[ -z "$TARGET" ]      && { echo "ERROR: --target is required"; echo_usage; }
[ -z "$RELEASE_TAG" ] && { echo "ERROR: --release-tag is required"; echo_usage; }
[ -z "$WORKDIR" ]     && WORKDIR="$(pwd)"

SDK_REPO="meta-qcom-robotics-sdk"
SDK_GIT="https://github.com/qualcomm-linux/meta-qcom-robotics-sdk.git"
RPM_DEPS_GIT="https://github.qualcomm.com/tengf/rpm-deps"

TARGET_DIR="${WORKDIR}/${TARGET}"
RPM_DEPS_DIR="${WORKDIR}/rpm-deps"
OUTPUT_DIR="${WORKDIR}/output"

build_proprietary_image() {
    echo ">>> [2/4] Building proprietary image for ${TARGET}..."
    cd "$TARGET_DIR"
    kas shell "${SDK_REPO}/ci/${TARGET}.yml:${SDK_REPO}/ci/linux-qcom-6.18.yml:${SDK_REPO}/ci/qcom-robotics-proprietary-image.yml:${SDK_REPO}/ci/performance.yml" \
        -c "bitbake -q -c build qcom-robotics-proprietary-image"
}

build_robotics_image() {
    echo ">>> [3/4] Building robotics image for ${TARGET}..."
    cd "$TARGET_DIR"
    kas shell "${SDK_REPO}/ci/${TARGET}.yml:${SDK_REPO}/ci/linux-qcom-6.18.yml:${SDK_REPO}/ci/qcom-robotics-image.yml:${SDK_REPO}/ci/performance.yml" \
        -c "bitbake -q -c build qcom-robotics-image"
}

publish_rpms() {
    echo ">>> [4/4] Pruning and pushing RPMs..."
    mkdir -p "$OUTPUT_DIR"
    bash "${RPM_DEPS_DIR}/prune_and_push_rpms.sh" \
        --image-dir "${TARGET_DIR}/build/tmp/deploy/images" \
        --repo-dir  "${TARGET_DIR}/build/tmp/deploy/rpm" \
        --outdir    "$OUTPUT_DIR"
}

# 1. Sync — clone SDK into target dir
echo ">>> [1/4] Syncing SDK into ${TARGET_DIR}..."
mkdir -p "$TARGET_DIR"
cd "$TARGET_DIR" && git clone -b "$RELEASE_TAG" "$SDK_GIT"

# 2. Build proprietary image
build_proprietary_image

# 3. Build non-proprietary image
build_robotics_image

# 4. Clone rpm-deps at workspace root, then prune and publish
cd "$WORKDIR" && git clone "$RPM_DEPS_GIT" rpm-deps
publish_rpms
