#ifndef ZIGGUI_H
#define ZIGGUI_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ZigguiContext ZigguiContext;

typedef struct ZigguiRect {
    float x;
    float y;
    float w;
    float h;
} ZigguiRect;

typedef struct ZigguiQuad {
    float pos_size[4];
    float uv_rect[4];
    float color[4];
    float border_color[4];
    float params[4];
    float clip_rect[4];
} ZigguiQuad;

typedef uint32_t ZigguiEventKind;
enum {
    ZIGGUI_EVENT_NONE = 0,
    ZIGGUI_EVENT_CLICKED = 1,
    ZIGGUI_EVENT_TOGGLED = 2,
    ZIGGUI_EVENT_CHANGED_F32 = 3,
    ZIGGUI_EVENT_HOVER_CHANGED = 4,
    ZIGGUI_EVENT_SCROLLED = 5,
    ZIGGUI_EVENT_SUBMITTED = 6,
    ZIGGUI_EVENT_SHORTCUT = 7
};

typedef uint32_t ZigguiKey;
enum {
    ZIGGUI_KEY_ESCAPE = 0,
    ZIGGUI_KEY_ENTER = 1,
    ZIGGUI_KEY_TAB = 2,
    ZIGGUI_KEY_SPACE = 3,
    ZIGGUI_KEY_BACKSPACE = 4,
    ZIGGUI_KEY_UP = 5,
    ZIGGUI_KEY_DOWN = 6,
    ZIGGUI_KEY_LEFT = 7,
    ZIGGUI_KEY_RIGHT = 8,
    ZIGGUI_KEY_HOME = 9,
    ZIGGUI_KEY_END = 10,
    ZIGGUI_KEY_CHAR = 11
};

enum {
    ZIGGUI_MOD_CTRL = 1u << 0,
    ZIGGUI_MOD_SHIFT = 1u << 1,
    ZIGGUI_MOD_ALT = 1u << 2,
    ZIGGUI_MOD_SUPER = 1u << 3
};

typedef struct ZigguiEvent {
    ZigguiEventKind kind;
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
} ZigguiEvent;

ZigguiContext *ziggui_create(float viewport_w, float viewport_h, float scale);
void ziggui_destroy(ZigguiContext *ctx);
void ziggui_reset(ZigguiContext *ctx);
void ziggui_set_viewport(ZigguiContext *ctx, float w, float h, float scale);

uint32_t ziggui_add_vstack(ZigguiContext *ctx, uint32_t parent_id, const char *test_id, float padding, float gap);
uint32_t ziggui_add_hstack(ZigguiContext *ctx, uint32_t parent_id, const char *test_id, float padding, float gap);
uint32_t ziggui_add_card(ZigguiContext *ctx, uint32_t parent_id, const char *test_id, const char *label, float height);
uint32_t ziggui_add_toggle(ZigguiContext *ctx, uint32_t parent_id, const char *test_id, const char *label, float height, bool checked);
uint32_t ziggui_add_slider(ZigguiContext *ctx, uint32_t parent_id, const char *test_id, const char *label, float height, float value);

void ziggui_layout(ZigguiContext *ctx);
bool ziggui_get_rect(ZigguiContext *ctx, uint32_t node_id, ZigguiRect *out_rect);

void ziggui_pointer_down(ZigguiContext *ctx, int32_t pointer_id, float x, float y, bool is_touch);
void ziggui_pointer_move(ZigguiContext *ctx, int32_t pointer_id, float x, float y, bool is_touch);
void ziggui_pointer_up(ZigguiContext *ctx, int32_t pointer_id, float x, float y, bool is_touch);
void ziggui_pointer_cancel(ZigguiContext *ctx, int32_t pointer_id);
void ziggui_wheel(ZigguiContext *ctx, float x, float y, float dx, float dy);
void ziggui_key_down(ZigguiContext *ctx, uint32_t key, uint32_t mods, uint32_t codepoint, bool repeat);

bool ziggui_poll_event(ZigguiContext *ctx, ZigguiEvent *out_ev);
bool ziggui_needs_redraw(ZigguiContext *ctx);
void ziggui_consume_redraw(ZigguiContext *ctx);
size_t ziggui_emit_quads(ZigguiContext *ctx, ZigguiQuad *out_buf, size_t cap);

#ifdef __cplusplus
}
#endif

#endif /* ZIGGUI_H */
