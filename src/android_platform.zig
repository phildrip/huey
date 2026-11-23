const std = @import("std");
const builtin = @import("builtin");

pub const is_android: bool = builtin.abi.isAndroid();

/// Haptic feedback kinds mapped to bounded durations and pulse patterns.
pub const HapticKind = enum {
    tap,
    confirm,
    double_pulse,
    err,
};

const TAP_PATTERN = [_]u32{ 0, 18 };
const CONFIRM_PATTERN = [_]u32{ 0, 45 };
const DOUBLE_PULSE_PATTERN = [_]u32{ 0, 28, 60, 28 };
const ERR_PATTERN = [_]u32{ 0, 80, 45, 80 };

/// Returns the single-shot vibration duration in milliseconds for `kind`.
pub fn hapticDurationMs(kind: HapticKind) u32 {
    return switch (kind) {
        .tap => 18,
        .confirm => 45,
        .double_pulse => 30,
        .err => 80,
    };
}

/// Returns a `[delay, on, off, on, ...]` timing pattern in milliseconds for `kind`.
pub fn hapticPattern(kind: HapticKind) []const u32 {
    return switch (kind) {
        .tap => &TAP_PATTERN,
        .confirm => &CONFIRM_PATTERN,
        .double_pulse => &DOUBLE_PULSE_PATTERN,
        .err => &ERR_PATTERN,
    };
}

/// Idempotent visibility tracker for the Android soft keyboard IME.
pub const SoftKeyboardState = struct {
    visible: bool = false,

    pub fn init() SoftKeyboardState {
        return .{};
    }

    /// Transitions state to visible. Returns `true` only on a `false -> true` change.
    pub fn requestShow(self: *SoftKeyboardState) bool {
        if (self.visible) return false;
        self.visible = true;
        return true;
    }

    /// Transitions state to hidden. Returns `true` only on a `true -> false` change.
    pub fn requestHide(self: *SoftKeyboardState) bool {
        if (!self.visible) return false;
        self.visible = false;
        return true;
    }

    /// Synchronizes visibility with the actual platform IME state.
    pub fn syncVisible(self: *SoftKeyboardState, vis: bool) void {
        self.visible = vis;
    }
};

/// Maps Android `AKEYCODE_*` values to ASCII bytes for text/VIN/MAC entry, or `null` if unmapped.
pub fn androidKeycodeToAscii(keycode: i32, shifted: bool) ?u8 {
    // AKEYCODE_0 (7) .. AKEYCODE_9 (16)
    if (keycode >= 7 and keycode <= 16) {
        return '0' + @as(u8, @intCast(keycode - 7));
    }
    // AKEYCODE_NUMPAD_0 (144) .. AKEYCODE_NUMPAD_9 (153)
    if (keycode >= 144 and keycode <= 153) {
        return '0' + @as(u8, @intCast(keycode - 144));
    }
    // AKEYCODE_A (29) .. AKEYCODE_Z (54)
    if (keycode >= 29 and keycode <= 54) {
        const base: u8 = if (shifted) 'A' else 'a';
        return base + @as(u8, @intCast(keycode - 29));
    }
    return switch (keycode) {
        55 => ',', // AKEYCODE_COMMA
        56 => '.', // AKEYCODE_PERIOD
        62 => ' ', // AKEYCODE_SPACE
        69 => if (shifted) '_' else '-', // AKEYCODE_MINUS
        74 => if (shifted) ':' else ';', // AKEYCODE_SEMICOLON
        else => null,
    };
}

/// Returns `true` for Android `AKEYCODE_DEL` (67).
pub fn isAndroidBackspace(keycode: i32) bool {
    return keycode == 67;
}

/// Returns `true` for Android `AKEYCODE_ENTER` (66) or `AKEYCODE_NUMPAD_ENTER` (160).
pub fn isAndroidEnter(keycode: i32) bool {
    return keycode == 66 or keycode == 160;
}

/// Idempotent tracker for `AWINDOW_FLAG_KEEP_SCREEN_ON`.
pub const KeepScreenOnState = struct {
    enabled: bool = false,

    pub fn init() KeepScreenOnState {
        return .{};
    }

    /// Updates the keep-screen-on state. Returns `true` only when the state changes.
    pub fn setEnabled(self: *KeepScreenOnState, on: bool) bool {
        if (self.enabled == on) return false;
        self.enabled = on;
        return true;
    }
};

// ---------------------------------------------------------------------------
// Android NDK & JNI ABI definitions (verified against NDK 21 jni.h / native_activity.h)
// ---------------------------------------------------------------------------

const AWINDOW_FLAG_KEEP_SCREEN_ON: u32 = 0x00000080;
const ANATIVEACTIVITY_SHOW_SOFT_INPUT_IMPLICIT: u32 = 0x0001;
const ANATIVEACTIVITY_SHOW_SOFT_INPUT_FORCED: u32 = 0x0002;

