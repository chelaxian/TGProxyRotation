#import "Logger.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <unistd.h>
#import <sqlite3.h>
// SecTask.h is absent from the iOS SDK Security umbrella; forward-declare the
// two entitlement APIs we use (resolved at link time via Security.framework).
typedef struct __SecTask *SecTaskRef;
extern SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error);
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <sys/time.h>
#import <poll.h>
#import <fcntl.h>
#import <errno.h>

#pragma mark - MtProtoKit surface (local minimal protocol declarations)
@protocol TGMTApiEnvironment
- (id)socksProxySettings;
- (id)withUpdatedSocksProxySettings:(id)socksProxySettings;
- (id)datacenterAddressOverrides;
@end
@protocol TGMTSocksProxySettingsBuilder
- (id)initWithIp:(NSString *)ip port:(uint16_t)port username:(NSString *)username password:(NSString *)password secret:(NSData *)secret;
@end
@protocol TGMTContext
- (id)apiEnvironment;
- (void)updateApiEnvironment:(id (^)(id))f;
@end

// forward declarations
static NSDictionary *TGParseProxyLink(NSString *link);
static id<TGMTContext> TGContext(void);
static void TGUpdatePanel(void);
static UIWindow *TGKeyWindow(void);
static NSString *TGActiveProxyHostSnapshot(void);

// Forward-declared so TGShowToast can reference the global gesture target.
@interface TGGestureTarget : NSObject
- (void)openPanel;
@end
static TGGestureTarget *gGestureTarget;

#pragma mark - Preferences
#define kDarwinNotify "com.ratush.tgproxyrotation.changed"
#define kKeyEnabled    @"enabled"
#define kKeyInterval   @"intervalSec"
#define kKeyIndex      @"currentIndex"
#define kKeyShowPanel  @"showPanel"
#define kKeyLanguage   @"language"
#define kKeyProxyOff   @"proxyOff"   // YES = proxy fully disabled (no SOCKS)
#define kKeyTelemt     @"telemtSearch"  // YES = fetch proxies from online list
#define kKeyProxyURL   @"proxyListURL"  // custom URL for proxy list
#define kDefaultProxyURL @"https://raw.githubusercontent.com/chelaxian/freetelemt/main/proxies.txt"

static NSString *TGPrefsPath(void) {
    NSString *lib = [NSHomeDirectory() stringByAppendingPathComponent:@"Library"];
    return [lib stringByAppendingPathComponent:[@"com.ratush.tgproxyrotation" stringByAppendingPathExtension:@"plist"]];
}
static NSDictionary *TGPrefsLoad(void) { return [NSDictionary dictionaryWithContentsOfFile:TGPrefsPath()]; }
static void TGPrefsSave(NSDictionary *d) { [d writeToFile:TGPrefsPath() atomically:YES]; notify_post(kDarwinNotify); }

// ---- Runtime state ----
static BOOL gEnabled = NO;
static NSInteger gIntervalSec = 10;  // default 10s (most balanced)
static BOOL gShowPanel = YES;
static NSString *gLanguage = @"ru";
static BOOL gProxyOff = NO;   // proxy fully disabled by long-press toggle
static BOOL gProxyConfirmed = NO; // TRUE only when the active proxy is verified working
static BOOL gStartupPending = NO; // TRUE: first watchdog tick should apply saved proxy
static BOOL gTelemtSearch = NO;   // fetch proxies from online list
static NSMutableArray<NSDictionary *> *gTelemtProxies = nil; // online-fetched proxies
static NSString *gProxyListURL = kDefaultProxyURL;
static NSMutableArray<NSDictionary *> *gProxies = nil; // host,port,secret,link
static NSInteger gCurrentIndex = 0;
static NSString *gActiveProxyHost = nil; // host currently rotated to by tweak
static NSString *gPendingConfirmationHost = nil;

static __weak id gContextWeak = nil;
static NSTimer *gWatchTimer = nil;
static volatile CFAbsoluteTime gLastSuccessAbs = 0.0;
static volatile CFAbsoluteTime gCooldownUntil = 0.0;
static volatile int gConsecutiveRotates = 0;
static volatile CFAbsoluteTime gLastRotateAbs = 0.0;

// Proxy reachability probe (TCP connect latency in ms; -1 = unreachable).
static volatile NSInteger gLastPingMs = -1;
static NSString *gLastPingHost = nil;
static volatile BOOL gPingRunning = NO;
static NSString *gPendingProbeHost = nil;   // queued for next probe cycle
static uint16_t gPendingProbePort = 0;
// Telegram's own transport results — authoritative reachability signal.
static volatile CFAbsoluteTime gTransportSuccessAbs = 0.0;  // last success for active proxy
static volatile CFAbsoluteTime gTransportFailureAbs = 0.0;  // last failure for active proxy

static BOOL TGLangRU(void) { return ![gLanguage isEqualToString:@"en"]; }
static NSString *TGLoc(NSString *ru, NSString *en) { return TGLangRU() ? ru : en; }

#pragma mark - Postbox proxy list reader
// Reads ProxySettings from Telegram's Account Manager SQLite (shared app-group).
// Key 0x04 in table t2 holds the Codable-encoded struct. We parse host/port/secret.
#pragma mark - Client-agnostic proxy DB discovery
// TGProxyRotation works with any MTProtoKit-based Telegram client - the official
// app, Swiftgram, Nicegram, etc. Each fork ships its own app-group container but
// stores the account DB at the same relative path. We discover the right group
// from THIS process's own entitlements, so nothing is hardcoded to one client.
static NSString *const kTGDBRelPath = @"telegram-data/accounts-metadata/db/db_sqlite";

static NSArray<NSString *> *TGAppGroupsFromEntitlements(void) {
    SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
    if (!task) return nil;
    CFTypeRef val = SecTaskCopyValueForEntitlement(task, CFSTR("com.apple.security.application-groups"), NULL);
    CFRelease(task);
    if (val && CFGetTypeID(val) == CFArrayGetTypeID()) return (__bridge_transfer NSArray *)val;
    if (val) CFRelease(val);
    return nil;
}

// Path to the active Telegram-family account DB, or nil. First success is
// cached; nil is never cached (the DB may not be ready yet at launch).
static NSString *gCachedDBPath = nil;
static NSString *TGProxyDBPath(void) {
    if (gCachedDBPath) return gCachedDBPath;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *groups = [NSMutableArray array];
    // 1) Authoritative: whatever app-groups this client actually declares.
    for (NSString *g in TGAppGroupsFromEntitlements())
        if (g.length && ![groups containsObject:g]) [groups addObject:g];
    // 2) Derived + known fallbacks (if entitlements are unreadable).
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (bid.length) {
        NSString *derived = [@"group." stringByAppendingString:bid];
        if (![groups containsObject:derived]) [groups addObject:derived];
    }
    for (NSString *g in @[@"group.ph.telegra.Telegraph", @"group.app.swiftgram.ios"])
        if (![groups containsObject:g]) [groups addObject:g];
    for (NSString *g in groups) {
        NSURL *u = [fm containerURLForSecurityApplicationGroupIdentifier:g];
        if (!u) continue;
        NSString *p = [[u path] stringByAppendingPathComponent:kTGDBRelPath];
        if ([fm fileExistsAtPath:p]) {
            gCachedDBPath = [p copy];
            TGLog(@"postbox DB via app-group %@", g);
            return gCachedDBPath;
        }
    }
    return nil;
}

// YES if this process is a Telegram-family client we should activate in.
static BOOL TGIsSupportedClient(void) {
    if (objc_getClass("MTContext")) return YES;   // MTProtoKit present
    if (TGProxyDBPath()) return YES;              // account DB reachable
    NSString *bid = [[[NSBundle mainBundle] bundleIdentifier] lowercaseString] ?: @"";
    return ([bid rangeOfString:@"telegra"].location != NSNotFound ||
            [bid rangeOfString:@"swiftgram"].location != NSNotFound ||
            [bid rangeOfString:@"nicegram"].location != NSNotFound);
}

static NSMutableArray<NSDictionary *> *TGReadProxySettingsFromPostbox(void) {
    NSMutableArray *results = [NSMutableArray array];
    NSString *dbPath = TGProxyDBPath();
    if (!dbPath) return results;

    sqlite3 *db = NULL;
    if (sqlite3_open_v2(dbPath.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return results;
    }
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, "SELECT value FROM t2 WHERE key = X'00000004'", -1, &stmt, NULL) == SQLITE_OK) {
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            const unsigned char *p = (const unsigned char *)sqlite3_column_blob(stmt, 0);
            int blen = sqlite3_column_bytes(stmt, 0);
            if (p && blen > 100) {
                // Find "activeServer" marker to know where servers array ends.
                int activeOff = -1;
                for (int i = 0; i + 13 < blen; i++) {
                    if (p[i] == 0x0c && memcmp(p+i+1, "activeServer", 12) == 0) { activeOff = i; break; }
                }
                for (int i = 0; i + 9 < blen; i++) {
                    if (activeOff > 0 && i >= activeOff) break;
                    if (p[i] != 0x04 || memcmp(p+i+1, "host", 4) != 0) continue;
                    if (i + 10 >= blen) break;
                    uint32_t hlen = p[i+6] | (p[i+7]<<8) | (p[i+8]<<16) | (p[i+9]<<24);
                    if (hlen == 0 || hlen > 200 || i+10+(int)hlen > blen) continue;
                    char hbuf[256] = {0};
                    memcpy(hbuf, p+i+10, hlen);
                    NSString *host = [NSString stringWithUTF8String:hbuf];
                    int portOff = i + 10 + (int)hlen;
                    if (portOff + 10 >= blen) continue;
                    if (p[portOff] != 0x04 || memcmp(p+portOff+1, "port", 4) != 0) continue;
                    uint32_t port = p[portOff+6] | (p[portOff+7]<<8) | (p[portOff+8]<<16) | (p[portOff+9]<<24);
                    if (port == 0 || port > 65535) continue;
                    // Find _t discriminator
                    int tOff = -1;
                    for (int j = portOff+10; j < portOff+50 && j+6 < blen; j++) {
                        if (p[j] == 0x02 && p[j+1]=='_' && p[j+2]=='t') { tOff = j; break; }
                    }
                    if (tOff < 0) continue;
                    // Find secret after _t
                    int sOff = -1;
                    for (int j = tOff+7; j < tOff+40 && j+11 < blen; j++) {
                        if (p[j] == 0x06 && memcmp(p+j+1, "secret", 6) == 0) { sOff = j; break; }
                    }
                    NSData *secretData = nil;
                    if (sOff >= 0 && sOff+12 < blen) {
                        uint32_t slen = p[sOff+8] | (p[sOff+9]<<8) | (p[sOff+10]<<16) | (p[sOff+11]<<24);
                        if (slen > 0 && slen <= 64 && sOff+12+(int)slen <= blen) {
                            secretData = [NSData dataWithBytes:p+sOff+12 length:slen];
                        }
                    }
                    NSString *secretHex = @"";
                    if (secretData.length > 0) {
                        const unsigned char *sb = secretData.bytes;
                        NSMutableString *hex = [NSMutableString stringWithCapacity:secretData.length*2];
                        for (NSUInteger k = 0; k < secretData.length; k++) [hex appendFormat:@"%02x", sb[k]];
                        secretHex = hex;
                    }
                    NSString *link = [NSString stringWithFormat:@"tg://proxy?server=%@&port=%u&secret=%@", host, port, secretHex];
                    NSDictionary *d = TGParseProxyLink(link);
                    if (d) [results addObject:d];
                }
            }
        }
        sqlite3_finalize(stmt);
    }
    sqlite3_close(db);
    return results;
}

// No hardcoded proxies — all proxy data comes from Telegram's own postbox DB
// at runtime. Empty fallback = no proxies until user adds them in Telegram.
static NSArray *TGFallbackLinks(void) {
    return @[];
}

#pragma mark - Online proxy list fetcher
// Parses lines of proxy URLs (one per line: https://t.me/proxy?server=...&port=...&secret=...)
static NSArray *TGParseProxyListText(NSString *text) {
    if (!text.length) return @[];
    NSMutableArray *found = [NSMutableArray array];
    NSArray *lines = [text componentsSeparatedByString:@"\n"];
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length < 10) continue;
        NSDictionary *d = TGParseProxyLink(trimmed);
        if (d) [found addObject:d];
    }
    return found;
}

static void TGAddTelemtProxies(NSArray *newProxies) {
    if (!newProxies.count) return;
    @synchronized(gTelemtProxies) { [gTelemtProxies removeAllObjects]; [gTelemtProxies addObjectsFromArray:newProxies]; }
    TGLog(@"online: %lu proxies loaded", (unsigned long)newProxies.count);
}

// On-disk cache of the last successfully fetched external list, so a relaunch
// shows/rotates proxies instantly instead of waiting ~a minute for the first fetch.
static NSString *TGOnlineCachePath(void) {
    NSString *lib = [NSHomeDirectory() stringByAppendingPathComponent:@"Library"];
    return [lib stringByAppendingPathComponent:@"com.ratush.tgproxyrotation.online.txt"];
}
static void TGSaveOnlineCache(NSString *rawText) {
    if (!rawText.length) return;
    [rawText writeToFile:TGOnlineCachePath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
static void TGLoadOnlineCache(void) {
    NSString *text = [NSString stringWithContentsOfFile:TGOnlineCachePath() encoding:NSUTF8StringEncoding error:nil];
    NSArray *proxies = TGParseProxyListText(text);
    if (proxies.count) {
        TGAddTelemtProxies(proxies);
        TGLog(@"online cache: %lu proxies loaded from disk", (unsigned long)proxies.count);
    }
}

// Fetches the proxy list from gProxyListURL on a background queue.
static void TGFetchOnlineProxies(void) {
    if (!gTelemtSearch) return;
    NSString *urlStr = gProxyListURL;
    if (!urlStr.length) return;
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return;
    TGLog(@"online: fetching %@", urlStr);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error || !data) { TGLog(@"online: fetch failed %@", error.localizedDescription); return; }
            NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (!text) text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
            NSArray *proxies = TGParseProxyListText(text);
            if (proxies.count) {
                TGAddTelemtProxies(proxies);
                TGSaveOnlineCache(text);
                TGUpdatePanel();
            }
        }];
    [task resume];
}

