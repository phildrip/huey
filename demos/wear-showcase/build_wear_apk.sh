#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

ZIG="${ZIG:-/home/phil/.local/bin/zig}"
ANDROID_SDK="${ANDROID_SDK:-/home/phil/Android/Sdk}"
NDK="${NDK:-$ANDROID_SDK/ndk/21.1.6352462}"
BUILD_TOOLS="${BUILD_TOOLS:-$ANDROID_SDK/build-tools/35.0.0}"
PLATFORM_JAR="${PLATFORM_JAR:-$ANDROID_SDK/platforms/android-34/android.jar}"

echo "[0/5] Running Wear OS showcase, theme & animation unit tests..."
"$ZIG" test "$REPO_ROOT/src/theme_test.zig"
"$ZIG" test "$REPO_ROOT/src/animation_test.zig"
"$ZIG" test "$REPO_ROOT/src/wearos_test.zig"
"$ZIG" test "$REPO_ROOT/src/wear_circular_test.zig"
"$ZIG" test "$REPO_ROOT/src/hold_confirm_test.zig"
"$ZIG" test "$REPO_ROOT/src/text_input_test.zig"
"$ZIG" test "$REPO_ROOT/src/controls_test.zig"
"$ZIG" test "$REPO_ROOT/src/primitives_test.zig"
"$ZIG" test "$REPO_ROOT/src/android_platform_test.zig"
"$ZIG" test --dep huey -I"$REPO_ROOT/vendor" -lc -lm "$REPO_ROOT/src/stb_truetype_impl.c" -Mroot="$SCRIPT_DIR/wear_showcase_scene_test.zig" -Mhuey="$REPO_ROOT/src/huey.zig"

SYSROOT_INC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include"
TARGET_INC="$SYSROOT_INC/arm-linux-androideabi"
NDK_LIBS="$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/arm-linux-androideabi/24"

BUILD_DIR="$REPO_ROOT/build"
APK_STAGING="$BUILD_DIR/wear-apk"
LIB_OUT="$APK_STAGING/lib/armeabi-v7a/libhuey.so"
KEYSTORE="$BUILD_DIR/debug.keystore"
UNALIGNED_APK="$BUILD_DIR/huey-wear-unaligned.apk"
ALIGNED_APK="$BUILD_DIR/huey-wear-aligned.apk"
FINAL_APK="$BUILD_DIR/huey-wear.apk"

rm -f "$APK_STAGING/lib/armeabi-v7a/libziggui.so"
mkdir -p "$APK_STAGING/lib/armeabi-v7a"

cat > "$BUILD_DIR/android-wear-libc.txt" <<EOF
include_dir=$SYSROOT_INC
sys_include_dir=$TARGET_INC
cc_dir=$NDK_LIBS
crt_dir=$NDK_LIBS
msvc_lib_dir=
kernel32_lib_dir=
darwin_sdk_dir=
EOF

echo "[1/5] Compiling libhuey.so (arm-linux-androideabi.24, ReleaseSmall)..."
"$ZIG" build-lib \
  -dynamic \
  -fPIC \
  -fstrip \
  --libc "$BUILD_DIR/android-wear-libc.txt" \
  -fsoname=libhuey.so \
  -femit-bin="$LIB_OUT" \
  -target arm-linux-androideabi.24 \
  -O ReleaseSmall \
  --dep android_main \
  -I"$REPO_ROOT/vendor" \
  -I"$SYSROOT_INC" \
  -L"$NDK_LIBS" \
  -lc -lm -landroid -llog -lEGL -lGLESv3 \
  "$REPO_ROOT/src/sokol_impl.c" \
  "$REPO_ROOT/src/stb_truetype_impl.c" \
  -Mroot="$SCRIPT_DIR/wear_entry.zig" \
  -target arm-linux-androideabi.24 \
  -O ReleaseSmall \
  --dep huey \
  --dep wear_showcase \
  -Mandroid_main="$REPO_ROOT/demos/android-showcase/android_main.zig" \
  -target arm-linux-androideabi.24 \
  -O ReleaseSmall \
  --dep huey \
  -Mwear_showcase="$SCRIPT_DIR/wear_showcase_scene.zig" \
  -target arm-linux-androideabi.24 \
  -O ReleaseSmall \
  -Mhuey="$REPO_ROOT/src/huey.zig"

echo "[2/5] Compiling Wear OS resources & linking base APK with aapt2 (android-34)..."
rm -f "$UNALIGNED_APK" "$ALIGNED_APK" "$FINAL_APK" "$BUILD_DIR/res-wear.zip"
"$BUILD_TOOLS/aapt2" compile --dir "$SCRIPT_DIR/res" -o "$BUILD_DIR/res-wear.zip"
"$BUILD_TOOLS/aapt2" link \
  -I "$PLATFORM_JAR" \
  --manifest "$SCRIPT_DIR/AndroidManifestWear.xml" \
  -R "$BUILD_DIR/res-wear.zip" \
  -o "$UNALIGNED_APK"

echo "[3/5] Packaging uncompressed native library into Wear OS APK (extractNativeLibs=false)..."
(
  cd "$APK_STAGING"
  zip -0 -u -r "$UNALIGNED_APK" lib/armeabi-v7a/libhuey.so
)

echo "[4/5] Aligning Wear OS APK with zipalign (-p 4 for 4096-byte page alignment)..."
"$BUILD_TOOLS/zipalign" -f -p 4 "$UNALIGNED_APK" "$ALIGNED_APK"
"$BUILD_TOOLS/zipalign" -c -p 4 "$ALIGNED_APK"

echo "[5/5] Signing Wear OS APK with debug keystore..."
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
echo "=== Wear OS Build Succeeded ==="
ls -lh "$LIB_OUT" "$FINAL_APK"
stat -c "%n: %s bytes" "$LIB_OUT" "$FINAL_APK"