const JNI_VERSION_1_6: i32 = 0x00010006;
const JNI_OK: i32 = 0;
const JNI_EDETACHED: i32 = -2;

const jobject = ?*anyopaque;
const jclass = ?*anyopaque;
const jstring = ?*anyopaque;
const jlongArray = ?*anyopaque;
const jmethodID = ?*anyopaque;
const jboolean = u8;
const jint = i32;
const jlong = i64;
const jsize = i32;

const jvalue = extern union {
    z: jboolean,
    b: i8,
    c: u16,
    s: i16,
    i: jint,
    j: jlong,
    f: f32,
    d: f64,
    l: jobject,
};

const JNIEnvPtr = *const *const JNINativeInterface;
const JavaVMPtr = *const *const JNIInvokeInterface;

const JNIInvokeInterface = extern struct {
    reserved0: ?*anyopaque,
    reserved1: ?*anyopaque,
    reserved2: ?*anyopaque,
    DestroyJavaVM: ?*const fn (JavaVMPtr) callconv(.c) jint,
    AttachCurrentThread: ?*const fn (JavaVMPtr, *?JNIEnvPtr, ?*anyopaque) callconv(.c) jint,
    DetachCurrentThread: ?*const fn (JavaVMPtr) callconv(.c) jint,
    GetEnv: ?*const fn (JavaVMPtr, *?*anyopaque, jint) callconv(.c) jint,
    AttachCurrentThreadAsDaemon: ?*const fn (JavaVMPtr, *?JNIEnvPtr, ?*anyopaque) callconv(.c) jint,
};

