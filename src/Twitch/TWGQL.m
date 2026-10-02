#import "TWGQL.h"
#import "TWConfig.h"
#import "TWSettings.h"
#import "TWUtils.h"
#import "TWCommon.h"

NSString * const TWClipPeriodDay   = @"LAST_DAY";
NSString * const TWClipPeriodWeek  = @"LAST_WEEK";
NSString * const TWClipPeriodMonth = @"LAST_MONTH";
NSString * const TWClipPeriodAll   = @"ALL_TIME";

NSString * const TWVideoTypeArchive   = @"ARCHIVE";
NSString * const TWVideoTypeHighlight = @"HIGHLIGHT";
NSString * const TWVideoTypeUpload    = @"UPLOAD";

static const NSInteger TWStreamPageSize = 30;
static const NSInteger TWGamePageSize = 40;
static const NSInteger TWVideoPageSize = 20;

// Every query below is one line on purpose: tools/check-gql.ps1 runs them against the live API as they are.

#define TW_STREAM_FIELDS @"id title type viewersCount createdAt broadcaster { id login displayName profileImageURL(width: 70) } game { id name displayName } freeformTags { name }"
#define TW_GAME_FIELDS @"id name displayName viewersCount broadcastersCount boxArtURL(width: 188, height: 250)"
#define TW_VIDEO_FIELDS @"id title lengthSeconds viewCount publishedAt broadcastType previewThumbnailURL(width: 320, height: 180) game { displayName } owner { id login displayName }"
#define TW_CLIP_FIELDS @"id slug title viewCount durationSeconds createdAt thumbnailURL(width: 480, height: 272) curator { displayName } game { displayName } broadcaster { login displayName }"
#define TW_PLAYER_PARAMS @"params: { platform: \"web\", playerBackend: \"mediaplayer\", playerType: \"site\" }"

static NSString * const TWQueryTopStreams =
    @"query($first: Int!, $after: Cursor, $options: StreamOptions) { streams(first: $first, after: $after, options: $options) { pageInfo { hasNextPage } edges { cursor node { " TW_STREAM_FIELDS @" } } } }";

static NSString * const TWQueryTopGames =
    @"query($first: Int!, $after: Cursor) { games(first: $first, after: $after) { pageInfo { hasNextPage } edges { cursor node { " TW_GAME_FIELDS @" } } } }";

static NSString * const TWQueryGameStreams =
    @"query($id: ID, $name: String, $first: Int!, $after: Cursor, $options: GameStreamOptions) { game(id: $id, name: $name) { id streams(first: $first, after: $after, options: $options) { pageInfo { hasNextPage } edges { cursor node { " TW_STREAM_FIELDS @" } } } } }";

static NSString * const TWQueryGameClips =
    @"query($id: ID, $name: String, $first: Int!, $after: Cursor, $period: ClipsPeriod!) { game(id: $id, name: $name) { id clips(first: $first, after: $after, criteria: { period: $period }) { pageInfo { hasNextPage } edges { cursor node { " TW_CLIP_FIELDS @" } } } } }";

static NSString * const TWQuerySearch =
    @"query($q: String!) { searchFor(userQuery: $q, platform: \"web\", options: { targets: [ { index: CHANNEL }, { index: GAME } ] }) { channels { edges { item { ... on User { id login displayName description profileImageURL(width: 70) followers { totalCount } stream { id title type viewersCount createdAt game { id name displayName } } } } } } games { edges { item { ... on Game { " TW_GAME_FIELDS @" } } } } } }";

static NSString * const TWQueryChannel =
    @"query($login: String!) { user(login: $login) { id login displayName description createdAt profileImageURL(width: 150) bannerImageURL offlineImageURL roles { isPartner isAffiliate } followers { totalCount } lastBroadcast { startedAt title game { displayName } } stream { id title type viewersCount createdAt game { id name displayName } freeformTags { name } } } }";

