#import <Foundation/Foundation.h>

// Plain model objects filled from Twitch's answers (GQL and Helix). Missing fields stay nil / 0.

@interface TWStream : NSObject
@property (nonatomic, copy) NSString *streamId;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *login;            // channel name as in URLs and in chat (lower case)
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *userId;
@property (nonatomic, copy) NSString *avatarURL;
@property (nonatomic, copy) NSString *gameId;
@property (nonatomic, copy) NSString *gameName;
@property (nonatomic, copy) NSString *language;         // lower case code, when known
@property (nonatomic, copy) NSString *cursor;
@property (nonatomic, strong) NSArray *tags;            // names
@property (nonatomic, strong) NSDate *startedAt;
@property (nonatomic) NSInteger viewers;

// A node of streams{} / game.streams{} (carries its broadcaster), or user.stream with the user passed separately
+ (instancetype)streamFromGQL:(NSDictionary *)node broadcaster:(NSDictionary *)broadcaster;
+ (instancetype)streamFromHelix:(NSDictionary *)item;   // helix/streams
- (NSString *)nameForDisplay;                           // the display name; with the login when they differ (localized names)
- (NSString *)previewURLWithWidth:(NSInteger)width height:(NSInteger)height;   // refreshed by Twitch every few minutes
@end

@interface TWGame : NSObject
@property (nonatomic, copy) NSString *gameId;
@property (nonatomic, copy) NSString *name;             // the name the API looks categories up by
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *boxArtURL;
@property (nonatomic, copy) NSString *cursor;
@property (nonatomic) NSInteger viewers;
@property (nonatomic) NSInteger channels;
+ (instancetype)gameFromGQL:(NSDictionary *)node;
- (NSString *)title;
@end

@interface TWChannel : NSObject
@property (nonatomic, copy) NSString *userId;
@property (nonatomic, copy) NSString *login;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *bio;
@property (nonatomic, copy) NSString *avatarURL;
@property (nonatomic, copy) NSString *bannerURL;
@property (nonatomic, copy) NSString *offlineImageURL;
@property (nonatomic, copy) NSString *lastBroadcastTitle;
@property (nonatomic, copy) NSString *lastGameName;
@property (nonatomic, strong) NSDate *lastBroadcastAt;
@property (nonatomic, strong) NSDate *createdAt;
@property (nonatomic, strong) TWStream *stream;         // nil when offline
@property (nonatomic) NSInteger followers;
@property (nonatomic) BOOL isPartner;
@property (nonatomic) BOOL isAffiliate;
+ (instancetype)channelFromGQL:(NSDictionary *)user;
- (NSString *)nameForDisplay;
- (BOOL)isLive;
@end

@interface TWVideo : NSObject
@property (nonatomic, copy) NSString *videoId;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *previewURL;
@property (nonatomic, copy) NSString *gameName;
@property (nonatomic, copy) NSString *broadcastType;    // ARCHIVE, HIGHLIGHT, UPLOAD
@property (nonatomic, copy) NSString *ownerLogin;
@property (nonatomic, copy) NSString *ownerName;
@property (nonatomic, copy) NSString *cursor;
@property (nonatomic, strong) NSDate *publishedAt;
@property (nonatomic) NSTimeInterval length;
@property (nonatomic) NSInteger views;
+ (instancetype)videoFromGQL:(NSDictionary *)node;
@end

@interface TWClip : NSObject
@property (nonatomic, copy) NSString *slug;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *thumbnailURL;
@property (nonatomic, copy) NSString *curatorName;
@property (nonatomic, copy) NSString *gameName;
@property (nonatomic, copy) NSString *broadcasterLogin;
@property (nonatomic, copy) NSString *broadcasterName;
@property (nonatomic, copy) NSString *cursor;
@property (nonatomic, strong) NSDate *createdAt;
@property (nonatomic) NSTimeInterval duration;
@property (nonatomic) NSInteger views;
+ (instancetype)clipFromGQL:(NSDictionary *)node;
@end
