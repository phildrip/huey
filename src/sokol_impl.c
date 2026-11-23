#if defined(__ANDROID__)
// Force GLES 3.1 header selection in sokol_gfx.h so we don't pull GLES 3.2
// symbols (glColorMaski, glCopyImageSubData, glDrawElementsBaseVertex) on
// Android 7.x GLES 3.1 devices such as Nexus 9.
#include <android/api-level.h>
#include <android/log.h>
#undef __ANDROID_API__
#define __ANDROID_API__ 21
#endif

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define SOKOL_GFX_IMPL
#define SOKOL_GLES3
#include "sokol_gfx.h"

typedef struct HueySgHandles {
    uint32_t vbuf;
    uint32_t ibuf;
    uint32_t atlas_staging;
    uint32_t atlas_img;
    uint32_t atlas_view;
    uint32_t atlas_smp;
    uint32_t shd;
    uint32_t pip;
} HueySgHandles;

typedef struct HueyVsParams {
    float u_viewport[2];
} HueyVsParams;

typedef struct HueyFsParams {
    float u_round_clip[4];
} HueyFsParams;

static void huey_log_err(const char *msg) {
#if defined(__ANDROID__)
    __android_log_print(ANDROID_LOG_ERROR, "Huey", "%s", msg);
#else
    fprintf(stderr, "Huey: %s\n", msg);
#endif
}

static void huey_sokol_logger(
    const char *tag,
    uint32_t log_level,
    uint32_t log_item_id,
    const char *message_or_null,
    uint32_t line_nr,
    const char *filename_or_null,
    void *user_data
) {
    (void)user_data;
    const char *msg = message_or_null ? message_or_null : "(null)";
    const char *file = filename_or_null ? filename_or_null : "?";
    const char *t = tag ? tag : "sg";
#if defined(__ANDROID__)
    int prio = ANDROID_LOG_INFO;
    if (log_level == 0 || log_level == 1) {
        prio = ANDROID_LOG_ERROR;
    } else if (log_level == 2) {
        prio = ANDROID_LOG_WARN;
    }
    __android_log_print(prio, "Huey", "[%s] id=%u (%s:%u): %s", t, log_item_id, file, line_nr, msg);
#else
    (void)log_level;
    fprintf(stderr, "Huey [%s] id=%u (%s:%u): %s\n", t, log_item_id, file, line_nr, msg);
#endif
}

