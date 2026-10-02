#import "TWAuth.h"
#import "TWConfig.h"
#import "TWHTTP.h"
#import "TWSettings.h"
#import "TWUtils.h"
#import "TWCommon.h"
#import <Security/Security.h>

static NSString * const kKeychainService = @"com.samcejko.twitcher";
static NSString * const kKeychainAccount = @"twitch-login";
static NSString * const kFallbackKey = @"twitchLogin.fallback";
static const NSTimeInterval TWValidateInterval = 3600;        // Twitch asks for an hourly check of tokens in use
static const NSTimeInterval TWRefreshAhead = 15 * 60;         // refresh this long before the token expires

typedef void (^TWRefreshWaiter)(BOOL refreshed);

@interface TWAuth ()
@property (nonatomic, copy) NSString *login;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *userId;
@property (nonatomic, copy) NSString *avatarURL;
@property (nonatomic, copy) NSString *accessToken;
@property (nonatomic, copy) NSString *refreshToken;
@property (nonatomic, copy) NSString *tokenClientId;          // the Client ID the tokens belong to
@property (nonatomic, strong) NSDate *expiresAt;
@property (nonatomic, strong) NSDate *lastValidated;
@property (nonatomic) BOOL deviceFlowActive;
@property (nonatomic) NSUInteger flowGeneration;
@property (nonatomic) BOOL refreshing;
@property (nonatomic, strong) NSMutableArray *refreshWaiters;
@end

@implementation TWAuth

+ (instancetype)shared
{
    static TWAuth *auth;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ auth = [[TWAuth alloc] init]; });
    return auth;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _refreshWaiters = [NSMutableArray array];
        [self load];
    }
    return self;
}

#pragma mark - Storage

- (NSDictionary *)keychainQuery
{
    return @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kKeychainService,
        (__bridge id)kSecAttrAccount: kKeychainAccount,
    };
}

- (NSData *)loadFromKeychain
{
    NSMutableDictionary *q = [[self keychainQuery] mutableCopy];
    q[(__bridge id)kSecReturnData] = @YES;
    q[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)q, &result);
    if (st == errSecSuccess && result) return (__bridge_transfer NSData *)result;
    if (st != errSecItemNotFound) TWLog(@"Keychain read failed: %ld", (long)st);
    return nil;
}

- (BOOL)saveToKeychain:(NSData *)data
{
    NSDictionary *q = [self keychainQuery];
    SecItemDelete((__bridge CFDictionaryRef)q);
    if (!data.length) return YES;
    NSMutableDictionary *add = [q mutableCopy];
    add[(__bridge id)kSecValueData] = data;
    add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
    OSStatus st = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    if (st != errSecSuccess) TWLog(@"Keychain write failed: %ld (the login is kept in the preferences instead)", (long)st);
    return st == errSecSuccess;
}

- (void)load
{
    NSData *data = [self loadFromKeychain];
    if (!data) {
        NSString *s = [[NSUserDefaults standardUserDefaults] stringForKey:kFallbackKey];
        data = [s dataUsingEncoding:NSUTF8StringEncoding];
    }
    NSDictionary *d = TWDict([TWUtils JSONObjectFromData:data]);
    if (!d) return;
    self.accessToken = TWStr(d[@"access"]);
    self.refreshToken = TWStr(d[@"refresh"]);
    self.login = TWStr(d[@"login"]);
    self.displayName = TWStr(d[@"displayName"]);
    self.userId = TWStr(d[@"userId"]);
    self.avatarURL = TWStr(d[@"avatar"]);
    self.tokenClientId = TWStr(d[@"clientId"]);
    double expires = TWDbl(d[@"expires"]);
    self.expiresAt = expires > 0 ? [NSDate dateWithTimeIntervalSince1970:expires] : nil;
    double validated = TWDbl(d[@"validated"]);
    self.lastValidated = validated > 0 ? [NSDate dateWithTimeIntervalSince1970:validated] : nil;
}

