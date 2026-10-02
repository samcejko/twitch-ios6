#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>
#import "TWChatMessage.h"

// Everything the layout of a chat line depends on, captured on the main thread so that layouts can be made anywhere
@interface TWChatStyle : NSObject
@property (nonatomic) CGFloat fontSize;
@property (nonatomic) CGFloat width;                  // the text width available to a line
@property (nonatomic) CGFloat screenScale;
@property (nonatomic) BOOL showTimestamps;
@property (nonatomic) BOOL animatedEmotes;
@property (nonatomic) BOOL thirdPartyEmotes;
@property (nonatomic) BOOL showDeleted;
@property (nonatomic) BOOL dark;
@property (nonatomic, copy) NSString *channelId;
@property (nonatomic, strong) UIColor *textColor;
@property (nonatomic, strong) UIColor *systemColor;
@property (nonatomic, strong) UIColor *deletedColor;
@property (nonatomic, strong) UIColor *linkColor;
@property (nonatomic) NSUInteger version;             // changes whenever any of this changes
+ (instancetype)currentStyleForWidth:(CGFloat)width channelId:(NSString *)channelId;   // main thread
- (CGFloat)emoteHeight;
- (CGFloat)badgeSize;
@end

// Where an image (badge or emote) goes in a laid-out line
@interface TWChatImageSlot : NSObject
@property (nonatomic) CGRect frame;                   // in the layout's coordinates (origin top left)
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *name;           // the emote's word (badges: the set)
@property (nonatomic) BOOL animated;
@end

// A tappable link in the text
@interface TWChatLink : NSObject
@property (nonatomic, copy) NSString *url;
@property (nonatomic) NSRange range;
@end

// One chat entry laid out with Core Text for a given width: the text (drawn with -drawInContext:), the places of
// its images, the links. Made once per message and width, kept in TWChatMessage.layout.
@interface TWChatLayout : NSObject
@property (nonatomic, readonly) CGFloat height;
@property (nonatomic, readonly) CGFloat width;
@property (nonatomic, readonly, strong) NSArray *imageSlots;    // TWChatImageSlot
@property (nonatomic, readonly, strong) NSArray *links;         // TWChatLink
@property (nonatomic, readonly) NSRange nameRange;              // the author's name in the string (for taps)
@property (nonatomic, readonly, strong) NSAttributedString *string;

+ (TWChatLayout *)layoutForMessage:(TWChatMessage *)message style:(TWChatStyle *)style;   // any thread
+ (TWChatLayout *)cachedLayoutForMessage:(TWChatMessage *)message style:(TWChatStyle *)style;   // makes it when missing

- (void)drawInContext:(CGContextRef)context;          // UIKit coordinates, origin top left
- (NSInteger)stringIndexAtPoint:(CGPoint)point;      // NSNotFound when off the text
- (TWChatLink *)linkAtPoint:(CGPoint)point;
- (BOOL)isNameAtPoint:(CGPoint)point;

@end
