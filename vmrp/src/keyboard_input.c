#include "./include/keyboard_input.h"

#ifdef _MSC_VER
#include <SDL.h>
#else
#include <SDL2/SDL.h>
#endif

#include "./include/types.h"

int32_t skyengine_normalize_windows_keycode(int32_t sym,
                                            int32_t scancode,
                                            int is_e2e_event) {
    if (is_e2e_event) return sym;

    /* These are physical emulator controls, matching the printed QWEASD key
     * positions even when Windows maps those positions to other characters. */
    switch ((SDL_Scancode)scancode) {
        case SDL_SCANCODE_Q:
            return SDLK_q;
        case SDL_SCANCODE_W:
            return SDLK_w;
        case SDL_SCANCODE_E:
            return SDLK_e;
        case SDL_SCANCODE_A:
            return SDLK_a;
        case SDL_SCANCODE_S:
            return SDLK_s;
        case SDL_SCANCODE_D:
            return SDLK_d;
        default:
            /* Non-control keys retain SDL's layout-aware keycode semantics. */
            return sym;
    }
}

int32_t skyengine_mr_key_from_sdl_key(int32_t keycode) {
    if (keycode >= SDLK_0 && keycode <= SDLK_9) {
        return MR_KEY_0 + (keycode - SDLK_0);
    }

    switch ((SDL_Keycode)keycode) {
        case SDLK_KP_0:
            return MR_KEY_0;
        case SDLK_KP_1:
            return MR_KEY_1;
        case SDLK_KP_2:
            return MR_KEY_2;
        case SDLK_KP_3:
            return MR_KEY_3;
        case SDLK_KP_4:
            return MR_KEY_4;
        case SDLK_KP_5:
            return MR_KEY_5;
        case SDLK_KP_6:
            return MR_KEY_6;
        case SDLK_KP_7:
            return MR_KEY_7;
        case SDLK_KP_8:
            return MR_KEY_8;
        case SDLK_KP_9:
            return MR_KEY_9;
        case SDLK_KP_ENTER:
        case SDLK_RETURN:
            return MR_KEY_SELECT;
        case SDLK_EQUALS:
        case SDLK_q:
        case SDLK_LEFTBRACKET:
            return MR_KEY_SOFTLEFT;
        case SDLK_MINUS:
        case SDLK_e:
        case SDLK_RIGHTBRACKET:
            return MR_KEY_SOFTRIGHT;
        case SDLK_ASTERISK:
            return MR_KEY_STAR;
        case SDLK_HASH:
            return MR_KEY_POUND;
        case SDLK_w:
        case SDLK_UP:
            return MR_KEY_UP;
        case SDLK_s:
        case SDLK_DOWN:
            return MR_KEY_DOWN;
        case SDLK_a:
        case SDLK_LEFT:
            return MR_KEY_LEFT;
        case SDLK_d:
        case SDLK_RIGHT:
            return MR_KEY_RIGHT;
        case SDLK_TAB:
            return MR_KEY_SEND;
        case SDLK_ESCAPE:
            return MR_KEY_POWER;
        default:
            return MR_KEY_NONE;
    }
}

int skyengine_key_latch_press(SkyEngineKeyLatch *latch,
                              int32_t keycode,
                              int32_t *mr_key) {
    int32_t mapped_key = skyengine_mr_key_from_sdl_key(keycode);
    if (!latch || !mr_key || latch->active_keycode != SDLK_UNKNOWN ||
        mapped_key == MR_KEY_NONE) {
        return 0;
    }

    /* Publish the host identity before guest dispatch so a nested UI handoff
     * cannot leave the matching KEYUP without an owner. */
    latch->active_keycode = keycode;
    *mr_key = mapped_key;
    return 1;
}

int skyengine_key_latch_release(SkyEngineKeyLatch *latch,
                                int32_t keycode,
                                int32_t *mr_key) {
    if (!latch || !mr_key || latch->active_keycode != keycode) return 0;

    *mr_key = skyengine_mr_key_from_sdl_key(keycode);
    latch->active_keycode = SDLK_UNKNOWN;
    return *mr_key != MR_KEY_NONE;
}

int skyengine_key_latch_clear(SkyEngineKeyLatch *latch, int32_t keycode) {
    if (!latch || latch->active_keycode != keycode) return 0;
    latch->active_keycode = SDLK_UNKNOWN;
    return 1;
}
