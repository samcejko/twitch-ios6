#import "TWChannelViewController.h"
#import "TWGQL.h"
#import "TWFavorites.h"
#import "TWImageLoader.h"
#import "TWNavigator.h"
#import "TWTheme.h"
#import "TWUtils.h"
#import "TWCommon.h"
#import <QuartzCore/QuartzCore.h>

typedef NS_ENUM(NSInteger, TWChannelTab) {
    TWChannelTabVideos = 0,
    TWChannelTabHighlights,
    TWChannelTabClips,
};

@interface TWChannelViewController () <UIActionSheetDelegate>
@property (nonatomic, copy) NSString *login;
@property (nonatomic, strong) TWChannel *channel;
@property (nonatomic, strong) TWHTTPTask *channelTask;
@property (nonatomic) TWChannelTab tab;
@property (nonatomic, strong) NSString *clipPeriod;
// header
@property (nonatomic, strong) UIView *header;
@property (nonatomic, strong) TWImageView *banner;
@property (nonatomic, strong) TWImageView *avatar;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *followersLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *bioLabel;
@property (nonatomic, strong) UIButton *watchButton;
@property (nonatomic, strong) UIButton *favoriteButton;
@property (nonatomic, strong) UIView *segmentBar;
@property (nonatomic, strong) UISegmentedControl *segments;
@property (nonatomic, strong) UIButton *periodButton;
@end

@implementation TWChannelViewController

- (instancetype)initWithLogin:(NSString *)login
{
    self = [super initWithLoader:nil];
    if (self) {
        _login = [login lowercaseString];
        _clipPeriod = TWClipPeriodWeek;
        self.loadsOnAppear = NO;
        self.title = login;
    }
    return self;
}

- (void)dealloc
{
    [_channelTask cancel];
}

#pragma mark - View

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self buildHeader];
    [self buildSegmentBar];
    if (self.showsDoneButton) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(doneTapped)];
    }
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(favoritesChanged) name:TWFavoritesDidChangeNotification object:nil];
    [self loadChannel];
    [self switchToTab:TWChannelTabVideos];
}

- (void)viewWillLayoutSubviews
{
    [super viewWillLayoutSubviews];
    [self layoutHeader];
}

- (void)doneTapped
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)buildHeader
{
    TWTheme *t = [TWTheme shared];
    self.header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 200)];
    self.header.backgroundColor = [UIColor clearColor];

    self.banner = [[TWImageView alloc] initWithFrame:CGRectZero];
    self.banner.contentMode = UIViewContentModeScaleAspectFill;
    self.banner.clipsToBounds = YES;
    self.banner.maxPixels = 1024;
    self.banner.backgroundColor = [t accentColor];
    [self.header addSubview:self.banner];

    self.avatar = [[TWImageView alloc] initWithFrame:CGRectZero];
    self.avatar.contentMode = UIViewContentModeScaleAspectFill;
    self.avatar.clipsToBounds = YES;
    self.avatar.maxPixels = 300;
    self.avatar.layer.borderWidth = 3;
    self.avatar.layer.borderColor = [t cardColor].CGColor;
    [self.header addSubview:self.avatar];

    self.nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.nameLabel.backgroundColor = [UIColor clearColor];
    self.nameLabel.font = [UIFont boldSystemFontOfSize:20];
    self.nameLabel.adjustsFontSizeToFitWidth = YES;
    self.nameLabel.minimumScaleFactor = 0.7;
    [self.header addSubview:self.nameLabel];

    self.followersLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.followersLabel.backgroundColor = [UIColor clearColor];
    self.followersLabel.font = [UIFont systemFontOfSize:13];
    [self.header addSubview:self.followersLabel];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusLabel.backgroundColor = [UIColor clearColor];
    self.statusLabel.font = [UIFont systemFontOfSize:13];
    self.statusLabel.numberOfLines = 2;
    [self.header addSubview:self.statusLabel];

    self.bioLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.bioLabel.backgroundColor = [UIColor clearColor];
    self.bioLabel.font = [UIFont systemFontOfSize:13];
    self.bioLabel.numberOfLines = 0;
    [self.header addSubview:self.bioLabel];

    self.watchButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.watchButton.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    self.watchButton.titleLabel.shadowOffset = CGSizeMake(0, -1);
    [self.watchButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.watchButton setTitleShadowColor:[UIColor colorWithWhite:0 alpha:0.4] forState:UIControlStateNormal];
    [self.watchButton addTarget:self action:@selector(watchTapped) forControlEvents:UIControlEventTouchUpInside];
    self.watchButton.hidden = YES;
    [self.header addSubview:self.watchButton];

    self.favoriteButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.favoriteButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [self.favoriteButton addTarget:self action:@selector(favoriteTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.header addSubview:self.favoriteButton];

    self.tableView.tableHeaderView = self.header;
    [self applyHeaderTheme];
}

