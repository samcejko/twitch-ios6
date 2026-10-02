#import "TWNavigator.h"
#import "TWPlayerViewController.h"
#import "TWChannelViewController.h"
#import "TWGameViewController.h"
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

@end
