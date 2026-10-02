#import <Foundation/Foundation.h>

// Quality preference values (also what the quality menu of the player stores)
extern NSString * const TWQualityAuto;      // the player switches between what the device can decode
extern NSString * const TWQualitySource;
extern NSString * const TWQualityAudio;     // audio only
// ...and "1080", "720", "480", "360", "160": the highest rendition that is not above this height

// User preferences, kept in NSUserDefaults. Setters post TWSettingsDidChangeNotification.
@interface TWSettings : NSObject

+ (void)registerDefaults;
+ (void)save;

// Appearance
+ (BOOL)darkTheme;
+ (void)setDarkTheme:(BOOL)value;

// Playback
+ (NSString *)preferredQuality;
+ (void)setPreferredQuality:(NSString *)value;
+ (BOOL)backgroundAudio;            // keep the sound playing when the app goes to the background
+ (void)setBackgroundAudio:(BOOL)value;
+ (BOOL)keepScreenOn;               // no auto-lock while a video plays
+ (void)setKeepScreenOn:(BOOL)value;
+ (BOOL)showChat;                   // the chat next to the video, as it was left the last time
+ (void)setShowChat:(BOOL)value;

// Browsing
+ (NSString *)streamLanguage;       // "" = every language, else a lower case ISO 639-1 code ("cs")
+ (void)setStreamLanguage:(NSString *)value;

// Chat
+ (NSInteger)chatFontSize;          // 0 small, 1 medium, 2 large
+ (void)setChatFontSize:(NSInteger)value;
+ (BOOL)chatTimestamps;
+ (void)setChatTimestamps:(BOOL)value;
+ (BOOL)animatedEmotes;
+ (void)setAnimatedEmotes:(BOOL)value;
+ (BOOL)thirdPartyEmotes;           // BetterTTV, FrankerFaceZ, 7TV
+ (void)setThirdPartyEmotes:(BOOL)value;
+ (BOOL)showDeletedMessages;        // keep the text of messages a moderator removed (greyed out)
+ (void)setShowDeletedMessages:(BOOL)value;
+ (BOOL)chatSeparators;             // a line between messages
+ (void)setChatSeparators:(BOOL)value;

// Network
+ (BOOL)verifyTLS;
+ (void)setVerifyTLS:(BOOL)value;

// Account: the Client ID of the Twitch application the login goes through ("" = the one built into the app)
+ (NSString *)clientIdOverride;
+ (void)setClientIdOverride:(NSString *)value;

// Resume positions of videos: seconds by video id (the last 200 are kept)
+ (NSTimeInterval)resumePositionForVideo:(NSString *)videoId;
+ (void)setResumePosition:(NSTimeInterval)seconds forVideo:(NSString *)videoId;

// Search history (most recent first, 12 kept)
+ (NSArray *)recentSearches;
+ (void)addRecentSearch:(NSString *)query;
+ (void)clearRecentSearches;

@end