static void TGPrefsApply(NSDictionary *p) {
    if (!p) p = TGPrefsLoad();
    gEnabled  = [p[kKeyEnabled] boolValue];
    NSInteger iv = [p[kKeyInterval] integerValue];
    if (iv == 5 || iv == 10 || iv == 15 || iv == 30 || iv == 60) gIntervalSec = iv;
    gShowPanel = p[kKeyShowPanel] ? [p[kKeyShowPanel] boolValue] : YES;
    gProxyOff = [p[kKeyProxyOff] boolValue];
    gTelemtSearch = [p[kKeyTelemt] boolValue];
    if (!gTelemtProxies) gTelemtProxies = [NSMutableArray array];
    NSString *savedURL = p[kKeyProxyURL];
    if (savedURL.length) gProxyListURL = [savedURL copy];
    NSString *lang = p[kKeyLanguage];
    gLanguage = [lang isEqualToString:@"en"] ? @"en" : @"ru";
    gCurrentIndex = [p[kKeyIndex] integerValue];
    if (gCurrentIndex < 0) gCurrentIndex = 0;

    // Always read the live proxy list from Postbox so additions/removals are reflected.
    NSMutableArray *parsed = TGReadProxySettingsFromPostbox();
    if (parsed.count == 0) {
        // Postbox read returned nothing - often transient (DB locked/busy, e.g.
        // right after a prefs save posts a Darwin reload). Keep the list we
        // already have instead of blanking the active proxy (which showed "-").
        NSArray *prev; @synchronized(gProxies) { prev = [gProxies copy]; }
        if (prev.count > 0) {
            parsed = [prev mutableCopy];
        } else {
            NSArray *links = TGFallbackLinks();
            parsed = [NSMutableArray array];
            for (NSString *ln in links) {
                NSDictionary *d = TGParseProxyLink(ln);
                if (d) [parsed addObject:d];
            }
        }
    }
    @synchronized(gProxies) { gProxies = parsed; }
    if (gCurrentIndex >= (NSInteger)parsed.count) gCurrentIndex = 0;
    if (parsed.count > 0) {
        NSDictionary *active = parsed[(NSUInteger)gCurrentIndex];
        NSString *host = active[@"host"];
        if ([host isKindOfClass:[NSString class]] && host.length) {
            @synchronized([NSObject class]) { gActiveProxyHost = [host copy]; }
        }
    } else {
        @synchronized([NSObject class]) { gActiveProxyHost = nil; }
    }

    TGLogSetEnabled(YES);
    TGLog(@"prefs: enabled=%d interval=%lds proxies=%lu index=%lds",
          gEnabled, (long)gIntervalSec, (unsigned long)parsed.count, (long)gCurrentIndex);
}

#pragma mark - Proxy link parsing
static NSData *TGHexToData(NSString *hex) {
    if (!hex) return nil;
    NSMutableData *d = [NSMutableData data];
    const char *s = [hex UTF8String];
    size_t n = strlen(s);
    if (n % 2 != 0) return nil;
    for (size_t i = 0; i+1 < n; i += 2) {
        char b[3] = {s[i], s[i+1], 0};
        char *end = NULL;
        long v = strtol(b, &end, 16);
        if (end != b+2) return nil;
        uint8_t byte = (uint8_t)v;
        [d appendBytes:&byte length:1];
    }
    return d;
}

static NSDictionary *TGParseProxyLink(NSString *link) {
    if (!link) return nil;
    NSURLComponents *c = [NSURLComponents componentsWithString:link];
    if (!c) return nil;
    NSString *host = nil;
    NSNumber *port = @0;
    NSString *secretHex = nil;
    for (NSURLQueryItem *q in c.queryItems) {
        NSString *k = q.name.lowercaseString;
        if ([k isEqualToString:@"server"] || [k isEqualToString:@"host"]) host = q.value;
        else if ([k isEqualToString:@"port"]) port = @([q.value integerValue]);
        else if ([k isEqualToString:@"secret"]) secretHex = q.value;
    }
    if (!host.length || port.integerValue <= 0) return nil;
    NSData *secret = secretHex ? TGHexToData(secretHex) : nil;
    return @{
        @"host": host, @"port": port,
        @"secret": secret ?: [NSNull null], @"link": link,
    };
}

static id TGBuildProxySettings(NSDictionary *p) {
    Class cls = objc_getClass("MTSocksProxySettings");
    if (!cls || !p) return nil;
    id<TGMTSocksProxySettingsBuilder> b = [cls alloc];
    NSString *host = p[@"host"];
    uint16_t port = (uint16_t)[p[@"port"] unsignedShortValue];
    NSData *secret = p[@"secret"] == [NSNull null] ? nil : p[@"secret"];
    return [b initWithIp:host port:port username:nil password:nil secret:secret];
}

// Fully disable the proxy: set socksProxySettings to nil so Telegram connects
// directly. Restoring sets the active proxy back.
static void TGApplyProxyOff(void) {
    id<TGMTContext> ctx = TGContext();
    if (!ctx) return;
    if (gProxyOff) {
        [ctx updateApiEnvironment:^id (id e) {
            return [(id<TGMTApiEnvironment>)e withUpdatedSocksProxySettings:nil];
        }];
        @synchronized([NSObject class]) { gActiveProxyHost = nil; gPendingConfirmationHost = nil; }
        gProxyConfirmed = NO;
        TGLog(@"proxy OFF -> socksProxySettings nil");
    }
    TGUpdatePanel();
}

#pragma mark - Rotation
static id<TGMTContext> TGContext(void) {
    id ctx = gContextWeak;
    return ctx ? (id<TGMTContext>)ctx : nil;
}

static UIWindow *TGShowToast(NSString *text);

static NSString *TGActiveProxyLabelSnapshot(void) {
    NSString *host = nil;
    @synchronized([NSObject class]) { host = [gActiveProxyHost copy]; }
    if (!host.length) return nil;
    NSArray *list; @synchronized(gProxies) { list = [gProxies copy]; }
    for (NSDictionary *p in list) {
        NSString *h = p[@"host"];
        if ([h isKindOfClass:[NSString class]] && [h isEqualToString:host]) {
            NSNumber *port = p[@"port"];
            return port ? [NSString stringWithFormat:@"%@:%@", host, port] : host;
        }
    }
    return host;
}

#pragma mark - TCP reachability probe
// Performs a non-blocking TCP connect with poll() to host:port with a 2s
// timeout on a background queue. Updates gLastPingMs / gLastPingHost, then
// refreshes the panel. Telegram connects to its proxies over TCP (SOCKS5 /
// MTProto), so a successful connect means the endpoint is reachable at the
// TCP level. The authoritative reachability signal still comes from
// Telegram's own reportTransportSchemeSuccess/Failure hooks.
static void TGProbeProxy(NSString *host, uint16_t port);

static void TGProbeProxyInternal(NSString *host, uint16_t port) {
    NSInteger result = -1;
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock >= 0) {
        // Make the socket non-blocking so we can poll with a hard deadline.
        int flags = fcntl(sock, F_GETFL, 0);
        fcntl(sock, F_SETFL, flags | O_NONBLOCK);

        struct addrinfo hints = {0}, *res = NULL;
        hints.ai_family = AF_UNSPEC;       // allow IPv4 and IPv6
        hints.ai_socktype = SOCK_STREAM;
        char portbuf[8];
        snprintf(portbuf, sizeof(portbuf), "%u", port);
        if (getaddrinfo(host.UTF8String, portbuf, &hints, &res) == 0 && res) {
            struct timeval start; gettimeofday(&start, NULL);
            int cr = connect(sock, res->ai_addr, res->ai_addrlen);
            if (cr == 0) {
                struct timeval end; gettimeofday(&end, NULL);
                long ms = (end.tv_sec - start.tv_sec) * 1000 + (end.tv_usec - start.tv_usec) / 1000;
                result = ms < 0 ? 0 : ms;
            } else if (cr < 0 && errno == EINPROGRESS) {
                // Poll for writability up to 2 seconds.
                struct pollfd pfd = { .fd = sock, .events = POLLOUT };
                int pr = poll(&pfd, 1, 2000);
                if (pr > 0 && (pfd.revents & POLLOUT)) {
                    int soerr = 0; socklen_t slen = sizeof(soerr);
                    if (getsockopt(sock, SOL_SOCKET, SO_ERROR, &soerr, &slen) == 0 && soerr == 0) {
                        struct timeval end; gettimeofday(&end, NULL);
                        long ms = (end.tv_sec - start.tv_sec) * 1000 + (end.tv_usec - start.tv_usec) / 1000;
                        result = ms < 0 ? 0 : ms;
                    }
                }
            }
            freeaddrinfo(res);
        }
        close(sock);
    }
    gLastPingMs = result;
    gPingRunning = NO;
    TGUpdatePanel();

    // If another probe was queued while we were busy, run it now.
    NSString *nextHost = nil; uint16_t nextPort = 0;
    @synchronized([NSObject class]) {
        nextHost = [gPendingProbeHost copy];
        nextPort = gPendingProbePort;
        gPendingProbeHost = nil;
        gPendingProbePort = 0;
    }
    if (nextHost.length && nextPort) {
        TGProbeProxy(nextHost, nextPort);
    }
}

static void TGProbeProxy(NSString *host, uint16_t port) {
    if (!host.length || port == 0) return;
    @synchronized([NSObject class]) {
        if (gPingRunning) {
            // Queue this probe; it runs after the current one finishes.
            gPendingProbeHost = [host copy];
            gPendingProbePort = port;
            return;
        }
        gPingRunning = YES;
        gLastPingHost = [host copy];
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        TGProbeProxyInternal(host, port);
    });
}

static void TGRotateBy(NSInteger delta) {
    id<TGMTContext> ctx = TGContext();
    if (!ctx) return;
    // delta == 0 means "re-apply current proxy" (used when re-enabling proxy);
    // any other delta is blocked when proxy is fully off.
    if (gProxyOff && delta != 0) return;
    // Re-read the proxy list so we pick up user changes (added/removed proxies).
    NSMutableArray *fresh = TGReadProxySettingsFromPostbox();
    if (fresh.count >= 1) @synchronized(gProxies) { gProxies = fresh; }

    // When telemtrs search is ON, use the harvested proxy list instead of the
    // user's saved proxies.
    NSArray *list;
    if (gTelemtSearch) {
        @synchronized(gTelemtProxies) { list = [gTelemtProxies copy]; }
    } else {
        @synchronized(gProxies) { list = [gProxies copy]; }
    }
    if (list.count < 1) return;
    NSInteger count = (NSInteger)list.count;
    if (count == 1) {
        gCurrentIndex = 0;
    } else {
        gCurrentIndex = ((gCurrentIndex + delta) % count + count) % count;
    }
    NSDictionary *p = list[gCurrentIndex];
    NSString *host = p[@"host"];
    NSNumber *port = p[@"port"];
    id proxy = TGBuildProxySettings(p);
    if (proxy) {
        [ctx updateApiEnvironment:^id (id e) {
            return [(id<TGMTApiEnvironment>)e withUpdatedSocksProxySettings:proxy];
        }];
        TGLog(@"rotate(%+ld) -> idx=%ld %@:%@", (long)delta, (long)gCurrentIndex, host, port);
    }

    // delta == 0 means "apply saved proxy" (startup tick or re-enable).
    // Set it as active without pending confirmation; the watchdog's normal
    // interval timer will rotate only if it genuinely fails.
    if (delta == 0) {
        @synchronized([NSObject class]) {
            gActiveProxyHost = host;
            gPendingConfirmationHost = nil;
        }
        gProxyConfirmed = YES;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        gLastRotateAbs = now;
        gConsecutiveRotates = 0;
        gCooldownUntil = 0.0;
        // Reset watchdog timer so the next check is one full interval from now.
        if (gEnabled) gLastSuccessAbs = now;
        TGLog(@"apply saved proxy idx=%ld %@:%@", (long)gCurrentIndex, host, port);
        TGProbeProxy(host, (uint16_t)[port unsignedShortValue]);
        TGUpdatePanel();
        return;
    }

    @synchronized([NSObject class]) {
        gActiveProxyHost = host;
        gPendingConfirmationHost = [host copy];
    }
    gProxyConfirmed = NO;  // new proxy, awaiting verification

    // Manual rotation: just switch the proxy. If auto-rotation (the checkbox)
    // is ON, the existing watchdog will verify and auto-skip dead proxies.
    // If the checkbox is OFF, this is a plain manual switch with no checking.
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    gLastRotateAbs = now;
    gConsecutiveRotates = 0;
    gCooldownUntil = 0.0;
    if (gEnabled) gLastSuccessAbs = now;  // reset watchdog timer for auto mode

    NSMutableDictionary *pp = [TGPrefsLoad() mutableCopy] ?: [NSMutableDictionary dictionary];
    pp[kKeyIndex] = @(gCurrentIndex);
    [pp writeToFile:TGPrefsPath() atomically:YES];

    // Show a toast so the user knows rotation happened (no Telegram dialog).
    TGShowToast([NSString stringWithFormat:@" \u21bb %@:%@ ", host, port]);
    TGProbeProxy(host, (uint16_t)[port unsignedShortValue]);
    TGUpdatePanel();
}

