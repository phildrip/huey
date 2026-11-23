const std = @import("std");
const core = @import("core.zig");
const events = @import("events.zig");
const glyph_atlas = @import("glyph_atlas.zig");
const renderer = @import("renderer.zig");
const showcase_scene = @import("showcase_scene.zig");
const virtual_scroll = @import("virtual_scroll.zig");
const wearos = @import("wearos.zig");

const IS_WEAR: bool = @hasDecl(@import("root"), "WEAR_MODE") and @import("root").WEAR_MODE;
const ActiveShowcase = if (IS_WEAR) @import("wear_showcase_scene.zig").WearShowcaseApp else showcase_scene.ShowcaseApp;
const DEFAULT_LW: f32 = if (IS_WEAR) 233.0 else 768.0;
const DEFAULT_LH: f32 = if (IS_WEAR) 233.0 else 1024.0;

const c = @cImport({
    @cDefine("BIONIC_IOCTL_NO_SIGNEDNESS_OVERLOAD", "1");
    @cInclude("pthread.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/stat.h");
    @cInclude("time.h");
    @cInclude("EGL/egl.h");
    @cInclude("android/native_activity.h");
    @cInclude("android/looper.h");
    @cInclude("android/input.h");
    @cInclude("android/configuration.h");
    @cInclude("android/native_window.h");
    @cInclude("android/choreographer.h");
    @cInclude("android/log.h");
});

const LOG_TAG: [*:0]const u8 = if (IS_WEAR) "ZigGuiWatch" else "ZigGuiSpike";
const LOOPER_ID_MAIN: c_int = 1;
const LOOPER_ID_INPUT: c_int = 2;
const MAX_INPUT_EVENTS_PER_FRAME: usize = 32;

fn logInfo(comptime fmt: [*:0]const u8, args: anytype) void {
    _ = @call(.auto, c.__android_log_print, .{ c.ANDROID_LOG_INFO, LOG_TAG, fmt } ++ args);
}

fn logErr(comptime fmt: [*:0]const u8, args: anytype) void {
    _ = @call(.auto, c.__android_log_print, .{ c.ANDROID_LOG_ERROR, LOG_TAG, fmt } ++ args);
}

const Cmd = enum(u8) {
    init_window = 1,
    term_window = 2,
    resize_window = 3,
    redraw_needed = 4,
    input_changed = 5,
    config_changed = 6,
    cancel_pointer = 7,
    destroy = 8,
};

const AppState = struct {
    activity: *c.ANativeActivity,
    msgread: c_int,
    msgwrite: c_int,
    mutex: c.pthread_mutex_t,
    cond: c.pthread_cond_t,
    thread: c.pthread_t,

    running: bool = false,
    startup_failed: bool = false,
    worker_exited: bool = false,
    destroy_requested: bool = false,

    pending_window: ?*c.ANativeWindow = null,
    window_ack: bool = false,

    pending_input_queue: ?*c.AInputQueue = null,
    input_ack: bool = false,

    redraw_ack: bool = true,
};

fn writeCmdByte(fd: c_int, cmd: Cmd) bool {
    var b: u8 = @intFromEnum(cmd);
    while (true) {
        const rc = c.write(fd, &b, 1);
        if (rc == 1) return true;
        if (rc < 0) {
            if (std.c._errno().* == @intFromEnum(std.posix.E.INTR)) continue;
            return false;
        }
        return false;
    }
}

fn getDensityScale(asset_manager: ?*c.AAssetManager, config: *c.AConfiguration) f32 {
    if (asset_manager) |am| {
        c.AConfiguration_fromAssetManager(config, am);
    }
    const density = c.AConfiguration_getDensity(config);
    if (density > 0 and density < 0xFFFE) {
        return @as(f32, @floatFromInt(density)) / 160.0;
    }
    return 2.0;
}

fn readFileAllocPosix(allocator: std.mem.Allocator, path: [*:0]const u8, max_bytes: usize) ?[]u8 {
    var fd: c_int = -1;
    while (true) {
        fd = c.open(path, c.O_RDONLY);
        if (fd >= 0) break;
        if (std.c._errno().* == @intFromEnum(std.posix.E.INTR)) continue;
        return null;
    }
    defer _ = c.close(fd);

    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0 or st.st_size <= 0 or st.st_size > max_bytes) {
        return null;
    }
    const size: usize = @intCast(st.st_size);
    const buf = allocator.alloc(u8, size) catch return null;

    var total: usize = 0;
    while (total < size) {
        const rc = c.read(fd, buf[total..].ptr, size - total);
        if (rc > 0) {
            total += @intCast(rc);
        } else if (rc == 0) {
            allocator.free(buf);
            return null;
        } else {
            if (std.c._errno().* == @intFromEnum(std.posix.E.INTR)) continue;
            allocator.free(buf);
            return null;
        }
    }
    return buf;
}

fn initAndroidGlyphAtlas(allocator: std.mem.Allocator, atlas_size: u32, scale_factor: f32) ?glyph_atlas.GlyphAtlas {
    const candidates = [_][*:0]const u8{
        "/system/fonts/Roboto-Regular.ttf",
        "/system/fonts/DroidSans.ttf",
    };
    for (candidates) |path| {
        const fb = readFileAllocPosix(allocator, path, 16 * 1024 * 1024) orelse continue;
        defer allocator.free(fb);

        if (glyph_atlas.GlyphAtlas.init(allocator, fb, atlas_size, atlas_size)) |a_val| {
            var a = a_val;
            a.setScaleFactor(scale_factor);
            logInfo("Loaded font %s (%zu bytes), GlyphAtlas %ux%u ready", .{ path, fb.len, atlas_size, atlas_size });
            return a;
        } else |err| {
            logErr("GlyphAtlas.init failed for %s: %s", .{ path, @errorName(err).ptr });
        }
    }
    return null;
}

fn dumpSemanticTreeToLogcat(arena: *const core.LayoutArena) void {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    arena.dumpSemanticTree(&writer) catch {};
    const text = writer.buffered();
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        logInfo("%.*s", .{ @as(c_int, @intCast(line.len)), line.ptr });
    }
}

