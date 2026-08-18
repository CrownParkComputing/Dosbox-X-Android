/*
 * dosbox_bridge.cpp - implementation of the C ABI in dosbox_bridge.h.
 *
 * This is compiled against DOSBox-X's own headers and linked with its object
 * tree, so it can call the engine directly. It is NOT a standalone library.
 *
 * DESIGN
 * ------
 * The engine is upstream DOSBox-X, running its real mainloop on a background
 * thread via dosbox_x_main() (sdlmain.cpp's main(), aliased by the bridge
 * patch). Video comes out through the existing Game Link output
 * (SCREEN_GAMELINK), which already renders to a plain 32bpp malloc'd buffer
 * instead of a window; the patch adds one call at its publish point
 * (OUTPUT_GAMELINK_Transfer) into DOSBOX_BRIDGE_PublishFrame below. Nothing
 * about the renderer itself is reimplemented.
 *
 * THREADING
 * ---------
 * Everything the engine owns is touched only on the mainloop thread. Callers
 * from Dart run on some other thread and never reach into the engine: they
 * push work onto g_pending under g_lock, and the mainloop drains it from
 * inside the publish hook, which is a frame boundary and therefore a safe
 * point. The framebuffer is copied into bridge-owned memory in the same hook,
 * so a reader can never see a half-drawn frame from the scaler.
 */
#include "config.h"

#include <SDL.h>

#include <atomic>
#include <cstdio>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <vector>
#include <pthread.h>
#include <unistd.h>

#include "dosbox.h"
#include "control.h"
#include "setup.h"
#include "render.h"
#include "mouse.h"
#include "mapper.h"
#include "joystick.h"
#include "cpu.h"

#include "dosbox_bridge.h"

/* sdlmain.cpp; aliased to main() by the bridge patch. */
extern "C" int dosbox_x_main(int argc, char *argv[]);

/* The name of the DOS program executing, as the engine tracks it. */
extern std::string RunningProgram;

/* ------------------------------------------------------------------------ */
/* State                                                                    */
/* ------------------------------------------------------------------------ */

