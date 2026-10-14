#import "TWExternalOpen.h"
#import "TWNavigator.h"
#import "TWLinks.h"
#import "TWUtils.h"
#import "TWModern.h"
#import "TWCommon.h"

// A sister app of this family that shows the links of a site: Tubie (YouTube), Kicker (Kick), TikTak (TikTok).
// Each takes <scheme>:open?url=<percent-encoded link>, as Surfari does.
@interface TWSisterApp : NSObject
@property (nonatomic, copy) NSString *title;          // "Open in Tubie"
@property (nonatomic, strong) NSArray *schemes;       // the URL schemes the app registers (TikTak answers to two)
@property (nonatomic, strong) NSArray *hosts;         // youtube.com also matches www.youtube.com and m.youtube.com
@end

@implementation TWSisterApp
@end

enum { TWSheetChooser = 1, TWSheetLinks = 2 };

@interface TWExternalOpen () <UIActionSheetDelegate, UIPopoverControllerDelegate>
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, strong) NSArray *links;                   // the links of a text (NSString), for the sheet listing them
@property (nonatomic, weak) UIViewController *controller;
@property (nonatomic, weak) UIView *anchor;
@property (nonatomic, copy) NSString *sisterTitle;              // the first button when a sister app takes the link
@property (nonatomic, strong) NSURL *sisterURL;
@property (nonatomic, strong) UIPopoverController *popover;     // iOS 7 iPad: the share sheet's popover
@end

// The live sheets' delegates, so ARC does not free them while a sheet is on screen
static NSMutableArray *g_live;

static void TWKeepAlive(TWExternalOpen *open)
{
    if (!g_live) g_live = [NSMutableArray array];
    [g_live addObject:open];
}

static NSInteger TWMajorVersion(void)
{
    static NSInteger major = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        major = [[[[UIDevice currentDevice] systemVersion] componentsSeparatedByString:@"."][0] integerValue];
        if (major < 1) major = 6;
    });
    return major;
}

// host is domain, or a subdomain of it
static BOOL TWHostMatches(NSString *host, NSString *domain)
{
    return [host isEqualToString:domain] || [host hasSuffix:[@"." stringByAppendingString:domain]];
}

// A text's link as an NSURL: percent escapes added when the characters need them, "http://" when the scheme is missing
static NSURL *TWURLFromLink(NSString *link)
{
    NSString *s = [link stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!s.length) return nil;
    if ([s rangeOfString:@"://"].location == NSNotFound) s = [@"http://" stringByAppendingString:s];
    NSURL *url = [NSURL URLWithString:s];
    if (!url) url = [NSURL URLWithString:[s stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding] ?: s];
    return url;
}

@implementation TWExternalOpen

#pragma mark - Browsers and sister apps

+ (BOOL)surfariAvailable
{
    if (TWModernIOS()) return NO;   // (Surfari is an iOS 6 browser; newer iOS open Safari directly anyway)
    return [[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:@"surfari://open?url=https://twitch.tv/"]];
}

+ (NSURL *)surfariURLForURL:(NSURL *)url
{
    NSString *encoded = [TWUtils urlEncode:url.absoluteString ?: @""];
    return [NSURL URLWithString:[@"surfari://open?url=" stringByAppendingString:encoded]];
}

+ (NSArray *)sisterApps
{
    static NSArray *apps;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        TWSisterApp *tubie = [[TWSisterApp alloc] init];
        tubie.title = L(@"Open in Tubie");
        tubie.schemes = @[ @"tubie" ];
        tubie.hosts = @[ @"youtube.com", @"youtu.be", @"youtube-nocookie.com" ];
        TWSisterApp *kicker = [[TWSisterApp alloc] init];
        kicker.title = L(@"Open in Kicker");
        kicker.schemes = @[ @"kicker" ];
        kicker.hosts = @[ @"kick.com" ];
        TWSisterApp *tiktak = [[TWSisterApp alloc] init];
        tiktak.title = L(@"Open in TikTak");
        tiktak.schemes = @[ @"tiktak", @"tikie" ];
        tiktak.hosts = @[ @"tiktok.com" ];
        apps = @[ tubie, kicker, tiktak ];
    });
    return apps;
}

