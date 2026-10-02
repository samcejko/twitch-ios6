#import "TWChatLayout.h"
#import "TWEmotes.h"
#import "TWSettings.h"
#import "TWTheme.h"
#import "TWUtils.h"
#import "TWCommon.h"

static NSString * const TWChatImageAttribute = @"TWChatImage";   // NSNumber: index into imageSlots
static NSString * const TWChatLinkAttribute = @"TWChatLink";     // NSNumber: index into links
static const CGFloat TWChatLineSpacing = 2.0;

#pragma mark - Style

@implementation TWChatStyle

+ (instancetype)currentStyleForWidth:(CGFloat)width channelId:(NSString *)channelId
{
    TWTheme *t = [TWTheme shared];
    TWChatStyle *s = [[TWChatStyle alloc] init];
    s.fontSize = [t chatFontSize];
    s.width = MAX(40, floor(width));
    s.screenScale = [TWUtils screenScale];
    s.showTimestamps = [TWSettings chatTimestamps];
    s.animatedEmotes = [TWSettings animatedEmotes];
    s.thirdPartyEmotes = [TWSettings thirdPartyEmotes];
    s.showDeleted = [TWSettings showDeletedMessages];
    s.dark = t.isDark;
    s.channelId = channelId;
    s.textColor = [t chatTextColor];
    s.systemColor = [t chatSystemTextColor];
    s.deletedColor = [t chatDeletedTextColor];
    s.linkColor = [t linkColor];
    s.version = (NSUInteger)(s.fontSize * 100) ^ (s.showTimestamps ? 1 : 0) ^ (s.animatedEmotes ? 2 : 0) ^ (s.thirdPartyEmotes ? 4 : 0)
                ^ (s.showDeleted ? 8 : 0) ^ (s.dark ? 16 : 0) ^ ([channelId hash] << 5);
    return s;
}

- (CGFloat)emoteHeight
{
    return round(self.fontSize * 1.8);
}

- (CGFloat)badgeSize
{
    return round(self.fontSize * 1.2);
}

@end

@implementation TWChatImageSlot
@end

@implementation TWChatLink
@end

#pragma mark - Run delegates

typedef struct {
    CGFloat width;
    CGFloat ascent;
    CGFloat descent;
} TWRunMetrics;

static void TWRunDealloc(void *refCon) { free(refCon); }
static CGFloat TWRunAscent(void *refCon) { return ((TWRunMetrics *)refCon)->ascent; }
static CGFloat TWRunDescent(void *refCon) { return ((TWRunMetrics *)refCon)->descent; }
static CGFloat TWRunWidth(void *refCon) { return ((TWRunMetrics *)refCon)->width; }

// A placeholder character that takes the room of an image, vertically centred on the text's x-height
static void TWAppendImagePlaceholder(NSMutableAttributedString *string, CGFloat width, CGFloat height, CTFontRef font, NSUInteger slotIndex)
{
    TWRunMetrics *metrics = malloc(sizeof(TWRunMetrics));
    if (!metrics) return;
    CGFloat fontAscent = CTFontGetAscent(font), fontDescent = CTFontGetDescent(font);
    CGFloat middle = (fontAscent - fontDescent) / 2;   // the centre of the text's body above the baseline
    metrics->width = width + 2;                          // a little air on both sides
    metrics->ascent = ceil(middle + height / 2);
    metrics->descent = ceil(height / 2 - middle);
    if (metrics->descent < fontDescent) metrics->descent = fontDescent;
    CTRunDelegateCallbacks callbacks;
    callbacks.version = kCTRunDelegateVersion1;
    callbacks.dealloc = TWRunDealloc;
    callbacks.getAscent = TWRunAscent;
    callbacks.getDescent = TWRunDescent;
    callbacks.getWidth = TWRunWidth;
    CTRunDelegateRef delegate = CTRunDelegateCreate(&callbacks, metrics);
    if (!delegate) { free(metrics); return; }
    NSAttributedString *placeholder = [[NSAttributedString alloc] initWithString:@"￼" attributes:@{
        (__bridge NSString *)kCTRunDelegateAttributeName: (__bridge id)delegate,
        (__bridge NSString *)kCTFontAttributeName: (__bridge id)font,
        TWChatImageAttribute: @(slotIndex),
    }];
    CFRelease(delegate);
    [string appendAttributedString:placeholder];
}