static NSString * const TWQueryChannels =
    @"query($logins: [String!]) { users(logins: $logins) { id login displayName profileImageURL(width: 70) lastBroadcast { startedAt title game { displayName } } stream { id title type viewersCount createdAt game { id name displayName } freeformTags { name } } } }";

static NSString * const TWQueryVideos =
    @"query($login: String!, $first: Int!, $after: Cursor, $type: BroadcastType) { user(login: $login) { id videos(first: $first, after: $after, type: $type, sort: TIME) { pageInfo { hasNextPage } edges { cursor node { " TW_VIDEO_FIELDS @" } } } } }";

static NSString * const TWQueryClips =
    @"query($login: String!, $first: Int!, $after: Cursor, $period: ClipsPeriod!) { user(login: $login) { id clips(first: $first, after: $after, criteria: { period: $period }) { pageInfo { hasNextPage } edges { cursor node { " TW_CLIP_FIELDS @" } } } } }";

static NSString * const TWQueryVideo =
    @"query($id: ID!) { video(id: $id) { " TW_VIDEO_FIELDS @" } }";

static NSString * const TWQueryStreamToken =
    @"query($login: String!) { streamPlaybackAccessToken(channelName: $login, " TW_PLAYER_PARAMS @") { value signature } }";

static NSString * const TWQueryVideoToken =
    @"query($id: ID!) { videoPlaybackAccessToken(id: $id, " TW_PLAYER_PARAMS @") { value signature } }";

static NSString * const TWQueryClip =
    @"query($slug: ID!) { clip(slug: $slug) { id slug playbackAccessToken(" TW_PLAYER_PARAMS @") { signature value } videoQualities { frameRate quality sourceURL } } }";

static NSString * const TWQueryGlobalBadges =
    @"query { badges { setID version imageURL(size: NORMAL) } }";

static NSString * const TWQueryChannelBadges =
    @"query($login: String!) { user(login: $login) { id broadcastBadges { setID version imageURL(size: NORMAL) } } }";

static NSString * const TWQueryComments =
    @"query($id: ID!, $offset: Int) { video(id: $id) { id comments(contentOffsetSeconds: $offset) { pageInfo { hasNextPage } edges { node { id contentOffsetSeconds commenter { id login displayName } message { fragments { text emote { emoteID } } userBadges { setID version } userColor } } } } } }";

// The cursor of the next page of a connection: that of its last edge that has one (clips give one only now and then)
static NSString *TWNextCursor(NSDictionary *connection)
{
    if (!TWBool(TWDict(connection[@"pageInfo"])[@"hasNextPage"])) return nil;
    NSString *cursor = nil;
    for (id edge in TWArr(connection[@"edges"])) {
        NSString *c = TWStr(TWDict(edge)[@"cursor"]);
        if (c.length) cursor = c;
    }
    return cursor;
}

@implementation TWGQL

+ (TWHTTPTask *)query:(NSString *)query variables:(NSDictionary *)variables
           completion:(void (^)(NSDictionary *data, NSError *error))completion
{
    NSDictionary *headers = @{ @"Client-ID": TWTwitchWebClientID, @"Content-Type": @"text/plain;charset=UTF-8" };
    NSDictionary *body = @{ @"query": query ?: @"", @"variables": variables ?: @{} };
    // (reads only: asking a second time after a network error is safe)
    return [TWHTTP postJSON:TWTwitchGQLURL headers:headers object:body retries:1 completion:^(id json, NSInteger status, NSError *error) {
        if (!completion) return;
        NSDictionary *root = TWDict(json);
        NSDictionary *data = TWDict(root[@"data"]);
        if (error && !data) { completion(nil, error); return; }
        if (!data) {
            NSString *message = TWStr(TWDict([TWArr(root[@"errors"]) firstObject])[@"message"]);
            completion(nil, TWMakeError(TWErrorAPI, message.length ? message : L(@"Twitch sent an unexpected answer.")));
            return;
        }
        completion(data, nil);
    }];
}

