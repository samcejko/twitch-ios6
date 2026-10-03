#import "TWFollowingViewController.h"
#import "TWStreamCell.h"
#import "TWGQL.h"
#import "TWHelix.h"
#import "TWAuth.h"
#import "TWFavorites.h"
#import "TWNavigator.h"
#import "TWLoginViewController.h"
#import "TWTheme.h"
#import "TWUtils.h"
#import "TWCommon.h"

typedef NS_ENUM(NSInteger, TWFollowSection) {
    TWFollowSectionLive = 0,
    TWFollowSectionOffline,
    TWFollowSectionCount,
};

@interface TWFollowingViewController ()
@property (nonatomic, strong) NSArray *live;          // TWChannel (with a stream) or TWStream
@property (nonatomic, strong) NSArray *offline;       // TWChannel, or @{login, name, avatar}
@property (nonatomic, strong) NSMutableArray *tasks;
@property (nonatomic) NSInteger pending;
@property (nonatomic, strong) NSDate *loadedAt;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) UIButton *loginButton;
@property (nonatomic, strong) UIView *headerView;
@property (nonatomic, strong) NSMutableDictionary *favoriteChannels;   // login -> TWChannel
@property (nonatomic, strong) NSArray *followedStreams;                // TWStream
@property (nonatomic, strong) NSArray *followedChannels;               // dictionaries
@property (nonatomic, strong) NSError *lastError;
@end

@implementation TWFollowingViewController

- (instancetype)init
{
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        self.title = L(@"Following");
        _tasks = [NSMutableArray array];
        _favoriteChannels = [NSMutableDictionary dictionary];
        _live = @[];
        _offline = @[];
    }
    return self;
}

- (void)dealloc
{
    for (TWHTTPTask *t in _tasks) [t cancel];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self.tableView registerClass:[TWChannelCell class] forCellReuseIdentifier:[TWChannelCell reuseIdentifier]];
    self.tableView.rowHeight = [TWChannelCell height];
    self.tableView.tableFooterView = [[UIView alloc] initWithFrame:CGRectZero];   // (no separator lines below the last row)
    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.leftBarButtonItem = self.editButtonItem;

    self.headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 52)];
    self.loginButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.loginButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    self.loginButton.titleLabel.shadowOffset = CGSizeMake(0, -1);
    [self.loginButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.loginButton setTitleShadowColor:[UIColor colorWithWhite:0 alpha:0.4] forState:UIControlStateNormal];
    [self.loginButton setTitle:L(@"Log in to see the channels you follow") forState:UIControlStateNormal];
    [self.loginButton addTarget:self action:@selector(loginTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.headerView addSubview:self.loginButton];

    self.messageLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.messageLabel.backgroundColor = [UIColor clearColor];
    self.messageLabel.numberOfLines = 0;
    self.messageLabel.textAlignment = NSTextAlignmentCenter;
    self.messageLabel.font = [UIFont systemFontOfSize:15];
    self.messageLabel.hidden = YES;
    [self.tableView addSubview:self.messageLabel];

    [self applyTheme];
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(applyTheme) name:TWThemeDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(favoritesChanged) name:TWFavoritesDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(authChanged) name:TWAuthDidChangeNotification object:nil];
    [self updateHeader];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [[TWTheme shared] applyToNavigationBar:self.navigationController.navigationBar];
    if (!self.loadedAt || -[self.loadedAt timeIntervalSinceNow] > 90) [self reload];
    else [self rebuild];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    CGRect b = self.tableView.bounds;
    self.messageLabel.frame = CGRectMake(30, 110, b.size.width - 60, 100);
    self.loginButton.frame = CGRectMake(12, 10, b.size.width - 24, 34);
    self.headerView.frame = CGRectMake(0, 0, b.size.width, 52);
}

