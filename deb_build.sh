set -ex

echo_usage()
{
    cat <<'END_OF_USAGE'

Usage:
    ./build.sh [OPTIONS]

    Options:
        -h, --help
            Displays this help list

        -b, --branch
            Release tag / branch for qcom-deb-images (Eg: 20260529-1)

        -k, --kernel-ref
            Kernel release tag for qcom-next (Eg: qcom-next-7.1-rc4-20260524)

        -s, --snapshot
            Debian snapshot date (Eg: 20260528)

        -w, --workdir
            Working directory (Eg: /home/codelinaro/app)

        -x, --xfce
            Enable XFCE desktop (true/false, default: true)

        -u, --jf-user
            JFrog username

        -t, --tag
            release tag to checkout (Eg: 20260731-1, skip if not needed)

        -a, --jf-pass
            JFrog password or token

        -r, --jf-url
            JFrog Platform URL

END_OF_USAGE
    exit 1
}

LONG_OPTS="help,branch:,kernel-ref:,snapshot:,workdir:,xfce:,jf-user:,tag:,jf-pass:,jf-url:"

GETOPT_CMD=$(getopt \
    -o hb:k:s:w:x:u:t:a:r: \
    -l "$LONG_OPTS" \
    -n "$(basename "$0")" \
    -- "$@") || {
        echo "error parsing options."
        echo_usage
}

eval set -- "$GETOPT_CMD"

while true; do
    case "$1" in
       -h|--help) echo_usage;;
       -b|--branch) BRANCH="$2"; shift ;;
       -k|--kernel-ref) KERNEL_REF="$2"; shift ;;
       -s|--snapshot) SNAPSHOT="$2"; shift ;;
       -w|--workdir) WORKDIR="$2"; shift ;;
       -x|--xfce) XFCE="$2"; shift ;;
       -u|--jf-user) JF_USER="$2"; shift ;;
       -t|--tag) RELEASE_TAG="$2"; shift ;;
       -a|--jf-pass) JF_PASS="$2"; shift ;;
       -r|--jf-url) JF_URL="$2"; shift ;;
       --) shift ; break ;;
       *) echo "Error processing args -- unrecognized option $1" >&2
          exit 1;;
    esac
    shift
done

BUILD_ID="local-$(date +%Y%m%d)"

# Create and enter working directory
mkdir -p $WORKDIR
cd $WORKDIR

clone_repo()
{
        rm -rf $WORKDIR/qcom-deb-images
        git clone --branch "$RELEASE_TAG" --single-branch https://github.com/qualcomm-linux/qcom-deb-images.git
        cd $WORKDIR/qcom-deb-images
}


build_kernel()
{
    cd $WORKDIR/qcom-deb-images
    echo ">>> Building kernel (ref: $KERNEL_REF)..."

    time scripts/build-linux-deb.py --qcom-next --ref "$KERNEL_REF" prune.config qcom.config kernel-configs/*.config

    echo ">>> Copying kernel deb to debos-recipes/local-debs/..."
    ls *.deb | grep -v dbg | xargs cp -t debos-recipes/local-debs/
}


build_rootfs()
{
    echo ">>> Building rootfs..."
    cd $WORKDIR/qcom-deb-images
    time make USE_CONTAINER=no rootfs.tar \
        EXTRA_DEBOS_OPTS="-t localdebs:local-debs -t kernelpackage:none -t xfcedesktop:$XFCE  -t snapshot:$SNAPSHOT -t overlays:qsc-deb-releases -t buildid:$BUILD_ID"
}


build_sdcard()
{
    echo ">>> Building SD card image..."
    cd $WORKDIR/qcom-deb-images
    time make USE_CONTAINER=no disk-sdcard.img \
        EXTRA_DEBOS_OPTS="-t snapshot:$SNAPSHOT"
}


build_flash()
{
    echo ">>> Building flashable images..."
    cd $WORKDIR/qcom-deb-images
    time make USE_CONTAINER=no flash
}

generate_tar()
{
    cd $WORKDIR/qcom-deb-images
    tar -cvf deb_artifacts.tar flash_glymur-crd_nvme flash_glymur-crd_spinor disk-sdcard.img1 disk-sdcard.img2
}

upload_artifacts()
{
    /usr/local/bin/jf c add artifactory-server --url=$JF_URL --user=$JF_USER --password=$JF_PASS
    /usr/local/bin/jf rt u --detailed-summary --flat=false --recursive cd $WORKDIR/qcom-deb-images/deb_artifacts.tar qli-ci/flashable-binaries/meta-qcom-robotics/qcom-robotics-distro/iq-8275-evk/
    echo ">>> Artifacts uploaded successfully! : with deb_artifacts.tar"
}

clone_repo
build_kernel
build_rootfs
build_sdcard
build_flash
generate_tar
if [ -n "$JF_URL" ] && [ -n "$JF_USER" ] && [ -n "$JF_PASS" ]; then
    upload_artifacts
else
    echo "JFrog credentials not provided, skipping JFrog configuration."
fi