- (void)buildSegmentBar
{
    self.segmentBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    self.segments = [[UISegmentedControl alloc] initWithItems:@[ L(@"Videos"), L(@"Highlights"), L(@"Clips") ]];
    self.segments.segmentedControlStyle = UISegmentedControlStyleBar;
    self.segments.selectedSegmentIndex = 0;
    [self.segments addTarget:self action:@selector(segmentChanged) forControlEvents:UIControlEventValueChanged];
    [self.segmentBar addSubview:self.segments];
    self.periodButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.periodButton.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [self.periodButton addTarget:self action:@selector(periodTapped) forControlEvents:UIControlEventTouchUpInside];
    self.periodButton.hidden = YES;
    [self.segmentBar addSubview:self.periodButton];
    self.segmentHeaderView = self.segmentBar;
}

- (void)applyTheme
{
    [super applyTheme];
    if (self.header) [self applyHeaderTheme];
}

- (void)applyHeaderTheme
{
    TWTheme *t = [TWTheme shared];
    self.header.backgroundColor = [t cardColor];
    self.nameLabel.textColor = [t primaryTextColor];
    self.followersLabel.textColor = [t secondaryTextColor];
    self.statusLabel.textColor = [t primaryTextColor];
    self.bioLabel.textColor = [t secondaryTextColor];
    self.avatar.layer.borderColor = [t cardColor].CGColor;
    [self.watchButton setBackgroundImage:[t accentButtonImageHighlighted:NO disabled:NO] forState:UIControlStateNormal];
    [self.watchButton setBackgroundImage:[t accentButtonImageHighlighted:YES disabled:NO] forState:UIControlStateHighlighted];
    [self.favoriteButton setBackgroundImage:[t buttonImageHighlighted:NO] forState:UIControlStateNormal];
    [self.favoriteButton setBackgroundImage:[t buttonImageHighlighted:YES] forState:UIControlStateHighlighted];
    [self.favoriteButton setTitleColor:[t primaryTextColor] forState:UIControlStateNormal];
    self.segmentBar.backgroundColor = t.isDark ? [UIColor colorWithWhite:0.12 alpha:0.97] : [UIColor colorWithWhite:0.93 alpha:0.97];
    [self.periodButton setTitleColor:[t accentColor] forState:UIControlStateNormal];
    [self updateFavoriteButton];
}

