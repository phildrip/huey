const std = @import("std");
const core = @import("core.zig");

const sg = @cImport({
    @cDefine("SOKOL_GLES3", "1");
    @cInclude("sokol_gfx.h");
});

extern fn __android_log_print(prio: c_int, tag: [*:0]const u8, fmt: [*:0]const u8, ...) c_int;

const ANDROID_LOG_INFO: c_int = 4;
const ANDROID_LOG_WARN: c_int = 5;
const ANDROID_LOG_ERROR: c_int = 6;

fn sokolLogger(
    tag: [*c]const u8,
    log_level: u32,
    log_item_id: u32,
    message_or_null: [*c]const u8,
    line_nr: u32,
    filename_or_null: [*c]const u8,
    user_data: ?*anyopaque,
) callconv(.c) void {
    _ = user_data;
    const prio: c_int = switch (log_level) {
        0, 1 => ANDROID_LOG_ERROR,
        2 => ANDROID_LOG_WARN,
        else => ANDROID_LOG_INFO,
    };
    const msg: [*:0]const u8 = if (message_or_null != null) message_or_null else "(null)";
    const file: [*:0]const u8 = if (filename_or_null != null) filename_or_null else "?";
    const t: [*:0]const u8 = if (tag != null) tag else "sg";
    _ = __android_log_print(
        prio,
        "ZigGuiSpike",
        "[%s] id=%u (%s:%u): %s",
        t,
        log_item_id,
        file,
        line_nr,
        msg,
    );
}

pub const MAX_QUADS: usize = 2048;
pub const DEFAULT_ATLAS_SIZE: u32 = 1024;

const VsParams = extern struct {
    u_viewport: [2]f32,
};

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
    \\    if (v_params.w > 0.5) {
    \\        float cov = texture(u_atlas, v_uv).r;
    \\        float out_a = v_color.a * cov;
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
    \\        frag_color = vec4(v_color.rgb, 1.0);
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
    \\    if (blur > 0.5 && fg_pm.a < 0.9999) {
    \\        float d_shadow = sdRoundedBox(v_local_px - vec2(0.0, blur * 0.25), v_half_size, radius);
    \\        shadow_alpha = (1.0 - safeSmoothstep(-blur * 0.35, blur * 1.15, d_shadow)) * 0.32;
    \\    }
    \\    const vec3 kShadowLin = vec3(0.002322, 0.003096, 0.004960);
    \\    vec4 shadow_pm = vec4(kShadowLin * shadow_alpha, shadow_alpha);
    \\
    \\    vec4 out_pm = fg_pm + shadow_pm * (1.0 - fg_pm.a);
    \\    if (out_pm.a < 0.0001) {
    \\        discard;
    \\    }
    \\    frag_color = vec4(linearToSrgb(out_pm.rgb / out_pm.a), out_pm.a);
    \\}
;

