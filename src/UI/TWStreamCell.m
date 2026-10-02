#import "TWStreamCell.h"
#import "TWGQL.h"
#import "TWImageLoader.h"
#import "TWTheme.h"
#import "TWUtils.h"
#import "TWCommon.h"
#import <QuartzCore/QuartzCore.h>

static const CGFloat kCardPad = 8;
static const CGFloat kCardTextHeight = 58;
static const CGFloat kRowHeight = 92;
static const CGFloat kRowThumbWidth = 128;

// A label on a dark capsule, placed over a thumbnail
@interface TWPillLabel : UIView
@property (nonatomic, strong) UIImageView *background;
@property (nonatomic, strong) UILabel *label;
- (void)setText:(NSString *)text image:(UIImage *)image;
@end

@implementation TWPillLabel

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        _background = [[UIImageView alloc] initWithFrame:self.bounds];
        _background.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_background];
        _label = [[UILabel alloc] initWithFrame:self.bounds];
        _label.backgroundColor = [UIColor clearColor];
        _label.textColor = [UIColor whiteColor];
        _label.font = [UIFont boldSystemFontOfSize:11];
        _label.textAlignment = NSTextAlignmentCenter;
        _label.shadowColor = [UIColor colorWithWhite:0 alpha:0.5];
        _label.shadowOffset = CGSizeMake(0, -1);
        [self addSubview:_label];
        self.userInteractionEnabled = NO;
    }
    return self;
}

- (void)setText:(NSString *)text image:(UIImage *)image
{
    self.label.text = text;
    self.background.image = image;
    CGSize size = [text sizeWithFont:self.label.font];
    CGRect f = self.frame;
    f.size = CGSizeMake(ceil(size.width) + 12, 18);
    self.frame = f;
    self.label.frame = self.bounds;
    self.hidden = text.length == 0;
}

@end

#pragma mark - Stream cell

@interface TWStreamCell ()
@property (nonatomic, strong) UIImageView *cardBackground;
@property (nonatomic, strong) TWImageView *thumbnail;
@property (nonatomic, strong) TWImageView *avatar;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *gameLabel;
@property (nonatomic, strong) TWPillLabel *livePill;
@property (nonatomic, strong) TWPillLabel *viewersPill;
@property (nonatomic, strong) TWPillLabel *uptimePill;
@property (nonatomic) BOOL card;
@end

@implementation TWStreamCell

+ (NSString *)reuseIdentifier { return @"stream"; }

+ (CGFloat)rowHeightForWidth:(CGFloat)width { return kRowHeight; }

+ (CGFloat)cardHeightForWidth:(CGFloat)width
{
    return floor((width - 2 * kCardPad) * 9.0 / 16.0) + kCardTextHeight + kCardPad * 2;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        _cardBackground = [[UIImageView alloc] initWithFrame:self.bounds];
        [self.contentView addSubview:_cardBackground];
        _thumbnail = [[TWImageView alloc] initWithFrame:CGRectZero];
        _thumbnail.contentMode = UIViewContentModeScaleAspectFill;
        _thumbnail.clipsToBounds = YES;
        _thumbnail.maxPixels = 640;
        [self.contentView addSubview:_thumbnail];
        _avatar = [[TWImageView alloc] initWithFrame:CGRectZero];
        _avatar.contentMode = UIViewContentModeScaleAspectFill;
        _avatar.clipsToBounds = YES;
        _avatar.maxPixels = 150;
        [self.contentView addSubview:_avatar];
        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.backgroundColor = [UIColor clearColor];
        _titleLabel.numberOfLines = 2;
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.contentView addSubview:_titleLabel];
        _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _nameLabel.backgroundColor = [UIColor clearColor];
        [self.contentView addSubview:_nameLabel];
        _gameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _gameLabel.backgroundColor = [UIColor clearColor];
        [self.contentView addSubview:_gameLabel];
        _livePill = [[TWPillLabel alloc] initWithFrame:CGRectZero];
        [self.contentView addSubview:_livePill];
        _viewersPill = [[TWPillLabel alloc] initWithFrame:CGRectZero];
        [self.contentView addSubview:_viewersPill];
        _uptimePill = [[TWPillLabel alloc] initWithFrame:CGRectZero];
        [self.contentView addSubview:_uptimePill];
        [self applyTheme];
    }
    return self;
}