int huey_sg_init(
    HueySgHandles *out,
    uint32_t atlas_w,
    uint32_t atlas_h,
    size_t max_quads,
    size_t quad_stride,
    const size_t *quad_offsets6,
    const float *unit_quad_verts,
    size_t unit_quad_bytes,
    const char *vs_source,
    const char *fs_source
) {
    memset(out, 0, sizeof(*out));

    sg_desc desc = {0};
    desc.environment.defaults.color_format = SG_PIXELFORMAT_RGBA8;
    desc.environment.defaults.depth_format = SG_PIXELFORMAT_NONE;
    desc.environment.defaults.sample_count = 1;
    desc.logger.func = huey_sokol_logger;
    sg_setup(&desc);

    if (!sg_isvalid()) {
        huey_log_err("sg_setup failed: sg_isvalid() is false");
        return -1;
    }

    sg_buffer_desc vbuf_desc = {0};
    vbuf_desc.usage.vertex_buffer = true;
    vbuf_desc.data.ptr = unit_quad_verts;
    vbuf_desc.data.size = unit_quad_bytes;
    vbuf_desc.label = "uberquad_verts";
    sg_buffer vbuf = sg_make_buffer(&vbuf_desc);

    sg_buffer_desc ibuf_desc = {0};
    ibuf_desc.size = max_quads * quad_stride;
    ibuf_desc.usage.vertex_buffer = true;
    ibuf_desc.usage.write_transient = true;
    ibuf_desc.label = "uberquad_instances";
    sg_buffer ibuf = sg_make_buffer(&ibuf_desc);

    sg_buffer_desc stg_desc = {0};
    stg_desc.size = (size_t)atlas_w * (size_t)atlas_h;
    stg_desc.usage.staging_buffer = true;
    stg_desc.usage.write_transient = true;
    stg_desc.usage.copy_src = true;
    stg_desc.label = "glyph_atlas_staging";
    sg_buffer atlas_staging = sg_make_buffer(&stg_desc);

    sg_image_desc img_desc = {0};
    img_desc.type = SG_IMAGETYPE_2D;
    img_desc.usage.copy_dst = true;
    img_desc.width = (int)atlas_w;
    img_desc.height = (int)atlas_h;
    img_desc.num_slices = 1;
    img_desc.num_mipmaps = 1;
    img_desc.pixel_format = SG_PIXELFORMAT_R8;
    img_desc.sample_count = 1;
    img_desc.label = "glyph_atlas_img";
    sg_image atlas_img = sg_make_image(&img_desc);

    sg_view_desc view_desc = {0};
    view_desc.texture.image = atlas_img;
    view_desc.label = "glyph_atlas_view";
    sg_view atlas_view = sg_make_view(&view_desc);

    sg_sampler_desc smp_desc = {0};
    smp_desc.min_filter = SG_FILTER_LINEAR;
    smp_desc.mag_filter = SG_FILTER_LINEAR;
    smp_desc.mipmap_filter = SG_FILTER_NEAREST;
    smp_desc.wrap_u = SG_WRAP_CLAMP_TO_EDGE;
    smp_desc.wrap_v = SG_WRAP_CLAMP_TO_EDGE;
    smp_desc.wrap_w = SG_WRAP_CLAMP_TO_EDGE;
    smp_desc.label = "glyph_atlas_smp";
    sg_sampler atlas_smp = sg_make_sampler(&smp_desc);

    sg_shader_desc shd_desc = {0};
    shd_desc.vertex_func.source = vs_source;
    shd_desc.fragment_func.source = fs_source;
    shd_desc.attrs[0] = (sg_shader_vertex_attr){ .base_type = SG_SHADERATTRBASETYPE_FLOAT, .glsl_name = "a_pos" };
    shd_desc.attrs[1] = (sg_shader_vertex_attr){ .base_type = SG_SHADERATTRBASETYPE_FLOAT, .glsl_name = "a_pos_size" };
    shd_desc.attrs[2] = (sg_shader_vertex_attr){ .base_type = SG_SHADERATTRBASETYPE_FLOAT, .glsl_name = "a_uv_rect" };
    shd_desc.attrs[3] = (sg_shader_vertex_attr){ .base_type = SG_SHADERATTRBASETYPE_FLOAT, .glsl_name = "a_color" };
    shd_desc.attrs[4] = (sg_shader_vertex_attr){ .base_type = SG_SHADERATTRBASETYPE_FLOAT, .glsl_name = "a_border_color" };
    shd_desc.attrs[5] = (sg_shader_vertex_attr){ .base_type = SG_SHADERATTRBASETYPE_FLOAT, .glsl_name = "a_params" };
    shd_desc.attrs[6] = (sg_shader_vertex_attr){ .base_type = SG_SHADERATTRBASETYPE_FLOAT, .glsl_name = "a_clip_rect" };
    shd_desc.uniform_blocks[0].stage = SG_SHADERSTAGE_VERTEX;
    shd_desc.uniform_blocks[0].size = sizeof(HueyVsParams);
    shd_desc.uniform_blocks[0].layout = SG_UNIFORMLAYOUT_NATIVE;
    shd_desc.uniform_blocks[0].glsl_uniforms[0] = (sg_glsl_shader_uniform){
        .type = SG_UNIFORMTYPE_FLOAT2,
        .array_count = 1,
        .glsl_name = "u_viewport",
    };
    shd_desc.uniform_blocks[1].stage = SG_SHADERSTAGE_FRAGMENT;
    shd_desc.uniform_blocks[1].size = sizeof(HueyFsParams);
    shd_desc.uniform_blocks[1].layout = SG_UNIFORMLAYOUT_NATIVE;
    shd_desc.uniform_blocks[1].glsl_uniforms[0] = (sg_glsl_shader_uniform){
        .type = SG_UNIFORMTYPE_FLOAT4,
        .array_count = 1,
        .glsl_name = "u_round_clip",
    };
    shd_desc.views[0].texture = (sg_shader_texture_view){
        .stage = SG_SHADERSTAGE_FRAGMENT,
        .image_type = SG_IMAGETYPE_2D,
        .sample_type = SG_IMAGESAMPLETYPE_FLOAT,
    };
    shd_desc.samplers[0] = (sg_shader_sampler){
        .stage = SG_SHADERSTAGE_FRAGMENT,
        .sampler_type = SG_SAMPLERTYPE_FILTERING,
    };
    shd_desc.texture_sampler_pairs[0] = (sg_shader_texture_sampler_pair){
        .stage = SG_SHADERSTAGE_FRAGMENT,
        .view_slot = 0,
        .sampler_slot = 0,
        .glsl_name = "u_atlas",
    };
    shd_desc.label = "uberquad_shader";
    sg_shader shd = sg_make_shader(&shd_desc);

    sg_pipeline_desc pip_desc = {0};
    pip_desc.shader = shd;
    pip_desc.layout.buffers[0] = (sg_vertex_buffer_layout_state){
        .stride = 2 * (int)sizeof(float),
        .step_func = SG_VERTEXSTEP_PER_VERTEX,
        .step_rate = 1,
    };
    pip_desc.layout.buffers[1] = (sg_vertex_buffer_layout_state){
        .stride = (int)quad_stride,
        .step_func = SG_VERTEXSTEP_PER_INSTANCE,
        .step_rate = 1,
    };
    pip_desc.layout.attrs[0] = (sg_vertex_attr_state){
        .buffer_index = 0,
        .offset = 0,
        .format = SG_VERTEXFORMAT_FLOAT2,
    };
    for (int i = 0; i < 6; i++) {
        pip_desc.layout.attrs[1 + i] = (sg_vertex_attr_state){
            .buffer_index = 1,
            .offset = (int)quad_offsets6[i],
            .format = SG_VERTEXFORMAT_FLOAT4,
        };
    }
    pip_desc.color_count = 1;
    pip_desc.colors[0].pixel_format = SG_PIXELFORMAT_RGBA8;
    pip_desc.colors[0].blend = (sg_blend_state){
        .enabled = true,
        .src_factor_rgb = SG_BLENDFACTOR_SRC_ALPHA,
        .dst_factor_rgb = SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
        .op_rgb = SG_BLENDOP_ADD,
        .src_factor_alpha = SG_BLENDFACTOR_ONE,
        .dst_factor_alpha = SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
        .op_alpha = SG_BLENDOP_ADD,
    };
    pip_desc.primitive_type = SG_PRIMITIVETYPE_TRIANGLES;
    pip_desc.cull_mode = SG_CULLMODE_NONE;
    pip_desc.label = "uberquad_pipeline";
    sg_pipeline pip = sg_make_pipeline(&pip_desc);

    bool vbuf_ok = sg_query_buffer_state(vbuf) == SG_RESOURCESTATE_VALID;
    bool ibuf_ok = sg_query_buffer_state(ibuf) == SG_RESOURCESTATE_VALID;
    bool stg_ok = sg_query_buffer_state(atlas_staging) == SG_RESOURCESTATE_VALID;
    bool img_ok = sg_query_image_state(atlas_img) == SG_RESOURCESTATE_VALID;
    bool view_ok = sg_query_view_state(atlas_view) == SG_RESOURCESTATE_VALID;
    bool smp_ok = sg_query_sampler_state(atlas_smp) == SG_RESOURCESTATE_VALID;
    bool shd_ok = sg_query_shader_state(shd) == SG_RESOURCESTATE_VALID;
    bool pip_ok = sg_query_pipeline_state(pip) == SG_RESOURCESTATE_VALID;

    if (!vbuf_ok || !ibuf_ok || !stg_ok || !img_ok || !view_ok || !smp_ok || !shd_ok || !pip_ok) {
#if defined(__ANDROID__)
        __android_log_print(
            ANDROID_LOG_ERROR,
            "Huey",
            "Renderer resource validation failed (vbuf=%d ibuf=%d stg=%d img=%d view=%d smp=%d shd=%d pip=%d)",
            (int)vbuf_ok, (int)ibuf_ok, (int)stg_ok, (int)img_ok,
            (int)view_ok, (int)smp_ok, (int)shd_ok, (int)pip_ok
        );
#else
        fprintf(
            stderr,
            "Huey: Renderer resource validation failed (vbuf=%d ibuf=%d stg=%d img=%d view=%d smp=%d shd=%d pip=%d)\n",
            (int)vbuf_ok, (int)ibuf_ok, (int)stg_ok, (int)img_ok,
            (int)view_ok, (int)smp_ok, (int)shd_ok, (int)pip_ok
        );
#endif
        sg_destroy_pipeline(pip);
        sg_destroy_shader(shd);
        sg_destroy_view(atlas_view);
        sg_destroy_sampler(atlas_smp);
        sg_destroy_image(atlas_img);
        sg_destroy_buffer(atlas_staging);
        sg_destroy_buffer(ibuf);
        sg_destroy_buffer(vbuf);
        sg_shutdown();
        return -2;
    }

    out->vbuf = vbuf.id;
    out->ibuf = ibuf.id;
    out->atlas_staging = atlas_staging.id;
    out->atlas_img = atlas_img.id;
    out->atlas_view = atlas_view.id;
    out->atlas_smp = atlas_smp.id;
    out->shd = shd.id;
    out->pip = pip.id;
    return 0;
}

