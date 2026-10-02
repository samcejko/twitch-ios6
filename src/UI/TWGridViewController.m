#import "TWGridViewController.h"
#import "TWStreamCell.h"
#import "TWNavigator.h"
#import "TWTheme.h"
#import "TWUtils.h"
#import "TWCommon.h"

static NSString * const kFooterId = @"footer";

@interface TWGridFooterView : UICollectionReusableView
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation TWGridFooterView
- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:[[TWTheme shared] spinnerStyle]];
        _spinner.hidesWhenStopped = YES;
        _spinner.center = CGPointMake(frame.size.width / 2, frame.size.height / 2);
        _spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
        [self addSubview:_spinner];
    }
    return self;
}
@end

@interface TWGridViewController () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>
@property (nonatomic) TWGridKind kind;
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) UICollectionViewFlowLayout *layout;
@property (nonatomic, strong) NSMutableArray *mutableItems;
@property (nonatomic, copy) NSString *nextCursor;
@property (nonatomic) BOOL hasMore;
@property (nonatomic) BOOL loading;
@property (nonatomic) BOOL fixedList;
@property (nonatomic, strong) TWHTTPTask *task;
@property (nonatomic, strong) UIRefreshControl *refreshControl;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) UIButton *retryButton;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSDate *loadedAt;
@property (nonatomic) CGFloat headerHeight;
@property (nonatomic) BOOL firstPageFailed;
@end

@implementation TWGridViewController

- (instancetype)initWithKind:(TWGridKind)kind loader:(TWGridLoader)loader
{
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _kind = kind;
        _loader = [loader copy];
        _mutableItems = [NSMutableArray array];
        _refreshesOnAppear = YES;
        _staleAfter = 120;
        _emptyText = L(@"Nothing here right now.");
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

#pragma mark - View

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.layout = [[UICollectionViewFlowLayout alloc] init];
    self.layout.scrollDirection = UICollectionViewScrollDirectionVertical;
    self.collectionView = [[UICollectionView alloc] initWithFrame:self.view.bounds collectionViewLayout:self.layout];
    self.collectionView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.alwaysBounceVertical = YES;
    [self.collectionView registerClass:[TWStreamCell class] forCellWithReuseIdentifier:[TWStreamCell reuseIdentifier]];
    [self.collectionView registerClass:[TWGameCell class] forCellWithReuseIdentifier:[TWGameCell reuseIdentifier]];
    [self.collectionView registerClass:[TWGridFooterView class] forSupplementaryViewOfKind:UICollectionElementKindSectionFooter withReuseIdentifier:kFooterId];
    [self.view addSubview:self.collectionView];

    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(pulled) forControlEvents:UIControlEventValueChanged];
    [self.collectionView addSubview:self.refreshControl];

    self.messageLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.messageLabel.backgroundColor = [UIColor clearColor];
    self.messageLabel.numberOfLines = 0;
    self.messageLabel.textAlignment = NSTextAlignmentCenter;
    self.messageLabel.font = [UIFont systemFontOfSize:15];
    self.messageLabel.hidden = YES;
    [self.view addSubview:self.messageLabel];

    self.retryButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.retryButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [self.retryButton setTitle:L(@"Try Again") forState:UIControlStateNormal];
    [self.retryButton addTarget:self action:@selector(reload) forControlEvents:UIControlEventTouchUpInside];
    self.retryButton.hidden = YES;
    [self.view addSubview:self.retryButton];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    self.spinner.hidesWhenStopped = YES;
    [self.view addSubview:self.spinner];

    if (self.headerView) [self installHeader];
    [self applyTheme];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeChanged) name:TWThemeDidChangeNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    if (!self.fixedList && !self.mutableItems.count && !self.loading && !self.firstPageFailed) {
        [self reload];
    } else if (self.refreshesOnAppear && !self.fixedList && self.loadedAt && -[self.loadedAt timeIntervalSinceNow] > self.staleAfter && !self.loading) {
        [self reload];
    }
}

- (void)viewWillLayoutSubviews
{
    [super viewWillLayoutSubviews];
    [self layoutChrome];
}

- (void)layoutChrome
{
    CGRect b = self.view.bounds;
    self.messageLabel.frame = CGRectMake(30, b.size.height * 0.35 + self.headerHeight / 2, b.size.width - 60, 80);
    self.retryButton.frame = CGRectMake(floor((b.size.width - 120) / 2), CGRectGetMaxY(self.messageLabel.frame) + 8, 120, 34);
    self.spinner.center = CGPointMake(b.size.width / 2, b.size.height * 0.4 + self.headerHeight / 2);
    if (self.headerView) {
        self.headerView.frame = CGRectMake(0, -self.headerHeight, b.size.width, self.headerHeight);
    }
    [self.layout invalidateLayout];
}

- (void)willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration
{
    [super willAnimateRotationToInterfaceOrientation:toInterfaceOrientation duration:duration];
    [self.layout invalidateLayout];
}

