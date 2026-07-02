#!/bin/bash

# Set up logging
BUILD_LOG="build_$(date +%Y%m%d_%H%M%S).log"
exec 1> >(tee -a "$BUILD_LOG")
exec 2>&1

echo "====================================="
echo "Kernel Build Started: $(date)"
echo "Build Log: $BUILD_LOG"
echo "====================================="

# Restore tracked files that make mrproper may have deleted (*.i matched by .gitignore)
git checkout -- drivers/input/touchscreen/xiaomi/focaltech_touch_mi/include/ 2>/dev/null

# Define toolchain variables
CLANG_DIR=$PWD/toolchain/neutron_18
PATH=$CLANG_DIR/bin:$PATH

# Check if toolchain exists
if [ ! -f "$CLANG_DIR/bin/clang-18" ]; then
    echo "-----------------------------------------------"
    echo "Toolchain not found! Downloading..."
    echo "-----------------------------------------------"
    rm -rf "$CLANG_DIR"
    mkdir -p "$CLANG_DIR"
    pushd toolchain/neutron_18 > /dev/null
    bash <(curl -s "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman") -S=05012024
    echo "-----------------------------------------------"
    echo "Patching toolchain..."
    echo "-----------------------------------------------"
    bash <(curl -s "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman") --patch=glibc
    echo "-----------------------------------------------"
    echo "Cleaning up..."
    popd > /dev/null
fi

MAKE_ARGS="
LLVM=1
LLVM_IAS=1
ARCH=arm64
-j$(nproc)
CC=clang
CLANG_TRIPLE=aarch64-linux-gnu-
CROSS_COMPILE=aarch64-linux-android-
O=out
"

echo "====================================="
echo "Step 1: Generating .config from defconfigs"
echo "====================================="
make ${MAKE_ARGS} vendor/sdm845-perf_defconfig || {
    echo "Failed to generate base defconfig"
    exit 1
}

KCONFIG_CONFIG=out/.config scripts/kconfig/merge_config.sh -m out/.config \
    arch/arm64/configs/vendor/xiaomi/sdm845-common.config \
    arch/arm64/configs/vendor/xiaomi/beryllium.config

make ${MAKE_ARGS} olddefconfig || {
    echo "Failed to run olddefconfig"
    exit 1
}

echo ""
echo "====================================="
echo "Step 2: Building KPM (KernelPatch Module)"
echo "====================================="

# Build standalone kpimg binary
KPM_DIR="$PWD/kernel/kpm"
if [ -d "$KPM_DIR" ]; then
    CLANG_DIR="$PWD/toolchain/neutron_18"
    CC="${CLANG_DIR}/bin/clang-18"
    LD="${CLANG_DIR}/bin/ld.lld"
    AS="${CLANG_DIR}/bin/llvm-as"
    OBJCOPY="${CLANG_DIR}/bin/llvm-objcopy"

    CFLAGS="-Wall -fno-builtin -std=gnu11 -nostdinc -mgeneral-regs-only -g"
    CFLAGS="$CFLAGS -Wno-unused-function -Wno-return-type -Wno-uninitialized"
    CFLAGS="$CFLAGS -fno-PIC -fno-asynchronous-unwind-tables -fno-stack-protector"
    CFLAGS="$CFLAGS -fno-unwind-tables -fno-semantic-interposition -U_FORTIFY_SOURCE -fno-common"
    CFLAGS="$CFLAGS -DANDROID"
    CFLAGS="$CFLAGS --target=aarch64-linux-android35"

    INCLUDE="-I$KPM_DIR -I$KPM_DIR/include -I$KPM_DIR/patch/include"
    INCLUDE="$INCLUDE -I$KPM_DIR/linux -I$KPM_DIR/linux/include"
    INCLUDE="$INCLUDE -I$KPM_DIR/linux/arch/arm64/include"
    INCLUDE="$INCLUDE -I$KPM_DIR/linux/tools/arch/arm64/include"
    INCLUDE="$INCLUDE -I$KPM_DIR/kernel-source"

    KPM_SRCS=""
    for dir in base patch/common patch/module patch/ksyms patch/android; do
        for f in "$KPM_DIR/$dir"/*.c "$KPM_DIR/$dir"/*.S; do
            [ -f "$f" ] 2>/dev/null && KPM_SRCS="$KPM_SRCS $f"
        done
    done
    KPM_SRCS="$KPM_SRCS $KPM_DIR/patch/patch.c"

    KPM_OBJS=""
    for src in $KPM_SRCS; do
        obj="${src%.c}.o"
        obj="${obj%.S}.o"
        KPM_OBJS="$KPM_OBJS $obj"
        if [ ! -f "$obj" ] || [ "$src" -nt "$obj" ]; then
            echo "  [KPM] CC $(basename $src)"
            $CC $CFLAGS $INCLUDE -c -O2 -o "$obj" "$src" 2>&1 || {
                echo "  [KPM] WARNING: $(basename $src) failed, retrying with relaxed flags"
                $CC $CFLAGS $INCLUDE -c -O2 -Wno-int-conversion -Wno-implicit-function-declaration -o "$obj" "$src" 2>&1 || echo "  [KPM] SKIPPED: $(basename $src)"
            }
        fi
    done

    echo "  [KPM] LD kpimg.elf"
    $LD -nostdlib -static -no-pie --unresolved-symbols=ignore-all -T"$KPM_DIR/kpimg.lds" -e start -o "$KPM_DIR/kpimg.elf" $KPM_OBJS 2>&1 || echo "  [KPM] WARNING: kpimg link failed (non-fatal)"

    if [ -f "$KPM_DIR/kpimg.elf" ]; then
        echo "  [KPM] OBJCOPY kpimg"
        $OBJCOPY -O binary -S "$KPM_DIR/kpimg.elf" "$KPM_DIR/kpimg" 2>&1 || true
    fi

    if [ -f "$KPM_DIR/kpimg" ]; then
        echo "  [KPM] Built: $(ls -lh $KPM_DIR/kpimg | awk '{print $5}')"
    else
        echo "  [KPM] kpimg not built (source may need adaptation)"
    fi
else
    echo "KPM source not found, skipping"
fi

echo ""
echo "====================================="
echo "Step 3: Building Kernel"
echo "====================================="
make ${MAKE_ARGS} || {
    echo "Build failed! Check $BUILD_LOG for details"
    exit 1
}

echo ""
echo "====================================="
echo "Step 4: Packaging with AnyKernel3"
echo "====================================="
if [ -f out/arch/arm64/boot/Image.gz-dtb ]; then
    ZIP_NAME="Jiro_kernel-$(date +%Y%m%d)-beryllium-4.19.zip"
    rm -rf anykernel_out
    cp -r Anykernel3 anykernel_out
    rm -rf anykernel_out/.git anykernel_out/.github anykernel_out/LICENSE anykernel_out/README.md
    cp out/arch/arm64/boot/Image.gz-dtb anykernel_out/
    cd anykernel_out
    zip -r9 "../$ZIP_NAME" . -x '.git/*'
    cd ..
    rm -rf anykernel_out
    echo "Kernel zip: $ZIP_NAME"
else
    echo "Kernel image not found!"
    exit 1
fi

echo ""
echo "====================================="
echo "Build Completed Successfully: $(date)"
echo "Build Log: $BUILD_LOG"
echo "====================================="
