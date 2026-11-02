// Apple TV controller front end.  tvOS has no touch surface, so this target
// keeps only the GameController path from DmGamepad.m and feeds the same
// Switch button/axis layout to the host.
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#include <math.h>
#include <stdlib.h>
#include "dm.h"
#include "dm_input.h"
#include "pad_slots.h"
#include "haptics_apple.h"

static pad_slots g_slots;
static GCController *g_held[DM_PLAYERS];
static int g_merge;
static int g_started;

static int32_t axis(float v) {
    return (int32_t)(fmaxf(-1.f, fminf(1.f, v)) * DM_STICK_MAX);
}

static const char *pad_name(GCController *c) {
    return c.vendorName.UTF8String ?: "?";
}

static void read_pad(GCExtendedGamepad *g) {
    int p = g_merge ? 0 : pad_slot_of(&g_slots, (__bridge const void *)g.controller);
    if (p < 0) return;
    uint64_t m = 0;
#define K(btn, bit) if (btn.isPressed) m |= 1ull << (bit)
    // GameController's physical positions match the Switch layout after this
    // A/B and X/Y swap: right A, bottom B, top X, left Y.
    K(g.buttonB, 0); K(g.buttonA, 1); K(g.buttonY, 2); K(g.buttonX, 3);
    K(g.leftShoulder, 6); K(g.rightShoulder, 7);
    K(g.leftTrigger, 8); K(g.rightTrigger, 9);
    K(g.buttonMenu, 10);
    if (g.buttonOptions) K(g.buttonOptions, 11);
    if (g.leftThumbstickButton) K(g.leftThumbstickButton, 4);
    if (g.rightThumbstickButton) K(g.rightThumbstickButton, 5);
    K(g.dpad.left, 12); K(g.dpad.up, 13); K(g.dpad.right, 14); K(g.dpad.down, 15);
#undef K
    dm_haptics_apple_controller(p, g.controller);
    dm_pad_set_player(p, m, axis(g.leftThumbstick.xAxis.value), axis(g.leftThumbstick.yAxis.value),
                      axis(g.rightThumbstick.xAxis.value), axis(g.rightThumbstick.yAxis.value));
}

static void merged_refresh(GCController *gone) {
    if (gone) gone.extendedGamepad.valueChangedHandler = nil;
    BOOL any = NO;
    for (GCController *c in GCController.controllers) {
        if (c == gone || !c.extendedGamepad) continue;
        any = YES;
        c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *element) {
            (void)element; read_pad(g);
        };
        read_pad(c.extendedGamepad);
    }
    if (!any) {
        dm_haptics_apple_controller(0, nil);
        dm_pad_set(0, 0, 0, 0, 0);
    }
    dm_pad_players(any ? 1u : 0u);
}

static void slotted_refresh(GCController *gone) {
    NSArray<GCController *> *now = GCController.controllers;
    char name[64];
    for (int p = 0; p < DM_PLAYERS; p++) {
        GCController *held = g_held[p];
        if (!held || (held != gone && [now containsObject:held])) continue;
        snprintf(name, sizeof name, "%s", pad_name(held));
        LOG("controller '%s' disconnected: player %d is free", name, p + 1);
        held.extendedGamepad.valueChangedHandler = nil;
        dm_haptics_apple_controller(p, nil);
        pad_slot_free(&g_slots, (__bridge const void *)held);
        g_held[p] = nil;
        dm_pad_set_player(p, 0, 0, 0, 0, 0);
    }
    for (GCController *c in now) {
        if (!c.extendedGamepad || c == gone || pad_slot_of(&g_slots, (__bridge const void *)c) >= 0) continue;
        int p = pad_slot_take(&g_slots, (__bridge const void *)c, pad_name(c));
        if (p < 0) {
            LOG("controller '%s' connected: all %d players are taken, not used", pad_name(c), DM_PLAYERS);
            continue;
        }
        g_held[p] = c;
        c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *element) {
            (void)element; read_pad(g);
        };
        LOG("controller '%s' connected: player %d", pad_name(c), p + 1);
        read_pad(c.extendedGamepad);
    }
    dm_pad_players(pad_slot_mask(&g_slots));
}

static void pads_changed(NSNotification *note) {
    GCController *c = note.object;
    GCController *gone = [note.name isEqual:GCControllerDidDisconnectNotification] ? c : nil;
    if (g_merge) merged_refresh(gone); else slotted_refresh(gone);
}

void dm_tv_gamepad_start(void) {
    if (g_started) return;
    g_started = 1;
    const char *e = getenv("DM_PAD_MERGE"); g_merge = e && atoi(e);
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:GCControllerDidConnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock: ^(NSNotification *n) { pads_changed(n); }];
    [nc addObserverForName:GCControllerDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock: ^(NSNotification *n) { pads_changed(n); }];
    LOG("front end: tvOS controllers %s", g_merge ? "merged into player 1" : "assigned to player slots");
    if (g_merge) merged_refresh(nil); else slotted_refresh(nil);
}

void dm_gamepad_reset(void) {
    for (int p = 0; p < DM_PLAYERS; p++) dm_pad_set_player(p, 0, 0, 0, 0, 0);
    dm_pad_players(g_merge ? (GCController.controllers.count ? 1u : 0u) : pad_slot_mask(&g_slots));
}