static void TGRotateToNext(id<TGMTContext> ctx) {
    // Re-read the proxy list so we pick up user changes (added/removed proxies).
    NSMutableArray *fresh = TGReadProxySettingsFromPostbox();
    if (fresh.count >= 1) @synchronized(gProxies) { gProxies = fresh; }

    // Use harvested telemtrs list when search mode is active.
    NSArray *list;
    if (gTelemtSearch) {
        @synchronized(gTelemtProxies) { list = [gTelemtProxies copy]; }
    } else {
        @synchronized(gProxies) { list = [gProxies copy]; }
    }
    if (list.count < 2 || !ctx) return;

    gCurrentIndex = (gCurrentIndex + 1) % (NSInteger)list.count;
    NSDictionary *p = list[gCurrentIndex];
    NSString *host = p[@"host"];
    NSNumber *port = p[@"port"];
    id proxy = TGBuildProxySettings(p);
    if (proxy) {
        [ctx updateApiEnvironment:^id (id e) {
            return [(id<TGMTApiEnvironment>)e withUpdatedSocksProxySettings:proxy];
        }];
        TGLog(@"rotate -> idx=%ld %@:%@", (long)gCurrentIndex, host, port);
    }

    @synchronized([NSObject class]) {
        gActiveProxyHost = host;
        gPendingConfirmationHost = [host copy];
    }
    gProxyConfirmed = NO;  // new proxy, awaiting verification

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    gLastSuccessAbs = now;
    gLastRotateAbs = now;
    gConsecutiveRotates++;
    if (gConsecutiveRotates >= (int)list.count) {
        gCooldownUntil = now + 60.0;
        gConsecutiveRotates = 0;
        TGLog(@"rotate: full cycle, no success; cooldown 60s");
    }

    NSMutableDictionary *pp = [TGPrefsLoad() mutableCopy] ?: [NSMutableDictionary dictionary];
    pp[kKeyIndex] = @(gCurrentIndex);
    [pp writeToFile:TGPrefsPath() atomically:YES];

    // Show a toast so the user knows rotation happened (no Telegram dialog).
    TGShowToast([NSString stringWithFormat:@" \u21bb %@:%@ ", host, port]);
    TGProbeProxy(host, (uint16_t)[port unsignedShortValue]);
    TGUpdatePanel();
}

#pragma mark - Detection / Watchdog
static void TGOnSchemeSuccess(void) {
    gLastSuccessAbs = CFAbsoluteTimeGetCurrent();
    gConsecutiveRotates = 0;

    NSString *host = nil;
    NSString *pending = nil;
    @synchronized([NSObject class]) {
        host = [gActiveProxyHost copy];
        pending = [gPendingConfirmationHost copy];
    }
    if (!host.length) return;
    if (!pending.length || ![pending isEqualToString:host]) return;
    // Proxy confirmed working — clear pending and mark as confirmed.
    @synchronized([NSObject class]) {
        if ([gPendingConfirmationHost isEqualToString:host]) gPendingConfirmationHost = nil;
    }
    gProxyConfirmed = YES;
    NSString *label = TGActiveProxyLabelSnapshot() ?: host;
    TGLog(@"success -> active proxy confirmed %@", label);
    if (gEnabled) {
        TGShowToast([NSString stringWithFormat:@" \u2713 %@ %@ ", label,
            TGLoc(@"\u0440\u0430\u0431\u043e\u0442\u0430\u0435\u0442", @"works")]);
    }
    TGUpdatePanel();
}

static int gTelemtScanCounter = 0;
static void TGWatchTick(__unused NSTimer *t) {
    if (!gEnabled) return;
    TGUpdatePanel();
    // Periodically scan postbox for telemtrs proxies (every 10 seconds).
    if (gTelemtSearch) {
        gTelemtScanCounter++;
        if (gTelemtScanCounter >= 60) {  // refresh every 60 seconds
            gTelemtScanCounter = 0;
            TGFetchOnlineProxies();
        }
    }
    // Startup phase: the first tick after launch applies the saved last-working
    // proxy instead of rotating forward. This absorbs the "phantom" first tick
    // that fires before Telegram has confirmed traffic through any proxy.
    if (gStartupPending) {
        TGLog(@"startup tick: applying saved proxy idx=%ld", (long)gCurrentIndex);
        gStartupPending = NO;
        TGRotateBy(0);
        return;
    }
    NSArray *list;
    if (gTelemtSearch) {
        @synchronized(gTelemtProxies) { list = [gTelemtProxies copy]; }
    } else {
        @synchronized(gProxies) { list = [gProxies copy]; }
    }
    if (list.count < 2) return;
    id<TGMTContext> ctx = TGContext();
    if (!ctx) return;
    id env = [ctx apiEnvironment];
    id socks = env ? [(id<TGMTApiEnvironment>)env socksProxySettings] : nil;
    if (!socks) return; // no proxy in use
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now < gCooldownUntil) return;
    CFAbsoluteTime since = now - gLastSuccessAbs;
    if (since >= (CFAbsoluteTime)gIntervalSec) {
        TGLog(@"tick: no success for %.0fs (> %lds) -> rotate", since, (long)gIntervalSec);
        TGRotateToNext(ctx);
    }
}

static void TGWatchStart(void) {
    if (gWatchTimer) return;
    gLastSuccessAbs = CFAbsoluteTimeGetCurrent();
    gCooldownUntil = 0.0;
    gConsecutiveRotates = 0;
    gWatchTimer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *tt) { TGWatchTick(tt); }];
    [[NSRunLoop mainRunLoop] addTimer:gWatchTimer forMode:NSRunLoopCommonModes];
    TGLog(@"watch started (interval %lds)", (long)gIntervalSec);
}
static void TGWatchStop(void) {
    [gWatchTimer invalidate]; gWatchTimer = nil;
    TGLog(@"watch stopped");
}

#pragma mark - Darwin reload
static void TGOnDarwinNotify(__unused CFNotificationCenterRef center,
                             __unused void *observer,
                             __unused CFStringRef name,
                             __unused const void *object,
                             __unused CFDictionaryRef userInfo) {
    @autoreleasepool {
        BOOL wasEnabled = gEnabled;
        TGPrefsApply(nil);
        if (gEnabled && !wasEnabled) TGWatchStart();
        else if (!gEnabled && wasEnabled) TGWatchStop();
        else if (gEnabled) TGWatchStart();
        TGUpdatePanel();
    }
}

#pragma mark - Theme helpers
static UIColor *TGAccentColor(void) { return [UIColor colorWithRed:54.0/255 green:143.0/255 blue:237.0/255 alpha:1]; }
// Dark grey matching the tweak's panel background for toast backgrounds.
static UIColor *TGToastColor(void) {
    // Same dark grey as the floating card surface (opaque).
    return [UIColor colorWithRed:28.0/255 green:28.0/255 blue:30.0/255 alpha:1.0];
}
static UIColor *TGLabelColor(void) {
    if (@available(iOS 13.0,*)) return [UIColor labelColor];
    return [UIColor colorWithWhite:0 alpha:0.88];
}
static UIColor *TGSecondaryColor(void) {
    if (@available(iOS 13.0,*)) return [UIColor secondaryLabelColor];
    return [UIColor colorWithWhite:0 alpha:0.5];
}
static UIColor *TGCardColor(void) {
    if (@available(iOS 13.0,*)) return [UIColor secondarySystemGroupedBackgroundColor];
    return [UIColor whiteColor];
}
static UIColor *TGSeparatorColor(void) {
    if (@available(iOS 13.0,*)) return [UIColor separatorColor];
    return [UIColor colorWithWhite:0 alpha:0.12];
}

#pragma mark - Toast
static UIWindow *TGShowToast(NSString *text) {
    __block UIWindow *win = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *kw = TGKeyWindow();
        if (!kw) return;
        UILabel *toast = [[UILabel alloc] init];
        toast.text = text;
        toast.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
        toast.textColor = [UIColor whiteColor];
        toast.backgroundColor = TGToastColor();
        toast.layer.cornerRadius = 12;
        toast.layer.borderWidth = 1.0;
        toast.layer.borderColor = TGAccentColor().CGColor;
        toast.layer.masksToBounds = YES;
        toast.textAlignment = NSTextAlignmentCenter;
        toast.translatesAutoresizingMaskIntoConstraints = NO;
        [kw addSubview:toast];
        CGFloat topInset = kw.safeAreaInsets.top > 0 ? kw.safeAreaInsets.top + 4.0 : 8.0;
        [NSLayoutConstraint activateConstraints:@[
            [toast.topAnchor constraintEqualToAnchor:kw.topAnchor constant:topInset],
            [toast.centerXAnchor constraintEqualToAnchor:kw.centerXAnchor],
            [toast.heightAnchor constraintEqualToConstant:38],
            [toast.widthAnchor constraintGreaterThanOrEqualToConstant:220],
        ]];
        toast.alpha = 0;
        // Tapping the toast opens/restores the tweak panel.
        toast.userInteractionEnabled = YES;
        UITapGestureRecognizer *toastTap = [[UITapGestureRecognizer alloc]
            initWithTarget:gGestureTarget action:@selector(openPanel)];
        [toast addGestureRecognizer:toastTap];
        [UIView animateWithDuration:0.2 animations:^{ toast.alpha = 1; }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.3 animations:^{ toast.alpha = 0; }
                             completion:^(BOOL f){ [toast removeFromSuperview]; }];
        });
    });
    return win;
}

#pragma mark - Pass-through window
static const NSInteger kPanelTag = 0x71507;

@interface TGPassThroughWindow : UIWindow
@end
@implementation TGPassThroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    UIView *v = hit;
    while (v) {
        if (v.tag == kPanelTag) return hit;
        v = v.superview;
    }
    return nil;
}
@end

#pragma mark - Shield icon (vector, CAShapeLayer-based)
typedef NS_ENUM(NSInteger, TGShieldStatus) {
    TGShieldStatusWorking = 0,   // checkmark
    TGShieldStatusChecking = 1,  // question mark
    TGShieldStatusFailed = 2,    // cross
};
@interface TGShieldIconView : UIView
@property (nonatomic, assign) TGShieldStatus status;
@end
@implementation TGShieldIconView {
    CAShapeLayer *_shieldLayer;
    CAShapeLayer *_symbolLayer;
}
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = [UIColor clearColor];
    self.contentMode = UIViewContentModeRedraw;
    _shieldLayer = [CAShapeLayer layer];
    _shieldLayer.fillColor = [UIColor clearColor].CGColor;
    _shieldLayer.strokeColor = [UIColor whiteColor].CGColor;
    _shieldLayer.lineCap = kCALineCapRound;
    _shieldLayer.lineJoin = kCALineJoinRound;
    _symbolLayer = [CAShapeLayer layer];
    _symbolLayer.fillColor = [UIColor clearColor].CGColor;
    _symbolLayer.strokeColor = [UIColor whiteColor].CGColor;
    _symbolLayer.lineCap = kCALineCapRound;
    _symbolLayer.lineJoin = kCALineJoinRound;
    [self.layer addSublayer:_shieldLayer];
    [self.layer addSublayer:_symbolLayer];
    _status = TGShieldStatusFailed;
    return self;
}
- (void)setStatus:(TGShieldStatus)status {
    _status = status;
    [self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat s = MIN(CGRectGetWidth(b), CGRectGetHeight(b));
    CGFloat line = s * 0.075;
    _shieldLayer.frame = b;
    _symbolLayer.frame = b;
    _shieldLayer.lineWidth = line;
    _symbolLayer.lineWidth = line * 1.15;
    CGFloat cx = CGRectGetMidX(b);
    CGFloat top = CGRectGetMinY(b) + s * 0.08;
    CGFloat left = cx - s * 0.38;
    CGFloat right = cx + s * 0.38;
    CGFloat bottom = CGRectGetMinY(b) + s * 0.90;
    // Classic heraldic shield contour (matches reference SVG).
    UIBezierPath *shield = [UIBezierPath bezierPath];
    [shield moveToPoint:CGPointMake(cx, top)];
    [shield addCurveToPoint:CGPointMake(left, top + s * 0.16)
               controlPoint1:CGPointMake(cx - s * 0.14, top + s * 0.09)
               controlPoint2:CGPointMake(cx - s * 0.25, top + s * 0.14)];
    [shield addLineToPoint:CGPointMake(left, top + s * 0.46)];
    [shield addCurveToPoint:CGPointMake(cx, bottom)
               controlPoint1:CGPointMake(left, top + s * 0.65)
               controlPoint2:CGPointMake(cx - s * 0.22, bottom - s * 0.06)];
    [shield addCurveToPoint:CGPointMake(right, top + s * 0.46)
               controlPoint1:CGPointMake(cx + s * 0.22, bottom - s * 0.06)
               controlPoint2:CGPointMake(right, top + s * 0.65)];
    [shield addLineToPoint:CGPointMake(right, top + s * 0.16)];
    [shield addCurveToPoint:CGPointMake(cx, top)
               controlPoint1:CGPointMake(cx + s * 0.25, top + s * 0.14)
               controlPoint2:CGPointMake(cx + s * 0.14, top + s * 0.09)];
    _shieldLayer.path = shield.CGPath;

    if (_status == TGShieldStatusWorking) {
        UIBezierPath *p = [UIBezierPath bezierPath];
        CGFloat pcx = cx, pcy = CGRectGetMidY(b) + s * 0.05;
        [p moveToPoint:CGPointMake(pcx - s * 0.16, pcy)];
        [p addLineToPoint:CGPointMake(pcx - s * 0.04, pcy + s * 0.12)];
        [p addLineToPoint:CGPointMake(pcx + s * 0.18, pcy - s * 0.14)];
        _symbolLayer.path = p.CGPath;
        _symbolLayer.hidden = NO;
    } else if (_status == TGShieldStatusFailed) {
        UIBezierPath *p = [UIBezierPath bezierPath];
        CGFloat pcx = cx, pcy = CGRectGetMidY(b) + s * 0.04;
        CGFloat r = s * 0.15;
        [p moveToPoint:CGPointMake(pcx - r, pcy - r)];
        [p addLineToPoint:CGPointMake(pcx + r, pcy + r)];
        [p moveToPoint:CGPointMake(pcx + r, pcy - r)];
        [p addLineToPoint:CGPointMake(pcx - r, pcy + r)];
        _symbolLayer.path = p.CGPath;
        _symbolLayer.hidden = NO;
    } else {
        // Checking: question mark via text layer fallback is complex; use a
        // small dot + curve approximation with a simple "?" drawn as paths.
        _symbolLayer.path = [self questionPathInBounds:b scale:s].CGPath;
        _symbolLayer.hidden = NO;
    }
}
- (UIBezierPath *)questionPathInBounds:(CGRect)b scale:(CGFloat)s {
    CGFloat pcx = CGRectGetMidX(b);
    CGFloat pcy = CGRectGetMidY(b) + s * 0.04;
    UIBezierPath *p = [UIBezierPath bezierPath];
    // Arc for the hook of "?".
    [p addArcWithCenter:CGPointMake(pcx, pcy - s * 0.05)
                 radius:s * 0.08
             startAngle:M_PI * 1.15
               endAngle:M_PI * 0.15
              clockwise:YES];
    // Stem down to the dot.
    [p moveToPoint:CGPointMake(pcx, pcy + s * 0.01)];
    [p addLineToPoint:CGPointMake(pcx, pcy + s * 0.05)];
    // Dot.
    [p moveToPoint:CGPointMake(pcx, pcy + s * 0.12)];
    [p addArcWithCenter:CGPointMake(pcx, pcy + s * 0.12)
                 radius:s * 0.012
             startAngle:0
               endAngle:M_PI * 2
              clockwise:YES];
    return p;
}
@end

#pragma mark - Checkbox
@interface TGCheckboxView : UIView
@property (nonatomic, assign) BOOL on;
@property (nonatomic, assign) BOOL cross;   // shows ✗ instead of ✓ (proxy off)
@property (nonatomic, strong) UILabel *check;
@end
@implementation TGCheckboxView
- (instancetype)init {
    self = [super initWithFrame:CGRectMake(0,0,24,24)];
    if (self) {
        self.layer.cornerRadius = 7;
        self.layer.borderWidth = 1.6;
        self.layer.masksToBounds = YES;
        _check = [[UILabel alloc] initWithFrame:self.bounds];
        _check.text = @"\u2713";
        _check.textAlignment = NSTextAlignmentCenter;
        _check.textColor = [UIColor whiteColor];
        _check.font = [UIFont boldSystemFontOfSize:16];
        [self addSubview:_check];
        _on = NO; _cross = NO; _check.hidden = YES;
        self.layer.borderColor = TGSecondaryColor().CGColor;
    }
    return self;
}
- (void)setOn:(BOOL)on {
    _on = on;
    [self refreshVisual];
}
- (void)setCross:(BOOL)cross {
    _cross = cross;
    [self refreshVisual];
}
- (void)refreshVisual {
    UIColor *accent = TGAccentColor();
    if (_cross) {
        // Red cross indicating proxy disabled.
        self.backgroundColor = [UIColor colorWithRed:0.85 green:0.2 blue:0.2 alpha:1.0];
        self.layer.borderColor = [UIColor colorWithRed:0.85 green:0.2 blue:0.2 alpha:1.0].CGColor;
        _check.text = @"\u2715";
        _check.textColor = [UIColor whiteColor];
        _check.hidden = NO;
    } else if (_on) {
        self.backgroundColor = accent; self.layer.borderColor = accent.CGColor;
        _check.text = @"\u2713";
        _check.textColor = [UIColor whiteColor];
        _check.hidden = NO;
    } else {
        self.backgroundColor = [UIColor clearColor]; self.layer.borderColor = TGSecondaryColor().CGColor;
        _check.hidden = YES;
    }
}
@end

#pragma mark - Floating control panel
@interface TGPanelController : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, strong) TGPassThroughWindow *window;
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) TGCheckboxView *checkbox;
@property (nonatomic, strong) UIStackView *segmentStack;
@property (nonatomic, strong) NSArray<UIButton *> *segmentButtons;
@property (nonatomic, strong) UILabel *panelTitleLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *languageButton;
@property (nonatomic, strong) UIButton *prevButton;
@property (nonatomic, strong) UIButton *nextButton;
@property (nonatomic, strong) UIButton *minimizeButton;
@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, strong) UILabel *bottomHintLabel;
@property (nonatomic, strong) UILabel *proxyHintLabel;
@property (nonatomic, strong) UIView *telemtRow;
@property (nonatomic, strong) TGCheckboxView *telemtCheckbox;
@property (nonatomic, strong) UILabel *telemtTitle;
@property (nonatomic, strong) UIButton *proxyOffButton;
@property (nonatomic, strong) UILabel *telemtHintLabel;
@property (nonatomic, strong) UIButton *miniShieldButton; // collapsed FAB
@property (nonatomic, strong) TGShieldIconView *miniShieldIcon;
@property (nonatomic, strong) UIView *urlEditorOverlay;    // in-window URL editor
@property (nonatomic, strong) UITextView *urlEditorTextView;
@property (nonatomic, strong) UIView *urlEditorDialog;
@property (nonatomic, weak)   UIWindow *prevKeyWindow;
@property (nonatomic, assign) CGPoint cardOffset;
@property (nonatomic, assign) CGPoint miniOffset;
@property (nonatomic, assign) BOOL miniDragging;
@property (nonatomic, assign) CGPoint miniDragStart;
+ (instancetype)shared;
- (void)show;
- (void)dismiss;
- (void)minimize;
- (void)restore;
- (void)update;
@end

