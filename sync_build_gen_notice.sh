# **************************************************************************
#
# Copyright (c) 2023 Qualcomm Innovation Center, Inc. All rights reserved.
# SPDX-License-Identifier: BSD-3-Clause
#
# **************************************************************************
#!/bin/bash
echo_usage()
{
    cat <<'END_OF_USAGE'

Usage:
    ./sync_build.sh [OPTIONS]

    Options:
        -u, --url
            repo url
        -h, --help
            Displays this help list

        -b, --branch
            branch name (Eg: LE.QCLINUX.1.0)

        -m, --manifest-file
            manifest file

        -M, --machine
            machine (Eg: qcm6490)

        -d, --distro
            Distro (Eg: qcom-wayland)

        -i, --image
            Image (Eg: qcom-console-image)

        -w, --workdir
            Working directory (Eg: /local/mnt/worksapce/test)

        -a, --arch
            architecture (Eg: x86, arm)

END_OF_USAGE
    exit 1
}

LONG_OPTS="url:,help,branch:,manifest:,machine:,distro:,image:,workdir:,arch:,"
GETOPT_CMD=$(getopt -o b:d:h:i:m:M:u:w:a: -l $LONG_OPTS -n $(basename $0) -- "$@"
) || \
            { echo "error parsing options."; echo_usage; }

eval set -- "$GETOPT_CMD"

while true; do
    case "$1" in
       -u|--url) URL="$2"; shift ;;
       -h|--help) echo_usage;;
       -b|--branch) BRANCH="$2"; shift ;;
       -m|--manifest) MANIFEST="$2"; shift ;;
       -M|--machine) MACHINE="$2"; shift ;;
       -d|--distro) DISTRO="$2"; shift ;;
       -i|--image) IMAGE="$2"; shift ;;
       -w|--workdir) WORKDIR="$2"; shift ;;
       -a|--arch) ARCH="$2"; shift ;;
       --) shift ; break ;;
       *) echo "Error processing args -- unrecognized option $1" >&2
          exit 1;;
    esac
    shift
done

# Create if working directory not created
mkdir -p $WORKDIR

# Go to working directory
cd $WORKDIR

# repo init
time repo init -u "$URL" -b "$BRANCH" -m "$MANIFEST"

# repo sync
time repo sync -c --no-tags -j`nproc`

# build variables
MACHINE="$MACHINE"
DISTRO="$DISTRO"

# setup environment
export SHELL=/bin/bash
#if [[ "$ARCH" =~ "arm" ]]; then
export SDKMACHINE="aarch64"
#fi
#if [[ "$MANIFEST" =~ "qim-product-sdk" ]]; then
#export EXTRALAYERS="meta-qcom-qim-product-sdk"
#fi

#if [[ "$MANIFEST" =~ "robotics-product-sdk" ]]; then
source setup-robotics-environment
#else
#source setup-environment
#fi

# Run build
#time bitbake "$IMAGE"
#if [[ "$MANIFEST" =~ "qim-product-sdk" ]]; then
#time bitbake qim-product-sdk
#time bitbake -c populate_sdk_ext qcom-multimedia-image
#elif [[ "$MANIFEST" =~ "robotics-product-sdk" ]]; then
time ../qirp-build qcom-robotics-full-image
time bitbake -fc populate_sdk_ext qcom-robotics-full-image
#else
#   time bitbake -c populate_sdk_ext qcom-multimedia-image
#fi

SUBDIR="${WORKDIR%/*}"

# copy nhlos notice files
cp $SUBDIR/scripts/hwe/NO.LOGIN.BINARY.LICENSE.QTI.pdf $WORKDIR
cp $SUBDIR/scripts/nhlos/NHLOS_NOTICE $WORKDIR
#if [[ "$MANIFEST" =~ "robotics-product-sdk" ]]; then
cp $SUBDIR/scripts/robotics/ROBOTICS_NOTICE $WORKDIR
#fi
cat $SUBDIR/scripts/hwe/NOTICE >> $WORKDIR/NOTICE

# Go to working directory
cd $WORKDIR

# Append NOTICE file from nologin NHLOS proprietary bins to NOTICE file from nologin HLOS proprietary bins
#if [[ "$MANIFEST" =~ "robotics-product-sdk" ]]; then
cat ROBOTICS_NOTICE >> NOTICE
#fi
cat NHLOS_NOTICE >> NOTICE

# Get notices related to all the open-source modules that are pulled during build
NoticeFilesList=`find ./ -type f -iname "Notice" -o -iname "License" -o -iname "Copying" -o -iname "Credits" -o -iname "Patent" -o -iname "copyright" | xargs`
cat $NoticeFilesList >> NOTICE_OSS
cat NOTICE_OSS >> NOTICE