- (void)save
{
    NSData *data = nil;
    if (self.accessToken.length) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"access"] = self.accessToken;
        if (self.refreshToken) d[@"refresh"] = self.refreshToken;
        if (self.login) d[@"login"] = self.login;
        if (self.displayName) d[@"displayName"] = self.displayName;
        if (self.userId) d[@"userId"] = self.userId;
        if (self.avatarURL) d[@"avatar"] = self.avatarURL;
        if (self.tokenClientId) d[@"clientId"] = self.tokenClientId;
        if (self.expiresAt) d[@"expires"] = @([self.expiresAt timeIntervalSince1970]);
        if (self.lastValidated) d[@"validated"] = @([self.lastValidated timeIntervalSince1970]);
        data = [TWUtils JSONDataFromObject:d];
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([self saveToKeychain:data]) {
        [defaults removeObjectForKey:kFallbackKey];
    } else if (data) {
        [defaults setObject:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] forKey:kFallbackKey];
    } else {
        [defaults removeObjectForKey:kFallbackKey];
    }
    [defaults synchronize];
}

- (void)notify
{
    TWMain(^{ [[NSNotificationCenter defaultCenter] postNotificationName:TWAuthDidChangeNotification object:self]; });
}

#pragma mark - State

- (BOOL)isLoggedIn
{
    return self.accessToken.length > 0 && self.userId.length > 0;
}

- (NSString *)clientId
{
    NSString *override = [TWSettings clientIdOverride];
    if (override.length) return override;
    // tokens stay usable with the Client ID they were issued for, even after the setting was cleared
    if (self.tokenClientId.length && self.accessToken.length) return self.tokenClientId;
    return TWTwitchClientID;
}

- (BOOL)hasClientId
{
    return [self clientId].length > 0;
}

- (NSDictionary *)helixHeaders
{
    if (!self.accessToken.length) return @{ @"Client-Id": [self clientId] ?: @"" };
    return @{ @"Authorization": [@"Bearer " stringByAppendingString:self.accessToken], @"Client-Id": [self clientId] ?: @"" };
}

#pragma mark - Device code flow

- (void)beginDeviceFlow:(void (^)(NSString *, NSString *, NSError *))started completion:(void (^)(NSError *))completion
{
    NSString *clientId = [self clientId];
    if (!clientId.length) {
        if (started) started(nil, nil, TWMakeError(TWErrorAuth, L(@"No Client ID. Enter one in Settings > Account first.")));
        return;
    }
    [self cancelDeviceFlow];
    self.deviceFlowActive = YES;
    NSUInteger generation = ++self.flowGeneration;
    NSDictionary *fields = @{ @"client_id": clientId, @"scopes": TWTwitchScopes };
    [TWHTTP postForm:[TWTwitchAuthURL stringByAppendingString:@"/device"] fields:fields completion:^(id json, NSInteger status, NSError *error) {
        if (generation != self.flowGeneration) return;
        NSDictionary *d = TWDict(json);
        NSString *deviceCode = TWStr(d[@"device_code"]), *userCode = TWStr(d[@"user_code"]);
        NSString *verification = TWStr(d[@"verification_uri"]);
        if (error || !deviceCode.length || !userCode.length) {
            self.deviceFlowActive = NO;
            if (started) started(nil, nil, error ?: TWMakeError(TWErrorAuth, L(@"Twitch did not start the login. Check the Client ID.")));
            return;
        }
        NSTimeInterval interval = MAX(TWDbl(d[@"interval"]), 5.0);
        NSTimeInterval expires = TWDbl(d[@"expires_in"]);
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:expires > 0 ? expires : 1800];
        if (started) started(userCode, verification.length ? verification : @"https://www.twitch.tv/activate", nil);
        [self pollDeviceCode:deviceCode clientId:clientId interval:interval deadline:deadline generation:generation completion:completion];
    }];
}

