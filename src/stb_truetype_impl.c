#include <stddef.h>
#include <stdint.h>

#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"

_Static_assert(sizeof(stbtt_fontinfo) <= 512, "stbtt_fontinfo exceeds 512 bytes");
_Static_assert(_Alignof(stbtt_fontinfo) <= 16, "stbtt_fontinfo alignment exceeds 16 bytes");

int huey_stbtt_get_font_offset_for_index(const unsigned char *data, int index) {
    return stbtt_GetFontOffsetForIndex(data, index);
}

int huey_stbtt_init_font(void *info_buf, const unsigned char *data, int offset) {
    return stbtt_InitFont((stbtt_fontinfo *)info_buf, data, offset);
}

void huey_stbtt_get_font_vmetrics(const void *info_buf, int *ascent, int *descent, int *line_gap) {
    stbtt_GetFontVMetrics((const stbtt_fontinfo *)info_buf, ascent, descent, line_gap);
}

float huey_stbtt_scale_for_pixel_height(const void *info_buf, float pixels) {
    return stbtt_ScaleForPixelHeight((const stbtt_fontinfo *)info_buf, pixels);
}

void huey_stbtt_get_codepoint_hmetrics(const void *info_buf, int codepoint, int *advance_width, int *left_side_bearing) {
    stbtt_GetCodepointHMetrics((const stbtt_fontinfo *)info_buf, codepoint, advance_width, left_side_bearing);
}

void huey_stbtt_get_codepoint_bitmap_box(const void *info_buf, int codepoint, float scale_x, float scale_y, int *ix0, int *iy0, int *ix1, int *iy1) {
    stbtt_GetCodepointBitmapBox((const stbtt_fontinfo *)info_buf, codepoint, scale_x, scale_y, ix0, iy0, ix1, iy1);
}

void huey_stbtt_make_codepoint_bitmap(const void *info_buf, unsigned char *output, int out_w, int out_h, int out_stride, float scale_x, float scale_y, int codepoint) {
    stbtt_MakeCodepointBitmap((const stbtt_fontinfo *)info_buf, output, out_w, out_h, out_stride, scale_x, scale_y, codepoint);
}

int huey_stbtt_get_codepoint_kern_advance(const void *info_buf, int ch1, int ch2) {
    return stbtt_GetCodepointKernAdvance((const stbtt_fontinfo *)info_buf, ch1, ch2);
}
