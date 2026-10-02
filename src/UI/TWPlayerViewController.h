#import <UIKit/UIKit.h>
#import "TWModels.h"

// Watching: a live channel with its chat, a past broadcast with the chat replay, or a clip. Presented full screen.
@interface TWPlayerViewController : UIViewController

- (instancetype)initWithChannelLogin:(NSString *)login stream:(TWStream *)stream;   // stream may be nil (looked up)
- (instancetype)initWithVideo:(TWVideo *)video;
- (instancetype)initWithClip:(TWClip *)clip;

// Another player takes this screen's place (a channel opened from inside the player)
- (void)replaceWithPlayer:(TWPlayerViewController *)player;

@end
