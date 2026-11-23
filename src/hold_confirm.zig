const std = @import("std");
const core = @import("core.zig");
const animation = @import("animation.zig");
const wearos = @import("wearos.zig");

pub const MAX_SPARKS: usize = 48;

const DEFAULT_DURATION_S: f32 = 1.5;
const MIN_DURATION_S: f32 = 0.1;
const MAX_DURATION_S: f32 = 10.0;
const POINTER_SLOP_DP: f32 = 12.0;
const MAX_DT_S: f32 = 0.05;
const TRAIL_SPAWN_INTERVAL_S: f32 = 0.025;
const BURST_DURATION_S: f32 = 0.55;
const REWIND_RATE_PER_S: f32 = 3.5;
const BURST_SPARK_COUNT: usize = 24;

pub const Spark = struct {
    angle_rad: f32 = 0.0,
    radial_offset: f32 = 0.0,
    ang_vel: f32 = 0.0,
    rad_vel: f32 = 0.0,
    life: f32 = 0.0,
    max_life: f32 = 0.0,
    size: f32 = 0.0,
    color: core.Color = core.Nord.transparent,
    active: bool = false,
};

fn sanitizeDuration(duration_s: f32) f32 {
    if (!std.math.isFinite(duration_s)) return DEFAULT_DURATION_S;
    return std.math.clamp(duration_s, MIN_DURATION_S, MAX_DURATION_S);
}

fn sanitizeUnit(v: f32) f32 {
    if (!std.math.isFinite(v) or v <= 0.0) return 0.0;
    if (v >= 1.0) return 1.0;
    return v;
}

/// Interpolates Oklab color across Nord Frost (#88C0D0) -> Aurora Yellow (#EBCB8B) -> Aurora Orange (#D08770).
pub fn arcColorForProgress(t_raw: f32) core.Color {
    const t = sanitizeUnit(t_raw);
    if (t < 0.5) {
        return animation.lerpColorOklab(core.Nord.frost_1, core.Nord.aurora_yellow, t * 2.0);
    }
    return animation.lerpColorOklab(core.Nord.aurora_yellow, core.Nord.aurora_orange, (t - 0.5) * 2.0);
}

