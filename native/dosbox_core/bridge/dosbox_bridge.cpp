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
/* _GNU_SOURCE for the GNU extensions the Linux build uses. Must precede every
 * libc include, so it comes first. Note stop() no longer relies on
 * pthread_timedjoin_np: Bionic has no such function, so that version never
 * compiled for Android. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "config.h"

#include <SDL.h>

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <atomic>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <deque>
#include <mutex>
#include <string>
#include <vector>
#include <pthread.h>
#include <time.h>
#include <unistd.h>

#include "dosbox.h"
#include "control.h"
#include "setup.h"
#include "render.h"
#include "mouse.h"
#include "mapper.h"
#include "joystick.h"
#include "cpu.h"
#include "../src/dos/cdrom.h"

#include "dosbox_bridge.h"
#include "audio_backend.h"

/* sdlmain.cpp; aliased to main() by the bridge patch. */
extern "C" int dosbox_x_main(int argc, char *argv[]);

/* The name of the DOS program executing, as the engine tracks it. */
extern std::string RunningProgram;

/* sdlmain.cpp; the kill switch sets this before throwing so late DOS-side
 * memory writes during teardown log rather than crash. */
extern bool warn_on_mem_write;

/* ------------------------------------------------------------------------ */
/* State                                                                    */
/* ------------------------------------------------------------------------ */

/* Runtime CD swapping, all owned by DOSBox-X.
 *
 * IDE_ATAPI_MediaChangeNotify is what its own Drive menu calls to change a
 * disc under a running guest: it advances the drive, sets has_changed and
 * schedules the insertion event, so the guest gets a real "medium may have
 * changed" and auto-insert notification fires. Declared here rather than
 * included because ide.cpp exports it without a header -- every caller in the
 * tree forward-declares it the same way.
 *
 * qmount suppresses the "could not load image" message SetDevice would
 * otherwise write to the DOS console. There is no DOS console once a guest OS
 * has booted, which is exactly when this is used. */
extern void IDE_ATAPI_MediaChangeNotify(signed char index, bool slave, bool immediate);
extern bool qmount;

/* DOSBox-X's mouse-capture flag, a plain global owned by sdlmain.cpp.
 *
 * Declared HERE, at file scope, and deliberately not inside the anonymous
 * namespace below: a name declared in an anonymous namespace mangles to a
 * translation-unit-private symbol, so the reference became
 * _ZN12_GLOBAL__N_118user_cursor_lockedE and the whole core failed to load
 * with "cannot locate symbol" -- which the app reports only as falling back
 * to the stub. */
extern bool user_cursor_locked;

