#import <Foundation/Foundation.h>

// Append a formatted log line to the tweak's log file (jbroot-relative on roothide,
// NSTemporaryDirectory() fallback otherwise). Thread-safe. No-op if logging disabled.
void TGLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

// Enable/disable logging at runtime (default on). Reads the tweak's prefs plist.
void TGLogSetEnabled(BOOL enabled);
