const std = @import("std");
const core = @import("core.zig");

const SgHandles = extern struct {
    vbuf: u32 = 0,
    ibuf: u32 = 0,
    atlas_staging: u32 = 0,
    atlas_img: u32 = 0,
    atlas_view: u32 = 0,
    atlas_smp: u32 = 0,
    shd: u32 = 0,
    pip: u32 = 0,
};

extern "c" fn huey_sg_init(
    out: *SgHandles,
    atlas_w: u32,
    atlas_h: u32,
    max_quads: usize,
    quad_stride: usize,
    quad_offsets6: [*]const usize,
    unit_quad_verts: [*]const f32,
    unit_quad_bytes: usize,
    vs_source: [*:0]const u8,
    fs_source: [*:0]const u8,
) c_int;
extern "c" fn huey_sg_deinit(h: *const SgHandles) void;
extern "c" fn huey_sg_upload_atlas(h: *const SgHandles, pixels: [*]const u8, byte_len: usize, w: u32, h_px: u32) void;
extern "c" fn huey_sg_render(
    h: *const SgHandles,
    width: i32,
    height: i32,
    quads_ptr: ?*const anyopaque,
    quad_count: usize,
    quad_stride: usize,
    clear_rgba: [*]const f32,
    round_clip: [*]const f32,
) void;

pub const MAX_QUADS: usize = 2048;
pub const DEFAULT_ATLAS_SIZE: u32 = 1024;

const unit_quad_verts = [12]f32{
    0.0, 0.0,
    1.0, 0.0,
    1.0, 1.0,
    0.0, 0.0,
    1.0, 1.0,
    0.0, 1.0,
};

