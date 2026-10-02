#import "TWHelix.h"
#import "TWAuth.h"
#import "TWConfig.h"
#import "TWModels.h"
#import "TWUtils.h"
#import "TWCommon.h"

static const NSInteger TWHelixMaxPages = 6;

@implementation TWHelix

+ (NSString *)urlForPath:(NSString *)path params:(NSDictionary *)params
{
    NSMutableString *url = [NSMutableString stringWithFormat:@"%@%@", TWTwitchHelixURL, [path hasPrefix:@"/"] ? path : [@"/" stringByAppendingString:path]];
    BOOL first = YES;
    for (NSString *key in params) {
        id value = params[key];
        NSArray *values = [value isKindOfClass:[NSArray class]] ? value : @[ value ];
        for (id v in values) {
            [url appendFormat:@"%@%@=%@", first ? @"?" : @"&", [TWUtils urlEncode:key], [TWUtils urlEncode:[v description]]];
            first = NO;
        }
    }
    return url;
}

// One request with the current token; after a 401 the token is refreshed and the request repeated once
+ (TWHTTPTask *)request:(NSString *)method url:(NSString *)url object:(id)object retry:(BOOL)retry
             completion:(void (^)(NSDictionary *json, NSError *error))completion
{
    TWAuth *auth = [TWAuth shared];
    if (!auth.isLoggedIn) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, TWMakeError(TWErrorAuth, L(@"Log in first."))); });
        return nil;
    }
    TWHTTPTask *outer = [[TWHTTPTask alloc] init];
    __block TWHTTPTask *inner = nil;
    void (^handler)(id, NSInteger, NSError *) = ^(id json, NSInteger status, NSError *error) {
        if (outer.isCancelled) return;
        if (status == 401 && retry) {
            [auth refreshTokenWithCompletion:^(BOOL refreshed) {
                if (outer.isCancelled) return;
                if (!refreshed) { if (completion) completion(nil, TWMakeError(TWErrorAuth, L(@"The login expired. Log in again."))); return; }
                inner = [self request:method url:url object:object retry:NO completion:completion];
            }];
            return;
        }
        if (error) { if (completion) completion(TWDict(json), error); return; }
        if (completion) completion(TWDict(json), nil);
    };
    if ([method isEqualToString:@"POST"]) {
        inner = [TWHTTP postJSON:url headers:[auth helixHeaders] object:object retries:0 completion:handler];
    } else {
        inner = [TWHTTP getJSON:url headers:[auth helixHeaders] completion:handler];
    }
    outer.cancelBlock = ^{ [inner cancel]; };
    return outer;
}

+ (TWHTTPTask *)get:(NSString *)path params:(NSDictionary *)params completion:(void (^)(NSDictionary *, NSError *))completion
{
    return [self request:@"GET" url:[self urlForPath:path params:params] object:nil retry:YES completion:completion];
}

+ (TWHTTPTask *)post:(NSString *)path object:(id)object completion:(void (^)(NSDictionary *, NSError *))completion
{
    return [self request:@"POST" url:[self urlForPath:path params:nil] object:object retry:YES completion:completion];
}

#pragma mark - Paging

// Collects the `data` of every page (pagination.cursor) into one list
+ (TWHTTPTask *)collect:(NSString *)path params:(NSDictionary *)params into:(NSMutableArray *)items page:(NSInteger)page
                  outer:(TWHTTPTask *)outer completion:(void (^)(NSArray *items, NSError *error))completion
{
    __block TWHTTPTask *inner = nil;
    inner = [self get:path params:params completion:^(NSDictionary *json, NSError *error) {
        if (outer.isCancelled) return;
        if (error) { completion(items.count ? items : nil, error); return; }
        for (id d in TWArr(json[@"data"])) if (TWDict(d)) [items addObject:d];
        NSString *cursor = TWStr(TWDict(json[@"pagination"])[@"cursor"]);
        if (cursor.length && page + 1 < TWHelixMaxPages && TWArr(json[@"data"]).count) {
            NSMutableDictionary *next = [params mutableCopy];
            next[@"after"] = cursor;
            inner = [self collect:path params:next into:items page:page + 1 outer:outer completion:completion];
            outer.cancelBlock = ^{ [inner cancel]; };
            return;
        }
        completion(items, nil);
    }];
    outer.cancelBlock = ^{ [inner cancel]; };
    return inner;
}