// A page of a connection as model objects
+ (void)finishList:(NSDictionary *)connection make:(id (^)(NSDictionary *node))make completion:(TWListCompletion)completion
{
    NSMutableArray *items = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (id edge in TWArr(connection[@"edges"])) {
        NSDictionary *e = TWDict(edge);
        NSDictionary *node = TWDict(e[@"node"]);
        if (!node) continue;
        NSString *ident = TWStr(node[@"id"]);
        if (ident.length) {
            if ([seen containsObject:ident]) continue;
            [seen addObject:ident];
        }
        id item = make(node);
        if (item) [items addObject:item];
    }
    completion(items, TWNextCursor(connection), nil);
}

+ (NSArray *)languageOption
{
    NSString *language = [TWSettings streamLanguage];
    return language.length ? @[ [language uppercaseString] ] : nil;
}

#pragma mark - Browsing

+ (TWHTTPTask *)topStreamsAfter:(NSString *)cursor completion:(TWListCompletion)completion
{
    NSMutableDictionary *vars = [NSMutableDictionary dictionaryWithDictionary:@{ @"first": @(TWStreamPageSize) }];
    if (cursor.length) vars[@"after"] = cursor;
    NSArray *languages = [self languageOption];
    if (languages) vars[@"options"] = @{ @"broadcasterLanguages": languages };
    return [self query:TWQueryTopStreams variables:vars completion:^(NSDictionary *data, NSError *error) {
        if (error) { completion(nil, nil, error); return; }
        [self finishList:TWDict(data[@"streams"]) make:^id(NSDictionary *node) {
            return [TWStream streamFromGQL:node broadcaster:nil];
        } completion:completion];
    }];
}

+ (TWHTTPTask *)topGamesAfter:(NSString *)cursor completion:(TWListCompletion)completion
{
    NSMutableDictionary *vars = [NSMutableDictionary dictionaryWithDictionary:@{ @"first": @(TWGamePageSize) }];
    if (cursor.length) vars[@"after"] = cursor;
    return [self query:TWQueryTopGames variables:vars completion:^(NSDictionary *data, NSError *error) {
        if (error) { completion(nil, nil, error); return; }
        [self finishList:TWDict(data[@"games"]) make:^id(NSDictionary *node) {
            return [TWGame gameFromGQL:node];
        } completion:completion];
    }];
}

+ (NSMutableDictionary *)variablesForGame:(TWGame *)game
{
    NSMutableDictionary *vars = [NSMutableDictionary dictionary];
    if (game.gameId.length) vars[@"id"] = game.gameId;
    else if (game.name.length) vars[@"name"] = game.name;
    return vars;
}

+ (TWHTTPTask *)streamsForGame:(TWGame *)game after:(NSString *)cursor completion:(TWListCompletion)completion
{
    NSMutableDictionary *vars = [self variablesForGame:game];
    vars[@"first"] = @(TWStreamPageSize);
    if (cursor.length) vars[@"after"] = cursor;
    NSMutableDictionary *options = [NSMutableDictionary dictionaryWithDictionary:@{ @"sort": @"VIEWER_COUNT" }];
    NSArray *languages = [self languageOption];
    if (languages) options[@"broadcasterLanguages"] = languages;
    vars[@"options"] = options;
    return [self query:TWQueryGameStreams variables:vars completion:^(NSDictionary *data, NSError *error) {
        if (error) { completion(nil, nil, error); return; }
        NSDictionary *g = TWDict(data[@"game"]);
        if (!g) { completion(nil, nil, TWMakeError(TWErrorAPI, L(@"This category does not exist any more."))); return; }
        [self finishList:TWDict(g[@"streams"]) make:^id(NSDictionary *node) {
            return [TWStream streamFromGQL:node broadcaster:nil];
        } completion:completion];
    }];
}