// The installed sister app for this link, and the URL that opens the link in it; nil when there is none
+ (TWSisterApp *)sisterAppForURL:(NSURL *)url openURL:(NSURL **)openURL
{
    NSString *host = [url.host lowercaseString];
    if (!host.length) return nil;
    NSString *encoded = [TWUtils urlEncode:url.absoluteString ?: @""];
    for (TWSisterApp *app in [self sisterApps]) {
        BOOL matches = NO;
        for (NSString *domain in app.hosts) matches = matches || TWHostMatches(host, domain);
        if (!matches) continue;
        for (NSString *scheme in app.schemes) {
            NSURL *target = [NSURL URLWithString:[NSString stringWithFormat:@"%@:open?url=%@", scheme, encoded]];
            if (target && [[UIApplication sharedApplication] canOpenURL:target]) {
                if (openURL) *openURL = target;
                return app;
            }
        }
        return nil;   // (the site has a sister app, but it is not installed)
    }
    return nil;
}

#pragma mark - Links in texts

+ (void)openLink:(NSString *)link from:(UIViewController *)controller anchor:(UIView *)anchor
{
    NSURL *url = TWURLFromLink(link);
    if (!url) return;
    // a twitch.tv address the app has a screen for opens right here; the rest goes to a sister app or the browser
    if ([TWNavigator openTwitchURL:url from:controller]) return;
    [self presentOpenInForURL:url from:controller anchor:anchor];
}

+ (void)presentLinks:(NSArray *)links from:(UIViewController *)controller anchor:(UIView *)anchor
{
    NSMutableArray *urls = [NSMutableArray array];
    for (id item in links) {
        NSString *url = [item isKindOfClass:[TWTextLink class]] ? [(TWTextLink *)item url] : ([item isKindOfClass:[NSString class]] ? item : nil);
        if (url.length && ![urls containsObject:url]) [urls addObject:url];
    }
    if (!urls.count) return;
    if (urls.count == 1) { [self openLink:urls[0] from:controller anchor:anchor]; return; }
    TWExternalOpen *open = [[TWExternalOpen alloc] init];
    open.links = urls;
    open.controller = controller ?: [TWNavigator presenterFrom:nil];
    open.anchor = anchor;
    TWKeepAlive(open);
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:L(@"Links") delegate:open cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
    for (NSString *url in urls) [sheet addButtonWithTitle:[TWLinks shortTitleForURL:url]];
    sheet.cancelButtonIndex = [sheet addButtonWithTitle:L(@"Cancel")];
    sheet.tag = TWSheetLinks;
    [open showSheet:sheet];
}

#pragma mark - The chooser

+ (void)presentShareSheetForURL:(NSURL *)url from:(UIViewController *)controller anchor:(UIView *)anchor
{
    [self present:url share:YES from:controller anchor:anchor];
}

+ (void)presentOpenInForURL:(NSURL *)url from:(UIViewController *)controller anchor:(UIView *)anchor
{
    [self present:url share:NO from:controller anchor:anchor];
}

+ (void)present:(NSURL *)url share:(BOOL)share from:(UIViewController *)controller anchor:(UIView *)anchor
{
    if (!url || ![[url.scheme lowercaseString] hasPrefix:@"http"]) return;
    if (!controller) controller = [TWNavigator presenterFrom:nil];
    BOOL modern = TWModernIOS();
    NSURL *sisterURL = nil;
    TWSisterApp *sister = [self sisterAppForURL:url openURL:&sisterURL];
    if (modern && !sister) {
        // iOS 7 and newer ask nothing: Safari straight away, or the system's share sheet
        if (share) [self presentActivitySheetForURL:url from:controller anchor:anchor];
        else [[UIApplication sharedApplication] openURL:url];
        return;
    }
    TWExternalOpen *open = [[TWExternalOpen alloc] init];
    open.url = url;
    open.controller = controller;
    open.anchor = anchor;
    open.sisterTitle = sister.title;
    open.sisterURL = sisterURL;
    TWKeepAlive(open);
    // iOS 6: [Open in Tubie] [Copy link] Open in Safari [Open in Surfari] Cancel; iOS 7+: Open in Tubie, Open in Safari, [Share…], Cancel
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:url.absoluteString delegate:open cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
    if (sister) [sheet addButtonWithTitle:sister.title];
    if (share && !modern) [sheet addButtonWithTitle:L(@"Copy link")];
    [sheet addButtonWithTitle:L(@"Open in Safari")];
    if (!modern && [self surfariAvailable]) [sheet addButtonWithTitle:L(@"Open in Surfari")];
    if (share && modern) [sheet addButtonWithTitle:L(@"Share…")];
    sheet.cancelButtonIndex = [sheet addButtonWithTitle:L(@"Cancel")];
    sheet.tag = TWSheetChooser;
    [open showSheet:sheet];
}