+ (TWHTTPTask *)collectAll:(NSString *)path params:(NSDictionary *)params completion:(void (^)(NSArray *items, NSError *error))completion
{
    TWHTTPTask *outer = [[TWHTTPTask alloc] init];
    [self collect:path params:params into:[NSMutableArray array] page:0 outer:outer completion:completion];
    return outer;
}

#pragma mark - Follows

+ (TWHTTPTask *)followedStreams:(void (^)(NSArray *, NSError *))completion
{
    NSString *userId = [TWAuth shared].userId ?: @"";
    return [self collectAll:@"streams/followed" params:@{ @"user_id": userId, @"first": @"100" } completion:^(NSArray *items, NSError *error) {
        if (error) { completion(nil, error); return; }
        NSMutableArray *streams = [NSMutableArray array];
        for (NSDictionary *item in items) {
            TWStream *s = [TWStream streamFromHelix:item];
            if (s) [streams addObject:s];
        }
        [streams sortUsingComparator:^NSComparisonResult(TWStream *a, TWStream *b) {
            return a.viewers > b.viewers ? NSOrderedAscending : (a.viewers < b.viewers ? NSOrderedDescending : NSOrderedSame);
        }];
        completion(streams, nil);
    }];
}

+ (TWHTTPTask *)followedChannels:(void (^)(NSArray *, NSError *))completion
{
    NSString *userId = [TWAuth shared].userId ?: @"";
    return [self collectAll:@"channels/followed" params:@{ @"user_id": userId, @"first": @"100" } completion:^(NSArray *items, NSError *error) {
        if (error) { completion(nil, error); return; }
        NSMutableArray *channels = [NSMutableArray array];
        for (NSDictionary *item in items) {
            NSString *login = [TWStr(item[@"broadcaster_login"]) lowercaseString];
            if (!login.length) continue;
            [channels addObject:@{ @"login": login, @"name": TWStr(item[@"broadcaster_name"]) ?: login,
                                   @"id": TWStr(item[@"broadcaster_id"]) ?: @"", @"followedAt": TWStr(item[@"followed_at"]) ?: @"" }];
        }
        completion(channels, nil);
    }];
}

#pragma mark - Chat

+ (TWHTTPTask *)sendChatMessage:(NSString *)text toBroadcaster:(NSString *)broadcasterId replyTo:(NSString *)parentMessageId
                     completion:(void (^)(NSString *, NSString *, NSError *))completion
{
    NSMutableDictionary *body = [NSMutableDictionary dictionaryWithDictionary:@{
        @"broadcaster_id": broadcasterId ?: @"", @"sender_id": [TWAuth shared].userId ?: @"", @"message": text ?: @"" }];
    if (parentMessageId.length) body[@"reply_parent_message_id"] = parentMessageId;
    return [self post:@"chat/messages" object:body completion:^(NSDictionary *json, NSError *error) {
        if (error) { completion(nil, nil, error); return; }
        NSDictionary *result = TWDict([TWArr(json[@"data"]) firstObject]);
        if (TWBool(result[@"is_sent"])) { completion(TWStr(result[@"message_id"]), nil, nil); return; }
        NSString *reason = TWStr(TWDict(result[@"drop_reason"])[@"message"]) ?: L(@"The message was not sent.");
        completion(nil, reason, nil);
    }];
}

+ (TWHTTPTask *)userEmotes:(void (^)(NSArray *, NSError *))completion
{
    NSString *userId = [TWAuth shared].userId ?: @"";
    return [self collectAll:@"chat/emotes/user" params:@{ @"user_id": userId } completion:^(NSArray *items, NSError *error) {
        if (error) { completion(nil, error); return; }
        NSMutableArray *emotes = [NSMutableArray array];
        for (NSDictionary *item in items) {
            NSString *ident = TWStr(item[@"id"]), *name = TWStr(item[@"name"]);
            if (!ident.length || !name.length) continue;
            BOOL animated = [TWArr(item[@"format"]) containsObject:@"animated"];
            [emotes addObject:@{ @"id": ident, @"name": name, @"animated": @(animated), @"setId": TWStr(item[@"emote_set_id"]) ?: @"",
                                 @"ownerId": TWStr(item[@"owner_id"]) ?: @"", @"type": TWStr(item[@"emote_type"]) ?: @"" }];
        }
        completion(emotes, nil);
    }];
}

@end