- (void)applyTheme
{
    TWTheme *t = [TWTheme shared];
    self.cardBackground.image = [t cardBackgroundImage];
    self.titleLabel.font = [UIFont boldSystemFontOfSize:TWIsPad() ? 14 : 13];
    self.titleLabel.textColor = [t primaryTextColor];
    self.nameLabel.font = [UIFont systemFontOfSize:TWIsPad() ? 13 : 12];
    self.nameLabel.textColor = [t primaryTextColor];
    self.gameLabel.font = [UIFont systemFontOfSize:TWIsPad() ? 13 : 12];
    self.gameLabel.textColor = [t secondaryTextColor];
    self.thumbnail.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
}

- (void)setHighlighted:(BOOL)highlighted
{
    [super setHighlighted:highlighted];
    TWTheme *t = [TWTheme shared];
    self.cardBackground.image = highlighted ? [t cardBackgroundImageHighlighted] : [t cardBackgroundImage];
}

- (void)configureCommonLogin:(NSString *)login displayName:(NSString *)displayName avatarURL:(NSString *)avatarURL
                       title:(NSString *)title game:(NSString *)game asCard:(BOOL)card
{
    TWTheme *t = [TWTheme shared];
    self.card = card;
    self.titleLabel.text = title.length ? title : displayName;
    self.nameLabel.text = displayName;
    self.gameLabel.text = game ?: @"";
    self.avatar.hidden = !card;
    if (card) [self.avatar setImageURL:avatarURL placeholder:[t avatarPlaceholderWithSize:32]];
    [self setNeedsLayout];
}

- (void)configureWithStream:(TWStream *)stream asCard:(BOOL)card
{
    TWTheme *t = [TWTheme shared];
    [self configureCommonLogin:stream.login displayName:stream.displayName avatarURL:stream.avatarURL title:stream.title game:stream.gameName asCard:card];
    NSInteger w = card ? 440 : 320, h = card ? 248 : 180;
    if ([TWUtils screenScale] > 1.5 && card) { w = 640; h = 360; }
    [self.thumbnail setImageURL:[stream previewURLWithWidth:w height:h] placeholder:[t thumbnailPlaceholder]];
    [self.livePill setText:L(@"LIVE") image:[t pillImageWithColor:[t liveColor]]];
    [self.viewersPill setText:[TWUtils formatCount:stream.viewers] image:[t darkPillImage]];
    [self.uptimePill setText:[TWUtils formatUptimeSince:stream.startedAt] image:[t darkPillImage]];
}

- (void)configureWithChannel:(TWChannel *)channel asCard:(BOOL)card
{
    TWTheme *t = [TWTheme shared];
    if (channel.stream) {
        [self configureWithStream:channel.stream asCard:card];
        return;
    }
    NSString *detail = channel.lastBroadcastAt ? [NSString stringWithFormat:L(@"Last live %@"), [TWUtils formatRelativeDate:channel.lastBroadcastAt]] : L(@"Offline");
    [self configureCommonLogin:channel.login displayName:channel.displayName avatarURL:channel.avatarURL
                         title:channel.lastBroadcastTitle ?: channel.displayName game:detail asCard:card];
    NSString *url = channel.offlineImageURL.length ? channel.offlineImageURL : nil;
    [self.thumbnail setImageURL:url placeholder:[t thumbnailPlaceholder]];
    [self.livePill setText:L(@"OFFLINE") image:[t darkPillImage]];
    [self.viewersPill setText:nil image:nil];
    [self.uptimePill setText:nil image:nil];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGRect b = self.contentView.bounds;
    self.cardBackground.frame = b;
    if (self.card) {
        CGFloat w = b.size.width - 2 * kCardPad;
        CGFloat h = floor(w * 9.0 / 16.0);
        self.thumbnail.frame = CGRectMake(kCardPad, kCardPad, w, h);
        CGFloat y = kCardPad + h + 6;
        self.avatar.frame = CGRectMake(kCardPad, y + 2, 32, 32);
        self.avatar.layer.cornerRadius = 16;
        CGFloat x = kCardPad + 40;
        CGFloat tw = b.size.width - x - kCardPad;
        self.titleLabel.frame = CGRectMake(x, y - 1, tw, 18);
        self.titleLabel.numberOfLines = 1;
        self.nameLabel.frame = CGRectMake(x, y + 17, tw, 16);
        self.gameLabel.frame = CGRectMake(x, y + 33, tw, 16);
    } else {
        CGFloat th = floor(kRowThumbWidth * 9.0 / 16.0);
        self.thumbnail.frame = CGRectMake(kCardPad, floor((b.size.height - th) / 2), kRowThumbWidth, th);
        CGFloat x = kCardPad + kRowThumbWidth + 10;
        CGFloat tw = b.size.width - x - kCardPad;
        self.titleLabel.numberOfLines = 2;
        self.titleLabel.frame = CGRectMake(x, 10, tw, 36);
        self.nameLabel.frame = CGRectMake(x, 48, tw, 16);
        self.gameLabel.frame = CGRectMake(x, 65, tw, 16);
    }
    CGRect tf = self.thumbnail.frame;
    CGRect lp = self.livePill.frame;
    self.livePill.frame = CGRectMake(tf.origin.x + 5, tf.origin.y + 5, lp.size.width, lp.size.height);
    CGRect vp = self.viewersPill.frame;
    self.viewersPill.frame = CGRectMake(tf.origin.x + 5, CGRectGetMaxY(tf) - 23, vp.size.width, vp.size.height);
    CGRect up = self.uptimePill.frame;
    self.uptimePill.frame = CGRectMake(CGRectGetMaxX(tf) - 5 - up.size.width, CGRectGetMaxY(tf) - 23, up.size.width, up.size.height);
}

