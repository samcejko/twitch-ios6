#import <Foundation/Foundation.h>
#import "TWHTTP.h"

// The official Twitch API, for what needs the login: followed channels, sending chat messages, the user's emotes.
// A 401 refreshes the token and tries once more. Completion blocks run on the main thread.
@interface TWHelix : NSObject

+ (TWHTTPTask *)get:(NSString *)path params:(NSDictionary *)params completion:(void (^)(NSDictionary *json, NSError *error))completion;
+ (TWHTTPTask *)post:(NSString *)path object:(id)object completion:(void (^)(NSDictionary *json, NSError *error))completion;

// Live channels the user follows (TWStream, most viewers first; all pages)
+ (TWHTTPTask *)followedStreams:(void (^)(NSArray *streams, NSError *error))completion;
// Every channel the user follows: @{ @"login", @"name", @"id", @"followedAt" } (all pages, newest follow first)
+ (TWHTTPTask *)followedChannels:(void (^)(NSArray *channels, NSError *error))completion;

// Sends a chat message as the user. messageId is set when Twitch accepted it; dropReason tells why it did not
// (followers-only mode, AutoMod...) when the request itself went through.
+ (TWHTTPTask *)sendChatMessage:(NSString *)text toBroadcaster:(NSString *)broadcasterId replyTo:(NSString *)parentMessageId
                     completion:(void (^)(NSString *messageId, NSString *dropReason, NSError *error))completion;

// The emotes the user may use: @{ @"id", @"name", @"animated" (NSNumber), @"setId", @"ownerId", @"type" } (all pages)
+ (TWHTTPTask *)userEmotes:(void (^)(NSArray *emotes, NSError *error))completion;

@end