const EglState = struct {
    display: c.EGLDisplay = c.EGL_NO_DISPLAY,
    surface: c.EGLSurface = c.EGL_NO_SURFACE,
    context: c.EGLContext = c.EGL_NO_CONTEXT,
    width: i32 = 0,
    height: i32 = 0,

    fn init(window: *c.ANativeWindow) ?EglState {
        const display = c.eglGetDisplay(c.EGL_DEFAULT_DISPLAY);
        if (display == c.EGL_NO_DISPLAY) {
            logErr("eglGetDisplay failed", .{});
            return null;
        }
        var major: c.EGLint = 0;
        var minor: c.EGLint = 0;
        if (c.eglInitialize(display, &major, &minor) == 0) {
            logErr("eglInitialize failed", .{});
            return null;
        }

        var attribs = [_]c.EGLint{
            c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_ES3_BIT,
            c.EGL_SURFACE_TYPE,    c.EGL_WINDOW_BIT,
            c.EGL_RED_SIZE,        8,
            c.EGL_GREEN_SIZE,      8,
            c.EGL_BLUE_SIZE,       8,
            c.EGL_ALPHA_SIZE,      8,
            c.EGL_NONE,
        };

        var config: c.EGLConfig = null;
        var num_configs: c.EGLint = 0;
        if (c.eglChooseConfig(display, &attribs, &config, 1, &num_configs) == 0 or num_configs == 0) {
            attribs[1] = c.EGL_OPENGL_ES2_BIT;
            if (c.eglChooseConfig(display, &attribs, &config, 1, &num_configs) == 0 or num_configs == 0) {
                logErr("eglChooseConfig failed", .{});
                _ = c.eglTerminate(display);
                return null;
            }
        }

        var format: c.EGLint = 0;
        _ = c.eglGetConfigAttrib(display, config, c.EGL_NATIVE_VISUAL_ID, &format);
        _ = c.ANativeWindow_setBuffersGeometry(window, 0, 0, format);

        const surface = c.eglCreateWindowSurface(display, config, window, null);
        if (surface == c.EGL_NO_SURFACE) {
            logErr("eglCreateWindowSurface failed", .{});
            _ = c.eglTerminate(display);
            return null;
        }

        const ctx_attribs = [_]c.EGLint{
            c.EGL_CONTEXT_CLIENT_VERSION, 3,
            c.EGL_NONE,
        };
        const context = c.eglCreateContext(display, config, c.EGL_NO_CONTEXT, &ctx_attribs);
        if (context == c.EGL_NO_CONTEXT) {
            logErr("eglCreateContext(ES3) failed", .{});
            _ = c.eglDestroySurface(display, surface);
            _ = c.eglTerminate(display);
            return null;
        }

        if (c.eglMakeCurrent(display, surface, surface, context) == 0) {
            logErr("eglMakeCurrent failed", .{});
            _ = c.eglDestroyContext(display, context);
            _ = c.eglDestroySurface(display, surface);
            _ = c.eglTerminate(display);
            return null;
        }

        _ = c.eglSwapInterval(display, 1);

        var w: c.EGLint = 0;
        var h: c.EGLint = 0;
        _ = c.eglQuerySurface(display, surface, c.EGL_WIDTH, &w);
        _ = c.eglQuerySurface(display, surface, c.EGL_HEIGHT, &h);
        logInfo("EGL %d.%d initialized (%dx%d)", .{ major, minor, w, h });

        return .{
            .display = display,
            .surface = surface,
            .context = context,
            .width = w,
            .height = h,
        };
    }

    fn deinit(self: *EglState) void {
        if (self.display != c.EGL_NO_DISPLAY) {
            _ = c.eglMakeCurrent(self.display, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, c.EGL_NO_CONTEXT);
            if (self.context != c.EGL_NO_CONTEXT) _ = c.eglDestroyContext(self.display, self.context);
            if (self.surface != c.EGL_NO_SURFACE) _ = c.eglDestroySurface(self.display, self.surface);
            _ = c.eglTerminate(self.display);
        }
        self.* = .{};
    }

    fn querySize(self: *EglState) void {
        if (self.display == c.EGL_NO_DISPLAY or self.surface == c.EGL_NO_SURFACE) return;
        var w: c.EGLint = 0;
        var h: c.EGLint = 0;
        if (c.eglQuerySurface(self.display, self.surface, c.EGL_WIDTH, &w) != c.EGL_FALSE and
            c.eglQuerySurface(self.display, self.surface, c.EGL_HEIGHT, &h) != c.EGL_FALSE)
        {
            self.width = w;
            self.height = h;
        }
    }
};

fn signalRedrawAck(state: *AppState) void {
    _ = c.pthread_mutex_lock(&state.mutex);
    if (!state.redraw_ack) {
        state.redraw_ack = true;
        _ = c.pthread_cond_broadcast(&state.cond);
    }
    _ = c.pthread_mutex_unlock(&state.mutex);
}

const MouseButtonTracker = struct {
    const Entry = struct {
        active: bool = false,
        pointer_id: i32 = 0,
        button: events.PointerButton = .primary,
    };
    entries: [8]Entry = [_]Entry{.{}} ** 8,

    fn buttonFromEvent(ev: *const c.AInputEvent, is_touch: bool) events.PointerButton {
        if (is_touch) return .primary;
        const state = c.AMotionEvent_getButtonState(ev);
        if ((state & c.AMOTION_EVENT_BUTTON_SECONDARY) != 0) return .secondary;
        if ((state & c.AMOTION_EVENT_BUTTON_TERTIARY) != 0) return .middle;
        return .primary;
    }

    fn recordDown(self: *MouseButtonTracker, pointer_id: i32, btn: events.PointerButton) void {
        var free_idx: ?usize = null;
        for (&self.entries, 0..) |*e, i| {
            if (e.active and e.pointer_id == pointer_id) {
                e.button = btn;
                return;
            }
            if (!e.active and free_idx == null) {
                free_idx = i;
            }
        }
        if (free_idx) |idx| {
            self.entries[idx] = .{
                .active = true,
                .pointer_id = pointer_id,
                .button = btn,
            };
        }
    }

    fn takeUp(self: *MouseButtonTracker, pointer_id: i32) events.PointerButton {
        for (&self.entries) |*e| {
            if (e.active and e.pointer_id == pointer_id) {
                const btn = e.button;
                e.active = false;
                return btn;
            }
        }
        return .primary;
    }

    fn remove(self: *MouseButtonTracker, pointer_id: i32) void {
        for (&self.entries) |*e| {
            if (e.active and e.pointer_id == pointer_id) {
                e.active = false;
            }
        }
    }

    fn clear(self: *MouseButtonTracker) void {
        for (&self.entries) |*e| {
            e.active = false;
        }
    }
};

const TouchScrollState = struct {
    active_pointer: ?i32 = null,
    down_y: f32 = 0.0,
    down_t: f64 = 0.0,
    scrolling: bool = false,
    caught_fling: bool = false,

    fn reset(self: *TouchScrollState) void {
        self.active_pointer = null;
        self.down_y = 0.0;
        self.down_t = 0.0;
        self.scrolling = false;
        self.caught_fling = false;
    }
};

fn monotonicSeconds() f64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0.0;
    return @as(f64, @floatFromInt(ts.tv_sec)) + @as(f64, @floatFromInt(ts.tv_nsec)) / 1_000_000_000.0;
}

fn motionEventSeconds(ev: *const c.AInputEvent) f64 {
    const ns = c.AMotionEvent_getEventTime(ev);
    if (ns <= 0) return monotonicSeconds();
    return @as(f64, @floatFromInt(ns)) / 1_000_000_000.0;
}

fn applyScroll(
    arena: *core.LayoutArena,
    scroller: *const virtual_scroll.InertialScroller,
    scroll_target: ?core.NodeId,
    egl_w: c.EGLint,
    egl_h: c.EGLint,
    scale_factor: f32,
) void {
    if (scroll_target orelse arena.getRoot()) |target| {
        arena.setScroll(target, 0.0, @floatCast(scroller.offset));
    }
    if (egl_w > 0 and egl_h > 0) {
        const lw = @as(f32, @floatFromInt(egl_w)) / scale_factor;
        const lh = @as(f32, @floatFromInt(egl_h)) / scale_factor;
        arena.layout(lw, lh);
    }
}

fn layoutAndSyncScroll(
    arena: *core.LayoutArena,
    scroller: *virtual_scroll.InertialScroller,
    scroll_target: ?core.NodeId,
    egl_w: c.EGLint,
    egl_h: c.EGLint,
    scale_factor: f32,
) void {
    if (egl_w <= 0 or egl_h <= 0) return;
    const lw = @as(f32, @floatFromInt(egl_w)) / scale_factor;
    const lh = @as(f32, @floatFromInt(egl_h)) / scale_factor;
    arena.layout(lw, lh);
    if (scroll_target orelse arena.getRoot()) |target| {
        const ch = arena.contentHeight(target);
        const view_h = if (arena.getRect(target)) |r| r.h else arena.viewport_h;
        const max_s = @max(0.0, @as(f64, ch) - @as(f64, view_h));
        scroller.setMaxScroll(max_s);
        arena.setScroll(target, 0.0, @floatCast(scroller.offset));
        if (arena.layout_dirty) {
            arena.layout(lw, lh);
        }
    }
}