const JNINativeInterface = extern struct {
    reserved0: ?*anyopaque,
    reserved1: ?*anyopaque,
    reserved2: ?*anyopaque,
    reserved3: ?*anyopaque,
    GetVersion: ?*const anyopaque,
    DefineClass: ?*const anyopaque,
    FindClass: ?*const fn (JNIEnvPtr, [*:0]const u8) callconv(.c) jclass,
    FromReflectedMethod: ?*const anyopaque,
    FromReflectedField: ?*const anyopaque,
    ToReflectedMethod: ?*const anyopaque,
    GetSuperclass: ?*const anyopaque,
    IsAssignableFrom: ?*const anyopaque,
    ToReflectedField: ?*const anyopaque,
    Throw: ?*const anyopaque,
    ThrowNew: ?*const anyopaque,
    ExceptionOccurred: ?*const anyopaque,
    ExceptionDescribe: ?*const anyopaque,
    ExceptionClear: ?*const fn (JNIEnvPtr) callconv(.c) void,
    FatalError: ?*const anyopaque,
    PushLocalFrame: ?*const anyopaque,
    PopLocalFrame: ?*const anyopaque,
    NewGlobalRef: ?*const anyopaque,
    DeleteGlobalRef: ?*const anyopaque,
    DeleteLocalRef: ?*const fn (JNIEnvPtr, jobject) callconv(.c) void,
    IsSameObject: ?*const anyopaque,
    NewLocalRef: ?*const anyopaque,
    EnsureLocalCapacity: ?*const anyopaque,
    AllocObject: ?*const anyopaque,
    NewObject: ?*const anyopaque,
    NewObjectV: ?*const anyopaque,
    NewObjectA: ?*const anyopaque,
    GetObjectClass: ?*const fn (JNIEnvPtr, jobject) callconv(.c) jclass,
    IsInstanceOf: ?*const anyopaque,
    GetMethodID: ?*const fn (JNIEnvPtr, jclass, [*:0]const u8, [*:0]const u8) callconv(.c) jmethodID,
    CallObjectMethod: ?*const anyopaque,
    CallObjectMethodV: ?*const anyopaque,
    CallObjectMethodA: ?*const fn (JNIEnvPtr, jobject, jmethodID, [*]const jvalue) callconv(.c) jobject,
    CallBooleanMethod: ?*const anyopaque,
    CallBooleanMethodV: ?*const anyopaque,
    CallBooleanMethodA: ?*const fn (JNIEnvPtr, jobject, jmethodID, [*]const jvalue) callconv(.c) jboolean,
    CallByteMethod: ?*const anyopaque,
    CallByteMethodV: ?*const anyopaque,
    CallByteMethodA: ?*const anyopaque,
    CallCharMethod: ?*const anyopaque,
    CallCharMethodV: ?*const anyopaque,
    CallCharMethodA: ?*const anyopaque,
    CallShortMethod: ?*const anyopaque,
    CallShortMethodV: ?*const anyopaque,
    CallShortMethodA: ?*const anyopaque,
    CallIntMethod: ?*const anyopaque,
    CallIntMethodV: ?*const anyopaque,
    CallIntMethodA: ?*const anyopaque,
    CallLongMethod: ?*const anyopaque,
    CallLongMethodV: ?*const anyopaque,
    CallLongMethodA: ?*const anyopaque,
    CallFloatMethod: ?*const anyopaque,
    CallFloatMethodV: ?*const anyopaque,
    CallFloatMethodA: ?*const anyopaque,
    CallDoubleMethod: ?*const anyopaque,
    CallDoubleMethodV: ?*const anyopaque,
    CallDoubleMethodA: ?*const anyopaque,
    CallVoidMethod: ?*const anyopaque,
    CallVoidMethodV: ?*const anyopaque,
    CallVoidMethodA: ?*const fn (JNIEnvPtr, jobject, jmethodID, [*]const jvalue) callconv(.c) void,
    // CallNonvirtual* (30 slots)
    CallNonvirtualObjectMethod: ?*const anyopaque,
    CallNonvirtualObjectMethodV: ?*const anyopaque,
    CallNonvirtualObjectMethodA: ?*const anyopaque,
    CallNonvirtualBooleanMethod: ?*const anyopaque,
    CallNonvirtualBooleanMethodV: ?*const anyopaque,
    CallNonvirtualBooleanMethodA: ?*const anyopaque,
    CallNonvirtualByteMethod: ?*const anyopaque,
    CallNonvirtualByteMethodV: ?*const anyopaque,
    CallNonvirtualByteMethodA: ?*const anyopaque,
    CallNonvirtualCharMethod: ?*const anyopaque,
    CallNonvirtualCharMethodV: ?*const anyopaque,
    CallNonvirtualCharMethodA: ?*const anyopaque,
    CallNonvirtualShortMethod: ?*const anyopaque,
    CallNonvirtualShortMethodV: ?*const anyopaque,
    CallNonvirtualShortMethodA: ?*const anyopaque,
    CallNonvirtualIntMethod: ?*const anyopaque,
    CallNonvirtualIntMethodV: ?*const anyopaque,
    CallNonvirtualIntMethodA: ?*const anyopaque,
    CallNonvirtualLongMethod: ?*const anyopaque,
    CallNonvirtualLongMethodV: ?*const anyopaque,
    CallNonvirtualLongMethodA: ?*const anyopaque,
    CallNonvirtualFloatMethod: ?*const anyopaque,
    CallNonvirtualFloatMethodV: ?*const anyopaque,
    CallNonvirtualFloatMethodA: ?*const anyopaque,
    CallNonvirtualDoubleMethod: ?*const anyopaque,
    CallNonvirtualDoubleMethodV: ?*const anyopaque,
    CallNonvirtualDoubleMethodA: ?*const anyopaque,
    CallNonvirtualVoidMethod: ?*const anyopaque,
    CallNonvirtualVoidMethodV: ?*const anyopaque,
    CallNonvirtualVoidMethodA: ?*const anyopaque,
    GetFieldID: ?*const anyopaque,
    // Get*Field (9 slots)
    GetObjectField: ?*const anyopaque,
    GetBooleanField: ?*const anyopaque,
    GetByteField: ?*const anyopaque,
    GetCharField: ?*const anyopaque,
    GetShortField: ?*const anyopaque,
    GetIntField: ?*const anyopaque,
    GetLongField: ?*const anyopaque,
    GetFloatField: ?*const anyopaque,
    GetDoubleField: ?*const anyopaque,
    // Set*Field (9 slots)
    SetObjectField: ?*const anyopaque,
    SetBooleanField: ?*const anyopaque,
    SetByteField: ?*const anyopaque,
    SetCharField: ?*const anyopaque,
    SetShortField: ?*const anyopaque,
    SetIntField: ?*const anyopaque,
    SetLongField: ?*const anyopaque,
    SetFloatField: ?*const anyopaque,
    SetDoubleField: ?*const anyopaque,
    GetStaticMethodID: ?*const fn (JNIEnvPtr, jclass, [*:0]const u8, [*:0]const u8) callconv(.c) jmethodID,
    CallStaticObjectMethod: ?*const anyopaque,
    CallStaticObjectMethodV: ?*const anyopaque,
    CallStaticObjectMethodA: ?*const fn (JNIEnvPtr, jclass, jmethodID, [*]const jvalue) callconv(.c) jobject,
    // Remaining CallStatic* (27 slots)
    CallStaticBooleanMethod: ?*const anyopaque,
    CallStaticBooleanMethodV: ?*const anyopaque,
    CallStaticBooleanMethodA: ?*const anyopaque,
    CallStaticByteMethod: ?*const anyopaque,
    CallStaticByteMethodV: ?*const anyopaque,
    CallStaticByteMethodA: ?*const anyopaque,
    CallStaticCharMethod: ?*const anyopaque,
    CallStaticCharMethodV: ?*const anyopaque,
    CallStaticCharMethodA: ?*const anyopaque,
    CallStaticShortMethod: ?*const anyopaque,
    CallStaticShortMethodV: ?*const anyopaque,
    CallStaticShortMethodA: ?*const anyopaque,
    CallStaticIntMethod: ?*const anyopaque,
    CallStaticIntMethodV: ?*const anyopaque,
    CallStaticIntMethodA: ?*const anyopaque,
    CallStaticLongMethod: ?*const anyopaque,
    CallStaticLongMethodV: ?*const anyopaque,
    CallStaticLongMethodA: ?*const anyopaque,
    CallStaticFloatMethod: ?*const anyopaque,
    CallStaticFloatMethodV: ?*const anyopaque,
    CallStaticFloatMethodA: ?*const anyopaque,
    CallStaticDoubleMethod: ?*const anyopaque,
    CallStaticDoubleMethodV: ?*const anyopaque,
    CallStaticDoubleMethodA: ?*const anyopaque,
    CallStaticVoidMethod: ?*const anyopaque,
    CallStaticVoidMethodV: ?*const anyopaque,
    CallStaticVoidMethodA: ?*const anyopaque,
    GetStaticFieldID: ?*const anyopaque,
    // GetStatic*Field (9 slots)
    GetStaticObjectField: ?*const anyopaque,
    GetStaticBooleanField: ?*const anyopaque,
    GetStaticByteField: ?*const anyopaque,
    GetStaticCharField: ?*const anyopaque,
    GetStaticShortField: ?*const anyopaque,
    GetStaticIntField: ?*const anyopaque,
    GetStaticLongField: ?*const anyopaque,
    GetStaticFloatField: ?*const anyopaque,
    GetStaticDoubleField: ?*const anyopaque,
    // SetStatic*Field (9 slots)
    SetStaticObjectField: ?*const anyopaque,
    SetStaticBooleanField: ?*const anyopaque,
    SetStaticByteField: ?*const anyopaque,
    SetStaticCharField: ?*const anyopaque,
    SetStaticShortField: ?*const anyopaque,
    SetStaticIntField: ?*const anyopaque,
    SetStaticLongField: ?*const anyopaque,
    SetStaticFloatField: ?*const anyopaque,
    SetStaticDoubleField: ?*const anyopaque,
    NewString: ?*const anyopaque,
    GetStringLength: ?*const anyopaque,
    GetStringChars: ?*const anyopaque,
    ReleaseStringChars: ?*const anyopaque,
    NewStringUTF: ?*const fn (JNIEnvPtr, [*:0]const u8) callconv(.c) jstring,
    GetStringUTFLength: ?*const anyopaque,
    GetStringUTFChars: ?*const anyopaque,
    ReleaseStringUTFChars: ?*const anyopaque,
    GetArrayLength: ?*const anyopaque,
    NewObjectArray: ?*const anyopaque,
    GetObjectArrayElement: ?*const anyopaque,
    SetObjectArrayElement: ?*const anyopaque,
    NewBooleanArray: ?*const anyopaque,
    NewByteArray: ?*const anyopaque,
    NewCharArray: ?*const anyopaque,
    NewShortArray: ?*const anyopaque,
    NewIntArray: ?*const anyopaque,
    NewLongArray: ?*const fn (JNIEnvPtr, jsize) callconv(.c) jlongArray,
    NewFloatArray: ?*const anyopaque,
    NewDoubleArray: ?*const anyopaque,
    GetBooleanArrayElements: ?*const anyopaque,
    GetByteArrayElements: ?*const anyopaque,
    GetCharArrayElements: ?*const anyopaque,
    GetShortArrayElements: ?*const anyopaque,
    GetIntArrayElements: ?*const anyopaque,
    GetLongArrayElements: ?*const anyopaque,
    GetFloatArrayElements: ?*const anyopaque,
    GetDoubleArrayElements: ?*const anyopaque,
    ReleaseBooleanArrayElements: ?*const anyopaque,
    ReleaseByteArrayElements: ?*const anyopaque,
    ReleaseCharArrayElements: ?*const anyopaque,
    ReleaseShortArrayElements: ?*const anyopaque,
    ReleaseIntArrayElements: ?*const anyopaque,
    ReleaseLongArrayElements: ?*const anyopaque,
    ReleaseFloatArrayElements: ?*const anyopaque,
    ReleaseDoubleArrayElements: ?*const anyopaque,
    GetBooleanArrayRegion: ?*const anyopaque,
    GetByteArrayRegion: ?*const anyopaque,
    GetCharArrayRegion: ?*const anyopaque,
    GetShortArrayRegion: ?*const anyopaque,
    GetIntArrayRegion: ?*const anyopaque,
    GetLongArrayRegion: ?*const anyopaque,
    GetFloatArrayRegion: ?*const anyopaque,
    GetDoubleArrayRegion: ?*const anyopaque,
    SetBooleanArrayRegion: ?*const anyopaque,
    SetByteArrayRegion: ?*const anyopaque,
    SetCharArrayRegion: ?*const anyopaque,
    SetShortArrayRegion: ?*const anyopaque,
    SetIntArrayRegion: ?*const anyopaque,
    SetLongArrayRegion: ?*const fn (JNIEnvPtr, jlongArray, jsize, jsize, [*]const jlong) callconv(.c) void,
    SetFloatArrayRegion: ?*const anyopaque,
    SetDoubleArrayRegion: ?*const anyopaque,
    RegisterNatives: ?*const anyopaque,
    UnregisterNatives: ?*const anyopaque,
    MonitorEnter: ?*const anyopaque,
    MonitorExit: ?*const anyopaque,
    GetJavaVM: ?*const anyopaque,
    GetStringRegion: ?*const anyopaque,
    GetStringUTFRegion: ?*const anyopaque,
    GetPrimitiveArrayCritical: ?*const anyopaque,
    ReleasePrimitiveArrayCritical: ?*const anyopaque,
    GetStringCritical: ?*const anyopaque,
    ReleaseStringCritical: ?*const anyopaque,
    NewWeakGlobalRef: ?*const anyopaque,
    DeleteWeakGlobalRef: ?*const anyopaque,
    ExceptionCheck: ?*const fn (JNIEnvPtr) callconv(.c) jboolean,
    NewDirectByteBuffer: ?*const anyopaque,
    GetDirectBufferAddress: ?*const anyopaque,
    GetDirectBufferCapacity: ?*const anyopaque,
    GetObjectRefType: ?*const anyopaque,
};

