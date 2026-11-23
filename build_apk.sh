#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

ZIG="${ZIG:-/home/phil/.local/bin/zig}"
ANDROID_SDK="${ANDROID_SDK:-/home/phil/Android/Sdk}"
NDK="${NDK:-$ANDROID_SDK/ndk/21.1.6352462}"
BUILD_TOOLS="${BUILD_TOOLS:-$ANDROID_SDK/build-tools/35.0.0}"
PLATFORM_JAR="${PLATFORM_JAR:-$ANDROID_SDK/platforms/android-25/android.jar}"

echo "[0/5] Running unit tests (src/core_test.zig, src/glyph_atlas_test.zig, src/events_test.zig, src/headless_test.zig, src/focus_test.zig, src/layout_test.zig, src/clip_ime_test.zig, & src/virtual_scroll_test.zig)..."
"$ZIG" test "$ROOT_DIR/src/core_test.zig"
"$ZIG" test "$ROOT_DIR/src/glyph_atlas_test.zig" -I"$ROOT_DIR/vendor" "$ROOT_DIR/src/stb_truetype_impl.c" -lc -lm
"$ZIG" test "$ROOT_DIR/src/events_test.zig"
"$ZIG" test "$ROOT_DIR/src/headless_test.zig"
"$ZIG" test "$ROOT_DIR/src/focus_test.zig"
"$ZIG" test "$ROOT_DIR/src/layout_test.zig"
"$ZIG" test "$ROOT_DIR/src/clip_ime_test.zig"
"$ZIG" test "$ROOT_DIR/src/virtual_scroll_test.zig"
"$ZIG" test "$ROOT_DIR/src/reconcile_test.zig"
"$ZIG" test "$ROOT_DIR/src/async_queue_test.zig"
"$ZIG" test "$ROOT_DIR/src/tokens_test.zig"
"$ZIG" test "$ROOT_DIR/src/c_abi_test.zig" -I"$ROOT_DIR/include" -lc
"$ZIG" test "$ROOT_DIR/src/declarative_test.zig"
"$ZIG" test "$ROOT_DIR/src/text_edit_test.zig"
"$ZIG" test "$ROOT_DIR/src/a11y_test.zig"
"$ZIG" test "$ROOT_DIR/src/image_atlas_test.zig"
"$ZIG" test "$ROOT_DIR/src/ipc_bridge_test.zig"
"$ZIG" test "$ROOT_DIR/src/touch_ergonomics_test.zig"
"$ZIG" test "$ROOT_DIR/src/color_pipeline_test.zig"
"$ZIG" test "$ROOT_DIR/src/wearos_test.zig"
"$ZIG" test "$ROOT_DIR/src/multi_window_test.zig"
"$ZIG" test "$ROOT_DIR/src/wayland_test.zig"
"$ZIG" test "$ROOT_DIR/src/workbench_test.zig"
"$ZIG" test "$ROOT_DIR/src/overlay_test.zig"
"$ZIG" test "$ROOT_DIR/src/bloxwm_demo_test.zig"
"$ZIG" test "$ROOT_DIR/src/showcase_scene_test.zig" -I"$ROOT_DIR/vendor" "$ROOT_DIR/src/stb_truetype_impl.c" -lc -lm

SYSROOT_INC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include"
TARGET_INC="$SYSROOT_INC/aarch64-linux-android"
NDK_LIBS="$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/24"

BUILD_DIR="$ROOT_DIR/build"
APK_STAGING="$BUILD_DIR/apk"
LIB_OUT="$APK_STAGING/lib/arm64-v8a/libziggui.so"
KEYSTORE="$BUILD_DIR/debug.keystore"
UNALIGNED_APK="$BUILD_DIR/ziggui-unaligned.apk"
ALIGNED_APK="$BUILD_DIR/ziggui-aligned.apk"
FINAL_APK="$BUILD_DIR/ziggui-spike.apk"

mkdir -p "$APK_STAGING/lib/arm64-v8a"

cat > "$BUILD_DIR/android-libc.txt" <<EOF
include_dir=$SYSROOT_INC
sys_include_dir=$TARGET_INC
crt_dir=$NDK_LIBS
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=
EOF

echo "[1/5] Compiling libziggui.so (aarch64-linux-android, ReleaseSmall)..."
"$ZIG" build-lib \
  -target aarch64-linux-android.24 \
  -O ReleaseSmall \
  -dynamic \
  -fPIC \
  -fstrip \
  --libc "$BUILD_DIR/android-libc.txt" \
  -I"$ROOT_DIR/vendor" \
  -I"$SYSROOT_INC" \
  -L"$NDK_LIBS" \
  -lc -lm -landroid -llog -lEGL -lGLESv3 \
  -fsoname=libziggui.so \
  -femit-bin="$LIB_OUT" \
  "$ROOT_DIR/src/android_main.zig" \
  "$ROOT_DIR/src/sokol_impl.c" \
  "$ROOT_DIR/src/stb_truetype_impl.c"

echo "[2/5] Linking base APK with aapt2..."
rm -f "$UNALIGNED_APK" "$ALIGNED_APK" "$FINAL_APK"
"$BUILD_TOOLS/aapt2" link \
  -I "$PLATFORM_JAR" \
  --manifest "$ROOT_DIR/AndroidManifest.xml" \
  -o "$UNALIGNED_APK"

echo "[3/5] Packaging uncompressed native library into APK (extractNativeLibs=false)..."
(
  cd "$APK_STAGING"
  zip -0 -u -r "$UNALIGNED_APK" lib/arm64-v8a/libziggui.so
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
