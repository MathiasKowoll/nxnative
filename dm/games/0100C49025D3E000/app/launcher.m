/* FC 27 launcher: the same settings surface as FC 26, connected to nxnative's dmhost.
   Game data stay under FC27WorkFolder (or FC27_WORK). The launcher embeds the rebuilt dmhost in its Resources and
   stages that binary in a separate app before opening it, so a rebuild never leaves an old runtime inode running.
   Settings use org.macnativegames.fc27 and the log is ~/Library/Logs/MacNativeGames/fc27.log.
   FC27_HOST_BINARY overrides the bundled runtime for development; FC27_LAUNCHER_DRYRUN=1 or --dry-run prints the exact
   plan. Options whose runtime support is still pending in FC27 remain visible but disabled in the UI. */
#import <Cocoa/Cocoa.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <sys/stdio.h>
#include <crt_externs.h>

#ifndef FC27_BINARY
#define FC27_BINARY "fc27-native"
#endif
#ifndef FC27_PATCHED_DIR
#define FC27_PATCHED_DIR "patched-v262144"
#endif

static BOOL bundled_mode(void) {
#ifdef FC27_BUNDLED
    return YES;
#else
    return NO;
#endif
}

static BOOL portuguese(void) { return [NSLocale.preferredLanguages.firstObject hasPrefix:@"pt"]; }
#define T(pt, en) (portuguese() ? @pt : @en)

static const int sizes[][2] = {{1280, 720}, {1600, 900}, {1920, 1080}, {2560, 1440}};
static const int outputs[] = {0, 2160, 1440, 1080, 900};   /* 0 = the monitor's native pixels, else the height of a 16:9 output */

