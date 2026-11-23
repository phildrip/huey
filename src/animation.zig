const std = @import("std");
const core = @import("core.zig");
const tokens = @import("tokens.zig");

const POOL_MAX_SPRINGS: usize = 64;
const POOL_MAX_COLORS: usize = 16;

pub const MAX_SPRINGS: usize = POOL_MAX_SPRINGS;
pub const MAX_COLORS: usize = POOL_MAX_COLORS;

const MAX_DT_S: f64 = 0.1;

fn sanitizeFinite(v: f32) f32 {
    if (!std.math.isFinite(v)) return 0.0;
    return v;
}

fn sanitizeUnit(v: f32) f32 {
    if (!std.math.isFinite(v) or v <= 0.0) return 0.0;
    if (v >= 1.0) return 1.0;
    return v;
}

fn clampF32(v: f64) f32 {
    if (!std.math.isFinite(v)) return 0.0;
    const max_f: f64 = @as(f64, std.math.floatMax(f32));
    const clamped = std.math.clamp(v, -max_f, max_f);
    const f: f32 = @floatCast(clamped);
    return if (std.math.isFinite(f)) f else 0.0;
}

fn sanitizeCfgMin(v: f32, min_v: f64) f64 {
    if (!std.math.isFinite(v)) return min_v;
    return std.math.clamp(@as(f64, v), min_v, 1.0e7);
}

pub const Easing = enum {
    linear,
    ease_in,
    ease_out,
    ease_in_out,
    ease_out_cubic,
    ease_out_quint,
    ease_out_back,
};

/// Evaluates an easing curve at normalized progress `t` in `[0, 1]`.
/// Non-finite inputs are sanitized (NaN -> 0.0) and clamped to `[0, 1]`.
pub fn evalEasing(easing: Easing, t_raw: f32) f32 {
    const t = sanitizeUnit(t_raw);
    if (t <= 0.0) return 0.0;
    if (t >= 1.0) return 1.0;

    return switch (easing) {
        .linear => t,
        .ease_in => t * t,
        .ease_out => blk: {
            const inv = 1.0 - t;
            break :blk 1.0 - inv * inv;
        },
        .ease_in_out => if (t < 0.5)
            2.0 * t * t
        else blk: {
            const u = -2.0 * t + 2.0;
            break :blk 1.0 - 0.5 * u * u;
        },
        .ease_out_cubic => blk: {
            const inv = 1.0 - t;
            break :blk 1.0 - inv * inv * inv;
        },
        .ease_out_quint => blk: {
            const inv = 1.0 - t;
            const inv2 = inv * inv;
            break :blk 1.0 - inv2 * inv2 * inv;
        },
        .ease_out_back => blk: {
            const c1: f32 = 1.70158;
            const c3: f32 = c1 + 1.0;
            const u = t - 1.0;
            break :blk 1.0 + c3 * u * u * u + c1 * u * u;
        },
    };
}

pub const SpringConfig = struct {
    stiffness: f32,
    damping: f32,
    mass: f32 = 1.0,
    pos_epsilon: f32 = 0.0005,
    vel_epsilon: f32 = 0.005,

    pub const snappy: SpringConfig = .{ .stiffness = 420.0, .damping = 34.0 };
    pub const gentle: SpringConfig = .{ .stiffness = 220.0, .damping = 26.0 };
    pub const bouncy: SpringConfig = .{ .stiffness = 320.0, .damping = 18.0 };
};

