#import "TWFavorites.h"
#import "TWCommon.h"

static NSString * const kFavoritesKey = @"favorites";   // @[ @{ @"login", @"name", @"avatar" } ]
static const NSUInteger TWMaxFavorites = 100;             // (the status query takes a hundred names at once)

@interface TWFavorites ()
@property (nonatomic, strong) NSMutableArray *items;
@end

@implementation TWFavorites

+ (instancetype)shared
{
    static TWFavorites *favorites;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ favorites = [[TWFavorites alloc] init]; });
    return favorites;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _items = [NSMutableArray array];
        for (id d in [[NSUserDefaults standardUserDefaults] arrayForKey:kFavoritesKey]) {
            if ([d isKindOfClass:[NSDictionary class]] && [TWStr(d[@"login"]) length]) [_items addObject:[d mutableCopy]];
        }
    }
    return self;
}

- (void)save
{
    [[NSUserDefaults standardUserDefaults] setObject:self.items forKey:kFavoritesKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:TWFavoritesDidChangeNotification object:self];
}

- (NSMutableDictionary *)itemFor:(NSString *)login
{
    NSString *l = [login lowercaseString];
    for (NSMutableDictionary *d in self.items) {
        if ([d[@"login"] isEqualToString:l]) return d;
    }
    return nil;
}

- (NSArray *)logins
{
    NSMutableArray *result = [NSMutableArray array];
    for (NSDictionary *d in self.items) [result addObject:d[@"login"]];
    return result;
}

- (BOOL)contains:(NSString *)login
{
    return login.length && [self itemFor:login] != nil;
}

- (void)add:(NSString *)login displayName:(NSString *)displayName avatarURL:(NSString *)avatarURL
{
    NSString *l = [login lowercaseString];
    if (!l.length) return;
    NSMutableDictionary *existing = [self itemFor:l];
    if (existing) {
        if (displayName.length) existing[@"name"] = displayName;
        if (avatarURL.length) existing[@"avatar"] = avatarURL;
        [self save];
        return;
    }
    if (self.items.count >= TWMaxFavorites) [self.items removeObjectAtIndex:0];
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithObject:l forKey:@"login"];
    if (displayName.length) d[@"name"] = displayName;
    if (avatarURL.length) d[@"avatar"] = avatarURL;
    [self.items addObject:d];
    [self save];
}

- (void)remove:(NSString *)login
{
    NSMutableDictionary *existing = [self itemFor:login];
    if (!existing) return;
    [self.items removeObjectIdenticalTo:existing];
    [self save];
}

- (void)toggle:(TWChannel *)channel
{
    if (!channel.login.length) return;
    if ([self contains:channel.login]) [self remove:channel.login];
    else [self add:channel.login displayName:channel.displayName avatarURL:channel.avatarURL];
}

- (NSString *)displayNameFor:(NSString *)login
{
    NSString *name = TWStr([self itemFor:login][@"name"]);
    return name.length ? name : login;
}

- (NSString *)avatarURLFor:(NSString *)login
{
    return TWStr([self itemFor:login][@"avatar"]);
}

- (void)rememberChannel:(TWChannel *)channel
{
    NSMutableDictionary *existing = [self itemFor:channel.login];
    if (!existing) return;
    BOOL changed = NO;
    if (channel.displayName.length && ![existing[@"name"] isEqualToString:channel.displayName]) { existing[@"name"] = channel.displayName; changed = YES; }
    if (channel.avatarURL.length && ![existing[@"avatar"] isEqualToString:channel.avatarURL]) { existing[@"avatar"] = channel.avatarURL; changed = YES; }
    if (changed) {
        [[NSUserDefaults standardUserDefaults] setObject:self.items forKey:kFavoritesKey];
    }
}

@end
