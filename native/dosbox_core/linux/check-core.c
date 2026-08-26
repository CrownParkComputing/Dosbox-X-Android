/*
 * check-core.c - drive libdosboxcore.so the way the app does, on the host.
 *
 * Build and run with linux/check-core.sh.
 *
 * This exists because the alternative is testing the core by deploying to a
 * device, which is a slow loop and confuses "the core is broken" with "the
 * deploy is broken". Here a failure is a failure of the core alone.
 *
 * It dlopens the library exactly as Dart does (DynamicLibrary.open), boots a
 * generated .conf, and waits for the frame counter to move. A frame arriving
 * proves the whole chain: the engine started on its thread, parsed the conf,
 * booted DOS, ran the autoexec, rendered through the Game Link output, and the
 * patched Transfer hook published it to the bridge.
 */
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

typedef void (*init_fn)(const char *);
typedef int32_t (*start_fn)(const char *);
typedef int32_t (*running_fn)(void);
typedef uint64_t (*counter_fn)(void);
typedef const uint32_t *(*fb_fn)(int32_t *, int32_t *, int32_t *);
typedef int32_t (*aspect_fn)(void);
typedef int32_t (*strget_fn)(char *, int32_t);
typedef void (*mousemove_fn)(int32_t, int32_t);
typedef void (*mousepos_fn)(int32_t, int32_t);

