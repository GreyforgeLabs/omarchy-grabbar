// vpointer — inject pointer motion and buttons into a Wayland compositor
// through zwlr_virtual_pointer_v1. Used only against the isolated nested
// Hyprland test session; never point it at the live desktop.
//
//   vpointer WIDTH HEIGHT cmd [cmd...]
//   cmds: move X Y | down | up | click X Y | dblclick X Y | rclick X Y | mclick X Y
//         drag X1 Y1 X2 Y2 [steps] | sleep MS
//         drag X1 Y1 X2 Y2 [STEPS] | sleep MS
//
// Coordinates are absolute logical pixels of the target output.

#include <linux/input-event-codes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>

#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"

static struct wl_seat*                          seat = NULL;
static struct zwlr_virtual_pointer_manager_v1*  mgr  = NULL;
static struct zwlr_virtual_pointer_v1*          ptr  = NULL;
static struct wl_display*                       dpy  = NULL;
static uint32_t                                 W = 0, H = 0;

static void onGlobal(void* d, struct wl_registry* r, uint32_t name, const char* iface, uint32_t ver) {
    (void)d;
    (void)ver;
    if (!strcmp(iface, wl_seat_interface.name))
        seat = wl_registry_bind(r, name, &wl_seat_interface, 1);
    else if (!strcmp(iface, zwlr_virtual_pointer_manager_v1_interface.name))
        mgr = wl_registry_bind(r, name, &zwlr_virtual_pointer_manager_v1_interface, 1);
}

static void onGlobalRemove(void* d, struct wl_registry* r, uint32_t name) {
    (void)d;
    (void)r;
    (void)name;
}

static const struct wl_registry_listener REG = {onGlobal, onGlobalRemove};

static uint32_t nowMs(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

static void settle(int ms) {
    wl_display_flush(dpy);
    usleep(ms * 1000);
}

static void moveTo(double x, double y) {
    if (x < 0)
        x = 0;
    if (y < 0)
        y = 0;
    zwlr_virtual_pointer_v1_motion_absolute(ptr, nowMs(), (uint32_t)x, (uint32_t)y, W, H);
    zwlr_virtual_pointer_v1_frame(ptr);
    settle(15);
}

static void buttonCode(uint32_t code, int down) {
    zwlr_virtual_pointer_v1_button(ptr, nowMs(), code, down ? WL_POINTER_BUTTON_STATE_PRESSED : WL_POINTER_BUTTON_STATE_RELEASED);
    zwlr_virtual_pointer_v1_frame(ptr);
    settle(40);
}

static void button(int down) {
    buttonCode(BTN_LEFT, down);
}

int main(int argc, char** argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: vpointer WIDTH HEIGHT cmd...\n");
        return 2;
    }
    W = (uint32_t)atoi(argv[1]);
    H = (uint32_t)atoi(argv[2]);

    dpy = wl_display_connect(NULL);
    if (!dpy) {
        fprintf(stderr, "vpointer: cannot connect to WAYLAND_DISPLAY\n");
        return 1;
    }
    struct wl_registry* reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &REG, NULL);
    wl_display_roundtrip(dpy);
    if (!seat || !mgr) {
        fprintf(stderr, "vpointer: compositor lacks wl_seat or zwlr_virtual_pointer_manager_v1\n");
        return 1;
    }
    ptr = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(mgr, seat);
    wl_display_roundtrip(dpy);

    int i = 3;
    while (i < argc) {
        const char* cmd = argv[i++];
        if (!strcmp(cmd, "move") && i + 1 < argc) {
            moveTo(atof(argv[i]), atof(argv[i + 1]));
            i += 2;
        } else if (!strcmp(cmd, "down")) {
            button(1);
        } else if (!strcmp(cmd, "up")) {
            button(0);
        } else if (!strcmp(cmd, "click") && i + 1 < argc) {
            moveTo(atof(argv[i]), atof(argv[i + 1]));
            button(1);
            button(0);
            i += 2;
        } else if ((!strcmp(cmd, "rclick") || !strcmp(cmd, "mclick")) && i + 1 < argc) {
            moveTo(atof(argv[i]), atof(argv[i + 1]));
            buttonCode(cmd[0] == 'r' ? BTN_RIGHT : BTN_MIDDLE, 1);
            buttonCode(cmd[0] == 'r' ? BTN_RIGHT : BTN_MIDDLE, 0);
            i += 2;
        } else if (!strcmp(cmd, "dblclick") && i + 1 < argc) {
            moveTo(atof(argv[i]), atof(argv[i + 1]));
            button(1);
            button(0);
            settle(120);
            button(1);
            button(0);
            i += 2;
        } else if (!strcmp(cmd, "drag") && i + 3 < argc) {
            double x1 = atof(argv[i]), y1 = atof(argv[i + 1]), x2 = atof(argv[i + 2]), y2 = atof(argv[i + 3]);
            int    steps = 20;
            i += 4;
            if (i < argc && argv[i][0] >= '0' && argv[i][0] <= '9')
                steps = atoi(argv[i++]);
            moveTo(x1, y1);
            button(1);
            settle(60);
            for (int s = 1; s <= steps; s++)
                moveTo(x1 + (x2 - x1) * s / steps, y1 + (y2 - y1) * s / steps);
            settle(60);
            button(0);
        } else if (!strcmp(cmd, "sleep") && i < argc) {
            settle(atoi(argv[i++]));
        } else {
            fprintf(stderr, "vpointer: bad command near '%s'\n", cmd);
            return 2;
        }
    }

    wl_display_roundtrip(dpy);
    zwlr_virtual_pointer_v1_destroy(ptr);
    wl_display_disconnect(dpy);
    return 0;
}
