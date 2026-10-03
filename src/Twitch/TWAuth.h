#import <Foundation/Foundation.h>

// The optional Twitch login: the "device code" flow (the user types a short code at twitch.tv/activate on any
// device), tokens kept in the keychain (or in the preferences when the keychain is not available to a fake-signed
// app), validated hourly as Twitch requires, refreshed before they expire.
// Posts TWAuthDidChangeNotification on login, logout and when the user's details arrive.
@interface TWAuth : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) BOOL isLoggedIn;
@property (nonatomic, readonly, copy) NSString *login;
@property (nonatomic, readonly, copy) NSString *displayName;
@property (nonatomic, readonly, copy) NSString *userId;
@property (nonatomic, readonly, copy) NSString *avatarURL;
@property (nonatomic, readonly, copy) NSString *accessToken;
@property (nonatomic, readonly, strong) NSDate *expiresAt;

// The Client ID the Helix requests go with (the app's own, see TWConfig.h)
- (NSString *)clientId;

// Headers for Helix: Authorization: Bearer ..., Client-Id: ...
- (NSDictionary *)helixHeaders;

// Login. `started` gets the code to type and the address to type it at (or an error); `completion` fires when the
// user has finished at twitch.tv (or the code expired, or -cancelDeviceFlow was called: then error = cancelled).
- (void)beginDeviceFlow:(void (^)(NSString *userCode, NSString *verificationURL, NSError *error))started
             completion:(void (^)(NSError *error))completion;
- (void)cancelDeviceFlow;
@property (nonatomic, readonly) BOOL deviceFlowActive;

// Launch and foreground: validates the token when the last check is an hour old, refreshes when it expires soon
- (void)validateIfNeeded;
// A fresh access token (after a 401). completion(YES) when the token changed.
- (void)refreshTokenWithCompletion:(void (^)(BOOL refreshed))completion;
- (void)logout;

@end