fn rebuildShowcaseAndSync(
    showcase: *ActiveShowcase,
    arena: *core.LayoutArena,
    scroller: *virtual_scroll.InertialScroller,
    router: *events.EventRouter,
    egl_w: c.EGLint,
    egl_h: c.EGLint,
    scale_factor: f32,
) void {
    var cap_buf: [64]u8 = undefined;
    var cap_len: usize = 0;
    if (router.captured_node) |cid| {
        if (arena.getTestId(cid)) |tid| {
            if (tid.len > 0 and tid.len <= cap_buf.len) {
                @memcpy(cap_buf[0..tid.len], tid);
                cap_len = tid.len;
            }
        }
    }
    const lw: f32 = if (egl_w > 0) @as(f32, @floatFromInt(egl_w)) / scale_factor else DEFAULT_LW;
    const lh: f32 = if (egl_h > 0) @as(f32, @floatFromInt(egl_h)) / scale_factor else DEFAULT_LH;
    showcase.buildScene(arena, lw, lh) catch |err| {
        logErr("showcase.buildScene failed: %s", .{@errorName(err).ptr});
        return;
    };
    if (egl_w > 0 and egl_h > 0) {
        layoutAndSyncScroll(arena, scroller, showcase.scroll_container, egl_w, egl_h, scale_factor);
    } else {
        arena.layout(lw, lh);
    }
    if (cap_len > 0) {
        if (arena.findByTestId(cap_buf[0..cap_len])) |new_id| {
            router.captured_node = new_id;
        }
    }
}

fn isTouchInScrollArea(
    arena: *const core.LayoutArena,
    showcase: *const ActiveShowcase,
    px: f32,
    py: f32,
) bool {
    if (showcase.overlays.activeCount() > 0) return false;
    if (showcase.scroll_container) |sc| {
        if (arena.getRect(sc)) |r| {
            return px >= r.x and px <= r.x + r.w and py >= r.y and py <= r.y + r.h;
        }
    }
    return if (IS_WEAR) true else (py >= 108.0);
}

const VsyncState = struct {
    posted: bool = false,
    fired: bool = false,
    frame_time_ns: i64 = 0,
    last_frame_time_ns: i64 = 0,
    active: bool = false,
};

fn onChoreographerFrame(frame_time_nanos: c_long, data: ?*anyopaque) callconv(.c) void {
    const vs: *VsyncState = @ptrCast(@alignCast(data orelse return));
    vs.posted = false;
    vs.fired = true;
    vs.frame_time_ns = @intCast(frame_time_nanos);
}

