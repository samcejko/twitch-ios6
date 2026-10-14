#import <UIKit/UIKit.h>
#import "TWModels.h"

// Opening things from anywhere in the app: the player (full screen), channel and category pages (pushed)
@interface TWNavigator : NSObject

+ (void)openStream:(TWStream *)stream from:(UIViewController *)controller;
+ (void)openChannelLogin:(NSString *)login from:(UIViewController *)controller;   // the channel page
+ (void)watchChannelLogin:(NSString *)login from:(UIViewController *)controller;  // the player, straight away
+ (void)openGame:(TWGame *)game from:(UIViewController *)controller;
+ (void)openVideo:(TWVideo *)video from:(UIViewController *)controller;
+ (void)openClip:(TWClip *)clip from:(UIViewController *)controller;
// By id or slug alone: the details are looked up first (the URL scheme, links in texts)
+ (void)openVideoId:(NSString *)videoId from:(UIViewController *)controller;
+ (void)openClipSlug:(NSString *)slug from:(UIViewController *)controller;

// A link to twitch.tv (also www., m. and clips.twitch.tv) opened inside the app: twitch.tv/<login> (and its
// /videos, /clips, /about pages) is the channel page, /videos/<id> and /<login>/video/<id> a past broadcast,
// clips.twitch.tv/<slug> and /<login>/clip/<slug> a clip, /directory/game/<name> and /directory/category/<slug> a
// category, /search?term= the search. NO when the address is anything else (a page the app has no screen for).
+ (BOOL)openTwitchURL:(NSURL *)url from:(UIViewController *)controller;
+ (BOOL)openTwitchURL:(NSURL *)url;   // from the top of the current stack (twitcher:open?url=)

// The controller to present modal screens from (the top of the current stack)
+ (UIViewController *)presenterFrom:(UIViewController *)controller;

@end
