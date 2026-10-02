#import "TWEmotes.h"
#import "TWGQL.h"
#import "TWHelix.h"
#import "TWAuth.h"
#import "TWHTTP.h"
#import "TWSettings.h"
#import "TWUtils.h"
#import "TWCommon.h"

NSString * const TWEmotesDidChangeNotification = @"TWEmotesDidChangeNotification";

@implementation TWEmote

- (NSString *)urlForScale:(CGFloat)scale
{
    if (scale > 1.5 && self.url2x.length) return self.url2x;
    return self.url1x;
}

- (NSString *)providerName
{
    switch (self.provider) {
        case TWEmoteProviderBTTV: return @"BetterTTV";
        case TWEmoteProviderFFZ: return @"FrankerFaceZ";
        case TWEmoteProvider7TV: return @"7TV";
        default: return @"Twitch";
    }
}

@end

@interface TWEmoteStore ()
@property (nonatomic, strong) NSMutableDictionary *globalEmotes;      // name -> TWEmote
@property (nonatomic, strong) NSMutableDictionary *channelEmotes;     // name -> TWEmote
@property (nonatomic, strong) NSMutableArray *globalOrder;            // TWEmote, as listed by the services
@property (nonatomic, strong) NSMutableArray *channelOrder;
@property (nonatomic, copy) NSString *channelId;
@property (nonatomic, copy) NSString *channelLogin;
@property (nonatomic, strong) NSDictionary *globalBadges;             // "set/version" -> url (18 px)
@property (nonatomic, strong) NSDictionary *channelBadges;
@property (nonatomic, strong) NSArray *userEmotes;                    // TWEmote (Twitch)
@property (nonatomic) BOOL globalsLoading;
@property (nonatomic) BOOL globalsLoaded;
@property (nonatomic, strong) NSMutableArray *channelTasks;
@property (nonatomic, strong) NSDate *globalsLoadedAt;
@end

@implementation TWEmoteStore

+ (instancetype)shared
{
    static TWEmoteStore *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ store = [[TWEmoteStore alloc] init]; });
    return store;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _globalEmotes = [NSMutableDictionary dictionary];
        _channelEmotes = [NSMutableDictionary dictionary];
        _globalOrder = [NSMutableArray array];
        _channelOrder = [NSMutableArray array];
        _channelTasks = [NSMutableArray array];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(authChanged) name:TWAuthDidChangeNotification object:nil];
    }
    return self;
}

- (void)changed
{
    [[NSNotificationCenter defaultCenter] postNotificationName:TWEmotesDidChangeNotification object:self];
}

#pragma mark - Lookups (any thread)

- (TWEmote *)thirdPartyEmoteNamed:(NSString *)word channelId:(NSString *)channelId
{
    if (!word.length) return nil;
    @synchronized (self) {
        TWEmote *e = nil;
        if (channelId.length && [channelId isEqualToString:self.channelId]) e = self.channelEmotes[word];
        return e ?: self.globalEmotes[word];
    }
}

+ (TWEmote *)twitchEmoteWithId:(NSString *)emoteId name:(NSString *)name animated:(BOOL)animated
{
    if (!emoteId.length) return nil;
    TWEmote *e = [[TWEmote alloc] init];
    e.provider = TWEmoteProviderTwitch;
    e.emoteId = emoteId;
    e.name = name ?: emoteId;
    e.width = 28;
    e.height = 28;
    e.animated = animated;
    // ("default" is the animation when the emote has one, "static" always a still; the theme decides the outline
    // of a few emotes drawn for one background)
    NSString *format = animated ? @"default" : @"static";
    NSString *theme = [TWSettings darkTheme] ? @"dark" : @"light";
    e.url1x = [NSString stringWithFormat:@"https://static-cdn.jtvnw.net/emoticons/v2/%@/%@/%@/1.0", emoteId, format, theme];
    e.url2x = [NSString stringWithFormat:@"https://static-cdn.jtvnw.net/emoticons/v2/%@/%@/%@/2.0", emoteId, format, theme];
    return e;
}