#pragma mark - Layout

@interface TWChatLayout ()
@property (nonatomic) CGFloat height;
@property (nonatomic) CGFloat width;
@property (nonatomic, strong) NSArray *imageSlots;
@property (nonatomic, strong) NSArray *links;
@property (nonatomic) NSRange nameRange;
@property (nonatomic, strong) NSAttributedString *string;
@end

@implementation TWChatLayout {
    CTFrameRef _frame;
    CGFloat _pathHeight;     // the height of the rectangle the frame was laid out in (Core Text measures from its bottom)
    NSArray *_lineRects;     // NSValue CGRect per line, UIKit coordinates
}

- (void)dealloc
{
    if (_frame) CFRelease(_frame);
}

+ (TWChatLayout *)cachedLayoutForMessage:(TWChatMessage *)message style:(TWChatStyle *)style
{
    TWChatLayout *layout = message.layout;
    if ([layout isKindOfClass:[TWChatLayout class]] && fabs(message.layoutWidth - style.width) < 0.5 && message.layoutStyleVersion == style.version) return layout;
    layout = [self layoutForMessage:message style:style];
    message.layout = layout;
    message.layoutWidth = style.width;
    message.layoutStyleVersion = style.version;
    return layout;
}

static NSDictionary *TWTextAttributes(CTFontRef font, UIColor *color)
{
    return @{ (__bridge NSString *)kCTFontAttributeName: (__bridge id)font,
              (__bridge NSString *)kCTForegroundColorAttributeName: (__bridge id)color.CGColor };
}

static BOOL TWLooksLikeLink(NSString *word)
{
    NSString *lower = [word lowercaseString];
    if ([lower hasPrefix:@"http://"] || [lower hasPrefix:@"https://"]) return word.length > 10;
    if ([lower hasPrefix:@"www."] && [lower rangeOfString:@"."].location != NSNotFound) return word.length > 6;
    return NO;
}