static TGPanelController *gPanel = nil;
static void TGUpdatePanel(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ if (gPanel) [gPanel update]; });
}

@implementation TGPanelController
+ (instancetype)shared {
    static TGPanelController *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [TGPanelController new]; });
    return s;
}
- (NSArray<NSNumber *> *)intervals { return @[@5,@10,@15,@30,@60]; }

- (void)show {
    if (self.window) return;
    self.cardOffset = CGPointZero;
    self.window = [[TGPassThroughWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.windowLevel = UIWindowLevelAlert + 1.0;
    self.window.rootViewController = [UIViewController new];
    self.window.rootViewController.view.backgroundColor = [UIColor clearColor];
    self.window.backgroundColor = [UIColor clearColor];
    self.window.hidden = NO;

    UIView *host = self.window.rootViewController.view;
    CGFloat topInset = 8.0;
    UIWindow *kw = TGKeyWindow();
    if (kw && kw.safeAreaInsets.top > 0) topInset = kw.safeAreaInsets.top + 4.0;

    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = TGCardColor();
    card.layer.cornerRadius = 16;
    card.layer.shadowColor = [UIColor blackColor].CGColor;
    card.layer.shadowOpacity = 0.28;
    card.layer.shadowRadius = 16;
    card.layer.shadowOffset = CGSizeMake(0, 6);
    card.tag = kPanelTag;
    card.layer.borderColor = TGAccentColor().CGColor;
    card.layer.borderWidth = 1.0;
    [host addSubview:card];
    self.card = card;

    UIButton *hide = [UIButton buttonWithType:UIButtonTypeSystem];
    hide.translatesAutoresizingMaskIntoConstraints = NO;
    [hide setTitle:@"\u2715" forState:UIControlStateNormal];
    hide.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [hide setTitleColor:TGSecondaryColor() forState:UIControlStateNormal];
    [hide addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:hide];

    // Minimize button "−" in the top-left corner; collapses to a shield FAB.
    UIButton *minimize = [UIButton buttonWithType:UIButtonTypeSystem];
    minimize.translatesAutoresizingMaskIntoConstraints = NO;
    [minimize setTitle:@"\u2212" forState:UIControlStateNormal];
    minimize.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    [minimize setTitleColor:TGSecondaryColor() forState:UIControlStateNormal];
    [minimize addTarget:self action:@selector(minimize) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:minimize];
    self.minimizeButton = minimize;

    // Small hint between minimize and close: "(long press to disable proxy)".
    UILabel *hint = [[UILabel alloc] init];
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    hint.font = [UIFont systemFontOfSize:9];
    hint.textColor = TGSecondaryColor();
    hint.adjustsFontSizeToFitWidth = YES;
    hint.minimumScaleFactor = 0.7;
    hint.textAlignment = NSTextAlignmentCenter;
    [card addSubview:hint];
    self.hintLabel = hint;

    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    UITapGestureRecognizer *rowTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onToggle:)];
    rowTap.delegate = self;
    [row addGestureRecognizer:rowTap];
    [card addSubview:row];

    TGCheckboxView *cb = [[TGCheckboxView alloc] init];
    cb.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:cb];
    self.checkbox = cb;

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [UIFont systemFontOfSize:16];
    title.textColor = TGLabelColor();
    title.adjustsFontSizeToFitWidth = YES;
    [row addSubview:title];
    self.panelTitleLabel = title;

    // Proxy ON/OFF button in the auto-switch row (right side).
    UIButton *proxyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    proxyBtn.translatesAutoresizingMaskIntoConstraints = NO;
    proxyBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    proxyBtn.layer.cornerRadius = 6;
    proxyBtn.layer.masksToBounds = YES;
    [proxyBtn addTarget:self action:@selector(onProxyOffButton:) forControlEvents:UIControlEventTouchUpInside];
    [row addSubview:proxyBtn];
    self.proxyOffButton = proxyBtn;

    UIView *sep = [[UIView alloc] init];
    sep.translatesAutoresizingMaskIntoConstraints = NO;
    sep.backgroundColor = TGSeparatorColor();
    [card addSubview:sep];

    NSArray *titles = @[@"5\u0441",@"10\u0441",@"15\u0441",@"30\u0441",@"60\u0441"];
    NSMutableArray *btns = [NSMutableArray array];
    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentFill;
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.spacing = 6;
    NSUInteger i = 0;
    for (NSString *t in titles) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.translatesAutoresizingMaskIntoConstraints = NO;
        b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        b.layer.cornerRadius = 10;
        b.layer.masksToBounds = YES;
        b.layer.borderWidth = 1.0;
        b.layer.borderColor = TGAccentColor().CGColor;
        [b setTitle:t forState:UIControlStateNormal];
        [b addTarget:self action:@selector(onSegment:) forControlEvents:UIControlEventTouchUpInside];
        b.tag = (NSInteger)i;
        [stack addArrangedSubview:b];
        [btns addObject:b];
        i++;
    }
    self.segmentButtons = [btns copy];
    [card addSubview:stack];
    self.segmentStack = stack;

    // Second separator below the interval buttons (mirrors the one above).
    UIView *sep2 = [[UIView alloc] init];
    sep2.translatesAutoresizingMaskIntoConstraints = NO;
    sep2.backgroundColor = TGSeparatorColor();
    [card addSubview:sep2];

    UILabel *status = [[UILabel alloc] init];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    status.numberOfLines = 0;
    status.font = [UIFont systemFontOfSize:12];
    status.textAlignment = NSTextAlignmentCenter;
    status.textColor = TGSecondaryColor();
    [card addSubview:status];
    self.statusLabel = status;

    // Long press on status label opens Telegram native proxy dialog.
    status.userInteractionEnabled = YES;
    UILongPressGestureRecognizer *statusLong = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(onProxyLongPress:)];
    statusLong.minimumPressDuration = 0.5;
    [status addGestureRecognizer:statusLong];

    // Proxy hint above the arrows/status: "(long tap on proxy address — add to TG)".
    UILabel *proxyHint = [[UILabel alloc] init];
    proxyHint.translatesAutoresizingMaskIntoConstraints = NO;
    proxyHint.font = [UIFont systemFontOfSize:9];
    proxyHint.textColor = TGSecondaryColor();
    proxyHint.adjustsFontSizeToFitWidth = YES;
    proxyHint.minimumScaleFactor = 0.7;
    proxyHint.textAlignment = NSTextAlignmentCenter;
    [card addSubview:proxyHint];
    self.proxyHintLabel = proxyHint;

    // Bottom hint: "(long press on arrows to random switch)".
    UILabel *bottomHint = [[UILabel alloc] init];
    bottomHint.translatesAutoresizingMaskIntoConstraints = NO;
    bottomHint.font = [UIFont systemFontOfSize:9];
    bottomHint.textColor = TGSecondaryColor();
    bottomHint.adjustsFontSizeToFitWidth = YES;
    bottomHint.minimumScaleFactor = 0.7;
    bottomHint.textAlignment = NSTextAlignmentCenter;
    [card addSubview:bottomHint];
    self.bottomHintLabel = bottomHint;

    // Telemtrs search section: separator + checkbox row.
    UIView *telemtSep = [[UIView alloc] init];
    telemtSep.translatesAutoresizingMaskIntoConstraints = NO;
    telemtSep.backgroundColor = TGSeparatorColor();
    [card addSubview:telemtSep];

    UIView *telemtRow = [[UIView alloc] init];
    telemtRow.translatesAutoresizingMaskIntoConstraints = NO;
    UITapGestureRecognizer *telemtTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(onToggleTelemt:)];
    telemtTap.delegate = self;
    [telemtRow addGestureRecognizer:telemtTap];
    // Long press on the row to edit the proxy list URL.
    UILongPressGestureRecognizer *telemtLong = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(onEditProxyURL:)];
    telemtLong.minimumPressDuration = 0.5;
    telemtLong.delegate = self;
    [telemtRow addGestureRecognizer:telemtLong];
    [card addSubview:telemtRow];

    TGCheckboxView *telemtCb = [[TGCheckboxView alloc] init];
    telemtCb.translatesAutoresizingMaskIntoConstraints = NO;
    [telemtRow addSubview:telemtCb];
    self.telemtCheckbox = telemtCb;

    UILabel *telemtTitle = [[UILabel alloc] init];
    telemtTitle.translatesAutoresizingMaskIntoConstraints = NO;
    telemtTitle.font = [UIFont systemFontOfSize:14];
    telemtTitle.textColor = TGLabelColor();
    telemtTitle.adjustsFontSizeToFitWidth = YES;
    [telemtRow addSubview:telemtTitle];
    self.telemtTitle = telemtTitle;

    // Language button RU/EN in the telemtrs row (right side).
    UIButton *lang = [UIButton buttonWithType:UIButtonTypeSystem];
    lang.translatesAutoresizingMaskIntoConstraints = NO;
    lang.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    lang.layer.cornerRadius = 8;
    lang.layer.masksToBounds = YES;
    [lang addTarget:self action:@selector(onLanguage:) forControlEvents:UIControlEventTouchUpInside];
    [telemtRow addSubview:lang];
    self.languageButton = lang;

    // Hint for long press on telemt checkbox (change URL).
    UILabel *telemtHint = [[UILabel alloc] init];
    telemtHint.translatesAutoresizingMaskIntoConstraints = NO;
    telemtHint.font = [UIFont systemFontOfSize:9];
    telemtHint.textColor = TGSecondaryColor();
    telemtHint.numberOfLines = 2;
    telemtHint.lineBreakMode = NSLineBreakByWordWrapping;
    telemtHint.textAlignment = NSTextAlignmentCenter;
    [telemtHint setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                forAxis:UILayoutConstraintAxisVertical];
    [card addSubview:telemtHint];
    self.telemtHintLabel = telemtHint;

    // Manual prev/next buttons: bottom corners of the card, blue squares.
    UIButton *prev = [UIButton buttonWithType:UIButtonTypeSystem];
    prev.translatesAutoresizingMaskIntoConstraints = NO;
    prev.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    [prev setTitle:@"\u2190" forState:UIControlStateNormal]; // ←
    [prev setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    prev.backgroundColor = TGAccentColor();
    prev.layer.cornerRadius = 8;
    prev.layer.masksToBounds = YES;
    [prev addTarget:self action:@selector(onPrevProxy:) forControlEvents:UIControlEventTouchUpInside];
    UILongPressGestureRecognizer *prevLong = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(onRandomProxy:)];
    prevLong.minimumPressDuration = 0.5;
    [prev addGestureRecognizer:prevLong];
    [card addSubview:prev];
    self.prevButton = prev;

    UIButton *next = [UIButton buttonWithType:UIButtonTypeSystem];
    next.translatesAutoresizingMaskIntoConstraints = NO;
    next.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    [next setTitle:@"\u2192" forState:UIControlStateNormal]; // →
    [next setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    next.backgroundColor = TGAccentColor();
    next.layer.cornerRadius = 8;
    next.layer.masksToBounds = YES;
    [next addTarget:self action:@selector(onNextProxy:) forControlEvents:UIControlEventTouchUpInside];
    UILongPressGestureRecognizer *nextLong = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(onRandomProxy:)];
    nextLong.minimumPressDuration = 0.5;
    [next addGestureRecognizer:nextLong];
    [card addSubview:next];
    self.nextButton = next;

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPanCard:)];
    pan.delegate = self;
    [card addGestureRecognizer:pan];

    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:host.topAnchor constant:topInset],
        [card.centerXAnchor constraintEqualToAnchor:host.centerXAnchor],
        [card.widthAnchor constraintEqualToConstant:320],
        [hide.topAnchor constraintEqualToAnchor:card.topAnchor constant:6],
        [hide.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10],
        [hide.widthAnchor constraintEqualToConstant:26], [hide.heightAnchor constraintEqualToConstant:26],
        // Minimize button "−": top-left, mirroring the close button.
        [minimize.centerYAnchor constraintEqualToAnchor:hide.centerYAnchor],
        [minimize.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10],
        [minimize.widthAnchor constraintEqualToConstant:26], [minimize.heightAnchor constraintEqualToConstant:26],
        // Hint label centered between minimize and close buttons.
        [hint.centerYAnchor constraintEqualToAnchor:hide.centerYAnchor],
        [hint.leadingAnchor constraintEqualToAnchor:minimize.trailingAnchor constant:4],
        [hint.trailingAnchor constraintEqualToAnchor:hide.leadingAnchor constant:-4],
        // Checkbox row sits below the close button so it never overlaps ✕.
        [row.topAnchor constraintEqualToAnchor:hide.bottomAnchor constant:10],
        [row.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [row.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [row.heightAnchor constraintEqualToConstant:30],
        [cb.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [cb.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [cb.widthAnchor constraintEqualToConstant:24], [cb.heightAnchor constraintEqualToConstant:24],
        [title.leadingAnchor constraintEqualToAnchor:cb.trailingAnchor constant:12],
        [title.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:proxyBtn.leadingAnchor constant:-8],
        // Proxy ON/OFF button at end of auto-switch row.
        [proxyBtn.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [proxyBtn.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [proxyBtn.widthAnchor constraintEqualToConstant:48], [proxyBtn.heightAnchor constraintEqualToConstant:28],
        [sep.topAnchor constraintEqualToAnchor:row.bottomAnchor constant:14],
        [sep.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [sep.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [sep.heightAnchor constraintEqualToConstant:0.5],
        [stack.topAnchor constraintEqualToAnchor:sep.bottomAnchor constant:14],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [stack.heightAnchor constraintEqualToConstant:40],
        [sep2.topAnchor constraintEqualToAnchor:stack.bottomAnchor constant:14],
        [sep2.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [sep2.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [sep2.heightAnchor constraintEqualToConstant:0.5],
        [proxyHint.topAnchor constraintEqualToAnchor:sep2.bottomAnchor constant:8],
        [proxyHint.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [proxyHint.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [status.topAnchor constraintEqualToAnchor:proxyHint.bottomAnchor constant:4],
        [status.leadingAnchor constraintEqualToAnchor:prev.trailingAnchor constant:10],
        [status.trailingAnchor constraintEqualToAnchor:next.leadingAnchor constant:-10],
        // Manual prev/next buttons aligned vertically with the status text,
        // and horizontally with the interval buttons row above (18pt inset).
        [prev.centerYAnchor constraintEqualToAnchor:status.centerYAnchor],
        [prev.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [prev.widthAnchor constraintEqualToConstant:40], [prev.heightAnchor constraintEqualToConstant:36],
        [next.centerYAnchor constraintEqualToAnchor:status.centerYAnchor],
        [next.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [next.widthAnchor constraintEqualToConstant:40], [next.heightAnchor constraintEqualToConstant:36],
        // Bottom hint below the status/arrows row.
        [bottomHint.topAnchor constraintEqualToAnchor:status.bottomAnchor constant:6],
        [bottomHint.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [bottomHint.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        // Telemtrs separator and checkbox row.
        [telemtSep.topAnchor constraintEqualToAnchor:bottomHint.bottomAnchor constant:8],
        [telemtSep.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [telemtSep.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [telemtSep.heightAnchor constraintEqualToConstant:0.5],
        [telemtRow.topAnchor constraintEqualToAnchor:telemtSep.bottomAnchor constant:8],
        [telemtRow.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [telemtRow.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [telemtRow.heightAnchor constraintEqualToConstant:30],
        [telemtCb.leadingAnchor constraintEqualToAnchor:telemtRow.leadingAnchor],
        [telemtCb.centerYAnchor constraintEqualToAnchor:telemtRow.centerYAnchor],
        [telemtCb.widthAnchor constraintEqualToConstant:24], [telemtCb.heightAnchor constraintEqualToConstant:24],
        [telemtTitle.leadingAnchor constraintEqualToAnchor:telemtCb.trailingAnchor constant:12],
        [telemtTitle.centerYAnchor constraintEqualToAnchor:telemtRow.centerYAnchor],
        [telemtTitle.trailingAnchor constraintLessThanOrEqualToAnchor:proxyBtn.leadingAnchor constant:-8],
        // Proxy OFF/ON button at the end of the telemtrs row.
        [lang.centerYAnchor constraintEqualToAnchor:telemtRow.centerYAnchor],
        [lang.trailingAnchor constraintEqualToAnchor:telemtRow.trailingAnchor],
        [lang.widthAnchor constraintEqualToConstant:48], [lang.heightAnchor constraintEqualToConstant:28],
        // Telemt hint label below the telemt row — this is the bottom anchor.
        [telemtHint.topAnchor constraintEqualToAnchor:telemtRow.bottomAnchor constant:6],
        [telemtHint.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10],
        [telemtHint.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10],
        [telemtHint.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
    ]];

    [self update];
    card.alpha = 0;
    [UIView animateWithDuration:0.18 animations:^{ card.alpha = 1; }];
}

- (void)dismiss {
    if (!self.window) return;
    [UIView animateWithDuration:0.15 animations:^{ self.card.alpha = 0; }
                     completion:^(BOOL f) {
        self.card = nil; self.checkbox = nil; self.segmentStack = nil;
        self.segmentButtons = nil; self.panelTitleLabel = nil; self.statusLabel = nil; self.languageButton = nil;
        self.prevButton = nil; self.nextButton = nil; self.minimizeButton = nil;
        self.hintLabel = nil; self.bottomHintLabel = nil; self.proxyHintLabel = nil;
        self.telemtRow = nil; self.telemtCheckbox = nil; self.telemtTitle = nil;
        self.proxyOffButton = nil; self.telemtHintLabel = nil;
        self.cardOffset = CGPointZero; self.window.hidden = YES; self.window = nil;
    }];
}

- (void)minimize {
    if (!self.card) return;
    UIView *host = self.window.rootViewController.view;
    [host layoutIfNeeded];
    // Default FAB position: nav bar area, between back button and chat title,
    // slightly below the status bar and left of center per user request.
    UIWindow *kw = TGKeyWindow();
    CGFloat safeTop = (kw && kw.safeAreaInsets.top > 0) ? kw.safeAreaInsets.top : 44.0;
    CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
    CGFloat fabX = screenWidth * 0.25;
    CGFloat fabY = safeTop + 27.0;
    CGPoint fabCenter = CGPointMake(fabX, fabY);

    // Build the collapsed floating shield button (square FAB).
    // translatesAutoresizingMaskIntoConstraints = YES so AutoLayout never resets
    // the frame; we own the position entirely via frame/center.
    UIButton *fab = [UIButton buttonWithType:UIButtonTypeSystem];
    fab.translatesAutoresizingMaskIntoConstraints = YES;
    fab.frame = CGRectMake(fabCenter.x - 20, fabCenter.y - 20, 40, 40);
    fab.backgroundColor = TGAccentColor();
    fab.layer.cornerRadius = 10;
    fab.layer.borderColor = TGAccentColor().CGColor;
    fab.layer.borderWidth = 1.0;
    fab.layer.shadowColor = [UIColor blackColor].CGColor;
    fab.layer.shadowOpacity = 0.3;
    fab.layer.shadowRadius = 8;
    fab.layer.shadowOffset = CGSizeMake(0, 3);
    fab.tag = kPanelTag;
    // Long press → start dragging; short tap → restore.
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(onLongPressMini:)];
    lp.minimumPressDuration = 0.35;
    lp.delegate = self;
    [fab addGestureRecognizer:lp];
    // Touch up (short tap) restores the full panel.
    [fab addTarget:self action:@selector(restore) forControlEvents:UIControlEventTouchUpInside];
    [host addSubview:fab];
    self.miniShieldButton = fab;
    // Vector shield icon as subview (no bitmap).
    TGShieldIconView *icon = [[TGShieldIconView alloc] initWithFrame:fab.bounds];
    icon.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    icon.userInteractionEnabled = NO;
    [fab addSubview:icon];
    self.miniShieldIcon = icon;
    self.miniOffset = CGPointZero;
    self.miniDragging = NO;
    // Set the shield status glyph from current proxy state.
    [self updateMiniIcon];
    fab.alpha = 0;
    fab.transform = CGAffineTransformMakeScale(0.5, 0.5);
    // Hide the full card; the window stays so the FAB remains interactive.
    [UIView animateWithDuration:0.2 animations:^{
        self.card.alpha = 0;
        fab.alpha = 1;
        fab.transform = CGAffineTransformIdentity;
    } completion:^(BOOL f){
        self.card.hidden = YES;
    }];
}

- (void)restore {
    if (!self.miniShieldButton) { [self show]; return; }
    // Ignore restore if this touch-up ended a drag.
    if (self.miniDragging) { self.miniDragging = NO; return; }
    UIButton *fab = self.miniShieldButton;
    [UIView animateWithDuration:0.2 animations:^{
        fab.alpha = 0;
        fab.transform = CGAffineTransformMakeScale(0.5, 0.5);
        self.card.hidden = NO;
        self.card.alpha = 1;
    } completion:^(BOOL f){
        [fab removeFromSuperview];
        self.miniShieldButton = nil;
        self.miniShieldIcon = nil;
    }];
}

- (void)onLongPressMini:(UILongPressGestureRecognizer *)g {
    UIView *host = self.window.rootViewController.view;
    if (g.state == UIGestureRecognizerStateBegan) {
        self.miniDragging = YES;
        self.miniDragStart = [g locationInView:host];
        self.miniShieldButton.transform = CGAffineTransformMakeScale(1.1, 1.1);
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint loc = [g locationInView:host];
        CGPoint delta = CGPointMake(loc.x - self.miniDragStart.x, loc.y - self.miniDragStart.y);
        CGPoint c = self.miniShieldButton.center;
        self.miniShieldButton.center = CGPointMake(c.x + delta.x, c.y + delta.y);
        self.miniDragStart = loc;
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        self.miniShieldButton.transform = CGAffineTransformIdentity;
        // Drag ended — mark dragging so the following touch-up does NOT restore.
        // The user must do a separate short tap to restore.
    }
}

- (void)updateMiniIcon {
    if (!self.miniShieldButton || !self.miniShieldIcon) return;

    BOOL hasActive = TGActiveProxyHostSnapshot().length > 0;
    TGShieldStatus status;
    if (gProxyOff) {
        status = TGShieldStatusFailed;          // proxy disabled
    } else if (!hasActive) {
        status = TGShieldStatusFailed;          // no active proxy
    } else if (gProxyConfirmed) {
        status = TGShieldStatusWorking;         // active proxy verified working
    } else {
        status = TGShieldStatusFailed;          // not yet confirmed = cross
    }

    self.miniShieldIcon.status = status;
}

- (void)update {
    self.checkbox.on = gEnabled;
    UIColor *accent = TGAccentColor();
    UIColor *secondary = TGSecondaryColor();
    // Top hint removed (proxy toggle now has a dedicated ON/OFF button).
    self.hintLabel.text = @"";
    self.proxyHintLabel.text = TGLoc(@"(\u0434\u043e\u043b\u0433\u0438\u0439 \u0442\u0430\u043f \u043d\u0430 \u0430\u0434\u0440\u0435\u0441\u0435 \u043f\u0440\u043e\u043a\u0441\u0438 \u2014 \u0434\u043e\u0431\u0430\u0432\u0438\u0442\u044c \u0432 TG)",
                                      @"(long tap on proxy address \u2014 add to TG)");
    self.bottomHintLabel.text = TGLoc(@"(\u0434\u043e\u043b\u0433\u0438\u0439 \u0442\u0430\u043f \u043f\u043e \u0441\u0442\u0440\u0435\u043b\u043a\u0430\u043c \u2014 \u0441\u043b\u0443\u0447\u0430\u0439\u043d\u044b\u0439 \u0432\u044b\u0431\u043e\u0440)",
                                      @"(long press on arrows to random switch)");
    // Telemtrs search checkbox state.
    self.telemtCheckbox.on = gTelemtSearch;
    self.telemtCheckbox.cross = NO;
    NSInteger telemtCount = 0; @synchronized(gTelemtProxies) { telemtCount = (NSInteger)gTelemtProxies.count; }
    self.telemtTitle.text = [NSString stringWithFormat:@"%@%@",
        TGLoc(@"\u0412\u043d\u0435\u0448\u043d\u0438\u0439 \u0441\u043f\u0438\u0441\u043e\u043a \u043f\u0440\u043e\u043a\u0441\u0438", @"External proxy list"),
        telemtCount > 0 ? [NSString stringWithFormat:@" (%ld)", (long)telemtCount] : @""];
    self.telemtHintLabel.text = TGLoc(@"(\u0434\u043e\u043b\u0433\u0438\u0439 \u0442\u0430\u043f \u043f\u043e \u0433\u0430\u043b\u043e\u0447\u043a\u0435 \u2014 \u0438\u0437\u043c\u0435\u043d\u0438\u0442\u044c URL)",
                                      @"(long press on checkbox to change URL)");
    // Proxy OFF/ON button: shows "OFF" when proxy is on, "ON" when off.
    if (gProxyOff) {
        [self.proxyOffButton setTitle:@"ON" forState:UIControlStateNormal];
        [self.proxyOffButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        self.proxyOffButton.backgroundColor = TGAccentColor();
    } else {
        [self.proxyOffButton setTitle:@"OFF" forState:UIControlStateNormal];
        [self.proxyOffButton setTitleColor:TGSecondaryColor() forState:UIControlStateNormal];
        self.proxyOffButton.backgroundColor = [UIColor clearColor];
        self.proxyOffButton.layer.borderWidth = 1.0;
        self.proxyOffButton.layer.borderColor = TGSecondaryColor().CGColor;
    }
    // When proxy is fully off, checkbox shows a cross and title changes.
    if (gProxyOff) {
        self.checkbox.on = NO;
        self.checkbox.cross = YES;
        self.panelTitleLabel.text = TGLoc(@"\u041f\u0440\u043e\u043a\u0441\u0438 \u043e\u0442\u043a\u043b\u044e\u0447\u0451\u043d", @"Proxy turned off");
    } else {
        self.checkbox.on = gEnabled;
        self.checkbox.cross = NO;
        self.panelTitleLabel.text = TGLoc(@"\u0410\u0432\u0442\u043e\u043f\u0435\u0440\u0435\u043a\u043b\u044e\u0447\u0435\u043d\u0438\u0435 \u043f\u0440\u043e\u043a\u0441\u0438", @"Auto-switch proxy");
    }
    [self.languageButton setTitle:(TGLangRU() ? @"RU" : @"EN") forState:UIControlStateNormal];
    [self.languageButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.languageButton.backgroundColor = accent;
    NSArray *ints = self.intervals;
    for (NSUInteger i = 0; i < self.segmentButtons.count; i++) {
        UIButton *b = self.segmentButtons[i];
        BOOL sel = ([ints[i] integerValue] == gIntervalSec);
        if (sel) { b.backgroundColor = accent; [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal]; b.titleLabel.font = [UIFont boldSystemFontOfSize:15]; }
        else { b.backgroundColor = [UIColor clearColor]; [b setTitleColor:secondary forState:UIControlStateNormal]; b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium]; }
    }
    NSString *status;
    NSArray *list;
    if (gTelemtSearch) {
        @synchronized(gTelemtProxies) { list = [gTelemtProxies copy]; }
    } else {
        @synchronized(gProxies) { list = [gProxies copy]; }
    }
    NSInteger total = (NSInteger)list.count;
    // Clamp a stale index (list shrank, or we just switched between the local
    // and external lists) so a valid proxy shows instead of a "-" placeholder.
    if (total > 0 && (gCurrentIndex < 0 || gCurrentIndex >= total)) gCurrentIndex = 0;
    NSString *host = (total > 0) ? list[gCurrentIndex][@"host"] : @"-";
    NSNumber *portNum = (total > 0) ? list[gCurrentIndex][@"port"] : nil;
    NSString *endpoint = portNum ? [NSString stringWithFormat:@"%@:%@", host, portNum] : host;
    // Ping line: "12ms" if TCP probe succeeded, "works" if Telegram's own
    // transport reports recent success (authoritative), "unreachable" otherwise.
    // Telegram's transport signals override a failed TCP probe — an MTProto
    // proxy may accept the SOCKS handshake but not a raw TCP connect.
    NSString *pingStr;
    NSInteger ping = gLastPingMs;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL tgRecentSuccess = (gTransportSuccessAbs > 0 && (now - gTransportSuccessAbs) < 30.0);
    if (ping >= 0) {
        pingStr = [NSString stringWithFormat:@"%ldms", (long)ping];
    } else if (tgRecentSuccess) {
        pingStr = TGLoc(@"\u0440\u0430\u0431\u043e\u0442\u0430\u0435\u0442", @"works");
    } else {
        pingStr = TGLoc(@"\u043d\u0435\u0434\u043e\u0441\u0442\u0443\u043f\u0435\u043d", @"unreachable");
    }
    // Trigger a fresh probe if the active host changed and none is running.
    NSString *probeHost = host;
    uint16_t probePort = (uint16_t)[portNum unsignedShortValue];
    NSString *curPingHost = nil; @synchronized([NSObject class]) { curPingHost = [gLastPingHost copy]; }
    if (probeHost.length && probePort && ![curPingHost isEqualToString:probeHost]) {
        gLastPingMs = -1;  // reset stale ping from previous host
        TGProbeProxy(probeHost, probePort);
    }
    if (gProxyOff) {
        // Proxy fully disabled — show direct connection status.
        if (TGLangRU()) {
            status = [NSString stringWithFormat:@"%@\n%@", endpoint,
                TGLoc(@"\u043f\u0440\u044f\u043c\u043e\u0435 \u0441\u043e\u0435\u0434\u0438\u043d\u0435\u043d\u0438\u0435", @"direct connection")];
        } else {
            status = [NSString stringWithFormat:@"%@\n%@", endpoint, @"direct connection"];
        }
    } else if (gEnabled) {
        CFAbsoluteTime base = gLastSuccessAbs > 0 ? gLastSuccessAbs : CFAbsoluteTimeGetCurrent();
        NSInteger since = (NSInteger)(CFAbsoluteTimeGetCurrent() - base);
        if (since < 0) since = 0;
        NSInteger remain = gIntervalSec - since;
        if (remain < 0) remain = 0;
        if (TGLangRU()) {
            status = [NSString stringWithFormat:@"%@\n%ld/%ld \u00b7 %@ \u00b7 \u0434\u043e \u043f\u0435\u0440\u0435\u043a\u043b\u044e\u0447\u0435\u043d\u0438\u044f %lds",
                endpoint, (long)(gCurrentIndex+1), (long)total, pingStr, (long)remain];
        } else {
            status = [NSString stringWithFormat:@"%@\n%ld/%ld \u00b7 %@ \u00b7 next switch in %lds",
                endpoint, (long)(gCurrentIndex+1), (long)total, pingStr, (long)remain];
        }
    } else {
        if (TGLangRU()) {
            status = [NSString stringWithFormat:@"%@\n%@", endpoint, pingStr];
        } else {
            status = [NSString stringWithFormat:@"%@\n%@", endpoint, pingStr];
        }
    }
    // Build attributed string: first line (endpoint) bold + larger,
    // remaining lines small + regular weight.
    NSMutableAttributedString *attrStatus = [[NSMutableAttributedString alloc]
        initWithString:status];
    NSRange firstLineRange = [status rangeOfString:@"\n"];
    NSRange endRange = firstLineRange.location == NSNotFound
        ? NSMakeRange(0, status.length) : firstLineRange;
    [attrStatus addAttribute:NSFontAttributeName
                       value:[UIFont boldSystemFontOfSize:15]
                       range:NSMakeRange(0, endRange.location)];
    [attrStatus addAttribute:NSForegroundColorAttributeName
                       value:TGLabelColor()
                       range:NSMakeRange(0, endRange.location)];
    if (firstLineRange.location != NSNotFound) {
        NSRange restRange = NSMakeRange(firstLineRange.location + 1,
                                        status.length - firstLineRange.location - 1);
        [attrStatus addAttribute:NSFontAttributeName
                           value:[UIFont systemFontOfSize:12]
                           range:restRange];
        [attrStatus addAttribute:NSForegroundColorAttributeName
                           value:TGSecondaryColor()
                           range:restRange];
    }
    self.statusLabel.attributedText = attrStatus;
    // Refresh the minimized FAB icon so it reflects live proxy status.
    [self updateMiniIcon];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b { return YES; }
- (void)onPanCard:(UIPanGestureRecognizer *)p {
    CGPoint tr = [p translationInView:self.card.superview];
    self.cardOffset = CGPointMake(self.cardOffset.x + tr.x, self.cardOffset.y + tr.y);
    [p setTranslation:CGPointZero inView:self.card.superview];
    self.card.transform = CGAffineTransformMakeTranslation(self.cardOffset.x, self.cardOffset.y);
}
- (void)onToggle:(__unused id)s {
    gEnabled = !gEnabled;
    NSMutableDictionary *p = [TGPrefsLoad() mutableCopy] ?: [NSMutableDictionary dictionary];
    p[kKeyEnabled] = @(gEnabled);
    TGPrefsSave(p);
    TGLog(@"UI toggle -> %d", gEnabled);
    [self update];
}
// Long press on the checkbox row fully disables/enables the proxy.
- (void)onToggleProxyOff:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    gProxyOff = !gProxyOff;
    NSMutableDictionary *p = [TGPrefsLoad() mutableCopy] ?: [NSMutableDictionary dictionary];
    p[kKeyProxyOff] = @(gProxyOff);
    TGPrefsSave(p);
    TGLog(@"UI proxy-off toggle -> %d", gProxyOff);
    if (gProxyOff) {
        TGWatchStop();
        TGApplyProxyOff();
    } else {
        // Restore the active proxy by rotating to current index.
        TGRotateBy(0);
        if (gEnabled) TGWatchStart();
    }
    [self update];
}
// Proxy OFF/ON button in the telemtrs row.
- (void)onProxyOffButton:(__unused UIButton *)b {
    gProxyOff = !gProxyOff;
    NSMutableDictionary *p = [TGPrefsLoad() mutableCopy] ?: [NSMutableDictionary dictionary];
    p[kKeyProxyOff] = @(gProxyOff);
    TGPrefsSave(p);
    TGLog(@"UI proxy-off button -> %d", gProxyOff);
    if (gProxyOff) {
        TGWatchStop();
        TGApplyProxyOff();
    } else {
        TGRotateBy(0);
        if (gEnabled) TGWatchStart();
    }
    [self update];
}

// Toggle telemtrs proxy search mode.
- (void)onToggleTelemt:(__unused id)s {
    gTelemtSearch = !gTelemtSearch;
    NSMutableDictionary *p = [TGPrefsLoad() mutableCopy] ?: [NSMutableDictionary dictionary];
    p[kKeyTelemt] = @(gTelemtSearch);
    TGPrefsSave(p);
    TGLog(@"UI telemt search -> %d", gTelemtSearch);
    // Switching lists: reset the index so it never points past the other list.
    gCurrentIndex = 0;
    if (gTelemtSearch) {
        // Show the cached list instantly, then refresh it online.
        TGLoadOnlineCache();
        TGFetchOnlineProxies();
    }
    // Re-apply a proxy from the now-active list right away (fixes the local
    // list going to "-" when the external list is toggled off).
    TGRotateBy(0);
    TGUpdatePanel();
}
// Long press on the telemt checkbox row to edit the proxy list URL.
- (void)onEditProxyURL:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    dispatch_async(dispatch_get_main_queue(), ^{ [self showURLEditor]; });
}

// Build the proxy-list-URL editor as a self-contained overlay INSIDE our
// pass-through window. UIAlertController does not work here: our window sits at
// UIWindowLevelAlert+1, so any alert presented on Telegram's window ends up
// below us and its touches fall through to Telegram. By tagging the backdrop
// with kPanelTag, TGPassThroughWindow.hitTest routes touches to the editor, and
// a UITextView gives real multi-line wrapping for long URLs.
- (void)showURLEditor {
    if (self.urlEditorOverlay) return;                 // already open
    UIView *host = self.window.rootViewController.view;
    if (!host) return;

    UIView *backdrop = [[UIView alloc] initWithFrame:host.bounds];
    backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    backdrop.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    backdrop.tag = kPanelTag;                          // route touches to us
    backdrop.alpha = 0;
    UITapGestureRecognizer *bgTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(onURLEditorBackdrop:)];
    [backdrop addGestureRecognizer:bgTap];
    [host addSubview:backdrop];
    self.urlEditorOverlay = backdrop;

    UIView *dlg = [[UIView alloc] init];
    dlg.translatesAutoresizingMaskIntoConstraints = NO;
    dlg.backgroundColor = TGCardColor();
    dlg.layer.cornerRadius = 16;
    dlg.layer.borderColor = TGAccentColor().CGColor;
    dlg.layer.borderWidth = 1.0;
    dlg.tag = kPanelTag;
    [backdrop addSubview:dlg];
    self.urlEditorDialog = dlg;

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [UIFont boldSystemFontOfSize:16];
    title.textColor = TGLabelColor();
    title.textAlignment = NSTextAlignmentCenter;
    title.text = TGLoc(@"URL \u0441\u043f\u0438\u0441\u043a\u0430 \u043f\u0440\u043e\u043a\u0441\u0438", @"Proxy list URL");
    [dlg addSubview:title];

    UILabel *msg = [[UILabel alloc] init];
    msg.translatesAutoresizingMaskIntoConstraints = NO;
    msg.font = [UIFont systemFontOfSize:12];
    msg.textColor = TGSecondaryColor();
    msg.numberOfLines = 0;
    msg.textAlignment = NSTextAlignmentCenter;
    msg.text = TGLoc(@"\u0422\u0435\u043a\u0441\u0442\u043e\u0432\u044b\u0439 \u0444\u0430\u0439\u043b: \u043f\u043e 1 \u043f\u0440\u043e\u043a\u0441\u0438 \u043d\u0430 \u0441\u0442\u0440\u043e\u043a\u0443 (tg://proxy \u0438\u043b\u0438 https://t.me/proxy)",
                     @"Text file: 1 proxy per line (tg://proxy or https://t.me/proxy)");
    [dlg addSubview:msg];

    UITextView *tv = [[UITextView alloc] init];
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    tv.font = [UIFont systemFontOfSize:13];
    tv.textColor = TGLabelColor();
    tv.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.14];
    tv.layer.cornerRadius = 10;
    tv.layer.borderColor = TGSeparatorColor().CGColor;
    tv.layer.borderWidth = 1.0;
    tv.textContainerInset = UIEdgeInsetsMake(10, 8, 10, 8);
    tv.keyboardType = UIKeyboardTypeURL;
    tv.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tv.autocorrectionType = UITextAutocorrectionTypeNo;
    tv.scrollEnabled = YES;
    tv.text = gProxyListURL ?: @"";
    [dlg addSubview:tv];
    self.urlEditorTextView = tv;

    UIButton *(^mkBtn)(NSString *, SEL, UIColor *) = ^UIButton *(NSString *t, SEL sel, UIColor *color) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.translatesAutoresizingMaskIntoConstraints = NO;
        b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        [b setTitle:t forState:UIControlStateNormal];
        [b setTitleColor:color forState:UIControlStateNormal];
        [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
        [dlg addSubview:b];
        return b;
    };
    UIButton *reset = mkBtn(TGLoc(@"\u0421\u0431\u0440\u043e\u0441", @"Reset"),
                            @selector(onURLEditorReset:), [UIColor systemRedColor]);
    UIButton *cancel = mkBtn(TGLoc(@"\u041e\u0442\u043c\u0435\u043d\u0430", @"Cancel"),
                             @selector(onURLEditorCancel:), TGSecondaryColor());
    UIButton *save = mkBtn(TGLoc(@"\u0421\u043e\u0445\u0440\u0430\u043d\u0438\u0442\u044c", @"Save"),
                           @selector(onURLEditorSave:), TGAccentColor());
    save.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];

    UIView *btnSep = [[UIView alloc] init];
    btnSep.translatesAutoresizingMaskIntoConstraints = NO;
    btnSep.backgroundColor = TGSeparatorColor();
    [dlg addSubview:btnSep];

    [NSLayoutConstraint activateConstraints:@[
        [dlg.centerXAnchor constraintEqualToAnchor:backdrop.centerXAnchor],
        [dlg.topAnchor constraintEqualToAnchor:backdrop.safeAreaLayoutGuide.topAnchor constant:60],
        [dlg.widthAnchor constraintEqualToConstant:300],

        [title.topAnchor constraintEqualToAnchor:dlg.topAnchor constant:16],
        [title.leadingAnchor constraintEqualToAnchor:dlg.leadingAnchor constant:16],
        [title.trailingAnchor constraintEqualToAnchor:dlg.trailingAnchor constant:-16],

        [msg.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
        [msg.leadingAnchor constraintEqualToAnchor:dlg.leadingAnchor constant:16],
        [msg.trailingAnchor constraintEqualToAnchor:dlg.trailingAnchor constant:-16],

        [tv.topAnchor constraintEqualToAnchor:msg.bottomAnchor constant:12],
        [tv.leadingAnchor constraintEqualToAnchor:dlg.leadingAnchor constant:16],
        [tv.trailingAnchor constraintEqualToAnchor:dlg.trailingAnchor constant:-16],
        [tv.heightAnchor constraintEqualToConstant:96],

        [btnSep.topAnchor constraintEqualToAnchor:tv.bottomAnchor constant:16],
        [btnSep.leadingAnchor constraintEqualToAnchor:dlg.leadingAnchor],
        [btnSep.trailingAnchor constraintEqualToAnchor:dlg.trailingAnchor],
        [btnSep.heightAnchor constraintEqualToConstant:0.5],

        [reset.topAnchor constraintEqualToAnchor:btnSep.bottomAnchor],
        [reset.leadingAnchor constraintEqualToAnchor:dlg.leadingAnchor],
        [reset.bottomAnchor constraintEqualToAnchor:dlg.bottomAnchor],
        [reset.heightAnchor constraintEqualToConstant:48],
        [cancel.topAnchor constraintEqualToAnchor:btnSep.bottomAnchor],
        [cancel.leadingAnchor constraintEqualToAnchor:reset.trailingAnchor],
        [cancel.widthAnchor constraintEqualToAnchor:reset.widthAnchor],
        [cancel.heightAnchor constraintEqualToConstant:48],
        [save.topAnchor constraintEqualToAnchor:btnSep.bottomAnchor],
        [save.leadingAnchor constraintEqualToAnchor:cancel.trailingAnchor],
        [save.trailingAnchor constraintEqualToAnchor:dlg.trailingAnchor],
        [save.widthAnchor constraintEqualToAnchor:reset.widthAnchor],
        [save.heightAnchor constraintEqualToConstant:48],
    ]];

    // Our window must become key for the keyboard to route into the text view.
    self.prevKeyWindow = TGKeyWindow();
    [self.window makeKeyWindow];

    [UIView animateWithDuration:0.16 animations:^{ backdrop.alpha = 1; }];
}

- (void)onURLEditorBackdrop:(UITapGestureRecognizer *)g {
    // Ignore taps that land inside the dialog card; only the surrounding
    // dimmed area dismisses.
    CGPoint p = [g locationInView:self.urlEditorOverlay];
    if (self.urlEditorDialog && CGRectContainsPoint(self.urlEditorDialog.frame, p)) return;
    [self dismissURLEditor];
}

- (void)dismissURLEditor {
    UIView *ov = self.urlEditorOverlay;
    if (!ov) return;
    [self.urlEditorTextView resignFirstResponder];
    self.urlEditorOverlay = nil;
    self.urlEditorTextView = nil;
    self.urlEditorDialog = nil;
    UIWindow *tg = self.prevKeyWindow;
    self.prevKeyWindow = nil;
    if (tg && !tg.isHidden) [tg makeKeyWindow];
    [UIView animateWithDuration:0.14 animations:^{ ov.alpha = 0; }
                     completion:^(BOOL f) { [ov removeFromSuperview]; }];
}

- (void)onURLEditorCancel:(__unused UIButton *)b { [self dismissURLEditor]; }

- (void)onURLEditorReset:(__unused UIButton *)b {
    self.urlEditorTextView.text = kDefaultProxyURL;
}

- (void)onURLEditorSave:(__unused UIButton *)b {
    NSString *entered = [self.urlEditorTextView.text stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSURL *u = [NSURL URLWithString:entered];
    if (!u || !([u.scheme isEqualToString:@"http"] || [u.scheme isEqualToString:@"https"])) {
        TGShowToast(TGLoc(@" URL \u0434\u043e\u043b\u0436\u0435\u043d \u043d\u0430\u0447\u0438\u043d\u0430\u0442\u044c\u0441\u044f \u0441 http:// \u0438\u043b\u0438 https:// ",
                          @" URL must start with http:// or https:// "));
        return;
    }
    NSString *savingURL = [entered copy];
    NSURLSessionDataTask *verifyTask = [[NSURLSession sharedSession]
        dataTaskWithURL:u
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error || !data) {
                    TGShowToast([NSString stringWithFormat:@" \u2717 %@ ",
                        error ? error.localizedDescription
                              : TGLoc(@"\u041e\u0448\u0438\u0431\u043a\u0430 \u0437\u0430\u0433\u0440\u0443\u0437\u043a\u0438", @"Fetch error")]);
                    return;
                }
                NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                NSArray *proxies = TGParseProxyListText(text);
                if (proxies.count == 0) {
                    TGShowToast(TGLoc(@" \u0412 \u0444\u0430\u0439\u043b\u0435 \u043d\u0435 \u043d\u0430\u0439\u0434\u0435\u043d\u043e \u043f\u0440\u043e\u043a\u0441\u0438 ",
                                      @" No proxies found in file "));
                    return;
                }
                gProxyListURL = [savingURL copy];
                NSMutableDictionary *p = [TGPrefsLoad() mutableCopy] ?: [NSMutableDictionary dictionary];
                p[kKeyProxyURL] = gProxyListURL;
                TGPrefsSave(p);
                TGLog(@"proxy URL saved & validated: %@ (%ld proxies)", gProxyListURL, (long)proxies.count);
                TGAddTelemtProxies(proxies);
                TGSaveOnlineCache(text);
                TGShowToast([NSString stringWithFormat:@" \u2713 %ld ", (long)proxies.count]);
                TGUpdatePanel();
                [self dismissURLEditor];
            });
        }];
    [verifyTask resume];
}
- (void)onSegment:(UIButton *)b {
    NSArray *ints = self.intervals;
    NSInteger idx = b.tag;
    if (idx < 0 || idx >= (NSInteger)ints.count) return;
    gIntervalSec = [ints[idx] integerValue];
    NSMutableDictionary *p = [TGPrefsLoad() mutableCopy] ?: [NSMutableDictionary dictionary];
    p[kKeyInterval] = @(gIntervalSec);
    TGPrefsSave(p);
    TGLog(@"UI interval -> %lds", (long)gIntervalSec);
    [self update];
}
- (void)onLanguage:(__unused UIButton *)b {
    gLanguage = TGLangRU() ? @"en" : @"ru";
    NSMutableDictionary *p = [TGPrefsLoad() mutableCopy] ?: [NSMutableDictionary dictionary];
    p[kKeyLanguage] = gLanguage;
    TGPrefsSave(p);
    TGLog(@"UI language -> %@", gLanguage);
    [self update];
}
- (void)onPrevProxy:(__unused UIButton *)b {
    TGLog(@"UI manual prev proxy");
    TGRotateBy(-1);
}
- (void)onNextProxy:(__unused UIButton *)b {
    TGLog(@"UI manual next proxy");
    TGRotateBy(+1);
}
- (void)onRandomProxy:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    // Use the online proxy list when telemt search is active, otherwise the
    // user's saved proxies from Telegram.
    NSArray *list;
    if (gTelemtSearch) {
        @synchronized(gTelemtProxies) { list = [gTelemtProxies copy]; }
    } else {
        @synchronized(gProxies) { list = [gProxies copy]; }
    }
    if (list.count < 2) return;
    // Pick a random index different from current.
    NSInteger randomIdx;
    NSInteger tries = 0;
    do {
        randomIdx = arc4random_uniform((uint32_t)list.count);
        tries++;
    } while (randomIdx == gCurrentIndex && tries < 10);
    NSInteger delta = randomIdx - gCurrentIndex;
    TGLog(@"UI random proxy -> idx=%ld (of %ld)", (long)randomIdx, (long)list.count);
    TGRotateBy(delta);
}
- (void)onProxyLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    NSArray *list;
    if (gTelemtSearch) {
        @synchronized(gTelemtProxies) { list = [gTelemtProxies copy]; }
    } else {
        @synchronized(gProxies) { list = [gProxies copy]; }
    }
    if (list.count == 0) return;
    NSUInteger idx = (gCurrentIndex >= 0 && gCurrentIndex < (NSInteger)list.count) ? (NSUInteger)gCurrentIndex : 0;
    NSDictionary *p = list[idx];
    NSString *link = p[@"link"];
    if (!link.length) {
        NSString *host = p[@"host"];
        NSNumber *port = p[@"port"];
        NSData *secret = (p[@"secret"] == [NSNull null]) ? nil : p[@"secret"];
        NSString *secretHex = @"";
        if (secret.length > 0) {
            const unsigned char *sb = secret.bytes;
            NSMutableString *hex = [NSMutableString stringWithCapacity:secret.length*2];
            for (NSUInteger k = 0; k < secret.length; k++) [hex appendFormat:@"%02x", sb[k]];
            secretHex = hex;
        }
        link = [NSString stringWithFormat:@"tg://proxy?server=%@&port=%@&secret=%@", host, port, secretHex];
    }
    NSURL *url = [NSURL URLWithString:link];
    if (url) {
        // Handle the URL within the current app instead of going through iOS
        // system dispatcher (which may open a different Telegram client when
        // multiple ones are installed). We call the app delegate's URL handler
        // directly, bypassing UIApplication openURL: scheme resolution.
        UIApplication *app = [UIApplication sharedApplication];
        id<UIApplicationDelegate> delegate = app.delegate;
        BOOL handled = NO;
        if ([delegate respondsToSelector:@selector(application:openURL:options:)]) {
            handled = [delegate application:app openURL:url options:@{}];
        }
        if (!handled) {
            // Fallback: system openURL (may open another Telegram client).
            [app openURL:url options:@{} completionHandler:nil];
        }
        TGLog(@"long press: opening proxy link %@ (internal=%d)", link, handled);
    }
}

@end

#pragma mark - Gestures
@implementation TGGestureTarget
- (void)openPanel {
    dispatch_async(dispatch_get_main_queue(), ^{
        gPanel = [TGPanelController shared];
        // If the panel is minimized (FAB visible), restore it instead of show().
        if (gPanel.miniShieldButton) {
            [gPanel restore];
        } else {
            [gPanel show];
        }
    });
}
- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    [self openPanel];
}
- (void)onThreeFinger:(UITapGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateEnded) return;
    [self openPanel];
}
@end

static TGGestureTarget *gGestureTarget = nil;
static BOOL gGesturesInstalled = NO;

static UIWindow *TGKeyWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (@available(iOS 13.0,*)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow && !w.isHidden) return w;
            }
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (!w.isHidden) return w;
            }
        }
    }
    return app.keyWindow;
}

static void TGInstallGestures(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gGesturesInstalled) return;
        UIWindow *kw = TGKeyWindow();
        if (!kw) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0*NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ TGInstallGestures(); });
            return;
        }
        gGesturesInstalled = YES;
        if (!gGestureTarget) gGestureTarget = [TGGestureTarget new];
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
            initWithTarget:gGestureTarget action:@selector(onLongPress:)];
        lp.minimumPressDuration = 0.5;
        lp.cancelsTouchesInView = NO;
        [kw addGestureRecognizer:lp];
        UITapGestureRecognizer *three = [[UITapGestureRecognizer alloc]
            initWithTarget:gGestureTarget action:@selector(onThreeFinger:)];
        three.numberOfTouchesRequired = 3;
        three.cancelsTouchesInView = NO;
        [kw addGestureRecognizer:three];
        TGLog(@"gestures installed");
    });
}

