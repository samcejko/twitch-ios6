#import "TWPlayback.h"
#import "TWGQL.h"
#import "TWConfig.h"
#import "TWMediaProxy.h"
#import "TWSettings.h"
#import "TWUtils.h"
#import "TWCommon.h"

@implementation TWVariant

- (BOOL)isAudioOnly
{
    return [self.groupId isEqualToString:@"audio_only"] || (self.width == 0 && [self.codecs length] && [self.codecs rangeOfString:@"avc"].location == NSNotFound);
}

- (BOOL)isSource
{
    return [self.groupId isEqualToString:@"chunked"];
}

- (NSString *)title
{
    if ([self isAudioOnly]) return L(@"Audio only");
    NSString *base;
    if (self.height > 0) {
        base = self.frameRate > 30.5 ? [NSString stringWithFormat:@"%ldp%.0f", (long)self.height, self.frameRate] : [NSString stringWithFormat:@"%ldp", (long)self.height];
    } else {
        base = self.name.length ? self.name : L(@"Video");
    }
    return [self isSource] ? [NSString stringWithFormat:L(@"%@ (source)"), base] : base;
}

- (NSString *)qualityKey
{
    if ([self isAudioOnly]) return TWQualityAudio;
    if ([self isSource]) return TWQualitySource;
    return [NSString stringWithFormat:@"%ld", (long)self.height];
}

@end

// The attribute list of an HLS tag: NAME=value,NAME="quoted, value"
static NSDictionary *TWParseAttributes(NSString *list)
{
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSUInteger i = 0, n = list.length;
    while (i < n) {
        while (i < n && ([list characterAtIndex:i] == ',' || [list characterAtIndex:i] == ' ')) i++;
        NSUInteger nameStart = i;
        while (i < n && [list characterAtIndex:i] != '=' && [list characterAtIndex:i] != ',') i++;
        if (i >= n || [list characterAtIndex:i] != '=') break;
        NSString *name = [[list substringWithRange:NSMakeRange(nameStart, i - nameStart)] uppercaseString];
        i++;
        NSString *value;
        if (i < n && [list characterAtIndex:i] == '"') {
            NSUInteger end = [list rangeOfString:@"\"" options:0 range:NSMakeRange(i + 1, n - i - 1)].location;
            if (end == NSNotFound) end = n;
            value = [list substringWithRange:NSMakeRange(i + 1, end - i - 1)];
            i = MIN(end + 1, n);
        } else {
            NSUInteger end = [list rangeOfString:@"," options:0 range:NSMakeRange(i, n - i)].location;
            if (end == NSNotFound) end = n;
            value = [list substringWithRange:NSMakeRange(i, end - i)];
            i = end;
        }
        if (name.length) result[name] = value;
    }
    return result;
}

@implementation TWPlayback

#pragma mark - Master playlists

+ (NSArray *)variantsFromMaster:(NSString *)text baseURL:(NSURL *)base
{
    NSMutableDictionary *names = [NSMutableDictionary dictionary];   // GROUP-ID -> NAME from #EXT-X-MEDIA
    NSMutableArray *variants = [NSMutableArray array];
    NSDictionary *pending = nil;
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!line.length) continue;
        if ([line hasPrefix:@"#EXT-X-MEDIA:"]) {
            NSDictionary *a = TWParseAttributes([line substringFromIndex:@"#EXT-X-MEDIA:".length]);
            if (a[@"GROUP-ID"] && a[@"NAME"]) names[a[@"GROUP-ID"]] = a[@"NAME"];
            continue;
        }
        if ([line hasPrefix:@"#EXT-X-STREAM-INF:"]) {
            pending = TWParseAttributes([line substringFromIndex:@"#EXT-X-STREAM-INF:".length]);
            continue;
        }
        if ([line hasPrefix:@"#"]) continue;
        if (!pending) continue;
        NSURL *url = [[NSURL URLWithString:line relativeToURL:base] absoluteURL];
        if (url.host.length) {
            TWVariant *v = [[TWVariant alloc] init];
            v.url = url.absoluteString;
            v.groupId = pending[@"VIDEO"] ?: @"";
            v.name = names[v.groupId] ?: v.groupId;
            v.codecs = pending[@"CODECS"] ?: @"";
            v.bandwidth = [pending[@"BANDWIDTH"] integerValue];
            v.frameRate = [pending[@"FRAME-RATE"] doubleValue];
            NSArray *res = [pending[@"RESOLUTION"] componentsSeparatedByString:@"x"];
            if (res.count == 2) { v.width = [res[0] integerValue]; v.height = [res[1] integerValue]; }
            if (v.frameRate <= 0 && v.name.length) {
                // "720p60": the frame rate is in the name when the attribute is missing
                NSRange p = [v.name rangeOfString:@"p"];
                if (p.location != NSNotFound && p.location + 1 < v.name.length) v.frameRate = [[v.name substringFromIndex:p.location + 1] doubleValue];
                if (v.frameRate <= 0) v.frameRate = 30;
            }
            [variants addObject:v];
        }
        pending = nil;
    }
    // highest first, audio last
    [variants sortUsingComparator:^NSComparisonResult(TWVariant *a, TWVariant *b) {
        if ([a isAudioOnly] != [b isAudioOnly]) return [a isAudioOnly] ? NSOrderedDescending : NSOrderedAscending;
        if (a.height != b.height) return a.height > b.height ? NSOrderedAscending : NSOrderedDescending;
        if (a.frameRate != b.frameRate) return a.frameRate > b.frameRate ? NSOrderedAscending : NSOrderedDescending;
        if (a.bandwidth != b.bandwidth) return a.bandwidth > b.bandwidth ? NSOrderedAscending : NSOrderedDescending;
        return NSOrderedSame;
    }];
    return variants;
}