static NSString *work_folder(void) {
    const char *e = getenv("FC27_WORK");
    if (e && *e) return @(e);
    NSString *configured = [NSBundle.mainBundle objectForInfoDictionaryKey:@"FC27WorkFolder"];
    if (configured.length) return configured;
    return bundled_mode() ? [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/MacNativeGames/FC27"] : nil;
}
static NSString *binary_path(void) {
    const char *e = getenv("FC27_HOST_BINARY");
    if (e && *e) return @(e);
#ifdef FC27_BUNDLED
    return [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents/MacOS/dmhost"];
#else
    return NSBundle.mainBundle.resourcePath ? [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@FC27_BINARY] : nil;
#endif
}
static NSSize screen_pixels(NSScreen *s) { CGFloat k = s.backingScaleFactor > 0 ? s.backingScaleFactor : 1; return NSMakeSize(round(s.frame.size.width * k), round(s.frame.size.height * k)); }
static NSString *screen_name(NSScreen *s) { return s.localizedName ?: @"?"; }

@interface Launcher : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property NSWindow *window;
@property NSPopUpButton *size, *monitor, *output;
@property NSSegmentedControl *display, *scaler;
@property NSButton *hud, *fps60, *handheld, *smartai, *ppAlternate, *play, *sonyButtons; @property NSSegmentedControl *textures, *textureBias, *postfx, *interpolation; @property NSTextField *note;
@property BOOL launch;
@end

@implementation Launcher
- (NSTextField *)label:(NSString *)s { NSTextField *l = [NSTextField labelWithString:s]; l.alignment = NSTextAlignmentRight; return l; }
- (NSPopUpButton *)popup:(NSArray<NSString *> *)items { NSPopUpButton *p = [NSPopUpButton new]; [p addItemsWithTitles:items]; p.target = self; p.action = @selector(changed:); return p; }
- (NSSegmentedControl *)segments:(NSArray<NSString *> *)labels {
    return [NSSegmentedControl segmentedControlWithLabels:labels trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(changed:)];
}
- (void)applicationDidFinishLaunching:(NSNotification *)n {
    (void)n;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    self.monitor = [NSPopUpButton new]; self.monitor.target = self; self.monitor.action = @selector(monitorChanged:);
    for (NSScreen *s in NSScreen.screens) {
        NSSize px = screen_pixels(s);
        [self.monitor addItemWithTitle:[NSString stringWithFormat:@"%@ — %.0f × %.0f, %ld Hz", screen_name(s), px.width, px.height, (long)s.maximumFramesPerSecond]];
    }
    self.display = [self segments:@[T("Janela", "Window"), T("Tela cheia", "Full screen")]];
    NSMutableArray *sizeTitles = [NSMutableArray array];
    for (unsigned i = 0; i < sizeof sizes / sizeof *sizes; i++) [sizeTitles addObject:[NSString stringWithFormat:@"%d × %d", sizes[i][0], sizes[i][1]]];
    self.size = [self popup:sizeTitles];
    self.output = [NSPopUpButton new]; self.output.target = self; self.output.action = @selector(changed:);
    self.scaler = [self segments:@[T("MetalFX (mais nítido)", "MetalFX (sharper)"), T("Normal", "Plain")]];
    self.textures = [self segments:@[T("16× anisotrópico", "16× anisotropic"), T("Juego", "Game")]];
    self.textureBias = [self segments:@[T("Estándar", "Standard"), T("-0,25 nítido", "-0.25 sharp"), T("-0,50 alto", "-0.50 high")]];
    self.postfx = [self segments:@[T("Off", "Off"), T("Suave", "Soft"), T("PS5", "PS5"), T("Equilibrado", "Balanced"), T("Ultra", "Ultra")]];
    self.interpolation = [self segments:@[T("Off", "Off"), T("30+30", "30+30"), T("Mitad Hz", "Half Hz"), T("Máx.", "Max")]];
    self.sonyButtons = [NSButton checkboxWithTitle:T("Botones PlayStation", "PlayStation buttons") target:self action:@selector(changed:)];
    self.hud = [NSButton checkboxWithTitle:T("Mostrar FPS e resolução (a tecla 1 esconde)", "Show FPS and resolution (key 1 hides it)") target:self action:@selector(changed:)];
    self.fps60 = [NSButton checkboxWithTitle:T("60 fps (aumenta o calor e o consumo)", "60 fps (increases heat and power use)") target:self action:@selector(changed:)];
    self.handheld = [NSButton checkboxWithTitle:T("Modo economia: portátil do Switch, 720p, menos calor (imagem menos nítida)", "Economy mode: Switch handheld, 720p, less heat (less sharp image)") target:self action:@selector(changed:)];
    self.smartai = [NSButton checkboxWithTitle:T("IA mais atenta (experimental; usa um pouco mais de processador)", "More attentive AI (experimental; uses a little more processor)") target:self action:@selector(changed:)];
    self.ppAlternate = [NSButton checkboxWithTitle:T("Otimização de IA em frames alternos (experimental)", "Alternate-frame AI optimization (experimental)") target:self action:@selector(changed:)];
    self.note = [NSTextField wrappingLabelWithString:@""]; self.note.textColor = NSColor.secondaryLabelColor; self.note.font = [NSFont systemFontOfSize:11];
    self.play = [NSButton buttonWithTitle:T("Jogar", "Play") target:self action:@selector(start:)]; self.play.keyEquivalent = @"\r";
    NSButton *quit = [NSButton buttonWithTitle:T("Sair", "Quit") target:NSApp action:@selector(terminate:)]; quit.keyEquivalent = @"\033";

    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[[self label:T("Monitor", "Monitor")], self.monitor],
        @[[self label:T("Tela", "Display")], self.display],
        @[[self label:T("Tamanho da janela", "Window size")], self.size],
        @[[self label:T("Resolução de saída", "Output resolution")], self.output],
        @[[self label:T("Escala", "Scaling")], self.scaler],
        @[[self label:T("Texturas", "Textures")], self.textures],
        @[[self label:T("Detalle de texturas", "Texture detail")], self.textureBias],
        @[[self label:T("Pós-processamento", "PostFX")], self.postfx],
        @[[self label:T("Interpolação MetalFX", "MetalFX interpolation")], self.interpolation],
        @[[self label:T("Controles", "Controls")], self.sonyButtons],
        @[[self label:T("Informação", "Info")], self.hud],
        @[[self label:T("Fluidez", "Smoothness")], self.fps60],
        @[[self label:T("Economia", "Economy")], self.handheld],
        @[[self label:T("Experimental", "Experimental")], self.smartai],
        @[[self label:T("Experimental", "Experimental")], self.ppAlternate],
    ]];
    grid.rowSpacing = 10; grid.columnSpacing = 12; [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    NSStackView *buttons = [NSStackView stackViewWithViews:@[quit, self.play]];
    NSStackView *stack = [NSStackView stackViewWithViews:@[grid, self.note, buttons]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical; stack.alignment = NSLayoutAttributeTrailing; stack.spacing = 16;
    stack.edgeInsets = NSEdgeInsetsMake(20, 20, 20, 20);
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 860, 520) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"FC 27"; self.window.contentView = stack; self.window.delegate = self;
    [self.note.widthAnchor constraintEqualToConstant:520].active = YES;

    [self load:d];
    [self refresh];
    [self.window center]; [self.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
}
- (NSScreen *)chosenScreen { NSInteger i = self.monitor.indexOfSelectedItem; NSArray *all = NSScreen.screens; return i >= 0 && i < (NSInteger)all.count ? all[i] : NSScreen.mainScreen; }
/* The output resolutions this monitor can show: native first, then the 16:9 ones that fit. */
- (void)fillOutputs:(int)want {
    [self.output removeAllItems];
    NSSize px = screen_pixels(self.chosenScreen); int pick = 0, k = 0;
    for (unsigned i = 0; i < sizeof outputs / sizeof *outputs; i++) {
        int h = outputs[i];
        if (h && h > px.height) continue;
        [self.output addItemWithTitle:h ? [NSString stringWithFormat:@"%d × %d", h * 16 / 9, h] : [NSString stringWithFormat:T("Nativa do monitor (%.0f × %.0f)", "The monitor's native (%.0f × %.0f)"), px.width, px.height]];
        self.output.lastItem.tag = h; if (h == want) pick = k; k++;
    }
    [self.output selectItemAtIndex:pick];
}
- (void)load:(NSUserDefaults *)d {
    NSString *m = [d stringForKey:@"monitor"]; NSArray *all = NSScreen.screens; NSUInteger mi = [all indexOfObject:NSScreen.mainScreen];
    if (mi == NSNotFound) mi = 0;
    for (NSUInteger i = 0; i < all.count; i++) if (m && [screen_name(all[i]) isEqualToString:m]) mi = i;
    [self.monitor selectItemAtIndex:(NSInteger)mi];
    self.display.selectedSegment = [d boolForKey:@"fullscreen"];
    NSInteger s = [d objectForKey:@"size"] ? [d integerForKey:@"size"] : 2; [self.size selectItemAtIndex:s >= 0 && s < 4 ? s : 2];
    self.scaler.selectedSegment = [d objectForKey:@"metalfx"] ? ([d boolForKey:@"metalfx"] ? 0 : 1) : 0;   // MetalFX by default
    self.textures.selectedSegment = [d boolForKey:@"textureFilter"] ? 0 : 1;   // 16x anisotropic by default
    NSInteger bias = [d objectForKey:@"textureBias"] ? [d integerForKey:@"textureBias"] : 1; if (bias < 0 || bias > 2) bias = 1; self.textureBias.selectedSegment = bias;   // -0.25 by default
    NSInteger postfx = [d objectForKey:@"postfx"] ? [d integerForKey:@"postfx"] : 3; if (postfx < 0 || postfx > 4) postfx = 3; self.postfx.selectedSegment = postfx;   // balanced PS5 postFX by default
    NSInteger interpolation = [d objectForKey:@"interpolation"] ? [d integerForKey:@"interpolation"] : 0; if (interpolation < 0 || interpolation > 3) interpolation = 0; self.interpolation.selectedSegment = interpolation;
    self.sonyButtons.state = [d objectForKey:@"sonyButtons"] ? [d boolForKey:@"sonyButtons"] : YES;
    [self fillOutputs:(int)[d integerForKey:@"output"]];
    self.fps60.state = [d objectForKey:@"FPS60"] ? [d boolForKey:@"FPS60"] : YES;   // 60 fps by default
    self.handheld.state = [d boolForKey:@"handheld"];
    self.smartai.state = [d boolForKey:@"smartai"];
    self.ppAlternate.state = [d boolForKey:@"ppAlternate"];
    self.hud.state = [d objectForKey:@"hud"] ? [d boolForKey:@"hud"] : YES;
}
/* Every change is saved at once (and written to disk), so the next start shows the same choices. */
- (void)monitorChanged:(id)sender { (void)sender; [self fillOutputs:(int)self.output.selectedItem.tag]; [self refresh]; [self save]; }
- (void)changed:(id)sender { (void)sender; [self refresh]; [self save]; }
- (void)refresh {
    self.size.enabled = NO; self.output.enabled = NO;
    self.monitor.enabled = NO; self.textures.enabled = NO; self.textureBias.enabled = NO;
    self.postfx.enabled = NO; self.interpolation.enabled = NO; self.sonyButtons.enabled = NO;
    self.hud.enabled = YES; self.handheld.enabled = NO; self.smartai.enabled = NO; self.ppAlternate.enabled = NO;
    self.display.enabled = YES; self.scaler.enabled = YES; self.fps60.enabled = YES;
    NSMutableString *s = [NSMutableString stringWithString:T("FC27: filtros/texturas, PostFX, controles PlayStation, handheld y opciones experimentales aún están pendientes de portar. El menú conserva las mismas ranuras para implementarlas una por una.", "FC27: texture filters, PostFX, PlayStation controls, handheld and experimental gameplay are still pending. The menu keeps the same slots so they can be implemented one by one.")];
    self.play.enabled = YES;
    if (!work_folder() || ![NSFileManager.defaultManager isExecutableFileAtPath:binary_path()]) {
        [s appendFormat:T("\nO jogo não está em %@.", "\nThe game is not in %@."), work_folder() ?: @"?"]; self.play.enabled = NO;
    }
    self.note.stringValue = s; self.note.hidden = !s.length;
}
- (void)save {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setBool:self.display.selectedSegment == 1 forKey:@"fullscreen"]; [d setInteger:self.size.indexOfSelectedItem forKey:@"size"];
    [d setInteger:self.output.selectedItem.tag forKey:@"output"]; [d setBool:self.scaler.selectedSegment == 0 forKey:@"metalfx"];
    [d setBool:self.textures.selectedSegment == 0 forKey:@"textureFilter"];
    [d setInteger:self.textureBias.selectedSegment forKey:@"textureBias"];
    [d setInteger:self.postfx.selectedSegment forKey:@"postfx"];
    [d setInteger:self.interpolation.selectedSegment forKey:@"interpolation"];
    [d setBool:self.sonyButtons.state forKey:@"sonyButtons"];
    [d setObject:screen_name(self.chosenScreen) forKey:@"monitor"]; [d setBool:self.hud.state forKey:@"hud"];
    [d setBool:self.fps60.state forKey:@"FPS60"];
    [d setBool:self.handheld.state forKey:@"handheld"];
    [d setBool:self.smartai.state forKey:@"smartai"];
    [d setBool:self.ppAlternate.state forKey:@"ppAlternate"];
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);   // persist before launching the separate game app
}
- (void)start:(id)sender { (void)sender; [self save]; self.launch = YES; [NSApp stop:nil]; [self.window orderOut:nil];
    NSEvent *e = [NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0];
    [NSApp postEvent:e atStart:YES]; }
