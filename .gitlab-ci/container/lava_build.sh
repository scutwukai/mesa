#!/bin/bash

set -e
set -o xtrace

export DEBIAN_FRONTEND=noninteractive

check_minio()
{
    MINIO_PATH="${MINIO_HOST}/mesa-lava/$1/${MINIO_SUFFIX}/${DISTRIBUTION_TAG}/${DEBIAN_ARCH}"
    if wget -q --method=HEAD "https://${MINIO_PATH}/done"; then
        exit
    fi
}

# If remote files are up-to-date, skip rebuilding them
check_minio "${FDO_UPSTREAM_REPO}"
check_minio "${CI_PROJECT_PATH}"

. .gitlab-ci/container/container_pre_build.sh

# Install rust, which we'll be using for deqp-runner.  It will be cleaned up at the end.
. .gitlab-ci/container/build-rust.sh

if [[ "$DEBIAN_ARCH" = "arm64" ]]; then
    GCC_ARCH="aarch64-linux-gnu"
    KERNEL_ARCH="arm64"
    DEFCONFIG="arch/arm64/configs/defconfig"
    DEVICE_TREES="arch/arm64/boot/dts/rockchip/rk3399-gru-kevin.dtb"
    DEVICE_TREES+=" arch/arm64/boot/dts/amlogic/meson-gxl-s905x-libretech-cc.dtb"
    DEVICE_TREES+=" arch/arm64/boot/dts/allwinner/sun50i-h6-pine-h64.dtb"
    DEVICE_TREES+=" arch/arm64/boot/dts/amlogic/meson-gxm-khadas-vim2.dtb"
    DEVICE_TREES+=" arch/arm64/boot/dts/qcom/apq8016-sbc.dtb"
    DEVICE_TREES+=" arch/arm64/boot/dts/qcom/apq8096-db820c.dtb"
    DEVICE_TREES+=" arch/arm64/boot/dts/amlogic/meson-g12b-a311d-khadas-vim3.dtb"
    KERNEL_IMAGE_NAME="Image"
elif [[ "$DEBIAN_ARCH" = "armhf" ]]; then
    GCC_ARCH="arm-linux-gnueabihf"
    KERNEL_ARCH="arm"
    DEFCONFIG="arch/arm/configs/multi_v7_defconfig"
    DEVICE_TREES="arch/arm/boot/dts/rk3288-veyron-jaq.dtb arch/arm/boot/dts/sun8i-h3-libretech-all-h3-cc.dtb"
    KERNEL_IMAGE_NAME="zImage"
    . .gitlab-ci/container/create-cross-file.sh armhf
else
    GCC_ARCH="x86_64-linux-gnu"
    KERNEL_ARCH="x86_64"
    DEFCONFIG="arch/x86/configs/x86_64_defconfig"
    DEVICE_TREES=""
    KERNEL_IMAGE_NAME="bzImage"
fi

# Determine if we're in a cross build.
if [[ -e /cross_file-$DEBIAN_ARCH.txt ]]; then
    EXTRA_MESON_ARGS="--cross-file /cross_file-$DEBIAN_ARCH.txt"
    EXTRA_CMAKE_ARGS="-DCMAKE_TOOLCHAIN_FILE=/toolchain-$DEBIAN_ARCH.cmake"

    if [ $DEBIAN_ARCH = arm64 ]; then
        RUST_TARGET="aarch64-unknown-linux-gnu"
    elif [ $DEBIAN_ARCH = armhf ]; then
        RUST_TARGET="armv7-unknown-linux-gnueabihf"
    fi
    rustup target add $RUST_TARGET
    export EXTRA_CARGO_ARGS="--target $RUST_TARGET"

    export ARCH=${KERNEL_ARCH}
    export CROSS_COMPILE="${GCC_ARCH}-"
fi

apt-get update
apt-get install -y --no-remove \
                   automake \
                   bc \
                   cmake \
                   debootstrap \
                   git \
                   libegl1-mesa-dev \
                   libgbm-dev \
                   libgles2-mesa-dev \
                   libssl-dev \
                   libudev-dev \
                   libvulkan-dev \
                   libwaffle-dev \
                   libwayland-dev \
                   libx11-xcb-dev \
                   libxkbcommon-dev \
                   patch \
                   python3-distutils \
                   python3-mako \
                   python3-numpy \
                   python3-serial \
                   wget


if [[ "$DEBIAN_ARCH" = "armhf" ]]; then
    apt-get install -y --no-remove \
                       libegl1-mesa-dev:armhf \
                       libelf-dev:armhf \
                       libgbm-dev:armhf \
                       libgles2-mesa-dev:armhf \
                       libudev-dev:armhf \
                       libvulkan-dev:armhf \
                       libwaffle-dev:armhf \
                       libwayland-dev:armhf \
                       libx11-xcb-dev:armhf \
                       libxkbcommon-dev:armhf
fi


############### Building
STRIP_CMD="${GCC_ARCH}-strip"
mkdir -p /lava-files/rootfs-${DEBIAN_ARCH}


############### Build dEQP runner
. .gitlab-ci/container/build-deqp-runner.sh
mkdir -p /lava-files/rootfs-${DEBIAN_ARCH}/usr/bin
mv /usr/local/bin/deqp-runner /lava-files/rootfs-${DEBIAN_ARCH}/usr/bin/.
mv /usr/local/bin/piglit-runner /lava-files/rootfs-${DEBIAN_ARCH}/usr/bin/.


