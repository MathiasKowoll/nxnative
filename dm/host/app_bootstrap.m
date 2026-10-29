/* LaunchServices envelope for nxnative's Mac host launchers. Direct command-line boots leave the process unchanged. */
#import <Foundation/Foundation.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <crt_externs.h>
#include "app_bootstrap.h"

static int dm_bootstrap_failure(void) {
    const char *override = getenv("DM_BOOTSTRAP_LOG_DIR");
    NSString *dir = override && *override ? @(override) : [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/MacNativeGames"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:@"nxnative-bootstrap-error.log"];
    NSString *message = [NSString stringWithFormat:@"%@ — could not prepare the app environment or open the log.\n", NSDate.date];
    [message writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    fprintf(stderr, "[launcher] bootstrap failed; see %s\n", path.fileSystemRepresentation);
    return 1;
}

int dm_apply_app_bootstrap(void) {
    const char *raw = getenv("DM_APP_BOOTSTRAP");
    if (!raw) return 0;
    @autoreleasepool {
        NSData *data = [@(raw) dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *p = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![p isKindOfClass:NSDictionary.class] || ![p[@"environment"] isKindOfClass:NSDictionary.class] ||
            ![p[@"work"] isKindOfClass:NSString.class] || ![p[@"log"] isKindOfClass:NSString.class] ||
            ![p[@"previousLog"] isKindOfClass:NSString.class]) return dm_bootstrap_failure();
        NSDictionary *env = p[@"environment"];
        for (id k in env) if (![k isKindOfClass:NSString.class] || ![env[k] isKindOfClass:NSString.class]) return dm_bootstrap_failure();
        if (chdir([p[@"work"] fileSystemRepresentation])) return dm_bootstrap_failure();
        NSFileManager *fm = NSFileManager.defaultManager;
        NSError *error = nil;
        if ([fm fileExistsAtPath:p[@"previousLog"]] && ![fm removeItemAtPath:p[@"previousLog"] error:&error]) return dm_bootstrap_failure();
        if ([fm fileExistsAtPath:p[@"log"]] && ![fm moveItemAtPath:p[@"log"] toPath:p[@"previousLog"] error:&error]) return dm_bootstrap_failure();
        FILE *log = fopen([p[@"log"] fileSystemRepresentation], "w");
        if (!log) return dm_bootstrap_failure();
        int out = dup2(fileno(log), STDOUT_FILENO), err = dup2(fileno(log), STDERR_FILENO);
        fclose(log);
        if (out < 0 || err < 0) return dm_bootstrap_failure();
        NSMutableArray *keys = [NSMutableArray array];
        for (char **e = *_NSGetEnviron(); *e; ++e) {
            NSString *entry = @(*e); NSRange equal = [entry rangeOfString:@"="];
            if (equal.location != NSNotFound) [keys addObject:[entry substringToIndex:equal.location]];
        }
        for (NSString *key in keys) unsetenv(key.UTF8String);
        for (NSString *key in env) if (setenv(key.UTF8String, [env[key] UTF8String], 1)) return dm_bootstrap_failure();
        fprintf(stderr, "[launcher] work %s, fps target %s, present %s Hz, interval %s, fullscreen %s, MetalFX %s\n",
                [p[@"work"] UTF8String], getenv("DM_FPS_TARGET") ?: "profile", getenv("DM_PRESENT_HZ") ?: "?",
                getenv("DM_PRESENT_INTERVAL") ?: "profile", getenv("DM_FULLSCREEN") ?: "0", getenv("DM_PRESENT_UPSCALE") ?: "off");
        return 0;
    }
}