+ (TWChatLayout *)layoutForMessage:(TWChatMessage *)message style:(TWChatStyle *)style
{
    TWChatLayout *layout = [[TWChatLayout alloc] init];
    layout.width = style.width;
    NSMutableArray *slots = [NSMutableArray array];
    NSMutableArray *links = [NSMutableArray array];
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc] init];
    CGFloat size = style.fontSize;
    CTFontRef font = CTFontCreateWithName(CFSTR("Helvetica"), size, NULL);
    CTFontRef bold = CTFontCreateWithName(CFSTR("Helvetica-Bold"), size, NULL);
    CTFontRef small = CTFontCreateWithName(CFSTR("Helvetica"), size - 2, NULL);
    CTFontRef italic = CTFontCreateWithName(CFSTR("Helvetica-Oblique"), size, NULL);
    layout.nameRange = NSMakeRange(NSNotFound, 0);
    BOOL retina = style.screenScale > 1.5;
    TWEmoteStore *store = [TWEmoteStore shared];

    // timestamp
    if (style.showTimestamps && message.timestamp && message.kind != TWChatKindNotice) {
        static NSDateFormatter *formatter;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            formatter = [[NSDateFormatter alloc] init];
            formatter.dateFormat = @"HH:mm";
        });
        NSString *stamp;
        @synchronized (formatter) { stamp = [formatter stringFromDate:message.timestamp]; }
        [s appendAttributedString:[[NSAttributedString alloc] initWithString:[stamp stringByAppendingString:@" "] attributes:TWTextAttributes(small, style.systemColor)]];
    }

    // system line (notices, subscriptions...)
    if (message.kind == TWChatKindNotice || (message.kind == TWChatKindUserNotice && message.systemText.length)) {
        NSString *text = message.systemText ?: @"";
        [s appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:TWTextAttributes(message.kind == TWChatKindNotice ? italic : bold, style.systemColor)]];
        if (message.kind == TWChatKindUserNotice && message.text.length) {
            [s appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:TWTextAttributes(font, style.textColor)]];
        }
    }

    if (message.kind != TWChatKindNotice && (message.kind == TWChatKindMessage || message.text.length)) {
        // reply header
        if (message.replyParentName.length) {
            NSString *quoted = [TWUtils truncate:message.replyParentText ?: @"" to:60];
            NSString *header = [NSString stringWithFormat:@"↪ @%@: %@\n", message.replyParentName, quoted];
            [s appendAttributedString:[[NSAttributedString alloc] initWithString:header attributes:TWTextAttributes(small, style.systemColor)]];
        }
        // badges
        CGFloat badge = [style badgeSize];
        for (NSArray *b in message.badges) {
            if (b.count < 2) continue;
            NSString *url = [store badgeURLForSet:b[0] version:b[1] channelId:style.channelId scale2x:retina];
            if (!url) continue;
            TWChatImageSlot *slot = [[TWChatImageSlot alloc] init];
            slot.url = url;
            slot.name = b[0];
            [slots addObject:slot];
            TWAppendImagePlaceholder(s, badge, badge, font, slots.count - 1);
        }
        // name
        UIColor *nameColor = [TWUtils readableColor:[TWUtils colorFromHex:[message colorKey]] ?: style.textColor onDark:style.dark];
        NSString *name = message.displayName.length ? message.displayName : (message.login ?: @"");
        NSUInteger nameStart = s.length;
        [s appendAttributedString:[[NSAttributedString alloc] initWithString:name attributes:TWTextAttributes(bold, nameColor)]];
        layout.nameRange = NSMakeRange(nameStart, name.length);
        BOOL deleted = message.isDeleted && !style.showDeleted;
        UIColor *bodyColor = message.isDeleted ? style.deletedColor : (message.isAction ? nameColor : style.textColor);
        [s appendAttributedString:[[NSAttributedString alloc] initWithString:message.isAction ? @" " : @": " attributes:TWTextAttributes(font, style.textColor)]];
        if (deleted) {
            [s appendAttributedString:[[NSAttributedString alloc] initWithString:L(@"<message deleted>") attributes:TWTextAttributes(italic, style.deletedColor)]];
        } else {
            [self appendText:message.text ofMessage:message to:s slots:slots links:links style:style font:font bold:bold color:bodyColor store:store];
        }
    }

    // paragraph style: word wrapping, a little space between lines
    CTLineBreakMode lineBreak = kCTLineBreakByWordWrapping;
    CGFloat spacing = TWChatLineSpacing;
    CTParagraphStyleSetting settings[] = {
        { kCTParagraphStyleSpecifierLineBreakMode, sizeof(lineBreak), &lineBreak },
        { kCTParagraphStyleSpecifierLineSpacingAdjustment, sizeof(spacing), &spacing },
    };
    CTParagraphStyleRef paragraph = CTParagraphStyleCreate(settings, 2);
    if (s.length) [s addAttribute:(__bridge NSString *)kCTParagraphStyleAttributeName value:(__bridge id)paragraph range:NSMakeRange(0, s.length)];
    CFRelease(paragraph);

    // the frame
    CTFramesetterRef setter = CTFramesetterCreateWithAttributedString((__bridge CFAttributedStringRef)s);
    CGSize fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRangeMake(0, 0), NULL, CGSizeMake(style.width, 10000), NULL);
    // (plenty of room below: a line is left out of the frame when the rectangle is too short, and the suggested size
    // is not always generous with tall emotes; the real height comes from the lines themselves)
    CGFloat frameHeight = ceil(fit.height) * 2 + 200;
    CGPathRef path = CGPathCreateWithRect(CGRectMake(0, 0, style.width, frameHeight), NULL);
    CTFrameRef frame = CTFramesetterCreateFrame(setter, CFRangeMake(0, 0), path, NULL);
    CGPathRelease(path);
    CFRelease(setter);
    layout->_frame = frame;
    layout->_pathHeight = frameHeight;
    layout.string = s;

    // image positions and line rectangles, in UIKit coordinates
    CFArrayRef lines = CTFrameGetLines(frame);
    CFIndex lineCount = CFArrayGetCount(lines);
    CGPoint *origins = lineCount ? malloc(sizeof(CGPoint) * (size_t)lineCount) : NULL;
    if (origins) CTFrameGetLineOrigins(frame, CFRangeMake(0, 0), origins);
    NSMutableArray *lineRects = [NSMutableArray array];
    CGFloat bottom = 0;
    for (CFIndex i = 0; i < lineCount && origins; i++) {
        CTLineRef line = CFArrayGetValueAtIndex(lines, i);
        CGFloat ascent = 0, descent = 0, leading = 0;
        double lineWidth = CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
        CGFloat baselineY = frameHeight - origins[i].y;   // flipped
        CGRect lineRect = CGRectMake(origins[i].x, baselineY - ascent, (CGFloat)lineWidth, ascent + descent);
        [lineRects addObject:[NSValue valueWithCGRect:lineRect]];
        bottom = MAX(bottom, baselineY + descent);
        CFArrayRef runs = CTLineGetGlyphRuns(line);
        for (CFIndex r = 0; r < CFArrayGetCount(runs); r++) {
            CTRunRef run = CFArrayGetValueAtIndex(runs, r);
            NSDictionary *attributes = (__bridge NSDictionary *)CTRunGetAttributes(run);
            NSNumber *slotIndex = attributes[TWChatImageAttribute];
            if (!slotIndex || slotIndex.unsignedIntegerValue >= slots.count) continue;
            CGFloat runAscent = 0, runDescent = 0;
            double runWidth = CTRunGetTypographicBounds(run, CFRangeMake(0, 0), &runAscent, &runDescent, NULL);
            CFRange stringRange = CTRunGetStringRange(run);
            CGFloat x = origins[i].x + CTLineGetOffsetForStringIndex(line, stringRange.location, NULL);
            TWChatImageSlot *slot = slots[slotIndex.unsignedIntegerValue];
            // (the placeholder is 2 points wider than the image: one on each side)
            slot.frame = CGRectMake(x + 1, baselineY - runAscent, (CGFloat)runWidth - 2, runAscent + runDescent);
        }
    }
    free(origins);
    layout->_lineRects = lineRects;
    layout.imageSlots = slots;
    layout.links = links;
    layout.height = MAX(ceil(bottom), ceil(fit.height)) + 1;
    CFRelease(font);
    CFRelease(bold);
    CFRelease(small);
    CFRelease(italic);
    return layout;
}