pub const Renderer = struct {
    initialized: bool = false,
    vbuf: sg.sg_buffer = .{ .id = 0 },
    ibuf: sg.sg_buffer = .{ .id = 0 },
    atlas_staging: sg.sg_buffer = .{ .id = 0 },
    atlas_img: sg.sg_image = .{ .id = 0 },
    atlas_view: sg.sg_view = .{ .id = 0 },
    atlas_smp: sg.sg_sampler = .{ .id = 0 },
    shd: sg.sg_shader = .{ .id = 0 },
    pip: sg.sg_pipeline = .{ .id = 0 },
    atlas_w: u32 = DEFAULT_ATLAS_SIZE,
    atlas_h: u32 = DEFAULT_ATLAS_SIZE,

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

        var desc = std.mem.zeroes(sg.sg_desc);
        desc.environment.defaults.color_format = sg.SG_PIXELFORMAT_RGBA8;
        desc.environment.defaults.depth_format = sg.SG_PIXELFORMAT_NONE;
        desc.environment.defaults.sample_count = 1;
        desc.logger.func = sokolLogger;
        sg.sg_setup(&desc);

        if (!sg.sg_isvalid()) {
            _ = __android_log_print(ANDROID_LOG_ERROR, "ZigGuiSpike", "sg_setup failed: sg_isvalid() is false");
            return error.SokolSetupFailed;
        }

        var vbuf_desc = std.mem.zeroes(sg.sg_buffer_desc);
        vbuf_desc.usage.vertex_buffer = true;
        vbuf_desc.data = .{
            .ptr = &unit_quad_verts,
            .size = @sizeOf(@TypeOf(unit_quad_verts)),
        };
        vbuf_desc.label = "uberquad_verts";
        const vbuf = sg.sg_make_buffer(&vbuf_desc);

        var ibuf_desc = std.mem.zeroes(sg.sg_buffer_desc);
        ibuf_desc.size = MAX_QUADS * @sizeOf(core.QuadInstance);
        ibuf_desc.usage.vertex_buffer = true;
        ibuf_desc.usage.write_transient = true;
        ibuf_desc.label = "uberquad_instances";
        const ibuf = sg.sg_make_buffer(&ibuf_desc);

        var stg_desc = std.mem.zeroes(sg.sg_buffer_desc);
        stg_desc.size = atlas_bytes;
        stg_desc.usage = .{
            .staging_buffer = true,
            .write_transient = true,
            .copy_src = true,
        };
        stg_desc.label = "glyph_atlas_staging";
        const atlas_staging = sg.sg_make_buffer(&stg_desc);

        var img_desc = std.mem.zeroes(sg.sg_image_desc);
        img_desc.type = sg.SG_IMAGETYPE_2D;
        img_desc.usage.copy_dst = true;
        img_desc.width = @intCast(eff_w);
        img_desc.height = @intCast(eff_h);
        img_desc.num_slices = 1;
        img_desc.num_mipmaps = 1;
        img_desc.pixel_format = sg.SG_PIXELFORMAT_R8;
        img_desc.sample_count = 1;
        img_desc.label = "glyph_atlas_img";
        const atlas_img = sg.sg_make_image(&img_desc);

        var view_desc = std.mem.zeroes(sg.sg_view_desc);
        view_desc.texture.image = atlas_img;
        view_desc.label = "glyph_atlas_view";
        const atlas_view = sg.sg_make_view(&view_desc);

        var smp_desc = std.mem.zeroes(sg.sg_sampler_desc);
        smp_desc.min_filter = sg.SG_FILTER_LINEAR;
        smp_desc.mag_filter = sg.SG_FILTER_LINEAR;
        smp_desc.mipmap_filter = sg.SG_FILTER_NEAREST;
        smp_desc.wrap_u = sg.SG_WRAP_CLAMP_TO_EDGE;
        smp_desc.wrap_v = sg.SG_WRAP_CLAMP_TO_EDGE;
        smp_desc.wrap_w = sg.SG_WRAP_CLAMP_TO_EDGE;
        smp_desc.label = "glyph_atlas_smp";
        const atlas_smp = sg.sg_make_sampler(&smp_desc);

        var shd_desc = std.mem.zeroes(sg.sg_shader_desc);
        shd_desc.vertex_func.source = vs_source;
        shd_desc.fragment_func.source = fs_source;
        shd_desc.attrs[0] = .{ .base_type = sg.SG_SHADERATTRBASETYPE_FLOAT, .glsl_name = "a_pos" };
        shd_desc.attrs[1] = .{ .base_type = sg.SG_SHADERATTRBASETYPE_FLOAT, .glsl_name = "a_pos_size" };
        shd_desc.attrs[2] = .{ .base_type = sg.SG_SHADERATTRBASETYPE_FLOAT, .glsl_name = "a_uv_rect" };
        shd_desc.attrs[3] = .{ .base_type = sg.SG_SHADERATTRBASETYPE_FLOAT, .glsl_name = "a_color" };
        shd_desc.attrs[4] = .{ .base_type = sg.SG_SHADERATTRBASETYPE_FLOAT, .glsl_name = "a_border_color" };
        shd_desc.attrs[5] = .{ .base_type = sg.SG_SHADERATTRBASETYPE_FLOAT, .glsl_name = "a_params" };
        shd_desc.attrs[6] = .{ .base_type = sg.SG_SHADERATTRBASETYPE_FLOAT, .glsl_name = "a_clip_rect" };
        shd_desc.uniform_blocks[0].stage = sg.SG_SHADERSTAGE_VERTEX;
        shd_desc.uniform_blocks[0].size = @sizeOf(VsParams);
        shd_desc.uniform_blocks[0].layout = sg.SG_UNIFORMLAYOUT_NATIVE;
        shd_desc.uniform_blocks[0].glsl_uniforms[0] = .{
            .type = sg.SG_UNIFORMTYPE_FLOAT2,
            .array_count = 1,
            .glsl_name = "u_viewport",
        };
        shd_desc.views[0].texture = .{
            .stage = sg.SG_SHADERSTAGE_FRAGMENT,
            .image_type = sg.SG_IMAGETYPE_2D,
            .sample_type = sg.SG_IMAGESAMPLETYPE_FLOAT,
        };
        shd_desc.samplers[0] = .{
            .stage = sg.SG_SHADERSTAGE_FRAGMENT,
            .sampler_type = sg.SG_SAMPLERTYPE_FILTERING,
        };
        shd_desc.texture_sampler_pairs[0] = .{
            .stage = sg.SG_SHADERSTAGE_FRAGMENT,
            .view_slot = 0,
            .sampler_slot = 0,
            .glsl_name = "u_atlas",
        };
        shd_desc.label = "uberquad_shader";
        const shd = sg.sg_make_shader(&shd_desc);

        var pip_desc = std.mem.zeroes(sg.sg_pipeline_desc);
        pip_desc.shader = shd;
        pip_desc.layout.buffers[0] = .{
            .stride = 2 * @sizeOf(f32),
            .step_func = sg.SG_VERTEXSTEP_PER_VERTEX,
            .step_rate = 1,
        };
        pip_desc.layout.buffers[1] = .{
            .stride = @sizeOf(core.QuadInstance),
            .step_func = sg.SG_VERTEXSTEP_PER_INSTANCE,
            .step_rate = 1,
        };
        pip_desc.layout.attrs[0] = .{
            .buffer_index = 0,
            .offset = 0,
            .format = sg.SG_VERTEXFORMAT_FLOAT2,
        };
        pip_desc.layout.attrs[1] = .{
            .buffer_index = 1,
            .offset = @offsetOf(core.QuadInstance, "pos_size"),
            .format = sg.SG_VERTEXFORMAT_FLOAT4,
        };
        pip_desc.layout.attrs[2] = .{
            .buffer_index = 1,
            .offset = @offsetOf(core.QuadInstance, "uv_rect"),
            .format = sg.SG_VERTEXFORMAT_FLOAT4,
        };
        pip_desc.layout.attrs[3] = .{
            .buffer_index = 1,
            .offset = @offsetOf(core.QuadInstance, "color"),
            .format = sg.SG_VERTEXFORMAT_FLOAT4,
        };
        pip_desc.layout.attrs[4] = .{
            .buffer_index = 1,
            .offset = @offsetOf(core.QuadInstance, "border_color"),
            .format = sg.SG_VERTEXFORMAT_FLOAT4,
        };
        pip_desc.layout.attrs[5] = .{
            .buffer_index = 1,
            .offset = @offsetOf(core.QuadInstance, "params"),
            .format = sg.SG_VERTEXFORMAT_FLOAT4,
        };
        pip_desc.layout.attrs[6] = .{
            .buffer_index = 1,
            .offset = @offsetOf(core.QuadInstance, "clip_rect"),
            .format = sg.SG_VERTEXFORMAT_FLOAT4,
        };
        pip_desc.color_count = 1;
        pip_desc.colors[0].pixel_format = sg.SG_PIXELFORMAT_RGBA8;
        pip_desc.colors[0].blend = .{
            .enabled = true,
            .src_factor_rgb = sg.SG_BLENDFACTOR_SRC_ALPHA,
            .dst_factor_rgb = sg.SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
            .op_rgb = sg.SG_BLENDOP_ADD,
            .src_factor_alpha = sg.SG_BLENDFACTOR_ONE,
            .dst_factor_alpha = sg.SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
            .op_alpha = sg.SG_BLENDOP_ADD,
        };
        pip_desc.primitive_type = sg.SG_PRIMITIVETYPE_TRIANGLES;
        pip_desc.cull_mode = sg.SG_CULLMODE_NONE;
        pip_desc.label = "uberquad_pipeline";
        const pip = sg.sg_make_pipeline(&pip_desc);

        const vbuf_ok = sg.sg_query_buffer_state(vbuf) == sg.SG_RESOURCESTATE_VALID;
        const ibuf_ok = sg.sg_query_buffer_state(ibuf) == sg.SG_RESOURCESTATE_VALID;
        const stg_ok = sg.sg_query_buffer_state(atlas_staging) == sg.SG_RESOURCESTATE_VALID;
        const img_ok = sg.sg_query_image_state(atlas_img) == sg.SG_RESOURCESTATE_VALID;
        const view_ok = sg.sg_query_view_state(atlas_view) == sg.SG_RESOURCESTATE_VALID;
        const smp_ok = sg.sg_query_sampler_state(atlas_smp) == sg.SG_RESOURCESTATE_VALID;
        const shd_ok = sg.sg_query_shader_state(shd) == sg.SG_RESOURCESTATE_VALID;
        const pip_ok = sg.sg_query_pipeline_state(pip) == sg.SG_RESOURCESTATE_VALID;

        if (!vbuf_ok or !ibuf_ok or !stg_ok or !img_ok or !view_ok or !smp_ok or !shd_ok or !pip_ok) {
            _ = __android_log_print(
                ANDROID_LOG_ERROR,
                "ZigGuiSpike",
                "Renderer resource validation failed (vbuf=%d ibuf=%d stg=%d img=%d view=%d smp=%d shd=%d pip=%d)",
                @as(c_int, @intFromBool(vbuf_ok)),
                @as(c_int, @intFromBool(ibuf_ok)),
                @as(c_int, @intFromBool(stg_ok)),
                @as(c_int, @intFromBool(img_ok)),
                @as(c_int, @intFromBool(view_ok)),
                @as(c_int, @intFromBool(smp_ok)),
                @as(c_int, @intFromBool(shd_ok)),
                @as(c_int, @intFromBool(pip_ok)),
            );
            sg.sg_destroy_pipeline(pip);
            sg.sg_destroy_shader(shd);
            sg.sg_destroy_view(atlas_view);
            sg.sg_destroy_sampler(atlas_smp);
            sg.sg_destroy_image(atlas_img);
            sg.sg_destroy_buffer(atlas_staging);
            sg.sg_destroy_buffer(ibuf);
            sg.sg_destroy_buffer(vbuf);
            sg.sg_shutdown();
            return error.SokolResourceInvalid;
        }

        return .{
            .initialized = true,
            .vbuf = vbuf,
            .ibuf = ibuf,
            .atlas_staging = atlas_staging,
            .atlas_img = atlas_img,
            .atlas_view = atlas_view,
            .atlas_smp = atlas_smp,
            .shd = shd,
            .pip = pip,
            .atlas_w = eff_w,
            .atlas_h = eff_h,
        };
    }

    pub fn deinit(self: *Renderer) void {
        if (!self.initialized) return;
        sg.sg_destroy_pipeline(self.pip);
        sg.sg_destroy_shader(self.shd);
        sg.sg_destroy_view(self.atlas_view);
        sg.sg_destroy_sampler(self.atlas_smp);
        sg.sg_destroy_image(self.atlas_img);
        sg.sg_destroy_buffer(self.atlas_staging);
        sg.sg_destroy_buffer(self.ibuf);
        sg.sg_destroy_buffer(self.vbuf);
        sg.sg_shutdown();
        self.* = .{};
    }

    pub fn uploadAtlas(self: *Renderer, pixels: []const u8, w: u32, h: u32) void {
        if (!self.initialized or w == 0 or h == 0) return;
        if (w != self.atlas_w or h != self.atlas_h) return;
        const max_c_int: usize = @intCast(std.math.maxInt(c_int));
        if (w > max_c_int or h > max_c_int) return;
        const expected_len = std.math.mul(usize, @as(usize, w), @as(usize, h)) catch return;
        if (expected_len > max_c_int or pixels.len < expected_len) return;

        var wb = std.mem.zeroes(sg.sg_write_buffer_desc);
        wb.src.data = .{
            .ptr = pixels.ptr,
            .size = expected_len,
        };
        wb.dst.buffer = self.atlas_staging;
        wb.dst.offset = 0;
        wb.size = expected_len;
        sg.sg_write_buffer_transient(&wb);

        var cpy = std.mem.zeroes(sg.sg_copy_buffer_to_image_desc);
        cpy.src = .{
            .buffer = self.atlas_staging,
            .offset = 0,
            .bytes_per_row = @intCast(w),
            .bytes_per_slice = @intCast(expected_len),
        };
        cpy.dst = .{
            .image = self.atlas_img,
            .mip_level = 0,
            .x = 0,
            .y = 0,
            .slice = 0,
        };
        cpy.size = .{
            .width = @intCast(w),
            .height = @intCast(h),
            .num_slices = 1,
        };
        sg.sg_copy_buffer_to_image(&cpy);
    }

    pub fn render(self: *Renderer, width: i32, height: i32, quads: []const core.QuadInstance) void {
        if (!self.initialized or width <= 0 or height <= 0) return;

        const quad_count: usize = @min(quads.len, MAX_QUADS);
        if (quad_count > 0) {
            const byte_size: usize = quad_count * @sizeOf(core.QuadInstance);
            var write_desc = std.mem.zeroes(sg.sg_write_buffer_desc);
            write_desc.src.data = .{
                .ptr = quads.ptr,
                .size = byte_size,
            };
            write_desc.dst.buffer = self.ibuf;
            write_desc.size = byte_size;
            sg.sg_write_buffer_transient(&write_desc);
        }

        var pass = std.mem.zeroes(sg.sg_pass);
        pass.action.colors[0] = .{
            .load_action = sg.SG_LOADACTION_CLEAR,
            .store_action = sg.SG_STOREACTION_STORE,
            .clear_value = .{
                .r = core.Nord.polar_night_0[0],
                .g = core.Nord.polar_night_0[1],
                .b = core.Nord.polar_night_0[2],
                .a = 1.0,
            },
        };
        pass.swapchain.width = width;
        pass.swapchain.height = height;
        pass.swapchain.sample_count = 1;
        pass.swapchain.color_format = sg.SG_PIXELFORMAT_RGBA8;
        pass.swapchain.depth_format = sg.SG_PIXELFORMAT_NONE;
        pass.swapchain.gl.framebuffer = 0;

        sg.sg_begin_pass(&pass);
        if (quad_count > 0) {
            sg.sg_apply_pipeline(self.pip);

            var bind = std.mem.zeroes(sg.sg_bindings);
            bind.vertex_buffers[0] = self.vbuf;
            bind.vertex_buffers[1] = self.ibuf;
            bind.views[0] = self.atlas_view;
            bind.samplers[0] = self.atlas_smp;
            sg.sg_apply_bindings(&bind);

            var vs_params = VsParams{
                .u_viewport = .{
                    @floatFromInt(width),
                    @floatFromInt(height),
                },
            };
            sg.sg_apply_uniforms(0, &sg.sg_range{
                .ptr = &vs_params,
                .size = @sizeOf(VsParams),
            });

            sg.sg_draw(0, 6, @intCast(quad_count));
        }
        sg.sg_end_pass();
        sg.sg_commit();
    }
};
