#import "Logger.h"
#import <stdio.h>
#import <stdarg.h>
#import <dispatch/dispatch.h>

static NSString *TGLogPath(void) {
    // Telegram is sandboxed and refuses frida (anti-debug), so the only reliable
    // in-process signal is a log INSIDE the app's own container. NSTemporaryDirectory()
    // is always writable from within the host app. We locate the file afterwards by
    // searching /var/mobile/Containers/*/.../tmp/TGProxyRotation.log.
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"TGProxyRotation.log"];
}

static NSArray<NSString *> *TGLogPaths(void) {
    NSString *cache = [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches"]
        stringByAppendingPathComponent:@"TGProxyRotation.log"];
    NSString *tmp = TGLogPath();
    if (tmp.length && ![tmp isEqualToString:cache]) return @[tmp, cache];
    return @[cache];
}

static BOOL gLogEnabled = YES;
static NSLock *TGLogLock(void) {
    static NSLock *lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [NSLock new];
    });
    return lock;
}

void TGLogSetEnabled(BOOL enabled) {
    gLogEnabled = enabled;
}

void TGLog(NSString *format, ...) {
    if (!gLogEnabled) return;
    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    [fmt setDateFormat:@"HH:mm:ss.SSS"];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [fmt stringFromDate:[NSDate date]], body];

    NSLock *lock = TGLogLock();
    [lock lock];
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
        for (NSString *path in TGLogPaths()) {
            @autoreleasepool {
                NSString *dir = [path stringByDeletingLastPathComponent];
                if (dir && ![fm fileExistsAtPath:dir]) {
                    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
                }
                NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
                if ([attrs fileSize] > 1u * 1024u * 1024u) {
                    NSData *all = [NSData dataWithContentsOfFile:path];
                    if (all && all.length > 256u * 1024u) {
                        NSData *tail = [all subdataWithRange:NSMakeRange((NSUInteger)all.length - 256u * 1024u, 256u * 1024u)];
                        [tail writeToFile:path atomically:YES];
                    } else {
                        [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
                    }
                }
                NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
                if (!fh) {
                    [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
                    fh = [NSFileHandle fileHandleForWritingAtPath:path];
                }
                if (fh) {
                    [fh seekToEndOfFile];
                    [fh writeData:lineData];
                    [fh closeFile];
                }
            }
        }
    } @finally {
        [lock unlock];
    }
}