+ (TWHTTPTask *)clipsForGame:(TWGame *)game period:(NSString *)period after:(NSString *)cursor completion:(TWListCompletion)completion
{
    NSMutableDictionary *vars = [self variablesForGame:game];
    vars[@"first"] = @(TWVideoPageSize);
    vars[@"period"] = period ?: TWClipPeriodWeek;
    if (cursor.length) vars[@"after"] = cursor;
    return [self query:TWQueryGameClips variables:vars completion:^(NSDictionary *data, NSError *error) {
        if (error) { completion(nil, nil, error); return; }
        [self finishList:TWDict(TWDict(data[@"game"])[@"clips"]) make:^id(NSDictionary *node) {
            return [TWClip clipFromGQL:node];
        } completion:completion];
    }];
}

#pragma mark - Search

+ (TWHTTPTask *)search:(NSString *)text completion:(void (^)(NSArray *channels, NSArray *games, NSError *error))completion
{
    return [self query:TWQuerySearch variables:@{ @"q": text ?: @"" } completion:^(NSDictionary *data, NSError *error) {
        if (error) { completion(nil, nil, error); return; }
        NSDictionary *result = TWDict(data[@"searchFor"]);
        NSMutableArray *channels = [NSMutableArray array], *games = [NSMutableArray array];
        for (id edge in TWArr(TWDict(result[@"channels"])[@"edges"])) {
            TWChannel *c = [TWChannel channelFromGQL:TWDict(TWDict(edge)[@"item"])];
            if (c) [channels addObject:c];
        }
        for (id edge in TWArr(TWDict(result[@"games"])[@"edges"])) {
            TWGame *g = [TWGame gameFromGQL:TWDict(TWDict(edge)[@"item"])];
            if (g) [games addObject:g];
        }
        completion(channels, games, nil);
    }];
}

#pragma mark - Channels

+ (TWHTTPTask *)channel:(NSString *)login completion:(void (^)(TWChannel *channel, NSError *error))completion
{
    return [self query:TWQueryChannel variables:@{ @"login": [login lowercaseString] ?: @"" } completion:^(NSDictionary *data, NSError *error) {
        if (error) { completion(nil, error); return; }
        TWChannel *channel = [TWChannel channelFromGQL:TWDict(data[@"user"])];
        if (!channel) { completion(nil, TWMakeError(TWErrorAPI, L(@"This channel does not exist."))); return; }
        completion(channel, nil);
    }];
}

+ (TWHTTPTask *)channels:(NSArray *)logins completion:(void (^)(NSArray *channels, NSError *error))completion
{
    // (the API takes up to a hundred names at once; the favourites are capped below that)
    NSArray *names = logins.count > 100 ? [logins subarrayWithRange:NSMakeRange(0, 100)] : (logins ?: @[]);
    if (!names.count) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(@[], nil); });
        return nil;
    }
    return [self query:TWQueryChannels variables:@{ @"logins": names } completion:^(NSDictionary *data, NSError *error) {
        if (error) { completion(nil, error); return; }
        NSMutableArray *channels = [NSMutableArray array];
        for (id user in TWArr(data[@"users"])) {
            TWChannel *c = [TWChannel channelFromGQL:TWDict(user)];
            if (c) [channels addObject:c];
        }
        completion(channels, nil);
    }];
}

+ (TWHTTPTask *)videosForChannel:(NSString *)login type:(NSString *)type after:(NSString *)cursor completion:(TWListCompletion)completion
{
    NSMutableDictionary *vars = [NSMutableDictionary dictionaryWithDictionary:@{ @"login": [login lowercaseString] ?: @"", @"first": @(TWVideoPageSize) }];
    if (type.length) vars[@"type"] = type;
    if (cursor.length) vars[@"after"] = cursor;
    return [self query:TWQueryVideos variables:vars completion:^(NSDictionary *data, NSError *error) {
        if (error) { completion(nil, nil, error); return; }
        [self finishList:TWDict(TWDict(data[@"user"])[@"videos"]) make:^id(NSDictionary *node) {
            return [TWVideo videoFromGQL:node];
        } completion:completion];
    }];
}

