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
    \\flat out vec4 v_uv_rect;
    \\flat out vec4 v_color;
    \\flat out vec4 v_border_color;
    \\flat out vec4 v_color_lin;
    \\flat out vec4 v_border_lin;
    \\flat out vec4 v_aux_lin;
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
    \\    float mode = a_params.w;
    \\    if (any(isnan(a_pos_size)) || any(isinf(a_pos_size)) ||
    \\        a_pos_size.z <= 0.0 || a_pos_size.w <= 0.0 ||
    \\        any(isnan(a_params)) || any(isinf(a_params)) ||
    \\        (mode >= 0.5 && (any(isnan(a_uv_rect)) || any(isinf(a_uv_rect))))) {
    \\        gl_Position = vec4(-2.0, -2.0, 0.0, 1.0);
    \\        v_local_px = vec2(0.0);
    \\        v_half_size = vec2(0.0);
    \\        v_uv = vec2(0.0);
    \\        v_uv_rect = vec4(0.0);
    \\        v_color = vec4(0.0);
    \\        v_border_color = vec4(0.0);
    \\        v_color_lin = vec4(0.0);
    \\        v_border_lin = vec4(0.0);
    \\        v_aux_lin = vec4(0.0);
    \\        v_params = vec4(0.0);
    \\        v_frag_px = vec2(-1.0);
    \\        v_clip_rect = vec4(0.0);
    \\        return;
    \\    }
    \\    vec2 half_size = max(a_pos_size.zw, vec2(0.0)) * 0.5;
    \\    vec2 center = a_pos_size.xy + half_size;
    \\    bool is_glyph = (mode >= 0.5 && mode < 1.5);
    \\    bool is_surface = (mode >= 2.5 && mode < 3.5);
    \\    bool is_capsule = (mode >= 3.5);
    \\    float blur = is_glyph ? 0.0 : max(a_params.z, 0.0);
    \\    float pad = is_glyph ? 0.0 : (blur * 1.5 + 2.0);
    \\    vec2 extent_half = half_size;
    \\    if (is_glyph) {
    \\        if (abs(a_params.x) >= 0.0001) {
    \\            float cg = cos(a_params.x);
    \\            float sg = sin(a_params.x);
    \\            extent_half = vec2(
    \\                abs(cg) * half_size.x + abs(sg) * half_size.y,
    \\                abs(sg) * half_size.x + abs(cg) * half_size.y
    \\            );
    \\            pad = 1.0;
    \\        }
    \\    } else if (is_capsule) {
    \\        float cc = cos(a_uv_rect.x);
    \\        float sc = sin(a_uv_rect.x);
    \\        extent_half = vec2(
    \\            abs(cc) * half_size.x + abs(sc) * half_size.y,
    \\            abs(sc) * half_size.x + abs(cc) * half_size.y
    \\        );
    \\    }
    \\    vec2 expanded_half = extent_half + vec2(pad);
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
    \\    v_uv_rect = a_uv_rect;
    \\    v_color = vec4(vsSanitizeUnit(a_color.r), vsSanitizeUnit(a_color.g), vsSanitizeUnit(a_color.b), vsSanitizeUnit(a_color.a));
    \\    v_border_color = vec4(vsSanitizeUnit(a_border_color.r), vsSanitizeUnit(a_border_color.g), vsSanitizeUnit(a_border_color.b), vsSanitizeUnit(a_border_color.a));
    \\    v_color_lin = is_glyph ? vec4(0.0) : vsSrgbToLinear(v_color);
    \\    v_border_lin = is_glyph ? vec4(0.0) : vsSrgbToLinear(v_border_color);
    \\    v_aux_lin = is_surface
    \\        ? vsSrgbToLinear(vec4(vsSanitizeUnit(a_uv_rect.r), vsSanitizeUnit(a_uv_rect.g), vsSanitizeUnit(a_uv_rect.b), v_color.a))
    \\        : vec4(0.0);
    \\    float p0 = is_glyph ? a_params.x : max(a_params.x, 0.0);
    \\    v_params = vec4(p0, max(a_params.y, 0.0), blur, mode);
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
    \\flat in vec4 v_uv_rect;
    \\flat in vec4 v_color;
    \\flat in vec4 v_border_color;
    \\flat in vec4 v_color_lin;
    \\flat in vec4 v_border_lin;
    \\flat in vec4 v_aux_lin;
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
    \\    float mode = v_params.w;
    \\    if (mode >= 0.5 && mode < 1.5) {
    \\        float cov = 0.0;
    \\        if (abs(v_params.x) < 0.0001) {
    \\            cov = texture(u_atlas, v_uv).r;
    \\        } else {
    \\            if (v_half_size.x <= 0.0 || v_half_size.y <= 0.0) {
    \\                discard;
    \\            }
    \\            float cg = cos(v_params.x);
    \\            float sg = sin(v_params.x);
    \\            vec2 p_g = vec2(cg * v_local_px.x + sg * v_local_px.y,
    \\                           -sg * v_local_px.x + cg * v_local_px.y);
    \\            float dx = abs(p_g.x) - v_half_size.x;
    \\            float dy = abs(p_g.y) - v_half_size.y;
    \\            if (dx > 0.5 || dy > 0.5) {
    \\                discard;
    \\            }
    \\            float edge_cov = (1.0 - safeSmoothstep(-0.5, 0.5, dx)) *
    \\                             (1.0 - safeSmoothstep(-0.5, 0.5, dy));
    \\            vec2 uv_t = clamp(p_g / (v_half_size * 2.0) + 0.5, 0.0, 1.0);
    \\            vec2 glyph_uv = mix(v_uv_rect.xy, v_uv_rect.zw, uv_t);
    \\            cov = texture(u_atlas, glyph_uv).r * edge_cov;
    \\        }
    \\        float out_a = v_color.a * cov * round_alpha;
    \\        if (out_a < 0.0001) {
    \\            discard;
    \\        }
    \\        frag_color = vec4(v_color.rgb, out_a);
    \\        return;
    \\    }
    \\
    \\    if (mode < 0.5) {
    \\        float radius = min(v_params.x, min(v_half_size.x, v_half_size.y));
    \\        float bw = v_params.y;
    \\        float blur = v_params.z;
    \\
    \\        float d = sdRoundedBox(v_local_px, v_half_size, radius);
    \\
    \\        // Fast path for opaque solid interior pixels: 0 pow() calls!
    \\        if (d < -bw - 0.5 && v_color.a >= 0.9999) {
    \\            if (round_alpha < 0.0001) {
    \\                discard;
    \\            }
    \\            frag_color = vec4(v_color.rgb, round_alpha);
    \\            return;
    \\        }
    \\
    \\        float body_cov = 1.0 - safeSmoothstep(-0.5, 0.5, d);
    \\        vec4 fill_pm = vec4(v_color_lin.rgb * v_color_lin.a, v_color_lin.a);
    \\        vec4 border_pm = vec4(v_border_lin.rgb * v_border_lin.a, v_border_lin.a);
    \\
    \\        vec4 body_pm = fill_pm;
    \\        if (bw > 0.05) {
    \\            float border_t = safeSmoothstep(-bw - 0.5, -bw + 0.5, d);
    \\            body_pm = mix(fill_pm, border_pm, border_t);
    \\        }
    \\        vec4 fg_pm = body_pm * body_cov;
    \\
    \\        float shadow_alpha = 0.0;
    \\        float card_alpha = max(v_color.a, v_border_color.a);
    \\        if (blur > 0.5 && fg_pm.a < 0.9999 && card_alpha > 0.0001) {
    \\            float d_shadow = sdRoundedBox(v_local_px - vec2(0.0, blur * 0.25), v_half_size, radius);
    \\            shadow_alpha = (1.0 - safeSmoothstep(-blur * 0.35, blur * 1.15, d_shadow)) * 0.32 * card_alpha;
    \\        }
    \\        const vec3 kShadowLin = vec3(0.002322, 0.003096, 0.004960);
    \\        vec4 shadow_pm = vec4(kShadowLin * shadow_alpha, shadow_alpha);
    \\
    \\        vec4 out_pm = fg_pm + shadow_pm * (1.0 - fg_pm.a);
    \\        float final_a = out_pm.a * round_alpha;
    \\        if (out_pm.a < 0.0001 || final_a < 0.0001) {
    \\            discard;
    \\        }
    \\        frag_color = vec4(linearToSrgb(out_pm.rgb / out_pm.a), final_a);
    \\        return;
    \\    }
    \\
    \\    if (mode < 2.5) {
    \\        float thickness = v_params.y;
    \\        float sweep = clamp(v_uv_rect.y, 0.0, 6.28318530718);
    \\        if (thickness <= 0.0 || sweep <= 0.0) {
    \\            discard;
    \\        }
    \\        float half_t = thickness * 0.5;
    \\        float r_arc = (v_params.x > 0.0) ? v_params.x : max(min(v_half_size.x, v_half_size.y) - half_t, 0.0);
    \\        float d_arc = 0.0;
    \\        if (sweep >= 6.28218530718) {
    \\            d_arc = abs(length(v_local_px) - r_arc) - half_t;
    \\        } else {
    \\            float half_sweep = sweep * 0.5;
    \\            float mid_a = v_uv_rect.x + half_sweep;
    \\            float cm = cos(mid_a);
    \\            float sm = sin(mid_a);
    \\            vec2 p_a = vec2(cm * v_local_px.x + sm * v_local_px.y,
    \\                           abs(-sm * v_local_px.x + cm * v_local_px.y));
    \\            vec2 sc = vec2(cos(half_sweep), sin(half_sweep));
    \\            float dist_center = (sc.y * p_a.x - sc.x * p_a.y >= 0.0)
    \\                ? abs(length(p_a) - r_arc)
    \\                : length(p_a - r_arc * sc);
    \\            d_arc = dist_center - half_t;
    \\        }
    \\        float body_cov = 1.0 - safeSmoothstep(-0.5, 0.5, d_arc);
    \\        vec4 fill_pm = vec4(v_color_lin.rgb * v_color_lin.a, v_color_lin.a);
    \\        vec4 fg_pm = fill_pm * body_cov;
    \\        float blur = v_params.z;
    \\        float glow_alpha = 0.0;
    \\        if (blur > 0.5 && fg_pm.a < 0.9999 && v_color.a > 0.0001) {
    \\            float g = 1.0 - safeSmoothstep(0.0, blur * 1.25, max(d_arc, 0.0));
    \\            glow_alpha = g * g * 0.45 * v_color.a;
    \\        }
    \\        vec4 glow_pm = vec4(v_color_lin.rgb * glow_alpha, glow_alpha);
    \\        vec4 out_pm = fg_pm + glow_pm * (1.0 - fg_pm.a);
    \\        float final_a = out_pm.a * round_alpha;
    \\        if (out_pm.a < 0.0001 || final_a < 0.0001) {
    \\            discard;
    \\        }
    \\        frag_color = vec4(linearToSrgb(out_pm.rgb / out_pm.a), final_a);
    \\        return;
    \\    }
    \\
    \\    if (mode < 3.5) {
    \\        float radius = min(v_params.x, min(v_half_size.x, v_half_size.y));
    \\        float bw = v_params.y;
    \\        float blur = v_params.z;
    \\        float d = sdRoundedBox(v_local_px, v_half_size, radius);
    \\        float body_cov = 1.0 - safeSmoothstep(-0.5, 0.5, d);
    \\
    \\        float grad_t = clamp((v_local_px.y + v_half_size.y) / max(v_half_size.y * 2.0, 0.0001), 0.0, 1.0);
    \\        vec4 grad_lin = mix(v_color_lin, v_aux_lin, grad_t);
    \\        vec4 fill_pm = vec4(grad_lin.rgb * grad_lin.a, grad_lin.a);
    \\
    \\        float top_spec = clamp(v_uv_rect.w, 0.0, 1.0);
    \\        if (top_spec > 0.0001 && v_color.a > 0.0001) {
    \\            float rim_inset = (bw > 0.05) ? bw : 0.0;
    \\            float rim_dist = -d - rim_inset;
    \\            float fade_h = max(min(v_half_size.y * 0.5, max(radius + 4.0, 12.0)), 1.5);
    \\            float top_t = clamp(1.0 - (v_local_px.y + v_half_size.y) / fade_h, 0.0, 1.0);
    \\            float rim_mask = (1.0 - safeSmoothstep(0.0, 1.8, max(rim_dist, 0.0))) *
    \\                             safeSmoothstep(-0.25, 0.25, rim_dist);
    \\            float spec_a = top_spec * rim_mask * top_t * v_color.a;
    \\            fill_pm = vec4(1.0, 1.0, 1.0, 1.0) * spec_a + fill_pm * (1.0 - spec_a);
    \\        }
    \\
    \\        vec4 border_pm = vec4(v_border_lin.rgb * v_border_lin.a, v_border_lin.a);
    \\        vec4 body_pm = fill_pm;
    \\        if (bw > 0.05) {
    \\            float border_t = safeSmoothstep(-bw - 0.5, -bw + 0.5, d);
    \\            body_pm = mix(fill_pm, border_pm, border_t);
    \\        }
    \\        vec4 fg_pm = body_pm * body_cov;
    \\
    \\        float glow_alpha = 0.0;
    \\        if (blur > 0.5 && fg_pm.a < 0.9999 && v_border_color.a > 0.0001) {
    \\            float g = 1.0 - safeSmoothstep(0.0, blur * 1.25, max(d, 0.0));
    \\            glow_alpha = g * g * 0.45 * v_border_color.a;
    \\        }
    \\        vec4 glow_pm = vec4(v_border_lin.rgb * glow_alpha, glow_alpha);
    \\        vec4 out_pm = fg_pm + glow_pm * (1.0 - fg_pm.a);
    \\        float final_a = out_pm.a * round_alpha;
    \\        if (out_pm.a < 0.0001 || final_a < 0.0001) {
    \\            discard;
    \\        }
    \\        frag_color = vec4(linearToSrgb(out_pm.rgb / out_pm.a), final_a);
    \\        return;
    \\    }
    \\
    \\    // QUAD_MODE_CAPSULE (mode >= 3.5)
    \\    float radius = min(v_params.x, min(v_half_size.x, v_half_size.y));
    \\    float bw = v_params.y;
    \\    float blur = v_params.z;
    \\    float cc = cos(v_uv_rect.x);
    \\    float sc = sin(v_uv_rect.x);
    \\    vec2 p_c = vec2(cc * v_local_px.x + sc * v_local_px.y,
    \\                   -sc * v_local_px.x + cc * v_local_px.y);
    \\    float d = sdRoundedBox(p_c, v_half_size, radius);
    \\    float body_cov = 1.0 - safeSmoothstep(-0.5, 0.5, d);
    \\
    \\    vec4 fill_pm = vec4(v_color_lin.rgb * v_color_lin.a, v_color_lin.a);
    \\    vec4 border_pm = vec4(v_border_lin.rgb * v_border_lin.a, v_border_lin.a);
    \\    vec4 body_pm = fill_pm;
    \\    if (bw > 0.05) {
    \\        float border_t = safeSmoothstep(-bw - 0.5, -bw + 0.5, d);
    \\        body_pm = mix(fill_pm, border_pm, border_t);
    \\    }
    \\    vec4 fg_pm = body_pm * body_cov;
    \\
    \\    float glow_alpha = 0.0;
    \\    if (blur > 0.5 && fg_pm.a < 0.9999 && v_color.a > 0.0001) {
    \\        float g = 1.0 - safeSmoothstep(0.0, blur * 1.25, max(d, 0.0));
    \\        glow_alpha = g * g * 0.45 * v_color.a;
    \\    }
    \\    vec4 glow_pm = vec4(v_color_lin.rgb * glow_alpha, glow_alpha);
    \\    vec4 out_pm = fg_pm + glow_pm * (1.0 - fg_pm.a);
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