pub const HoldToConfirm = struct {
    hold_duration_s: f32 = DEFAULT_DURATION_S,
    holding: bool = false,
    active_pointer_id: ?i32 = null,
    progress: f32 = 0.0,
    fired_count: u32 = 0,
    burst_timer_s: f32 = 0.0,
    completed_this_press: bool = false,
    sparks: [MAX_SPARKS]Spark = [_]Spark{.{}} ** MAX_SPARKS,
    rng_state: u32 = 0x9E3779B9,
    spawn_accum_s: f32 = 0.0,

    pub fn init(duration_s: f32) HoldToConfirm {
        return .{
            .hold_duration_s = sanitizeDuration(duration_s),
        };
    }

    pub fn beginHold(self: *HoldToConfirm, pointer_id: i32) void {
        if (self.holding) return;
        self.holding = true;
        self.active_pointer_id = pointer_id;
        self.completed_this_press = false;
        self.progress = 0.0;
        self.burst_timer_s = 0.0;
        self.spawn_accum_s = 0.0;
    }

    pub fn updatePointerMove(self: *HoldToConfirm, pointer_id: i32, x: f32, y: f32, bounds: core.Rect) void {
        if (!self.holding) return;
        const pid = self.active_pointer_id orelse return;
        if (pid != pointer_id) return;

        const valid_pt = std.math.isFinite(x) and std.math.isFinite(y);
        const valid_bounds = std.math.isFinite(bounds.x) and std.math.isFinite(bounds.y) and
            std.math.isFinite(bounds.w) and std.math.isFinite(bounds.h) and
            bounds.w > 0.0 and bounds.h > 0.0;

        if (!valid_pt or !valid_bounds or
            x < bounds.x - POINTER_SLOP_DP or x > bounds.x + bounds.w + POINTER_SLOP_DP or
            y < bounds.y - POINTER_SLOP_DP or y > bounds.y + bounds.h + POINTER_SLOP_DP)
        {
            self.holding = false;
            self.active_pointer_id = null;
        }
    }

    pub fn endHold(self: *HoldToConfirm, pointer_id: i32) void {
        if (self.active_pointer_id) |pid| {
            if (pid == pointer_id) {
                self.holding = false;
                self.active_pointer_id = null;
                self.completed_this_press = false;
            }
        }
    }

    pub fn cancel(self: *HoldToConfirm) void {
        self.holding = false;
        self.active_pointer_id = null;
        self.completed_this_press = false;
    }

    pub fn reset(self: *HoldToConfirm) void {
        self.cancel();
        self.progress = 0.0;
        self.burst_timer_s = 0.0;
        self.spawn_accum_s = 0.0;
        for (&self.sparks) |*sp| {
            sp.active = false;
        }
    }

    pub fn activeSparkCount(self: *const HoldToConfirm) usize {
        var count: usize = 0;
        for (self.sparks) |sp| {
            if (sp.active) count += 1;
        }
        return count;
    }

    pub fn isAnimating(self: *const HoldToConfirm) bool {
        return self.holding or self.progress > 0.0 or self.burst_timer_s > 0.0 or self.activeSparkCount() > 0;
    }

    fn nextRandU32(self: *HoldToConfirm) u32 {
        var x = self.rng_state;
        if (x == 0) x = 0x9E3779B9;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.rng_state = x;
        return x;
    }

    fn nextRand01(self: *HoldToConfirm) f32 {
        return @as(f32, @floatFromInt(self.nextRandU32() >> 8)) / 16777216.0;
    }

    fn nextRandSigned(self: *HoldToConfirm) f32 {
        return self.nextRand01() * 2.0 - 1.0;
    }

    fn allocSparkSlot(self: *HoldToConfirm) *Spark {
        var oldest_idx: usize = 0;
        var min_life: f32 = std.math.floatMax(f32);
        for (&self.sparks, 0..) |*sp, i| {
            if (!sp.active) return sp;
            if (sp.life < min_life) {
                min_life = sp.life;
                oldest_idx = i;
            }
        }
        return &self.sparks[oldest_idx];
    }

    fn spawnTrailSpark(self: *HoldToConfirm, prog: f32) void {
        const slot = self.allocSparkSlot();
        const max_life = 0.24 + self.nextRand01() * 0.20;
        const base_angle = prog * std.math.tau;
        slot.* = .{
            .angle_rad = base_angle + self.nextRandSigned() * 0.04,
            .radial_offset = self.nextRandSigned() * 2.0,
            .ang_vel = -0.55 - self.nextRand01() * 0.85,
            .rad_vel = -8.0 - self.nextRand01() * 28.0 + self.nextRandSigned() * 6.0,
            .life = max_life,
            .max_life = max_life,
            .size = 0.55 + self.nextRand01() * 0.40,
            .color = arcColorForProgress(prog),
            .active = true,
        };
    }

    fn spawnBurstSparks(self: *HoldToConfirm) void {
        for (0..BURST_SPARK_COUNT) |i| {
            const slot = self.allocSparkSlot();
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(BURST_SPARK_COUNT));
            const base_angle = t * std.math.tau;
            const max_life = 0.35 + self.nextRand01() * 0.25;
            const burst_col = switch (i % 4) {
                0 => core.Nord.snow_storm_2,
                1 => core.Nord.aurora_yellow,
                2 => core.Nord.aurora_orange,
                else => core.Nord.frost_1,
            };
            slot.* = .{
                .angle_rad = base_angle + self.nextRandSigned() * 0.06,
                .radial_offset = self.nextRandSigned() * 1.5,
                .ang_vel = self.nextRandSigned() * 0.9,
                .rad_vel = -(22.0 + self.nextRand01() * 52.0),
                .life = max_life,
                .max_life = max_life,
                .size = 0.75 + self.nextRand01() * 0.45,
                .color = burst_col,
                .active = true,
            };
        }
    }

    pub fn step(self: *HoldToConfirm, dt_s: f32) bool {
        if (!std.math.isFinite(dt_s) or dt_s <= 0.0) return false;
        const dt: f32 = @min(dt_s, MAX_DT_S);

        self.hold_duration_s = sanitizeDuration(self.hold_duration_s);
        self.progress = sanitizeUnit(self.progress);
        if (!std.math.isFinite(self.burst_timer_s) or self.burst_timer_s < 0.0) {
            self.burst_timer_s = 0.0;
        }
        if (!std.math.isFinite(self.spawn_accum_s) or self.spawn_accum_s < 0.0) {
            self.spawn_accum_s = 0.0;
        }

        for (&self.sparks) |*sp| {
            if (!sp.active) continue;
            sp.life -= dt;
            if (!std.math.isFinite(sp.life) or sp.life <= 0.0) {
                sp.active = false;
                sp.life = 0.0;
                continue;
            }
            sp.angle_rad += sp.ang_vel * dt;
            sp.radial_offset += sp.rad_vel * dt;
            if (!std.math.isFinite(sp.angle_rad) or !std.math.isFinite(sp.radial_offset)) {
                sp.active = false;
            }
        }

        self.burst_timer_s = @max(0.0, self.burst_timer_s - dt);

        if (self.holding and !self.completed_this_press) {
            self.progress = @min(1.0, self.progress + dt / self.hold_duration_s);
            self.spawn_accum_s = @min(self.spawn_accum_s + dt, MAX_DT_S);
            while (self.spawn_accum_s >= TRAIL_SPAWN_INTERVAL_S) {
                self.spawn_accum_s -= TRAIL_SPAWN_INTERVAL_S;
                self.spawnTrailSpark(self.progress);
            }
            if (self.progress >= 1.0) {
                self.progress = 1.0;
                self.fired_count +%= 1;
                self.completed_this_press = true;
                self.holding = false;
                self.burst_timer_s = BURST_DURATION_S;
                self.spawn_accum_s = 0.0;
                self.spawnBurstSparks();
                return true;
            }
        } else if (self.burst_timer_s <= 0.0) {
            self.progress = @max(0.0, self.progress - dt * REWIND_RATE_PER_S);
            self.spawn_accum_s = 0.0;
        }

        return false;
    }

    pub fn emitPerimeterFireworkQuads(
        self: *const HoldToConfirm,
        out_quads: []core.QuadInstance,
        cx: f32,
        cy: f32,
        radius: f32,
        thickness: f32,
        clip_rect: [4]f32,
    ) usize {
        if (out_quads.len == 0) return 0;
        if (!std.math.isFinite(cx) or !std.math.isFinite(cy) or
            !std.math.isFinite(radius) or radius <= 0.0 or
            !std.math.isFinite(thickness) or thickness <= 0.0)
        {
            return 0;
        }
        for (clip_rect) |v| {
            if (!std.math.isFinite(v)) return 0;
        }

        const safe_prog = sanitizeUnit(self.progress);
        const safe_burst = if (std.math.isFinite(self.burst_timer_s) and self.burst_timer_s > 0.0)
            self.burst_timer_s
        else
            0.0;
        var written: usize = 0;

        if (safe_prog > 0.005) {
            const segs: usize = @max(1, @min(64, @as(usize, @intFromFloat(@ceil(safe_prog * 64.0)))));
            const dot_r = thickness * 0.5;
            const denom: f32 = if (safe_prog >= 0.9999 and segs > 1)
                @floatFromInt(segs)
            else if (segs <= 1)
                1.0
            else
                @floatFromInt(segs - 1);
            for (0..segs) |i| {
                if (written >= out_quads.len) return written;
                const frac: f32 = if (segs <= 1)
                    0.0
                else
                    @as(f32, @floatFromInt(i)) / denom;
                const angle = frac * safe_prog * std.math.tau;
                const qx = cx + radius * @sin(angle) - dot_r;
                const qy = cy - radius * @cos(angle) - dot_r;
                if (!std.math.isFinite(qx) or !std.math.isFinite(qy)) continue;

                out_quads[written] = .{
                    .pos_size = .{ qx, qy, thickness, thickness },
                    .color = core.sanitizeColor(arcColorForProgress(frac * safe_prog)),
                    .border_color = core.Nord.transparent,
                    .params = .{ dot_r, 0.0, 0.0, wearos.AMBIENT_FG_SDF_MODE },
                    .clip_rect = clip_rect,
                };
                written += 1;
            }

            // Glowing comet head at the leading edge
            if (written < out_quads.len) {
                const head_angle = safe_prog * std.math.tau;
                const head_size = thickness * 1.5;
                const head_r = head_size * 0.5;
                const hx = cx + radius * @sin(head_angle) - head_r;
                const hy = cy - radius * @cos(head_angle) - head_r;
                if (std.math.isFinite(hx) and std.math.isFinite(hy)) {
                    const head_col = animation.lerpColorOklab(core.Nord.snow_storm_2, core.Nord.aurora_yellow, 0.35);
                    out_quads[written] = .{
                        .pos_size = .{ hx, hy, head_size, head_size },
                        .color = core.sanitizeColor(head_col),
                        .border_color = core.Nord.transparent,
                        .params = .{ head_r, 0.0, thickness * 0.8, wearos.AMBIENT_FG_SDF_MODE },
                        .clip_rect = clip_rect,
                    };
                    written += 1;
                }
            }
        }

        if (safe_burst > 0.0 and written < out_quads.len) {
            const flash_alpha = std.math.clamp(safe_burst / BURST_DURATION_S, 0.0, 1.0);
            var flash_col = animation.lerpColorOklab(core.Nord.aurora_yellow, core.Nord.snow_storm_2, 0.5);
            flash_col[3] = flash_alpha;
            const ring_d = radius * 2.0;
            const rx = cx - radius;
            const ry = cy - radius;
            if (std.math.isFinite(rx) and std.math.isFinite(ry) and std.math.isFinite(ring_d) and ring_d > 0.0) {
                out_quads[written] = .{
                    .pos_size = .{ rx, ry, ring_d, ring_d },
                    .color = core.Nord.transparent,
                    .border_color = core.sanitizeColor(flash_col),
                    .params = .{ radius, thickness * (1.0 + 0.5 * flash_alpha), 0.0, wearos.AMBIENT_FG_SDF_MODE },
                    .clip_rect = clip_rect,
                };
                written += 1;
            }
        }

        for (self.sparks) |sp| {
            if (!sp.active) continue;
            if (written >= out_quads.len) return written;
            if (!std.math.isFinite(sp.angle_rad) or !std.math.isFinite(sp.radial_offset) or
                !std.math.isFinite(sp.life) or !std.math.isFinite(sp.max_life) or
                !std.math.isFinite(sp.size) or sp.max_life <= 0.0 or sp.life <= 0.0)
            {
                continue;
            }

            const life_frac = std.math.clamp(sp.life / sp.max_life, 0.0, 1.0);
            const spark_r = @max(0.0, radius + sp.radial_offset);
            const sx = cx + spark_r * @sin(sp.angle_rad);
            const sy = cy - spark_r * @cos(sp.angle_rad);
            const min_spark_d = @min(1.0, thickness * 0.5);
            const spark_d = @max(min_spark_d, thickness * std.math.clamp(sp.size, 0.1, 2.0) * (0.35 + 0.65 * life_frac));
            const half_d = spark_d * 0.5;
            const x0 = sx - half_d;
            const y0 = sy - half_d;
            if (!std.math.isFinite(x0) or !std.math.isFinite(y0) or !std.math.isFinite(spark_d)) continue;

            var col = core.sanitizeColor(sp.color);
            col[3] = std.math.clamp(col[3] * life_frac, 0.0, 1.0);

            out_quads[written] = .{
                .pos_size = .{ x0, y0, spark_d, spark_d },
                .color = col,
                .border_color = core.Nord.transparent,
                .params = .{ half_d, 0.0, 0.0, wearos.AMBIENT_FG_SDF_MODE },
                .clip_rect = clip_rect,
            };
            written += 1;
        }

        return written;
    }
};
