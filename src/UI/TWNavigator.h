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

// The controller to present modal screens from (the top of the current stack)
+ (UIViewController *)presenterFrom:(UIViewController *)controller;

@end
