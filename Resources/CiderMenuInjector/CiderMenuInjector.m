// CiderMenuInjector.m — DYLD_INSERT_LIBRARIES rider for wine.
//
// The wine binary (winemac.drv) builds its own NSApplication menu
// once it gets to the Cocoa main loop. This dylib loads BEFORE that
// happens (constructor + NSApplicationDidFinishLaunchingNotification
// observer) and injects two items into wine's first menu (the
// "application" submenu):
//
//   Settings…   (⌘,)   →  posts a NSDistributedNotification that
//                          Cider's parent process listens for and
//                          turns into "open Configure"
//   ──────────
//
// Why this works without modifying wine:
//   * macOS's hardened runtime allows DYLD_INSERT_LIBRARIES on
//     binaries entitled with com.apple.security.cs.allow-dyld-
//     environment-variables AND
//     com.apple.security.cs.disable-library-validation. The
//     Sikarugir wine binary ships with both (so do Whisky's,
//     CrossOver's). If a future engine drops them, this dylib
//     fails to load silently and the user sees the regular wine
//     menu.
//   * Wine's mainMenu is a vanilla NSMenu. Adding items via
//     NSMenu insertItem:atIndex: doesn't fight winemac.drv —
//     wine never re-creates the application menu after launch.
//
// Two env vars must be set by the parent (Cider) before exec:
//   CIDER_PARENT_PID         — the Cider PID; goes into the
//                               distributed-notification userInfo
//                               so multiple running Ciders only
//                               handle their own children's clicks
//   CIDER_MENU_NOTIFICATION  — the notification name to post
//                               (kept configurable so Cider can
//                               version it without re-shipping the
//                               dylib if needed)
//
// If either env var is missing the dylib still adds the menu item
// but the click is a no-op (and a debug log line on stderr).

#import <AppKit/AppKit.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

@interface CiderMenuInjectorTarget : NSObject
- (void)showSettings:(id)sender;
@end

@implementation CiderMenuInjectorTarget

- (void)showSettings:(id)sender {
    const char *name = getenv("CIDER_MENU_NOTIFICATION");
    const char *parent = getenv("CIDER_PARENT_PID");
    if (!name || !parent) {
        fprintf(stderr, "[CiderMenuInjector] missing env vars; Settings… click is a no-op\n");
        return;
    }
    NSString *notificationName = [NSString stringWithUTF8String:name];
    NSString *parentPID = [NSString stringWithUTF8String:parent];
    NSDictionary *userInfo = @{ @"parentPID": parentPID };
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:notificationName
                      object:nil
                    userInfo:userInfo
          deliverImmediately:YES];
}

@end

// Strong static so the target survives past the constructor.
static CiderMenuInjectorTarget *gCiderMenuInjectorTarget = nil;
static id gCiderMenuInjectorObserver = nil;

static void CiderMenuInjector_inject(void) {
    NSMenu *mainMenu = [NSApp mainMenu];
    if (!mainMenu || mainMenu.numberOfItems == 0) {
        return;
    }
    NSMenuItem *appMenuItem = [mainMenu itemAtIndex:0];
    NSMenu *appMenu = [appMenuItem submenu];
    if (!appMenu) {
        return;
    }

    // Make sure we only inject once per process. Tag-based dedup: a
    // distinctive tag identifies a previously-inserted Settings item.
    static const NSInteger kCiderSettingsTag = 0x431D5E15;
    for (NSMenuItem *existing in [appMenu itemArray]) {
        if (existing.tag == kCiderSettingsTag) {
            return;
        }
    }

    if (!gCiderMenuInjectorTarget) {
        gCiderMenuInjectorTarget = [[CiderMenuInjectorTarget alloc] init];
    }

    NSMenuItem *settings = [[NSMenuItem alloc]
        initWithTitle:@"Settings…"
               action:@selector(showSettings:)
        keyEquivalent:@","];
    settings.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    settings.target = gCiderMenuInjectorTarget;
    settings.tag = kCiderSettingsTag;

    NSMenuItem *separator = [NSMenuItem separatorItem];
    separator.tag = kCiderSettingsTag;

    // Insert after the About item if present (typically index 0),
    // otherwise at the very top. Followed by a separator so the
    // Settings item sits in its own visual group above wine's
    // own Hide / Quit lines.
    NSInteger insertAt = (appMenu.numberOfItems > 0) ? 1 : 0;
    [appMenu insertItem:separator atIndex:insertAt];
    [appMenu insertItem:settings atIndex:insertAt];
}

__attribute__((constructor))
static void CiderMenuInjector_load(void) {
    @autoreleasepool {
        // Try once now in case NSApp.mainMenu is already set up
        // (rare — the dylib usually loads before wine builds its
        // menu).
        CiderMenuInjector_inject();

        // Also observe didFinishLaunching so we hit the common path
        // where wine builds the menu after launch.
        gCiderMenuInjectorObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:NSApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *_Nonnull note) {
                        CiderMenuInjector_inject();
                    }];
    }
}