- (void)applyTheme
{
    TWTheme *t = [TWTheme shared];
    self.view.backgroundColor = [t backgroundColor];
    self.collectionView.backgroundColor = [t backgroundColor];
    self.collectionView.indicatorStyle = t.isDark ? UIScrollViewIndicatorStyleWhite : UIScrollViewIndicatorStyleDefault;
    self.messageLabel.textColor = [t secondaryTextColor];
    [self.retryButton setTitleColor:[t primaryTextColor] forState:UIControlStateNormal];
    [self.retryButton setBackgroundImage:[t buttonImageHighlighted:NO] forState:UIControlStateNormal];
    [self.retryButton setBackgroundImage:[t buttonImageHighlighted:YES] forState:UIControlStateHighlighted];
    self.spinner.activityIndicatorViewStyle = t.isDark ? UIActivityIndicatorViewStyleWhiteLarge : UIActivityIndicatorViewStyleGray;
    self.refreshControl.tintColor = t.isDark ? [UIColor whiteColor] : nil;
    [self.collectionView reloadData];
}

- (void)themeChanged
{
    [self applyTheme];
}

#pragma mark - Header

- (void)setHeaderView:(UIView *)headerView
{
    [_headerView removeFromSuperview];
    _headerView = headerView;
    _headerHeight = headerView.frame.size.height;
    if (self.isViewLoaded) [self installHeader];
}

- (void)installHeader
{
    if (!self.headerView) return;
    [self.collectionView addSubview:self.headerView];
    [self setHeaderHeight:self.headerHeight];
}

- (void)setHeaderHeight:(CGFloat)height
{
    _headerHeight = height;
    UIEdgeInsets insets = self.collectionView.contentInset;
    insets.top = height;
    self.collectionView.contentInset = insets;
    self.collectionView.scrollIndicatorInsets = UIEdgeInsetsMake(height, 0, 0, 0);
    if (self.headerView) self.headerView.frame = CGRectMake(0, -height, self.view.bounds.size.width, height);
    [self layoutChrome];
}

#pragma mark - Loading

- (void)pulled
{
    [self reload];
}

- (void)showMessage:(NSString *)text retry:(BOOL)retry
{
    self.messageLabel.text = text;
    self.messageLabel.hidden = text.length == 0;
    self.retryButton.hidden = !retry;
}

- (void)reload
{
    if (!self.loader) return;
    [self.task cancel];
    self.fixedList = NO;
    self.loading = YES;
    self.firstPageFailed = NO;
    [self showMessage:nil retry:NO];
    if (!self.mutableItems.count && !self.refreshControl.isRefreshing) [self.spinner startAnimating];
    __weak TWGridViewController *weakSelf = self;
    self.task = self.loader(nil, ^(NSArray *items, NSString *nextCursor, NSError *error) {
        TWGridViewController *s = weakSelf;
        if (!s) return;
        s.loading = NO;
        s.task = nil;
        [s.spinner stopAnimating];
        [s.refreshControl endRefreshing];
        if (error) {
            s.firstPageFailed = YES;
            if (!s.mutableItems.count) [s showMessage:error.localizedDescription retry:YES];
            else [TWUtils alertWithTitle:L(@"Could not refresh") message:error.localizedDescription];
            return;
        }
        s.loadedAt = [NSDate date];
        [s.mutableItems setArray:items ?: @[]];
        s.nextCursor = nextCursor;
        s.hasMore = nextCursor.length > 0;
        [s.collectionView reloadData];
        if (!s.mutableItems.count) [s showMessage:s.emptyText retry:NO];
    });
}

- (void)reloadKeepingItemsIfPossible
{
    if (self.fixedList) { [self.collectionView reloadData]; return; }
    [self reload];
}

- (void)loadMore
{
    if (self.loading || !self.hasMore || self.fixedList || !self.loader) return;
    self.loading = YES;
    __weak TWGridViewController *weakSelf = self;
    NSString *cursor = self.nextCursor;
    self.task = self.loader(cursor, ^(NSArray *items, NSString *nextCursor, NSError *error) {
        TWGridViewController *s = weakSelf;
        if (!s) return;
        s.loading = NO;
        s.task = nil;
        if (error) {
            s.hasMore = NO;   // (the end of the list is shown; a pull loads again)
            [s.collectionView reloadData];
            return;
        }
        // (the API may repeat items across pages)
        NSMutableSet *known = [NSMutableSet set];
        for (id item in s.mutableItems) [known addObject:[s identityOf:item]];
        NSMutableArray *fresh = [NSMutableArray array];
        for (id item in items) {
            NSString *key = [s identityOf:item];
            if ([known containsObject:key]) continue;
            [known addObject:key];
            [fresh addObject:item];
        }
        [s.mutableItems addObjectsFromArray:fresh];
        s.nextCursor = nextCursor;
        s.hasMore = nextCursor.length > 0 && items.count > 0;
        [s.collectionView reloadData];
    });
}