- (void)applyTheme
{
    TWTheme *t = [TWTheme shared];
    [t applyToTableView:self.tableView];
    self.tableView.backgroundColor = [t cardColor];
    self.messageLabel.textColor = [t secondaryTextColor];
    self.refreshControl.tintColor = t.isDark ? [UIColor whiteColor] : nil;
    self.headerView.backgroundColor = [t backgroundColor];
    [self.loginButton setBackgroundImage:[t accentButtonImageHighlighted:NO disabled:NO] forState:UIControlStateNormal];
    [self.loginButton setBackgroundImage:[t accentButtonImageHighlighted:YES disabled:NO] forState:UIControlStateHighlighted];
    [self.tableView reloadData];
}

- (void)updateHeader
{
    self.tableView.tableHeaderView = [TWAuth shared].isLoggedIn ? nil : self.headerView;
}

#pragma mark - Loading

- (void)reload
{
    for (TWHTTPTask *t in self.tasks) [t cancel];
    [self.tasks removeAllObjects];
    self.lastError = nil;
    self.pending = 0;
    __weak TWFollowingViewController *weakSelf = self;
    NSArray *favorites = [[TWFavorites shared] logins];
    if (favorites.count) {
        self.pending++;
        TWHTTPTask *t = [TWGQL channels:favorites completion:^(NSArray *channels, NSError *error) {
            TWFollowingViewController *s = weakSelf;
            if (!s) return;
            if (error) s.lastError = error;
            for (TWChannel *c in channels) {
                s.favoriteChannels[c.login] = c;
                [[TWFavorites shared] rememberChannel:c];
            }
            [s finishOne];
        }];
        if (t) [self.tasks addObject:t];
    }
    if ([TWAuth shared].isLoggedIn) {
        self.pending += 2;
        TWHTTPTask *a = [TWHelix followedStreams:^(NSArray *streams, NSError *error) {
            TWFollowingViewController *s = weakSelf;
            if (!s) return;
            if (error) s.lastError = error; else s.followedStreams = streams;
            [s finishOne];
        }];
        TWHTTPTask *b = [TWHelix followedChannels:^(NSArray *channels, NSError *error) {
            TWFollowingViewController *s = weakSelf;
            if (!s) return;
            if (error) s.lastError = error; else s.followedChannels = channels;
            [s finishOne];
        }];
        if (a) [self.tasks addObject:a];
        if (b) [self.tasks addObject:b];
    } else {
        self.followedStreams = nil;
        self.followedChannels = nil;
    }
    if (!self.pending) {
        [self.refreshControl endRefreshing];
        self.loadedAt = [NSDate date];
        [self rebuild];
    }
}

- (void)finishOne
{
    if (--self.pending > 0) return;
    [self.refreshControl endRefreshing];
    self.loadedAt = [NSDate date];
    [self rebuild];
    if (self.lastError && !self.live.count && !self.offline.count) {
        self.messageLabel.text = self.lastError.localizedDescription;
        self.messageLabel.hidden = NO;
    }
}

// Live first (most viewers first), then everything else by name; a channel that is both followed and a favourite once
- (void)rebuild
{
    NSMutableArray *live = [NSMutableArray array];
    NSMutableArray *offline = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (TWStream *s in self.followedStreams) {
        if (!s.login.length || [seen containsObject:s.login]) continue;
        [seen addObject:s.login];
        [live addObject:s];
    }
    for (NSString *login in [[TWFavorites shared] logins]) {
        if ([seen containsObject:login]) continue;
        TWChannel *c = self.favoriteChannels[login];
        [seen addObject:login];
        if (c.stream) [live addObject:c];
        else if (c) [offline addObject:c];
        else [offline addObject:@{ @"login": login, @"name": [[TWFavorites shared] displayNameFor:login], @"avatar": [[TWFavorites shared] avatarURLFor:login] ?: @"" }];
    }
    for (NSDictionary *d in self.followedChannels) {
        NSString *login = d[@"login"];
        if (!login.length || [seen containsObject:login]) continue;
        [seen addObject:login];
        [offline addObject:d];
    }
    [live sortUsingComparator:^NSComparisonResult(id a, id b) {
        NSInteger va = [a isKindOfClass:[TWStream class]] ? [(TWStream *)a viewers] : [(TWChannel *)a stream].viewers;
        NSInteger vb = [b isKindOfClass:[TWStream class]] ? [(TWStream *)b viewers] : [(TWChannel *)b stream].viewers;
        return va > vb ? NSOrderedAscending : (va < vb ? NSOrderedDescending : NSOrderedSame);
    }];
    [offline sortUsingComparator:^NSComparisonResult(id a, id b) {
        NSString *na = [a isKindOfClass:[TWChannel class]] ? [(TWChannel *)a displayName] : a[@"name"];
        NSString *nb = [b isKindOfClass:[TWChannel class]] ? [(TWChannel *)b displayName] : b[@"name"];
        return [na ?: @"" caseInsensitiveCompare:nb ?: @""];
    }];
    self.live = live;
    self.offline = offline;
    [self.tableView reloadData];
    BOOL empty = !live.count && !offline.count;
    self.messageLabel.hidden = !empty;
    if (empty) {
        self.messageLabel.text = [TWAuth shared].isLoggedIn ? L(@"You follow no channels yet. Mark channels with the star to keep them here.")
                                                             : L(@"Mark channels with the star to keep them here, or log in to see the channels you follow on Twitch.");
    }
}

