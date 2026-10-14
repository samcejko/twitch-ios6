#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// A web link found in a text (a chat message, a stream title, a channel's description)
@interface TWTextLink : NSObject
@property (nonatomic, copy) NSString *url;      // with its scheme: "http://" is put before bare "www." and domain links
@property (nonatomic) NSRange range;            // in the text, UTF-16 units
@end

// Finding the web links in plain text, and showing them in a label. A link is a word that starts with http:// or
// https:// or www., or a bare domain with a common ending (twitch.tv/xyz, youtu.be/abc, discord.gg/..., example.com);
// brackets and punctuation around a link are left out of it.
@interface TWLinks : NSObject

// The links in a text, in order
+ (NSArray *)linksInText:(NSString *)text;
// The link in one word (no spaces), or nil. `range` (may be NULL) receives the part of the word that is the link.
+ (NSString *)urlInWord:(NSString *)word range:(NSRange *)range;

// Shows the text in the label with the links in the link colour (the label's own font, colour and shadow for the
// rest); plain text when there are no links. The label's lineBreakMode and alignment are kept.
+ (void)styleLabel:(UILabel *)label text:(NSString *)text links:(NSArray *)links linkColor:(UIColor *)linkColor;

// "example.com/page" for a sheet button: without the scheme and "www.", cut when too long
+ (NSString *)shortTitleForURL:(NSString *)url;

@end