@end

#pragma mark - Game cell

@interface TWGameCell ()
@property (nonatomic, strong) TWImageView *boxArt;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *viewersLabel;
@end

@implementation TWGameCell

+ (NSString *)reuseIdentifier { return @"game"; }

+ (CGFloat)heightForWidth:(CGFloat)width
{
    return floor((width - 8) * 4.0 / 3.0) + 40;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        _boxArt = [[TWImageView alloc] initWithFrame:CGRectZero];
        _boxArt.contentMode = UIViewContentModeScaleAspectFill;
        _boxArt.clipsToBounds = YES;
        _boxArt.maxPixels = 400;
        _boxArt.layer.cornerRadius = 3;
        _boxArt.layer.borderWidth = 1;
        [self.contentView addSubview:_boxArt];
        _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _nameLabel.backgroundColor = [UIColor clearColor];
        _nameLabel.textAlignment = NSTextAlignmentCenter;
        _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.contentView addSubview:_nameLabel];
        _viewersLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _viewersLabel.backgroundColor = [UIColor clearColor];
        _viewersLabel.textAlignment = NSTextAlignmentCenter;
        [self.contentView addSubview:_viewersLabel];
        [self applyTheme];
    }
    return self;
}

- (void)applyTheme
{
    TWTheme *t = [TWTheme shared];
    self.nameLabel.font = [UIFont boldSystemFontOfSize:12];
    self.nameLabel.textColor = [t primaryTextColor];
    self.viewersLabel.font = [UIFont systemFontOfSize:11];
    self.viewersLabel.textColor = [t secondaryTextColor];
    self.boxArt.layer.borderColor = [t separatorColor].CGColor;
}

- (void)setHighlighted:(BOOL)highlighted
{
    [super setHighlighted:highlighted];
    self.boxArt.alpha = highlighted ? 0.6 : 1.0;
}

- (void)configureWithGame:(TWGame *)game
{
    [self.boxArt setImageURL:game.boxArtURL placeholder:[[TWTheme shared] boxArtPlaceholder]];
    self.nameLabel.text = [game title];
    self.viewersLabel.text = game.viewers > 0 ? [TWUtils formatViewers:game.viewers] : @"";
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGRect b = self.contentView.bounds;
    CGFloat w = b.size.width - 8;
    CGFloat h = floor(w * 4.0 / 3.0);
    self.boxArt.frame = CGRectMake(4, 2, w, h);
    self.nameLabel.frame = CGRectMake(0, h + 6, b.size.width, 16);
    self.viewersLabel.frame = CGRectMake(0, h + 22, b.size.width, 14);
}

@end

#pragma mark - Video cell

@interface TWVideoCell ()
@property (nonatomic, strong) TWImageView *thumbnail;
@property (nonatomic, strong) TWPillLabel *lengthPill;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UILabel *metaLabel;
@end