- (void)layoutHeader
{
    CGFloat w = self.tableView.bounds.size.width;
    if (w <= 0) return;
    BOOL wide = w >= 500;
    CGFloat bannerH = wide ? 150 : 100;
    CGFloat avatarSize = wide ? 96 : 72;
    CGFloat pad = 12;
    self.banner.frame = CGRectMake(0, 0, w, bannerH);
    self.avatar.frame = CGRectMake(pad, bannerH - avatarSize / 2, avatarSize, avatarSize);
    self.avatar.layer.cornerRadius = avatarSize / 2;
    CGFloat textX = pad + avatarSize + 10;
    CGFloat y = bannerH + 6;
    // buttons on the right of the name on wide screens, in a row below the avatar on narrow ones
    CGFloat buttonW = 120, buttonH = 32;
    if (wide) {
        self.watchButton.frame = CGRectMake(w - pad - buttonW, y, buttonW, buttonH);
        self.favoriteButton.frame = CGRectMake(w - pad - buttonW - 8 - 110, y, 110, buttonH);
        CGFloat textW = CGRectGetMinX(self.favoriteButton.frame) - 10 - textX;
        self.nameLabel.frame = CGRectMake(textX, y, textW, 24);
        self.followersLabel.frame = CGRectMake(textX, y + 24, textW, 16);
        y += 44;
    } else {
        self.nameLabel.frame = CGRectMake(textX, y, w - textX - pad, 24);
        self.followersLabel.frame = CGRectMake(textX, y + 24, w - textX - pad, 16);
        y = bannerH + avatarSize / 2 + 8;
        self.watchButton.frame = CGRectMake(pad, y, buttonW, buttonH);
        self.favoriteButton.frame = CGRectMake(pad + buttonW + 8, y, 110, buttonH);
        y += buttonH + 8;
    }
    CGFloat textW = w - 2 * pad;
    NSString *status = self.statusLabel.text ?: @"";
    CGFloat statusH = status.length ? MIN(36, ceil([status sizeWithFont:self.statusLabel.font constrainedToSize:CGSizeMake(textW, 36) lineBreakMode:NSLineBreakByTruncatingTail].height)) : 0;
    self.statusLabel.frame = CGRectMake(pad, y, textW, statusH);
    y += statusH ? statusH + 4 : 0;
    NSString *bio = self.bioLabel.text ?: @"";
    CGFloat bioH = bio.length ? MIN(80, ceil([bio sizeWithFont:self.bioLabel.font constrainedToSize:CGSizeMake(textW, 80) lineBreakMode:NSLineBreakByWordWrapping].height)) : 0;
    self.bioLabel.frame = CGRectMake(pad, y, textW, bioH);
    y += bioH ? bioH + 6 : 0;
    y += 6;
    if (fabs(self.header.frame.size.height - y) > 0.5 || fabs(self.header.frame.size.width - w) > 0.5) {
        self.header.frame = CGRectMake(0, 0, w, y);
        self.tableView.tableHeaderView = self.header;   // (the table reads the height when the view is set)
    }
    self.segmentBar.frame = CGRectMake(0, 0, w, 44);
    CGFloat segW = MIN(w - 24 - (self.periodButton.hidden ? 0 : 100), 360);
    self.segments.frame = CGRectMake(12, 7, segW, 30);
    self.periodButton.frame = CGRectMake(w - 12 - 90, 7, 90, 30);
}

#pragma mark - Data

- (void)loadChannel
{
    __weak TWChannelViewController *weakSelf = self;
    self.channelTask = [TWGQL channel:self.login completion:^(TWChannel *channel, NSError *error) {
        TWChannelViewController *s = weakSelf;
        if (!s) return;
        s.channelTask = nil;
        if (error) {
            s.statusLabel.text = error.localizedDescription;
            [s layoutHeader];
            return;
        }
        s.channel = channel;
        [[TWFavorites shared] rememberChannel:channel];
        [s showChannel];
    }];
}

- (void)showChannel
{
    TWChannel *c = self.channel;
    TWTheme *t = [TWTheme shared];
    self.title = c.displayName;
    self.nameLabel.text = [c nameForDisplay];
    NSMutableArray *facts = [NSMutableArray array];
    if (c.followers > 0) [facts addObject:[NSString stringWithFormat:L(@"%@ followers"), [TWUtils formatCount:c.followers]]];
    if (c.isPartner) [facts addObject:L(@"Partner")];
    else if (c.isAffiliate) [facts addObject:L(@"Affiliate")];
    self.followersLabel.text = [facts componentsJoinedByString:@" · "];
    [self.avatar setImageURL:c.avatarURL placeholder:[t avatarPlaceholderWithSize:96]];
    [self.banner setImageURL:c.bannerURL.length ? c.bannerURL : nil placeholder:nil];
    if (!c.bannerURL.length) self.banner.image = nil;
    if (c.stream) {
        NSString *game = c.stream.gameName.length ? [NSString stringWithFormat:@" · %@", c.stream.gameName] : @"";
        self.statusLabel.text = [NSString stringWithFormat:@"%@ %@%@\n%@", L(@"LIVE:"), c.stream.title.length ? c.stream.title : L(@"Live now"), game, [TWUtils formatViewers:c.stream.viewers]];
        self.statusLabel.textColor = [t primaryTextColor];
        self.watchButton.hidden = NO;
        [self.watchButton setTitle:L(@"Watch Live") forState:UIControlStateNormal];
    } else {
        self.statusLabel.text = c.lastBroadcastAt ? [NSString stringWithFormat:L(@"Offline · last live %@"), [TWUtils formatRelativeDate:c.lastBroadcastAt]] : L(@"Offline");
        self.statusLabel.textColor = [t secondaryTextColor];
        self.watchButton.hidden = YES;
    }
    self.bioLabel.text = c.bio;
    [self updateFavoriteButton];
    [self layoutHeader];
}