namespace {

/* One queued request for the mainloop to perform at a frame boundary. */
struct Request {
    enum Kind {
        Key, MouseMotion, MouseButton, Joystick, SaveState_, LoadState_,
        CdInsert, Quit
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
/* Set by the engine thread as its last act, so a bounded join can be built
 * out of pthread_join alone. See dosbox_core_stop. */
std::atomic<bool> g_thread_exited{false};
/* One-shot: the emulated joystick is attached at the first frame. */
std::atomic<bool> g_joystick_attached{false};
std::atomic<int32_t> g_fps{0};

/* Where we believe the guest's pointer is, in guest pixels, or -1 for
 * "no idea". A PS/2 mouse reports only movement, so placing the pointer
 * somewhere means steering it from where it already is -- which means
 * remembering. Reset whenever a session starts or ends, because the next
 * guest's pointer is somewhere else entirely. */
int32_t g_ptr_x = -1, g_ptr_y = -1;
/* Where the finger last asked the pointer to be, and whether the belief has
 * to be re-established against a corner before steering there. */
int32_t g_ptr_target_x = -1, g_ptr_target_y = -1;
bool g_ptr_rehome = false;
int32_t g_ptr_home_left = 0;

/* Button events that arrived while the pointer was still travelling.
 *
 * Pressing on touch-down and only then moving is what drew a selection box
 * across the desktop on every single tap: the button went down where the
 * pointer happened to be, the pointer then travelled to the finger, and
 * Windows quite correctly rubber-banded the whole journey. A click has to
 * happen where the user touched, so it waits for the pointer to get there. */
struct PendingButton { int32_t button; bool pressed; };
PendingButton g_ptr_btn_queue[8];
int32_t g_ptr_btn_count = 0;

bool ptr_is_travelling()
{
    return g_ptr_rehome ||
           (g_ptr_target_x >= 0 &&
            (g_ptr_x != g_ptr_target_x || g_ptr_y != g_ptr_target_y));
}

/* Path for a pending CD insert. The request queue carries ints only, so the
 * string travels beside it under the same lock. */
std::string g_cd_path;

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
        /* Hold the click back while the pointer is still on its way to where
         * the finger touched -- see g_ptr_btn_queue. Both press AND release
         * queue, so a tap that completes mid-flight still arrives as a press
         * followed by a release, in order, at the right place. Letting the
         * release through early would strand the button down. */
        if (ptr_is_travelling() &&
            g_ptr_btn_count <
                static_cast<int32_t>(sizeof(g_ptr_btn_queue) /
                                     sizeof(g_ptr_btn_queue[0]))) {
            g_ptr_btn_queue[g_ptr_btn_count].button = r.a;
            g_ptr_btn_queue[g_ptr_btn_count].pressed = r.b != 0;
            g_ptr_btn_count++;
            break;
        }
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
    case Request::CdInsert: {
        /* Secondary master -- the slot the Windows profile mounts the CD on
         * (-ide 2m), and where a period PC's CD-ROM lived. */
        const signed char kIdeIndex = 1;
        const bool kIdeSlave = false;

        std::string path;
        {
            std::lock_guard<std::mutex> guard(g_lock);
            path = g_cd_path;
        }

        if (path.empty()) {
            /* Eject: hand the drive an empty list is not possible, so an
             * empty path simply notifies a change with nothing new attached,
             * which the guest sees as the door having been opened. */
            IDE_ATAPI_MediaChangeNotify(kIdeIndex, kIdeSlave, false);
            break;
        }

        auto *iface = new CDROM_Interface_Image(0);
        const bool saved_qmount = qmount;
        qmount = true;
        const bool loaded = iface->SetDevice(path.c_str(), 0);
        qmount = saved_qmount;

        if (!loaded) {
            fprintf(stderr, "[bridge] could not load CD image %s\n",
                    path.c_str());
            delete iface;
            break;
        }

        std::vector<CDROM_Interface*> cds;
        cds.push_back(iface);
        /* opt_replace: rebind the CD-ROM already on that slot rather than
         * refusing because it is occupied. */
        if (!IDE_CDROM_Attach(kIdeIndex, kIdeSlave, cds, true)) {
            fprintf(stderr,
                    "[bridge] no CD-ROM on IDE 2m to replace; the title was "
                    "launched without one\n");
            delete iface;
            break;
        }

        /* Not immediate: the guest is an OS, and it wants the spin-up delay
         * (cd-rom insertion delay, 4000ms in the Windows profile) before the
         * new disc appears, which is what makes auto-insert notification
         * fire rather than the medium silently changing underneath it. */
        IDE_ATAPI_MediaChangeNotify(kIdeIndex, kIdeSlave, false);
        break;
    }

    case Request::Quit:
        /* The kill switch (sdlmain.cpp's KillSwitch / Ctrl+F9), minus
         * CheckQuit: that shows a host message box, and there is no host UI.
         * Throwing 1 unwinds out of DOSBOX_RunMachine into sdlmain's catch,
         * which runs the full engine teardown, after which dosbox_x_main
         * returns and the mainloop thread exits. This hook runs on that
         * thread (via the frame-publish path), exactly like the mapper's own
         * kill-switch handler. */
        warn_on_mem_write = true;
        throw 1;
    }
}

void *mainloop_thread(void *)
{
    /* argv must outlive the dosbox_x_main call: DOSBox-X keeps pointers into
     * it. These are plain locals of the thread function -- they live exactly
     * as long as the call. They must NOT be static: a second start (after a
     * clean stop) would otherwise relaunch with the FIRST session's conf. */
    const std::string conf = g_conf_path;
    char arg0[] = "dosbox-x";
    char argconf[] = "-conf";
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

    /* The engine ran its teardown and returned -- the kill-switch Quit did
     * its job. dosbox_core_stop joins on this, but clear the one-shot flags
     * here too so a crashed/never-joined exit still leaves sane state. */
    g_started.store(false);
    g_joystick_attached.store(false);
    g_fps.store(0);
    /* Last: whoever is waiting on this may join the moment it is seen. */
    g_thread_exited.store(true, std::memory_order_release);
    return nullptr;
}

} /* namespace */

