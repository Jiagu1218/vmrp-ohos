#include <stdio.h>

/* This test only uses SDL constants and deliberately does not link SDL2main. */
#define SDL_MAIN_HANDLED
#ifdef _MSC_VER
#include <SDL.h>
#else
#include <SDL2/SDL.h>
#endif

#include "keyboard_input.h"
#include "types.h"

#define CHECK(condition)                                                        \
    do {                                                                        \
        if (!(condition)) {                                                     \
            fprintf(stderr, "CHECK failed at %s:%d: %s\n",                   \
                    __FILE__, __LINE__, #condition);                            \
            return 1;                                                           \
        }                                                                       \
    } while (0)

typedef struct KeyExpectation {
    int32_t sym;
    int32_t scancode;
    int32_t normalized;
    int32_t mr_key;
} KeyExpectation;

int main(void) {
    static const KeyExpectation physical_controls[] = {
        {SDLK_UNKNOWN, SDL_SCANCODE_Q, SDLK_q, MR_KEY_SOFTLEFT},
        {SDLK_UNKNOWN, SDL_SCANCODE_W, SDLK_w, MR_KEY_UP},
        {SDLK_UNKNOWN, SDL_SCANCODE_E, SDLK_e, MR_KEY_SOFTRIGHT},
        {SDLK_UNKNOWN, SDL_SCANCODE_A, SDLK_a, MR_KEY_LEFT},
        {SDLK_UNKNOWN, SDL_SCANCODE_S, SDLK_s, MR_KEY_DOWN},
        {SDLK_UNKNOWN, SDL_SCANCODE_D, SDLK_d, MR_KEY_RIGHT},
    };
    static const KeyExpectation aliases[] = {
        {SDLK_0, SDL_SCANCODE_0, SDLK_0, MR_KEY_0},
        {SDLK_9, SDL_SCANCODE_9, SDLK_9, MR_KEY_9},
        {SDLK_KP_0, SDL_SCANCODE_KP_0, SDLK_KP_0, MR_KEY_0},
        {SDLK_KP_9, SDL_SCANCODE_KP_9, SDLK_KP_9, MR_KEY_9},
        {SDLK_KP_ENTER, SDL_SCANCODE_KP_ENTER, SDLK_KP_ENTER, MR_KEY_SELECT},
        {SDLK_RETURN, SDL_SCANCODE_RETURN, SDLK_RETURN, MR_KEY_SELECT},
        {SDLK_EQUALS, SDL_SCANCODE_EQUALS, SDLK_EQUALS, MR_KEY_SOFTLEFT},
        {SDLK_MINUS, SDL_SCANCODE_MINUS, SDLK_MINUS, MR_KEY_SOFTRIGHT},
        {SDLK_ASTERISK, SDL_SCANCODE_UNKNOWN, SDLK_ASTERISK, MR_KEY_STAR},
        {SDLK_HASH, SDL_SCANCODE_UNKNOWN, SDLK_HASH, MR_KEY_POUND},
        {SDLK_UP, SDL_SCANCODE_UP, SDLK_UP, MR_KEY_UP},
        {SDLK_DOWN, SDL_SCANCODE_DOWN, SDLK_DOWN, MR_KEY_DOWN},
        {SDLK_LEFT, SDL_SCANCODE_LEFT, SDLK_LEFT, MR_KEY_LEFT},
        {SDLK_RIGHT, SDL_SCANCODE_RIGHT, SDLK_RIGHT, MR_KEY_RIGHT},
        {SDLK_LEFTBRACKET, SDL_SCANCODE_LEFTBRACKET,
         SDLK_LEFTBRACKET, MR_KEY_SOFTLEFT},
        {SDLK_RIGHTBRACKET, SDL_SCANCODE_RIGHTBRACKET,
         SDLK_RIGHTBRACKET, MR_KEY_SOFTRIGHT},
        {SDLK_TAB, SDL_SCANCODE_TAB, SDLK_TAB, MR_KEY_SEND},
        {SDLK_ESCAPE, SDL_SCANCODE_ESCAPE, SDLK_ESCAPE, MR_KEY_POWER},
    };

    for (size_t i = 0; i < sizeof(physical_controls) / sizeof(physical_controls[0]); i++) {
        const KeyExpectation *entry = &physical_controls[i];
        int32_t normalized = skyengine_normalize_windows_keycode(
            entry->sym, entry->scancode, 0);
        CHECK(normalized == entry->normalized);
        CHECK(skyengine_mr_key_from_sdl_key(normalized) == entry->mr_key);

        /* E2E stores its token in scancode.  Every physical-control value is a
         * possible token collision and must leave the synthetic sym unchanged. */
        CHECK(skyengine_normalize_windows_keycode(
                  SDLK_RETURN, entry->scancode, 1) == SDLK_RETURN);
    }

    for (size_t i = 0; i < sizeof(aliases) / sizeof(aliases[0]); i++) {
        const KeyExpectation *entry = &aliases[i];
        int32_t normalized = skyengine_normalize_windows_keycode(
            entry->sym, entry->scancode, 0);
        CHECK(normalized == entry->normalized);
        CHECK(skyengine_mr_key_from_sdl_key(normalized) == entry->mr_key);
    }

    SkyEngineKeyLatch latch = SKYENGINE_KEY_LATCH_INITIALIZER;
    int32_t mr_key = MR_KEY_NONE;
    CHECK(!skyengine_key_latch_press(&latch, SDLK_LSHIFT, &mr_key));
    CHECK(latch.active_keycode == SDLK_UNKNOWN);

    for (size_t i = 0; i < sizeof(physical_controls) / sizeof(physical_controls[0]); i++) {
        const KeyExpectation *entry = &physical_controls[i];
        CHECK(skyengine_key_latch_press(&latch, entry->normalized, &mr_key));
        CHECK(mr_key == entry->mr_key);
        CHECK(skyengine_key_latch_release(&latch, entry->normalized, &mr_key));
        CHECK(mr_key == entry->mr_key);
        CHECK(latch.active_keycode == SDLK_UNKNOWN);
    }

    CHECK(skyengine_key_latch_press(&latch, SDLK_w, &mr_key));
    CHECK(!skyengine_key_latch_press(&latch, SDLK_s, &mr_key));
    CHECK(!skyengine_key_latch_release(&latch, SDLK_s, &mr_key));
    CHECK(skyengine_key_latch_release(&latch, SDLK_w, &mr_key));
    CHECK(mr_key == MR_KEY_UP);
    CHECK(latch.active_keycode == SDLK_UNKNOWN);

    CHECK(skyengine_key_latch_press(&latch, SDLK_q, &mr_key));
    CHECK(skyengine_key_latch_clear(&latch, SDLK_q));
    CHECK(latch.active_keycode == SDLK_UNKNOWN);
    CHECK(skyengine_key_latch_press(&latch, SDLK_d, &mr_key));
    CHECK(skyengine_key_latch_release(&latch, SDLK_d, &mr_key));
    CHECK(mr_key == MR_KEY_RIGHT);

    puts("keyboard_input_test: PASS");
    return 0;
}