############### Build dEQP
DEQP_TARGET=surfaceless . .gitlab-ci/container/build-deqp.sh

mv /deqp /lava-files/rootfs-${DEBIAN_ARCH}/.


############### Build piglit
. .gitlab-ci/container/build-piglit.sh
mv /piglit /lava-files/rootfs-${DEBIAN_ARCH}/.


############### Build libdrm
EXTRA_MESON_ARGS+=" -D prefix=/libdrm"
. .gitlab-ci/container/build-libdrm.sh


############### Cross-build kernel
mkdir -p kernel
wget -qO- ${KERNEL_URL} | tar -xz --strip-components=1 -C kernel
pushd kernel

# The kernel doesn't like the gold linker (or the old lld in our debians).
# Sneak in some override symlinks during kernel build until we can update
# debian (they'll get blown away by the rm of the kernel dir at the end).
mkdir -p ld-links
for i in /usr/bin/*-ld /usr/bin/ld; do
    i=`basename $i`
    ln -sf /usr/bin/$i.bfd ld-links/$i
done
export PATH=`pwd`/ld-links:$PATH

if [ -n "$INSTALL_KERNEL_MODULES" ]; then
    # Disable all modules in defconfig, so we only build the ones we want
    sed -i 's/=m/=n/g' ${DEFCONFIG}
fi

./scripts/kconfig/merge_config.sh ${DEFCONFIG} ../.gitlab-ci/container/${KERNEL_ARCH}.config
make ${KERNEL_IMAGE_NAME}
for image in ${KERNEL_IMAGE_NAME}; do
    cp arch/${KERNEL_ARCH}/boot/${image} /lava-files/.
done

if [[ -n ${DEVICE_TREES} ]]; then
    make dtbs
    cp ${DEVICE_TREES} /lava-files/.
fi

if [ -n "$INSTALL_KERNEL_MODULES" ]; then
    make modules
    INSTALL_MOD_PATH=/lava-files/rootfs-${DEBIAN_ARCH}/ make modules_install
fi

if [[ ${DEBIAN_ARCH} = "arm64" ]] && [[ ${MINIO_SUFFIX} = "baremetal" ]]; then
    make Image.lzma
    mkimage \
        -f auto \
        -A arm \
        -O linux \
        -d arch/arm64/boot/Image.lzma \
        -C lzma\
        -b arch/arm64/boot/dts/qcom/sdm845-cheza-r3.dtb \
        /lava-files/cheza-kernel
    KERNEL_IMAGE_NAME+=" cheza-kernel"
fi

popd
rm -rf kernel

############### Delete rust, since the tests won't be compiling anything.
rm -rf /root/.cargo

############### Create rootfs
set +e
if ! debootstrap \
     --variant=minbase \
     --arch=${DEBIAN_ARCH} \
     --components main,contrib,non-free \
     bullseye \
     /lava-files/rootfs-${DEBIAN_ARCH}/ \
     http://deb.debian.org/debian; then
    cat /lava-files/rootfs-${DEBIAN_ARCH}/debootstrap/debootstrap.log
    exit 1
fi
set -e

cp .gitlab-ci/container/create-rootfs.sh /lava-files/rootfs-${DEBIAN_ARCH}/.
chroot /lava-files/rootfs-${DEBIAN_ARCH} sh /create-rootfs.sh
rm /lava-files/rootfs-${DEBIAN_ARCH}/create-rootfs.sh


############### Install the built libdrm
# Dependencies pulled during the creation of the rootfs may overwrite
# the built libdrm. Hence, we add it after the rootfs has been already
# created.
mkdir -p /lava-files/rootfs-${DEBIAN_ARCH}/usr/lib/$GCC_ARCH
find /libdrm/ -name lib\*\.so\* | xargs cp -t /lava-files/rootfs-${DEBIAN_ARCH}/usr/lib/$GCC_ARCH/.
rm -rf /libdrm


if [ ${DEBIAN_ARCH} = arm64 ] && [ ${MINIO_SUFFIX} = baremetal ]; then
    # Make a gzipped copy of the Image for db410c.
    gzip -k /lava-files/Image
    KERNEL_IMAGE_NAME+=" Image.gz"
fi

du -ah /lava-files/rootfs-${DEBIAN_ARCH} | sort -h | tail -100
pushd /lava-files/rootfs-${DEBIAN_ARCH}
  tar czf /lava-files/lava-rootfs.tgz .
popd

. .gitlab-ci/container/container_post_build.sh

############### Upload the files!
ci-fairy minio login $CI_JOB_JWT
FILES_TO_UPLOAD="lava-rootfs.tgz \
                 $KERNEL_IMAGE_NAME"

if [[ -n $DEVICE_TREES ]]; then
    FILES_TO_UPLOAD="$FILES_TO_UPLOAD $(basename -a $DEVICE_TREES)"
fi

for f in $FILES_TO_UPLOAD; do
    ci-fairy minio cp /lava-files/$f \
             minio://${MINIO_PATH}/$f
done

touch /lava-files/done
ci-fairy minio cp /lava-files/done minio://${MINIO_PATH}/done
