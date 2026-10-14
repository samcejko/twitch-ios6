#import "TWNavigator.h"
#import "TWPlayerViewController.h"
#import "TWChannelViewController.h"
#import "TWGameViewController.h"
#import "TWRootViewController.h"
#import "TWGQL.h"
#import "TWUtils.h"
#import "TWCommon.h"

@implementation TWNavigator

+ (UIViewController *)presenterFrom:(UIViewController *)controller
{
    UIViewController *top = controller ?: [UIApplication sharedApplication].keyWindow.rootViewController;
    while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) top = top.presentedViewController;
    return top;
}

+ (void)presentPlayer:(TWPlayerViewController *)player from:(UIViewController *)controller
{
    UIViewController *presenter = [self presenterFrom:controller];
    if ([presenter isKindOfClass:[TWPlayerViewController class]]) {
        // already watching something: the new content replaces it in the same screen
        [(TWPlayerViewController *)presenter replaceWithPlayer:player];
        return;
    }
    player.modalPresentationStyle = UIModalPresentationFullScreen;   // (iOS 13 and newer would present a card)
    player.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [presenter presentViewController:player animated:YES completion:nil];
}

+ (void)openStream:(TWStream *)stream from:(UIViewController *)controller
{
    if (!stream.login.length) return;
    TWPlayerViewController *player = [[TWPlayerViewController alloc] initWithChannelLogin:stream.login stream:stream];
    [self presentPlayer:player from:controller];
}

+ (void)watchChannelLogin:(NSString *)login from:(UIViewController *)controller
{
    if (!login.length) return;
    TWPlayerViewController *player = [[TWPlayerViewController alloc] initWithChannelLogin:login stream:nil];
    [self presentPlayer:player from:controller];
}

+ (void)openVideo:(TWVideo *)video from:(UIViewController *)controller
{
    if (!video.videoId.length) return;
    TWPlayerViewController *player = [[TWPlayerViewController alloc] initWithVideo:video];
    [self presentPlayer:player from:controller];
}

+ (void)openClip:(TWClip *)clip from:(UIViewController *)controller
{
    if (!clip.slug.length) return;
    TWPlayerViewController *player = [[TWPlayerViewController alloc] initWithClip:clip];
    [self presentPlayer:player from:controller];
}

+ (void)openVideoId:(NSString *)videoId from:(UIViewController *)controller
{
    if (!videoId.length) return;
    __weak UIViewController *weakController = controller;
    [TWGQL video:videoId completion:^(TWVideo *video, NSError *error) {
        if (video) [TWNavigator openVideo:video from:weakController];
        else TWLog(@"Video %@: %@", videoId, error.localizedDescription);
    }];
}

+ (void)openClipSlug:(NSString *)slug from:(UIViewController *)controller
{
    if (!slug.length) return;
    __weak UIViewController *weakController = controller;
    [TWGQL clip:slug completion:^(TWClip *clip, NSError *error) {
        if (!clip) {
            // (the details are for the title only: the clip plays by its slug alone)
            TWLog(@"Clip %@: %@", slug, error.localizedDescription);
            clip = [[TWClip alloc] init];
            clip.slug = slug;
            clip.title = slug;
        }
        [TWNavigator openClip:clip from:weakController];
    }];
}

+ (UINavigationController *)navigationControllerFrom:(UIViewController *)controller
{
    UIViewController *presenter = [self presenterFrom:controller];
    if ([presenter isKindOfClass:[UINavigationController class]]) return (UINavigationController *)presenter;
    if (presenter.navigationController) return presenter.navigationController;
    if ([presenter isKindOfClass:[UITabBarController class]]) {
        UIViewController *selected = [(UITabBarController *)presenter selectedViewController];
        if ([selected isKindOfClass:[UINavigationController class]]) return (UINavigationController *)selected;
    }
    return nil;
}

+ (void)openChannelLogin:(NSString *)login from:(UIViewController *)controller
{
    if (!login.length) return;
    TWChannelViewController *vc = [[TWChannelViewController alloc] initWithLogin:login];
    UIViewController *presenter = [self presenterFrom:controller];
    if ([presenter isKindOfClass:[TWPlayerViewController class]]) {
        // from the player: the channel page opens in its own stack over the video
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        vc.showsDoneButton = YES;
        nav.modalPresentationStyle = TWIsPad() ? UIModalPresentationFormSheet : UIModalPresentationFullScreen;
        [presenter presentViewController:nav animated:YES completion:nil];
        return;
    }
    UINavigationController *nav = [self navigationControllerFrom:controller];
    if (nav) [nav pushViewController:vc animated:YES];
}