#pragma mark - Proxy list UI neutralization
// In auto-rotation mode, Telegram's checkbox stays on the manually-selected proxy
// even though MTContext is using a different one. We neutralize the stale checkmark
// and "connected" status on ALL proxy cells, then add our own marker to the
// proxy host that TGProxyRotation actually installed in MTContext.
static const NSInteger kTGActiveProxyBadgeTag = 0x54475052; // TGPR

static BOOL TGStringLooksConnected(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length == 0) return NO;
    NSString *low = s.lowercaseString;
    return [low isEqualToString:@"connected"] ||
           [low containsString:@"\u043f\u043e\u0434\u043a\u043b\u044e\u0447"] || // подключ
           [low containsString:@"\u0441\u043e\u0435\u0434\u0438\u043d"];        // соедин
}

static BOOL TGStringMatchesKnownProxyHost(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length == 0) return NO;
    NSArray *list; @synchronized(gProxies) { list = [gProxies copy]; }
    for (NSDictionary *p in list) {
        NSString *host = p[@"host"];
        if ([host isKindOfClass:[NSString class]] && host.length && [s containsString:host]) return YES;
    }
    return NO;
}

static NSString *TGActiveProxyHostSnapshot(void) {
    @synchronized([NSObject class]) { return [gActiveProxyHost copy]; }
}

