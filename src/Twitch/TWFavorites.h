#import <Foundation/Foundation.h>
#import "TWModels.h"

// Channels marked on this device (no account needed). Posts TWFavoritesDidChangeNotification on every change.
@interface TWFavorites : NSObject

+ (instancetype)shared;

- (NSArray *)logins;                                  // in the order they were added
- (BOOL)contains:(NSString *)login;
- (void)add:(NSString *)login displayName:(NSString *)displayName avatarURL:(NSString *)avatarURL;
- (void)remove:(NSString *)login;
- (void)toggle:(TWChannel *)channel;
- (NSString *)displayNameFor:(NSString *)login;       // the last name seen
- (NSString *)avatarURLFor:(NSString *)login;
- (void)rememberChannel:(TWChannel *)channel;         // refreshes the stored name and picture

@end