+ (void)openGame:(TWGame *)game from:(UIViewController *)controller
{
    if (!game) return;
    TWGameViewController *vc = [[TWGameViewController alloc] initWithGame:game];
    UINavigationController *nav = [self navigationControllerFrom:controller];
    if (nav) [nav pushViewController:vc animated:YES];
}

#pragma mark - twitch.tv links

// Twitch's own slug of a category name: "Just Chatting" -> "just-chatting", "Tom Clancy's..." -> "tom-clancys-..."
static NSString *TWCategorySlug(NSString *name)
{
    NSMutableString *slug = [NSMutableString string];
    NSString *lower = [name lowercaseString];
    BOOL dash = NO;
    for (NSUInteger i = 0; i < lower.length; i++) {
        unichar c = [lower characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) { [slug appendFormat:@"%C", c]; dash = NO; }
        else if ((c == ' ' || c == '-' || c == '_' || c == ':' || c == '/') && slug.length && !dash) { [slug appendString:@"-"]; dash = YES; }
    }
    while ([slug hasSuffix:@"-"]) [slug deleteCharactersInRange:NSMakeRange(slug.length - 1, 1)];
    return slug;
}

// A category by its name (/directory/game/<name>) or its slug (/directory/category/<slug>): the search finds the
// full category (box art, numbers); a name nobody found still opens by name, a slug falls back to the search screen.
+ (void)openCategoryNamed:(NSString *)name slug:(NSString *)slug from:(UIViewController *)controller
{
    NSString *text = name.length ? name : [slug stringByReplacingOccurrencesOfString:@"-" withString:@" "];
    if (!text.length) return;
    __weak UIViewController *weakController = controller;
    [TWGQL search:text completion:^(NSArray *channels, NSArray *games, NSError *error) {
        TWGame *found = nil;
        for (TWGame *g in games) {
            BOOL match = name.length ? ([[g.name lowercaseString] isEqualToString:[name lowercaseString]] || [[g.displayName lowercaseString] isEqualToString:[name lowercaseString]])
                                     : ([TWCategorySlug(g.name) isEqualToString:slug] || [TWCategorySlug(g.displayName) isEqualToString:slug]);
            if (match) { found = g; break; }
        }
        if (!found && name.length) {
            found = [[TWGame alloc] init];
            found.name = name;
            found.displayName = name;
        }
        if (found) {
            [TWNavigator openGame:found from:weakController];
        } else {
            UIViewController *root = [UIApplication sharedApplication].keyWindow.rootViewController;
            if ([root isKindOfClass:[TWRootViewController class]]) [(TWRootViewController *)root searchFor:text];
        }
    }];
}

static BOOL TWIsLogin(NSString *s)
{
    if (s.length < 1 || s.length > 25) return NO;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        BOOL ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
        if (!ok) return NO;
    }
    return YES;
}

static BOOL TWIsSlug(NSString *s)
{
    if (s.length < 3 || s.length > 120) return NO;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        BOOL ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-';
        if (!ok) return NO;
    }
    return YES;
}

// "123456789" or the old "v123456789"
static NSString *TWVideoIdIn(NSString *s)
{
    if ([s hasPrefix:@"v"] && s.length > 1) s = [s substringFromIndex:1];
    if (!s.length || s.length > 20) return nil;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c < '0' || c > '9') return nil;
    }
    return s;
}

+ (BOOL)openTwitchURL:(NSURL *)url
{
    return [self openTwitchURL:url from:nil];
}