- (void)updateFavoriteButton
{
    BOOL on = [[TWFavorites shared] contains:self.login];
    TWTheme *t = [TWTheme shared];
    [self.favoriteButton setTitle:on ? L(@"Favorite") : L(@"Add Favorite") forState:UIControlStateNormal];
    UIImage *star = [t starIconFilled:on color:on ? [UIColor colorWithRed:0.95 green:0.75 blue:0.1 alpha:1] : [t secondaryTextColor] size:18];
    [self.favoriteButton setImage:star forState:UIControlStateNormal];
    self.favoriteButton.titleEdgeInsets = UIEdgeInsetsMake(0, 6, 0, 0);
    self.favoriteButton.imageEdgeInsets = UIEdgeInsetsMake(0, -2, 0, 0);
}

- (void)favoritesChanged
{
    [self updateFavoriteButton];
}

#pragma mark - Actions

- (void)watchTapped
{
    if (self.channel.stream) [TWNavigator openStream:self.channel.stream from:self];
    else [TWNavigator watchChannelLogin:self.login from:self];
}

- (void)favoriteTapped
{
    TWFavorites *f = [TWFavorites shared];
    if ([f contains:self.login]) [f remove:self.login];
    else [f add:self.login displayName:self.channel.displayName ?: self.login avatarURL:self.channel.avatarURL];
    [self updateFavoriteButton];
}

- (void)segmentChanged
{
    [self switchToTab:(TWChannelTab)self.segments.selectedSegmentIndex];
}

- (void)switchToTab:(TWChannelTab)tab
{
    self.tab = tab;
    self.periodButton.hidden = tab != TWChannelTabClips;
    [self updatePeriodButton];
    [self layoutHeader];
    NSString *login = self.login;
    NSString *period = self.clipPeriod;
    // (each case in braces: a block literal is a declaration the compiler will not let a later case jump over)
    switch (tab) {
        case TWChannelTabClips: {
            self.emptyText = L(@"No clips in this period.");
            self.loader = ^TWHTTPTask *(NSString *cursor, TWListCompletion completion) {
                return [TWGQL clipsForChannel:login period:period after:cursor completion:completion];
            };
            break;
        }
        case TWChannelTabHighlights: {
            self.emptyText = L(@"No highlights.");
            self.loader = ^TWHTTPTask *(NSString *cursor, TWListCompletion completion) {
                return [TWGQL videosForChannel:login type:TWVideoTypeHighlight after:cursor completion:completion];
            };
            break;
        }
        default: {
            self.emptyText = L(@"No past broadcasts. The channel may keep none.");
            self.loader = ^TWHTTPTask *(NSString *cursor, TWListCompletion completion) {
                return [TWGQL videosForChannel:login type:TWVideoTypeArchive after:cursor completion:completion];
            };
            break;
        }
    }
    [self reload];
}

- (void)updatePeriodButton
{
    NSString *title = L(@"This week");
    if ([self.clipPeriod isEqualToString:TWClipPeriodDay]) title = L(@"Today");
    else if ([self.clipPeriod isEqualToString:TWClipPeriodMonth]) title = L(@"This month");
    else if ([self.clipPeriod isEqualToString:TWClipPeriodAll]) title = L(@"All time");
    [self.periodButton setTitle:[title stringByAppendingString:@" ▾"] forState:UIControlStateNormal];
}

- (void)periodTapped
{
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:L(@"Clips from") delegate:nil cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
    NSArray *titles = @[ L(@"Today"), L(@"This week"), L(@"This month"), L(@"All time") ];
    for (NSString *t in titles) [sheet addButtonWithTitle:t];
    sheet.cancelButtonIndex = [sheet addButtonWithTitle:L(@"Cancel")];
    sheet.delegate = self;
    sheet.tag = 1;
    if (TWIsPad()) [sheet showFromRect:self.periodButton.frame inView:self.segmentBar animated:YES];
    else [sheet showInView:self.view];
}

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (buttonIndex < 0 || buttonIndex == actionSheet.cancelButtonIndex) return;
    NSArray *periods = @[ TWClipPeriodDay, TWClipPeriodWeek, TWClipPeriodMonth, TWClipPeriodAll ];
    if (buttonIndex < (NSInteger)periods.count) {
        self.clipPeriod = periods[(NSUInteger)buttonIndex];
        [self switchToTab:TWChannelTabClips];
    }
}

@end