- (void)favoritesChanged
{
    // a new favourite: its live status is not known yet, so ask again
    NSArray *logins = [[TWFavorites shared] logins];
    BOOL unknown = NO;
    for (NSString *login in logins) if (!self.favoriteChannels[login]) unknown = YES;
    if (unknown && self.isViewLoaded && self.view.window) [self reload];
    else [self rebuild];
}

- (void)authChanged
{
    [self updateHeader];
    if (self.isViewLoaded) [self reload];
}

- (void)loginTapped
{
    [TWLoginViewController presentFrom:self];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return TWFollowSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return section == TWFollowSectionLive ? (NSInteger)self.live.count : (NSInteger)self.offline.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == TWFollowSectionLive) return self.live.count ? L(@"Live now") : nil;
    return self.offline.count ? L(@"Offline") : nil;
}

- (NSString *)loginAtIndexPath:(NSIndexPath *)indexPath
{
    id item = indexPath.section == TWFollowSectionLive ? self.live[(NSUInteger)indexPath.row] : self.offline[(NSUInteger)indexPath.row];
    if ([item isKindOfClass:[TWStream class]]) return [(TWStream *)item login];
    if ([item isKindOfClass:[TWChannel class]]) return [(TWChannel *)item login];
    return item[@"login"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    TWChannelCell *cell = [tableView dequeueReusableCellWithIdentifier:[TWChannelCell reuseIdentifier] forIndexPath:indexPath];
    id item = indexPath.section == TWFollowSectionLive ? self.live[(NSUInteger)indexPath.row] : self.offline[(NSUInteger)indexPath.row];
    if ([item isKindOfClass:[TWChannel class]]) {
        [cell configureWithChannel:item];
    } else if ([item isKindOfClass:[TWStream class]]) {
        TWStream *s = item;
        TWChannel *c = [[TWChannel alloc] init];
        c.login = s.login;
        c.displayName = s.displayName;
        c.avatarURL = s.avatarURL ?: [[TWFavorites shared] avatarURLFor:s.login];
        c.stream = s;
        [cell configureWithChannel:c];
    } else {
        NSDictionary *d = item;
        NSString *avatar = [d[@"avatar"] length] ? d[@"avatar"] : nil;
        [cell configureWithLogin:d[@"login"] displayName:d[@"name"] avatarURL:avatar detail:L(@"Offline")];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    id item = indexPath.section == TWFollowSectionLive ? self.live[(NSUInteger)indexPath.row] : self.offline[(NSUInteger)indexPath.row];
    if ([item isKindOfClass:[TWStream class]]) { [TWNavigator openStream:item from:self]; return; }
    if ([item isKindOfClass:[TWChannel class]] && [(TWChannel *)item stream]) { [TWNavigator openStream:[(TWChannel *)item stream] from:self]; return; }
    [TWNavigator openChannelLogin:[self loginAtIndexPath:indexPath] from:self];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return [[TWFavorites shared] contains:[self loginAtIndexPath:indexPath]];
}

- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return L(@"Remove");
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    [[TWFavorites shared] remove:[self loginAtIndexPath:indexPath]];
}

@end