+ (TWHTTPTask *)clipsForChannel:(NSString *)login period:(NSString *)period after:(NSString *)cursor completion:(TWListCompletion)completion
{
    NSMutableDictionary *vars = [NSMutableDictionary dictionaryWithDictionary:@{
        @"login": [login lowercaseString] ?: @"", @"first": @(TWVideoPageSize), @"period": period ?: TWClipPeriodWeek }];
    if (cursor.length) vars[@"after"] = cursor;
    return [self query:TWQueryClips variables:vars completion:^(NSDictionary *data, NSError *error) {
        if (error) { completion(nil, nil, error); return; }
        [self finishList:TWDict(TWDict(data[@"user"])[@"clips"]) make:^id(NSDictionary *node) {
            return [TWClip clipFromGQL:node];
        } completion:completion];
    }];
}

+ (TWHTTPTask *)video:(NSString *)videoId completion:(void (^)(TWVideo *video, NSError *error))completion
{
    return [self query:TWQueryVideo variables:@{ @"id": videoId ?: @"" } completion:^(NSDictionary *data, NSError *error) {
        if (error) { completion(nil, error); return; }
        TWVideo *video = [TWVideo videoFromGQL:TWDict(data[@"video"])];
        if (!video) { completion(nil, TWMakeError(TWErrorAPI, L(@"This video does not exist any more."))); return; }
        completion(video, nil);
    }];
}

#pragma mark - Playback

+ (TWHTTPTask *)token:(NSString *)query variables:(NSDictionary *)vars field:(NSString *)field
           completion:(void (^)(NSString *token, NSString *signature, NSError *error))completion
{
    return [self query:query variables:vars completion:^(NSDictionary *data, NSError *error) {
        if (error) { completion(nil, nil, error); return; }
        NSDictionary *t = TWDict(data[field]);
        NSString *value = TWStr(t[@"value"]), *signature = TWStr(t[@"signature"]);
        if (!value.length || !signature.length) {
            completion(nil, nil, TWMakeError(TWErrorAPI, L(@"Twitch did not allow the playback.")));
            return;
        }
        completion(value, signature, nil);
    }];
}

+ (TWHTTPTask *)streamAccessToken:(NSString *)login completion:(void (^)(NSString *token, NSString *signature, NSError *error))completion
{
    return [self token:TWQueryStreamToken variables:@{ @"login": [login lowercaseString] ?: @"" } field:@"streamPlaybackAccessToken" completion:completion];
}

+ (TWHTTPTask *)videoAccessToken:(NSString *)videoId completion:(void (^)(NSString *token, NSString *signature, NSError *error))completion
{
    return [self token:TWQueryVideoToken variables:@{ @"id": videoId ?: @"" } field:@"videoPlaybackAccessToken" completion:completion];
}

+ (TWHTTPTask *)clipSources:(NSString *)slug completion:(void (^)(NSArray *sources, NSError *error))completion
{
    return [self query:TWQueryClip variables:@{ @"slug": slug ?: @"" } completion:^(NSDictionary *data, NSError *error) {
        if (error) { completion(nil, error); return; }
        NSDictionary *clip = TWDict(data[@"clip"]);
        NSDictionary *token = TWDict(clip[@"playbackAccessToken"]);
        NSString *value = TWStr(token[@"value"]), *signature = TWStr(token[@"signature"]);
        NSMutableArray *sources = [NSMutableArray array];
        for (id q in TWArr(clip[@"videoQualities"])) {
            NSDictionary *quality = TWDict(q);
            NSString *source = TWStr(quality[@"sourceURL"]);
            if (!source.length) continue;
            NSString *separator = [source rangeOfString:@"?"].location == NSNotFound ? @"?" : @"&";
            NSString *url = value.length && signature.length ?
                [NSString stringWithFormat:@"%@%@sig=%@&token=%@", source, separator, signature, [TWUtils urlEncode:value]] : source;
            [sources addObject:@{ @"quality": TWStr(quality[@"quality"]) ?: @"", @"fps": @(lrint(TWDbl(quality[@"frameRate"]))), @"url": url }];
        }
        if (!sources.count) {
            completion(nil, TWMakeError(TWErrorAPI, L(@"This clip is not available any more.")));
            return;
        }
        [sources sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSInteger qa = [a[@"quality"] integerValue], qb = [b[@"quality"] integerValue];
            return qa > qb ? NSOrderedAscending : (qa < qb ? NSOrderedDescending : NSOrderedSame);
        }];
        completion(sources, nil);
    }];
}

