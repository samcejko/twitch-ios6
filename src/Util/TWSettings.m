#import "TWSettings.h"
#import "TWCommon.h"

NSString * const TWQualityAuto   = @"auto";
NSString * const TWQualitySource = @"source";
NSString * const TWQualityAudio  = @"audio";

#define DEF [NSUserDefaults standardUserDefaults]

@implementation TWSettings

+ (void)registerDefaults
{
    [DEF registerDefaults:@{
        @"darkTheme": @NO,
        @"preferredQuality": TWQualityAuto,
        @"backgroundAudio": @YES,
        @"keepScreenOn": @YES,
        @"showChat": @YES,
        @"streamLanguage": @"",
        @"chatFontSize": @1,
        @"chatTimestamps": @NO,
        @"animatedEmotes": @YES,
        @"thirdPartyEmotes": @YES,
        @"showDeletedMessages": @NO,
        @"chatSeparators": @NO,
        @"verifyTLS": @YES,
    }];
}

+ (void)save
{
    [DEF synchronize];
}

+ (void)notify
{
    TWMain(^{
        [[NSNotificationCenter defaultCenter] postNotificationName:TWSettingsDidChangeNotification object:nil];
    });
}

#pragma mark - Appearance

+ (BOOL)darkTheme { return [DEF boolForKey:@"darkTheme"]; }
+ (void)setDarkTheme:(BOOL)value { [DEF setBool:value forKey:@"darkTheme"]; }

#pragma mark - Playback

+ (NSString *)preferredQuality { return [DEF stringForKey:@"preferredQuality"] ?: TWQualityAuto; }
+ (void)setPreferredQuality:(NSString *)value { [DEF setObject:value ?: TWQualityAuto forKey:@"preferredQuality"]; [self notify]; }

+ (BOOL)backgroundAudio { return [DEF boolForKey:@"backgroundAudio"]; }
+ (void)setBackgroundAudio:(BOOL)value { [DEF setBool:value forKey:@"backgroundAudio"]; [self notify]; }

+ (BOOL)keepScreenOn { return [DEF boolForKey:@"keepScreenOn"]; }
+ (void)setKeepScreenOn:(BOOL)value { [DEF setBool:value forKey:@"keepScreenOn"]; [self notify]; }

+ (BOOL)showChat { return [DEF boolForKey:@"showChat"]; }
+ (void)setShowChat:(BOOL)value { [DEF setBool:value forKey:@"showChat"]; }

#pragma mark - Browsing

+ (NSString *)streamLanguage { return [DEF stringForKey:@"streamLanguage"] ?: @""; }
+ (void)setStreamLanguage:(NSString *)value { [DEF setObject:value ?: @"" forKey:@"streamLanguage"]; [self notify]; }

#pragma mark - Chat

+ (NSInteger)chatFontSize { return [DEF integerForKey:@"chatFontSize"]; }
+ (void)setChatFontSize:(NSInteger)value { [DEF setInteger:value forKey:@"chatFontSize"]; [self notify]; }

+ (BOOL)chatTimestamps { return [DEF boolForKey:@"chatTimestamps"]; }
+ (void)setChatTimestamps:(BOOL)value { [DEF setBool:value forKey:@"chatTimestamps"]; [self notify]; }

+ (BOOL)animatedEmotes { return [DEF boolForKey:@"animatedEmotes"]; }
+ (void)setAnimatedEmotes:(BOOL)value { [DEF setBool:value forKey:@"animatedEmotes"]; [self notify]; }

+ (BOOL)thirdPartyEmotes { return [DEF boolForKey:@"thirdPartyEmotes"]; }
+ (void)setThirdPartyEmotes:(BOOL)value { [DEF setBool:value forKey:@"thirdPartyEmotes"]; [self notify]; }

+ (BOOL)showDeletedMessages { return [DEF boolForKey:@"showDeletedMessages"]; }
+ (void)setShowDeletedMessages:(BOOL)value { [DEF setBool:value forKey:@"showDeletedMessages"]; [self notify]; }

+ (BOOL)chatSeparators { return [DEF boolForKey:@"chatSeparators"]; }
+ (void)setChatSeparators:(BOOL)value { [DEF setBool:value forKey:@"chatSeparators"]; [self notify]; }

#pragma mark - Network

+ (BOOL)verifyTLS { return [DEF boolForKey:@"verifyTLS"]; }
+ (void)setVerifyTLS:(BOOL)value { [DEF setBool:value forKey:@"verifyTLS"]; }

#pragma mark - Resume positions

+ (NSTimeInterval)resumePositionForVideo:(NSString *)videoId
{
    if (!videoId.length) return 0;
    NSDictionary *all = [DEF dictionaryForKey:@"resumePositions"];
    return TWDbl(all[videoId]);
}

+ (void)setResumePosition:(NSTimeInterval)seconds forVideo:(NSString *)videoId
{
    if (!videoId.length) return;
    NSMutableDictionary *all = [[DEF dictionaryForKey:@"resumePositions"] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableArray *order = [[DEF arrayForKey:@"resumeOrder"] mutableCopy] ?: [NSMutableArray array];
    [order removeObject:videoId];
    if (seconds > 5) {
        all[videoId] = @(floor(seconds));
        [order addObject:videoId];
    } else {
        [all removeObjectForKey:videoId];
    }
    while (order.count > 200) {
        [all removeObjectForKey:order[0]];
        [order removeObjectAtIndex:0];
    }
    [DEF setObject:all forKey:@"resumePositions"];
    [DEF setObject:order forKey:@"resumeOrder"];
}

#pragma mark - Search history

+ (NSArray *)recentSearches
{
    return [DEF arrayForKey:@"recentSearches"] ?: @[];
}

+ (void)addRecentSearch:(NSString *)query
{
    NSString *q = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!q.length) return;
    NSMutableArray *list = [[self recentSearches] mutableCopy];
    for (NSInteger i = (NSInteger)list.count - 1; i >= 0; i--) {
        if ([list[(NSUInteger)i] caseInsensitiveCompare:q] == NSOrderedSame) [list removeObjectAtIndex:(NSUInteger)i];
    }
    [list insertObject:q atIndex:0];
    while (list.count > 12) [list removeLastObject];
    [DEF setObject:list forKey:@"recentSearches"];
}

+ (void)clearRecentSearches
{
    [DEF removeObjectForKey:@"recentSearches"];
}

@end