const ANativeActivity = extern struct {
    callbacks: ?*anyopaque,
    vm: ?JavaVMPtr,
    env: ?JNIEnvPtr,
    clazz: jobject,
    internalDataPath: ?[*:0]const u8,
    externalDataPath: ?[*:0]const u8,
    sdkVersion: i32,
    instance: ?*anyopaque,
    assetManager: ?*anyopaque,
    obbPath: ?[*:0]const u8,
};

const NdkNativeActivity = if (is_android) struct {
    extern "android" fn ANativeActivity_setWindowFlags(activity: *anyopaque, addFlags: u32, removeFlags: u32) callconv(.c) void;
    extern "android" fn ANativeActivity_showSoftInput(activity: *anyopaque, flags: u32) callconv(.c) void;
    extern "android" fn ANativeActivity_hideSoftInput(activity: *anyopaque, flags: u32) callconv(.c) void;
} else struct {};

fn clearJniException(env: JNIEnvPtr) bool {
    const check_fn = env.*.*.ExceptionCheck orelse return false;
    if (check_fn(env) != 0) {
        if (env.*.*.ExceptionClear) |clear_fn| {
            clear_fn(env);
        }
        return true;
    }
    return false;
}

fn deleteLocalRef(env: JNIEnvPtr, ref: jobject) void {
    if (ref == null) return;
    if (env.*.*.DeleteLocalRef) |del_fn| {
        del_fn(env, ref);
    }
}

