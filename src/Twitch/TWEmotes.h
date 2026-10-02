#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, TWEmoteProvider) {
    TWEmoteProviderTwitch = 0,
    TWEmoteProviderBTTV,
    TWEmoteProviderFFZ,
    TWEmoteProvider7TV,
};

@interface TWEmote : NSObject
@property (nonatomic, copy) NSString *name;        // the word in the chat
@property (nonatomic, copy) NSString *emoteId;
@property (nonatomic, copy) NSString *url1x;
@property (nonatomic, copy) NSString *url2x;
@property (nonatomic) NSInteger width;             // points at 1x (28 x 28 when unknown)
@property (nonatomic) NSInteger height;
@property (nonatomic) BOOL animated;
@property (nonatomic) BOOL zeroWidth;              // drawn over the emote before it (7TV)
@property (nonatomic) TWEmoteProvider provider;
- (NSString *)urlForScale:(CGFloat)scale;          // 1x or 2x, as the screen needs
- (NSString *)providerName;                        // "Twitch", "BetterTTV", "FrankerFaceZ", "7TV"
@end

// Posted on the main thread when emotes or badges arrived (a chat redraws)
extern NSString * const TWEmotesDidChangeNotification;

// Emotes and badges of Twitch and the third-party services (BetterTTV, FrankerFaceZ, 7TV). Lookups are safe from
// any thread; loading happens on the main thread.
@interface TWEmoteStore : NSObject

+ (instancetype)shared;

- (void)loadGlobalsIfNeeded;                                        // global emote sets and badges, once
- (void)loadChannel:(NSString *)channelId login:(NSString *)login;  // the sets and badges of a channel (one at a time)
- (void)reloadUserEmotes;                                           // the logged-in user's Twitch emotes (for the picker)

// Third-party emote for a word (channel sets first, then global), nil for an ordinary word
- (TWEmote *)thirdPartyEmoteNamed:(NSString *)word channelId:(NSString *)channelId;
// A Twitch emote by id (from the chat tags); animated when the setting allows it and the emote has an animation
+ (TWEmote *)twitchEmoteWithId:(NSString *)emoteId name:(NSString *)name animated:(BOOL)animated;
// The image of a badge, nil when unknown; `set/version` as in the chat tags
- (NSString *)badgeURLForSet:(NSString *)set version:(NSString *)version channelId:(NSString *)channelId scale2x:(BOOL)retina;

// For the emote picker: sections of @{ @"title": ..., @"emotes": @[TWEmote] }
- (NSArray *)pickerSectionsForChannelId:(NSString *)channelId;

@end
