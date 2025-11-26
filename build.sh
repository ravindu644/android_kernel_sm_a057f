#!/bin/bash

git submodule update --init --recursive

export WDIR="$(dirname $(readlink -f $0))" && cd "$WDIR"
export MERGE_CONFIG="${WDIR}/kernel_platform/common/scripts/kconfig/merge_config.sh"
export PKG_VENDOR_BOOT="${WDIR}/LKM_Tools/02.prepare_vendor_boot_modules.sh"
export PKG_TOUCH_MODULE_SCRIPT="${WDIR}/LKM_Tools/04.prepare_only_nethunter_modules.sh"

# Source touch-modules.conf
source ${WDIR}/touch-modules.conf
[ -z "$TWRP_EXT_MODULES" ] && echo -e "[-] Error: TWRP_EXT_MODULES is not set\n" && exit 1

rm -rf "${WDIR}/dist" \
    && rm -rf "${WDIR}/out" \
    && mkdir -p "${WDIR}/dist"

# Download and install Toolchain
if [ ! -d "${WDIR}/kernel_platform/prebuilts" ]; then
    echo -e "[+] Downloading and installing Toolchain...\n"
    sudo apt install rsync p7zip-full -y
    curl -LO --progress-bar https://github.com/ravindu644/android_kernel_sm_x810/releases/download/toolchain/qcom-5.15-toolchain.tar.gz.zip
    curl -LO --progress-bar https://github.com/ravindu644/android_kernel_sm_x810/releases/download/toolchain/qcom-5.15-toolchain.tar.gz.z01
    7z x qcom-5.15-toolchain.tar.gz.zip && rm qcom-5.15-toolchain.tar.gz.zip qcom-5.15-toolchain.tar.gz.z01
    tar -xvf qcom-5.15-toolchain.tar.gz && rm qcom-5.15-toolchain.tar.gz
    mv prebuilts "${WDIR}/kernel_platform" && chmod -R +x "${WDIR}/kernel_platform/prebuilts"    
fi

echo -e "[+] Toolchain installed...\n"

# setup localversion
if [ -z "$BUILD_KERNEL_VERSION" ]; then
    export BUILD_KERNEL_VERSION="TWRP-dev"
fi

echo -e "CONFIG_LOCALVERSION_AUTO=n\nCONFIG_LOCALVERSION=\"-ravindu644-${BUILD_KERNEL_VERSION}\"\n" > "${WDIR}/custom_defconfigs/version_defconfig"

#1. target config
export MODEL="a05s"
export PROJECT_NAME=${MODEL}
export REGION="eur"
export CARRIER="open"
export TARGET_BUILD_VARIANT="user"

#2. sm8550 common config
CHIPSET_NAME="sm6225"

export ANDROID_BUILD_TOP=$(pwd)
export TARGET_PRODUCT=gki
export TARGET_BOARD_PLATFORM=gki

export ANDROID_PRODUCT_OUT=${ANDROID_BUILD_TOP}/out/target/product/${MODEL}
export OUT_DIR=${ANDROID_BUILD_TOP}/out/msm-${CHIPSET_NAME}-${CHIPSET_NAME}-${TARGET_PRODUCT}

# for Lcd(techpack) driver build
export KBUILD_EXTRA_SYMBOLS="${ANDROID_BUILD_TOP}/out/vendor/qcom/opensource/mmrm-driver/Module.symvers \
		${ANDROID_BUILD_TOP}/out/vendor/qcom/opensource/mm-drivers/hw_fence/Module.symvers \
		${ANDROID_BUILD_TOP}/out/vendor/qcom/opensource/mm-drivers/sync_fence/Module.symvers \
		${ANDROID_BUILD_TOP}/out/vendor/qcom/opensource/mm-drivers/msm_ext_display/Module.symvers \
		${ANDROID_BUILD_TOP}/out/vendor/qcom/opensource/securemsm-kernel/Module.symvers \
"

# for Audio(techpack) driver build
export MODNAME=audio_dlkm

