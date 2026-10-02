#import "TWChatMessage.h"
#import "TWCommon.h"

#pragma mark - IRC line

// The escaping of tag values (IRCv3): \s space, \: semicolon, \\ backslash, \r, \n
static NSString *TWUnescapeTag(NSString *value)
{
    if ([value rangeOfString:@"\\"].location == NSNotFound) return value;
    NSMutableString *out = [NSMutableString stringWithCapacity:value.length];
    NSUInteger n = value.length;
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = [value characterAtIndex:i];
        if (c != '\\' || i + 1 >= n) { [out appendFormat:@"%C", c]; continue; }
        unichar e = [value characterAtIndex:++i];
        switch (e) {
            case 's': [out appendString:@" "]; break;
            case ':': [out appendString:@";"]; break;
            case '\\': [out appendString:@"\\"]; break;
            case 'r': [out appendString:@"\r"]; break;
            case 'n': [out appendString:@"\n"]; break;
            default: [out appendFormat:@"%C", e]; break;
        }
    }
    return out;
}

@implementation TWIRCLine

+ (instancetype)lineWithString:(NSString *)raw
{
    NSString *s = [raw stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    if (!s.length) return nil;
    TWIRCLine *line = [[TWIRCLine alloc] init];
    NSUInteger pos = 0;
    // tags
    if ([s hasPrefix:@"@"]) {
        NSRange space = [s rangeOfString:@" "];
        if (space.location == NSNotFound) return nil;
        NSMutableDictionary *tags = [NSMutableDictionary dictionary];
        for (NSString *pair in [[s substringWithRange:NSMakeRange(1, space.location - 1)] componentsSeparatedByString:@";"]) {
            NSRange eq = [pair rangeOfString:@"="];
            if (eq.location == NSNotFound) { if (pair.length) tags[pair] = @""; continue; }
            tags[[pair substringToIndex:eq.location]] = TWUnescapeTag([pair substringFromIndex:eq.location + 1]);
        }
        line.tags = tags;
        pos = space.location + 1;
    } else {
        line.tags = @{};
    }
    // prefix
    if (pos < s.length && [s characterAtIndex:pos] == ':') {
        NSRange space = [s rangeOfString:@" " options:0 range:NSMakeRange(pos, s.length - pos)];
        if (space.location == NSNotFound) return nil;
        NSString *prefix = [s substringWithRange:NSMakeRange(pos + 1, space.location - pos - 1)];
        NSRange bang = [prefix rangeOfString:@"!"];
        line.nick = bang.location == NSNotFound ? prefix : [prefix substringToIndex:bang.location];
        pos = space.location + 1;
    }
    // command and parameters
    NSString *rest = pos < s.length ? [s substringFromIndex:pos] : @"";
    NSRange colon = [rest rangeOfString:@" :"];
    NSString *head = rest;
    if (colon.location != NSNotFound) {
        head = [rest substringToIndex:colon.location];
        line.trailing = [rest substringFromIndex:colon.location + 2];
    } else if ([rest hasPrefix:@":"]) {
        head = @"";
        line.trailing = [rest substringFromIndex:1];
    }
    NSMutableArray *words = [NSMutableArray array];
    for (NSString *w in [head componentsSeparatedByString:@" "]) if (w.length) [words addObject:w];
    if (!words.count) return nil;
    line.command = [words[0] uppercaseString];
    line.params = [words subarrayWithRange:NSMakeRange(1, words.count - 1)];
    return line;
}

- (NSString *)channel
{
    for (NSString *p in self.params) {
        if ([p hasPrefix:@"#"] && p.length > 1) return [[p substringFromIndex:1] lowercaseString];
    }
    return nil;
}

@end

@implementation TWChatEmoteRange
@end

#pragma mark - Message

// Twitch counts emote positions in Unicode code points; NSString counts UTF-16 units. The table maps one to the other.
static NSArray *TWCodePointOffsets(NSString *text)
{
    NSMutableArray *offsets = [NSMutableArray arrayWithCapacity:text.length + 1];
    NSUInteger n = text.length;
    for (NSUInteger i = 0; i < n; i++) {
        [offsets addObject:@(i)];
        unichar c = [text characterAtIndex:i];
        if (CFStringIsSurrogateHighCharacter(c) && i + 1 < n && CFStringIsSurrogateLowCharacter([text characterAtIndex:i + 1])) i++;
    }
    [offsets addObject:@(n)];
    return offsets;
}

static NSArray *TWParseEmotesTag(NSString *tag, NSString *text)
{
    if (!tag.length || !text.length) return @[];
    NSArray *offsets = TWCodePointOffsets(text);
    NSUInteger codePoints = offsets.count - 1;
    NSMutableArray *ranges = [NSMutableArray array];
    for (NSString *entry in [tag componentsSeparatedByString:@"/"]) {
        NSRange colon = [entry rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *emoteId = [entry substringToIndex:colon.location];
        for (NSString *span in [[entry substringFromIndex:colon.location + 1] componentsSeparatedByString:@","]) {
            NSArray *ends = [span componentsSeparatedByString:@"-"];
            if (ends.count != 2) continue;
            NSInteger start = [ends[0] integerValue], end = [ends[1] integerValue];
            if (start < 0 || end < start || (NSUInteger)end >= codePoints) continue;
            TWChatEmoteRange *r = [[TWChatEmoteRange alloc] init];
            r.emoteId = emoteId;
            NSUInteger from = [offsets[(NSUInteger)start] unsignedIntegerValue];
            NSUInteger to = [offsets[(NSUInteger)end + 1] unsignedIntegerValue];
            r.range = NSMakeRange(from, to - from);
            [ranges addObject:r];
        }
    }
    [ranges sortUsingComparator:^NSComparisonResult(TWChatEmoteRange *a, TWChatEmoteRange *b) {
        return a.range.location < b.range.location ? NSOrderedAscending : (a.range.location > b.range.location ? NSOrderedDescending : NSOrderedSame);
    }];
    return ranges;
}

static NSArray *TWParseBadgesTag(NSString *tag)
{
    NSMutableArray *badges = [NSMutableArray array];
    for (NSString *entry in [tag componentsSeparatedByString:@","]) {
        NSRange slash = [entry rangeOfString:@"/"];
        if (slash.location == NSNotFound || slash.location == 0) continue;
        [badges addObject:@[ [entry substringToIndex:slash.location], [entry substringFromIndex:slash.location + 1] ]];
    }
    return badges;
}

@implementation TWChatMessage

+ (instancetype)messageFromIRCLine:(TWIRCLine *)line ownLogin:(NSString *)ownLogin
{
    BOOL privmsg = [line.command isEqualToString:@"PRIVMSG"];
    BOOL userNotice = [line.command isEqualToString:@"USERNOTICE"];
    if (!privmsg && !userNotice) return nil;
    NSDictionary *tags = line.tags;
    TWChatMessage *m = [[TWChatMessage alloc] init];
    m.kind = privmsg ? TWChatKindMessage : TWChatKindUserNotice;
    m.messageId = tags[@"id"];
    m.login = [(privmsg ? line.nick : (tags[@"login"] ?: line.nick)) lowercaseString];
    NSString *display = tags[@"display-name"];
    m.displayName = display.length ? display : m.login;
    m.userId = tags[@"user-id"];
    NSString *color = tags[@"color"];
    m.colorHex = color.length ? color : nil;
    m.noticeType = tags[@"msg-id"];
    m.systemText = userNotice ? tags[@"system-msg"] : nil;
    m.bits = [tags[@"bits"] integerValue];
    m.isFirstMessage = [tags[@"first-msg"] isEqualToString:@"1"];
    m.isHighlighted = [m.noticeType isEqualToString:@"highlighted-message"];
    double ts = [tags[@"tmi-sent-ts"] doubleValue];
    m.timestamp = ts > 0 ? [NSDate dateWithTimeIntervalSince1970:ts / 1000.0] : [NSDate date];
    m.badges = TWParseBadgesTag(tags[@"badges"] ?: @"");
    NSString *text = line.trailing ?: @"";
    // "/me does something" arrives as \x01ACTION does something\x01
    if ([text hasPrefix:@"\x01" "ACTION "]) {   // (split literal: \x01A would be read as one hex escape)
        m.isAction = YES;
        text = [text substringFromIndex:8];
        if ([text hasSuffix:@"\x01"]) text = [text substringToIndex:text.length - 1];
    }
    m.text = text;
    m.emotes = TWParseEmotesTag(tags[@"emotes"], text);
    NSString *parentName = tags[@"reply-parent-display-name"];
    if (parentName.length) {
        m.replyParentName = parentName;
        m.replyParentText = tags[@"reply-parent-msg-body"];
        // Twitch puts "@parent " in front of a reply; the quoted line above makes that redundant
        NSString *prefix = [NSString stringWithFormat:@"@%@ ", parentName];
        if ([m.text length] > prefix.length && [[m.text lowercaseString] hasPrefix:[prefix lowercaseString]]) {
            NSUInteger cut = prefix.length;
            m.text = [m.text substringFromIndex:cut];
            NSMutableArray *shifted = [NSMutableArray array];
            for (TWChatEmoteRange *r in m.emotes) {
                if (r.range.location < cut) continue;
                TWChatEmoteRange *s = [[TWChatEmoteRange alloc] init];
                s.emoteId = r.emoteId;
                s.range = NSMakeRange(r.range.location - cut, r.range.length);
                [shifted addObject:s];
            }
            m.emotes = shifted;
        }
    }
    if (ownLogin.length) {
        m.isOwn = [m.login isEqualToString:[ownLogin lowercaseString]];
        if (!m.isOwn && m.text.length) {
            NSRange at = [m.text rangeOfString:[@"@" stringByAppendingString:ownLogin] options:NSCaseInsensitiveSearch];
            if (at.location != NSNotFound) {
                NSUInteger end = at.location + at.length;
                m.isMention = end >= m.text.length || ![[NSCharacterSet alphanumericCharacterSet] characterIsMember:[m.text characterAtIndex:end]];
            }
        }
    }
    if (userNotice && !m.text.length && !m.systemText.length) return nil;   // (nothing to show)
    return m;
}

+ (instancetype)noticeWithText:(NSString *)text
{
    TWChatMessage *m = [[TWChatMessage alloc] init];
    m.kind = TWChatKindNotice;
    m.systemText = text ?: @"";
    m.text = @"";
    m.timestamp = [NSDate date];
    m.badges = @[];
    m.emotes = @[];
    return m;
}

+ (instancetype)messageFromComment:(NSDictionary *)comment
{
    comment = TWDict(comment);
    if (!comment) return nil;
    TWChatMessage *m = [[TWChatMessage alloc] init];
    m.kind = TWChatKindMessage;
    m.messageId = TWStr(comment[@"id"]);
    m.login = TWStr(comment[@"login"]);
    m.displayName = TWStr(comment[@"displayName"]) ?: m.login;
    NSString *color = TWStr(comment[@"color"]);
    m.colorHex = color.length ? color : nil;
    m.badges = TWArr(comment[@"badges"]) ?: @[];
    m.timestamp = [NSDate dateWithTimeIntervalSince1970:TWDbl(comment[@"offset"])];   // (the offset in the video, not a time of day)
    NSMutableString *text = [NSMutableString string];
    NSMutableArray *emotes = [NSMutableArray array];
    for (NSDictionary *fragment in TWArr(comment[@"fragments"])) {
        NSString *part = TWStr(fragment[@"text"]) ?: @"";
        NSString *emoteId = TWStr(fragment[@"emoteId"]);
        if (emoteId.length) {
            TWChatEmoteRange *r = [[TWChatEmoteRange alloc] init];
            r.emoteId = emoteId;
            r.range = NSMakeRange(text.length, part.length);
            [emotes addObject:r];
        }
        [text appendString:part];
    }
    m.text = text;
    m.emotes = emotes;
    if (!m.login.length) return nil;
    return m;
}

- (NSString *)nameForDisplay
{
    if (!self.displayName.length) return self.login ?: @"";
    if (!self.login.length || [[self.displayName lowercaseString] isEqualToString:self.login]) return self.displayName;
    return [NSString stringWithFormat:@"%@ (%@)", self.displayName, self.login];
}

- (NSString *)colorKey
{
    if (self.colorHex.length) return self.colorHex;
    // Twitch's default palette for users without a colour, picked from the name as the website does
    static NSArray *palette;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        palette = @[ @"#FF0000", @"#0000FF", @"#008000", @"#B22222", @"#FF7F50", @"#9ACD32", @"#FF4500", @"#2E8B57",
                     @"#DAA520", @"#D2691E", @"#5F9EA0", @"#1E90FF", @"#FF69B4", @"#8A2BE2", @"#00FF7F" ];
    });
    NSString *name = self.login ?: @"";
    if (!name.length) return palette[0];
    NSUInteger n = [name characterAtIndex:0] + [name characterAtIndex:name.length - 1];
    return palette[n % palette.count];
}

@end
