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

pub const MAX_QUADS: usize = 256;

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
    \\layout(location = 2) in vec4 a_color;
    \\layout(location = 3) in vec4 a_border_color;
    \\layout(location = 4) in vec4 a_params;
    \\
    \\out vec2 v_local_px;
    \\out vec2 v_half_size;
    \\out vec4 v_color;
    \\out vec4 v_border_color;
    \\out vec4 v_params;
    \\
    \\void main() {
    \\    vec2 half_size = max(a_pos_size.zw, vec2(0.0)) * 0.5;
    \\    vec2 center = a_pos_size.xy + half_size;
    \\    float blur = max(a_params.z, 0.0);
    \\    float pad = blur * 1.5 + 2.0;
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
    \\    v_color = a_color;
    \\    v_border_color = a_border_color;
    \\    v_params = vec4(max(a_params.x, 0.0), max(a_params.y, 0.0), blur, a_params.w);
    \\}
;

const fs_source: [*:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\
    \\in vec2 v_local_px;
    \\in vec2 v_half_size;
    \\in vec4 v_color;
    \\in vec4 v_border_color;
    \\in vec4 v_params;
    \\
    \\out vec4 frag_color;
    \\
    \\float sdRoundedBox(vec2 p, vec2 b, float r) {
    \\    vec2 q = abs(p) - b + r;
    \\    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
    \\}
    \\
    \\void main() {
    \\    float radius = min(max(v_params.x, 0.0), min(v_half_size.x, v_half_size.y));
    \\    float bw = max(v_params.y, 0.0);
    \\    float blur = max(v_params.z, 0.0);
    \\
    \\    float d = sdRoundedBox(v_local_px, v_half_size, radius);
    \\    float body_cov = 1.0 - smoothstep(-0.5, 0.5, d);
    \\
    \\    vec4 fill_pm = vec4(v_color.rgb * v_color.a, v_color.a);
    \\    vec4 border_pm = vec4(v_border_color.rgb * v_border_color.a, v_border_color.a);
    \\
    \\    vec4 body_pm = fill_pm;
    \\    if (bw > 0.05) {
    \\        float border_t = smoothstep(-bw - 0.5, -bw + 0.5, d);
    \\        body_pm = mix(fill_pm, border_pm, border_t);
    \\    }
    \\    vec4 fg_pm = body_pm * body_cov;
    \\
    \\    float shadow_alpha = 0.0;
    \\    if (blur > 0.5) {
    \\        float d_shadow = sdRoundedBox(v_local_px - vec2(0.0, blur * 0.25), v_half_size, radius);
    \\        shadow_alpha = (1.0 - smoothstep(-blur * 0.35, blur * 1.15, d_shadow)) * 0.32;
    \\    }
    \\    vec4 shadow_pm = vec4(vec3(0.03, 0.04, 0.06) * shadow_alpha, shadow_alpha);
    \\
    \\    vec4 out_pm = fg_pm + shadow_pm * (1.0 - fg_pm.a);
    \\    if (out_pm.a < 0.001) {
    \\        discard;
    \\    }
    \\    frag_color = vec4(out_pm.rgb / out_pm.a, out_pm.a);
    \\}
;

pub const Renderer = struct {
    initialized: bool = false,
    vbuf: sg.sg_buffer = .{ .id = 0 },
    ibuf: sg.sg_buffer = .{ .id = 0 },
    shd: sg.sg_shader = .{ .id = 0 },
    pip: sg.sg_pipeline = .{ .id = 0 },

    pub fn init() !Renderer {
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

        var shd_desc = std.mem.zeroes(sg.sg_shader_desc);
        shd_desc.vertex_func.source = vs_source;
        shd_desc.fragment_func.source = fs_source;
        shd_desc.attrs[0] = .{ .base_type = sg.SG_SHADERATTRBASETYPE_FLOAT, .glsl_name = "a_pos" };
        shd_desc.attrs[1] = .{ .base_type = sg.SG_SHADERATTRBASETYPE_FLOAT, .glsl_name = "a_pos_size" };
        shd_desc.attrs[2] = .{ .base_type = sg.SG_SHADERATTRBASETYPE_FLOAT, .glsl_name = "a_color" };
        shd_desc.attrs[3] = .{ .base_type = sg.SG_SHADERATTRBASETYPE_FLOAT, .glsl_name = "a_border_color" };
        shd_desc.attrs[4] = .{ .base_type = sg.SG_SHADERATTRBASETYPE_FLOAT, .glsl_name = "a_params" };
        shd_desc.uniform_blocks[0].stage = sg.SG_SHADERSTAGE_VERTEX;
        shd_desc.uniform_blocks[0].size = @sizeOf(VsParams);
        shd_desc.uniform_blocks[0].layout = sg.SG_UNIFORMLAYOUT_NATIVE;
        shd_desc.uniform_blocks[0].glsl_uniforms[0] = .{
            .type = sg.SG_UNIFORMTYPE_FLOAT2,
            .array_count = 1,
            .glsl_name = "u_viewport",
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
            .offset = @offsetOf(core.QuadInstance, "color"),
            .format = sg.SG_VERTEXFORMAT_FLOAT4,
        };
        pip_desc.layout.attrs[3] = .{
            .buffer_index = 1,
            .offset = @offsetOf(core.QuadInstance, "border_color"),
            .format = sg.SG_VERTEXFORMAT_FLOAT4,
        };
        pip_desc.layout.attrs[4] = .{
            .buffer_index = 1,
            .offset = @offsetOf(core.QuadInstance, "params"),
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
        const shd_ok = sg.sg_query_shader_state(shd) == sg.SG_RESOURCESTATE_VALID;
        const pip_ok = sg.sg_query_pipeline_state(pip) == sg.SG_RESOURCESTATE_VALID;

        if (!vbuf_ok or !ibuf_ok or !shd_ok or !pip_ok) {
            _ = __android_log_print(
                ANDROID_LOG_ERROR,
                "ZigGuiSpike",
                "Renderer resource validation failed (vbuf=%d ibuf=%d shd=%d pip=%d)",
                @as(c_int, @intFromBool(vbuf_ok)),
                @as(c_int, @intFromBool(ibuf_ok)),
                @as(c_int, @intFromBool(shd_ok)),
                @as(c_int, @intFromBool(pip_ok)),
            );
            sg.sg_destroy_pipeline(pip);
            sg.sg_destroy_shader(shd);
            sg.sg_destroy_buffer(ibuf);
            sg.sg_destroy_buffer(vbuf);
            sg.sg_shutdown();
            return error.SokolResourceInvalid;
        }

        return .{
            .initialized = true,
            .vbuf = vbuf,
            .ibuf = ibuf,
            .shd = shd,
            .pip = pip,
        };
    }

    pub fn deinit(self: *Renderer) void {
        if (!self.initialized) return;
        sg.sg_destroy_pipeline(self.pip);
        sg.sg_destroy_shader(self.shd);
        sg.sg_destroy_buffer(self.ibuf);
        sg.sg_destroy_buffer(self.vbuf);
        sg.sg_shutdown();
        self.* = .{};
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