const vs_source: [*:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\
    \\uniform vec2 u_viewport;
    \\
    \\layout(location = 0) in vec2 a_pos;
    \\layout(location = 1) in vec4 a_pos_size;
    \\layout(location = 2) in vec4 a_uv_rect;
    \\layout(location = 3) in vec4 a_color;
    \\layout(location = 4) in vec4 a_border_color;
    \\layout(location = 5) in vec4 a_params;
    \\layout(location = 6) in vec4 a_clip_rect;
    \\
    \\out vec2 v_local_px;
    \\flat out vec2 v_half_size;
    \\out vec2 v_uv;
    \\flat out vec4 v_color;
    \\flat out vec4 v_border_color;
    \\flat out vec4 v_color_lin;
    \\flat out vec4 v_border_lin;
    \\flat out vec4 v_params;
    \\out vec2 v_frag_px;
    \\flat out vec4 v_clip_rect;
    \\
    \\float vsSanitizeUnit(float c) {
    \\    if (isnan(c) || isinf(c) || c <= 0.0) return 0.0;
    \\    if (c >= 1.0) return 1.0;
    \\    return c;
    \\}
    \\
    \\float vsSrgbToLinearCh(float c) {
    \\    float x = vsSanitizeUnit(c);
    \\    if (x <= 0.04045) return x / 12.92;
    \\    if (x >= 1.0) return 1.0;
    \\    return vsSanitizeUnit(pow((x + 0.055) / 1.055, 2.4));
    \\}
    \\
    \\vec4 vsSrgbToLinear(vec4 c) {
    \\    return vec4(vsSrgbToLinearCh(c.r), vsSrgbToLinearCh(c.g), vsSrgbToLinearCh(c.b), vsSanitizeUnit(c.a));
    \\}
    \\
    \\void main() {
    \\    if (any(isnan(a_pos_size)) || any(isinf(a_pos_size)) || any(isnan(a_params)) || any(isinf(a_params))) {
    \\        gl_Position = vec4(-2.0, -2.0, 0.0, 1.0);
    \\        v_local_px = vec2(0.0);
    \\        v_half_size = vec2(0.0);
    \\        v_uv = vec2(0.0);
    \\        v_color = vec4(0.0);
    \\        v_border_color = vec4(0.0);
    \\        v_color_lin = vec4(0.0);
    \\        v_border_lin = vec4(0.0);
    \\        v_params = vec4(0.0);
    \\        v_frag_px = vec2(-1.0);
    \\        v_clip_rect = vec4(0.0);
    \\        return;
    \\    }
    \\    vec2 half_size = max(a_pos_size.zw, vec2(0.0)) * 0.5;
    \\    vec2 center = a_pos_size.xy + half_size;
    \\    bool is_glyph = a_params.w > 0.5;
    \\    float blur = is_glyph ? 0.0 : max(a_params.z, 0.0);
    \\    float pad = is_glyph ? 0.0 : (blur * 1.5 + 2.0);
    \\    vec2 expanded_half = half_size + vec2(pad);
    \\    vec2 local_px = (a_pos * 2.0 - 1.0) * expanded_half;
    \\    vec2 frag_px = center + local_px;
    \\
    \\    vec2 ndc = (frag_px / u_viewport) * 2.0 - 1.0;
    \\    ndc.y = -ndc.y;
    \\    gl_Position = vec4(ndc, 0.0, 1.0);
    \\
    \\    v_local_px = local_px;
    \\    v_half_size = half_size;
    \\    v_uv = mix(a_uv_rect.xy, a_uv_rect.zw, a_pos);
    \\    v_color = vec4(vsSanitizeUnit(a_color.r), vsSanitizeUnit(a_color.g), vsSanitizeUnit(a_color.b), vsSanitizeUnit(a_color.a));
    \\    v_border_color = vec4(vsSanitizeUnit(a_border_color.r), vsSanitizeUnit(a_border_color.g), vsSanitizeUnit(a_border_color.b), vsSanitizeUnit(a_border_color.a));
    \\    v_color_lin = is_glyph ? vec4(0.0) : vsSrgbToLinear(v_color);
    \\    v_border_lin = is_glyph ? vec4(0.0) : vsSrgbToLinear(v_border_color);
    \\    v_params = vec4(max(a_params.x, 0.0), max(a_params.y, 0.0), blur, a_params.w);
    \\    v_frag_px = frag_px;
    \\    v_clip_rect = a_clip_rect;
    \\}
;

const fs_source: [*:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\
    \\uniform sampler2D u_atlas;
    \\uniform vec4 u_round_clip;
    \\
    \\in vec2 v_local_px;
    \\flat in vec2 v_half_size;
    \\in vec2 v_uv;
    \\flat in vec4 v_color;
    \\flat in vec4 v_border_color;
    \\flat in vec4 v_color_lin;
    \\flat in vec4 v_border_lin;
    \\flat in vec4 v_params;
    \\in vec2 v_frag_px;
    \\flat in vec4 v_clip_rect;
    \\
    \\out vec4 frag_color;
    \\
    \\vec3 linearToSrgb(vec3 c) {
    \\    vec3 x = clamp(c, 0.0, 1.0);
    \\    vec3 lo = 12.92 * x;
    \\    vec3 hi = 1.055 * pow(max(x, vec3(0.000001)), vec3(1.0 / 2.4)) - 0.055;
    \\    return clamp(mix(lo, hi, step(vec3(0.0031308), x)), 0.0, 1.0);
    \\}
    \\
    \\float safeSmoothstep(float edge0, float edge1, float x) {
    \\    if (edge1 <= edge0) {
    \\        return x >= edge1 ? 1.0 : 0.0;
    \\    }
    \\    return smoothstep(edge0, edge1, x);
    \\}
    \\
    \\float sdRoundedBox(vec2 p, vec2 b, float r) {
    \\    vec2 q = abs(p) - b + r;
    \\    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
    \\}
    \\
    \\void main() {
    \\    if (!(v_frag_px.x >= v_clip_rect.x && v_frag_px.y >= v_clip_rect.y &&
    \\          v_frag_px.x <= v_clip_rect.z && v_frag_px.y <= v_clip_rect.w)) {
    \\        discard;
    \\    }
    \\    float round_alpha = 1.0;
    \\    if (u_round_clip.w > 0.5) {
    \\        float d_round = length(v_frag_px - u_round_clip.xy) - u_round_clip.z;
    \\        if (d_round > 0.5) {
    \\            discard;
    \\        }
    \\        round_alpha = 1.0 - safeSmoothstep(-0.5, 0.5, d_round);
    \\    }
    \\    if (v_params.w > 0.5) {
    \\        float cov = texture(u_atlas, v_uv).r;
    \\        float out_a = v_color.a * cov * round_alpha;
    \\        if (out_a < 0.0001) {
    \\            discard;
    \\        }
    \\        frag_color = vec4(v_color.rgb, out_a);
    \\        return;
    \\    }
    \\
    \\    float radius = min(v_params.x, min(v_half_size.x, v_half_size.y));
    \\    float bw = v_params.y;
    \\    float blur = v_params.z;
    \\
    \\    float d = sdRoundedBox(v_local_px, v_half_size, radius);
    \\
    \\    // Fast path for opaque solid interior pixels: 0 pow() calls!
    \\    if (d < -bw - 0.5 && v_color.a >= 0.9999) {
    \\        if (round_alpha < 0.0001) {
    \\            discard;
    \\        }
    \\        frag_color = vec4(v_color.rgb, round_alpha);
    \\        return;
    \\    }
    \\
    \\    float body_cov = 1.0 - safeSmoothstep(-0.5, 0.5, d);
    \\    vec4 fill_pm = vec4(v_color_lin.rgb * v_color_lin.a, v_color_lin.a);
    \\    vec4 border_pm = vec4(v_border_lin.rgb * v_border_lin.a, v_border_lin.a);
    \\
    \\    vec4 body_pm = fill_pm;
    \\    if (bw > 0.05) {
    \\        float border_t = safeSmoothstep(-bw - 0.5, -bw + 0.5, d);
    \\        body_pm = mix(fill_pm, border_pm, border_t);
    \\    }
    \\    vec4 fg_pm = body_pm * body_cov;
    \\
    \\    float shadow_alpha = 0.0;
    \\    float card_alpha = max(v_color.a, v_border_color.a);
    \\    if (blur > 0.5 && fg_pm.a < 0.9999 && card_alpha > 0.0001) {
    \\        float d_shadow = sdRoundedBox(v_local_px - vec2(0.0, blur * 0.25), v_half_size, radius);
    \\        shadow_alpha = (1.0 - safeSmoothstep(-blur * 0.35, blur * 1.15, d_shadow)) * 0.32 * card_alpha;
    \\    }
    \\    const vec3 kShadowLin = vec3(0.002322, 0.003096, 0.004960);
    \\    vec4 shadow_pm = vec4(kShadowLin * shadow_alpha, shadow_alpha);
    \\
    \\    vec4 out_pm = fg_pm + shadow_pm * (1.0 - fg_pm.a);
    \\    float final_a = out_pm.a * round_alpha;
    \\    if (out_pm.a < 0.0001 || final_a < 0.0001) {
    \\        discard;
    \\    }
    \\    frag_color = vec4(linearToSrgb(out_pm.rgb / out_pm.a), final_a);
    \\}
;

pub const Renderer = struct {
    initialized: bool = false,
    handles: SgHandles = .{},
    atlas_w: u32 = DEFAULT_ATLAS_SIZE,
    atlas_h: u32 = DEFAULT_ATLAS_SIZE,
    u_round_clip: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 },

    pub fn setRoundClip(self: *Renderer, cx: f32, cy: f32, radius: f32) void {
        if (!std.math.isFinite(cx) or !std.math.isFinite(cy) or !std.math.isFinite(radius) or radius <= 0.0) {
            self.clearRoundClip();
            return;
        }
        self.u_round_clip = .{ cx, cy, radius, 1.0 };
    }

    pub fn clearRoundClip(self: *Renderer) void {
        self.u_round_clip = .{ 0.0, 0.0, 0.0, 0.0 };
    }

    pub fn init(atlas_w: u32, atlas_h: u32) !Renderer {
        const eff_w: u32 = if (atlas_w > 0) atlas_w else DEFAULT_ATLAS_SIZE;
        const eff_h: u32 = if (atlas_h > 0) atlas_h else DEFAULT_ATLAS_SIZE;
        const max_c_int: usize = @intCast(std.math.maxInt(c_int));
        if (eff_w > max_c_int or eff_h > max_c_int) {
            return error.InvalidAtlasSize;
        }
        const atlas_bytes = std.math.mul(usize, @as(usize, eff_w), @as(usize, eff_h)) catch {
            return error.InvalidAtlasSize;
        };
        if (atlas_bytes > max_c_int) {
            return error.InvalidAtlasSize;
        }

        const quad_offsets = [6]usize{
            @offsetOf(core.QuadInstance, "pos_size"),
            @offsetOf(core.QuadInstance, "uv_rect"),
            @offsetOf(core.QuadInstance, "color"),
            @offsetOf(core.QuadInstance, "border_color"),
            @offsetOf(core.QuadInstance, "params"),
            @offsetOf(core.QuadInstance, "clip_rect"),
        };
        var handles: SgHandles = .{};
        const rc = huey_sg_init(
            &handles,
            eff_w,
            eff_h,
            MAX_QUADS,
            @sizeOf(core.QuadInstance),
            &quad_offsets,
            &unit_quad_verts,
            @sizeOf(@TypeOf(unit_quad_verts)),
            vs_source,
            fs_source,
        );
        if (rc == -1) return error.SokolSetupFailed;
        if (rc != 0) return error.SokolResourceInvalid;

        return .{
            .initialized = true,
            .handles = handles,
            .atlas_w = eff_w,
            .atlas_h = eff_h,
        };
    }

    pub fn deinit(self: *Renderer) void {
        if (!self.initialized) return;
        huey_sg_deinit(&self.handles);
        self.* = .{};
    }

    pub fn uploadAtlas(self: *Renderer, pixels: []const u8, w: u32, h: u32) void {
        if (!self.initialized or w == 0 or h == 0) return;
        if (w != self.atlas_w or h != self.atlas_h) return;
        const max_c_int: usize = @intCast(std.math.maxInt(c_int));
        if (w > max_c_int or h > max_c_int) return;
        const expected_len = std.math.mul(usize, @as(usize, w), @as(usize, h)) catch return;
        if (expected_len > max_c_int or pixels.len < expected_len) return;

        huey_sg_upload_atlas(&self.handles, pixels.ptr, expected_len, w, h);
    }

    pub fn render(self: *Renderer, width: i32, height: i32, quads: []const core.QuadInstance) void {
        if (!self.initialized or width <= 0 or height <= 0) return;

        const quad_count: usize = @min(quads.len, MAX_QUADS);
        const round_clip_active = self.u_round_clip[3] > 0.5;
        const clear_rgba = [4]f32{
            if (round_clip_active) 0.0 else core.Nord.polar_night_0[0],
            if (round_clip_active) 0.0 else core.Nord.polar_night_0[1],
            if (round_clip_active) 0.0 else core.Nord.polar_night_0[2],
            1.0,
        };
        huey_sg_render(
            &self.handles,
            width,
            height,
            if (quad_count > 0) quads.ptr else null,
            quad_count,
            @sizeOf(core.QuadInstance),
            &clear_rgba,
            &self.u_round_clip,
        );
    }
};