static NSString *TGProxyHostForLabels(NSArray<UILabel *> *labels) {
    NSArray *list; @synchronized(gProxies) { list = [gProxies copy]; }
    for (UILabel *l in labels) {
        NSString *t = l.text ?: l.attributedText.string;
        if (![t isKindOfClass:[NSString class]] || t.length == 0) continue;
        for (NSDictionary *p in list) {
            NSString *host = p[@"host"];
            if ([host isKindOfClass:[NSString class]] && host.length && [t containsString:host]) return host;
        }
    }
    return nil;
}

static void TGCollectLabels(UIView *v, NSMutableArray<UILabel *> *labels) {
    if (!v) return;
    if ([v isKindOfClass:[UILabel class]]) [labels addObject:(UILabel *)v];
    for (UIView *s in v.subviews) TGCollectLabels(s, labels);
}

static UIView *TGActiveProxyBadge(void) {
    UIImage *img = nil;
    if (@available(iOS 13.0, *)) img = [UIImage systemImageNamed:@"checkmark.circle.fill"];
    UIImageView *iv = [[UIImageView alloc] initWithImage:img];
    iv.tag = kTGActiveProxyBadgeTag;
    iv.frame = CGRectMake(0, 0, 28, 28);
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.tintColor = TGAccentColor();
    if (!img) {
        UILabel *fallback = [[UILabel alloc] initWithFrame:iv.bounds];
        fallback.tag = kTGActiveProxyBadgeTag;
        fallback.text = @"ON";
        fallback.textAlignment = NSTextAlignmentCenter;
        fallback.font = [UIFont boldSystemFontOfSize:12];
        fallback.textColor = TGAccentColor();
        return fallback;
    }
    return iv;
}

