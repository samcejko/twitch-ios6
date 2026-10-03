#import <Foundation/Foundation.h>
#import "TWHTTP.h"
#import "TWModels.h"

// One page of a list: the items, and the cursor for the next page (nil = that was the last one)
typedef void (^TWListCompletion)(NSArray *items, NSString *nextCursor, NSError *error);

// Clip periods
extern NSString * const TWClipPeriodDay;
extern NSString * const TWClipPeriodWeek;
extern NSString * const TWClipPeriodMonth;
extern NSString * const TWClipPeriodAll;

// Video types (nil = every type)
extern NSString * const TWVideoTypeArchive;
extern NSString * const TWVideoTypeHighlight;
extern NSString * const TWVideoTypeUpload;

// Twitch's GraphQL API as an anonymous visitor: everything the app shows without a login.
// Completion blocks run on the main thread; a cancelled task never calls back.
@interface TWGQL : NSObject

+ (TWHTTPTask *)query:(NSString *)query variables:(NSDictionary *)variables
           completion:(void (^)(NSDictionary *data, NSError *error))completion;

// Browsing (TWStream / TWGame items). The language filter of the settings applies to streams.
+ (TWHTTPTask *)topStreamsAfter:(NSString *)cursor completion:(TWListCompletion)completion;
+ (TWHTTPTask *)topGamesAfter:(NSString *)cursor completion:(TWListCompletion)completion;
+ (TWHTTPTask *)streamsForGame:(TWGame *)game after:(NSString *)cursor completion:(TWListCompletion)completion;
+ (TWHTTPTask *)clipsForGame:(TWGame *)game period:(NSString *)period after:(NSString *)cursor completion:(TWListCompletion)completion;

// Search: TWChannel and TWGame items
+ (TWHTTPTask *)search:(NSString *)text completion:(void (^)(NSArray *channels, NSArray *games, NSError *error))completion;

// Channels
+ (TWHTTPTask *)channel:(NSString *)login completion:(void (^)(TWChannel *channel, NSError *error))completion;
// Several at once (the favourites): channels that do not exist any more are left out
+ (TWHTTPTask *)channels:(NSArray *)logins completion:(void (^)(NSArray *channels, NSError *error))completion;
+ (TWHTTPTask *)videosForChannel:(NSString *)login type:(NSString *)type after:(NSString *)cursor completion:(TWListCompletion)completion;
+ (TWHTTPTask *)clipsForChannel:(NSString *)login period:(NSString *)period after:(NSString *)cursor completion:(TWListCompletion)completion;
+ (TWHTTPTask *)video:(NSString *)videoId completion:(void (^)(TWVideo *video, NSError *error))completion;
+ (TWHTTPTask *)clip:(NSString *)slug completion:(void (^)(TWClip *clip, NSError *error))completion;

// Playback
+ (TWHTTPTask *)streamAccessToken:(NSString *)login completion:(void (^)(NSString *token, NSString *signature, NSError *error))completion;
+ (TWHTTPTask *)videoAccessToken:(NSString *)videoId completion:(void (^)(NSString *token, NSString *signature, NSError *error))completion;
// @[ @{ @"quality": @"720", @"fps": @60, @"url": signed MP4 URL }, ... ], the best first
+ (TWHTTPTask *)clipSources:(NSString *)slug completion:(void (^)(NSArray *sources, NSError *error))completion;

// Chat: badge images, "set/version" -> URL of the 18 px image (the last path component is the scale: 1, 2, 3)
+ (TWHTTPTask *)globalBadges:(void (^)(NSDictionary *badges, NSError *error))completion;
+ (TWHTTPTask *)channelBadges:(NSString *)login completion:(void (^)(NSDictionary *badges, NSError *error))completion;

// Chat replay of a video: the comments from `seconds` on, as dictionaries
// { id, offset (NSNumber), login, displayName, color, badges (@[@[set, version]]), fragments (@[@{text, emoteId?}]) }
+ (TWHTTPTask *)commentsForVideo:(NSString *)videoId offset:(NSInteger)seconds
                      completion:(void (^)(NSArray *comments, BOOL hasMore, NSError *error))completion;

@end
