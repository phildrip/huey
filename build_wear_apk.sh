#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

ZIG="${ZIG:-/home/phil/.local/bin/zig}"
ANDROID_SDK="${ANDROID_SDK:-/home/phil/Android/Sdk}"
NDK="${NDK:-$ANDROID_SDK/ndk/21.1.6352462}"
BUILD_TOOLS="${BUILD_TOOLS:-$ANDROID_SDK/build-tools/35.0.0}"
PLATFORM_JAR="${PLATFORM_JAR:-$ANDROID_SDK/platforms/android-34/android.jar}"

echo "[0/5] Running Wear OS showcase, theme & animation unit tests..."
"$ZIG" test "$ROOT_DIR/src/theme_test.zig"
"$ZIG" test "$ROOT_DIR/src/animation_test.zig"
"$ZIG" test "$ROOT_DIR/src/wearos_test.zig"
"$ZIG" test "$ROOT_DIR/src/wear_circular_test.zig"
"$ZIG" test "$ROOT_DIR/src/wear_showcase_scene_test.zig" -I"$ROOT_DIR/vendor" "$ROOT_DIR/src/stb_truetype_impl.c" -lc -lm

SYSROOT_INC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include"
TARGET_INC="$SYSROOT_INC/arm-linux-androideabi"
NDK_LIBS="$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/arm-linux-androideabi/24"

BUILD_DIR="$ROOT_DIR/build"
APK_STAGING="$BUILD_DIR/wear-apk"
LIB_OUT="$APK_STAGING/lib/armeabi-v7a/libziggui.so"
KEYSTORE="$BUILD_DIR/debug.keystore"
UNALIGNED_APK="$BUILD_DIR/ziggui-wear-unaligned.apk"
ALIGNED_APK="$BUILD_DIR/ziggui-wear-aligned.apk"
FINAL_APK="$BUILD_DIR/ziggui-wear.apk"

mkdir -p "$APK_STAGING/lib/armeabi-v7a"

cat > "$BUILD_DIR/android-wear-libc.txt" <<EOF
include_dir=$SYSROOT_INC
sys_include_dir=$TARGET_INC
crt_dir=$NDK_LIBS
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=
EOF

echo "[1/5] Compiling libziggui.so (arm-linux-androideabi.24, ReleaseSmall)..."
"$ZIG" build-lib \
  -target arm-linux-androideabi.24 \
  -O ReleaseSmall \
  -dynamic \
  -fPIC \
  -fstrip \
  --libc "$BUILD_DIR/android-wear-libc.txt" \
  -I"$ROOT_DIR/vendor" \
  -I"$SYSROOT_INC" \
  -L"$NDK_LIBS" \
  -lc -lm -landroid -llog -lEGL -lGLESv3 \
  -fsoname=libziggui.so \
  -femit-bin="$LIB_OUT" \
  "$ROOT_DIR/src/wear_entry.zig" \
  "$ROOT_DIR/src/sokol_impl.c" \
  "$ROOT_DIR/src/stb_truetype_impl.c"

echo "[2/5] Linking base Wear OS APK with aapt2 (android-34)..."
rm -f "$UNALIGNED_APK" "$ALIGNED_APK" "$FINAL_APK"
"$BUILD_TOOLS/aapt2" link \
  -I "$PLATFORM_JAR" \
  --manifest "$ROOT_DIR/AndroidManifestWear.xml" \
  -o "$UNALIGNED_APK"

echo "[3/5] Packaging uncompressed native library into Wear OS APK (extractNativeLibs=false)..."
(
  cd "$APK_STAGING"
  zip -0 -u -r "$UNALIGNED_APK" lib/armeabi-v7a/libziggui.so
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