// The message text: Twitch emotes by their positions, third-party emotes by word, links, mentions
+ (void)appendText:(NSString *)text ofMessage:(TWChatMessage *)message to:(NSMutableAttributedString *)s slots:(NSMutableArray *)slots
             links:(NSMutableArray *)links style:(TWChatStyle *)style font:(CTFontRef)font bold:(CTFontRef)bold color:(UIColor *)color store:(TWEmoteStore *)store
{
    if (!text.length) return;
    CGFloat emoteHeight = [style emoteHeight];
    BOOL retina = style.screenScale > 1.5;
    BOOL animate = style.animatedEmotes;
    NSDictionary *plain = TWTextAttributes(font, color);
    NSDictionary *strong = TWTextAttributes(bold, color);
    NSDictionary *link = TWTextAttributes(font, style.linkColor);
    // Twitch emotes come as positions; everything else is decided word by word
    NSArray *emotes = message.emotes;
    NSUInteger emoteIndex = 0;
    NSUInteger pos = 0, n = text.length;
    while (pos < n) {
        // the next Twitch emote at or after pos
        while (emoteIndex < emotes.count && [(TWChatEmoteRange *)emotes[emoteIndex] range].location < pos) emoteIndex++;
        TWChatEmoteRange *next = emoteIndex < emotes.count ? emotes[emoteIndex] : nil;
        if (next && next.range.location == pos && NSMaxRange(next.range) <= n) {
            NSString *word = [text substringWithRange:next.range];
            TWEmote *emote = [TWEmoteStore twitchEmoteWithId:next.emoteId name:word animated:animate];
            [self appendEmote:emote to:s slots:slots height:emoteHeight font:font retina:retina];
            pos = NSMaxRange(next.range);
            emoteIndex++;
            continue;
        }
        // a run of spaces
        if ([text characterAtIndex:pos] == ' ') {
            NSUInteger end = pos;
            while (end < n && [text characterAtIndex:end] == ' ') end++;
            [s appendAttributedString:[[NSAttributedString alloc] initWithString:[text substringWithRange:NSMakeRange(pos, end - pos)] attributes:plain]];
            pos = end;
            continue;
        }
        // a word: up to the next space or the next Twitch emote
        NSUInteger end = pos;
        NSUInteger limit = next ? MIN(next.range.location, n) : n;
        while (end < limit && [text characterAtIndex:end] != ' ') end++;
        if (end == pos) end = MIN(pos + 1, n);
        NSString *word = [text substringWithRange:NSMakeRange(pos, end - pos)];
        TWEmote *emote = style.thirdPartyEmotes ? [store thirdPartyEmoteNamed:word channelId:style.channelId] : nil;
        if (emote) {
            [self appendEmote:emote to:s slots:slots height:emoteHeight font:font retina:retina];
        } else if ([word hasPrefix:@"@"] && word.length > 1) {
            [s appendAttributedString:[[NSAttributedString alloc] initWithString:word attributes:strong]];
        } else if (TWLooksLikeLink(word)) {
            TWChatLink *l = [[TWChatLink alloc] init];
            l.url = [[word lowercaseString] hasPrefix:@"www."] ? [@"http://" stringByAppendingString:word] : word;
            l.range = NSMakeRange(s.length, word.length);
            [links addObject:l];
            NSMutableDictionary *attributes = [link mutableCopy];
            attributes[TWChatLinkAttribute] = @(links.count - 1);
            [s appendAttributedString:[[NSAttributedString alloc] initWithString:word attributes:attributes]];
        } else {
            [s appendAttributedString:[[NSAttributedString alloc] initWithString:word attributes:plain]];
        }
        pos = end;
    }
}

