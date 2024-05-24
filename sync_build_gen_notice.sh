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


END_OF_USAGE
    exit 1
}

LONG_OPTS="url:,help,branch:,manifest:,machine:,distro:,image:,workdir:,"
GETOPT_CMD=$(getopt -o b:d:h:i:m:M:u:w: -l $LONG_OPTS -n $(basename $0) -- "$@"
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
repo init -u "$URL" -b "$BRANCH" -m "$MANIFEST"

# repo sync
repo sync -j`nproc`

# build variables
MACHINE="$MACHINE"
DISTRO="$DISTRO"

# setup environment
export SHELL=/bin/bash
source setup-environment

# Run build
bitbake "$IMAGE"

SUBDIR="${WORKDIR%/*}"

# copy nhlos notice files
cp $SUBDIR/scripts/nhlos/License-Agreement-for-Redistributable-Binaries-of-QTI.txt $WORKDIR
cp $SUBDIR/scripts/nhlos/license.qcom.txt $WORKDIR
cat $SUBDIR/scripts/hwe/NOTICE >> $WORKDIR/NOTICE

# Go to working directory
cd $WORKDIR

# Get notices related to all the open-source modules that are pulled during build
NoticeFilesList=`find ./ -type f -iname "Notice" -o -iname "License" -o -iname "Copying" -o -iname "Credits" -o -iname "Patent" -o -iname "copyright" | xargs`
cat $NoticeFilesList >> NOTICE_OSS
cat NOTICE_OSS >> NOTICE