export EXT_MODULES="../vendor/qcom/opensource/mm-drivers/msm_ext_display \
  ../vendor/qcom/opensource/mm-drivers/sync_fence \
  ../vendor/qcom/opensource/mm-drivers/hw_fence \
  ../vendor/qcom/opensource/mmrm-driver \
  ../vendor/qcom/opensource/securemsm-kernel \
  ../vendor/qcom/opensource/display-drivers/msm \
  ../vendor/qcom/opensource/audio-kernel \
  ../vendor/qcom/opensource/camera-kernel \
  ../vendor/qcom/opensource/touch-drivers \
"

# Run menuconfig only if you want to.
# It's better to use MAKE_MENUCONFIG=0 when everything is already properly enabled, disabled, or configured.
export MAKE_MENUCONFIG=0

HERMETIC_VALUE=1
if [ "$MAKE_MENUCONFIG" = "1" ]; then
    HERMETIC_VALUE=0
fi

# custom build options
export GKI_BUILDSCRIPT="./kernel_platform/build/android/prepare_vendor.sh"
export BUILD_OPTIONS=(
    RECOMPILE_KERNEL=1
    SKIP_MRPROPER=0
    HERMETIC_TOOLCHAIN=$HERMETIC_VALUE
    KMI_SYMBOL_LIST_STRICT_MODE=0
    ABI_DEFINITION=""
    LTO="thin"
)

#3. build kernel
env ${BUILD_OPTIONS[@]} "${GKI_BUILDSCRIPT}" sec ${TARGET_PRODUCT} || exit 1

#4. copy kernel image and boot.img to dist directory
if [ -f "${OUT_DIR}/dist/boot.img" ]; then
    cp "${OUT_DIR}/dist/boot.img" "${WDIR}/dist/boot.img"
else
    echo -e "[-] Error: boot.img not found\n"
    exit 1
fi

if [ -f "${OUT_DIR}/dist/Image" ]; then
    cp "${OUT_DIR}/dist/Image" "${WDIR}/dist/Image"
else
    echo -e "[-] Error: Image not found\n"
    exit 1
fi

#4. Package vendor_boot modules
package_vendor_boot_modules(){

    mkdir -p ${WDIR}/dist/built_vendor_boot_modules
    echo -e "[+] Packaging vendor_boot modules...\n"

    # non-interactive mode
    # ./02.prepare_vendor_boot_modules.sh <modules_list> <staging_dir> <oem_load_file> <system_map> <strip_tool> <output_dir>
    ${PKG_VENDOR_BOOT} \
        ${WDIR}/prebuilts_a05s/vendor_boot/modules_list.txt \
        ${OUT_DIR}/staging \
        ${WDIR}/prebuilts_a05s/vendor_boot/modules.load \
        ${OUT_DIR}/dist/System.map \
        ${WDIR}/kernel_platform/prebuilts/clang/host/linux-x86/clang-r450784e/bin/llvm-strip \
        ${WDIR}/dist/built_vendor_boot_modules
} && package_vendor_boot_modules || exit 1

package_touch_modules(){

    mkdir -p ${WDIR}/dist/built_touch_modules/organized_output

    for i in ${TWRP_EXT_MODULES[@]}; do
        if [ -f ${OUT_DIR}/dist/${i} ]; then
            cp ${OUT_DIR}/dist/${i} ${WDIR}/dist/built_touch_modules/
        else
            echo -e "[-] Error: ${i} not found\n"
            exit 1
        fi
    done

    echo -e "[+] Packaging touch modules...\n"

    # non-interactive mode
    # ./04.prepare_only_nethunter_modules.sh <nh_modules_dir> <staging_dir> <vendor_boot_list> <system_map> <output_dir> [strip_tool]
    ${PKG_TOUCH_MODULE_SCRIPT} \
        ${WDIR}/dist/built_touch_modules \
        ${OUT_DIR}/staging \
        "" \
        ${OUT_DIR}/dist/System.map \
        ${WDIR}/dist/built_touch_modules/organized_output
} && package_touch_modules || exit 1

zip_dist_files(){
    echo -e "[+] Zipping dist files...\n"
    # Change to dist directory and zip all contents
    cd "${WDIR}/dist" && zip -r -9 "${WDIR}/SM-M145F-TWRP-Kernel-with-touch-modules.zip" . && cd "${WDIR}"
} && zip_dist_files || exit 1

echo -e "[+] Kernel build completed successfully\n"
exit 0
