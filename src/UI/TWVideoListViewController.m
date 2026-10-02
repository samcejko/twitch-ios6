#import "TWVideoListViewController.h"
#import "TWStreamCell.h"
#import "TWNavigator.h"
#import "TWTheme.h"
#import "TWUtils.h"
#import "TWCommon.h"

@interface TWVideoListViewController ()
@property (nonatomic, strong) NSMutableArray *mutableItems;
@property (nonatomic, copy) NSString *nextCursor;
@property (nonatomic) BOOL hasMore;
@property (nonatomic) BOOL loading;
@property (nonatomic) BOOL loadedOnce;
@property (nonatomic, strong) TWHTTPTask *task;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIActivityIndicatorView *footerSpinner;
@end

@implementation TWVideoListViewController

- (instancetype)initWithLoader:(TWGridLoader)loader
{
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _loader = [loader copy];
        _mutableItems = [NSMutableArray array];
        _emptyText = L(@"Nothing here.");
        _loadsOnAppear = YES;
    }
    return self;
}

- (void)dealloc
{
    [_task cancel];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSArray *)items
{
    return self.mutableItems;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.rowHeight = [TWVideoCell height];
    [self.tableView registerClass:[TWVideoCell class] forCellReuseIdentifier:[TWVideoCell reuseIdentifier]];
    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];

    self.messageLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.messageLabel.backgroundColor = [UIColor clearColor];
    self.messageLabel.numberOfLines = 0;
    self.messageLabel.textAlignment = NSTextAlignmentCenter;
    self.messageLabel.font = [UIFont systemFontOfSize:15];
    self.messageLabel.hidden = YES;
    [self.tableView addSubview:self.messageLabel];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    self.spinner.hidesWhenStopped = YES;
    [self.tableView addSubview:self.spinner];

    self.footerSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    self.footerSpinner.frame = CGRectMake(0, 0, 44, 44);
    self.footerSpinner.hidesWhenStopped = YES;
    self.tableView.tableFooterView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
    [self.tableView.tableFooterView addSubview:self.footerSpinner];

    [self applyTheme];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applyTheme) name:TWThemeDidChangeNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [[TWTheme shared] applyToNavigationBar:self.navigationController.navigationBar];
    if (self.loadsOnAppear && !self.loadedOnce && !self.loading && self.loader) [self reload];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    CGRect b = self.tableView.bounds;
    CGFloat top = self.tableView.tableHeaderView.frame.size.height + (self.segmentHeaderView ? 44 : 0);
    self.messageLabel.frame = CGRectMake(30, top + 60, b.size.width - 60, 80);
    self.spinner.center = CGPointMake(b.size.width / 2, top + 70);
    self.footerSpinner.center = CGPointMake(b.size.width / 2, 22);
}

- (void)applyTheme
{
    TWTheme *t = [TWTheme shared];
    [t applyToTableView:self.tableView];
    self.tableView.backgroundColor = [t cardColor];
    self.messageLabel.textColor = [t secondaryTextColor];
    self.spinner.activityIndicatorViewStyle = [t spinnerStyle];
    self.footerSpinner.activityIndicatorViewStyle = [t spinnerStyle];
    self.refreshControl.tintColor = t.isDark ? [UIColor whiteColor] : nil;
    [self.tableView reloadData];
}

- (void)showMessage:(NSString *)text
{
    self.messageLabel.text = text;
    self.messageLabel.hidden = text.length == 0;
}

#pragma mark - Loading

- (void)setLoader:(TWGridLoader)loader
{
    _loader = [loader copy];
    [self.task cancel];
    self.task = nil;
    self.loading = NO;
    self.loadedOnce = NO;
    [self.mutableItems removeAllObjects];
    self.hasMore = NO;
    if (self.isViewLoaded) {
        [self.tableView reloadData];
        [self showMessage:nil];
    }
}

- (void)reload
{
    if (!self.loader) return;
    [self.task cancel];
    self.loading = YES;
    [self showMessage:nil];
    if (!self.mutableItems.count && !self.refreshControl.isRefreshing) [self.spinner startAnimating];
    __weak TWVideoListViewController *weakSelf = self;
    self.task = self.loader(nil, ^(NSArray *items, NSString *nextCursor, NSError *error) {
        TWVideoListViewController *s = weakSelf;
        if (!s) return;
        s.loading = NO;
        s.loadedOnce = YES;
        s.task = nil;
        [s.spinner stopAnimating];
        [s.refreshControl endRefreshing];
        if (error) {
            if (!s.mutableItems.count) [s showMessage:error.localizedDescription];
            return;
        }
        [s.mutableItems setArray:items ?: @[]];
        s.nextCursor = nextCursor;
        s.hasMore = nextCursor.length > 0;
        [s.tableView reloadData];
        if (!s.mutableItems.count) [s showMessage:s.emptyText];
    });
}

- (void)loadMore
{
    if (self.loading || !self.hasMore || !self.loader) return;
    self.loading = YES;
    [self.footerSpinner startAnimating];
    __weak TWVideoListViewController *weakSelf = self;
    self.task = self.loader(self.nextCursor, ^(NSArray *items, NSString *nextCursor, NSError *error) {
        TWVideoListViewController *s = weakSelf;
        if (!s) return;
        s.loading = NO;
        s.task = nil;
        [s.footerSpinner stopAnimating];
        if (error) { s.hasMore = NO; return; }
        NSMutableSet *known = [NSMutableSet set];
        for (id item in s.mutableItems) [known addObject:[s identityOf:item]];
        for (id item in items) {
            NSString *key = [s identityOf:item];
            if ([known containsObject:key]) continue;
            [known addObject:key];
            [s.mutableItems addObject:item];
        }
        s.nextCursor = nextCursor;
        s.hasMore = nextCursor.length > 0 && items.count > 0;
        [s.tableView reloadData];
    });
}

- (NSString *)identityOf:(id)item
{
    if ([item isKindOfClass:[TWVideo class]]) return [@"v:" stringByAppendingString:[(TWVideo *)item videoId] ?: @""];
    if ([item isKindOfClass:[TWClip class]]) return [@"c:" stringByAppendingString:[(TWClip *)item slug] ?: @""];
    return [NSString stringWithFormat:@"%p", item];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)self.mutableItems.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    TWVideoCell *cell = [tableView dequeueReusableCellWithIdentifier:[TWVideoCell reuseIdentifier] forIndexPath:indexPath];
    id item = self.mutableItems[(NSUInteger)indexPath.row];
    if ([item isKindOfClass:[TWClip class]]) [cell configureWithClip:item];
    else [cell configureWithVideo:item];
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    return self.segmentHeaderView ? 44 : 0;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    return self.segmentHeaderView;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    id item = self.mutableItems[(NSUInteger)indexPath.row];
    if (self.onSelectItem) { self.onSelectItem(item); return; }
    if ([item isKindOfClass:[TWClip class]]) [TWNavigator openClip:item from:self];
    else if ([item isKindOfClass:[TWVideo class]]) [TWNavigator openVideo:item from:self];
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (self.hasMore && !self.loading && indexPath.row >= (NSInteger)self.mutableItems.count - 4) [self loadMore];
}

@end