- (NSString *)identityOf:(id)item
{
    if ([item isKindOfClass:[TWStream class]]) return [@"s:" stringByAppendingString:[(TWStream *)item login] ?: @""];
    if ([item isKindOfClass:[TWChannel class]]) return [@"c:" stringByAppendingString:[(TWChannel *)item login] ?: @""];
    if ([item isKindOfClass:[TWGame class]]) return [@"g:" stringByAppendingString:[(TWGame *)item gameId] ?: [(TWGame *)item name] ?: @""];
    return [NSString stringWithFormat:@"%p", item];
}

- (void)replaceItems:(NSArray *)items
{
    [self.task cancel];
    self.task = nil;
    self.loading = NO;
    self.fixedList = YES;
    self.hasMore = NO;
    [self.spinner stopAnimating];
    [self.refreshControl endRefreshing];
    [self.mutableItems setArray:items ?: @[]];
    [self.collectionView reloadData];
    [self showMessage:self.mutableItems.count ? nil : self.emptyText retry:NO];
}

#pragma mark - Layout metrics

- (BOOL)usesCards
{
    return self.view.bounds.size.width >= 500;
}

- (NSInteger)columns
{
    CGFloat width = self.view.bounds.size.width;
    if (self.kind == TWGridKindGames) return MAX(3, (NSInteger)floor(width / (TWIsPad() ? 150 : 106)));
    if (![self usesCards]) return 1;
    return MAX(2, MIN(4, (NSInteger)floor(width / 300)));
}

- (CGFloat)itemWidth
{
    NSInteger columns = [self columns];
    CGFloat width = self.view.bounds.size.width;
    CGFloat inset = (self.kind == TWGridKindGames) ? 6 : ([self usesCards] ? 8 : 0);
    CGFloat spacing = (self.kind == TWGridKindGames) ? 4 : ([self usesCards] ? 8 : 0);
    return floor((width - 2 * inset - (columns - 1) * spacing) / columns);
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)indexPath
{
    CGFloat w = [self itemWidth];
    if (self.kind == TWGridKindGames) return CGSizeMake(w, [TWGameCell heightForWidth:w]);
    if ([self usesCards]) return CGSizeMake(w, [TWStreamCell cardHeightForWidth:w]);
    return CGSizeMake(w, [TWStreamCell rowHeightForWidth:w]);
}

- (UIEdgeInsets)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout insetForSectionAtIndex:(NSInteger)section
{
    if (self.kind == TWGridKindGames) return UIEdgeInsetsMake(8, 6, 8, 6);
    return [self usesCards] ? UIEdgeInsetsMake(8, 8, 8, 8) : UIEdgeInsetsMake(0, 0, 0, 0);
}

- (CGFloat)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout minimumInteritemSpacingForSectionAtIndex:(NSInteger)section
{
    if (self.kind == TWGridKindGames) return 4;
    return [self usesCards] ? 8 : 0;
}

- (CGFloat)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout minimumLineSpacingForSectionAtIndex:(NSInteger)section
{
    if (self.kind == TWGridKindGames) return 8;
    return [self usesCards] ? 8 : 1;
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout referenceSizeForFooterInSection:(NSInteger)section
{
    return CGSizeMake(self.view.bounds.size.width, self.hasMore ? 44 : 8);
}

#pragma mark - Data source

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section
{
    return (NSInteger)self.mutableItems.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
    id item = self.mutableItems[(NSUInteger)indexPath.item];
    if (self.kind == TWGridKindGames) {
        TWGameCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:[TWGameCell reuseIdentifier] forIndexPath:indexPath];
        [cell applyTheme];
        [cell configureWithGame:item];
        return cell;
    }
    TWStreamCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:[TWStreamCell reuseIdentifier] forIndexPath:indexPath];
    [cell applyTheme];
    if ([item isKindOfClass:[TWChannel class]]) [cell configureWithChannel:item asCard:[self usesCards]];
    else [cell configureWithStream:item asCard:[self usesCards]];
    return cell;
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)collectionView viewForSupplementaryElementOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)indexPath
{
    TWGridFooterView *footer = [collectionView dequeueReusableSupplementaryViewOfKind:kind withReuseIdentifier:kFooterId forIndexPath:indexPath];
    footer.spinner.activityIndicatorViewStyle = [[TWTheme shared] spinnerStyle];
    if (self.hasMore) [footer.spinner startAnimating];
    else [footer.spinner stopAnimating];
    return footer;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath
{
    [collectionView deselectItemAtIndexPath:indexPath animated:YES];
    id item = self.mutableItems[(NSUInteger)indexPath.item];
    if (self.onSelectItem) { self.onSelectItem(item); return; }
    if ([item isKindOfClass:[TWStream class]]) [TWNavigator openStream:item from:self];
    else if ([item isKindOfClass:[TWChannel class]]) [TWNavigator openChannelLogin:[(TWChannel *)item login] from:self];
    else if ([item isKindOfClass:[TWGame class]]) [TWNavigator openGame:item from:self];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
    if (!self.hasMore || self.loading) return;
    CGFloat bottom = scrollView.contentOffset.y + scrollView.bounds.size.height;
    if (bottom > scrollView.contentSize.height - scrollView.bounds.size.height) [self loadMore];
}

@end