namespace {

/* One queued request for the mainloop to perform at a frame boundary. */
struct Request {
    enum Kind {
        Key, MouseMotion, MouseButton, Joystick, SaveState_, LoadState_
    } kind;
    int32_t a, b, c, d;
};

std::mutex g_lock;
std::deque<Request> g_pending;

/* Bridge-owned copy of the last completed frame. Sized once, at the first
 * frame, to the scaler's maximum so a mode change never reallocates it under
 * a reader. */
std::vector<uint32_t> g_frame;
int32_t g_width = 0;
int32_t g_height = 0;
int32_t g_pitch = 0;
std::atomic<uint64_t> g_frame_counter{0};
std::atomic<int32_t> g_aspect_x1000{0};

std::atomic<bool> g_running{false};
std::atomic<bool> g_paused{false};
std::atomic<bool> g_started{false};
/* One-shot: the emulated joystick is attached at the first frame. */
std::atomic<bool> g_joystick_attached{false};
std::atomic<int32_t> g_fps{0};

std::string g_resource_dir;
std::string g_conf_path;
pthread_t g_thread;

/* Answers written by the mainloop for SYNCHRONOUS requests. */
std::mutex g_reply_lock;
std::atomic<int32_t> g_reply_pending{0};
int32_t g_reply_value = DOSBOX_OK;

/* Copy at most buf_len bytes of s into buf, always NUL-terminated, and return
 * the length the full answer would have needed. This is the convention every
 * string getter in the header follows. */
int32_t copy_out(const std::string &s, char *buf, int32_t buf_len)
{
    if (buf == nullptr || buf_len <= 0) {
        return static_cast<int32_t>(s.size());
    }
    const size_t n = std::min<size_t>(s.size(), static_cast<size_t>(buf_len) - 1);
    memcpy(buf, s.data(), n);
    buf[n] = '\0';
    return static_cast<int32_t>(s.size());
}

void run_request(const Request &r)
{
    switch (r.kind) {
    case Request::Key: {
        /* Synthesised exactly as OUTPUT_GAMELINK_InputEvent does it, so the
         * key goes through DOSBox-X's own mapper and every DOS program sees a
         * normal keypress rather than injected text. */
        SDL_Event ev;
        memset(&ev, 0, sizeof(ev));
        ev.key.keysym.scancode = static_cast<SDL_Scancode>(r.a);
        ev.key.keysym.mod = KMOD_NONE;
        ev.key.keysym.sym = SDLK_UNKNOWN;
        ev.key.type = r.b ? SDL_KEYDOWN : SDL_KEYUP;
        ev.key.state = r.b ? SDL_PRESSED : SDL_RELEASED;
        MAPPER_CheckEvent(&ev);
        break;
    }
    case Request::MouseMotion:
        Mouse_CursorMoved(static_cast<float>(r.a), static_cast<float>(r.b),
                          0, 0, true /*emulate*/);
        break;
    case Request::MouseButton:
        if (r.b) {
            Mouse_ButtonPressed(static_cast<uint8_t>(r.a));
        } else {
            Mouse_ButtonReleased(static_cast<uint8_t>(r.a));
        }
        break;
    case Request::Joystick: {
        const int32_t port = r.a;
        const int32_t mask = r.b;

        JOYSTICK_Enable(static_cast<Bitu>(port), true);
        /* Digital directions win over the analog axes when both are given:
         * a d-pad is what the UI's on-screen control actually sends. */
        float x = static_cast<float>(r.c) / 1000.0f;
        float y = static_cast<float>(r.d) / 1000.0f;
        if (mask & DOSBOX_JOY_LEFT)  x = -1.0f;
        if (mask & DOSBOX_JOY_RIGHT) x = 1.0f;
        if (mask & DOSBOX_JOY_UP)    y = -1.0f;
        if (mask & DOSBOX_JOY_DOWN)  y = 1.0f;
        JOYSTICK_Move_X(static_cast<Bitu>(port), x);
        JOYSTICK_Move_Y(static_cast<Bitu>(port), y);
        JOYSTICK_Button(static_cast<Bitu>(port), 0, (mask & DOSBOX_JOY_BUTTON1) != 0);
        JOYSTICK_Button(static_cast<Bitu>(port), 1, (mask & DOSBOX_JOY_BUTTON2) != 0);
        break;
    }
    case Request::SaveState_:
    case Request::LoadState_: {
        int32_t rc = DOSBOX_OK;
        try {
            if (r.kind == Request::SaveState_) {
                SaveState::instance().save(static_cast<size_t>(r.a));
            } else {
                SaveState::instance().load(static_cast<size_t>(r.a));
            }
        } catch (...) {
            /* SaveState reports failure by throwing SaveState::Error. The ABI
             * is integer-only, so the message is dropped here; the engine has
             * already logged it. */
            rc = DOSBOX_ERR;
        }
        {
            std::lock_guard<std::mutex> guard(g_reply_lock);
            g_reply_value = rc;
        }
        g_reply_pending.store(0);
        break;
    }
    }
}

void *mainloop_thread(void *)
{
    /* argv must outlive the call: DOSBox-X keeps pointers into it. */
    static std::string conf = g_conf_path;
    static char arg0[] = "dosbox-x";
    static char argconf[] = "-conf";
    std::vector<char> confbuf(conf.begin(), conf.end());
    confbuf.push_back('\0');

    char *argv[] = {arg0, argconf, confbuf.data(), nullptr};

    /* SDL refuses to initialise unless it knows main() has been reached --
     * normally because SDL_main was the entry point. Ours is dosbox_x_main on
     * this thread, so SDL never sees it and SDL_Init fails with
     *   "Application didn't initialize properly, did you include SDL_main.h
     *    in the file containing your main() function?"
     * which reads like a build mistake but is this. Must be called before
     * SDL_Init, i.e. before the engine starts. Harmless everywhere else. */
    SDL_SetMainReady();

    /* On iOS, SDL presents the ACCELEROMETER as a joystick by default:
     *   LOG: Using joystick iOS Accelerometer with 3 axes, 0 buttons
     * DOSBox-X's mapper then binds it as stick 0 and polls it, so a title
     * correctly reports "joystick detected" -- and then reads a tablet lying
     * flat, with no buttons, while every value this bridge writes is
     * overwritten on the next poll. The stick appears dead for reasons no
     * amount of looking at the bridge would explain. The emulated joystick
     * here is entirely synthetic, so the physical one must be refused. */
    SDL_SetHint(SDL_HINT_ACCELEROMETER_AS_JOYSTICK, "0");

    g_running.store(true);
    dosbox_x_main(3, argv);
    g_running.store(false);
    return nullptr;
}

} /* namespace */