fn workerMain(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const state: *AppState = @ptrCast(@alignCast(arg.?));

    const looper = c.ALooper_prepare(c.ALOOPER_PREPARE_ALLOW_NON_CALLBACKS) orelse {
        logErr("ALooper_prepare returned null", .{});
        _ = c.pthread_mutex_lock(&state.mutex);
        state.startup_failed = true;
        state.worker_exited = true;
        _ = c.pthread_cond_broadcast(&state.cond);
        _ = c.pthread_mutex_unlock(&state.mutex);
        return null;
    };
    const choreographer = c.AChoreographer_getInstance();
    _ = c.ALooper_addFd(looper, state.msgread, LOOPER_ID_MAIN, c.ALOOPER_EVENT_INPUT, null, null);

    const config = c.AConfiguration_new() orelse {
        logErr("AConfiguration_new returned null", .{});
        _ = c.pthread_mutex_lock(&state.mutex);
        state.startup_failed = true;
        state.worker_exited = true;
        _ = c.pthread_cond_broadcast(&state.cond);
        _ = c.pthread_mutex_unlock(&state.mutex);
        return null;
    };
    defer c.AConfiguration_delete(config);

    var scale_factor = getDensityScale(state.activity.assetManager, config);
    logInfo("Worker started, initial scale_factor=%.2f", .{@as(f64, scale_factor)});

    const ATLAS_SIZE: u32 = renderer.DEFAULT_ATLAS_SIZE;
    var atlas_storage: glyph_atlas.GlyphAtlas = undefined;
    var atlas_ptr: ?*glyph_atlas.GlyphAtlas = null;
    if (initAndroidGlyphAtlas(std.heap.c_allocator, ATLAS_SIZE, scale_factor)) |a| {
        atlas_storage = a;
        atlas_ptr = &atlas_storage;
    } else {
        logErr("Failed to load Android system font; running without text", .{});
    }
    defer if (atlas_ptr) |a| a.deinit();

    var arena = core.LayoutArena.init(std.heap.c_allocator);
    defer arena.deinit();
    var showcase = ActiveShowcase.init();
    showcase.buildScene(&arena, DEFAULT_LW, DEFAULT_LH) catch {
        logErr("showcase.buildScene failed", .{});
        _ = c.pthread_mutex_lock(&state.mutex);
        state.startup_failed = true;
        state.worker_exited = true;
        _ = c.pthread_cond_broadcast(&state.cond);
        _ = c.pthread_mutex_unlock(&state.mutex);
        return null;
    };
    arena.consumeRedraw();

    const quad_buf = std.heap.c_allocator.alloc(core.QuadInstance, renderer.MAX_QUADS) catch {
        logErr("OOM allocating quad_buf", .{});
        _ = c.pthread_mutex_lock(&state.mutex);
        state.startup_failed = true;
        state.worker_exited = true;
        _ = c.pthread_cond_broadcast(&state.cond);
        _ = c.pthread_mutex_unlock(&state.mutex);
        return null;
    };
    defer std.heap.c_allocator.free(quad_buf);

    var egl: EglState = .{};
    var rend: renderer.Renderer = .{};
    var window: ?*c.ANativeWindow = null;
    var input_queue: ?*c.AInputQueue = null;
    var router = events.EventRouter.init();
    var mouse_buttons: MouseButtonTracker = .{};
    var scroller = virtual_scroll.InertialScroller.init(0.0);
    var rotary = wearos.WearRotaryAdapter.init(36.0);
    var touch_scroll: TouchScrollState = .{};
    var vsync: VsyncState = .{};
    var redraw_pending = false;
    var anim_frames: u32 = 0;
    var anim_dt_sum_ms: f64 = 0.0;
    var anim_render_sum_ms: f64 = 0.0;
    var last_anim_time_s: ?f64 = null;
    var last_logged_slider_id: ?core.NodeId = null;
    var last_logged_slider_val: f32 = -1.0;
    var dumped_initial_tree = false;
    var frame_idx: u64 = 0;

    _ = c.pthread_mutex_lock(&state.mutex);
    state.running = true;
    _ = c.pthread_cond_broadcast(&state.cond);
    _ = c.pthread_mutex_unlock(&state.mutex);

    var quit = false;
    while (!quit) {
        const has_surface = (window != null and egl.surface != c.EGL_NO_SURFACE and rend.initialized);
        const wants_frame = has_surface and (scroller.isAnimating() or arena.needsRedraw());
        if (wants_frame) {
            if (choreographer) |ch| {
                if (!vsync.posted) {
                    c.AChoreographer_postFrameCallback(ch, onChoreographerFrame, &vsync);
                    vsync.posted = true;
                    if (!vsync.active) {
                        vsync.last_frame_time_ns = 0;
                        vsync.active = true;
                    }
                }
            }
        }
        const has_pending_input = if (input_queue) |q| (c.AInputQueue_hasEvents(q) > 0) else false;
        const timeout_ms: c_int = if (has_pending_input or (wants_frame and choreographer == null)) 0 else -1;

        var looper_events: c_int = 0;
        var out_data: ?*anyopaque = null;
        var ident = c.ALooper_pollOnce(timeout_ms, null, &looper_events, &out_data);

        var drain_passes: usize = 0;
        while (ident >= 0 and !quit) {
            if (ident == LOOPER_ID_MAIN) {
                if ((looper_events & (c.ALOOPER_EVENT_ERROR | c.ALOOPER_EVENT_HANGUP)) != 0) {
                    quit = true;
                    break;
                }
                var cmd_byte: u8 = 0;
                while (!quit) {
                    const rc = c.read(state.msgread, &cmd_byte, 1);
                    if (rc == 0) {
                        quit = true;
                        break;
                    }
                    if (rc < 0) {
                        const err_no = std.c._errno().*;
                        if (err_no == @intFromEnum(std.posix.E.INTR)) continue;
                        if (err_no == @intFromEnum(std.posix.E.AGAIN)) break;
                        quit = true;
                        break;
                    }

                    const cmd = std.enums.fromInt(Cmd, cmd_byte) orelse continue;
                    switch (cmd) {
                        .init_window => {
                            _ = c.pthread_mutex_lock(&state.mutex);
                            const new_win = state.pending_window;
                            window = new_win;
                            state.window_ack = true;
                            _ = c.pthread_cond_broadcast(&state.cond);
                            _ = c.pthread_mutex_unlock(&state.mutex);

                            if (new_win) |w| {
                                rend.deinit();
                                egl.deinit();
                                if (EglState.init(w)) |new_egl| {
                                    egl = new_egl;
                                    if (renderer.Renderer.init(ATLAS_SIZE, ATLAS_SIZE)) |new_rend| {
                                        rend = new_rend;
                                        if (atlas_ptr) |a| {
                                            a.dirty = true;
                                        }
                                        rebuildShowcaseAndSync(&showcase, &arena, &scroller, &router, egl.width, egl.height, scale_factor);
                                        arena.requestRedraw();
                                    } else |_| {
                                        logErr("Renderer.init failed", .{});
                                        egl.deinit();
                                    }
                                }
                            }
                        },
                        .term_window => {
                            rend.deinit();
                            egl.deinit();
                            mouse_buttons.clear();
                            touch_scroll.reset();
                            last_anim_time_s = null;
                            vsync.active = false;
                            vsync.fired = false;
                            redraw_pending = false;
                            anim_frames = 0;
                            anim_dt_sum_ms = 0.0;
                            anim_render_sum_ms = 0.0;
                            if (scroller.dragging or scroller.animating) {
                                scroller.dragging = false;
                                scroller.animating = false;
                                scroller.velocity = 0.0;
                                scroller.offset = std.math.clamp(scroller.offset, 0.0, scroller.max_scroll);
                                if (showcase.scroll_container orelse arena.getRoot()) |target| {
                                    arena.setScroll(target, 0.0, @floatCast(scroller.offset));
                                }
                            }
                            router.dispatch(&arena, .focus_lost);

                            _ = c.pthread_mutex_lock(&state.mutex);
                            window = null;
                            state.window_ack = true;
                            state.redraw_ack = true;
                            _ = c.pthread_cond_broadcast(&state.cond);
                            _ = c.pthread_mutex_unlock(&state.mutex);
                        },
                        .resize_window => {
                            if (window) |w| {
                                if (egl.surface != c.EGL_NO_SURFACE) {
                                    const nw = c.ANativeWindow_getWidth(w);
                                    const nh = c.ANativeWindow_getHeight(w);
                                    egl.querySize();
                                    if (nw > 0 and nh > 0) {
                                        egl.width = nw;
                                        egl.height = nh;
                                    }
                                    if (egl.width > 0 and egl.height > 0) {
                                        rebuildShowcaseAndSync(&showcase, &arena, &scroller, &router, egl.width, egl.height, scale_factor);
                                        arena.requestRedraw();
                                    }
                                }
                            }
                        },
                        .redraw_needed => {
                            if (window != null and egl.surface != c.EGL_NO_SURFACE and rend.initialized) {
                                arena.requestRedraw();
                                redraw_pending = true;
                            } else {
                                redraw_pending = false;
                                signalRedrawAck(state);
                            }
                        },
                        .input_changed => {
                            _ = c.pthread_mutex_lock(&state.mutex);
                            const new_q = state.pending_input_queue;
                            if (input_queue) |old_q| {
                                c.AInputQueue_detachLooper(old_q);
                            }
                            input_queue = new_q;
                            if (new_q) |q| {
                                c.AInputQueue_attachLooper(q, looper, LOOPER_ID_INPUT, null, null);
                            }
                            mouse_buttons.clear();
                            const was_scrolling_ic = touch_scroll.scrolling;
                            touch_scroll.reset();
                            scroller.dragging = false;
                            if (was_scrolling_ic or scroller.offset < 0.0 or scroller.offset > scroller.max_scroll) {
                                scroller.endDrag();
                                if (scroller.isAnimating()) arena.requestRedraw();
                            }
                            router.dispatch(&arena, .focus_lost);
                            state.input_ack = true;
                            _ = c.pthread_cond_broadcast(&state.cond);
                            _ = c.pthread_mutex_unlock(&state.mutex);
                        },
                        .config_changed => {
                            scale_factor = getDensityScale(state.activity.assetManager, config);
                            if (atlas_ptr) |a| {
                                a.setScaleFactor(scale_factor);
                            }
                            if (egl.width > 0 and egl.height > 0) {
                                rebuildShowcaseAndSync(&showcase, &arena, &scroller, &router, egl.width, egl.height, scale_factor);
                                arena.requestRedraw();
                            }
                        },
                        .cancel_pointer => {
                            mouse_buttons.clear();
                            const was_scrolling_cp = touch_scroll.scrolling;
                            touch_scroll.reset();
                            scroller.dragging = false;
                            if (was_scrolling_cp or scroller.offset < 0.0 or scroller.offset > scroller.max_scroll) {
                                scroller.endDrag();
                                if (scroller.isAnimating()) arena.requestRedraw();
                            }
                            router.dispatch(&arena, .focus_lost);
                        },
                        .destroy => {
                            quit = true;
                            break;
                        },
                    }
                }
            } else if (ident == LOOPER_ID_INPUT) {
                if ((looper_events & (c.ALOOPER_EVENT_ERROR | c.ALOOPER_EVENT_HANGUP)) != 0) {
                    if (input_queue) |q| {
                        c.AInputQueue_detachLooper(q);
                        input_queue = null;
                    }
                } else if (input_queue) |q| {
                    var event: ?*c.AInputEvent = null;
                    var processed: usize = 0;
                    while (processed < MAX_INPUT_EVENTS_PER_FRAME and c.AInputQueue_getEvent(q, &event) >= 0) {
                        processed += 1;
                        const ev = event orelse continue;
                        if (c.AInputQueue_preDispatchEvent(q, ev) != 0) continue;

                        var handled: c_int = 0;
                        if (c.AInputEvent_getType(ev) == c.AINPUT_EVENT_TYPE_MOTION) {
                            const raw_action = c.AMotionEvent_getAction(ev);
                            const action = raw_action & c.AMOTION_EVENT_ACTION_MASK;
                            const ptr_idx: usize = @intCast(
                                (raw_action & c.AMOTION_EVENT_ACTION_POINTER_INDEX_MASK) >>
                                    c.AMOTION_EVENT_ACTION_POINTER_INDEX_SHIFT,
                            );
                            const ptr_count = c.AMotionEvent_getPointerCount(ev);

                            switch (action) {
                                c.AMOTION_EVENT_ACTION_DOWN => {
                                    if (ptr_count > 0) {
                                        if (arena.layout_dirty and egl.width > 0 and egl.height > 0) {
                                            const lw = @as(f32, @floatFromInt(egl.width)) / scale_factor;
                                            const lh = @as(f32, @floatFromInt(egl.height)) / scale_factor;
                                            arena.layout(lw, lh);
                                        }
                                        const pid = c.AMotionEvent_getPointerId(ev, 0);
                                        const px = c.AMotionEvent_getX(ev, 0) / scale_factor;
                                        const py = c.AMotionEvent_getY(ev, 0) / scale_factor;
                                        const is_touch = c.AMotionEvent_getToolType(ev, 0) != c.AMOTION_EVENT_TOOL_TYPE_MOUSE;
                                        const btn = MouseButtonTracker.buttonFromEvent(ev, is_touch);
                                        if (!is_touch) mouse_buttons.recordDown(pid, btn);
                                        if (showcase.handlePointerDown(px, py)) {
                                            touch_scroll.reset();
                                            arena.requestRedraw();
                                        } else if (is_touch) {
                                            const can_scroll = isTouchInScrollArea(&arena, &showcase, px, py);
                                            const was_animating = scroller.isAnimating();
                                            scroller.animating = false;
                                            scroller.dragging = false;
                                            scroller.velocity = 0.0;
                                            last_anim_time_s = null;
                                            anim_frames = 0;
                                            anim_dt_sum_ms = 0.0;
                                            anim_render_sum_ms = 0.0;
                                            if (can_scroll) {
                                                touch_scroll.active_pointer = pid;
                                                touch_scroll.down_y = py;
                                                touch_scroll.down_t = motionEventSeconds(ev);
                                                touch_scroll.scrolling = false;
                                                touch_scroll.caught_fling = was_animating;
                                                if (!was_animating) {
                                                    router.dispatch(&arena, .{ .pointer_down = .{
                                                        .pointer_id = pid,
                                                        .x = px,
                                                        .y = py,
                                                        .button = btn,
                                                        .is_touch = is_touch,
                                                    } });
                                                }
                                            } else {
                                                touch_scroll.reset();
                                                router.dispatch(&arena, .{ .pointer_down = .{
                                                    .pointer_id = pid,
                                                    .x = px,
                                                    .y = py,
                                                    .button = btn,
                                                    .is_touch = is_touch,
                                                } });
                                            }
                                        } else {
                                            router.dispatch(&arena, .{ .pointer_down = .{
                                                .pointer_id = pid,
                                                .x = px,
                                                .y = py,
                                                .button = btn,
                                                .is_touch = is_touch,
                                            } });
                                        }
                                        handled = 1;
                                    }
                                },
                                c.AMOTION_EVENT_ACTION_POINTER_DOWN => {
                                    if (ptr_idx < ptr_count) {
                                        const pid = c.AMotionEvent_getPointerId(ev, ptr_idx);
                                        const px = c.AMotionEvent_getX(ev, ptr_idx) / scale_factor;
                                        const py = c.AMotionEvent_getY(ev, ptr_idx) / scale_factor;
                                        const is_touch = c.AMotionEvent_getToolType(ev, ptr_idx) != c.AMOTION_EVENT_TOOL_TYPE_MOUSE;
                                        const btn = MouseButtonTracker.buttonFromEvent(ev, is_touch);
                                        if (!is_touch) mouse_buttons.recordDown(pid, btn);
                                        const allow_dispatch = if (is_touch) (touch_scroll.active_pointer == null and !touch_scroll.scrolling and !touch_scroll.caught_fling) else !touch_scroll.scrolling;
                                        if (btn == .primary and showcase.handlePointerDown(px, py)) {
                                            touch_scroll.reset();
                                            arena.requestRedraw();
                                        } else if (allow_dispatch) {
                                            router.dispatch(&arena, .{ .pointer_down = .{
                                                .pointer_id = pid,
                                                .x = px,
                                                .y = py,
                                                .button = btn,
                                                .is_touch = is_touch,
                                            } });
                                        }
                                        handled = 1;
                                    }
                                },
                                c.AMOTION_EVENT_ACTION_MOVE => {
                                    const ev_t = motionEventSeconds(ev);
                                    var i: usize = 0;
                                    while (i < ptr_count) : (i += 1) {
                                        const pid = c.AMotionEvent_getPointerId(ev, i);
                                        const px = c.AMotionEvent_getX(ev, i) / scale_factor;
                                        const py = c.AMotionEvent_getY(ev, i) / scale_factor;
                                        const is_touch = c.AMotionEvent_getToolType(ev, i) != c.AMOTION_EVENT_TOOL_TYPE_MOUSE;
                                        const is_active_scroll_ptr = is_touch and touch_scroll.active_pointer != null and touch_scroll.active_pointer.? == pid;
                                        if (is_active_scroll_ptr) {
                                            if (touch_scroll.scrolling) {
                                                scroller.updateDrag(@as(f64, py), ev_t);
                                                if (showcase.scroll_container orelse arena.getRoot()) |target| {
                                                    arena.setScroll(target, 0.0, @floatCast(scroller.offset));
                                                }
                                                continue;
                                            }
                                            if (router.captured_node == null and @abs(py - touch_scroll.down_y) > 8.0) {
                                                touch_scroll.scrolling = true;
                                                if (!touch_scroll.caught_fling) {
                                                    router.dispatch(&arena, .{ .pointer_cancel = .{ .pointer_id = pid } });
                                                }
                                                scroller.beginDrag(@as(f64, touch_scroll.down_y), touch_scroll.down_t);
                                                scroller.updateDrag(@as(f64, py), ev_t);
                                                if (showcase.scroll_container orelse arena.getRoot()) |target| {
                                                    arena.setScroll(target, 0.0, @floatCast(scroller.offset));
                                                }
                                                continue;
                                            }
                                            if (touch_scroll.caught_fling) {
                                                continue;
                                            }
                                        }
                                        router.dispatch(&arena, .{ .pointer_move = .{
                                            .pointer_id = pid,
                                            .x = px,
                                            .y = py,
                                            .is_touch = is_touch,
                                        } });
                                    }
                                    if (ptr_count > 0) handled = 1;
                                },
                                c.AMOTION_EVENT_ACTION_UP => {
                                    if (ptr_count > 0) {
                                        const pid = c.AMotionEvent_getPointerId(ev, 0);
                                        const px = c.AMotionEvent_getX(ev, 0) / scale_factor;
                                        const py = c.AMotionEvent_getY(ev, 0) / scale_factor;
                                        const is_touch = c.AMotionEvent_getToolType(ev, 0) != c.AMOTION_EVENT_TOOL_TYPE_MOUSE;
                                        const btn = if (is_touch) events.PointerButton.primary else mouse_buttons.takeUp(pid);
                                        if (is_touch and touch_scroll.active_pointer != null and touch_scroll.active_pointer.? == pid) {
                                            const was_scrolling = touch_scroll.scrolling;
                                            const was_caught = touch_scroll.caught_fling;
                                            touch_scroll.reset();
                                            if (was_scrolling) {
                                                scroller.endDrag();
                                                if (scroller.isAnimating()) arena.requestRedraw();
                                            } else {
                                                if (!was_caught) {
                                                    router.dispatch(&arena, .{ .pointer_up = .{
                                                        .pointer_id = pid,
                                                        .x = px,
                                                        .y = py,
                                                        .button = btn,
                                                        .is_touch = is_touch,
                                                    } });
                                                }
                                                if (scroller.offset < 0.0 or scroller.offset > scroller.max_scroll) {
                                                    scroller.endDrag();
                                                    arena.requestRedraw();
                                                }
                                            }
                                        } else {
                                            router.dispatch(&arena, .{ .pointer_up = .{
                                                .pointer_id = pid,
                                                .x = px,
                                                .y = py,
                                                .button = btn,
                                                .is_touch = is_touch,
                                            } });
                                        }
                                        handled = 1;
                                    }
                                },
                                c.AMOTION_EVENT_ACTION_POINTER_UP => {
                                    if (ptr_idx < ptr_count) {
                                        const pid = c.AMotionEvent_getPointerId(ev, ptr_idx);
                                        const px = c.AMotionEvent_getX(ev, ptr_idx) / scale_factor;
                                        const py = c.AMotionEvent_getY(ev, ptr_idx) / scale_factor;
                                        const is_touch = c.AMotionEvent_getToolType(ev, ptr_idx) != c.AMOTION_EVENT_TOOL_TYPE_MOUSE;
                                        const btn = if (is_touch) events.PointerButton.primary else mouse_buttons.takeUp(pid);
                                        if (is_touch and touch_scroll.active_pointer != null and touch_scroll.active_pointer.? == pid) {
                                            var next_idx: ?usize = null;
                                            if (ptr_count > 1) {
                                                var k: usize = 0;
                                                while (k < ptr_count) : (k += 1) {
                                                    if (k == ptr_idx) continue;
                                                    if (c.AMotionEvent_getToolType(ev, k) != c.AMOTION_EVENT_TOOL_TYPE_MOUSE) {
                                                        next_idx = k;
                                                        break;
                                                    }
                                                }
                                            }
                                            if (next_idx) |nk| {
                                                const new_pid = c.AMotionEvent_getPointerId(ev, nk);
                                                const new_py = c.AMotionEvent_getY(ev, nk) / scale_factor;
                                                const ev_t = motionEventSeconds(ev);
                                                touch_scroll.active_pointer = new_pid;
                                                touch_scroll.down_y = new_py;
                                                touch_scroll.down_t = ev_t;
                                                if (touch_scroll.scrolling) {
                                                    scroller.beginDrag(@as(f64, new_py), ev_t);
                                                }
                                            } else {
                                                const was_scrolling = touch_scroll.scrolling;
                                                const was_caught = touch_scroll.caught_fling;
                                                touch_scroll.reset();
                                                if (was_scrolling) {
                                                    scroller.endDrag();
                                                    if (scroller.isAnimating()) arena.requestRedraw();
                                                } else {
                                                    if (!was_caught) {
                                                        router.dispatch(&arena, .{ .pointer_up = .{
                                                            .pointer_id = pid,
                                                            .x = px,
                                                            .y = py,
                                                            .button = btn,
                                                            .is_touch = is_touch,
                                                        } });
                                                    }
                                                    if (scroller.offset < 0.0 or scroller.offset > scroller.max_scroll) {
                                                        scroller.endDrag();
                                                        arena.requestRedraw();
                                                    }
                                                }
                                            }
                                        } else {
                                            router.dispatch(&arena, .{ .pointer_up = .{
                                                .pointer_id = pid,
                                                .x = px,
                                                .y = py,
                                                .button = btn,
                                                .is_touch = is_touch,
                                            } });
                                        }
                                        handled = 1;
                                    }
                                },
                                c.AMOTION_EVENT_ACTION_CANCEL => {
                                    var i: usize = 0;
                                    while (i < ptr_count) : (i += 1) {
                                        const pid = c.AMotionEvent_getPointerId(ev, i);
                                        mouse_buttons.remove(pid);
                                        router.dispatch(&arena, .{ .pointer_cancel = .{ .pointer_id = pid } });
                                    }
                                    if (ptr_count == 0) {
                                        mouse_buttons.clear();
                                        router.dispatch(&arena, .focus_lost);
                                    }
                                    if (touch_scroll.active_pointer != null) {
                                        const was_scrolling = touch_scroll.scrolling;
                                        touch_scroll.reset();
                                        if (was_scrolling or scroller.offset < 0.0 or scroller.offset > scroller.max_scroll) {
                                            scroller.endDrag();
                                            if (scroller.isAnimating()) arena.requestRedraw();
                                        }
                                    }
                                    handled = 1;
                                },
                                c.AMOTION_EVENT_ACTION_HOVER_MOVE => {
                                    if (ptr_count > 0) {
                                        const pid = c.AMotionEvent_getPointerId(ev, 0);
                                        const px = c.AMotionEvent_getX(ev, 0) / scale_factor;
                                        const py = c.AMotionEvent_getY(ev, 0) / scale_factor;
                                        router.dispatch(&arena, .{ .pointer_move = .{
                                            .pointer_id = pid,
                                            .x = px,
                                            .y = py,
                                            .is_touch = false,
                                        } });
                                        handled = 1;
                                    }
                                },
                                c.AMOTION_EVENT_ACTION_HOVER_EXIT => {
                                    mouse_buttons.clear();
                                    router.dispatch(&arena, .focus_lost);
                                    handled = 1;
                                },
                                c.AMOTION_EVENT_ACTION_SCROLL => {
                                    if (ptr_count > 0) {
                                        const px = c.AMotionEvent_getX(ev, 0) / scale_factor;
                                        const py = c.AMotionEvent_getY(ev, 0) / scale_factor;
                                        const dx = c.AMotionEvent_getAxisValue(ev, c.AMOTION_EVENT_AXIS_HSCROLL, 0);
                                        const dy = c.AMotionEvent_getAxisValue(ev, c.AMOTION_EVENT_AXIS_VSCROLL, 0);
                                        const axis_scroll = c.AMotionEvent_getAxisValue(ev, c.AMOTION_EVENT_AXIS_SCROLL, 0);
                                        var wheel_dy = dy;
                                        var scroll_delta_dp: f64 = -@as(f64, dy) * 48.0;
                                        if (dy == 0.0 and axis_scroll != 0.0) {
                                            const rdelta = rotary.onRotaryDelta(axis_scroll);
                                            scroll_delta_dp = @as(f64, rdelta.scroll_dy);
                                            wheel_dy = -rdelta.scroll_dy / 36.0;
                                        }
                                        router.dispatch(&arena, .{ .wheel = .{
                                            .x = px,
                                            .y = py,
                                            .dx = dx,
                                            .dy = wheel_dy,
                                        } });
                                        touch_scroll.reset();
                                        last_anim_time_s = null;
                                        anim_frames = 0;
                                        anim_dt_sum_ms = 0.0;
                                        anim_render_sum_ms = 0.0;
                                        scroller.onWheel(scroll_delta_dp);
                                        applyScroll(&arena, &scroller, showcase.scroll_container, egl.width, egl.height, scale_factor);
                                        handled = 1;
                                    }
                                },
                                else => {},
                            }
                        }
                        c.AInputQueue_finishEvent(q, ev, handled);
                    }
                }
            }

            if (quit) break;
            drain_passes += 1;
            if (drain_passes >= 4) break;
            ident = c.ALooper_pollOnce(0, null, &looper_events, &out_data);
        }

        if (quit) break;

        const lw_cur: f32 = if (egl.width > 0) @as(f32, @floatFromInt(egl.width)) / scale_factor else DEFAULT_LW;
        const lh_cur: f32 = if (egl.height > 0) @as(f32, @floatFromInt(egl.height)) / scale_factor else DEFAULT_LH;
        var need_rebuild = false;
        var tab_changed = false;
        for (router.pollEvents()) |ui_ev| {
            switch (ui_ev) {
                .toggled => |t| {
                    const ptr: [*]const u8 = if (t.test_id.len > 0) t.test_id.ptr else "";
                    logInfo("UI toggled id=%.*s checked=%d", .{
                        @as(c_int, @intCast(t.test_id.len)),
                        ptr,
                        @as(c_int, @intFromBool(t.checked)),
                    });
                },
                .changed_f32 => |chg| {
                    const same_slider = if (last_logged_slider_id) |lid|
                        (lid.index == chg.id.index and lid.gen == chg.id.gen)
                    else
                        false;
                    const delta = if (same_slider) @abs(chg.value - last_logged_slider_val) else 1.0;
                    const at_edge = (chg.value <= 0.001 or chg.value >= 0.999) and (!same_slider or @abs(chg.value - last_logged_slider_val) > 0.001);
                    if (delta >= 0.05 or at_edge or router.captured_node == null) {
                        last_logged_slider_id = chg.id;
                        last_logged_slider_val = chg.value;
                        const ptr: [*]const u8 = if (chg.test_id.len > 0) chg.test_id.ptr else "";
                        logInfo("UI changed_f32 id=%.*s value=%.3f", .{
                            @as(c_int, @intCast(chg.test_id.len)),
                            ptr,
                            @as(f64, chg.value),
                        });
                    }
                },
                else => {},
            }
            const before_tab = if (@hasField(ActiveShowcase, "active_tab")) showcase.active_tab else {};
            if (showcase.handleUiEvent(ui_ev, lw_cur, lh_cur)) {
                need_rebuild = true;
                if (@hasField(ActiveShowcase, "active_tab")) {
                    if (showcase.active_tab != before_tab) {
                        tab_changed = true;
                    }
                }
            }
        }
        router.clearEvents();
        if (need_rebuild) {
            if (tab_changed) {
                scroller.offset = 0.0;
                scroller.velocity = 0.0;
                scroller.animating = false;
                scroller.dragging = false;
                touch_scroll.reset();
                router.captured_node = null;
                router.captured_pointer_id = null;
            }
            rebuildShowcaseAndSync(&showcase, &arena, &scroller, &router, egl.width, egl.height, scale_factor);
            arena.requestRedraw();
        }

        const has_surface_now = (window != null and egl.surface != c.EGL_NO_SURFACE and rend.initialized);
        var should_render = false;
        var frame_was_animating = false;
        var frame_dt_s: f64 = 1.0 / 60.0;

        if (!has_surface_now) {
            last_anim_time_s = null;
            vsync.active = false;
            vsync.fired = false;
            redraw_pending = false;
            anim_frames = 0;
            anim_dt_sum_ms = 0.0;
            anim_render_sum_ms = 0.0;
        } else if (choreographer == null) {
            if (scroller.isAnimating()) {
                const now_s = monotonicSeconds();
                frame_dt_s = if (last_anim_time_s) |prev_t| (now_s - prev_t) else (1.0 / 60.0);
                last_anim_time_s = now_s;
                frame_was_animating = true;
                _ = scroller.step(frame_dt_s);
                applyScroll(&arena, &scroller, showcase.scroll_container, egl.width, egl.height, scale_factor);
                arena.requestRedraw();
            } else {
                last_anim_time_s = null;
            }
            should_render = arena.needsRedraw();
        } else {
            if (vsync.fired) {
                vsync.fired = false;
                frame_dt_s = if (vsync.last_frame_time_ns > 0 and vsync.frame_time_ns > vsync.last_frame_time_ns)
                    @as(f64, @floatFromInt(vsync.frame_time_ns - vsync.last_frame_time_ns)) / 1_000_000_000.0
                else
                    (1.0 / 60.0);
                vsync.last_frame_time_ns = vsync.frame_time_ns;

                if (scroller.isAnimating()) {
                    frame_was_animating = true;
                    _ = scroller.step(frame_dt_s);
                    if (showcase.scroll_container orelse arena.getRoot()) |target| {
                        arena.setScroll(target, 0.0, @floatCast(scroller.offset));
                    }
                    arena.requestRedraw();
                }
                if (arena.needsRedraw()) {
                    should_render = true;
                }
            } else if (redraw_pending and arena.needsRedraw()) {
                should_render = true;
            }
        }

        if (should_render) {
            var t0: c.struct_timespec = undefined;
            var t1: c.struct_timespec = undefined;
            _ = c.clock_gettime(c.CLOCK_MONOTONIC, &t0);

            const lw: f32 = if (egl.width > 0) @as(f32, @floatFromInt(egl.width)) / scale_factor else DEFAULT_LW;
            const lh: f32 = if (egl.height > 0) @as(f32, @floatFromInt(egl.height)) / scale_factor else DEFAULT_LH;
            if (arena.layout_dirty and egl.width > 0 and egl.height > 0) {
                arena.layout(lw, lh);
            }

            frame_idx +%= 1;
            const base_quads = arena.emitQuadsWithAtlas(quad_buf, scale_factor, atlas_ptr, frame_idx);
            const quad_count = showcase.emitPostQuads(&arena, quad_buf, base_quads, lw, lh, scale_factor, atlas_ptr, frame_idx);
            if (atlas_ptr) |a| {
                if (a.dirty) {
                    rend.uploadAtlas(a.pixels, a.width, a.height);
                    a.markUploaded();
                }
            }
            rend.render(egl.width, egl.height, quad_buf[0..quad_count]);
            const swap_ok = c.eglSwapBuffers(egl.display, egl.surface) != c.EGL_FALSE;

            if (!swap_ok) {
                const err = c.eglGetError();
                logErr("eglSwapBuffers failed (eglGetError=0x%x), recreating EGL/Renderer", .{err});
                rend.deinit();
                egl.deinit();
                if (window) |w| {
                    if (EglState.init(w)) |new_egl| {
                        egl = new_egl;
                        if (renderer.Renderer.init(ATLAS_SIZE, ATLAS_SIZE)) |new_rend| {
                            rend = new_rend;
                            if (atlas_ptr) |a| {
                                a.dirty = true;
                            }
                            rebuildShowcaseAndSync(&showcase, &arena, &scroller, &router, egl.width, egl.height, scale_factor);
                        } else |_| {
                            egl.deinit();
                        }
                    }
                }
                arena.requestRedraw();
                redraw_pending = false;
                signalRedrawAck(state);
            } else {
                const prev_w = egl.width;
                const prev_h = egl.height;
                egl.querySize();
                if ((egl.width != prev_w or egl.height != prev_h) and egl.width > 0 and egl.height > 0) {
                    rebuildShowcaseAndSync(&showcase, &arena, &scroller, &router, egl.width, egl.height, scale_factor);
                    arena.requestRedraw();
                } else {
                    arena.consumeRedraw();
                }
                redraw_pending = false;
                signalRedrawAck(state);

                _ = c.clock_gettime(c.CLOCK_MONOTONIC, &t1);
                const dt_ns: i64 = (@as(i64, t1.tv_sec) - @as(i64, t0.tv_sec)) * 1_000_000_000 +
                    (@as(i64, t1.tv_nsec) - @as(i64, t0.tv_nsec));
                const dt_ms = @as(f64, @floatFromInt(dt_ns)) / 1_000_000.0;
                showcase.last_frame_ms = @floatCast(dt_ms);
                showcase.last_quad_count = quad_count;

                if (frame_was_animating) {
                    anim_frames += 1;
                    anim_dt_sum_ms += frame_dt_s * 1000.0;
                    anim_render_sum_ms += dt_ms;
                    if (!scroller.isAnimating()) {
                        const n_f64: f64 = @floatFromInt(anim_frames);
                        logInfo("Fling settled: %u frames | avg=%.2f ms | vsync=%.2f ms | quads=%zu", .{
                            anim_frames,
                            anim_render_sum_ms / n_f64,
                            anim_dt_sum_ms / n_f64,
                            quad_count,
                        });
                        anim_frames = 0;
                        anim_dt_sum_ms = 0.0;
                        anim_render_sum_ms = 0.0;
                    }
                } else if (frame_idx <= 2) {
                    logInfo("Frame rendered: %.3f ms | quads=%zu | viewport=%dx%d | scale=%.2f", .{
                        dt_ms,
                        quad_count,
                        egl.width,
                        egl.height,
                        @as(f64, scale_factor),
                    });
                }

                if (!dumped_initial_tree) {
                    dumped_initial_tree = true;
                    dumpSemanticTreeToLogcat(&arena);
                }
            }
        }

        if (choreographer != null and !scroller.isAnimating() and !arena.needsRedraw()) {
            vsync.active = false;
        }
    }

    if (input_queue) |q| {
        c.AInputQueue_detachLooper(q);
    }
    rend.deinit();
    egl.deinit();

    _ = c.pthread_mutex_lock(&state.mutex);
    state.worker_exited = true;
    state.window_ack = true;
    state.input_ack = true;
    state.redraw_ack = true;
    _ = c.pthread_cond_broadcast(&state.cond);
    _ = c.pthread_mutex_unlock(&state.mutex);

    logInfo("Worker exiting cleanly", .{});
    return null;
}