- (void)windowWillClose:(NSNotification *)n { (void)n; if (!self.launch) { [self save]; [NSApp terminate:nil]; } }
@end

static void fail(NSString *s) {
    NSAlert *a = [NSAlert new]; a.messageText = T("O FC 27 não conseguiu iniciar", "FC 27 could not start"); a.informativeText = s; [a runModal];
}
static BOOL make_dir(NSString *p) { return [NSFileManager.defaultManager createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:nil]; }

/* What the game starts with, from the saved settings: the variables set and cleared, the folder, the command and the log.
   The start and the dry run (--dry-run or FC27_LAUNCHER_DRYRUN=1: print it, start nothing) share it. */
@interface LaunchPlan : NSObject
@property NSString *work, *data, *profile, *slot, *logs, *log, *previousLog, *input;
@property NSArray<NSString *> *args;
@property NSMutableArray<NSString *> *unset;
@property NSMutableDictionary<NSString *, NSString *> *set;
@end
@implementation LaunchPlan
@end

static LaunchPlan *launch_plan(NSUserDefaults *d, NSString *work, NSString *home, NSArray<NSScreen *> *all, NSScreen *main_screen) {
    (void)all; (void)main_screen;
    LaunchPlan *p = [LaunchPlan new]; NSMutableDictionary<NSString *, NSString *> *e = [NSMutableDictionary dictionary];
    p.work = work; p.set = e;
    p.data = [home stringByAppendingPathComponent:@"Library/Application Support/MacNativeGames/FC27"];
    p.logs = [home stringByAppendingPathComponent:@"Library/Logs/MacNativeGames"];
    p.log = [p.logs stringByAppendingPathComponent:@"fc27.log"]; p.previousLog = [p.logs stringByAppendingPathComponent:@"fc27.previous.log"];
    p.profile = [p.data stringByAppendingPathComponent:@"profile"];
    p.slot = [work stringByAppendingPathComponent:@"run-valid"];
    p.input = [p.slot stringByAppendingPathComponent:@"ctl.txt"];
    e[@"DM_NVN_SHDUMP"] = [p.slot stringByAppendingPathComponent:@"shader-dump"];
    p.unset = [@[@"DM_FPS_TARGET", @"DM_FULLSCREEN", @"DM_PRESENT_INTERVAL", @"DM_PRESENT_HZ", @"DM_PRESENT_LINK",
                 @"DM_PRESENT_UPSCALE", @"DM_METAL_HUD", @"DM_OPMODE", @"DM_CTL", @"DM_AUDIO_OFF", @"DM_PSO_MANIFEST", @"DM_QOS_MAP"] mutableCopy];

    e[@"DM_ROOT"] = work;
    e[@"DM_SAVE"] = [work stringByAppendingPathComponent:@"run-valid/save"];
    e[@"DM_TEMP"] = [work stringByAppendingPathComponent:@"run-valid/temp"];
    if (bundled_mode()) {
        NSString *resources = NSBundle.mainBundle.resourcePath ?: @"";
        NSString *dm = [resources stringByAppendingPathComponent:@"dm"];
        p.args = @[binary_path() ?: @"", dm];
        e[@"DM_ROMFS"] = [resources stringByAppendingPathComponent:@"romfs.img"];
        e[@"DM_FONT_DIR"] = [dm stringByAppendingPathComponent:@"font"];
        e[@"DM_MSL_DIR"] = [resources stringByAppendingPathComponent:@"msl"];
        e[@"DM_NVN_SHMAP"] = [dm stringByAppendingPathComponent:@"shader_map.tsv"];
        e[@"DM_PSO_BUNDLE"] = [resources stringByAppendingPathComponent:@"pso"];
        [p.unset addObjectsFromArray:@[@"DM_PSO_PREBUILD", @"DM_PSO_PREPARE", @"DM_PSO_ARCHIVE"]];
        NSString *aoc = [resources stringByAppendingPathComponent:@"aoc"];
        if ([NSFileManager.defaultManager fileExistsAtPath:aoc]) e[@"DM_AOC_DIR"] = aoc;
    } else {
        NSString *patched = [work stringByAppendingPathComponent:@FC27_PATCHED_DIR];
        p.args = @[binary_path() ?: @"", patched, @"main", @"sdk"];
        e[@"DM_ROMFS"] = [work stringByAppendingPathComponent:@"extract-base-update-v262144/RomFS.img"];
        e[@"DM_FONT_DIR"] = [work stringByAppendingPathComponent:@"run-valid/font"];
        e[@"DM_MSL_DIR"] = [work stringByAppendingPathComponent:@"shader-cache-fc27"];
        e[@"DM_NVN_SHMAP"] = [work stringByAppendingPathComponent:@"profile/shader_map.tsv"];
    }
    // During development the work-folder archive is prepared on demand. The
    // final app carries the archive in Resources/pso and must not rebuild it
    // into a path beside the user's game.
    if (!bundled_mode()) {
        e[@"DM_PSO_PREBUILD"] = @"1";
        e[@"DM_PSO_PREPARE"] = @"1";
        e[@"DM_PSO_ARCHIVE"] = [work stringByAppendingPathComponent:@"pipeline-cache-fc27"];
    }
    e[@"DM_QOS_MAP"] = @"1";   // keep the game's worker priorities below the real-time main thread
    e[@"DM_CTL"] = p.input;
    e[@"DM_WINDOW"] = @"1";
    e[@"DM_AUDIO"] = @"1";   // FC27's AudioOut must use CoreAudio on Mac, not the silent test sink
    e[@"DM_FULLSCREEN"] = [d boolForKey:@"fullscreen"] ? @"1" : @"0";
    e[@"DM_PRESENT_INTERVAL"] = @"display";
    e[@"DM_PRESENT_HZ"] = @"60";
    e[@"DM_PRESENT_LINK"] = @"0";
    e[@"DM_FPS_TARGET"] = [d boolForKey:@"FPS60"] ? @"60" : @"30";
    e[@"DM_PRESENT_UPSCALE"] = [d boolForKey:@"metalfx"] ? @"metalfx" : @"off";
    e[@"DM_METAL_HUD"] = [d boolForKey:@"hud"] ? @"1" : @"0";
    return p;
}