/* ------------------------------------------------------------------------ */
/* Hook called by the patched OUTPUT_GAMELINK_Transfer                      */
/* ------------------------------------------------------------------------ */

extern "C" void DOSBOX_BRIDGE_PublishFrame(const uint32_t *pixels, int32_t width,
                                           int32_t height, int32_t pitch_bytes,
                                           double ratio)
{
    /* Pausing blocks the mainloop here, at a frame boundary, which is the only
     * place it is safe to stop: no CPU emulation runs, no new frames are
     * produced, and the last frame stays intact for the UI to keep showing. */
    while (g_paused.load() && g_running.load()) {
        usleep(10 * 1000);
    }

    if (pixels != nullptr && width > 0 && height > 0 && pitch_bytes > 0) {
        const size_t needed =
            static_cast<size_t>(height) * static_cast<size_t>(pitch_bytes) / 4;
        std::lock_guard<std::mutex> guard(g_lock);
        if (g_frame.size() < needed) {
            g_frame.resize(needed);
        }
        memcpy(g_frame.data(), pixels, needed * 4);
        g_width = width;
        g_height = height;
        g_pitch = pitch_bytes;
    }

    /* Attach the emulated joystick once, as early as the mainloop reaches a
     * frame boundary -- which is before a DOS program has had time to run and
     * probe for one.
     *
     * Timing is the whole point. JOYSTICK_Enable is normally called from
     * sdl_mapper.cpp when SDL binds a real host joystick; there is none here,
     * so stick[].enabled would stay false forever. Doing it lazily on the
     * first stick movement is too late: games detect the game port at startup
     * and remember the answer, so the title would report "no joystick" and
     * ignore the stick for the rest of the session no matter how much the
     * player waggled it. Whether the port responds at all is still the conf's
     * decision (joysticktype), which is per-title. */
    if (!g_joystick_attached.exchange(true)) {
        JOYSTICK_Enable(0, true);
        JOYSTICK_Enable(1, true);
    }

    g_aspect_x1000.store(static_cast<int32_t>(ratio * 1000.0));
    g_frame_counter.fetch_add(1);

    /* Drain the request queue. This is the frame boundary the header promises:
     * every mutation of engine state happens here, on the mainloop thread. */
    for (;;) {
        Request r;
        {
            std::lock_guard<std::mutex> guard(g_lock);
            if (g_pending.empty()) {
                break;
            }
            r = g_pending.front();
            g_pending.pop_front();
        }
        run_request(r);
    }
}

/* ------------------------------------------------------------------------ */
/* Lifecycle                                                                */
/* ------------------------------------------------------------------------ */

extern "C" void dosbox_core_init(const char *resource_dir)
{
    g_resource_dir = resource_dir ? resource_dir : "";

    /* There is no window to create: the Game Link output renders to memory and
     * this process has no display of its own. The dummy driver gives SDL
     * something to initialise against without one. */
    setenv("SDL_VIDEODRIVER", "dummy", 1);
}

extern "C" int32_t dosbox_core_start(const char *conf_path)
{
    if (g_started.exchange(true)) {
        return DOSBOX_ERR_ALREADY_STARTED;
    }
    if (conf_path == nullptr) {
        return DOSBOX_ERR;
    }
    g_conf_path = conf_path;

    if (pthread_create(&g_thread, nullptr, mainloop_thread, nullptr) != 0) {
        g_started.store(false);
        return DOSBOX_ERR;
    }
    pthread_detach(g_thread);
    return DOSBOX_OK;
}

extern "C" int32_t dosbox_core_stop(void)
{
    /* Documented limitation, not an oversight: upstream DOSBox-X has no
     * complete teardown path, and this process cannot use the old Android
     * app's trick of killing a separate ":emu" process. Unpause so the caller
     * is not left with a mainloop parked in the publish hook, and report
     * honestly that the core is still up. */
    g_paused.store(false);
    return DOSBOX_ERR;
}

extern "C" int32_t dosbox_core_is_running(void)
{
    return g_running.load() ? 1 : 0;
}

