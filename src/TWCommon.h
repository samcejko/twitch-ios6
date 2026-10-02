// Shared macros and constants. Everything here must be iOS 6.0 safe.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// Any API newer than the iOS 6.0 deployment target is a hard error in files that include this header.
#pragma clang diagnostic error "-Wunguarded-availability"

#define L(key) NSLocalizedString((key), nil)
#define TWIsPad() (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
#define TWLog(fmt, ...) NSLog((@"[Twitcher] " fmt), ##__VA_ARGS__)

// Runs a block on the main thread (immediately if already there).
static inline void TWMain(dispatch_block_t block)
{
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

extern NSString * const TWErrorDomain;
extern NSString * const TWThemeDidChangeNotification;
extern NSString * const TWSettingsDidChangeNotification;
extern NSString * const TWAuthDidChangeNotification;        // logged in, logged out, token refreshed
extern NSString * const TWFavoritesDidChangeNotification;

// NSError codes in TWErrorDomain (HTTP errors use the HTTP status as code)
enum {
    TWErrorNetwork        = -1,
    TWErrorTLS            = -2,
    TWErrorCertificate    = -3,
    TWErrorTimeout        = -4,
    TWErrorCancelled      = -5,
    TWErrorBadResponse    = -6,
    TWErrorDNS            = -7,
    TWErrorConnect        = -8,
    TWErrorConnectionLost = -9,
    TWErrorAPI            = -10,   // Twitch answered, but with an error
    TWErrorOffline        = -11,   // the channel is not live
    TWErrorAuth           = -12,   // not logged in, or the login expired
    TWErrorRestricted     = -13,   // subscribers only, geoblocked...
};

NSError *TWMakeError(NSInteger code, NSString *message);

// JSON values as the type the caller expects, nil/0 for anything else (NSNull, wrong type)
NSString *TWStr(id value);         // numbers become their decimal string
NSDictionary *TWDict(id value);
NSArray *TWArr(id value);
NSInteger TWInt(id value);
double TWDbl(id value);
BOOL TWBool(id value);

// "2026-10-02T17:31:00Z" and "2026-10-02T17:31:05.042684Z"
NSDate *TWDateFromISO(NSString *string);