- (NSString *)badgeURLForSet:(NSString *)set version:(NSString *)version channelId:(NSString *)channelId scale2x:(BOOL)retina
{
    if (!set.length) return nil;
    NSString *key = [NSString stringWithFormat:@"%@/%@", set, version.length ? version : @"1"];
    NSString *url = nil;
    @synchronized (self) {
        if (channelId.length && [channelId isEqualToString:self.channelId]) url = self.channelBadges[key];
        if (!url) url = self.globalBadges[key];
        if (!url && ![version isEqualToString:@"1"]) {
            // a subscriber badge version the channel has not drawn: the plain one
            NSString *fallback = [NSString stringWithFormat:@"%@/1", set];
            url = self.channelBadges[fallback] ?: self.globalBadges[fallback];
            if (!url && [set isEqualToString:@"subscriber"]) url = self.channelBadges[@"subscriber/0"] ?: self.globalBadges[@"subscriber/0"];
        }
    }
    if (!url) return nil;
    if (retina && [url hasSuffix:@"/1"]) return [[url substringToIndex:url.length - 1] stringByAppendingString:@"2"];
    return url;
}

- (NSArray *)pickerSectionsForChannelId:(NSString *)channelId
{
    NSMutableArray *sections = [NSMutableArray array];
    @synchronized (self) {
        if (self.userEmotes.count) [sections addObject:@{ @"title": L(@"Your Twitch emotes"), @"emotes": self.userEmotes }];
        if (channelId.length && [channelId isEqualToString:self.channelId] && self.channelOrder.count) {
            [sections addObject:@{ @"title": L(@"Channel emotes"), @"emotes": [self.channelOrder copy] }];
        }
        if (self.globalOrder.count) [sections addObject:@{ @"title": L(@"Global emotes"), @"emotes": [self.globalOrder copy] }];
    }
    return sections;
}

#pragma mark - Parsing the services

- (NSInteger)dimension:(id)value fallback:(NSInteger)fallback
{
    NSInteger v = TWInt(value);
    return v > 0 && v < 400 ? v : fallback;
}

// BetterTTV: {id, code, imageType: png|gif|webp, animated, width?, height?}
- (NSArray *)emotesFromBTTV:(NSArray *)list
{
    NSMutableArray *result = [NSMutableArray array];
    for (id item in list) {
        NSDictionary *d = TWDict(item);
        NSString *ident = TWStr(d[@"id"]), *code = TWStr(d[@"code"]);
        NSString *type = [TWStr(d[@"imageType"]) lowercaseString] ?: @"png";
        if (!ident.length || !code.length) continue;
        if ([type isEqualToString:@"webp"]) continue;   // (the 2012 image decoder knows no WebP)
        TWEmote *e = [[TWEmote alloc] init];
        e.provider = TWEmoteProviderBTTV;
        e.emoteId = ident;
        e.name = code;
        e.animated = TWBool(d[@"animated"]) || [type isEqualToString:@"gif"];
        e.width = [self dimension:d[@"width"] fallback:28];
        e.height = [self dimension:d[@"height"] fallback:28];
        e.url1x = [NSString stringWithFormat:@"https://cdn.betterttv.net/emote/%@/1x.%@", ident, type];
        e.url2x = [NSString stringWithFormat:@"https://cdn.betterttv.net/emote/%@/2x.%@", ident, type];
        [result addObject:e];
    }
    return result;
}

// FrankerFaceZ: sets: { id: { emoticons: [ {id, name, width, height, urls: {1:..., 2:...}, modifier} ] } }
- (NSArray *)emotesFromFFZSets:(NSDictionary *)sets
{
    NSMutableArray *result = [NSMutableArray array];
    for (id key in sets) {
        for (id item in TWArr(TWDict(sets[key])[@"emoticons"])) {
            NSDictionary *d = TWDict(item);
            NSString *name = TWStr(d[@"name"]);
            NSDictionary *urls = TWDict(d[@"urls"]);
            NSString *u1 = TWStr(urls[@"1"]);
            if (!name.length || !u1.length) continue;
            // (FFZ's modifier emotes change the look of the emote before them; shown as a plain emote here)
            TWEmote *e = [[TWEmote alloc] init];
            e.provider = TWEmoteProviderFFZ;
            e.emoteId = TWStr(d[@"id"]) ?: name;
            e.name = name;
            e.width = [self dimension:d[@"width"] fallback:28];
            e.height = [self dimension:d[@"height"] fallback:28];
            e.url1x = [u1 hasPrefix:@"//"] ? [@"https:" stringByAppendingString:u1] : u1;
            NSString *u2 = TWStr(urls[@"2"]);
            if (u2.length) e.url2x = [u2 hasPrefix:@"//"] ? [@"https:" stringByAppendingString:u2] : u2;
            [result addObject:e];
        }
    }
    return result;
}