fn getState(activity: ?*c.ANativeActivity) ?*AppState {
    const act = activity orelse return null;
    const ptr = act.instance orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn onDestroy(activity: [*c]c.ANativeActivity) callconv(.c) void {
    const state = getState(activity) orelse return;
    _ = c.pthread_mutex_lock(&state.mutex);
    state.destroy_requested = true;
    _ = c.pthread_cond_broadcast(&state.cond);
    _ = c.pthread_mutex_unlock(&state.mutex);

    _ = writeCmdByte(state.msgwrite, .destroy);
    _ = c.pthread_join(state.thread, null);

    _ = c.close(state.msgread);
    _ = c.close(state.msgwrite);
    _ = c.pthread_cond_destroy(&state.cond);
    _ = c.pthread_mutex_destroy(&state.mutex);

    activity.*.instance = null;
    std.heap.c_allocator.destroy(state);
}

fn onStart(activity: [*c]c.ANativeActivity) callconv(.c) void {
    _ = activity;
}

fn onResume(activity: [*c]c.ANativeActivity) callconv(.c) void {
    _ = activity;
}

fn onPause(activity: [*c]c.ANativeActivity) callconv(.c) void {
    const state = getState(activity) orelse return;
    _ = writeCmdByte(state.msgwrite, .cancel_pointer);
}

fn onStop(activity: [*c]c.ANativeActivity) callconv(.c) void {
    _ = activity;
}

fn onWindowFocusChanged(activity: [*c]c.ANativeActivity, has_focus: c_int) callconv(.c) void {
    if (has_focus == 0) {
        const state = getState(activity) orelse return;
        _ = writeCmdByte(state.msgwrite, .cancel_pointer);
    }
}

fn onNativeWindowCreated(activity: [*c]c.ANativeActivity, window: ?*c.ANativeWindow) callconv(.c) void {
    const state = getState(activity) orelse return;
    _ = c.pthread_mutex_lock(&state.mutex);
    if (state.worker_exited or state.destroy_requested) {
        _ = c.pthread_mutex_unlock(&state.mutex);
        return;
    }
    state.pending_window = window;
    state.window_ack = false;
    if (!writeCmdByte(state.msgwrite, .init_window)) {
        _ = c.pthread_mutex_unlock(&state.mutex);
        return;
    }
    while (!state.window_ack and !state.worker_exited and !state.destroy_requested) {
        _ = c.pthread_cond_wait(&state.cond, &state.mutex);
    }
    _ = c.pthread_mutex_unlock(&state.mutex);
}

fn onNativeWindowResized(activity: [*c]c.ANativeActivity, window: ?*c.ANativeWindow) callconv(.c) void {
    _ = window;
    const state = getState(activity) orelse return;
    _ = writeCmdByte(state.msgwrite, .resize_window);
}

fn onNativeWindowRedrawNeeded(activity: [*c]c.ANativeActivity, window: ?*c.ANativeWindow) callconv(.c) void {
    _ = window;
    const state = getState(activity) orelse return;
    _ = c.pthread_mutex_lock(&state.mutex);
    if (state.worker_exited or state.destroy_requested) {
        _ = c.pthread_mutex_unlock(&state.mutex);
        return;
    }
    state.redraw_ack = false;
    if (!writeCmdByte(state.msgwrite, .redraw_needed)) {
        state.redraw_ack = true;
        _ = c.pthread_mutex_unlock(&state.mutex);
        return;
    }
    while (!state.redraw_ack and !state.worker_exited and !state.destroy_requested) {
        _ = c.pthread_cond_wait(&state.cond, &state.mutex);
    }
    _ = c.pthread_mutex_unlock(&state.mutex);
}

fn onNativeWindowDestroyed(activity: [*c]c.ANativeActivity, window: ?*c.ANativeWindow) callconv(.c) void {
    _ = window;
    const state = getState(activity) orelse return;
    _ = c.pthread_mutex_lock(&state.mutex);
    if (state.worker_exited or state.destroy_requested) {
        _ = c.pthread_mutex_unlock(&state.mutex);
        return;
    }
    state.pending_window = null;
    state.window_ack = false;
    if (!writeCmdByte(state.msgwrite, .term_window)) {
        _ = c.pthread_mutex_unlock(&state.mutex);
        return;
    }
    while (!state.window_ack and !state.worker_exited and !state.destroy_requested) {
        _ = c.pthread_cond_wait(&state.cond, &state.mutex);
    }
    _ = c.pthread_mutex_unlock(&state.mutex);
}

fn onInputQueueCreated(activity: [*c]c.ANativeActivity, queue: ?*c.AInputQueue) callconv(.c) void {
    const state = getState(activity) orelse return;
    _ = c.pthread_mutex_lock(&state.mutex);
    if (state.worker_exited or state.destroy_requested) {
        _ = c.pthread_mutex_unlock(&state.mutex);
        return;
    }
    state.pending_input_queue = queue;
    state.input_ack = false;
    if (!writeCmdByte(state.msgwrite, .input_changed)) {
        _ = c.pthread_mutex_unlock(&state.mutex);
        return;
    }
    while (!state.input_ack and !state.worker_exited and !state.destroy_requested) {
        _ = c.pthread_cond_wait(&state.cond, &state.mutex);
    }
    _ = c.pthread_mutex_unlock(&state.mutex);
}

fn onInputQueueDestroyed(activity: [*c]c.ANativeActivity, queue: ?*c.AInputQueue) callconv(.c) void {
    _ = queue;
    const state = getState(activity) orelse return;
    _ = c.pthread_mutex_lock(&state.mutex);
    if (state.worker_exited or state.destroy_requested) {
        _ = c.pthread_mutex_unlock(&state.mutex);
        return;
    }
    state.pending_input_queue = null;
    state.input_ack = false;
    if (!writeCmdByte(state.msgwrite, .input_changed)) {
        _ = c.pthread_mutex_unlock(&state.mutex);
        return;
    }
    while (!state.input_ack and !state.worker_exited and !state.destroy_requested) {
        _ = c.pthread_cond_wait(&state.cond, &state.mutex);
    }
    _ = c.pthread_mutex_unlock(&state.mutex);
}

fn onConfigurationChanged(activity: [*c]c.ANativeActivity) callconv(.c) void {
    const state = getState(activity) orelse return;
    _ = writeCmdByte(state.msgwrite, .config_changed);
}

fn onLowMemory(activity: [*c]c.ANativeActivity) callconv(.c) void {
    _ = activity;
}

export fn ANativeActivity_onCreate(
    activity: [*c]c.ANativeActivity,
    saved_state: ?*anyopaque,
    saved_state_size: usize,
) callconv(.c) void {
    _ = saved_state;
    _ = saved_state_size;

    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) {
        logErr("pipe() failed", .{});
        return;
    }
    const flags0 = c.fcntl(fds[0], c.F_GETFL, @as(c_int, 0));
    if (flags0 >= 0) {
        _ = c.fcntl(fds[0], c.F_SETFL, flags0 | c.O_NONBLOCK);
    }
    const flags1 = c.fcntl(fds[1], c.F_GETFL, @as(c_int, 0));
    if (flags1 >= 0) {
        _ = c.fcntl(fds[1], c.F_SETFL, flags1 | c.O_NONBLOCK);
    }

    const state = std.heap.c_allocator.create(AppState) catch {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
        logErr("OOM allocating AppState", .{});
        return;
    };

    state.* = .{
        .activity = @ptrCast(activity),
        .msgread = fds[0],
        .msgwrite = fds[1],
        .mutex = undefined,
        .cond = undefined,
        .thread = undefined,
    };
    _ = c.pthread_mutex_init(&state.mutex, null);
    _ = c.pthread_cond_init(&state.cond, null);

    activity.*.callbacks.*.onDestroy = onDestroy;
    activity.*.callbacks.*.onStart = onStart;
    activity.*.callbacks.*.onResume = onResume;
    activity.*.callbacks.*.onPause = onPause;
    activity.*.callbacks.*.onStop = onStop;
    activity.*.callbacks.*.onWindowFocusChanged = onWindowFocusChanged;
    activity.*.callbacks.*.onNativeWindowCreated = onNativeWindowCreated;
    activity.*.callbacks.*.onNativeWindowResized = onNativeWindowResized;
    activity.*.callbacks.*.onNativeWindowRedrawNeeded = onNativeWindowRedrawNeeded;
    activity.*.callbacks.*.onNativeWindowDestroyed = onNativeWindowDestroyed;
    activity.*.callbacks.*.onInputQueueCreated = onInputQueueCreated;
    activity.*.callbacks.*.onInputQueueDestroyed = onInputQueueDestroyed;
    activity.*.callbacks.*.onConfigurationChanged = onConfigurationChanged;
    activity.*.callbacks.*.onLowMemory = onLowMemory;

    activity.*.instance = state;

    if (c.pthread_create(&state.thread, null, workerMain, state) != 0) {
        logErr("pthread_create failed", .{});
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
        _ = c.pthread_cond_destroy(&state.cond);
        _ = c.pthread_mutex_destroy(&state.mutex);
        activity.*.instance = null;
        std.heap.c_allocator.destroy(state);
        return;
    }

    _ = c.pthread_mutex_lock(&state.mutex);
    while (!state.running and !state.startup_failed and !state.worker_exited) {
        _ = c.pthread_cond_wait(&state.cond, &state.mutex);
    }
    const failed = state.startup_failed or state.worker_exited;
    _ = c.pthread_mutex_unlock(&state.mutex);

    if (failed) {
        logErr("Worker startup failed; cleaning up", .{});
        _ = c.pthread_join(state.thread, null);
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
        _ = c.pthread_cond_destroy(&state.cond);
        _ = c.pthread_mutex_destroy(&state.mutex);
        activity.*.instance = null;
        std.heap.c_allocator.destroy(state);
    }
}