int main(int argc, char **argv)
{
    /* Line-buffered: this harness is normally read through a pipe, and a
     * crash in the core would otherwise take the whole progress log with it,
     * leaving no way to tell a boot failure from a shutdown failure. */
    setvbuf(stdout, NULL, _IOLBF, 0);

    if (argc < 3) {
        fprintf(stderr, "usage: %s <libdosboxcore.so> <conf> [resource_dir]\n", argv[0]);
        return 2;
    }

    void *lib = dlopen(argv[1], RTLD_NOW);
    if (!lib) {
        fprintf(stderr, "FAIL: dlopen: %s\n", dlerror());
        return 1;
    }

    init_fn core_init = (init_fn)dlsym(lib, "dosbox_core_init");
    start_fn core_start = (start_fn)dlsym(lib, "dosbox_core_start");
    running_fn core_running = (running_fn)dlsym(lib, "dosbox_core_is_running");
    counter_fn core_counter = (counter_fn)dlsym(lib, "dosbox_core_get_frame_counter");
    fb_fn core_fb = (fb_fn)dlsym(lib, "dosbox_core_get_framebuffer");
    aspect_fn core_aspect = (aspect_fn)dlsym(lib, "dosbox_core_get_pixel_aspect_x1000");
    strget_fn core_prog = (strget_fn)dlsym(lib, "dosbox_core_get_running_program");

    if (!core_init || !core_start || !core_running || !core_counter || !core_fb) {
        fprintf(stderr, "FAIL: missing symbols\n");
        return 1;
    }

    core_init(argc > 3 ? argv[3] : ".");

    printf("starting with %s\n", argv[2]);
    int32_t rc = core_start(argv[2]);
    if (rc != 0) {
        fprintf(stderr, "FAIL: dosbox_core_start returned %d\n", rc);
        return 1;
    }

    /* Booting DOS takes a moment; the header documents start() as asynchronous
     * and tells callers to poll. 20s is far longer than a boot needs and short
     * enough that a hang is still a quick failure.
     *
     * CHECK_BOOT_SECONDS raises it for guests that are not DOS: a Windows 98
     * image has a boot sequence measured in minutes on an interpreted core,
     * and timing that out would report "the core is broken" for a machine
     * that is working exactly as configured. */
    const char *boot_env = getenv("CHECK_BOOT_SECONDS");
    const uint64_t deadline = boot_env ? (uint64_t)atoi(boot_env) * 10 : 200;
    uint64_t frames = 0;
    int running_seen = 0;
    for (uint64_t i = 0; i < deadline; ++i) {
        if (core_running()) running_seen = 1;
        frames = core_counter();
        if (frames > 0) break;
        usleep(100 * 1000);
    }

    printf("is_running     : %d\n", core_running());
    printf("frames         : %llu\n", (unsigned long long)frames);

    if (frames == 0) {
        fprintf(stderr, "FAIL: no frame was ever published (running_seen=%d)\n",
                running_seen);
        return 1;
    }

    /* CHECK_SETTLE_SECONDS lets the guest run on before the pixels are
     * judged. The first frame a Windows guest publishes is its BIOS POST
     * screen, which is a real frame and proves nothing about whether the OS
     * behind it ever loads. */
    const char *settle_env = getenv("CHECK_SETTLE_SECONDS");
    if (settle_env) {
        int settle = atoi(settle_env);
        printf("settling       : %ds\n", settle);
        for (int i = 0; i < settle; ++i) {
            sleep(1);
            if (!core_running()) {
                fprintf(stderr, "FAIL: core stopped running after %ds\n", i + 1);
                return 1;
            }
        }
        printf("frames after settle: %llu\n",
               (unsigned long long)core_counter());
    }

    int32_t w = 0, h = 0, pitch = 0;
    const uint32_t *px = core_fb(&w, &h, &pitch);
    printf("framebuffer    : %p %dx%d pitch=%d\n", (const void *)px, w, h, pitch);
    if (!px || w <= 0 || h <= 0) {
        fprintf(stderr, "FAIL: no framebuffer after a frame was counted\n");
        return 1;
    }

    /* An all-black frame would also satisfy the checks above, and black is
     * exactly what a broken render path produces, so look at the pixels. */
    int nonzero = 0;
    for (int y = 0; y < h; ++y) {
        const uint32_t *row = px + (size_t)y * (pitch / 4);
        for (int x = 0; x < w; ++x) {
            if ((row[x] & 0x00FFFFFFu) != 0) { nonzero++; }
        }
    }
    printf("non-black px   : %d of %d\n", nonzero, w * h);

    /* CHECK_DUMP_PPM writes the frame out so a human can see what the guest
     * actually reached. "Non-black pixels exist" is satisfied by a BIOS error
     * message as readily as by a desktop. */
    const char *dump = getenv("CHECK_DUMP_PPM");
    if (dump) {
        FILE *f = fopen(dump, "wb");
        if (f) {
            fprintf(f, "P6\n%d %d\n255\n", w, h);
            for (int y = 0; y < h; ++y) {
                const uint32_t *row = px + (size_t)y * (pitch / 4);
                for (int x = 0; x < w; ++x) {
                    uint32_t p = row[x];
                    fputc((p >> 16) & 0xFF, f);
                    fputc((p >> 8) & 0xFF, f);
                    fputc(p & 0xFF, f);
                }
            }
            fclose(f);
            printf("dumped frame   : %s\n", dump);
        }
    }

    if (core_aspect) printf("aspect x1000   : %d\n", core_aspect());
    if (core_prog) {
        char name[64] = {0};
        core_prog(name, sizeof(name));
        printf("running program: '%s'\n", name);
    }

    /* Frames must keep coming: one frame proves boot, a rising counter proves
     * the mainloop is alive rather than wedged after its first render.
     *
     * CHECK_ALLOW_STATIC relaxes that for a booted GUI. A Windows desktop
     * sitting idle -- or holding a modal dialog -- genuinely stops changing,
     * and DOSBox-X only publishes a frame when something does, so an
     * unmoving counter there means "nothing is happening on screen", not
     * "the emulator is wedged". Liveness is proven instead by the frames
     * that arrived during the settle period, which the caller sets a floor
     * for with CHECK_MIN_FRAMES. */
    const uint64_t first = core_counter();
    sleep(1);
    const uint64_t second = core_counter();
    printf("frames after 1s: %llu (+%llu)\n",
           (unsigned long long)second, (unsigned long long)(second - first));

    const int allow_static = getenv("CHECK_ALLOW_STATIC") != NULL;
    if (second == first && !allow_static) {
        fprintf(stderr, "FAIL: frame counter stopped advancing\n");
        return 1;
    }
    if (second == first && !core_running()) {
        fprintf(stderr, "FAIL: core is no longer running\n");
        return 1;
    }

    const char *min_frames_env = getenv("CHECK_MIN_FRAMES");
    if (min_frames_env) {
        const uint64_t min_frames = (uint64_t)atoi(min_frames_env);
        if (second < min_frames) {
            fprintf(stderr,
                    "FAIL: only %llu frames published, expected at least %llu\n",
                    (unsigned long long)second, (unsigned long long)min_frames);
            return 1;
        }
    }

    if (nonzero == 0) {
        fprintf(stderr, "FAIL: every pixel is black\n");
        return 1;
    }

    /* CHECK_MOUSE_TEST drives the mouse the way the app does and reports
     * whether the guest reacted. A guest OS draws its own pointer, so "the
     * picture changed after a mouse move and nothing else happened" is the
     * whole test -- and it isolates the bridge from Flutter and from the
     * Android IPC, which is the question when a pointer works nowhere. */
    /* CHECK_MOUSE_ABS drives dosbox_core_mouse_position -- the absolute
     * "put the pointer here" entry point the touchscreen uses -- rather than
     * the relative one. They are different code paths and only one of them is
     * what a finger actually reaches. */
    if (getenv("CHECK_MOUSE_ABS")) {
        mousepos_fn core_pos =
            (mousepos_fn)dlsym(lib, "dosbox_core_mouse_position");
        if (!core_pos) {
            printf("mouse abs      : SYMBOL MISSING\n");
        } else {
            const size_t px_count = (size_t)h * (size_t)(pitch / 4);
            uint32_t *before = (uint32_t *)malloc(px_count * 4);
            memcpy(before, px, px_count * 4);
            /* Two places far apart, so a pointer that only twitches is not
             * mistaken for one that goes where it is told. */
            core_pos(200, 200);
            sleep(1);
            core_pos(800, 800);
            sleep(1);
            int32_t w2 = 0, h2 = 0, p2 = 0;
            const uint32_t *after = core_fb(&w2, &h2, &p2);
            size_t changed = 0;
            if (after && w2 == w && h2 == h && p2 == pitch) {
                for (size_t i = 0; i < px_count; ++i) {
                    if ((before[i] & 0x00FFFFFFu) != (after[i] & 0x00FFFFFFu))
                        changed++;
                }
            }
            printf("mouse abs      : %zu pixels changed -> %s\n",
                   changed, changed > 0 ? "MOVES" : "NO RESPONSE");
            free(before);
        }
    }

    if (getenv("CHECK_MOUSE_TEST")) {
        mousemove_fn core_mouse =
            (mousemove_fn)dlsym(lib, "dosbox_core_mouse_motion");
        if (!core_mouse) {
            printf("mouse          : SYMBOL MISSING\n");
        } else {
            /* Snapshot, jog the mouse the way a finger would, compare. Many
             * small steps rather than one big jump: that is what the trackpad
             * sends, and a driver that coalesces or ignores large deltas
             * would otherwise pass a test no real input could. */
            const size_t px_count = (size_t)h * (size_t)(pitch / 4);
            uint32_t *before = (uint32_t *)malloc(px_count * 4);
            memcpy(before, px, px_count * 4);
            for (int i = 0; i < 40; ++i) {
                core_mouse(6, 4);
                usleep(20 * 1000);
            }
            sleep(1);
            int32_t w2 = 0, h2 = 0, p2 = 0;
            const uint32_t *after = core_fb(&w2, &h2, &p2);
            size_t changed = 0;
            if (after && w2 == w && h2 == h && p2 == pitch) {
                for (size_t i = 0; i < px_count; ++i) {
                    if ((before[i] & 0x00FFFFFFu) != (after[i] & 0x00FFFFFFu))
                        changed++;
                }
            }
            printf("mouse          : %zu pixels changed after 40 moves -> %s\n",
                   changed, changed > 0 ? "MOVES" : "NO RESPONSE");
            free(before);
        }
    }

    /* PASS is printed BEFORE teardown, on purpose. Everything the test set
     * out to prove has been proven by this point, and shutdown is a separate
     * question with its own separate answer below -- a core that boots and
     * renders correctly but crashes on the way out is a different bug from
     * one that never renders, and the two must not share an exit code. */
    printf("PASS\n");

    /* The return value is the whole point of calling this. stop() returns
     * DOSBOX_ERR when the mainloop never drained the quit request, and it
     * does so ~5 seconds later having NOT joined the thread -- so the process
     * then exits with the engine still executing guest code, and crashes on
     * the way out. Printing "clean" without looking made that failure read as
     * a success followed by an unrelated crash. */
    running_fn core_stop = (running_fn)dlsym(lib, "dosbox_core_stop");
    if (core_stop) {
        const int32_t rc = core_stop();
        if (rc == 0) {
            printf("shutdown       : clean\n");
        } else {
            printf("shutdown       : FAILED (dosbox_core_stop returned %d)\n",
                   rc);
        }
    }
    return 0;
}
