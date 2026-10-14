#import "TWLinks.h"
#import "TWUtils.h"
#import "TWCommon.h"

@implementation TWTextLink
@end

// The endings a bare domain (no scheme, no www.) is recognised by: the big ones, the ones streamers link to all the
// time (twitch.tv, youtu.be, discord.gg) and the usual link shorteners. Kept short on purpose: every ending here
// turns "word.ending" in a sentence into a link.
static NSSet *TWKnownEndings(void)
{
    static NSSet *endings;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        endings = [NSSet setWithArray:@[ @"com", @"net", @"org", @"tv", @"gg", @"io", @"be", @"me", @"co", @"cz", @"sk", @"de", @"eu",
                                         @"uk", @"info", @"app", @"live", @"stream", @"fm", @"link", @"xyz", @"ly", @"gl", @"to", @"at",
                                         @"pl", @"fr", @"es", @"nl", @"ru", @"us", @"ch", @"moe", @"wtf" ]];
    });
    return endings;
}

// letters, digits, dots and dashes, at least one dot, no empty labels
static BOOL TWIsHost(NSString *host)
{
    if (host.length < 3 || [host hasPrefix:@"."] || [host hasSuffix:@"."] || [host hasPrefix:@"-"]) return NO;
    if ([host rangeOfString:@"."].location == NSNotFound || [host rangeOfString:@".."].location != NSNotFound) return NO;
    for (NSUInteger i = 0; i < host.length; i++) {
        unichar c = [host characterAtIndex:i];
        BOOL ok = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '-';
        if (!ok) return NO;
    }
    return YES;
}

// The host part of "host/path?query#fragment" or "host:port/..."
static NSString *TWHostOf(NSString *lower)
{
    NSRange end = [lower rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/?#:"]];
    return end.location == NSNotFound ? lower : [lower substringToIndex:end.location];
}

@implementation TWLinks

+ (NSString *)urlForCandidate:(NSString *)candidate
{
    NSString *lower = [candidate lowercaseString];
    if ([lower rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound) return nil;
    if ([lower hasPrefix:@"http://"] || [lower hasPrefix:@"https://"]) {
        NSString *rest = [lower substringFromIndex:[lower rangeOfString:@"://"].location + 3];
        NSString *host = TWHostOf(rest);
        if (![host isEqualToString:@"localhost"] && !TWIsHost(host)) return nil;
        return candidate;
    }
    NSString *host = TWHostOf(lower);
    if (!TWIsHost(host)) return nil;
    if ([lower hasPrefix:@"www."]) {
        return host.length > 4 ? [@"http://" stringByAppendingString:candidate] : nil;
    }
    // a bare domain: "twitch.tv/xyz", "youtu.be/abc", "example.com"
    NSArray *labels = [host componentsSeparatedByString:@"."];
    if (labels.count < 2 || ![TWKnownEndings() containsObject:labels.lastObject]) return nil;
    return [@"http://" stringByAppendingString:candidate];
}

+ (NSString *)urlInWord:(NSString *)word range:(NSRange *)range
{
    static NSCharacterSet *opening, *closing;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        opening = [NSCharacterSet characterSetWithCharactersInString:@"([{<\"'"];
        closing = [NSCharacterSet characterSetWithCharactersInString:@".,;:!?)]}>\"'"];
    });
    NSUInteger n = word.length, start = 0, end = n;
    if (n < 4) return nil;
    while (start < end && [opening characterIsMember:[word characterAtIndex:start]]) start++;
    while (end > start && [closing characterIsMember:[word characterAtIndex:end - 1]]) {
        if ([word characterAtIndex:end - 1] == ')') {
            // a ")" that closes a "(" inside the link belongs to it (wikipedia.org/wiki/Foo_(bar))
            NSUInteger opens = 0, closes = 0;
            for (NSUInteger i = start; i < end; i++) {
                unichar c = [word characterAtIndex:i];
                if (c == '(') opens++;
                else if (c == ')') closes++;
            }
            if (closes <= opens) break;
        }
        end--;
    }
    if (end <= start + 3) return nil;
    NSString *url = [self urlForCandidate:[word substringWithRange:NSMakeRange(start, end - start)]];
    if (!url) return nil;
    if (range) *range = NSMakeRange(start, end - start);
    return url;
}

+ (NSArray *)linksInText:(NSString *)text
{
    NSMutableArray *links = [NSMutableArray array];
    if (!text.length) return links;
    NSCharacterSet *space = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSUInteger n = text.length, pos = 0;
    while (pos < n) {
        while (pos < n && [space characterIsMember:[text characterAtIndex:pos]]) pos++;
        NSUInteger end = pos;
        while (end < n && ![space characterIsMember:[text characterAtIndex:end]]) end++;
        if (end > pos) {
            NSRange r = NSMakeRange(0, 0);
            NSString *url = [self urlInWord:[text substringWithRange:NSMakeRange(pos, end - pos)] range:&r];
            if (url) {
                TWTextLink *link = [[TWTextLink alloc] init];
                link.url = url;
                link.range = NSMakeRange(pos + r.location, r.length);
                [links addObject:link];
            }
        }
        pos = end;
    }
    return links;
}

+ (void)styleLabel:(UILabel *)label text:(NSString *)text links:(NSArray *)links linkColor:(UIColor *)linkColor
{
    if (!label) return;
    if (!links.count || !text.length) {
        label.text = text;
        return;
    }
    // (every attribute set explicitly: on iOS 6 the attributed text decides, not the label's properties. The line
    // break mode goes in only for one-line labels: a truncating paragraph style folds a multi-line label into one line.)
    NSMutableDictionary *base = [NSMutableDictionary dictionary];
    if (label.font) base[NSFontAttributeName] = label.font;
    if (label.textColor) base[NSForegroundColorAttributeName] = label.textColor;
    if (label.shadowColor) {
        NSShadow *shadow = [[NSShadow alloc] init];
        shadow.shadowColor = label.shadowColor;
        shadow.shadowOffset = label.shadowOffset;
        base[NSShadowAttributeName] = shadow;
    }
    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.alignment = label.textAlignment;
    paragraph.lineBreakMode = label.numberOfLines == 1 ? label.lineBreakMode : NSLineBreakByWordWrapping;
    base[NSParagraphStyleAttributeName] = paragraph;
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:text attributes:base];
    for (TWTextLink *link in links) {
        if (NSMaxRange(link.range) <= text.length && linkColor) [s addAttribute:NSForegroundColorAttributeName value:linkColor range:link.range];
    }
    label.attributedText = s;
}

+ (NSString *)shortTitleForURL:(NSString *)url
{
    NSString *s = url ?: @"";
    for (NSString *prefix in @[ @"https://", @"http://" ]) {
        if ([[s lowercaseString] hasPrefix:prefix]) { s = [s substringFromIndex:prefix.length]; break; }
    }
    if ([[s lowercaseString] hasPrefix:@"www."]) s = [s substringFromIndex:4];
    if ([s hasSuffix:@"/"] && s.length > 1) s = [s substringToIndex:s.length - 1];
    return [TWUtils truncate:s to:60];
}

@end