pub const SpringState = struct {
    value: f32,
    target: f32,
    velocity: f32 = 0.0,
    value_f64: f64 = 0.0,
    velocity_f64: f64 = 0.0,
    active: bool = false,

    pub fn init(initial: f32) SpringState {
        const v = sanitizeFinite(initial);
        return .{
            .value = v,
            .target = v,
            .velocity = 0.0,
            .value_f64 = @as(f64, v),
            .velocity_f64 = 0.0,
            .active = false,
        };
    }

    pub fn setTarget(self: *SpringState, new_target: f32) void {
        self.setTargetWithConfig(new_target, SpringConfig.snappy);
    }

    pub fn setTargetWithConfig(self: *SpringState, new_target: f32, cfg: SpringConfig) void {
        const safe_target = sanitizeFinite(new_target);
        self.target = safe_target;
        const target_f64: f64 = @as(f64, safe_target);
        if (!std.math.isFinite(self.value_f64)) self.value_f64 = target_f64;
        if (!std.math.isFinite(self.velocity_f64)) self.velocity_f64 = 0.0;
        if (!std.math.isFinite(self.value)) self.value = safe_target;
        if (!std.math.isFinite(self.velocity)) self.velocity = 0.0;

        const pos_eps = sanitizeCfgMin(cfg.pos_epsilon, 1.0e-6);
        const vel_eps = sanitizeCfgMin(cfg.vel_epsilon, 1.0e-6);
        const eff_pos_eps = @max(pos_eps, 2.0 * @as(f64, @abs(safe_target)) * 1.1920929e-7);

        if (@abs(target_f64 - self.value_f64) > eff_pos_eps or @abs(self.velocity_f64) > vel_eps) {
            self.active = true;
        } else {
            self.value = safe_target;
            self.velocity = 0.0;
            self.value_f64 = target_f64;
            self.velocity_f64 = 0.0;
            self.active = false;
        }
    }

    pub fn snap(self: *SpringState, val: f32) void {
        const v = sanitizeFinite(val);
        self.value = v;
        self.target = v;
        self.velocity = 0.0;
        self.value_f64 = @as(f64, v);
        self.velocity_f64 = 0.0;
        self.active = false;
    }

    pub fn isAnimating(self: SpringState) bool {
        return self.active;
    }

    /// Advances the spring using the exact closed-form analytical damped harmonic oscillator in `f64`.
    /// Returns `true` if still animating after the step.
    pub fn step(self: *SpringState, dt_s: f32, cfg: SpringConfig) bool {
        if (!self.active) return false;
        if (!std.math.isFinite(dt_s) or dt_s <= 0.0) return self.active;

        const dt = @min(@as(f64, dt_s), MAX_DT_S);
        const k = sanitizeCfgMin(cfg.stiffness, 1.0);
        const c = sanitizeCfgMin(cfg.damping, 0.1);
        const m = sanitizeCfgMin(cfg.mass, 0.01);
        const pos_eps = sanitizeCfgMin(cfg.pos_epsilon, 1.0e-6);
        const vel_eps = sanitizeCfgMin(cfg.vel_epsilon, 1.0e-6);

        self.target = sanitizeFinite(self.target);
        const target: f64 = @as(f64, self.target);
        const pos: f64 = if (std.math.isFinite(self.value_f64)) self.value_f64 else target;
        const vel: f64 = if (std.math.isFinite(self.velocity_f64)) self.velocity_f64 else 0.0;

        const x0: f64 = pos - target;
        const v0: f64 = vel;
        const w0: f64 = @sqrt(k / m);
        const zeta: f64 = c / (2.0 * @sqrt(k * m));

        var x: f64 = undefined;
        var v: f64 = undefined;

        if (zeta < 1.0 - 1.0e-6) {
            // Underdamped
            const wd = w0 * @sqrt(1.0 - zeta * zeta);
            const decay = @exp(-zeta * w0 * dt);
            const a_coef = x0;
            const b_coef = (v0 + zeta * w0 * x0) / wd;
            const cos_wd = @cos(wd * dt);
            const sin_wd = @sin(wd * dt);
            x = decay * (a_coef * cos_wd + b_coef * sin_wd);
            v = decay * ((b_coef * wd - a_coef * zeta * w0) * cos_wd - (a_coef * wd + b_coef * zeta * w0) * sin_wd);
        } else if (@abs(zeta - 1.0) <= 1.0e-6) {
            // Critically damped
            const decay = @exp(-w0 * dt);
            const a_coef = x0;
            const b_coef = v0 + w0 * x0;
            x = decay * (a_coef + b_coef * dt);
            v = decay * (b_coef - w0 * (a_coef + b_coef * dt));
        } else {
            // Overdamped
            const s = @sqrt(zeta * zeta - 1.0);
            const r1 = -w0 / (zeta + s); // -w0 * (zeta - s), cancellation-free for large zeta
            const r2 = -w0 * (zeta + s);
            const c1 = (v0 - r2 * x0) / (r1 - r2);
            const c2 = x0 - c1;
            const e1 = @exp(r1 * dt);
            const e2 = @exp(r2 * dt);
            x = c1 * e1 + c2 * e2;
            v = c1 * r1 * e1 + c2 * r2 * e2;
        }

        const eff_pos_eps = @max(pos_eps, 2.0 * @as(f64, @abs(self.target)) * 1.1920929e-7);
        const next_pos = target + x;
        if (!std.math.isFinite(next_pos) or !std.math.isFinite(v) or
            (@abs(x) <= eff_pos_eps and @abs(v) <= vel_eps))
        {
            self.value = self.target;
            self.velocity = 0.0;
            self.value_f64 = target;
            self.velocity_f64 = 0.0;
            self.active = false;
            return false;
        }

        self.value_f64 = next_pos;
        self.velocity_f64 = v;
        self.value = clampF32(next_pos);
        self.velocity = clampF32(v);
        return true;
    }
};

