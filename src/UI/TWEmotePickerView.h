#import <UIKit/UIKit.h>
#import "TWEmotes.h"

@class TWEmotePickerView;

@protocol TWEmotePickerDelegate <NSObject>
- (void)emotePicker:(TWEmotePickerView *)picker didPickEmote:(TWEmote *)emote;
@end

// A grid of emotes in sections (the user's Twitch emotes, the channel's, the global ones), shown in place of the
// keyboard
@interface TWEmotePickerView : UIView
@property (nonatomic, weak) id<TWEmotePickerDelegate> delegate;
+ (CGFloat)preferredHeight;
- (void)reloadWithChannelId:(NSString *)channelId;
- (void)applyTheme;
@end