// 7TV: emotes: [ { name, flags, data: { animated, host: { url, files: [ {name, width, height, format} ] } } } ]
- (NSArray *)emotesFrom7TV:(NSArray *)list
{
    NSMutableArray *result = [NSMutableArray array];
    for (id item in list) {
        NSDictionary *d = TWDict(item);
        NSString *name = TWStr(d[@"name"]);
        NSDictionary *data = TWDict(d[@"data"]);
        NSDictionary *host = TWDict(data[@"host"]);
        NSString *base = TWStr(host[@"url"]);
        if (!name.length || !base.length) continue;
        if ([base hasPrefix:@"//"]) base = [@"https:" stringByAppendingString:base];
        BOOL animated = TWBool(data[@"animated"]);
        // the GIF of an animated emote, the PNG of a still one (the WebP and AVIF files cannot be decoded here)
        NSString *wanted = animated ? @"GIF" : @"PNG";
        NSDictionary *file1 = nil, *file2 = nil;
        for (id f in TWArr(host[@"files"])) {
            NSDictionary *file = TWDict(f);
            if (![[TWStr(file[@"format"]) uppercaseString] isEqualToString:wanted]) continue;
            NSString *fileName = TWStr(file[@"name"]);
            if ([fileName hasPrefix:@"1x"]) file1 = file;
            else if ([fileName hasPrefix:@"2x"]) file2 = file;
        }
        if (!file1) continue;
        TWEmote *e = [[TWEmote alloc] init];
        e.provider = TWEmoteProvider7TV;
        e.emoteId = TWStr(d[@"id"]) ?: name;
        e.name = name;
        e.animated = animated;
        e.zeroWidth = (TWInt(d[@"flags"]) & 1) != 0;
        e.width = [self dimension:file1[@"width"] fallback:32];
        e.height = [self dimension:file1[@"height"] fallback:32];
        e.url1x = [NSString stringWithFormat:@"%@/%@", base, TWStr(file1[@"name"])];
        if (file2) e.url2x = [NSString stringWithFormat:@"%@/%@", base, TWStr(file2[@"name"])];
        [result addObject:e];
    }
    return result;
}

- (void)addEmotes:(NSArray *)emotes toChannel:(BOOL)channel
{
    if (!emotes.count) return;
    @synchronized (self) {
        NSMutableDictionary *map = channel ? self.channelEmotes : self.globalEmotes;
        NSMutableArray *order = channel ? self.channelOrder : self.globalOrder;
        for (TWEmote *e in emotes) {
            if (!map[e.name]) [order addObject:e];
            map[e.name] = e;
        }
    }
    [self changed];
}

#pragma mark - Loading

- (void)loadGlobalsIfNeeded
{
    if (self.globalsLoading) return;
    if (self.globalsLoaded && self.globalsLoadedAt && -[self.globalsLoadedAt timeIntervalSinceNow] < 6 * 3600) return;
    self.globalsLoading = YES;
    __block NSInteger pending = 0;
    void (^done)(void) = ^{
        if (--pending > 0) return;
        self.globalsLoading = NO;
        self.globalsLoaded = YES;
        self.globalsLoadedAt = [NSDate date];
    };
    pending++;
    [TWGQL globalBadges:^(NSDictionary *badges, NSError *error) {
        if (badges.count) {
            @synchronized (self) { self.globalBadges = badges; }
            [self changed];
        }
        done();
    }];
    if ([TWSettings thirdPartyEmotes]) {
        pending++;
        [TWHTTP getJSON:@"https://api.betterttv.net/3/cached/emotes/global" headers:nil completion:^(id json, NSInteger status, NSError *error) {
            [self addEmotes:[self emotesFromBTTV:TWArr(json)] toChannel:NO];
            done();
        }];
        pending++;
        [TWHTTP getJSON:@"https://api.frankerfacez.com/v1/set/global" headers:nil completion:^(id json, NSInteger status, NSError *error) {
            [self addEmotes:[self emotesFromFFZSets:TWDict(TWDict(json)[@"sets"])] toChannel:NO];
            done();
        }];
        pending++;
        [TWHTTP getJSON:@"https://7tv.io/v3/emote-sets/global" headers:nil completion:^(id json, NSInteger status, NSError *error) {
            [self addEmotes:[self emotesFrom7TV:TWArr(TWDict(json)[@"emotes"])] toChannel:NO];
            done();
        }];
    }
    if ([TWAuth shared].isLoggedIn && !self.userEmotes) [self reloadUserEmotes];
}