+ (NSError *)errorForUsherStatus:(NSInteger)status body:(NSData *)body live:(BOOL)live
{
    // usher answers errors with a JSON list: [{"error": "...", "error_code": "...", "type": "error"}]
    NSString *code = nil, *message = nil;
    for (id e in TWArr([TWUtils JSONObjectFromData:body])) {
        code = TWStr(TWDict(e)[@"error_code"]);
        message = TWStr(TWDict(e)[@"error"]);
        if (code || message) break;
    }
    if (status == 404 && live) return TWMakeError(TWErrorOffline, L(@"The channel is not live right now."));
    if (status == 403 || [code rangeOfString:@"restricted"].location != NSNotFound) {
        return TWMakeError(TWErrorRestricted, L(@"This content is restricted (subscribers only, or not available in your country)."));
    }
    if (status == 404) return TWMakeError(TWErrorAPI, L(@"This video is not available any more."));
    return TWMakeError(TWErrorAPI, message.length ? message : [NSString stringWithFormat:L(@"Request failed (HTTP %ld)."), (long)status]);
}

+ (TWHTTPTask *)fetchMaster:(NSString *)url live:(BOOL)live completion:(void (^)(NSArray *variants, NSError *error))completion
{
    return [TWHTTP get:url headers:@{ @"Accept": @"application/vnd.apple.mpegurl, application/x-mpegURL, */*" }
            completion:^(NSInteger status, NSData *body, NSDictionary *headers, NSError *error) {
        if (error) { completion(nil, error); return; }
        if (status != 200) { completion(nil, [self errorForUsherStatus:status body:body live:live]); return; }
        NSString *text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] ?: @"";
        NSArray *variants = [self variantsFromMaster:text baseURL:[NSURL URLWithString:url]];
        if (!variants.count) { completion(nil, TWMakeError(TWErrorBadResponse, L(@"The stream list could not be read."))); return; }
        completion(variants, nil);
    }];
}

+ (NSString *)usherQueryWithToken:(NSString *)token signature:(NSString *)signature
{
    // (h264 only: the hardware of these devices decodes nothing else; the player picks a rendition itself when the
    // master playlist offers several, so every rendition is asked for)
    return [NSString stringWithFormat:@"allow_source=true&allow_audio_only=true&player_backend=mediaplayer&playlist_include_framerate=true"
            "&supported_codecs=h264&p=%u&sig=%@&token=%@", arc4random_uniform(9000000) + 1000000, signature, [TWUtils urlEncode:token]];
}

+ (TWHTTPTask *)variantsForChannel:(NSString *)login completion:(void (^)(NSArray *variants, NSError *error))completion
{
    // two steps in one cancellable task: the token, then the master playlist
    TWHTTPTask *outer = [[TWHTTPTask alloc] init];
    __block TWHTTPTask *inner = nil;
    inner = [TWGQL streamAccessToken:login completion:^(NSString *token, NSString *signature, NSError *error) {
        if (outer.isCancelled) return;
        if (error) { completion(nil, error); return; }
        NSString *url = [NSString stringWithFormat:@"%@/api/channel/hls/%@.m3u8?%@", TWTwitchUsherURL, [TWUtils urlEncode:[login lowercaseString]],
                         [self usherQueryWithToken:token signature:signature]];
        inner = [self fetchMaster:url live:YES completion:^(NSArray *variants, NSError *e) {
            if (outer.isCancelled) return;
            completion(variants, e);
        }];
    }];
    outer.cancelBlock = ^{ [inner cancel]; };
    return outer;
}

+ (TWHTTPTask *)variantsForVideo:(NSString *)videoId completion:(void (^)(NSArray *variants, NSError *error))completion
{
    TWHTTPTask *outer = [[TWHTTPTask alloc] init];
    __block TWHTTPTask *inner = nil;
    inner = [TWGQL videoAccessToken:videoId completion:^(NSString *token, NSString *signature, NSError *error) {
        if (outer.isCancelled) return;
        if (error) { completion(nil, error); return; }
        NSString *url = [NSString stringWithFormat:@"%@/vod/%@.m3u8?%@", TWTwitchUsherURL, [TWUtils urlEncode:videoId],
                         [self usherQueryWithToken:token signature:signature]];
        inner = [self fetchMaster:url live:NO completion:^(NSArray *variants, NSError *e) {
            if (outer.isCancelled) return;
            completion(variants, e);
        }];
    }];
    outer.cancelBlock = ^{ [inner cancel]; };
    return outer;
}