pub const TweenState = struct {
    from: f32,
    to: f32,
    duration_s: f64,
    elapsed_s: f64,
    easing: Easing,
    active: bool,

    pub fn init(from: f32, to: f32, duration_s: f32, easing: Easing) TweenState {
        const safe_from = sanitizeFinite(from);
        const safe_to = sanitizeFinite(to);
        const safe_dur: f64 = if (std.math.isFinite(duration_s) and duration_s > 0.0) @as(f64, duration_s) else 0.0;
        if (safe_dur <= 0.0 or @abs(@as(f64, safe_to) - @as(f64, safe_from)) <= 1.0e-6) {
            return .{
                .from = safe_to,
                .to = safe_to,
                .duration_s = safe_dur,
                .elapsed_s = safe_dur,
                .easing = easing,
                .active = false,
            };
        }
        return .{
            .from = safe_from,
            .to = safe_to,
            .duration_s = safe_dur,
            .elapsed_s = 0.0,
            .easing = easing,
            .active = true,
        };
    }

    pub fn setTarget(self: *TweenState, new_to: f32, duration_s: f32, easing: Easing) void {
        const safe_to = sanitizeFinite(new_to);
        const safe_dur: f64 = if (std.math.isFinite(duration_s) and duration_s > 0.0) @as(f64, duration_s) else 0.0;
        if (safe_dur > 0.0 and @abs(@as(f64, safe_to) - @as(f64, self.to)) <= 1.0e-6) {
            return;
        }
        const cur = self.value();
        self.easing = easing;
        if (safe_dur <= 0.0 or @abs(@as(f64, safe_to) - @as(f64, cur)) <= 1.0e-6) {
            self.from = safe_to;
            self.to = safe_to;
            self.duration_s = safe_dur;
            self.elapsed_s = safe_dur;
            self.active = false;
            return;
        }
        self.from = cur;
        self.to = safe_to;
        self.duration_s = safe_dur;
        self.elapsed_s = 0.0;
        self.active = true;
    }

    pub fn value(self: TweenState) f32 {
        if (!self.active or self.duration_s <= 0.0 or self.elapsed_s >= self.duration_s) {
            return sanitizeFinite(self.to);
        }
        const t = sanitizeUnit(@floatCast(self.elapsed_s / self.duration_s));
        const e: f64 = @as(f64, evalEasing(self.easing, t));
        const res = @as(f64, self.from) + (@as(f64, self.to) - @as(f64, self.from)) * e;
        return clampF32(res);
    }

    pub fn step(self: *TweenState, dt_s: f32) bool {
        if (!self.active) return false;
        if (!std.math.isFinite(dt_s) or dt_s <= 0.0) return self.active;

        self.elapsed_s += @as(f64, dt_s);
        if (!std.math.isFinite(self.elapsed_s) or self.duration_s <= 0.0 or self.elapsed_s >= self.duration_s) {
            self.elapsed_s = self.duration_s;
            self.active = false;
            return false;
        }
        return true;
    }

    pub fn isAnimating(self: TweenState) bool {
        return self.active;
    }
};

/// Linearly interpolates two sRGB colors in perceptual Oklab space (plus alpha).
pub fn lerpColorOklab(a: core.Color, b: core.Color, t_raw: f32) core.Color {
    const t = sanitizeUnit(t_raw);
    const sa = core.sanitizeColor(a);
    const sb = core.sanitizeColor(b);
    if (t <= 0.0) return sa;
    if (t >= 1.0) return sb;

    if (sa[3] <= 0.0001 and sb[3] <= 0.0001) {
        return .{ sa[0], sa[1], sa[2], sa[3] + (sb[3] - sa[3]) * t };
    }
    if (sa[3] <= 0.0001) {
        return .{ sb[0], sb[1], sb[2], sa[3] + (sb[3] - sa[3]) * t };
    }
    if (sb[3] <= 0.0001) {
        return .{ sa[0], sa[1], sa[2], sa[3] + (sb[3] - sa[3]) * t };
    }

    const oa = tokens.OklabColor.fromSrgb(sa);
    const ob = tokens.OklabColor.fromSrgb(sb);
    const blended: tokens.OklabColor = .{
        .l = oa.l + (ob.l - oa.l) * t,
        .a = oa.a + (ob.a - oa.a) * t,
        .b = oa.b + (ob.b - oa.b) * t,
        .alpha = oa.alpha + (ob.alpha - oa.alpha) * t,
    };
    return blended.toSrgb();
}