- (void)loadChannel:(NSString *)channelId login:(NSString *)login
{
    if (!channelId.length) return;
    if ([channelId isEqualToString:self.channelId]) return;
    for (TWHTTPTask *t in self.channelTasks) [t cancel];
    [self.channelTasks removeAllObjects];
    @synchronized (self) {
        self.channelId = channelId;
        self.channelLogin = login;
        [self.channelEmotes removeAllObjects];
        [self.channelOrder removeAllObjects];
        self.channelBadges = nil;
    }
    [self changed];
    [self loadGlobalsIfNeeded];
    TWHTTPTask *badges = [TWGQL channelBadges:login completion:^(NSDictionary *result, NSError *error) {
        if (![channelId isEqualToString:self.channelId]) return;
        if (result) {
            @synchronized (self) { self.channelBadges = result; }
            [self changed];
        }
    }];
    if (badges) [self.channelTasks addObject:badges];
    if (![TWSettings thirdPartyEmotes]) return;
    NSString *idPart = [TWUtils urlEncode:channelId];
    TWHTTPTask *bttv = [TWHTTP getJSON:[@"https://api.betterttv.net/3/cached/users/twitch/" stringByAppendingString:idPart] headers:nil
                            completion:^(id json, NSInteger status, NSError *error) {
        if (![channelId isEqualToString:self.channelId]) return;
        NSDictionary *d = TWDict(json);
        NSMutableArray *all = [NSMutableArray array];
        [all addObjectsFromArray:[self emotesFromBTTV:TWArr(d[@"channelEmotes"])]];
        [all addObjectsFromArray:[self emotesFromBTTV:TWArr(d[@"sharedEmotes"])]];
        [self addEmotes:all toChannel:YES];
    }];
    TWHTTPTask *ffz = [TWHTTP getJSON:[@"https://api.frankerfacez.com/v1/room/id/" stringByAppendingString:idPart] headers:nil
                           completion:^(id json, NSInteger status, NSError *error) {
        if (![channelId isEqualToString:self.channelId]) return;
        [self addEmotes:[self emotesFromFFZSets:TWDict(TWDict(json)[@"sets"])] toChannel:YES];
    }];
    TWHTTPTask *seventv = [TWHTTP getJSON:[@"https://7tv.io/v3/users/twitch/" stringByAppendingString:idPart] headers:nil
                               completion:^(id json, NSInteger status, NSError *error) {
        if (![channelId isEqualToString:self.channelId]) return;
        [self addEmotes:[self emotesFrom7TV:TWArr(TWDict(TWDict(json)[@"emote_set"])[@"emotes"])] toChannel:YES];
    }];
    if (bttv) [self.channelTasks addObject:bttv];
    if (ffz) [self.channelTasks addObject:ffz];
    if (seventv) [self.channelTasks addObject:seventv];
}

- (void)reloadUserEmotes
{
    if (![TWAuth shared].isLoggedIn) {
        @synchronized (self) { self.userEmotes = nil; }
        [self changed];
        return;
    }
    [TWHelix userEmotes:^(NSArray *emotes, NSError *error) {
        if (error) { TWLog(@"User emotes: %@", error.localizedDescription); return; }
        NSMutableArray *list = [NSMutableArray array];
        BOOL animate = [TWSettings animatedEmotes];
        for (NSDictionary *d in emotes) {
            TWEmote *e = [TWEmoteStore twitchEmoteWithId:d[@"id"] name:d[@"name"] animated:animate && TWBool(d[@"animated"])];
            if (e) [list addObject:e];
        }
        [list sortUsingComparator:^NSComparisonResult(TWEmote *a, TWEmote *b) { return [a.name caseInsensitiveCompare:b.name]; }];
        @synchronized (self) { self.userEmotes = list; }
        [self changed];
    }];
}

- (void)authChanged
{
    self.userEmotes = nil;
    if ([TWAuth shared].isLoggedIn) [self reloadUserEmotes];
    else [self changed];
}

@end
