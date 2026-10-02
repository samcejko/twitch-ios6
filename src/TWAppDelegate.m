#import "TWAppDelegate.h"
#import "TWRootViewController.h"
#import "TWTLSSocket.h"
#import "TWMediaProxy.h"
#import "TWImageLoader.h"
#import "TWAuth.h"
#import "TWSettings.h"
#import "TWTheme.h"
#import "TWUtils.h"
#import "TWCommon.h"
#include <dlfcn.h>
#include <signal.h>

@implementation TWAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    // (a peer that went away must not kill the process while a socket is written to)
    signal(SIGPIPE, SIG_IGN);
    [TWSettings registerDefaults];
    TWLog(@"Twitcher %@ starting on %@ (iOS %@)", [TWUtils appVersion], [TWUtils deviceModel], [UIDevice currentDevice].systemVersion);
    [TWTLSSocket warmUp];
    [[TWImageLoader shared] pruneDisk];
    [TWImageLoader shared].animationAllowed = [TWSettings animatedEmotes];
    [[TWAuth shared] validateIfNeeded];

    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.rootViewController = [[TWRootViewController alloc] init];
    self.window.rootViewController = self.rootViewController;
    self.window.backgroundColor = [[TWTheme shared] backgroundColor];
    [self.window makeKeyAndVisible];
    [application setStatusBarStyle:[[TWTheme shared] statusBarStyle] animated:NO];
    return YES;
}

// twitcher:channel/<login> opens the channel page, twitcher:watch/<login> the player; over SSH (uiopen) a few
// commands help checking the app: twitcher:snapshot and twitcher:screen write tmp/screen.png, twitcher:press?n=1
// presses a button of the alert on screen. The commands need a file named "debug" in the app's Documents folder.
- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url sourceApplication:(NSString *)sourceApplication annotation:(id)annotation
{
    NSString *s = url.absoluteString ?: @"";
    if (![s hasPrefix:@"twitcher:"]) return NO;
    NSString *target = [s substringFromIndex:@"twitcher:".length];
    while ([target hasPrefix:@"/"]) target = [target substringFromIndex:1];
    NSString *query = nil;
    NSRange q = [target rangeOfString:@"?"];
    if (q.location != NSNotFound) {
        query = [target substringFromIndex:q.location + 1];
        target = [target substringToIndex:q.location];
    }
    NSDictionary *params = query.length ? [TWUtils parseQuery:query] : @{};
    if ([target hasPrefix:@"channel/"] || [target hasPrefix:@"watch/"]) {
        BOOL watch = [target hasPrefix:@"watch/"];
        NSString *login = [[target substringFromIndex:[target rangeOfString:@"/"].location + 1] lowercaseString];
        login = [login stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding] ?: login;
        if (login.length) [self.rootViewController openChannelLogin:login watch:watch];
        return YES;
    }
    if ([target isEqualToString:@"open"] && [params[@"channel"] length]) {
        [self.rootViewController openChannelLogin:[params[@"channel"] lowercaseString] watch:[params[@"watch"] boolValue]];
        return YES;
    }
    BOOL debug = [[NSFileManager defaultManager] fileExistsAtPath:[[TWUtils documentsPath] stringByAppendingPathComponent:@"debug"]];
    if (!debug) return YES;
    if ([target isEqualToString:@"snapshot"]) {
        // every visible window drawn into one picture (alerts and sheets have windows of their own)
        CGSize size = [UIScreen mainScreen].bounds.size;
        UIGraphicsBeginImageContextWithOptions(size, YES, 1.0);
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.hidden || w.alpha <= 0) continue;
            CGContextSaveGState(ctx);
            CGContextTranslateCTM(ctx, w.frame.origin.x, w.frame.origin.y);
            [w.layer renderInContext:ctx];
            CGContextRestoreGState(ctx);
        }
        UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"screen.png"];
        BOOL ok = [UIImagePNGRepresentation(image) writeToFile:path atomically:YES];
        TWLog(@"Snapshot %@: %@", ok ? @"written to" : @"failed for", path);
        return YES;
    }
    if ([target isEqualToString:@"screen"]) {
        // what the screen really shows, video included (the system's own screen grab, resolved at run time)
        CGImageRef (*grab)(void) = (CGImageRef (*)(void))dlsym(RTLD_DEFAULT, "UIGetScreenImage");
        CGImageRef shot = grab ? grab() : NULL;
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"screen.png"];
        BOOL ok = NO;
        if (shot) {
            ok = [UIImagePNGRepresentation([UIImage imageWithCGImage:shot]) writeToFile:path atomically:YES];
            CGImageRelease(shot);
        }
        TWLog(@"Screen grab %@: %@", ok ? @"written to" : @"failed for", path);
        return YES;
    }
    if ([target isEqualToString:@"press"]) {
        // twitcher:press?n=<index> presses a button of the alert or action sheet on screen, press?title=<text> a button with that title
        NSString *byTitle = params[@"title"];
        NSInteger n = [params[@"n"] integerValue];
        NSMutableArray *views = [NSMutableArray array];
        for (UIWindow *w in [UIApplication sharedApplication].windows) [views addObject:w];
        BOOL pressed = NO;
        for (NSUInteger i = 0; i < views.count && !pressed; i++) {
            UIView *v = views[i];
            if (!byTitle.length && [v isKindOfClass:[UIAlertView class]] && ((UIAlertView *)v).visible) {
                UIAlertView *alert = (UIAlertView *)v;
                if ([alert.delegate respondsToSelector:@selector(alertView:clickedButtonAtIndex:)]) [alert.delegate alertView:alert clickedButtonAtIndex:n];
                [alert dismissWithClickedButtonIndex:n animated:NO];
                pressed = YES;
            } else if (!byTitle.length && [v isKindOfClass:[UIActionSheet class]] && ((UIActionSheet *)v).visible) {
                UIActionSheet *sheet = (UIActionSheet *)v;
                if ([sheet.delegate respondsToSelector:@selector(actionSheet:clickedButtonAtIndex:)]) [sheet.delegate actionSheet:sheet clickedButtonAtIndex:n];
                [sheet dismissWithClickedButtonIndex:n animated:NO];
                pressed = YES;
            } else if (byTitle.length && [v isKindOfClass:[UIButton class]] && !v.hidden &&
                       [((UIButton *)v).currentTitle rangeOfString:byTitle].location != NSNotFound) {
                [(UIButton *)v sendActionsForControlEvents:UIControlEventTouchUpInside];
                pressed = YES;
            } else {
                [views addObjectsFromArray:v.subviews];
            }
        }
        TWLog(@"Press %@: %@", query ?: @"", pressed ? @"done" : @"nothing found");
        return YES;
    }
    if ([target isEqualToString:@"tab"]) {
        NSInteger n = [params[@"n"] integerValue];
        if (n >= 0 && n < 5) self.rootViewController.selectedIndex = (NSUInteger)n;
        return YES;
    }
    return YES;
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
    [[TWAuth shared] validateIfNeeded];
    [[TWMediaProxy shared] ensureRunning];
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    [TWSettings save];
}

- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application
{
    TWLog(@"Memory warning");
    [[TWImageLoader shared] clearMemory];
}

- (void)applicationWillTerminate:(UIApplication *)application
{
    [TWSettings save];
}

@end