- (void)showSheet:(UIActionSheet *)sheet
{
    UIView *anchor = self.anchor;
    UIView *view = self.controller.view;
    if (!view.window) view = [UIApplication sharedApplication].keyWindow.rootViewController.view;
    if (TWIsPad() && anchor.window) [sheet showFromRect:anchor.bounds inView:anchor animated:YES];
    else [sheet showInView:view];
}

// (the sheet is gone by now: another sheet, or the share sheet, may follow right away. The debug command
// twitcher:press?n= dismisses with a button index and lands here too.)
- (void)actionSheet:(UIActionSheet *)actionSheet didDismissWithButtonIndex:(NSInteger)buttonIndex
{
    BOOL chosen = buttonIndex >= 0 && buttonIndex != actionSheet.cancelButtonIndex;
    NSString *title = chosen ? [actionSheet buttonTitleAtIndex:buttonIndex] : nil;
    UIApplication *app = [UIApplication sharedApplication];
    if (!chosen) {
        // nothing
    } else if (actionSheet.tag == TWSheetLinks) {
        if ((NSUInteger)buttonIndex < self.links.count) [TWExternalOpen openLink:self.links[(NSUInteger)buttonIndex] from:self.controller anchor:self.anchor];
    } else if (self.sisterURL && [title isEqualToString:self.sisterTitle]) {
        [app openURL:self.sisterURL];
    } else if ([title isEqualToString:L(@"Copy link")]) {
        [UIPasteboard generalPasteboard].string = self.url.absoluteString ?: @"";
    } else if ([title isEqualToString:L(@"Open in Safari")]) {
        [app openURL:self.url];
    } else if ([title isEqualToString:L(@"Open in Surfari")]) {
        [app openURL:[TWExternalOpen surfariURLForURL:self.url]];
    } else if ([title isEqualToString:L(@"Share…")]) {
        [TWExternalOpen presentActivitySheetForURL:self.url from:self.controller anchor:self.anchor];
    }
    // (last: the sheet holds its delegate unretained and ARC does not retain self in a method, so this may free self)
    [g_live removeObject:self];
}

#pragma mark - The system's share sheet (iOS 7 and newer)

+ (void)presentActivitySheetForURL:(NSURL *)url from:(UIViewController *)controller anchor:(UIView *)anchor
{
    UIViewController *presenter = controller ?: [TWNavigator presenterFrom:nil];
    if (!presenter || !url) return;
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[ url ] applicationActivities:nil];
    if (!TWIsPad()) {
        [presenter presentViewController:activity animated:YES completion:nil];
        return;
    }
    // the iPad wants a popover: from the anchor, or from the middle of the view without one
    BOOL anchored = anchor && anchor.window;
    UIView *source = anchored ? anchor : presenter.view;
    CGRect rect = anchored ? anchor.bounds : CGRectMake(floor(CGRectGetMidX(source.bounds)), floor(CGRectGetMidY(source.bounds)), 1, 1);
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 80000
    if (TWMajorVersion() >= 8) {
        // (iOS 8 API, checked at run time: the deployment target of the armv7 build is iOS 6)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
        activity.modalPresentationStyle = UIModalPresentationPopover;
        UIPopoverPresentationController *popover = activity.popoverPresentationController;
        popover.sourceView = source;
        popover.sourceRect = rect;
        popover.permittedArrowDirections = anchored ? UIPopoverArrowDirectionAny : (UIPopoverArrowDirection)0;
#pragma clang diagnostic pop
        [presenter presentViewController:activity animated:YES completion:nil];
        return;
    }
#endif
    // iOS 7: the popover controller of old, kept alive until it is gone
    TWExternalOpen *holder = [[TWExternalOpen alloc] init];
    holder.popover = [[UIPopoverController alloc] initWithContentViewController:activity];
    holder.popover.delegate = holder;
    TWKeepAlive(holder);
    __weak TWExternalOpen *weakHolder = holder;
    activity.completionHandler = ^(NSString *activityType, BOOL completed) {
        TWExternalOpen *h = weakHolder;
        [h.popover dismissPopoverAnimated:YES];
        if (h) [g_live removeObject:h];
    };
    [holder.popover presentPopoverFromRect:rect inView:source permittedArrowDirections:UIPopoverArrowDirectionAny animated:YES];
}

- (void)popoverControllerDidDismissPopover:(UIPopoverController *)popoverController
{
    [g_live removeObject:self];
}

@end