static void TGResetProxyCellDecoration(UITableViewCell *cell) {
    if (!cell) return;
    if (cell.accessoryView.tag == kTGActiveProxyBadgeTag) cell.accessoryView = nil;
    cell.contentView.layer.borderWidth = 0.0;
    cell.contentView.layer.borderColor = nil;
    cell.contentView.layer.cornerRadius = 0.0;
}

static void TGNeutralizeProxyCellIfNeeded(UITableViewCell *cell) {
    if (!cell) return;
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    TGCollectLabels(cell.contentView ?: (UIView *)cell, labels);
    NSString *cellHost = TGProxyHostForLabels(labels);
    if (!gEnabled || !cellHost.length) { TGResetProxyCellDecoration(cell); return; }

    // Remove stale checkmark from all proxy cells.
    if (cell.accessoryType == UITableViewCellAccessoryCheckmark) {
        cell.accessoryType = UITableViewCellAccessoryNone;
    }
    // Hide "connected/подключён" status labels (they are stale).
    for (UILabel *l in labels) {
        NSString *t = l.text ?: l.attributedText.string;
        if (TGStringLooksConnected(t)) { l.hidden = YES; l.alpha = 0.0; }
    }

    NSString *activeHost = TGActiveProxyHostSnapshot();
    BOOL isActive = activeHost.length && [cellHost isEqualToString:activeHost];
    if (!isActive) { TGResetProxyCellDecoration(cell); return; }

    cell.accessoryType = UITableViewCellAccessoryNone;
    if (cell.accessoryView.tag != kTGActiveProxyBadgeTag) cell.accessoryView = TGActiveProxyBadge();
    cell.contentView.layer.cornerRadius = 8.0;
    cell.contentView.layer.borderWidth = 1.5;
    cell.contentView.layer.borderColor = TGAccentColor().CGColor;
}