/* ------------------------------------------------------------------------ */
/* Shared frames                                                            */
/* ------------------------------------------------------------------------ */

/* Header + pixels in one mapping. The header carries everything a reader
 * needs, so a frame costs no IPC: the reader polls this exactly as an
 * in-process reader polls g_frame.
 *
 * counter is written LAST on publish and read FIRST by the reader, which is
 * what makes a torn frame impossible to mistake for a whole one: a reader
 * that sees a new counter has, by release/acquire, seen the pixels that came
 * with it. */
struct SharedFrameHeader {
    std::atomic<uint64_t> counter;
    std::atomic<int32_t> width;
    std::atomic<int32_t> height;
    std::atomic<int32_t> pitch_bytes;
    std::atomic<int32_t> capacity_bytes;
};

static void *g_shm_base = nullptr;         /* writer side */
static size_t g_shm_size = 0;
static void *g_shm_read_base = nullptr;    /* reader side */
static size_t g_shm_read_size = 0;

static size_t shm_total_bytes(int32_t max_width, int32_t max_height)
{
    return sizeof(SharedFrameHeader) +
           static_cast<size_t>(max_width) * static_cast<size_t>(max_height) * 4;
}

extern "C" int32_t dosbox_core_set_shared_frame(const char *path,
                                                int32_t max_width,
                                                int32_t max_height)
{
    if (path == nullptr || max_width <= 0 || max_height <= 0) {
        return DOSBOX_ERR;
    }
    const size_t total = shm_total_bytes(max_width, max_height);

    const int fd = open(path, O_RDWR | O_CREAT, 0600);
    if (fd < 0) {
        return DOSBOX_ERR;
    }
    /* Sized up front. A mapping that grows under a reader is a mapping the
     * reader can be holding a stale length for. */
    if (ftruncate(fd, static_cast<off_t>(total)) != 0) {
        close(fd);
        return DOSBOX_ERR;
    }
    void *base = mmap(nullptr, total, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd); /* the mapping keeps the file alive */
    if (base == MAP_FAILED) {
        return DOSBOX_ERR;
    }

    auto *header = static_cast<SharedFrameHeader *>(base);
    header->counter.store(0, std::memory_order_relaxed);
    header->width.store(0, std::memory_order_relaxed);
    header->height.store(0, std::memory_order_relaxed);
    header->pitch_bytes.store(0, std::memory_order_relaxed);
    header->capacity_bytes.store(
        static_cast<int32_t>(total - sizeof(SharedFrameHeader)),
        std::memory_order_relaxed);

    g_shm_base = base;
    g_shm_size = total;
    return DOSBOX_OK;
}

/* Called from the publish hook, on the engine thread. */
static void shared_frame_publish(const uint32_t *pixels, int32_t width,
                                 int32_t height, int32_t pitch_bytes)
{
    if (g_shm_base == nullptr || pixels == nullptr) {
        return;
    }
    auto *header = static_cast<SharedFrameHeader *>(g_shm_base);
    const size_t needed =
        static_cast<size_t>(height) * static_cast<size_t>(pitch_bytes);
    /* A frame larger than the mapping is dropped rather than truncated: half a
     * frame drawn confidently is worse than the last whole one held. */
    if (needed > g_shm_size - sizeof(SharedFrameHeader)) {
        return;
    }
    memcpy(static_cast<uint8_t *>(g_shm_base) + sizeof(SharedFrameHeader),
           pixels, needed);
    header->width.store(width, std::memory_order_relaxed);
    header->height.store(height, std::memory_order_relaxed);
    header->pitch_bytes.store(pitch_bytes, std::memory_order_relaxed);
    /* Last, and with release: see the note on SharedFrameHeader. */
    header->counter.fetch_add(1, std::memory_order_release);
}