extern "C" void dosbox_core_set_paused(int32_t paused)
{
    g_paused.store(paused != 0);
}

/* ------------------------------------------------------------------------ */
/* Video                                                                    */
/* ------------------------------------------------------------------------ */

extern "C" const uint32_t *dosbox_core_get_framebuffer(int32_t *out_width,
                                                       int32_t *out_height,
                                                       int32_t *out_pitch_bytes)
{
    std::lock_guard<std::mutex> guard(g_lock);
    if (g_frame.empty() || g_width == 0) {
        return nullptr;
    }
    if (out_width) *out_width = g_width;
    if (out_height) *out_height = g_height;
    if (out_pitch_bytes) *out_pitch_bytes = g_pitch;
    return g_frame.data();
}

extern "C" uint64_t dosbox_core_get_frame_counter(void)
{
    return g_frame_counter.load();
}

extern "C" int32_t dosbox_core_get_pixel_aspect_x1000(void)
{
    return g_aspect_x1000.load();
}

/* ------------------------------------------------------------------------ */
/* Input                                                                    */
/* ------------------------------------------------------------------------ */

static void queue(Request::Kind kind, int32_t a, int32_t b, int32_t c, int32_t d)
{
    if (!g_running.load()) {
        return;
    }
    std::lock_guard<std::mutex> guard(g_lock);
    /* A user cannot outrun the emulator by more than a few frames of input;
     * anything beyond this is a stuck producer and dropping is better than
     * unbounded growth. */
    if (g_pending.size() > 512) {
        return;
    }
    g_pending.push_back(Request{kind, a, b, c, d});
}

extern "C" void dosbox_core_key_event(int32_t sdl_scancode, int32_t pressed)
{
    queue(Request::Key, sdl_scancode, pressed, 0, 0);
}

extern "C" void dosbox_core_mouse_motion(int32_t dx, int32_t dy)
{
    queue(Request::MouseMotion, dx, dy, 0, 0);
}

extern "C" void dosbox_core_mouse_position(int32_t x_per_mille, int32_t y_per_mille)
{
    /* DOSBox-X's mouse emulation wants deltas, so an absolute position is
     * converted against the last one we sent. The first call therefore only
     * establishes the origin and moves nothing, which is correct for a touch:
     * the pointer should not leap on finger-down. */
    static int32_t last_x = -1, last_y = -1;
    if (g_width <= 0 || g_height <= 0) {
        return;
    }
    const int32_t x = x_per_mille * g_width / 1000;
    const int32_t y = y_per_mille * g_height / 1000;
    if (last_x >= 0) {
        queue(Request::MouseMotion, x - last_x, y - last_y, 0, 0);
    }
    last_x = x;
    last_y = y;
}

extern "C" void dosbox_core_mouse_button(int32_t button, int32_t pressed)
{
    queue(Request::MouseButton, button, pressed, 0, 0);
}

extern "C" void dosbox_core_joystick(int32_t port, int32_t mask, int32_t axis_x,
                                     int32_t axis_y)
{
    queue(Request::Joystick, port, mask, axis_x, axis_y);
}