+ (void)appendEmote:(TWEmote *)emote to:(NSMutableAttributedString *)s slots:(NSMutableArray *)slots height:(CGFloat)height font:(CTFontRef)font retina:(BOOL)retina
{
    if (!emote) return;
    CGFloat w = emote.width > 0 && emote.height > 0 ? round(height * emote.width / emote.height) : height;
    w = MIN(w, height * 4);
    TWChatImageSlot *slot = [[TWChatImageSlot alloc] init];
    slot.url = [emote urlForScale:retina ? 2 : 1];
    slot.name = emote.name;
    slot.animated = emote.animated;
    [slots addObject:slot];
    TWAppendImagePlaceholder(s, w, height, font, slots.count - 1);
}

#pragma mark - Drawing and hit testing

- (void)drawInContext:(CGContextRef)context
{
    if (!_frame) return;
    CGContextSaveGState(context);
    CGContextSetTextMatrix(context, CGAffineTransformIdentity);
    CGContextTranslateCTM(context, 0, _pathHeight);
    CGContextScaleCTM(context, 1, -1);
    CTFrameDraw(_frame, context);
    CGContextRestoreGState(context);
}

- (NSInteger)stringIndexAtPoint:(CGPoint)point
{
    if (!_frame) return NSNotFound;
    CFArrayRef lines = CTFrameGetLines(_frame);
    for (NSUInteger i = 0; i < _lineRects.count && (CFIndex)i < CFArrayGetCount(lines); i++) {
        CGRect rect = [_lineRects[i] CGRectValue];
        rect.origin.x = 0;
        rect.size.width = self.width;
        if (!CGRectContainsPoint(CGRectInset(rect, 0, -TWChatLineSpacing), point)) continue;
        CTLineRef line = CFArrayGetValueAtIndex(lines, (CFIndex)i);
        CGRect lineRect = [_lineRects[i] CGRectValue];
        if (point.x > CGRectGetMaxX(lineRect) + 4) return NSNotFound;
        CFIndex index = CTLineGetStringIndexForPosition(line, CGPointMake(point.x - lineRect.origin.x, 0));
        return index == kCFNotFound ? NSNotFound : (NSInteger)index;
    }
    return NSNotFound;
}

- (TWChatLink *)linkAtPoint:(CGPoint)point
{
    NSInteger index = [self stringIndexAtPoint:point];
    if (index == NSNotFound) return nil;
    for (TWChatLink *l in self.links) {
        if (NSLocationInRange((NSUInteger)index, l.range) || (NSUInteger)index == NSMaxRange(l.range)) return l;
    }
    return nil;
}

- (BOOL)isNameAtPoint:(CGPoint)point
{
    NSInteger index = [self stringIndexAtPoint:point];
    if (index == NSNotFound || self.nameRange.location == NSNotFound) return NO;
    return NSLocationInRange((NSUInteger)index, self.nameRange) || (NSUInteger)index == NSMaxRange(self.nameRange);
}

@end