- (void)pollDeviceCode:(NSString *)deviceCode clientId:(NSString *)clientId interval:(NSTimeInterval)interval deadline:(NSDate *)deadline
            generation:(NSUInteger)generation completion:(void (^)(NSError *))completion
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != self.flowGeneration) return;
        if ([deadline timeIntervalSinceNow] < 0) {
            self.deviceFlowActive = NO;
            if (completion) completion(TWMakeError(TWErrorAuth, L(@"The code expired. Start the login again.")));
            return;
        }
        NSDictionary *fields = @{ @"client_id": clientId, @"scopes": TWTwitchScopes, @"device_code": deviceCode,
                                  @"grant_type": @"urn:ietf:params:oauth:grant-type:device_code" };
        [TWHTTP postForm:[TWTwitchAuthURL stringByAppendingString:@"/token"] fields:fields completion:^(id json, NSInteger status, NSError *error) {
            if (generation != self.flowGeneration) return;
            NSDictionary *d = TWDict(json);
            NSString *token = TWStr(d[@"access_token"]);
            if (token.length) {
                self.accessToken = token;
                self.refreshToken = TWStr(d[@"refresh_token"]);
                self.tokenClientId = clientId;
                double expiresIn = TWDbl(d[@"expires_in"]);
                self.expiresAt = [NSDate dateWithTimeIntervalSinceNow:expiresIn > 0 ? expiresIn : 3600];
                self.deviceFlowActive = NO;
                [self save];
                [self fetchIdentityWithCompletion:^(NSError *identityError) {
                    if (completion) completion(identityError);
                }];
                return;
            }
            NSString *message = [TWStr(d[@"message"]) lowercaseString] ?: @"";
            BOOL pending = status == 400 && ([message rangeOfString:@"pending"].location != NSNotFound || [message rangeOfString:@"slow"].location != NSNotFound);
            if (pending || (error && status == 0)) {
                // not yet (or the network hiccupped): ask again, slower when Twitch says so
                NSTimeInterval next = [message rangeOfString:@"slow"].location != NSNotFound ? interval + 5 : interval;
                [self pollDeviceCode:deviceCode clientId:clientId interval:next deadline:deadline generation:generation completion:completion];
                return;
            }
            self.deviceFlowActive = NO;
            if (completion) completion(error ?: TWMakeError(TWErrorAuth, message.length ? message : L(@"The login was refused.")));
        }];
    });
}

- (void)cancelDeviceFlow
{
    if (!self.deviceFlowActive) return;
    self.flowGeneration++;
    self.deviceFlowActive = NO;
}

// Who logged in: validate gives the login and the user id, Helix the display name and the picture
- (void)fetchIdentityWithCompletion:(void (^)(NSError *error))completion
{
    [self validateWithCompletion:^(BOOL valid, NSError *error) {
        if (!valid) {
            if (completion) completion(error ?: TWMakeError(TWErrorAuth, L(@"The login could not be verified.")));
            return;
        }
        [self notify];
        [TWHTTP getJSON:[TWTwitchHelixURL stringByAppendingString:@"/users"] headers:[self helixHeaders] completion:^(id json, NSInteger status, NSError *e) {
            NSDictionary *user = TWDict([TWArr(TWDict(json)[@"data"]) firstObject]);
            if (user) {
                self.displayName = TWStr(user[@"display_name"]) ?: self.login;
                self.avatarURL = TWStr(user[@"profile_image_url"]);
                if (!self.login.length) self.login = TWStr(user[@"login"]);
                if (!self.userId.length) self.userId = TWStr(user[@"id"]);
                [self save];
                [self notify];
            }
            if (completion) completion(nil);
        }];
    }];
}

#pragma mark - Validation and refresh