/* A fresh regular-file copy per launch: atomic replacement builds cannot leave an old inode here.
   Build and sign beside the destination, then replace it atomically. */
static NSDictionary *inherited_environment(void) {
    NSMutableDictionary *env = [NSMutableDictionary dictionary];
    for (char **e = *_NSGetEnviron(); *e; ++e) {
        NSString *entry = @(*e); NSRange equal = [entry rangeOfString:@"="];
        if (equal.location != NSNotFound) env[[entry substringToIndex:equal.location]] = [entry substringFromIndex:equal.location + 1];
    }
    return env;
}
static NSDictionary *game_environment(LaunchPlan *p, NSDictionary *inherited) {
    NSMutableDictionary *env = [inherited mutableCopy];
    [env removeObjectForKey:@"DM_APP_BOOTSTRAP"];
    for (NSString *key in p.unset) [env removeObjectForKey:key];
    [env addEntriesFromDictionary:p.set];
    return env;
}
static NSURL *prepare_game_app(LaunchPlan *p, NSError **error) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = [p.work stringByAppendingPathComponent:@"launcher-apps"];
    if (![fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    /* Stage without touching the previous signed bundle. */
    NSString *app = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"%@/FC 27.app", NSUUID.UUID.UUIDString]];
    NSString *contents = [app stringByAppendingPathComponent:@"Contents"];
    NSString *mac = [contents stringByAppendingPathComponent:@"MacOS"];
    if (![fm createDirectoryAtPath:mac withIntermediateDirectories:YES attributes:nil error:error] ||
        ![fm copyItemAtPath:p.args[0] toPath:[mac stringByAppendingPathComponent:@"fc27-native"] error:error]) return nil;
    /* Executable keeps the runtime's name: the tools and boot_gpu.sh find the player's game by "fc27-native rewritten". */
    NSDictionary *info = @{@"CFBundleExecutable": @"fc27-native", @"CFBundleIdentifier": @"org.macnativegames.fc27.game",
        @"CFBundleName": @"FC 27", @"CFBundlePackageType": @"APPL", @"CFBundleVersion": @"1",
        @"LSApplicationCategoryType": @"public.app-category.sports-games", @"NSHighResolutionCapable": @YES,
        @"CFBundleIconFile": @"AppIcon"};
    NSData *plist = [NSPropertyListSerialization dataWithPropertyList:info format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
    if (!plist || ![plist writeToFile:[contents stringByAppendingPathComponent:@"Info.plist"] options:NSDataWritingAtomic error:error]) return nil;
    NSString *icon = [NSBundle.mainBundle pathForResource:@"AppIcon" ofType:@"icns"];
    if (icon) {
        NSString *resources = [contents stringByAppendingPathComponent:@"Resources"];
        if (![fm createDirectoryAtPath:resources withIntermediateDirectories:YES attributes:nil error:error] ||
            ![fm copyItemAtPath:icon toPath:[resources stringByAppendingPathComponent:@"AppIcon.icns"] error:error]) return nil;
    }
    NSTask *sign = [NSTask new]; sign.executableURL = [NSURL fileURLWithPath:@"/usr/bin/codesign"];
    sign.arguments = @[@"--force", @"--sign", @"-", app];
    if (![sign launchAndReturnError:error]) return nil;
    [sign waitUntilExit];
    if (sign.terminationStatus) { if (error) *error = [NSError errorWithDomain:@"FC27Signing" code:sign.terminationStatus userInfo:nil]; return nil; }
    NSString *destination = [root stringByAppendingPathComponent:@"FC 27.app"];
    if ([fm fileExistsAtPath:destination]) {
        if (renamex_np(app.fileSystemRepresentation, destination.fileSystemRepresentation, RENAME_SWAP)) {
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
            return nil;
        }
        [fm removeItemAtPath:[app stringByDeletingLastPathComponent] error:nil];
    } else {
        if (![fm moveItemAtPath:app toPath:destination error:error]) return nil;
        [fm removeItemAtPath:[app stringByDeletingLastPathComponent] error:nil];
    }
    return [NSURL fileURLWithPath:destination];
}
static BOOL open_game(LaunchPlan *p, NSError **error) {
    if (!make_dir(p.profile) || !make_dir(p.slot) || !make_dir(p.logs) || !make_dir(p.set[@"DM_NVN_SHDUMP"])) return NO;
    /* Empty commands before opening; fail visibly instead of replaying stale commands. */
    if (![@"" writeToFile:p.input atomically:YES encoding:NSUTF8StringEncoding error:error]) return NO;
    if (bundled_mode()) {
        NSFileManager *fm = NSFileManager.defaultManager;
        if ([fm fileExistsAtPath:p.log]) [fm removeItemAtPath:p.previousLog error:nil], [fm moveItemAtPath:p.log toPath:p.previousLog error:nil];
        if (![fm createFileAtPath:p.log contents:nil attributes:nil]) {
            if (error) *error = [NSError errorWithDomain:@"FC27Launcher" code:1 userInfo:@{NSLocalizedDescriptionKey: @"No se pudo crear el log del juego."}];
            return NO;
        }
        NSFileHandle *log = [NSFileHandle fileHandleForWritingAtPath:p.log];
        NSTask *task = [NSTask new]; task.executableURL = [NSURL fileURLWithPath:p.args[0]];
        task.arguments = [p.args subarrayWithRange:NSMakeRange(1, p.args.count - 1)];
        task.currentDirectoryURL = [NSURL fileURLWithPath:p.data];
        task.environment = game_environment(p, inherited_environment());
        task.standardOutput = log; task.standardError = log;
        if (![task launchAndReturnError:error]) { [log closeFile]; return NO; }
        [task waitUntilExit]; [log closeFile];
        return YES;
    }
    NSURL *app = prepare_game_app(p, error); if (!app) return NO;
    NSDictionary *payload = @{@"environment":game_environment(p, inherited_environment()),
        @"work":p.work, @"log":p.log, @"previousLog":p.previousLog};
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:error]; if (!data) return NO;
    NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
    config.createsNewApplicationInstance = YES;
    config.arguments = [p.args subarrayWithRange:NSMakeRange(1, p.args.count - 1)];
    NSMutableDictionary *initial = [payload[@"environment"] mutableCopy];
    initial[@"DM_APP_BOOTSTRAP"] = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    config.environment = initial;
    __block BOOL done = NO, ok = NO; __block NSError *launchError = nil;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:app configuration:config completionHandler:^(NSRunningApplication *running, NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ok = running != nil && e == nil; launchError = e; done = YES;
        });
    }];
    while (!done) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    if (!ok && error) *error = launchError;
    return ok;
}

