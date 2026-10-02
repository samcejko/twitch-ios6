#import "TWModels.h"
#import "TWCommon.h"

static NSString *TWJoinedName(NSString *displayName, NSString *login)
{
    if (!displayName.length) return login ?: @"";
    if (!login.length || [[displayName lowercaseString] isEqualToString:[login lowercaseString]]) return displayName;
    return [NSString stringWithFormat:@"%@ (%@)", displayName, login];
}

@implementation TWStream

+ (instancetype)streamFromGQL:(NSDictionary *)node broadcaster:(NSDictionary *)broadcaster
{
    node = TWDict(node);
    if (!node) return nil;
    NSDictionary *user = TWDict(broadcaster) ?: TWDict(node[@"broadcaster"]);
    TWStream *s = [[TWStream alloc] init];
    s.streamId = TWStr(node[@"id"]);
    s.title = [TWStr(node[@"title"]) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    s.viewers = TWInt(node[@"viewersCount"]);
    s.startedAt = TWDateFromISO(TWStr(node[@"createdAt"]));
    s.language = [TWStr(node[@"language"]) lowercaseString];
    s.login = [TWStr(user[@"login"]) lowercaseString];
    s.displayName = TWStr(user[@"displayName"]) ?: s.login;
    s.userId = TWStr(user[@"id"]);
    s.avatarURL = TWStr(user[@"profileImageURL"]);
    NSDictionary *game = TWDict(node[@"game"]);
    s.gameId = TWStr(game[@"id"]);
    s.gameName = TWStr(game[@"displayName"]) ?: TWStr(game[@"name"]);
    NSMutableArray *tags = [NSMutableArray array];
    for (id tag in TWArr(node[@"freeformTags"])) {
        NSString *name = TWStr(TWDict(tag)[@"name"]);
        if (name.length) [tags addObject:name];
    }
    s.tags = tags;
    if (!s.login.length) return nil;   // (a stream whose broadcaster is gone: nothing to open)
    return s;
}

+ (instancetype)streamFromHelix:(NSDictionary *)item
{
    item = TWDict(item);
    if (!item) return nil;
    TWStream *s = [[TWStream alloc] init];
    s.streamId = TWStr(item[@"id"]);
    s.title = [TWStr(item[@"title"]) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    s.viewers = TWInt(item[@"viewer_count"]);
    s.startedAt = TWDateFromISO(TWStr(item[@"started_at"]));
    s.language = [TWStr(item[@"language"]) lowercaseString];
    s.login = [TWStr(item[@"user_login"]) lowercaseString];
    s.displayName = TWStr(item[@"user_name"]) ?: s.login;
    s.userId = TWStr(item[@"user_id"]);
    s.gameId = TWStr(item[@"game_id"]);
    s.gameName = TWStr(item[@"game_name"]);
    NSMutableArray *tags = [NSMutableArray array];
    for (id tag in TWArr(item[@"tags"])) {
        if ([tag isKindOfClass:[NSString class]] && [tag length]) [tags addObject:tag];
    }
    s.tags = tags;
    if (!s.login.length) return nil;
    return s;
}

- (NSString *)nameForDisplay
{
    return TWJoinedName(self.displayName, self.login);
}

- (NSString *)previewURLWithWidth:(NSInteger)width height:(NSInteger)height
{
    if (!self.login.length) return nil;
    // (the picture behind this address changes every few minutes: the stamp makes the image cache notice)
    long stamp = (long)([[NSDate date] timeIntervalSince1970] / 300.0);
    return [NSString stringWithFormat:@"https://static-cdn.jtvnw.net/previews-ttv/live_user_%@-%ldx%ld.jpg?t=%ld",
            self.login, (long)width, (long)height, stamp];
}

@end

@implementation TWGame

+ (instancetype)gameFromGQL:(NSDictionary *)node
{
    node = TWDict(node);
    if (!node) return nil;
    TWGame *g = [[TWGame alloc] init];
    g.gameId = TWStr(node[@"id"]);
    g.name = TWStr(node[@"name"]);
    g.displayName = TWStr(node[@"displayName"]) ?: g.name;
    g.boxArtURL = TWStr(node[@"boxArtURL"]);
    g.viewers = TWInt(node[@"viewersCount"]);
    g.channels = TWInt(node[@"broadcastersCount"]);
    if (!g.gameId.length && !g.name.length) return nil;
    return g;
}

- (NSString *)title
{
    return self.displayName.length ? self.displayName : (self.name ?: @"");
}

@end

@implementation TWChannel

+ (instancetype)channelFromGQL:(NSDictionary *)user
{
    user = TWDict(user);
    if (!user) return nil;
    TWChannel *c = [[TWChannel alloc] init];
    c.userId = TWStr(user[@"id"]);
    c.login = [TWStr(user[@"login"]) lowercaseString];
    c.displayName = TWStr(user[@"displayName"]) ?: c.login;
    c.bio = [TWStr(user[@"description"]) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    c.avatarURL = TWStr(user[@"profileImageURL"]);
    c.bannerURL = TWStr(user[@"bannerImageURL"]);
    c.offlineImageURL = TWStr(user[@"offlineImageURL"]);
    c.createdAt = TWDateFromISO(TWStr(user[@"createdAt"]));
    c.followers = TWInt(TWDict(user[@"followers"])[@"totalCount"]);
    NSDictionary *roles = TWDict(user[@"roles"]);
    c.isPartner = TWBool(roles[@"isPartner"]);
    c.isAffiliate = TWBool(roles[@"isAffiliate"]);
    NSDictionary *last = TWDict(user[@"lastBroadcast"]);
    c.lastBroadcastAt = TWDateFromISO(TWStr(last[@"startedAt"]));
    c.lastBroadcastTitle = TWStr(last[@"title"]);
    NSDictionary *lastGame = TWDict(last[@"game"]);
    c.lastGameName = TWStr(lastGame[@"displayName"]) ?: TWStr(lastGame[@"name"]);
    NSDictionary *stream = TWDict(user[@"stream"]);
    if (stream) c.stream = [TWStream streamFromGQL:stream broadcaster:user];
    if (!c.login.length) return nil;
    return c;
}

- (NSString *)nameForDisplay
{
    return TWJoinedName(self.displayName, self.login);
}

- (BOOL)isLive
{
    return self.stream != nil;
}

@end

@implementation TWVideo

+ (instancetype)videoFromGQL:(NSDictionary *)node
{
    node = TWDict(node);
    if (!node) return nil;
    TWVideo *v = [[TWVideo alloc] init];
    v.videoId = TWStr(node[@"id"]);
    v.title = [TWStr(node[@"title"]) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    v.length = TWDbl(node[@"lengthSeconds"]);
    v.views = TWInt(node[@"viewCount"]);
    v.publishedAt = TWDateFromISO(TWStr(node[@"publishedAt"])) ?: TWDateFromISO(TWStr(node[@"createdAt"]));
    v.broadcastType = TWStr(node[@"broadcastType"]);
    v.previewURL = TWStr(node[@"previewThumbnailURL"]);
    NSDictionary *game = TWDict(node[@"game"]);
    v.gameName = TWStr(game[@"displayName"]) ?: TWStr(game[@"name"]);
    NSDictionary *owner = TWDict(node[@"owner"]);
    v.ownerLogin = [TWStr(owner[@"login"]) lowercaseString];
    v.ownerName = TWStr(owner[@"displayName"]) ?: v.ownerLogin;
    if (!v.videoId.length) return nil;
    return v;
}

@end

@implementation TWClip

+ (instancetype)clipFromGQL:(NSDictionary *)node
{
    node = TWDict(node);
    if (!node) return nil;
    TWClip *c = [[TWClip alloc] init];
    c.slug = TWStr(node[@"slug"]);
    c.title = [TWStr(node[@"title"]) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    c.views = TWInt(node[@"viewCount"]);
    c.duration = TWDbl(node[@"durationSeconds"]);
    c.createdAt = TWDateFromISO(TWStr(node[@"createdAt"]));
    // (the API hands out the full-size picture whatever size was asked for; the CDN has a small one under the same name)
    c.thumbnailURL = [TWStr(node[@"thumbnailURL"]) stringByReplacingOccurrencesOfString:@"-1920x1080." withString:@"-480x272."];
    c.curatorName = TWStr(TWDict(node[@"curator"])[@"displayName"]);
    NSDictionary *game = TWDict(node[@"game"]);
    c.gameName = TWStr(game[@"displayName"]) ?: TWStr(game[@"name"]);
    NSDictionary *broadcaster = TWDict(node[@"broadcaster"]);
    c.broadcasterLogin = [TWStr(broadcaster[@"login"]) lowercaseString];
    c.broadcasterName = TWStr(broadcaster[@"displayName"]) ?: c.broadcasterLogin;
    if (!c.slug.length) return nil;
    return c;
}

@end
