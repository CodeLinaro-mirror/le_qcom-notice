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

        -p, --project
            Project Name  (Eg: meta-qcom)

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

LONG_OPTS="url:,help,branch:,project:,machine:,distro:,image:,workdir:,arch:,"
GETOPT_CMD=$(getopt -o b:d:h:i:p:M:u:w:a: -l $LONG_OPTS -n $(basename $0) -- "$@"
) || \
            { echo "error parsing options."; echo_usage; }

eval set -- "$GETOPT_CMD"

while true; do
    case "$1" in
       -u|--url) URL="$2"; shift ;;
       -h|--help) echo_usage;;
       -b|--branch) BRANCH="$2"; shift ;;
       -p|--project) PROJECT="$2"; shift ;;
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
time git clone https://github.com/qualcomm-linux/${PROJECT}.git -b "$BRANCH"

# build variables
MACHINE="$MACHINE"
DISTRO="$DISTRO"

# setup environment
export SHELL=/bin/bash

# Run build
time kas build meta-qcom/ci/${MACHINE}.yml:meta-qcom/ci/${DISTRO}.yml
sleep 3
time kas build meta-qcom/ci/iq-8275-evk.yml:meta-qcom/ci/${DISTRO}.yml
sleep 3
time kas build meta-qcom/ci/iq-9075-evk.yml:meta-qcom/ci/${DISTRO}.yml
sleep 3
time kas build meta-qcom/ci/iq-x7181-evk.yml:meta-qcom/ci/${DISTRO}.yml
sleep 3
time kas build meta-qcom/ci/qcom-armv8a.yml:meta-qcom/ci/${DISTRO}.yml
sleep 3
time kas build meta-qcom/ci/qcs615-ride.yml:meta-qcom/ci/${DISTRO}.yml

pwd

tree -L 3 build/tmp/deploy