void huey_sg_deinit(const HueySgHandles *h) {
    sg_destroy_pipeline((sg_pipeline){ .id = h->pip });
    sg_destroy_shader((sg_shader){ .id = h->shd });
    sg_destroy_view((sg_view){ .id = h->atlas_view });
    sg_destroy_sampler((sg_sampler){ .id = h->atlas_smp });
    sg_destroy_image((sg_image){ .id = h->atlas_img });
    sg_destroy_buffer((sg_buffer){ .id = h->atlas_staging });
    sg_destroy_buffer((sg_buffer){ .id = h->ibuf });
    sg_destroy_buffer((sg_buffer){ .id = h->vbuf });
    sg_shutdown();
}

void huey_sg_upload_atlas(const HueySgHandles *h, const uint8_t *pixels, size_t byte_len, uint32_t w, uint32_t h_px) {
    sg_buffer stg = { .id = h->atlas_staging };
    sg_image img = { .id = h->atlas_img };

    sg_write_buffer_desc wb = {0};
    wb.src.data.ptr = pixels;
    wb.src.data.size = byte_len;
    wb.dst.buffer = stg;
    wb.dst.offset = 0;
    wb.size = byte_len;
    sg_write_buffer_transient(&wb);

    sg_copy_buffer_to_image_desc cpy = {0};
    cpy.src.buffer = stg;
    cpy.src.offset = 0;
    cpy.src.bytes_per_row = (int)w;
    cpy.src.bytes_per_slice = (int)byte_len;
    cpy.dst.image = img;
    cpy.dst.mip_level = 0;
    cpy.dst.x = 0;
    cpy.dst.y = 0;
    cpy.dst.slice = 0;
    cpy.size.width = (int)w;
    cpy.size.height = (int)h_px;
    cpy.size.num_slices = 1;
    sg_copy_buffer_to_image(&cpy);
}