extern "C" int32_t dosbox_core_send_command(const char *line)
{
    if (line == nullptr) {
        return DOSBOX_ERR;
    }
    if (!g_running.load()) {
        return DOSBOX_ERR_NOT_RUNNING;
    }
    /* Typed as scancodes rather than injected into the shell's input buffer,
     * so it goes down exactly the path real typing does. Only the characters a
     * DOS command line can contain are mapped; anything else is skipped rather
     * than guessed at. */
    for (const char *p = line; *p; ++p) {
        const char ch = *p;
        SDL_Scancode sc = SDL_SCANCODE_UNKNOWN;
        bool shift = false;

        if (ch >= 'a' && ch <= 'z') {
            sc = static_cast<SDL_Scancode>(SDL_SCANCODE_A + (ch - 'a'));
        } else if (ch >= 'A' && ch <= 'Z') {
            sc = static_cast<SDL_Scancode>(SDL_SCANCODE_A + (ch - 'A'));
            shift = true;
        } else if (ch >= '1' && ch <= '9') {
            sc = static_cast<SDL_Scancode>(SDL_SCANCODE_1 + (ch - '1'));
        } else if (ch == '0') {
            sc = SDL_SCANCODE_0;
        } else {
            switch (ch) {
            case ' ':  sc = SDL_SCANCODE_SPACE; break;
            case '\\': sc = SDL_SCANCODE_BACKSLASH; break;
            case ':':  sc = SDL_SCANCODE_SEMICOLON; shift = true; break;
            case '.':  sc = SDL_SCANCODE_PERIOD; break;
            case '-':  sc = SDL_SCANCODE_MINUS; break;
            case '_':  sc = SDL_SCANCODE_MINUS; shift = true; break;
            case '/':  sc = SDL_SCANCODE_SLASH; break;
            default:   break;
            }
        }
        if (sc == SDL_SCANCODE_UNKNOWN) {
            continue;
        }
        if (shift) {
            queue(Request::Key, SDL_SCANCODE_LSHIFT, 1, 0, 0);
        }
        queue(Request::Key, sc, 1, 0, 0);
        queue(Request::Key, sc, 0, 0, 0);
        if (shift) {
            queue(Request::Key, SDL_SCANCODE_LSHIFT, 0, 0, 0);
        }
    }
    queue(Request::Key, SDL_SCANCODE_RETURN, 1, 0, 0);
    queue(Request::Key, SDL_SCANCODE_RETURN, 0, 0, 0);
    return DOSBOX_OK;
}

/* ------------------------------------------------------------------------ */
/* Save states                                                              */
/* ------------------------------------------------------------------------ */

static int32_t state_request(Request::Kind kind, int32_t slot)
{
    if (slot < 0 || slot >= DOSBOX_SLOT_COUNT) {
        return DOSBOX_ERR;
    }
    if (!g_running.load()) {
        return DOSBOX_ERR_NOT_RUNNING;
    }
    g_reply_pending.store(1);
    queue(kind, slot, 0, 0, 0);

    /* SYNCHRONOUS, per the header. The mainloop answers at the next frame
     * boundary; a machine that has stopped producing frames would hang the
     * caller forever, hence the timeout. */
    for (int i = 0; i < 500; ++i) {
        if (g_reply_pending.load() == 0) {
            std::lock_guard<std::mutex> guard(g_reply_lock);
            return g_reply_value;
        }
        usleep(10 * 1000);
    }
    g_reply_pending.store(0);
    return DOSBOX_ERR_TIMEOUT;
}

extern "C" int32_t dosbox_core_save_state(int32_t slot)
{
    return state_request(Request::SaveState_, slot);
}

extern "C" int32_t dosbox_core_load_state(int32_t slot)
{
    return state_request(Request::LoadState_, slot);
}

extern "C" int32_t dosbox_core_state_is_empty(int32_t slot)
{
    if (slot < 0 || slot >= DOSBOX_SLOT_COUNT) {
        return DOSBOX_ERR;
    }
    /* Read-only and does not touch emulator state, so it does not need the
     * mailbox. */
    return SaveState::instance().isEmpty(static_cast<size_t>(slot)) ? 1 : 0;
}

/* ------------------------------------------------------------------------ */
/* Live configuration                                                       */
/* ------------------------------------------------------------------------ */

extern "C" int32_t dosbox_core_config_sections(char *buf, int32_t buf_len)
{
    if (control == nullptr) {
        return DOSBOX_ERR_NOT_RUNNING;
    }
    /* Config::sectionlist is private; GetSection(int) is the public way to walk
     * it and returns NULL past the end. */
    std::string out;
    for (int i = 0;; ++i) {
        Section *sec = control->GetSection(i);
        if (sec == nullptr) {
            break;
        }
        if (!out.empty()) {
            out += "\n";
        }
        out += sec->GetName();
    }
    return copy_out(out, buf, buf_len);
}

namespace {

/* Minimal JSON string escaping. Help text is free-form English written by the
 * engine authors and routinely contains quotes and newlines, so it cannot be
 * pasted into JSON unescaped. */
std::string json_escape(const std::string &in)
{
    std::string out;
    out.reserve(in.size() + 16);
    for (const char c : in) {
        switch (c) {
        case '"':  out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (static_cast<unsigned char>(c) < 0x20) {
                char buf[8];
                snprintf(buf, sizeof(buf), "\\u%04x", c);
                out += buf;
            } else {
                out += c;
            }
        }
    }
    return out;
}

const char *type_name(Value::Etype t)
{
    switch (t) {
    case Value::V_BOOL:   return "bool";
    case Value::V_INT:    return "int";
    case Value::V_HEX:    return "hex";
    case Value::V_DOUBLE: return "double";
    case Value::V_STRING: return "string";
    default:              return "string";
    }
}

} /* namespace */

