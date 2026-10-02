#import <UIKit/UIKit.h>
#import "TWModels.h"

// A live stream in a grid: the "card" (thumbnail on top, texts below) on wide screens, a row (thumbnail on the left)
// on narrow ones. Also used for channels that are offline (the offline picture, no live badge).
@interface TWStreamCell : UICollectionViewCell
+ (NSString *)reuseIdentifier;
+ (CGFloat)rowHeightForWidth:(CGFloat)width;              // row layout (narrow)
+ (CGFloat)cardHeightForWidth:(CGFloat)width;             // card layout
- (void)configureWithStream:(TWStream *)stream asCard:(BOOL)card;
- (void)configureWithChannel:(TWChannel *)channel asCard:(BOOL)card;   // offline channel
- (void)applyTheme;
@end

// A category in a grid: box art with the name and the viewer count below
@interface TWGameCell : UICollectionViewCell
+ (NSString *)reuseIdentifier;
+ (CGFloat)heightForWidth:(CGFloat)width;
- (void)configureWithGame:(TWGame *)game;
- (void)applyTheme;
@end

// A video or a clip in a list (table): thumbnail with the length, title, name/game, views and age
@interface TWVideoCell : UITableViewCell
+ (NSString *)reuseIdentifier;
+ (CGFloat)height;
- (void)configureWithVideo:(TWVideo *)video;
- (void)configureWithClip:(TWClip *)clip;
@end

// A channel in a list: round avatar, name, a live dot with the game or "offline"
@interface TWChannelCell : UITableViewCell
+ (NSString *)reuseIdentifier;
+ (CGFloat)height;
- (void)configureWithChannel:(TWChannel *)channel;
- (void)configureWithLogin:(NSString *)login displayName:(NSString *)name avatarURL:(NSString *)avatar detail:(NSString *)detail;
@end
