#ifndef HUEY_H
#define HUEY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct HueyContext HueyContext;

typedef struct HueyRect {
    float x;
    float y;
    float w;
    float h;
} HueyRect;

typedef struct HueyQuad {
    float pos_size[4];
    float uv_rect[4];
    float color[4];
    float border_color[4];
    float params[4];
    float clip_rect[4];
} HueyQuad;

typedef uint32_t HueyEventKind;
enum {
    HUEY_EVENT_NONE = 0,
    HUEY_EVENT_CLICKED = 1,
    HUEY_EVENT_TOGGLED = 2,
    HUEY_EVENT_CHANGED_F32 = 3,
    HUEY_EVENT_HOVER_CHANGED = 4,
    HUEY_EVENT_SCROLLED = 5,
    HUEY_EVENT_SUBMITTED = 6,
    HUEY_EVENT_SHORTCUT = 7
};

typedef uint32_t HueyKey;
enum {
    HUEY_KEY_ESCAPE = 0,
    HUEY_KEY_ENTER = 1,
    HUEY_KEY_TAB = 2,
    HUEY_KEY_SPACE = 3,
    HUEY_KEY_BACKSPACE = 4,
    HUEY_KEY_UP = 5,
    HUEY_KEY_DOWN = 6,
    HUEY_KEY_LEFT = 7,
    HUEY_KEY_RIGHT = 8,
    HUEY_KEY_HOME = 9,
    HUEY_KEY_END = 10,
    HUEY_KEY_CHAR = 11
};

enum {
    HUEY_MOD_CTRL = 1u << 0,
    HUEY_MOD_SHIFT = 1u << 1,
    HUEY_MOD_ALT = 1u << 2,
    HUEY_MOD_SUPER = 1u << 3
};

typedef struct HueyEvent {
    HueyEventKind kind;
    uint32_t node_id;
    bool bool_val;
    uint8_t _pad0[3];
    float f32_val;
    float dx;
    float dy;
    uint32_t key;
    uint32_t mods;
    uint32_t codepoint;
    char test_id[64];
    uint32_t test_id_len;
} HueyEvent;

HueyContext *huey_create(float viewport_w, float viewport_h, float scale);
void huey_destroy(HueyContext *ctx);
void huey_reset(HueyContext *ctx);
void huey_set_viewport(HueyContext *ctx, float w, float h, float scale);

uint32_t huey_add_vstack(HueyContext *ctx, uint32_t parent_id, const char *test_id, float padding, float gap);
uint32_t huey_add_hstack(HueyContext *ctx, uint32_t parent_id, const char *test_id, float padding, float gap);
uint32_t huey_add_card(HueyContext *ctx, uint32_t parent_id, const char *test_id, const char *label, float height);
uint32_t huey_add_toggle(HueyContext *ctx, uint32_t parent_id, const char *test_id, const char *label, float height, bool checked);
uint32_t huey_add_slider(HueyContext *ctx, uint32_t parent_id, const char *test_id, const char *label, float height, float value);

void huey_layout(HueyContext *ctx);
bool huey_get_rect(HueyContext *ctx, uint32_t node_id, HueyRect *out_rect);

void huey_pointer_down(HueyContext *ctx, int32_t pointer_id, float x, float y, bool is_touch);
void huey_pointer_move(HueyContext *ctx, int32_t pointer_id, float x, float y, bool is_touch);
void huey_pointer_up(HueyContext *ctx, int32_t pointer_id, float x, float y, bool is_touch);
void huey_pointer_cancel(HueyContext *ctx, int32_t pointer_id);
void huey_wheel(HueyContext *ctx, float x, float y, float dx, float dy);
void huey_key_down(HueyContext *ctx, uint32_t key, uint32_t mods, uint32_t codepoint, bool repeat);

bool huey_poll_event(HueyContext *ctx, HueyEvent *out_ev);
bool huey_needs_redraw(HueyContext *ctx);
void huey_consume_redraw(HueyContext *ctx);
size_t huey_emit_quads(HueyContext *ctx, HueyQuad *out_buf, size_t cap);

#ifdef __cplusplus
}
#endif

#endif /* HUEY_H */