+ (BOOL)openTwitchURL:(NSURL *)url from:(UIViewController *)controller
{
    NSString *scheme = [url.scheme lowercaseString];
    NSString *host = [url.host lowercaseString];
    if (!host.length || !([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) return NO;
    if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
    BOOL clipsHost = [host isEqualToString:@"clips.twitch.tv"];
    if (!clipsHost && ![host isEqualToString:@"twitch.tv"] && ![host isEqualToString:@"m.twitch.tv"] && ![host isEqualToString:@"go.twitch.tv"]) return NO;
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *p in [url.path componentsSeparatedByString:@"/"]) {   // (NSURL decodes the percent escapes of .path)
        if (p.length) [parts addObject:p];
    }
    NSDictionary *query = url.query.length ? [TWUtils parseQuery:url.query] : @{};

    if (clipsHost) {
        // clips.twitch.tv/<slug>, clips.twitch.tv/embed?clip=<slug>
        NSString *slug = [[parts.firstObject lowercaseString] isEqualToString:@"embed"] ? query[@"clip"] : parts.firstObject;
        if (!TWIsSlug(slug)) return NO;
        [self openClipSlug:slug from:controller];
        return YES;
    }
    if (!parts.count) return NO;   // the front page
    NSString *first = [parts[0] lowercaseString];
    NSString *second = parts.count > 1 ? parts[1] : nil;
    NSString *third = parts.count > 2 ? parts[2] : nil;

    if ([first isEqualToString:@"videos"]) {
        // twitch.tv/videos/<id>
        NSString *videoId = TWVideoIdIn(second);
        if (!videoId) return NO;
        [self openVideoId:videoId from:controller];
        return YES;
    }
    if ([first isEqualToString:@"clip"]) {
        // m.twitch.tv/clip/<slug>
        if (!TWIsSlug(second)) return NO;
        [self openClipSlug:second from:controller];
        return YES;
    }
    if ([first isEqualToString:@"directory"]) {
        // twitch.tv/directory/game/<name>, twitch.tv/directory/category/<slug>
        NSString *kind = [second lowercaseString];
        if (!third.length) return NO;
        if ([kind isEqualToString:@"game"]) { [self openCategoryNamed:third slug:nil from:controller]; return YES; }
        if ([kind isEqualToString:@"category"]) { [self openCategoryNamed:nil slug:[third lowercaseString] from:controller]; return YES; }
        return NO;
    }
    if ([first isEqualToString:@"search"]) {
        NSString *term = query[@"term"] ?: query[@"q"];
        if (!term.length) return NO;
        UIViewController *root = [UIApplication sharedApplication].keyWindow.rootViewController;
        if (![root isKindOfClass:[TWRootViewController class]]) return NO;
        [(TWRootViewController *)root searchFor:term];
        return YES;
    }
    if ([first isEqualToString:@"popout"] || [first isEqualToString:@"embed"]) {
        // twitch.tv/popout/<login>/chat
        if (!TWIsLogin(second)) return NO;
        [self openChannelLogin:[second lowercaseString] from:controller];
        return YES;
    }
    // pages of the site that are no channel
    static NSSet *reserved;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        reserved = [NSSet setWithArray:@[ @"p", @"settings", @"downloads", @"jobs", @"turbo", @"prime", @"store", @"products", @"subs",
                                          @"subscriptions", @"friends", @"inventory", @"wallet", @"drops", @"payments", @"messages", @"moderator",
                                          @"dashboard", @"login", @"signup", @"activate", @"team", @"collections", @"event", @"events",
                                          @"creatorcamp", @"bits", @"legal", @"security", @"user", @"broadcast", @"manager", @"privacy", @"about",
                                          @"careers", @"partner", @"affiliate", @"redeem", @"gift", @"following", @"year" ]];
    });
    if ([reserved containsObject:first] || !TWIsLogin(first)) return NO;
    NSString *login = first;
    NSString *kind = [second lowercaseString];
    if (([kind isEqualToString:@"video"] || [kind isEqualToString:@"v"]) && third.length) {
        // twitch.tv/<login>/video/<id>
        NSString *videoId = TWVideoIdIn(third);
        if (!videoId) return NO;
        [self openVideoId:videoId from:controller];
        return YES;
    }
    if ([kind isEqualToString:@"clip"] && third.length) {
        // twitch.tv/<login>/clip/<slug>
        if (!TWIsSlug(third)) return NO;
        [self openClipSlug:third from:controller];
        return YES;
    }
    // twitch.tv/<login>, and its /videos, /clips, /about, /schedule pages: the channel page
    [self openChannelLogin:login from:controller];
    return YES;
}

@end
