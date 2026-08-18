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
#include <string.h>
#include <unistd.h>

typedef void (*init_fn)(const char *);
typedef int32_t (*start_fn)(const char *);
typedef int32_t (*running_fn)(void);
typedef uint64_t (*counter_fn)(void);
typedef const uint32_t *(*fb_fn)(int32_t *, int32_t *, int32_t *);
typedef int32_t (*aspect_fn)(void);
typedef int32_t (*strget_fn)(char *, int32_t);

int main(int argc, char **argv)
{
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
     * enough that a hang is still a quick failure. */
    const uint64_t deadline = 200;
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

    if (core_aspect) printf("aspect x1000   : %d\n", core_aspect());
    if (core_prog) {
        char name[64] = {0};
        core_prog(name, sizeof(name));
        printf("running program: '%s'\n", name);
    }

    /* Frames must keep coming: one frame proves boot, a rising counter proves
     * the mainloop is alive rather than wedged after its first render. */
    const uint64_t first = core_counter();
    sleep(1);
    const uint64_t second = core_counter();
    printf("frames after 1s: %llu (+%llu)\n",
           (unsigned long long)second, (unsigned long long)(second - first));

    if (second == first) {
        fprintf(stderr, "FAIL: frame counter stopped advancing\n");
        return 1;
    }
    if (nonzero == 0) {
        fprintf(stderr, "FAIL: every pixel is black\n");
        return 1;
    }

    printf("PASS\n");
    return 0;
}