#pragma mark - Chat

+ (NSDictionary *)badgeMap:(NSArray *)badges
{
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    for (id b in badges) {
        NSDictionary *badge = TWDict(b);
        NSString *set = TWStr(badge[@"setID"]), *version = TWStr(badge[@"version"]), *url = TWStr(badge[@"imageURL"]);
        if (set.length && version.length && url.length) map[[NSString stringWithFormat:@"%@/%@", set, version]] = url;
    }
    return map;
}

+ (TWHTTPTask *)globalBadges:(void (^)(NSDictionary *badges, NSError *error))completion
{
    return [self query:TWQueryGlobalBadges variables:nil completion:^(NSDictionary *data, NSError *error) {
        if (error) { completion(nil, error); return; }
        completion([self badgeMap:TWArr(data[@"badges"])], nil);
    }];
}

+ (TWHTTPTask *)channelBadges:(NSString *)login completion:(void (^)(NSDictionary *badges, NSError *error))completion
{
    return [self query:TWQueryChannelBadges variables:@{ @"login": [login lowercaseString] ?: @"" } completion:^(NSDictionary *data, NSError *error) {
        if (error) { completion(nil, error); return; }
        completion([self badgeMap:TWArr(TWDict(data[@"user"])[@"broadcastBadges"])], nil);
    }];
}

+ (TWHTTPTask *)commentsForVideo:(NSString *)videoId offset:(NSInteger)seconds
                      completion:(void (^)(NSArray *comments, BOOL hasMore, NSError *error))completion
{
    NSDictionary *vars = @{ @"id": videoId ?: @"", @"offset": @(MAX(seconds, (NSInteger)0)) };
    return [self query:TWQueryComments variables:vars completion:^(NSDictionary *data, NSError *error) {
        if (error) { completion(nil, NO, error); return; }
        NSDictionary *connection = TWDict(TWDict(data[@"video"])[@"comments"]);
        NSMutableArray *comments = [NSMutableArray array];
        for (id edge in TWArr(connection[@"edges"])) {
            NSDictionary *node = TWDict(TWDict(edge)[@"node"]);
            NSDictionary *commenter = TWDict(node[@"commenter"]);
            NSDictionary *message = TWDict(node[@"message"]);
            NSString *ident = TWStr(node[@"id"]);
            if (!ident.length || !message) continue;
            NSMutableArray *fragments = [NSMutableArray array];
            for (id f in TWArr(message[@"fragments"])) {
                NSDictionary *fragment = TWDict(f);
                NSString *text = TWStr(fragment[@"text"]);
                if (!text.length) continue;
                NSString *emoteId = TWStr(TWDict(fragment[@"emote"])[@"emoteID"]);
                if (emoteId.length) [fragments addObject:@{ @"text": text, @"emoteId": emoteId }];
                else [fragments addObject:@{ @"text": text }];
            }
            NSMutableArray *badges = [NSMutableArray array];
            for (id b in TWArr(message[@"userBadges"])) {
                NSString *set = TWStr(TWDict(b)[@"setID"]), *version = TWStr(TWDict(b)[@"version"]);
                if (set.length) [badges addObject:@[ set, version ?: @"1" ]];
            }
            NSString *login = [TWStr(commenter[@"login"]) lowercaseString] ?: @"";
            [comments addObject:@{
                @"id": ident,
                @"offset": @(TWInt(node[@"contentOffsetSeconds"])),
                @"login": login,
                @"displayName": TWStr(commenter[@"displayName"]) ?: login,
                @"color": TWStr(message[@"userColor"]) ?: @"",
                @"badges": badges,
                @"fragments": fragments,
            }];
        }
        completion(comments, TWBool(TWDict(connection[@"pageInfo"])[@"hasNextPage"]), nil);
    }];
}

@end
