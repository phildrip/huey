#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

ZIG="${ZIG:-/home/phil/.local/bin/zig}"
ANDROID_SDK="${ANDROID_SDK:-/home/phil/Android/Sdk}"
NDK="${NDK:-$ANDROID_SDK/ndk/21.1.6352462}"
BUILD_TOOLS="${BUILD_TOOLS:-$ANDROID_SDK/build-tools/35.0.0}"
PLATFORM_JAR="${PLATFORM_JAR:-$ANDROID_SDK/platforms/android-25/android.jar}"

echo "[0/5] Running unit tests..."
"$ZIG" test "$REPO_ROOT/src/core_test.zig"
"$ZIG" test "$REPO_ROOT/src/glyph_atlas_test.zig" -I"$REPO_ROOT/vendor" "$REPO_ROOT/src/stb_truetype_impl.c" -lc -lm
"$ZIG" test "$REPO_ROOT/src/events_test.zig"
"$ZIG" test "$REPO_ROOT/src/headless_test.zig"
"$ZIG" test "$REPO_ROOT/src/focus_test.zig"
"$ZIG" test "$REPO_ROOT/src/layout_test.zig"
"$ZIG" test "$REPO_ROOT/src/clip_ime_test.zig"
"$ZIG" test "$REPO_ROOT/src/virtual_scroll_test.zig"
"$ZIG" test "$REPO_ROOT/src/reconcile_test.zig"
"$ZIG" test "$REPO_ROOT/src/async_queue_test.zig"
"$ZIG" test "$REPO_ROOT/src/tokens_test.zig"
"$ZIG" test "$REPO_ROOT/src/theme_test.zig"
"$ZIG" test "$REPO_ROOT/src/c_abi_test.zig" -I"$REPO_ROOT/include" -lc
"$ZIG" test "$REPO_ROOT/src/declarative_test.zig"
"$ZIG" test "$REPO_ROOT/src/text_edit_test.zig"
"$ZIG" test "$REPO_ROOT/src/a11y_test.zig"
"$ZIG" test "$REPO_ROOT/src/image_atlas_test.zig"
"$ZIG" test "$REPO_ROOT/src/ipc_bridge_test.zig"
"$ZIG" test "$REPO_ROOT/src/touch_ergonomics_test.zig"
"$ZIG" test "$REPO_ROOT/src/color_pipeline_test.zig"
"$ZIG" test "$REPO_ROOT/src/wearos_test.zig"
"$ZIG" test "$REPO_ROOT/src/wear_circular_test.zig"
"$ZIG" test "$REPO_ROOT/src/hold_confirm_test.zig"
"$ZIG" test "$REPO_ROOT/src/text_input_test.zig"
"$ZIG" test "$REPO_ROOT/src/controls_test.zig"
"$ZIG" test "$REPO_ROOT/src/primitives_test.zig"
"$ZIG" test "$REPO_ROOT/src/android_platform_test.zig"
"$ZIG" test "$REPO_ROOT/src/multi_window_test.zig"
"$ZIG" test "$REPO_ROOT/src/wayland_test.zig"
"$ZIG" test "$REPO_ROOT/src/workbench_test.zig"
"$ZIG" test "$REPO_ROOT/src/overlay_test.zig"
"$ZIG" test "$REPO_ROOT/src/animation_test.zig"
"$ZIG" test --dep huey -Mroot="$REPO_ROOT/demos/stratifi-bar/stratifi_demo_test.zig" -Mhuey="$REPO_ROOT/src/huey.zig"
"$ZIG" test --dep huey -I"$REPO_ROOT/vendor" -lc -lm "$REPO_ROOT/src/stb_truetype_impl.c" -Mroot="$SCRIPT_DIR/showcase_scene_test.zig" -Mhuey="$REPO_ROOT/src/huey.zig"

SYSROOT_INC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include"
TARGET_INC="$SYSROOT_INC/aarch64-linux-android"
NDK_LIBS="$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/24"

