#import <UIKit/UIKit.h>

// Opening web links. A link tapped in a text (-openLink:) goes to twitch.tv addresses inside the app (TWNavigator), to
// the sister app of this family for YouTube (Tubie), Kick (Kicker) and TikTok (TikTak) links when it is installed - a
// sheet asks first - and to the browser for everything else: on iOS 6 a sheet offers Safari and, when installed,
// Surfari (the iOS 6 browser of this family); iOS 7 and newer open Safari directly. Retains itself until a sheet is gone.
@interface TWExternalOpen : NSObject

// A link in a text was tapped (chat, titles, descriptions). Also the twitcher:link?url= debug command.
+ (void)openLink:(NSString *)link from:(UIViewController *)controller anchor:(UIView *)anchor;
// The links of one text (TWTextLink or NSString items): one is opened right away, several are offered in a sheet
+ (void)presentLinks:(NSArray *)links from:(UIViewController *)controller anchor:(UIView *)anchor;

// The browser chooser for a web link: iOS 6 asks (Open in Safari / Open in Surfari when installed / Cancel), iOS 7
// and newer open Safari directly. A sister app's link is offered first on every iOS.
+ (void)presentOpenInForURL:(NSURL *)url from:(UIViewController *)controller anchor:(UIView *)anchor;
// Sharing a web link: on iOS 6 the chooser with "Copy link" added, on iOS 7 and newer the system's share sheet
// (UIActivityViewController; on the iPad a popover from the anchor, or from the middle of the view without one)
+ (void)presentShareSheetForURL:(NSURL *)url from:(UIViewController *)controller anchor:(UIView *)anchor;
+ (BOOL)surfariAvailable;   // on iOS 6 (newer iOS never ask)

@end