void huey_sg_render(
    const HueySgHandles *h,
    int32_t width,
    int32_t height,
    const void *quads_ptr,
    size_t quad_count,
    size_t quad_stride,
    const float *clear_rgba,
    const float *round_clip
) {
    sg_buffer vbuf = { .id = h->vbuf };
    sg_buffer ibuf = { .id = h->ibuf };
    sg_view atlas_view = { .id = h->atlas_view };
    sg_sampler atlas_smp = { .id = h->atlas_smp };
    sg_pipeline pip = { .id = h->pip };

    if (quad_count > 0) {
        size_t byte_size = quad_count * quad_stride;
        sg_write_buffer_desc write_desc = {0};
        write_desc.src.data.ptr = quads_ptr;
        write_desc.src.data.size = byte_size;
        write_desc.dst.buffer = ibuf;
        write_desc.size = byte_size;
        sg_write_buffer_transient(&write_desc);
    }

    sg_pass pass = {0};
    pass.action.colors[0] = (sg_color_attachment_action){
        .load_action = SG_LOADACTION_CLEAR,
        .store_action = SG_STOREACTION_STORE,
        .clear_value = {
            .r = clear_rgba[0],
            .g = clear_rgba[1],
            .b = clear_rgba[2],
            .a = clear_rgba[3],
        },
    };
    pass.swapchain.width = width;
    pass.swapchain.height = height;
    pass.swapchain.sample_count = 1;
    pass.swapchain.color_format = SG_PIXELFORMAT_RGBA8;
    pass.swapchain.depth_format = SG_PIXELFORMAT_NONE;
    pass.swapchain.gl.framebuffer = 0;

    sg_begin_pass(&pass);
    if (quad_count > 0) {
        sg_apply_pipeline(pip);

        sg_bindings bind = {0};
        bind.vertex_buffers[0] = vbuf;
        bind.vertex_buffers[1] = ibuf;
        bind.views[0] = atlas_view;
        bind.samplers[0] = atlas_smp;
        sg_apply_bindings(&bind);

        HueyVsParams vs_params = { .u_viewport = { (float)width, (float)height } };
        sg_apply_uniforms(0, &(sg_range){ .ptr = &vs_params, .size = sizeof(HueyVsParams) });

        HueyFsParams fs_params = {
            .u_round_clip = { round_clip[0], round_clip[1], round_clip[2], round_clip[3] },
        };
        sg_apply_uniforms(1, &(sg_range){ .ptr = &fs_params, .size = sizeof(HueyFsParams) });

        sg_draw(0, 6, (int)quad_count);
    }
    sg_end_pass();
    sg_commit();
}
