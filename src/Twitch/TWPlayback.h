#import <Foundation/Foundation.h>
#import "TWHTTP.h"

// One rendition of an HLS master playlist
@interface TWVariant : NSObject
@property (nonatomic, copy) NSString *name;        // "720p60", "1080p60 (source)", "audio_only"
@property (nonatomic, copy) NSString *groupId;     // "chunked" is the source rendition
@property (nonatomic, copy) NSString *codecs;
@property (nonatomic, copy) NSString *url;         // the media playlist
@property (nonatomic) NSInteger width;
@property (nonatomic) NSInteger height;
@property (nonatomic) NSInteger bandwidth;
@property (nonatomic) double frameRate;
- (BOOL)isAudioOnly;
- (BOOL)isSource;
- (NSString *)title;                               // for menus: "720p60", "Audio only", "1080p60 (source)"
- (NSString *)qualityKey;                          // what the quality setting stores: "source", "720", "480", "audio"...
@end

// Getting from a channel or video to playlists the player can use.
// Completion blocks run on the main thread; a cancelled task never calls back.
@interface TWPlayback : NSObject

// The renditions of a live channel (TWVariant, highest first, audio last). Errors: TWErrorOffline when the channel is
// not live, TWErrorRestricted for subscriber-only or geoblocked content.
+ (TWHTTPTask *)variantsForChannel:(NSString *)login completion:(void (^)(NSArray *variants, NSError *error))completion;
+ (TWHTTPTask *)variantsForVideo:(NSString *)videoId completion:(void (^)(NSArray *variants, NSError *error))completion;

// The master playlist text as renditions
+ (NSArray *)variantsFromMaster:(NSString *)text baseURL:(NSURL *)base;

// Whether this device decodes the rendition (the iPad 2 and its contemporaries manage H.264 up to 1080p30; the
// iPhone 4 and older up to 720p30)
+ (BOOL)deviceCanPlay:(TWVariant *)variant;
// The rendition to start with for a quality preference (TWSettings), nil = "auto" (let the player choose)
+ (TWVariant *)variantFrom:(NSArray *)variants forQuality:(NSString *)quality;
// The playable video renditions of a list, highest first (what "auto" may switch between)
+ (NSArray *)playableVariants:(NSArray *)variants;
// A master playlist (text) naming the given renditions through the proxy; `first` is the one the player begins with
+ (NSString *)masterPlaylistForVariants:(NSArray *)variants startingWith:(TWVariant *)first;

// The URL for the player: the chosen rendition through the proxy, or a filtered master playlist for "auto"
+ (NSURL *)playerURLForVariants:(NSArray *)variants quality:(NSString *)quality chosen:(TWVariant **)chosen;

@end