fn tryVibrateEffect(env: JNIEnvPtr, vibrator_obj: jobject, vib_cls: jclass, kind: HapticKind) bool {
    const find_class = env.*.*.FindClass orelse return false;
    const get_static_mid = env.*.*.GetStaticMethodID orelse return false;
    const call_static_obj = env.*.*.CallStaticObjectMethodA orelse return false;
    const get_mid = env.*.*.GetMethodID orelse return false;
    const call_void = env.*.*.CallVoidMethodA orelse return false;

    const ve_cls = find_class(env, "android/os/VibrationEffect");
    defer deleteLocalRef(env, ve_cls);
    if (clearJniException(env) or ve_cls == null) return false;

    var effect_obj: jobject = null;
    defer deleteLocalRef(env, effect_obj);
    const pattern = hapticPattern(kind);
    if (pattern.len > 2) {
        const new_long_array = env.*.*.NewLongArray orelse return false;
        const set_long_region = env.*.*.SetLongArrayRegion orelse return false;

        var timings: [8]jlong = undefined;
        const count = @min(pattern.len, timings.len);
        for (0..count) |i| {
            timings[i] = @intCast(pattern[i]);
        }

        const jarr = new_long_array(env, @intCast(count));
        defer deleteLocalRef(env, jarr);
        if (clearJniException(env) or jarr == null) return false;

        set_long_region(env, jarr, 0, @intCast(count), &timings);
        if (clearJniException(env)) return false;

        const create_wave_mid = get_static_mid(
            env,
            ve_cls,
            "createWaveform",
            "([JI)Landroid/os/VibrationEffect;",
        );
        if (clearJniException(env) or create_wave_mid == null) return false;

        const args = [_]jvalue{
            .{ .l = jarr },
            .{ .i = -1 }, // repeat = -1 (do not repeat)
        };
        effect_obj = call_static_obj(env, ve_cls, create_wave_mid, &args);
        if (clearJniException(env) or effect_obj == null) return false;
    } else {
        const create_one_shot_mid = get_static_mid(
            env,
            ve_cls,
            "createOneShot",
            "(JI)Landroid/os/VibrationEffect;",
        );
        if (clearJniException(env) or create_one_shot_mid == null) return false;

        const args = [_]jvalue{
            .{ .j = @intCast(hapticDurationMs(kind)) },
            .{ .i = -1 }, // VibrationEffect.DEFAULT_AMPLITUDE
        };
        effect_obj = call_static_obj(env, ve_cls, create_one_shot_mid, &args);
        if (clearJniException(env) or effect_obj == null) return false;
    }

    const vibrate_mid = get_mid(env, vib_cls, "vibrate", "(Landroid/os/VibrationEffect;)V");
    if (clearJniException(env) or vibrate_mid == null) return false;

    const vib_args = [_]jvalue{.{ .l = effect_obj }};
    call_void(env, vibrator_obj, vibrate_mid, &vib_args);
    return !clearJniException(env);
}