static NSString *quoted(NSString *s) { return [NSString stringWithFormat:@"'%@'", [s stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]]; }
/* The dry run: the plan as shell lines on stdout; 3 when the game is not in the work folder. */
static int dry_run(LaunchPlan *p) {
    printf("# FC 27 launcher, dry run: nothing is started\n# Equivalent runtime plan; actual opening uses LaunchServices (no exec).\ncd %s\nunset %s\n", quoted(p.work).UTF8String,
           [[p.unset sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@" "].UTF8String);
    for (NSString *k in [p.set.allKeys sortedArrayUsingSelector:@selector(compare:)]) printf("export %s=%s\n", k.UTF8String, quoted(p.set[k]).UTF8String);
    printf("# Commands are emptied before opening; the runtime rotates the log before loading the game.\n");
    printf("mkdir -p %s %s %s\n: > %s\n", quoted(p.profile).UTF8String, quoted(p.slot).UTF8String,
           quoted(p.logs).UTF8String, quoted(p.input).UTF8String);
    printf("rm -f %s\n[ ! -f %s ] || mv %s %s\n", quoted(p.previousLog).UTF8String, quoted(p.log).UTF8String,
           quoted(p.log).UTF8String, quoted(p.previousLog).UTF8String);
    printf("exec %s", quoted(p.args[0]).UTF8String);
    for (NSUInteger i = 1; i < p.args.count; i++) printf(" %s", quoted(p.args[i]).UTF8String);
    printf(" > %s 2>&1\n", quoted(p.log).UTF8String);
    if (![NSFileManager.defaultManager isExecutableFileAtPath:p.args[0]]) { fprintf(stderr, "the game is not built: %s\n", p.args[0].UTF8String); return 3; }
    return 0;
}

static void register_defaults(void) {
    /* Persistent saved values win; these are the values a fresh installation starts with. */
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        @"FPS60": @YES, @"metalfx": @YES, @"textureFilter": @YES, @"textureBias": @1, @"postfx": @3, @"sonyButtons": @YES, @"hud": @YES,
        @"interpolation": @0, @"fullscreen": @NO, @"handheld": @NO, @"smartai": @NO, @"ppAlternate": @NO
    }];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        register_defaults();
        const char *dry = getenv("FC27_LAUNCHER_DRYRUN");
        if ((argc > 1 && !strcmp(argv[1], "--dry-run")) || (dry && !strcmp(dry, "1"))) {
            NSString *work = work_folder(); if (!work) { fprintf(stderr, "no work folder (Info.plist FC27WorkFolder or FC27_WORK)\n"); return 2; }
            return dry_run(launch_plan(NSUserDefaults.standardUserDefaults, work, NSHomeDirectory(), NSScreen.screens, NSScreen.mainScreen));
        }
        [NSApplication sharedApplication]; NSApp.activationPolicy = NSApplicationActivationPolicyRegular;
        Launcher *l = [Launcher new]; NSApp.delegate = l;
        [NSApp run];
        if (!l.launch) return 0;
        LaunchPlan *p = launch_plan(NSUserDefaults.standardUserDefaults, work_folder(), NSHomeDirectory(), NSScreen.screens, NSScreen.mainScreen);
        NSError *error = nil;
        if (open_game(p, &error)) return 0;
        fail(error.localizedDescription ?: @"Não foi possível preparar o app do jogo.");
        return 1;
    }
}