#pragma mark - Context adoption
static NSMutableSet *gSeenCtx = nil;
static NSObject *gCtxLock = nil;
static BOOL TGEnvHasProxy(id env) {
    if (!env) return NO;
    id socks = [(id<TGMTApiEnvironment>)env socksProxySettings];
    return socks ? YES : NO;
}
static void TGAdoptContext(id ctx, NSString *tag) {
    if (!ctx) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gSeenCtx = [NSMutableSet set]; gCtxLock = [NSObject new]; });
    @synchronized(gCtxLock) {
        NSString *key = [NSString stringWithFormat:@"%@:%p", NSStringFromClass([ctx class]), ctx];
        BOOL firstSight = ![gSeenCtx containsObject:key];
        if (firstSight) [gSeenCtx addObject:key];
        BOOL hasProxy = TGEnvHasProxy([(id<TGMTContext>)ctx apiEnvironment]);
        id cur = gContextWeak;
        if (cur == ctx) return;
        if (cur) {
            BOOL curHasProxy = TGEnvHasProxy([(id<TGMTContext>)cur apiEnvironment]);
            if (curHasProxy && !hasProxy) return;
            if (!curHasProxy && !hasProxy) return;
        }
        gContextWeak = ctx;
        if (firstSight) TGLog(@"ctx-adopt %@ cls=%@ ptr=%p hasProxy=%d", tag, NSStringFromClass([ctx class]), ctx, hasProxy);
    }
}

#pragma mark - Manual method hooks (no Logos/Substrate)
// Replaces a method IMP on the target class itself (MTContext / MTTransport /
// UITableViewCell). The previous version looked the replacement selector up on
// the *target* class, but the replacements lived on a helper class, so the
// lookup returned NULL and every hook silently failed to install - which is why
// the sideloaded dylib never adopted an MTContext and the arrows/rotation did
// nothing. We now bind C-function IMPs directly and always call the original.
static void (*orig_MTContext_reportSuccess)(id, SEL, NSInteger, id);
static void (*orig_MTContext_reportFailure)(id, SEL, NSInteger, id);
static id   (*orig_MTTransport_init)(id, SEL, id, id, NSInteger, id, id, id, id);
static void (*orig_UITableViewCell_layoutSubviews)(id, SEL);
static void (*orig_UITableViewCell_setAccessoryType)(id, SEL, UITableViewCellAccessoryType);

static BOOL TGHookMethod(Class cls, SEL sel, IMP newImp, void *origStore) {
    if (!cls) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    const char *types = method_getTypeEncoding(m);
    IMP superImp = method_getImplementation(m);
    // If the IMP is inherited, class_addMethod installs a fresh entry on cls and
    // returns YES, so the saved orig correctly targets the super IMP; otherwise
    // method_setImplementation swaps it in place and returns the real original.
    if (class_addMethod(cls, sel, newImp, types)) {
        *(IMP *)origStore = superImp;
    } else {
        *(IMP *)origStore = method_setImplementation(class_getInstanceMethod(cls, sel), newImp);
    }
    return YES;
}

static void tg_MTContext_reportSuccess(id self, SEL _cmd, NSInteger dc, id scheme) {
    if (orig_MTContext_reportSuccess) orig_MTContext_reportSuccess(self, _cmd, dc, scheme);
    TGAdoptContext(self, @"success");
    gTransportSuccessAbs = CFAbsoluteTimeGetCurrent();
    TGOnSchemeSuccess();
}
static void tg_MTContext_reportFailure(id self, SEL _cmd, NSInteger dc, id scheme) {
    if (orig_MTContext_reportFailure) orig_MTContext_reportFailure(self, _cmd, dc, scheme);
    TGAdoptContext(self, @"failure");
    gTransportFailureAbs = CFAbsoluteTimeGetCurrent();
    TGUpdatePanel();
}
static id tg_MTTransport_init(id self, SEL _cmd, id delegate, id context, NSInteger dc,
                              id schemes, id proxySettings, id usage, id getLogPrefix) {
    id ret = orig_MTTransport_init ? orig_MTTransport_init(self, _cmd, delegate, context, dc, schemes, proxySettings, usage, getLogPrefix) : self;
    if (ret && context) TGAdoptContext(context, @"transport.init");
    return ret;
}
static void tg_UITableViewCell_layoutSubviews(id self, SEL _cmd) {
    if (orig_UITableViewCell_layoutSubviews) orig_UITableViewCell_layoutSubviews(self, _cmd);
    TGNeutralizeProxyCellIfNeeded((UITableViewCell *)self);
}
static void tg_UITableViewCell_setAccessoryType(id self, SEL _cmd, UITableViewCellAccessoryType t) {
    if (gEnabled && t == UITableViewCellAccessoryCheckmark) {
        NSMutableArray<UILabel *> *labels = [NSMutableArray array];
        TGCollectLabels(((UITableViewCell *)self).contentView ?: (UIView *)self, labels);
        for (UILabel *l in labels) {
            NSString *txt = l.text ?: l.attributedText.string;
            if (TGStringMatchesKnownProxyHost(txt)) { t = UITableViewCellAccessoryNone; break; }
        }
    }
    if (orig_UITableViewCell_setAccessoryType) orig_UITableViewCell_setAccessoryType(self, _cmd, t);
}

static BOOL gHooksInstalled = NO;
static void TGInstallHooks(void) {
    if (gHooksInstalled) return;
    Class mtCtx = objc_getClass("MTContext");
    Class mtTr  = objc_getClass("MTTransport");
    // MTProtoKit may not be loaded yet at ctor time - require MTContext before
    // binding, otherwise retry shortly so the dylib still hooks on a cold start.
    if (!mtCtx) {
        TGLog(@"hooks: MTContext not ready, retrying in 0.5s");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5*NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ TGInstallHooks(); });
        return;
    }
    TGHookMethod(mtCtx, @selector(reportTransportSchemeSuccessForDatacenterId:transportScheme:),
                 (IMP)tg_MTContext_reportSuccess, &orig_MTContext_reportSuccess);
    TGHookMethod(mtCtx, @selector(reportTransportSchemeFailureForDatacenterId:transportScheme:),
                 (IMP)tg_MTContext_reportFailure, &orig_MTContext_reportFailure);
    if (mtTr) {
        TGHookMethod(mtTr, @selector(initWithDelegate:context:datacenterId:schemes:proxySettings:usageCalculationInfo:getLogPrefix:),
                     (IMP)tg_MTTransport_init, &orig_MTTransport_init);
    }
    TGHookMethod([UITableViewCell class], @selector(layoutSubviews),
                 (IMP)tg_UITableViewCell_layoutSubviews, &orig_UITableViewCell_layoutSubviews);
    TGHookMethod([UITableViewCell class], @selector(setAccessoryType:),
                 (IMP)tg_UITableViewCell_setAccessoryType, &orig_UITableViewCell_setAccessoryType);
    gHooksInstalled = YES;
    TGLog(@"hooks installed (MTContext=%d MTTransport=%d)", mtCtx != nil, mtTr != nil);
}
__attribute__((constructor)) static void TGProxyRotationCtor(void) {
    @autoreleasepool {
        // Client-agnostic gate: official Telegram OR any MTProtoKit-based fork.
        if (!TGIsSupportedClient()) return;
        // Guard against double-activation when both the bootstrap tweak and an
        // embedded sideload dylib are present in the same client: the first to
        // load registers a process-wide sentinel class; any later copy bails.
        if (objc_getClass("TGPRLoadedSentinel")) {
            TGLog(@"another TGProxyRotation instance already active - skipping");
            return;
        }
        Class tgSentinel = objc_allocateClassPair([NSObject class], "TGPRLoadedSentinel", 0);
        if (tgSentinel) objc_registerClassPair(tgSentinel);
        gProxies = [NSMutableArray array]; TGPrefsApply(nil);
        TGLog(@"=== TGProxyRotation (dylib) loaded pid=%d ===", getpid());
        if (gTelemtSearch) { TGLoadOnlineCache(); TGFetchOnlineProxies(); }
        gStartupPending = gEnabled; if (gEnabled) TGWatchStart();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, TGOnDarwinNotify, CFSTR("com.ratush.tgproxyrotation.changed"), NULL, CFNotificationSuspensionBehaviorCoalesce);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ TGInstallHooks(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            TGInstallGestures(); gPanel = [TGPanelController shared]; [gPanel show]; gPanel.card.alpha = 0; gPanel.card.hidden = YES; [gPanel minimize];
        });
        for (int delay = 5; delay <= 15; delay += 5) { int d = delay; dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ NSArray *b; @synchronized(gProxies) { b = [gProxies copy]; } TGPrefsApply(nil); NSArray *a; @synchronized(gProxies) { a = [gProxies copy]; } if (a.count != b.count) { TGLog(@"late proxy reload: %lu -> %lu", (unsigned long)b.count, (unsigned long)a.count); TGUpdatePanel(); } }); }
    }
}