fn tryVibrateLegacy(env: JNIEnvPtr, vibrator_obj: jobject, vib_cls: jclass, kind: HapticKind) bool {
    const get_mid = env.*.*.GetMethodID orelse return false;
    const call_void = env.*.*.CallVoidMethodA orelse return false;

    const vibrate_mid = get_mid(env, vib_cls, "vibrate", "(J)V");
    if (clearJniException(env) or vibrate_mid == null) return false;

    const args = [_]jvalue{.{ .j = @intCast(hapticDurationMs(kind)) }};
    call_void(env, vibrator_obj, vibrate_mid, &args);
    return !clearJniException(env);
}

/// Native Android NDK and JNI platform bridge.
/// All methods compile cleanly as no-ops on non-Android hosts.
pub const AndroidBridge = struct {
    /// Sets or clears `AWINDOW_FLAG_KEEP_SCREEN_ON` on the given `ANativeActivity*`.
    pub fn setKeepScreenOnNative(activity: *anyopaque, enable: bool) void {
        if (comptime !is_android) return;
        if (enable) {
            NdkNativeActivity.ANativeActivity_setWindowFlags(activity, AWINDOW_FLAG_KEEP_SCREEN_ON, 0);
        } else {
            NdkNativeActivity.ANativeActivity_setWindowFlags(activity, 0, AWINDOW_FLAG_KEEP_SCREEN_ON);
        }
    }

    /// Requests the Android soft input keyboard to show implicitly for `ANativeActivity*`.
    /// Requests the Android soft input keyboard to show for `ANativeActivity*`.
    /// Uses JNI `InputMethodManager.toggleSoftInput(SHOW_FORCED, 0)` because
    /// `ANativeActivity_showSoftInput(..., SHOW_IMPLICIT)` is silently ignored on
    /// pure `NativeActivity` views across Android 7–14.
    pub fn showSoftInputNative(activity: *anyopaque) void {
        if (comptime !is_android) return;
        if (!toggleSoftInputJni(activity, true)) {
            NdkNativeActivity.ANativeActivity_showSoftInput(activity, ANATIVEACTIVITY_SHOW_SOFT_INPUT_FORCED);
        }
    }

    /// Requests the Android soft input keyboard to hide for `ANativeActivity*`.
    pub fn hideSoftInputNative(activity: *anyopaque) void {
        if (comptime !is_android) return;
        if (!toggleSoftInputJni(activity, false)) {
            NdkNativeActivity.ANativeActivity_hideSoftInput(activity, 0);
        }
    }

    fn toggleSoftInputJni(activity: *anyopaque, show: bool) bool {
        if (comptime !is_android) return false;
        const act: *const ANativeActivity = @ptrCast(@alignCast(activity));
        const vm = act.vm orelse return false;
        const act_obj = act.clazz orelse return false;

        var env_raw: ?*anyopaque = null;
        var attached = false;
        const get_env = vm.*.*.GetEnv orelse return false;
        const env_rc = get_env(vm, &env_raw, JNI_VERSION_1_6);
        var env_opt: ?JNIEnvPtr = if (env_raw) |ptr| @ptrCast(@alignCast(ptr)) else null;
        if (env_rc == JNI_EDETACHED) {
            const attach = vm.*.*.AttachCurrentThread orelse return false;
            if (attach(vm, &env_opt, null) != JNI_OK) return false;
            attached = true;
        } else if (env_rc != JNI_OK) {
            return false;
        }
        defer if (attached) {
            if (vm.*.*.DetachCurrentThread) |detach| _ = detach(vm);
        };

        const env = env_opt orelse return false;
        const exc_check = env.*.*.ExceptionCheck orelse return false;
        if (exc_check(env) != 0) return false;

        const new_str_utf = env.*.*.NewStringUTF orelse return false;
        const get_obj_class = env.*.*.GetObjectClass orelse return false;
        const get_mid = env.*.*.GetMethodID orelse return false;
        const call_obj = env.*.*.CallObjectMethodA orelse return false;
        const call_void = env.*.*.CallVoidMethodA orelse return false;

        const service_name = new_str_utf(env, "input_method");
        defer deleteLocalRef(env, service_name);
        if (clearJniException(env) or service_name == null) return false;

        const act_cls = get_obj_class(env, act_obj);
        defer deleteLocalRef(env, act_cls);
        if (clearJniException(env) or act_cls == null) return false;

        const get_sys_svc = get_mid(env, act_cls, "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;");
        if (clearJniException(env) or get_sys_svc == null) return false;

        const svc_args = [_]jvalue{.{ .l = service_name }};
        const imm_obj = call_obj(env, act_obj, get_sys_svc, &svc_args);
        defer deleteLocalRef(env, imm_obj);
        if (clearJniException(env) or imm_obj == null) return false;

        const imm_cls = get_obj_class(env, imm_obj);
        defer deleteLocalRef(env, imm_cls);
        if (clearJniException(env) or imm_cls == null) return false;

        if (show) {
            // InputMethodManager.toggleSoftInput(SHOW_FORCED=2, 0)
            const toggle_mid = get_mid(env, imm_cls, "toggleSoftInput", "(II)V");
            if (clearJniException(env) or toggle_mid == null) return false;
            const args = [_]jvalue{ .{ .i = 2 }, .{ .i = 0 } };
            call_void(env, imm_obj, toggle_mid, &args);
            return !clearJniException(env);
        } else {
            // InputMethodManager.hideSoftInputFromWindow(activity.getWindow().getDecorView().getWindowToken(), 0)
            const no_args = [_]jvalue{.{ .i = 0 }};
            const get_win_mid = get_mid(env, act_cls, "getWindow", "()Landroid/view/Window;");
            if (clearJniException(env) or get_win_mid == null) return false;
            const win_obj = call_obj(env, act_obj, get_win_mid, &no_args);
            defer deleteLocalRef(env, win_obj);
            if (clearJniException(env) or win_obj == null) return false;

            const win_cls = get_obj_class(env, win_obj);
            defer deleteLocalRef(env, win_cls);
            if (clearJniException(env) or win_cls == null) return false;

            const get_decor_mid = get_mid(env, win_cls, "getDecorView", "()Landroid/view/View;");
            if (clearJniException(env) or get_decor_mid == null) return false;
            const decor_obj = call_obj(env, win_obj, get_decor_mid, &no_args);
            defer deleteLocalRef(env, decor_obj);
            if (clearJniException(env) or decor_obj == null) return false;

            const decor_cls = get_obj_class(env, decor_obj);
            defer deleteLocalRef(env, decor_cls);
            if (clearJniException(env) or decor_cls == null) return false;

            const get_tok_mid = get_mid(env, decor_cls, "getWindowToken", "()Landroid/os/IBinder;");
            if (clearJniException(env) or get_tok_mid == null) return false;
            const tok_obj = call_obj(env, decor_obj, get_tok_mid, &no_args);
            defer deleteLocalRef(env, tok_obj);
            if (clearJniException(env) or tok_obj == null) return false;

            const hide_mid = get_mid(env, imm_cls, "hideSoftInputFromWindow", "(Landroid/os/IBinder;I)Z");
            if (clearJniException(env) or hide_mid == null) return false;
            const call_bool = env.*.*.CallBooleanMethodA orelse return false;
            const hide_args = [_]jvalue{ .{ .l = tok_obj }, .{ .i = 0 } };
            _ = call_bool(env, imm_obj, hide_mid, &hide_args);
            return !clearJniException(env);
        }
    }

    /// Triggers bounded haptic feedback via Android `Vibrator` / `VibrationEffect` over JNI.
    /// Safely attaches/detaches the current thread if needed, checks and clears JNI exceptions
    /// after every call, and deletes all local references. Returns `false` on host or failure.
    pub fn vibrateNative(activity: *anyopaque, kind: HapticKind) bool {
        if (comptime !is_android) return false;

        const act: *const ANativeActivity = @ptrCast(@alignCast(activity));
        const vm = act.vm orelse return false;
        const act_obj = act.clazz orelse return false;

        var env_raw: ?*anyopaque = null;
        var attached = false;
        const get_env = vm.*.*.GetEnv orelse return false;
        const env_rc = get_env(vm, &env_raw, JNI_VERSION_1_6);
        var env_opt: ?JNIEnvPtr = if (env_raw) |ptr| @ptrCast(@alignCast(ptr)) else null;
        if (env_rc == JNI_EDETACHED) {
            const attach = vm.*.*.AttachCurrentThread orelse return false;
            if (attach(vm, &env_opt, null) != JNI_OK) {
                return false;
            }
            attached = true;
        } else if (env_rc != JNI_OK) {
            return false;
        }
        defer if (attached) {
            if (vm.*.*.DetachCurrentThread) |detach| {
                _ = detach(vm);
            }
        };

        const env = env_opt orelse return false;
        const exc_check = env.*.*.ExceptionCheck orelse return false;
        if (exc_check(env) != 0) return false;

        const new_str_utf = env.*.*.NewStringUTF orelse return false;
        const get_obj_class = env.*.*.GetObjectClass orelse return false;
        const get_mid = env.*.*.GetMethodID orelse return false;
        const call_obj = env.*.*.CallObjectMethodA orelse return false;

        const service_name = new_str_utf(env, "vibrator");
        defer deleteLocalRef(env, service_name);
        if (clearJniException(env) or service_name == null) return false;

        const act_cls = get_obj_class(env, act_obj);
        defer deleteLocalRef(env, act_cls);
        if (clearJniException(env) or act_cls == null) return false;

        const get_svc_mid = get_mid(
            env,
            act_cls,
            "getSystemService",
            "(Ljava/lang/String;)Ljava/lang/Object;",
        );
        if (clearJniException(env) or get_svc_mid == null) return false;

        const svc_args = [_]jvalue{.{ .l = service_name }};
        const vibrator_obj = call_obj(env, act_obj, get_svc_mid, &svc_args);
        defer deleteLocalRef(env, vibrator_obj);
        if (clearJniException(env) or vibrator_obj == null) return false;

        const vib_cls = get_obj_class(env, vibrator_obj);
        defer deleteLocalRef(env, vib_cls);
        if (clearJniException(env) or vib_cls == null) return false;

        if (act.sdkVersion >= 26) {
            if (tryVibrateEffect(env, vibrator_obj, vib_cls, kind)) {
                return true;
            }
        }
        return tryVibrateLegacy(env, vibrator_obj, vib_cls, kind);
    }
};

