#import "TWGameViewController.h"
#import "TWGridViewController.h"
#import "TWVideoListViewController.h"
#import "TWImageLoader.h"
#import "TWGQL.h"
#import "TWTheme.h"
#import "TWUtils.h"
#import "TWCommon.h"
#import <QuartzCore/QuartzCore.h>

static const CGFloat kHeaderHeight = 104;

@interface TWGameViewController ()
@property (nonatomic, strong) TWGame *game;
@property (nonatomic, strong) UIView *header;
@property (nonatomic, strong) TWImageView *boxArt;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *viewersLabel;
@property (nonatomic, strong) UISegmentedControl *segments;
@property (nonatomic, strong) TWGridViewController *streams;
@property (nonatomic, strong) TWVideoListViewController *clips;
@property (nonatomic, strong) UIViewController *current;
@end

@implementation TWGameViewController

- (instancetype)initWithGame:(TWGame *)game
{
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _game = game;
        self.title = [game title];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    TWGame *game = self.game;

    self.header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, kHeaderHeight)];
    self.boxArt = [[TWImageView alloc] initWithFrame:CGRectZero];
    self.boxArt.contentMode = UIViewContentModeScaleAspectFill;
    self.boxArt.clipsToBounds = YES;
    self.boxArt.layer.cornerRadius = 3;
    self.boxArt.maxPixels = 400;
    [self.boxArt setImageURL:game.boxArtURL placeholder:[[TWTheme shared] boxArtPlaceholder]];
    [self.header addSubview:self.boxArt];
    self.nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.nameLabel.backgroundColor = [UIColor clearColor];
    self.nameLabel.font = [UIFont boldSystemFontOfSize:18];
    self.nameLabel.numberOfLines = 2;
    self.nameLabel.text = [game title];
    [self.header addSubview:self.nameLabel];
    self.viewersLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.viewersLabel.backgroundColor = [UIColor clearColor];
    self.viewersLabel.font = [UIFont systemFontOfSize:13];
    [self.header addSubview:self.viewersLabel];
    [self updateNumbers];
    self.segments = [[UISegmentedControl alloc] initWithItems:@[ L(@"Live Channels"), L(@"Clips") ]];
    self.segments.segmentedControlStyle = UISegmentedControlStyleBar;
    self.segments.selectedSegmentIndex = 0;
    [self.segments addTarget:self action:@selector(segmentChanged) forControlEvents:UIControlEventValueChanged];
    [self.header addSubview:self.segments];
    [self.view addSubview:self.header];

    self.streams = [[TWGridViewController alloc] initWithKind:TWGridKindStreams loader:^TWHTTPTask *(NSString *cursor, TWListCompletion completion) {
        return [TWGQL streamsForGame:game after:cursor completion:completion];
    }];
    self.streams.emptyText = L(@"Nobody is streaming this right now.");
    self.clips = [[TWVideoListViewController alloc] initWithLoader:^TWHTTPTask *(NSString *cursor, TWListCompletion completion) {
        return [TWGQL clipsForGame:game period:TWClipPeriodWeek after:cursor completion:completion];
    }];
    self.clips.emptyText = L(@"No clips this week.");
    [self showChild:self.streams];
    [self applyTheme];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applyTheme) name:TWThemeDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(settingsChanged) name:TWSettingsDidChangeNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [[TWTheme shared] applyToNavigationBar:self.navigationController.navigationBar];
}

- (void)viewWillLayoutSubviews
{
    [super viewWillLayoutSubviews];
    CGRect b = self.view.bounds;
    self.header.frame = CGRectMake(0, 0, b.size.width, kHeaderHeight);
    self.boxArt.frame = CGRectMake(12, 10, 42, 56);
    CGFloat x = 66;
    self.nameLabel.frame = CGRectMake(x, 8, b.size.width - x - 12, 40);
    self.viewersLabel.frame = CGRectMake(x, 48, b.size.width - x - 12, 16);
    CGFloat segW = MIN(b.size.width - 24, 320);
    self.segments.frame = CGRectMake(12, kHeaderHeight - 36, segW, 30);
    self.current.view.frame = CGRectMake(0, kHeaderHeight, b.size.width, b.size.height - kHeaderHeight);
}

- (void)updateNumbers
{
    NSMutableArray *parts = [NSMutableArray array];
    if (self.game.viewers > 0) [parts addObject:[TWUtils formatViewers:self.game.viewers]];
    if (self.game.channels > 0) [parts addObject:[NSString stringWithFormat:L(@"%@ channels"), [TWUtils formatCount:self.game.channels]]];
    self.viewersLabel.text = [parts componentsJoinedByString:@" · "];
}

- (void)applyTheme
{
    TWTheme *t = [TWTheme shared];
    self.view.backgroundColor = [t backgroundColor];
    self.header.backgroundColor = [t cardColor];
    self.nameLabel.textColor = [t primaryTextColor];
    self.viewersLabel.textColor = [t secondaryTextColor];
}

- (void)settingsChanged
{
    [self.streams reloadKeepingItemsIfPossible];   // (the language filter)
}

- (void)showChild:(UIViewController *)child
{
    if (self.current == child) return;
    if (self.current) {
        [self.current willMoveToParentViewController:nil];
        [self.current.view removeFromSuperview];
        [self.current removeFromParentViewController];
    }
    self.current = child;
    [self addChildViewController:child];
    CGRect b = self.view.bounds;
    child.view.frame = CGRectMake(0, kHeaderHeight, b.size.width, b.size.height - kHeaderHeight);
    [self.view addSubview:child.view];
    [child didMoveToParentViewController:self];
}

- (void)segmentChanged
{
    [self showChild:self.segments.selectedSegmentIndex == 1 ? (UIViewController *)self.clips : (UIViewController *)self.streams];
}

@end