extern "C" int32_t dosbox_shared_frame_attach(const char *path)
{
    if (path == nullptr) {
        return DOSBOX_ERR;
    }
    dosbox_shared_frame_detach();

    const int fd = open(path, O_RDONLY);
    if (fd < 0) {
        return DOSBOX_ERR;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 ||
        static_cast<size_t>(st.st_size) < sizeof(SharedFrameHeader)) {
        close(fd);
        return DOSBOX_ERR;
    }
    void *base = mmap(nullptr, static_cast<size_t>(st.st_size), PROT_READ,
                      MAP_SHARED, fd, 0);
    close(fd);
    if (base == MAP_FAILED) {
        return DOSBOX_ERR;
    }
    g_shm_read_base = base;
    g_shm_read_size = static_cast<size_t>(st.st_size);
    return DOSBOX_OK;
}

extern "C" const uint32_t *dosbox_shared_frame_get(int32_t *out_width,
                                                   int32_t *out_height,
                                                   int32_t *out_pitch_bytes)
{
    if (g_shm_read_base == nullptr) {
        return nullptr;
    }
    auto *header = static_cast<SharedFrameHeader *>(g_shm_read_base);
    /* Acquire pairs with the publisher's release store of counter. */
    if (header->counter.load(std::memory_order_acquire) == 0) {
        return nullptr;
    }
    const int32_t width = header->width.load(std::memory_order_relaxed);
    const int32_t height = header->height.load(std::memory_order_relaxed);
    const int32_t pitch = header->pitch_bytes.load(std::memory_order_relaxed);
    if (width <= 0 || height <= 0 || pitch <= 0) {
        return nullptr;
    }
    if (out_width) *out_width = width;
    if (out_height) *out_height = height;
    if (out_pitch_bytes) *out_pitch_bytes = pitch;
    return reinterpret_cast<const uint32_t *>(
        static_cast<uint8_t *>(g_shm_read_base) + sizeof(SharedFrameHeader));
}

extern "C" uint64_t dosbox_shared_frame_counter(void)
{
    if (g_shm_read_base == nullptr) {
        return 0;
    }
    auto *header = static_cast<SharedFrameHeader *>(g_shm_read_base);
    return header->counter.load(std::memory_order_acquire);
}

extern "C" void dosbox_shared_frame_detach(void)
{
    if (g_shm_read_base != nullptr) {
        munmap(g_shm_read_base, g_shm_read_size);
        g_shm_read_base = nullptr;
        g_shm_read_size = 0;
    }
}

/* ------------------------------------------------------------------------ */
/* Hooks called by the patched engine                                       */
/* ------------------------------------------------------------------------ */

/* Honour a pause request and drain everything the app has queued.
 *
 * Both hooks below call this, and that redundancy is the point. It used to
 * live only on the frame-publish path, on the reasonable-looking assumption
 * that a running machine draws. A booted guest OS breaks that assumption
 * outright: DOSBox-X publishes a frame only when the picture changes, and a
 * Windows desktop sitting idle changes nothing at all. The queue is the only
 * channel the app has -- keys, mouse, pause, save-state, quit -- so on a
 * still screen the machine went deaf, and because input is what would have
 * changed the picture, it could never wake up again. stop() then timed out
 * against a thread still executing guest code, and the process took its
 * chances at exit.
 *
 * Called on the mainloop thread from both sites, so no two drains overlap. */