- (void)validateWithCompletion:(void (^)(BOOL valid, NSError *error))completion
{
    if (!self.accessToken.length) { if (completion) completion(NO, nil); return; }
    NSDictionary *headers = @{ @"Authorization": [@"OAuth " stringByAppendingString:self.accessToken] };
    [TWHTTP getJSON:[TWTwitchAuthURL stringByAppendingString:@"/validate"] headers:headers completion:^(id json, NSInteger status, NSError *error) {
        NSDictionary *d = TWDict(json);
        if (status == 200 && d) {
            self.login = TWStr(d[@"login"]) ?: self.login;
            self.userId = TWStr(d[@"user_id"]) ?: self.userId;
            double expiresIn = TWDbl(d[@"expires_in"]);
            if (expiresIn > 0) self.expiresAt = [NSDate dateWithTimeIntervalSinceNow:expiresIn];
            self.lastValidated = [NSDate date];
            [self save];
            if (completion) completion(YES, nil);
            return;
        }
        if (status == 401) {
            // expired or revoked: a refresh may rescue it
            [self refreshTokenWithCompletion:^(BOOL refreshed) {
                if (completion) completion(refreshed, refreshed ? nil : TWMakeError(TWErrorAuth, L(@"The login expired. Log in again.")));
            }];
            return;
        }
        if (completion) completion(NO, error);   // (network trouble: nothing changes)
    }];
}

- (void)validateIfNeeded
{
    if (!self.isLoggedIn) return;
    BOOL expiringSoon = self.expiresAt && [self.expiresAt timeIntervalSinceNow] < TWRefreshAhead;
    if (expiringSoon) {
        [self refreshTokenWithCompletion:^(BOOL refreshed) {
            if (!refreshed) [self validateWithCompletion:nil];
        }];
        return;
    }
    if (!self.lastValidated || -[self.lastValidated timeIntervalSinceNow] > TWValidateInterval) {
        [self validateWithCompletion:^(BOOL valid, NSError *error) {
            if (!valid && !error) [self clearLogin];   // refused for good
        }];
    }
}

- (void)refreshTokenWithCompletion:(void (^)(BOOL))completion
{
    if (!self.refreshToken.length || ![self clientId].length) { if (completion) completion(NO); return; }
    if (completion) [self.refreshWaiters addObject:[completion copy]];
    if (self.refreshing) return;
    self.refreshing = YES;
    NSDictionary *fields = @{ @"client_id": [self clientId], @"grant_type": @"refresh_token", @"refresh_token": self.refreshToken };
    [TWHTTP postForm:[TWTwitchAuthURL stringByAppendingString:@"/token"] fields:fields completion:^(id json, NSInteger status, NSError *error) {
        self.refreshing = NO;
        NSDictionary *d = TWDict(json);
        NSString *token = TWStr(d[@"access_token"]);
        BOOL ok = token.length > 0;
        if (ok) {
            self.accessToken = token;
            NSString *refresh = TWStr(d[@"refresh_token"]);
            if (refresh.length) self.refreshToken = refresh;
            double expiresIn = TWDbl(d[@"expires_in"]);
            self.expiresAt = [NSDate dateWithTimeIntervalSinceNow:expiresIn > 0 ? expiresIn : 3600];
            self.lastValidated = [NSDate date];
            [self save];
            [self notify];
        } else if (status == 400 || status == 401) {
            TWLog(@"Token refresh refused (%ld): %@", (long)status, error.localizedDescription);
            [self clearLogin];   // the refresh token is dead: the user has to log in again
        }
        NSArray *waiters = [self.refreshWaiters copy];
        [self.refreshWaiters removeAllObjects];
        for (TWRefreshWaiter waiter in waiters) waiter(ok);
    }];
}

- (void)clearLogin
{
    BOOL was = self.isLoggedIn;
    self.accessToken = nil;
    self.refreshToken = nil;
    self.login = nil;
    self.displayName = nil;
    self.userId = nil;
    self.avatarURL = nil;
    self.expiresAt = nil;
    self.lastValidated = nil;
    [self save];
    if (was) [self notify];
}

- (void)logout
{
    [self cancelDeviceFlow];
    if (self.accessToken.length && [self clientId].length) {
        // (best effort: the token is forgotten here either way)
        NSDictionary *fields = @{ @"client_id": [self clientId], @"token": self.accessToken };
        [TWHTTP postForm:[TWTwitchAuthURL stringByAppendingString:@"/revoke"] fields:fields completion:nil];
    }
    [self clearLogin];
}

@end