@implementation TWVideoCell

+ (NSString *)reuseIdentifier { return @"video"; }
+ (CGFloat)height { return 88; }

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier];
    if (self) {
        _thumbnail = [[TWImageView alloc] initWithFrame:CGRectZero];
        _thumbnail.contentMode = UIViewContentModeScaleAspectFill;
        _thumbnail.clipsToBounds = YES;
        _thumbnail.maxPixels = 480;
        _thumbnail.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
        [self.contentView addSubview:_thumbnail];
        _lengthPill = [[TWPillLabel alloc] initWithFrame:CGRectZero];
        [self.contentView addSubview:_lengthPill];
        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.backgroundColor = [UIColor clearColor];
        _titleLabel.numberOfLines = 2;
        _titleLabel.font = [UIFont boldSystemFontOfSize:13];
        [self.contentView addSubview:_titleLabel];
        _detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _detailLabel.backgroundColor = [UIColor clearColor];
        _detailLabel.font = [UIFont systemFontOfSize:12];
        [self.contentView addSubview:_detailLabel];
        _metaLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _metaLabel.backgroundColor = [UIColor clearColor];
        _metaLabel.font = [UIFont systemFontOfSize:12];
        [self.contentView addSubview:_metaLabel];
        self.accessoryType = UITableViewCellAccessoryNone;
    }
    return self;
}

- (void)applyTheme
{
    TWTheme *t = [TWTheme shared];
    [t styleCell:self];
    self.titleLabel.textColor = [t primaryTextColor];
    self.detailLabel.textColor = [t primaryTextColor];
    self.metaLabel.textColor = [t secondaryTextColor];
}

- (void)configureWithVideo:(TWVideo *)video
{
    [self applyTheme];
    TWTheme *t = [TWTheme shared];
    NSString *preview = video.previewURL;
    if ([preview rangeOfString:@"404_processing"].location != NSNotFound) preview = nil;   // (still being processed)
    [self.thumbnail setImageURL:preview placeholder:[t thumbnailPlaceholder]];
    [self.lengthPill setText:[TWUtils formatDuration:video.length] image:[t darkPillImage]];
    self.titleLabel.text = video.title.length ? video.title : L(@"Untitled");
    NSMutableArray *detail = [NSMutableArray array];
    if (video.ownerName.length) [detail addObject:video.ownerName];
    if (video.gameName.length) [detail addObject:video.gameName];
    self.detailLabel.text = [detail componentsJoinedByString:@" · "];
    NSString *type = [video.broadcastType isEqualToString:TWVideoTypeHighlight] ? L(@"Highlight") : ([video.broadcastType isEqualToString:TWVideoTypeUpload] ? L(@"Upload") : L(@"Past broadcast"));
    self.metaLabel.text = [NSString stringWithFormat:@"%@ · %@ · %@", type, [NSString stringWithFormat:L(@"%@ views"), [TWUtils formatCount:video.views]], [TWUtils formatRelativeDate:video.publishedAt]];
    [self setNeedsLayout];
}

- (void)configureWithClip:(TWClip *)clip
{
    [self applyTheme];
    TWTheme *t = [TWTheme shared];
    [self.thumbnail setImageURL:clip.thumbnailURL placeholder:[t thumbnailPlaceholder]];
    [self.lengthPill setText:[TWUtils formatDuration:clip.duration] image:[t darkPillImage]];
    self.titleLabel.text = clip.title.length ? clip.title : L(@"Untitled");
    NSMutableArray *detail = [NSMutableArray array];
    if (clip.broadcasterName.length) [detail addObject:clip.broadcasterName];
    if (clip.gameName.length) [detail addObject:clip.gameName];
    self.detailLabel.text = [detail componentsJoinedByString:@" · "];
    NSString *by = clip.curatorName.length ? [NSString stringWithFormat:L(@"clipped by %@"), clip.curatorName] : L(@"Clip");
    self.metaLabel.text = [NSString stringWithFormat:@"%@ · %@ · %@", [NSString stringWithFormat:L(@"%@ views"), [TWUtils formatCount:clip.views]], [TWUtils formatRelativeDate:clip.createdAt], by];
    [self setNeedsLayout];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGRect b = self.contentView.bounds;
    CGFloat tw = 128, th = 72;
    self.thumbnail.frame = CGRectMake(8, floor((b.size.height - th) / 2), tw, th);
    CGRect lp = self.lengthPill.frame;
    self.lengthPill.frame = CGRectMake(CGRectGetMaxX(self.thumbnail.frame) - 5 - lp.size.width, CGRectGetMaxY(self.thumbnail.frame) - 23, lp.size.width, lp.size.height);
    CGFloat x = 8 + tw + 10;
    CGFloat w = b.size.width - x - 10;
    self.titleLabel.frame = CGRectMake(x, 8, w, 36);
    self.detailLabel.frame = CGRectMake(x, 46, w, 16);
    self.metaLabel.frame = CGRectMake(x, 64, w, 16);
}

