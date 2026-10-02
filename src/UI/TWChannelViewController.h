#import <UIKit/UIKit.h>
#import "TWVideoListViewController.h"
#import "TWModels.h"

// A channel: banner, avatar, name, followers, description, "Watch" when live, the star for the favourites, and
// below the segmented list of past broadcasts, highlights and clips.
@interface TWChannelViewController : TWVideoListViewController
- (instancetype)initWithLogin:(NSString *)login;
@property (nonatomic, readonly, copy) NSString *login;
@property (nonatomic) BOOL showsDoneButton;   // when presented modally (from the player)
@end