extern "C" int32_t dosbox_core_config_section_properties(const char *section,
                                                         char *buf,
                                                         int32_t buf_len)
{
    if (control == nullptr) {
        return DOSBOX_ERR_NOT_RUNNING;
    }
    if (section == nullptr) {
        return DOSBOX_ERR;
    }
    /* Only a Section_prop has properties to reflect over; a Section_line (the
     * [autoexec] block) is free text and legitimately has none, so it returns
     * an empty array rather than an error. */
    Section *sec = control->GetSection(section);
    Section_prop *props = dynamic_cast<Section_prop *>(sec);
    if (sec == nullptr) {
        return DOSBOX_ERR;
    }

    std::string out = "[";
    if (props != nullptr) {
        for (int i = 0;; ++i) {
            Property *p = props->Get_prop(i);
            if (p == nullptr) {
                break;
            }
            if (out.size() > 1) {
                out += ",";
            }
            out += "{\"name\":\"" + json_escape(p->propname) + "\"";
            out += ",\"type\":\"" + std::string(type_name(p->Get_type())) + "\"";
            out += ",\"value\":\"" + json_escape(p->GetValue().ToString()) + "\"";
            out += ",\"default\":\"" +
                   json_escape(p->Get_Default_Value().ToString()) + "\"";
            const char *help = p->Get_help();
            out += ",\"help\":\"" + json_escape(help ? help : "") + "\"";

            /* The legal set, which the UI uses to choose between a free text
             * field and a picker. Empty means unconstrained. */
            out += ",\"values\":[";
            bool first = true;
            for (const Value &v : p->GetValues()) {
                if (!first) {
                    out += ",";
                }
                first = false;
                out += "\"" + json_escape(v.ToString()) + "\"";
            }
            out += "]}";
        }
    }
    out += "]";

    return copy_out(out, buf, buf_len);
}

extern "C" int32_t dosbox_core_config_set(const char *section, const char *property,
                                          const char *value)
{
    if (control == nullptr) {
        return DOSBOX_ERR_NOT_RUNNING;
    }
    if (section == nullptr || property == nullptr || value == nullptr) {
        return DOSBOX_ERR;
    }
    Section *sec = control->GetSection(section);
    if (sec == nullptr) {
        return DOSBOX_ERR;
    }
    /* HandleInputline is the same path the engine's own CONFIG command uses,
     * so a property applied here behaves exactly as if the user had typed it. */
    const std::string line = std::string(property) + "=" + value;
    return sec->HandleInputline(line) ? DOSBOX_OK : DOSBOX_ERR;
}

extern "C" int32_t dosbox_core_config_save(void)
{
    if (control == nullptr) {
        return DOSBOX_ERR_NOT_RUNNING;
    }
    control->PrintConfig(g_conf_path.c_str(), 0);
    return DOSBOX_OK;
}

/* ------------------------------------------------------------------------ */
/* Status                                                                   */
/* ------------------------------------------------------------------------ */

extern "C" int32_t dosbox_core_get_fps(void)
{
    return g_fps.load();
}

extern "C" int32_t dosbox_core_get_audio_level(void)
{
    /* Not wired up: there is no audio backend yet (see docs/NATIVE_BUILD.md,
     * problem 1), so reporting a level would be inventing one. */
    return 0;
}

extern "C" int32_t dosbox_core_get_cycles(void)
{
    return static_cast<int32_t>(CPU_CycleMax);
}

extern "C" int32_t dosbox_core_get_running_program(char *buf, int32_t buf_len)
{
    return copy_out(RunningProgram.c_str(), buf, buf_len);
}

extern "C" int32_t dosbox_core_get_status_line(char *buf, int32_t buf_len)
{
    char tmp[128];
    snprintf(tmp, sizeof(tmp), "%s%d cycles, %d fps",
             g_paused.load() ? "PAUSED, " : "",
             static_cast<int>(CPU_CycleMax), static_cast<int>(g_fps.load()));
    return copy_out(tmp, buf, buf_len);
}
