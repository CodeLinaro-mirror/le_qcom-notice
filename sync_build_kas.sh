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

        -D, --downloadderver
            0 or 1 (Eg: 1 to host downloads)

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

LONG_OPTS="url:,help,branch:,project:,machine:,distro:,downloadserver:,image:,workdir:,arch:,"
GETOPT_CMD=$(getopt -o b:d:D:h:i:p:M:u:w:a: -l $LONG_OPTS -n $(basename $0) -- "$@"
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
       -D|--downloadserver) DOWNLOADSERVER="$2"; shift ;;
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
kas checkout meta-qcom-releases/lock.yml

# kas configuration files need to be part of same repository
# copy kas lock file to meta-qcom repository
cp meta-qcom-releases/lock.yml meta-qcom/ci/lock.yml

# build variables
MACHINE="$MACHINE"
DISTRO="$DISTRO"

if [[ "$ARCH" =~ "arm" ]]; then
   export SDKMACHINE="aarch64"
fi

if [[ "$ARCH" =~ "arm" ]]; then
   DISTRO="qcom-distro"
   echo "Architecture is $ARCH: Compile for Generic target, compile eSDK and standard SDK for generic target, distro=$DISTRO"
   time kas build meta-qcom/ci/qcom-armv8a.yml:meta-qcom/ci/${DISTRO}.yml:meta-qcom/ci/mirror-tarballs.yml:meta-qcom/ci/linux-qcom-6.18.yml:meta-qcom/ci/lock.yml
   sleep 3
   kas shell meta-qcom/ci/qcom-armv8a.yml:meta-qcom/ci/${DISTRO}.yml:meta-qcom/ci/mirror-tarballs.yml:meta-qcom/ci/linux-qcom-6.18.yml:meta-qcom/ci/lock.yml -c "bitbake -c populate_sdk qcom-multimedia-proprietary-image && bitbake -c populate_sdk_ext qcom-multimedia-proprietary-image"
else
   if [ "$DOWNLOADSERVER" == 1 ]; then
      DISTRO="qcom-distro-catchall"
      echo "Architecture is $ARCH: Compile for Generic target, distro $DISTRO for downloads hosting"
      time kas build meta-qcom/ci/qcom-armv8a.yml:meta-qcom/ci/${DISTRO}.yml:meta-qcom/ci/mirror-tarballs.yml:meta-qcom/ci/linux-qcom-6.18.yml:meta-qcom/ci/lock.yml
      sleep 3
      kas shell meta-qcom/ci/qcom-armv8a.yml:meta-qcom/ci/${DISTRO}.yml:meta-qcom/ci/mirror-tarballs.yml:meta-qcom/ci/linux-qcom-6.18.yml:meta-qcom/ci/lock.yml -c "bitbake -c populate_sdk qcom-multimedia-proprietary-image && bitbake -c populate_sdk_ext qcom-multimedia-proprietary-image"
   else
      DISTRO="qcom-distro"
      echo "Architecture is $ARCH: Compile for all applicable targets (KLMT), compile eSDK and standard SDK for generic target, distro=$DISTRO"
      # Run build
      time kas build meta-qcom/ci/rb3gen2-core-kit.yml:meta-qcom/ci/${DISTRO}.yml:meta-qcom/ci/linux-qcom-6.18.yml:meta-qcom/ci/lock.yml
      sleep 3
      time kas build meta-qcom/ci/iq-8275-evk.yml:meta-qcom/ci/${DISTRO}.yml:meta-qcom/ci/linux-qcom-6.18.yml:meta-qcom/ci/lock.yml
      sleep 3
      time kas build meta-qcom/ci/iq-9075-evk.yml:meta-qcom/ci/${DISTRO}.yml:meta-qcom/ci/linux-qcom-6.18.yml:meta-qcom/ci/lock.yml
      sleep 3
      time kas build meta-qcom/ci/iq-615-evk.yml:meta-qcom/ci/${DISTRO}.yml:meta-qcom/ci/linux-qcom-6.18.yml:meta-qcom/ci/lock.yml
      sleep 3
      time kas build meta-qcom/ci/qcom-armv8a.yml:meta-qcom/ci/${DISTRO}.yml:meta-qcom/ci/mirror-tarballs.yml:meta-qcom/ci/linux-qcom-6.18.yml:meta-qcom/ci/lock.yml
      sleep 3
      kas shell meta-qcom/ci/qcom-armv8a.yml:meta-qcom/ci/${DISTRO}.yml:meta-qcom/ci/mirror-tarballs.yml:meta-qcom/ci/linux-qcom-6.18.yml:meta-qcom/ci/lock.yml -c "bitbake -c populate_sdk qcom-multimedia-proprietary-image && bitbake -c populate_sdk_ext qcom-multimedia-proprietary-image"
   fi
fi

# setup environment
export SHELL=/bin/bash

# Run build
#time kas build meta-qcom/ci/rb3gen2-core-kit.yml:meta-qcom/ci/${DISTRO}.yml:meta-qcom/ci/linux-qcom-6.18.yml:meta-qcom/ci/lock.yml
#sleep 3
#time kas build meta-qcom/ci/iq-8275-evk.yml:meta-qcom/ci/${DISTRO}.yml:meta-qcom/ci/linux-qcom-6.18.yml:meta-qcom/ci/lock.yml
#sleep 3
#time kas build meta-qcom/ci/iq-9075-evk.yml:meta-qcom/ci/${DISTRO}.yml:meta-qcom/ci/linux-qcom-6.18.yml:meta-qcom/ci/lock.yml
#sleep 3
#time kas build meta-qcom/ci/iq-615-evk.yml:meta-qcom/ci/${DISTRO}.yml:meta-qcom/ci/linux-qcom-6.18.yml:meta-qcom/ci/lock.yml
#sleep 3
#time kas build meta-qcom/ci/qcom-armv8a.yml:meta-qcom/ci/${DISTRO}.yml:meta-qcom/ci/mirror-tarballs.yml:meta-qcom/ci/linux-qcom-6.18.yml:meta-qcom/ci/lock.yml
#sleep 3
#kas shell meta-qcom/ci/qcom-armv8a.yml:meta-qcom/ci/${DISTRO}.yml:meta-qcom/ci/mirror-tarballs.yml:meta-qcom/ci/linux-qcom-6.18.yml:meta-qcom/ci/lock.yml -c "bitbake -c populate_sdk qcom-multimedia-proprietary-image && bitbake -c populate_sdk_ext qcom-multimedia-proprietary-image"

SUBDIR="${WORKDIR%/*}"

# copy nhlos notice files
cp $SUBDIR/scripts/hwe/NO.LOGIN.BINARY.LICENSE.QTI.pdf $WORKDIR
cp $SUBDIR/scripts/nhlos/NHLOS_NOTICE $WORKDIR
cat $SUBDIR/scripts/hwe/NOTICE >> $WORKDIR/NOTICE

# Go to working directory
cd $WORKDIR

cat NHLOS_NOTICE >> NOTICE

# Get notices related to all the open-source modules that are pulled during build
NoticeFilesList=`find ./ -type f -iname "Notice" -o -iname "License" -o -iname "Copying" -o -iname "Credits" -o -iname "Patent" -o -iname "copyright" | xargs`
cat $NoticeFilesList >> NOTICE_OSS
cat NOTICE_OSS >> NOTICE

pwd

tree -L 2 build/tmp/deploy || true