/// Computes a deterministic 64-bit Wyhash key from widget `id` and property `prop`.
pub fn hashKey(id: []const u8, prop: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    var len_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_buf, @intCast(id.len), .little);
    hasher.update(&len_buf);
    hasher.update(id);
    std.mem.writeInt(u64, &len_buf, @intCast(prop.len), .little);
    hasher.update(&len_buf);
    hasher.update(prop);
    const h = hasher.final();
    return if (h == 0) 1 else h;
}

const SpringEntry = struct {
    key: u64 = 0,
    spring: SpringState = SpringState.init(0.0),
    cfg: SpringConfig = SpringConfig.snappy,
    last_touch: u64 = 0,
};

const ColorEntry = struct {
    key: u64 = 0,
    from_color: core.Color = .{ 0.0, 0.0, 0.0, 0.0 },
    to_color: core.Color = .{ 0.0, 0.0, 0.0, 0.0 },
    spring: SpringState = SpringState.init(1.0),
    cfg: SpringConfig = SpringConfig.gentle,
    last_touch: u64 = 0,
};

fn colorChanged(a: core.Color, b: core.Color) bool {
    return @abs(a[0] - b[0]) > 1.0e-5 or
        @abs(a[1] - b[1]) > 1.0e-5 or
        @abs(a[2] - b[2]) > 1.0e-5 or
        @abs(a[3] - b[3]) > 1.0e-5;
}

