#ifndef SKYENGINE_KEYBOARD_INPUT_H
#define SKYENGINE_KEYBOARD_INPUT_H

#include <stdint.h>

typedef struct SkyEngineKeyLatch {
    int32_t active_keycode;
} SkyEngineKeyLatch;

#define SKYENGINE_KEY_LATCH_INITIALIZER {0}

/* Windows SDL keycodes follow the active keyboard layout.  Normalize only the
 * six fixed emulator control positions; synthetic E2E events keep their sym
 * because their scancode field carries a command token rather than hardware. */
int32_t skyengine_normalize_windows_keycode(int32_t sym,
                                            int32_t scancode,
                                            int is_e2e_event);

int32_t skyengine_mr_key_from_sdl_key(int32_t keycode);

/* The latch models the handset's single active key.  Unmapped host keys never
 * enter it, so modifiers cannot block a following Q/W/E/A/S/D control key. */
int skyengine_key_latch_press(SkyEngineKeyLatch *latch,
                              int32_t keycode,
                              int32_t *mr_key);
int skyengine_key_latch_release(SkyEngineKeyLatch *latch,
                                int32_t keycode,
                                int32_t *mr_key);
int skyengine_key_latch_clear(SkyEngineKeyLatch *latch, int32_t keycode);

#endif /* SKYENGINE_KEYBOARD_INPUT_H */