@end

#pragma mark - Channel cell

@interface TWChannelCell ()
@property (nonatomic, strong) TWImageView *avatar;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UIImageView *liveDot;
@end

@implementation TWChannelCell

+ (NSString *)reuseIdentifier { return @"channel"; }
+ (CGFloat)height { return 56; }

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier];
    if (self) {
        _avatar = [[TWImageView alloc] initWithFrame:CGRectMake(10, 8, 40, 40)];
        _avatar.contentMode = UIViewContentModeScaleAspectFill;
        _avatar.clipsToBounds = YES;
        _avatar.layer.cornerRadius = 20;
        _avatar.maxPixels = 150;
        [self.contentView addSubview:_avatar];
        _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _nameLabel.backgroundColor = [UIColor clearColor];
        _nameLabel.font = [UIFont boldSystemFontOfSize:15];
        [self.contentView addSubview:_nameLabel];
        _detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _detailLabel.backgroundColor = [UIColor clearColor];
        _detailLabel.font = [UIFont systemFontOfSize:12];
        _detailLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.contentView addSubview:_detailLabel];
        _liveDot = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
        [self.contentView addSubview:_liveDot];
        self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return self;
}

- (void)configureWithChannel:(TWChannel *)channel
{
    TWTheme *t = [TWTheme shared];
    [t styleCell:self];
    self.nameLabel.textColor = [t primaryTextColor];
    [self.avatar setImageURL:channel.avatarURL placeholder:[t avatarPlaceholderWithSize:40]];
    self.nameLabel.text = channel.displayName;
    if (channel.stream) {
        self.liveDot.hidden = NO;
        self.liveDot.image = [t liveDotImage];
        NSString *game = channel.stream.gameName.length ? channel.stream.gameName : L(@"Live");
        self.detailLabel.text = [NSString stringWithFormat:@"%@ · %@", game, [TWUtils formatViewers:channel.stream.viewers]];
        self.detailLabel.textColor = [t primaryTextColor];
    } else {
        self.liveDot.hidden = YES;
        self.detailLabel.text = channel.lastBroadcastAt ? [NSString stringWithFormat:L(@"Last live %@"), [TWUtils formatRelativeDate:channel.lastBroadcastAt]] : L(@"Offline");
        self.detailLabel.textColor = [t secondaryTextColor];
    }
    [self setNeedsLayout];
}

- (void)configureWithLogin:(NSString *)login displayName:(NSString *)name avatarURL:(NSString *)avatar detail:(NSString *)detail
{
    TWTheme *t = [TWTheme shared];
    [t styleCell:self];
    self.nameLabel.textColor = [t primaryTextColor];
    [self.avatar setImageURL:avatar placeholder:[t avatarPlaceholderWithSize:40]];
    self.nameLabel.text = name.length ? name : login;
    self.detailLabel.text = detail ?: @"";
    self.detailLabel.textColor = [t secondaryTextColor];
    self.liveDot.hidden = YES;
    [self setNeedsLayout];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGRect b = self.contentView.bounds;
    CGFloat x = 60;
    CGFloat w = b.size.width - x - 10;
    self.nameLabel.frame = CGRectMake(x, 9, w, 20);
    if (self.liveDot.hidden) {
        self.detailLabel.frame = CGRectMake(x, 30, w, 16);
    } else {
        self.liveDot.frame = CGRectMake(x, 33, 10, 10);
        self.detailLabel.frame = CGRectMake(x + 14, 30, w - 14, 16);
    }
}

@end