/// Zero-allocation fixed-capacity pool of retained float and Oklab color springs with LRU eviction.
pub const AnimationPool = struct {
    pub const MAX_SPRINGS: usize = POOL_MAX_SPRINGS;
    pub const MAX_COLORS: usize = POOL_MAX_COLORS;

    springs: [POOL_MAX_SPRINGS]SpringEntry = @splat(.{}),
    spring_count: usize = 0,
    colors: [POOL_MAX_COLORS]ColorEntry = @splat(.{}),
    color_count: usize = 0,
    touch_counter: u64 = 0,
    reduced_motion: bool = false,

    pub fn init() AnimationPool {
        return .{};
    }

    fn nextTouch(self: *AnimationPool) u64 {
        self.touch_counter +%= 1;
        if (self.touch_counter == 0) self.touch_counter = 1;
        return self.touch_counter;
    }

    fn findLruIndex(self: *const AnimationPool, comptime EntryT: type, entries: []const EntryT) usize {
        var settled_idx: ?usize = null;
        var max_settled_age: u64 = 0;
        var active_idx: usize = 0;
        var max_active_age: u64 = 0;
        var has_active = false;

        for (entries, 0..) |entry, idx| {
            const age = self.touch_counter -% entry.last_touch;
            if (!entry.spring.active) {
                if (settled_idx == null or age > max_settled_age) {
                    settled_idx = idx;
                    max_settled_age = age;
                }
            } else {
                if (!has_active or age > max_active_age) {
                    active_idx = idx;
                    max_active_age = age;
                    has_active = true;
                }
            }
        }
        return settled_idx orelse active_idx;
    }

    pub fn setReducedMotion(self: *AnimationPool, enabled: bool) void {
        self.reduced_motion = enabled;
        if (enabled) {
            self.snapAllActive();
        }
    }

    fn snapAllActive(self: *AnimationPool) void {
        for (self.springs[0..self.spring_count]) |*entry| {
            if (entry.spring.active) {
                entry.spring.snap(entry.spring.target);
            }
        }
        for (self.colors[0..self.color_count]) |*entry| {
            if (entry.spring.active) {
                entry.from_color = entry.to_color;
                entry.spring.snap(1.0);
            }
        }
    }

    pub fn animateSpring(self: *AnimationPool, key: u64, target_raw: f32, cfg: SpringConfig) f32 {
        const k: u64 = if (key == 0) 1 else key;
        const target = sanitizeFinite(target_raw);
        const touch = self.nextTouch();

        for (self.springs[0..self.spring_count]) |*entry| {
            if (entry.key == k) {
                entry.last_touch = touch;
                if (self.reduced_motion) {
                    entry.spring.snap(target);
                    entry.cfg = cfg;
                    return entry.spring.value;
                }
                if (@abs(@as(f64, entry.spring.target) - @as(f64, target)) > 1.0e-6) {
                    entry.spring.setTargetWithConfig(target, cfg);
                    entry.cfg = cfg;
                }
                return entry.spring.value;
            }
        }

        const slot_idx = if (self.spring_count < POOL_MAX_SPRINGS) blk: {
            const idx = self.spring_count;
            self.spring_count += 1;
            break :blk idx;
        } else self.findLruIndex(SpringEntry, self.springs[0..POOL_MAX_SPRINGS]);

        self.springs[slot_idx] = .{
            .key = k,
            .spring = SpringState.init(target),
            .cfg = cfg,
            .last_touch = touch,
        };
        return self.springs[slot_idx].spring.value;
    }

    pub fn snapSpring(self: *AnimationPool, key: u64, value_raw: f32) void {
        const k: u64 = if (key == 0) 1 else key;
        const val = sanitizeFinite(value_raw);
        const touch = self.nextTouch();

        for (self.springs[0..self.spring_count]) |*entry| {
            if (entry.key == k) {
                entry.last_touch = touch;
                entry.spring.snap(val);
                return;
            }
        }

        const slot_idx = if (self.spring_count < POOL_MAX_SPRINGS) blk: {
            const idx = self.spring_count;
            self.spring_count += 1;
            break :blk idx;
        } else self.findLruIndex(SpringEntry, self.springs[0..POOL_MAX_SPRINGS]);

        self.springs[slot_idx] = .{
            .key = k,
            .spring = SpringState.init(val),
            .cfg = SpringConfig.snappy,
            .last_touch = touch,
        };
    }

    pub fn restartSpring(self: *AnimationPool, key: u64, from_raw: f32, target_raw: f32, cfg: SpringConfig) void {
        const target = sanitizeFinite(target_raw);
        if (self.reduced_motion) {
            self.snapSpring(key, target);
            return;
        }
        self.snapSpring(key, from_raw);
        _ = self.animateSpring(key, target, cfg);
    }

    pub fn animateColor(self: *AnimationPool, key: u64, target_raw: core.Color, cfg: SpringConfig) core.Color {
        const k: u64 = if (key == 0) 1 else key;
        const target = core.sanitizeColor(target_raw);
        const touch = self.nextTouch();

        for (self.colors[0..self.color_count]) |*entry| {
            if (entry.key == k) {
                entry.last_touch = touch;
                if (self.reduced_motion) {
                    entry.from_color = target;
                    entry.to_color = target;
                    entry.spring.snap(1.0);
                    entry.cfg = cfg;
                    return entry.to_color;
                }
                if (colorChanged(entry.to_color, target)) {
                    const current = if (!entry.spring.active)
                        entry.to_color
                    else
                        lerpColorOklab(entry.from_color, entry.to_color, entry.spring.value);
                    if (!colorChanged(current, target)) {
                        entry.from_color = target;
                        entry.to_color = target;
                        entry.spring.snap(1.0);
                        entry.cfg = cfg;
                        return target;
                    }
                    entry.from_color = current;
                    entry.to_color = target;
                    entry.spring.snap(0.0);
                    entry.spring.setTargetWithConfig(1.0, cfg);
                    entry.cfg = cfg;
                }
                if (!entry.spring.active) return entry.to_color;
                return lerpColorOklab(entry.from_color, entry.to_color, entry.spring.value);
            }
        }

        const slot_idx = if (self.color_count < POOL_MAX_COLORS) blk: {
            const idx = self.color_count;
            self.color_count += 1;
            break :blk idx;
        } else self.findLruIndex(ColorEntry, self.colors[0..POOL_MAX_COLORS]);

        self.colors[slot_idx] = .{
            .key = k,
            .from_color = target,
            .to_color = target,
            .spring = SpringState.init(1.0),
            .cfg = cfg,
            .last_touch = touch,
        };
        return target;
    }

    pub fn step(self: *AnimationPool, dt_s: f32) bool {
        if (self.reduced_motion) {
            self.snapAllActive();
            return false;
        }
        var any_active = false;
        for (self.springs[0..self.spring_count]) |*entry| {
            if (entry.spring.active) {
                if (entry.spring.step(dt_s, entry.cfg)) {
                    any_active = true;
                }
            }
        }
        for (self.colors[0..self.color_count]) |*entry| {
            if (entry.spring.active) {
                if (entry.spring.step(dt_s, entry.cfg)) {
                    any_active = true;
                }
            }
        }
        return any_active;
    }

    pub fn isAnimating(self: *const AnimationPool) bool {
        if (self.reduced_motion) return false;
        for (self.springs[0..self.spring_count]) |entry| {
            if (entry.spring.active) return true;
        }
        for (self.colors[0..self.color_count]) |entry| {
            if (entry.spring.active) return true;
        }
        return false;
    }
};