#pragma mark - Device capability

+ (BOOL)deviceCanPlay:(TWVariant *)variant
{
    if ([variant isAudioOnly]) return YES;
    BOOL old = [TWUtils deviceIsOldGeneration];
    NSInteger height = variant.height;
    double fps = variant.frameRate > 0 ? variant.frameRate : 30;
    if (old) return height <= 720 && (height < 720 || fps <= 30.5);
    // A5 and A6: H.264 High Profile up to level 4.1, 1080p30. 1080p60 (level 4.2) is beyond them; 720p60 fits.
    if (height > 1080) return NO;
    if (height >= 1080 && fps > 30.5) return NO;
    return YES;
}

+ (NSArray *)playableVariants:(NSArray *)variants
{
    NSMutableArray *result = [NSMutableArray array];
    for (TWVariant *v in variants) {
        if (![v isAudioOnly] && [self deviceCanPlay:v]) [result addObject:v];
    }
    return result;
}

+ (TWVariant *)variantFrom:(NSArray *)variants forQuality:(NSString *)quality
{
    if (!variants.count) return nil;
    if (!quality.length || [quality isEqualToString:TWQualityAuto]) return nil;
    if ([quality isEqualToString:TWQualityAudio]) {
        for (TWVariant *v in variants) if ([v isAudioOnly]) return v;
        quality = @"160";   // no audio rendition: the smallest picture
    }
    NSArray *playable = [self playableVariants:variants];
    if (!playable.count) {
        // nothing this device is sure to decode: the smallest video rendition, better than nothing
        TWVariant *smallest = nil;
        for (TWVariant *v in variants) if (![v isAudioOnly]) smallest = v;
        return smallest;
    }
    if ([quality isEqualToString:TWQualitySource]) {
        for (TWVariant *v in playable) if ([v isSource]) return v;
        return playable[0];   // (the source is beyond the device: the best that is not)
    }
    NSInteger wanted = [quality integerValue];
    if (wanted <= 0) return nil;
    // the highest rendition not above the wanted height (lists are sorted highest first)
    for (TWVariant *v in playable) {
        if (v.height <= wanted) return v;
    }
    return [playable lastObject];
}

+ (NSString *)masterPlaylistForVariants:(NSArray *)variants startingWith:(TWVariant *)first
{
    TWMediaProxy *proxy = [TWMediaProxy shared];
    NSMutableArray *ordered = [NSMutableArray array];
    if (first && [variants containsObject:first]) [ordered addObject:first];
    for (TWVariant *v in variants) if (![ordered containsObject:v]) [ordered addObject:v];
    NSMutableString *text = [NSMutableString stringWithString:@"#EXTM3U\n"];
    for (TWVariant *v in ordered) {
        NSString *proxied = [proxy proxyURLForURL:[NSURL URLWithString:v.url]];
        if (!proxied) continue;
        [text appendFormat:@"#EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=%ld", (long)MAX(v.bandwidth, (NSInteger)100000)];
        if (v.width > 0 && v.height > 0) [text appendFormat:@",RESOLUTION=%ldx%ld", (long)v.width, (long)v.height];
        if (v.codecs.length) [text appendFormat:@",CODECS=\"%@\"", v.codecs];
        [text appendFormat:@"\n%@\n", proxied];
    }
    return text;
}

+ (NSURL *)playerURLForVariants:(NSArray *)variants quality:(NSString *)quality chosen:(TWVariant **)chosen
{
    TWMediaProxy *proxy = [TWMediaProxy shared];
    [proxy ensureRunning];
    [proxy resetPlaybackState];
    TWVariant *v = [self variantFrom:variants forQuality:quality];
    if (v) {
        if (chosen) *chosen = v;
        NSString *url = [proxy proxyURLForURL:[NSURL URLWithString:v.url]];
        return url ? [NSURL URLWithString:url] : nil;
    }
    // automatic: every rendition the device can decode, the player starts with a middle one and switches by bandwidth
    NSArray *playable = [self playableVariants:variants];
    if (!playable.count) {
        TWVariant *fallback = [self variantFrom:variants forQuality:@"360"];
        if (chosen) *chosen = fallback;
        NSString *url = fallback ? [proxy proxyURLForURL:[NSURL URLWithString:fallback.url]] : nil;
        return url ? [NSURL URLWithString:url] : nil;
    }
    TWVariant *start = [self variantFrom:playable forQuality:@"480"] ?: [playable lastObject];
    if (chosen) *chosen = nil;
    NSString *master = [self masterPlaylistForVariants:playable startingWith:start];
    NSString *url = [proxy proxyURLForPlaylistText:master];
    return url ? [NSURL URLWithString:url] : nil;
}

@end