BUILD_DIR="$REPO_ROOT/build"
APK_STAGING="$BUILD_DIR/apk"
LIB_OUT="$APK_STAGING/lib/arm64-v8a/libhuey.so"
KEYSTORE="$BUILD_DIR/debug.keystore"
UNALIGNED_APK="$BUILD_DIR/huey-unaligned.apk"
ALIGNED_APK="$BUILD_DIR/huey-aligned.apk"
FINAL_APK="$BUILD_DIR/huey-showcase.apk"

rm -f "$APK_STAGING/lib/arm64-v8a/libziggui.so"
mkdir -p "$APK_STAGING/lib/arm64-v8a"

cat > "$BUILD_DIR/android-libc.txt" <<EOF
include_dir=$SYSROOT_INC
sys_include_dir=$TARGET_INC
cc_dir=$NDK_LIBS
crt_dir=$NDK_LIBS
msvc_lib_dir=
kernel32_lib_dir=
darwin_sdk_dir=
EOF

echo "[1/5] Compiling libhuey.so (aarch64-linux-android, ReleaseSmall)..."
"$ZIG" build-lib \
  -dynamic \
  -fPIC \
  -fstrip \
  --libc "$BUILD_DIR/android-libc.txt" \
  -fsoname=libhuey.so \
  -femit-bin="$LIB_OUT" \
  -target aarch64-linux-android.24 \
  -O ReleaseSmall \
  --dep huey \
  -I"$REPO_ROOT/vendor" \
  -I"$SYSROOT_INC" \
  -L"$NDK_LIBS" \
  -lc -lm -landroid -llog -lEGL -lGLESv3 \
  "$REPO_ROOT/src/sokol_impl.c" \
  "$REPO_ROOT/src/stb_truetype_impl.c" \
  -Mroot="$SCRIPT_DIR/android_main.zig" \
  -target aarch64-linux-android.24 \
  -O ReleaseSmall \
  -Mhuey="$REPO_ROOT/src/huey.zig"

echo "[2/5] Compiling resources & linking base APK with aapt2..."
rm -f "$UNALIGNED_APK" "$ALIGNED_APK" "$FINAL_APK" "$BUILD_DIR/res.zip"
"$BUILD_TOOLS/aapt2" compile --dir "$SCRIPT_DIR/res" -o "$BUILD_DIR/res.zip"
"$BUILD_TOOLS/aapt2" link \
  -I "$PLATFORM_JAR" \
  --manifest "$SCRIPT_DIR/AndroidManifest.xml" \
  -R "$BUILD_DIR/res.zip" \
  -o "$UNALIGNED_APK"

echo "[3/5] Packaging uncompressed native library into APK (extractNativeLibs=false)..."
(
  cd "$APK_STAGING"
  zip -0 -u -r "$UNALIGNED_APK" lib/arm64-v8a/libhuey.so
)

echo "[4/5] Aligning APK with zipalign (-p 4 for 4096-byte page alignment)..."
"$BUILD_TOOLS/zipalign" -f -p 4 "$UNALIGNED_APK" "$ALIGNED_APK"
"$BUILD_TOOLS/zipalign" -c -p 4 "$ALIGNED_APK"

echo "[5/5] Signing APK with debug keystore..."
if [[ ! -f "$KEYSTORE" ]]; then
  keytool -genkeypair -v \
    -keystore "$KEYSTORE" \
    -storepass android \
    -alias androiddebugkey \
    -keypass android \
    -keyalg RSA \
    -keysize 2048 \
    -validity 10000 \
    -dname "CN=Android Debug,O=Android,C=US"
fi

"$BUILD_TOOLS/apksigner" sign \
  --ks "$KEYSTORE" \
  --ks-pass pass:android \
  --ks-key-alias androiddebugkey \
  --key-pass pass:android \
  --out "$FINAL_APK" \
  "$ALIGNED_APK"

"$BUILD_TOOLS/apksigner" verify --verbose "$FINAL_APK"

echo ""
echo "=== Build Succeeded ==="
ls -lh "$LIB_OUT" "$FINAL_APK"
stat -c "%n: %s bytes" "$LIB_OUT" "$FINAL_APK"
