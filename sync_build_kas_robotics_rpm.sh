#!/bin/bash
set -ex

echo_usage() {
    cat <<'EOF'

Usage: ./build.sh [OPTIONS]

    Options:
        -h, --help       Displays this help
        -t, --target     Board target (repeatable: -t iq-9075-evk -t iq-8275-evk)
        -w, --workdir    Working directory
        -u, --jf-user    JFrog username
        -a, --jf-pass    JFrog password or token
        -r, --jf-url     JFrog Platform URL
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

TARGETS=()

while true; do
    case "$1" in
        -h|--help)    echo_usage ;;
        -t|--target)  TARGETS+=("$2"); shift ;;
        -w|--workdir) WORKDIR="$2";    shift ;;
        -u|--jf-user) JF_USER="$2";   shift ;;
        -a|--jf-pass) JF_PASS="$2";   shift ;;
        -r|--jf-url)      JF_URL="$2";       shift ;;
        -g|--release-tag) RELEASE_TAG="$2";  shift ;;
        --) shift; break ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

[ "${#TARGETS[@]}" -eq 0 ] && { echo "ERROR: --target is required"; echo_usage; }
[ -z "$RELEASE_TAG" ]     && { echo "ERROR: --release-tag is required"; echo_usage; }
[ -z "$WORKDIR" ] && WORKDIR="$(pwd)"

SDK_REPO="meta-qcom-robotics-sdk"
SDK_GIT="https://github.com/qualcomm-linux/meta-qcom-robotics-sdk.git"
RPM_DEPS_GIT="https://github.qualcomm.com/tengf/rpm-deps"

NON_PROP_DIR="${WORKDIR}/non-prop"
PROP_DIR="${WORKDIR}/prop"
COMMON_DIR="${WORKDIR}/common"

mkdir -p "$NON_PROP_DIR" "$PROP_DIR"
cd "$NON_PROP_DIR" && git clone -b "$RELEASE_TAG" "$SDK_GIT"
cd "$PROP_DIR"     && git clone -b "$RELEASE_TAG" "$SDK_GIT"

build_robotics_image() {
    local target="$1"
    local ci_target_yml="${SDK_REPO}/ci/${target}.yml"
    local ci_distro_yml="${SDK_REPO}/ci/qcom-robotics-distro.yml"

    echo ">>> [1/4] [$target] Building qcom-robotics-image (non-prop)..."
    cd "$NON_PROP_DIR"
    kas shell "${ci_target_yml}:${ci_distro_yml}" \
        -c "bitbake -c build qcom-robotics-image"
}

build_proprietary_image() {
    local target="$1"
    local ci_target_yml="${SDK_REPO}/ci/${target}.yml"
    local ci_distro_yml="${SDK_REPO}/ci/qcom-robotics-distro.yml"
    local ci_prop_yml="${SDK_REPO}/ci/qcom-robotics-proprietary-image.yml"

    echo ">>> [2/4] [$target] Building qcom-robotics-image (prop)..."
    cd "$PROP_DIR"
    kas build "${ci_target_yml}:${ci_distro_yml}:${ci_prop_yml}"
    kas shell "${ci_target_yml}:${ci_distro_yml}:${ci_prop_yml}" \
        -c "bitbake -c build qcom-robotics-image"
}

collect_artifacts() {
    local target="$1"

    echo ">>> [3/4] [$target] Collecting artifacts into common/..."
    mkdir -p "${COMMON_DIR}/images" "${COMMON_DIR}/rpm"

    cp -r "${NON_PROP_DIR}/build/tmp/deploy/images/." "${COMMON_DIR}/images/"
    cp -r "${PROP_DIR}/build/tmp/deploy/images/."     "${COMMON_DIR}/images/"

    cp -r "${NON_PROP_DIR}/build/tmp/deploy/rpm/." "${COMMON_DIR}/rpm/"
    cp -r "${PROP_DIR}/build/tmp/deploy/rpm/."     "${COMMON_DIR}/rpm/"
}

publish_rpms() {
    echo ">>> [4/4] Pruning and pushing RPMs..."
    bash "${COMMON_DIR}/rpm-deps/prune_and_push_rpms.sh" \
        --image-dir "${COMMON_DIR}/images" \
        --repo-dir "${COMMON_DIR}/rpm" \
        --outdir "${COMMON_DIR}/output"
}

for TARGET in "${TARGETS[@]}"; do
    build_robotics_image "$TARGET"
    build_proprietary_image "$TARGET"
    collect_artifacts "$TARGET"
done

mkdir -p "${COMMON_DIR}/output"
cd "$COMMON_DIR"
git clone "$RPM_DEPS_GIT" rpm-deps
publish_rpms