static void pump_requests()
{
    /* The emulated machine always owns the pointer.
     *
     * DOSBox-X only accumulates PS/2 mouse movement when user_cursor_locked
     * is set -- see KEYBOARD_AUX_Event, which throws the delta away
     * otherwise while still reporting the buttons. That flag is assigned in
     * exactly one place, HandleMouseMotion, from SDL's real mouse-capture
     * state, and this core has no window and no real mouse: the handler
     * never runs, the flag stays false from init, and a guest OS therefore
     * receives clicks that work and motion that does not. Which is precisely
     * how it looked: the cursor sat still while taps registered under it.
     *
     * Set every pump rather than once at start, so nothing that runs later
     * can quietly clear it. It is a plain bool write on the mainloop thread. */
    user_cursor_locked = true;

    /* One mouse packet per pump, at most.
     *
     * This is called every tick from GFX_Events, so the pointer still crosses
     * the screen in a fraction of a second, but each packet gets a chance to
     * be consumed instead of landing in a full buffer and being thrown away.
     * Pacing IS the algorithm here; the arithmetic is trivial. */
    if (g_ptr_target_x >= 0 && g_width > 0 && g_height > 0) {
        const int32_t kMaxPerPacket = 200;
        if (g_ptr_rehome) {
            /* Pin against the top-left corner, the one position a relative
             * device can be certain of, then steer from there. */
            if (g_ptr_home_left == 0) {
                g_ptr_home_left = (g_width + g_height) / 32 + 8;
            }
            Mouse_CursorMoved(-(float)kMaxPerPacket, -(float)kMaxPerPacket,
                              0, 0, true);
            if (--g_ptr_home_left <= 0) {
                g_ptr_rehome = false;
                g_ptr_x = 0;
                g_ptr_y = 0;
            }
        } else {
            /* How many units of movement make one guest pixel.
             *
             * KEYBOARD_AUX_Event turns accumulated movement into a packet as
             *     x2 = (acx * (1 << resolution)) / 16
             * so a delta has to be scaled by 16 to survive the division --
             * and then divided by (1 << resolution) again, which is the part
             * that was missing. Windows sets the PS/2 resolution to 3, giving
             * 16/8 = 2. Compensating for only the /16 made every movement
             * eight times too far, which is exactly how it felt.
             *
             * resolution is private to keyboard.cpp, so this assumes the
             * value Windows actually programs rather than reading it. A guest
             * that picks a different one will be off by a constant factor --
             * the reason this is a named constant and not a literal. */
            const int32_t kUnitsPerPixel = 2;
            int32_t dx = (g_ptr_target_x - g_ptr_x) * kUnitsPerPixel;
            int32_t dy = (g_ptr_target_y - g_ptr_y) * kUnitsPerPixel;
            if (dx != 0 || dy != 0) {
                int32_t sx = dx > kMaxPerPacket ? kMaxPerPacket
                           : (dx < -kMaxPerPacket ? -kMaxPerPacket : dx);
                int32_t sy = dy > kMaxPerPacket ? kMaxPerPacket
                           : (dy < -kMaxPerPacket ? -kMaxPerPacket : dy);
                Mouse_CursorMoved((float)sx, (float)sy, 0, 0, true);
                g_ptr_x += sx / kUnitsPerPixel;
                g_ptr_y += sy / kUnitsPerPixel;
                /* A step too small to divide cleanly still arrived, so treat
                 * the axis as settled rather than looping on it forever. */
                if (sx != 0 && sx / kUnitsPerPixel == 0) {
                    g_ptr_x = g_ptr_target_x;
                }
                if (sy != 0 && sy / kUnitsPerPixel == 0) {
                    g_ptr_y = g_ptr_target_y;
                }
            }
        }
    }

    /* Arrived: let any held-back clicks happen, now that they will happen
     * under the finger rather than along the way to it. */
    if (!ptr_is_travelling() && g_ptr_btn_count > 0) {
        for (int32_t i = 0; i < g_ptr_btn_count; ++i) {
            if (g_ptr_btn_queue[i].pressed) {
                Mouse_ButtonPressed(
                    static_cast<uint8_t>(g_ptr_btn_queue[i].button));
            } else {
                Mouse_ButtonReleased(
                    static_cast<uint8_t>(g_ptr_btn_queue[i].button));
            }
        }
        g_ptr_btn_count = 0;
    }

    /* Pausing blocks the mainloop here, which is the only place it is safe to
     * stop: no CPU emulation runs, no new frames are produced, and the last
     * frame stays intact for the UI to keep showing. */
    while (g_paused.load() && g_running.load()) {
        usleep(10 * 1000);
    }

    /* Every mutation of engine state happens here, on the mainloop thread --
     * that is the safe point the header promises. */
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

/* Called from the patched GFX_Events(), which DOSBox-X's Normal_Loop runs
 * every tick whether or not anything was drawn. This is the hook that keeps a
 * guest OS reachable; the frame hook alone is not enough. */
extern "C" void DOSBOX_BRIDGE_Pump(void)
{
    pump_requests();
}

extern "C" void DOSBOX_BRIDGE_PublishFrame(const uint32_t *pixels, int32_t width,
                                           int32_t height, int32_t pitch_bytes,
                                           double ratio)
{
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

    /* And into the shared mapping, when another process is doing the drawing.
     * A no-op when nothing is shared, which is the in-process case. */
    shared_frame_publish(pixels, width, height, pitch_bytes);

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

    /* Drain at the frame boundary too. GFX_Events() already pumps every tick,
     * but a frame is the point at which the app's view of the machine is
     * newest, so a request queued against what the user just saw takes effect
     * without waiting for the next tick. */
    pump_requests();
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
    g_thread_exited.store(false, std::memory_order_relaxed);
    if (g_started.exchange(true)) {
        return DOSBOX_ERR_ALREADY_STARTED;
    }
    if (conf_path == nullptr) {
        return DOSBOX_ERR;
    }
    g_conf_path = conf_path;
    g_ptr_x = g_ptr_y = -1;
    g_ptr_target_x = g_ptr_target_y = -1;
    g_ptr_rehome = false;
    g_ptr_home_left = 0;
    g_ptr_btn_count = 0;

    if (pthread_create(&g_thread, nullptr, mainloop_thread, nullptr) != 0) {
        g_started.store(false);
        return DOSBOX_ERR;
    }
    /* Joinable, not detached: stop() joins so the engine's teardown has
     * finished before the app returns to the library and offers another
     * launch. */
    return DOSBOX_OK;
}

extern "C" int32_t dosbox_core_stop(void)
{
    if (!g_started.load()) {
        return DOSBOX_ERR; /* nothing to stop */
    }
    /* Unpause first: the publish hook parks in its pause wait ahead of the
     * request drain, and the Quit request has to be drained to take effect. */
    g_paused.store(false);
    {
        std::lock_guard<std::mutex> guard(g_lock);
        g_pending.push_back(Request{Request::Quit, 0, 0, 0, 0});
    }

    /* Teardown can take a moment (the engine closes drives, devices, the
     * mapper and SDL), but it must not be allowed to wedge the caller: on a
     * stuck mainloop the app still has the process-restart fallback, which
     * only works if this call returns. */
    /* A bounded join, without pthread_timedjoin_np.
     *
     * That is a glibc extension: Bionic has no such function at any API level,
     * so the timed-join version of this never compiled for Android at all -
     * which is why the shipped core predates it. Polling a flag the engine
     * thread sets as it exits, then joining a thread already known to be
     * finished, is portable and keeps the property that actually matters here:
     * a stuck mainloop must not wedge the caller, because the app's only
     * remaining recourse - replacing the process - needs this call to return.
     */
    bool exited = false;
    for (int i = 0; i < 500; ++i) { /* 500 x 10ms = the same ~5s bound */
        if (g_thread_exited.load(std::memory_order_acquire)) {
            exited = true;
            break;
        }
        usleep(10 * 1000);
    }
    if (!exited) {
        return DOSBOX_ERR;
    }
    pthread_join(g_thread, nullptr);

    /* Back to the just-launched state so the next start() builds a fresh
     * session: no frames, no stick, no leftover input. */
    {
        std::lock_guard<std::mutex> guard(g_lock);
        g_pending.clear();
        g_frame.clear();
    }
    g_width = 0;
    g_height = 0;
    g_pitch = 0;
    g_frame_counter.store(0);
    g_aspect_x1000.store(0);
    g_started.store(false);
    g_joystick_attached.store(false);
    /* The next session's pointer is somewhere else entirely. */
    g_ptr_x = g_ptr_y = -1;
    g_ptr_target_x = g_ptr_target_y = -1;
    g_ptr_rehome = false;
    g_ptr_home_left = 0;
    g_ptr_btn_count = 0;
    return DOSBOX_OK;
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

extern "C" int32_t dosbox_core_cd_insert(const char *iso_path)
{
    if (!g_started.load()) {
        return DOSBOX_ERR_NOT_RUNNING;
    }
    {
        std::lock_guard<std::mutex> guard(g_lock);
        g_cd_path = iso_path ? iso_path : "";
    }
    queue(Request::CdInsert, 0, 0, 0, 0);
    return DOSBOX_OK;
}

extern "C" void dosbox_core_mouse_motion(int32_t dx, int32_t dy)
{
    queue(Request::MouseMotion, dx, dy, 0, 0);
}

extern "C" void dosbox_core_mouse_position(int32_t x_per_mille, int32_t y_per_mille)
{
    /* Put the guest pointer AT a place, which a PS/2 mouse cannot be told to
     * do: it is a relative device and reports only movement. The previous
     * implementation sent (target - last_target), which silently assumes the
     * guest pointer went exactly where the last call aimed it. Under a DOS
     * mouse driver that is roughly true. Under a guest OS it is not -- the OS
     * applies its own pointer speed and acceleration -- so the pointer drifted
     * away from the finger immediately and never came back. A touchscreen
     * needs the pointer to BE under the finger, so this tracks where we
     * believe it is and steers toward the target.
     *
     * The only position a relative device can be certain of is a corner: push
     * far enough in one direction and the pointer is pinned against the edge
     * however much acceleration was applied. That is the fixed point this
     * homes to whenever the belief is unusable. */
    if (g_width <= 0 || g_height <= 0) {
        return;
    }

    const int32_t tx = x_per_mille * g_width / 1000;
    const int32_t ty = y_per_mille * g_height / 1000;

    /* Home ONLY when there is no belief at all -- once per session.
     *
     * This used to re-home on any jump over a quarter of the screen, meaning
     * nearly every tap. The pointer visibly flew to the top-left corner and
     * back on each touch, which is both the "not smooth" part and half of the
     * reason clicks landed nowhere. Now that the scale factor is right the
     * belief tracks well enough to steer from directly, and a corner run is
     * reserved for having genuinely lost track. */
    const bool far_jump = (g_ptr_x < 0);

    /* Set a target; the pump walks toward it. Do NOT queue the whole journey
     * here.
     *
     * KEYBOARD_AUX_Event drops a packet outright when the keyboard buffer is
     * near full ("if ((keyb.used+4) < KEYBUFSIZE)"), and the guest drains
     * that buffer at its own PS/2 sample rate -- around 100Hz, not as fast as
     * a drain loop can push. A burst of sixteen packets in one pump therefore
     * delivers the first couple and silently discards the rest, which is why
     * the pointer moved a long way in one axis and barely at all in the
     * other: the surviving packets were arbitrary. */
    g_ptr_target_x = tx;
    g_ptr_target_y = ty;
    /* Start a corner run only if one is not already under way.
     *
     * far_jump is "we have no belief yet", which stays true for the whole
     * duration of the run that establishes it. Every position update in the
     * meantime -- and a finger on the glass produces a stream of them --
     * therefore re-entered this branch and reset the counter, so the run
     * restarted forever and the pointer simply travelled up and left without
     * ever arriving. Guarding on g_ptr_rehome lets the run finish, after
     * which g_ptr_x is 0 and far_jump is false for the rest of the session. */
    if (far_jump && !g_ptr_rehome) {
        g_ptr_rehome = true;
        g_ptr_home_left = 0;
    }
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
    /* Live output peak, computed by the audio backend from the real PCM it is
     * playing. Zero until a backend has been opened (i.e. before the first
     * frame / while the mixer is still booting). */
    return audio_backend_get_level();
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