test "android_platform: full keycode, haptic, state, and host no-op bridge coverage" {
    // Haptics
    try std.testing.expectEqual(@as(u32, 18), hapticDurationMs(.tap));
    try std.testing.expectEqual(@as(u32, 45), hapticDurationMs(.confirm));
    try std.testing.expectEqual(@as(u32, 30), hapticDurationMs(.double_pulse));
    try std.testing.expectEqual(@as(u32, 80), hapticDurationMs(.err));
    try std.testing.expect(hapticPattern(.tap).len >= 2);
    try std.testing.expect(hapticPattern(.confirm).len >= 2);
    try std.testing.expectEqualSlices(u32, &.{ 0, 28, 60, 28 }, hapticPattern(.double_pulse));
    try std.testing.expect(hapticPattern(.err).len >= 2);

    // Keycode mapping (digits, numpad, letters, punctuation, enter/backspace)
    try std.testing.expectEqual(@as(?u8, ' '), androidKeycodeToAscii(62, false));
    try std.testing.expectEqual(@as(?u8, '-'), androidKeycodeToAscii(69, false));
    try std.testing.expectEqual(@as(?u8, '_'), androidKeycodeToAscii(69, true));
    try std.testing.expectEqual(@as(?u8, ';'), androidKeycodeToAscii(74, false));
    try std.testing.expectEqual(@as(?u8, ':'), androidKeycodeToAscii(74, true));
    try std.testing.expectEqual(@as(?u8, '.'), androidKeycodeToAscii(56, false));
    try std.testing.expectEqual(@as(?u8, ','), androidKeycodeToAscii(55, false));
    try std.testing.expectEqual(@as(?u8, '0'), androidKeycodeToAscii(144, false));
    try std.testing.expectEqual(@as(?u8, '9'), androidKeycodeToAscii(153, true));
    try std.testing.expectEqual(@as(?u8, 'z'), androidKeycodeToAscii(54, false));
    try std.testing.expectEqual(@as(?u8, 'Z'), androidKeycodeToAscii(54, true));
    try std.testing.expectEqual(@as(?u8, null), androidKeycodeToAscii(0, false));
    try std.testing.expect(isAndroidBackspace(67));
    try std.testing.expect(!isAndroidBackspace(66));
    try std.testing.expect(isAndroidEnter(66));
    try std.testing.expect(isAndroidEnter(160));
    try std.testing.expect(!isAndroidEnter(67));

    // SoftKeyboardState syncVisible
    var kb = SoftKeyboardState.init();
    kb.syncVisible(true);
    try std.testing.expect(kb.visible);
    try std.testing.expect(!kb.requestShow());
    kb.syncVisible(false);
    try std.testing.expect(!kb.visible);
    try std.testing.expect(!kb.requestHide());

    // Reference all AndroidBridge functions so cross-compilation always analyzes and compiles them
    const keep_fn: *const fn (*anyopaque, bool) void = &AndroidBridge.setKeepScreenOnNative;
    const show_fn: *const fn (*anyopaque) void = &AndroidBridge.showSoftInputNative;
    const hide_fn: *const fn (*anyopaque) void = &AndroidBridge.hideSoftInputNative;
    const vib_fn: *const fn (*anyopaque, HapticKind) bool = &AndroidBridge.vibrateNative;
    _ = .{ keep_fn, show_fn, hide_fn, vib_fn };

    if (comptime !is_android) {
        var dummy: u8 = 0;
        const ptr: *anyopaque = @ptrCast(&dummy);
        keep_fn(ptr, true);
        keep_fn(ptr, false);
        show_fn(ptr);
        hide_fn(ptr);
        try std.testing.expect(!vib_fn(ptr, .tap));
    }
}

