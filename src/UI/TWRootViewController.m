#import "TWRootViewController.h"
#import "TWGridViewController.h"
#import "TWFollowingViewController.h"
#import "TWSearchViewController.h"
#import "TWSettingsViewController.h"
#import "TWNavigator.h"
#import "TWGQL.h"
#import "TWSettings.h"
#import "TWTheme.h"
#import "TWCommon.h"

#pragma mark - Browse

@interface TWBrowseViewController () <UIActionSheetDelegate>
@property (nonatomic, strong) TWGridViewController *grid;
@property (nonatomic, strong) UIBarButtonItem *languageItem;
@end

@implementation TWBrowseViewController

- (instancetype)init
{
    self = [super initWithNibName:nil bundle:nil];
    if (self) self.title = L(@"Live");
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.grid = [[TWGridViewController alloc] initWithKind:TWGridKindStreams loader:^TWHTTPTask *(NSString *cursor, TWListCompletion completion) {
        return [TWGQL topStreamsAfter:cursor completion:completion];
    }];
    self.grid.emptyText = L(@"No live channels for this language right now.");
    [self addChildViewController:self.grid];
    self.grid.view.frame = self.view.bounds;
    self.grid.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.grid.view];
    [self.grid didMoveToParentViewController:self];
    self.languageItem = [[UIBarButtonItem alloc] initWithTitle:@"" style:UIBarButtonItemStyleBordered target:self action:@selector(languageTapped)];
    self.navigationItem.rightBarButtonItem = self.languageItem;
    [self updateLanguageItem];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(settingsChanged) name:TWSettingsDidChangeNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [[TWTheme shared] applyToNavigationBar:self.navigationController.navigationBar];
}

+ (NSArray *)languages
{
    // code, name (the common languages of Twitch; "" = all)
    return @[ @[@"", L(@"All languages")], @[@"cs", @"Čeština"], @[@"sk", @"Slovenčina"], @[@"en", @"English"], @[@"de", @"Deutsch"],
              @[@"pl", @"Polski"], @[@"es", @"Español"], @[@"fr", @"Français"], @[@"it", @"Italiano"], @[@"pt", @"Português"],
              @[@"ru", @"Русский"], @[@"uk", @"Українська"], @[@"tr", @"Türkçe"], @[@"ja", @"日本語"], @[@"ko", @"한국어"] ];
}

- (void)updateLanguageItem
{
    NSString *code = [TWSettings streamLanguage];
    NSString *title = L(@"Language");
    for (NSArray *l in [TWBrowseViewController languages]) {
        if ([l[0] isEqualToString:code] && code.length) title = l[1];
    }
    self.languageItem.title = title;
}

- (void)languageTapped
{
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:L(@"Show channels streaming in") delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
    for (NSArray *l in [TWBrowseViewController languages]) [sheet addButtonWithTitle:l[1]];
    sheet.cancelButtonIndex = [sheet addButtonWithTitle:L(@"Cancel")];
    if (TWIsPad()) [sheet showFromBarButtonItem:self.languageItem animated:YES];
    else [sheet showFromTabBar:self.tabBarController.tabBar];
}

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex
{
    NSArray *languages = [TWBrowseViewController languages];
    if (buttonIndex < 0 || buttonIndex >= (NSInteger)languages.count) return;
    [TWSettings setStreamLanguage:languages[(NSUInteger)buttonIndex][0]];
    [TWSettings save];
    [self updateLanguageItem];
    [self.grid reload];
}

- (void)settingsChanged
{
    [self updateLanguageItem];
}

@end

#pragma mark - Root

@interface TWRootViewController () <UITabBarControllerDelegate>
@property (nonatomic, strong) UINavigationController *followingNav;
@property (nonatomic, strong) UINavigationController *browseNav;
@property (nonatomic, strong) UINavigationController *gamesNav;
@property (nonatomic, strong) UINavigationController *searchNav;
@property (nonatomic, strong) UINavigationController *settingsNav;
@end

@implementation TWRootViewController

- (instancetype)init
{
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        TWTheme *t = [TWTheme shared];
        TWFollowingViewController *following = [[TWFollowingViewController alloc] init];
        following.tabBarItem = [[UITabBarItem alloc] initWithTitle:L(@"Following") image:[t tabIconFollowing] tag:0];
        _followingNav = [[UINavigationController alloc] initWithRootViewController:following];

        TWBrowseViewController *browse = [[TWBrowseViewController alloc] init];
        browse.tabBarItem = [[UITabBarItem alloc] initWithTitle:L(@"Live") image:[t tabIconBrowse] tag:1];
        _browseNav = [[UINavigationController alloc] initWithRootViewController:browse];

        TWGridViewController *games = [[TWGridViewController alloc] initWithKind:TWGridKindGames loader:^TWHTTPTask *(NSString *cursor, TWListCompletion completion) {
            return [TWGQL topGamesAfter:cursor completion:completion];
        }];
        games.title = L(@"Categories");
        games.tabBarItem = [[UITabBarItem alloc] initWithTitle:L(@"Categories") image:[t tabIconGames] tag:2];
        _gamesNav = [[UINavigationController alloc] initWithRootViewController:games];

        TWSearchViewController *search = [[TWSearchViewController alloc] init];
        search.tabBarItem = [[UITabBarItem alloc] initWithTitle:L(@"Search") image:[t tabIconSearch] tag:3];
        _searchNav = [[UINavigationController alloc] initWithRootViewController:search];

        TWSettingsViewController *settings = [[TWSettingsViewController alloc] init];
        settings.tabBarItem = [[UITabBarItem alloc] initWithTitle:L(@"Settings") image:[t tabIconSettings] tag:4];
        _settingsNav = [[UINavigationController alloc] initWithRootViewController:settings];

        self.viewControllers = @[ _followingNav, _browseNav, _gamesNav, _searchNav, _settingsNav ];
        NSInteger last = [[NSUserDefaults standardUserDefaults] integerForKey:@"lastTab"];
        self.selectedIndex = (NSUInteger)((last >= 0 && last <= 4) ? last : 1);
        self.delegate = self;
        [self applyTheme];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applyTheme) name:TWThemeDidChangeNotification object:nil];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)applyTheme
{
    TWTheme *t = [TWTheme shared];
    for (UINavigationController *nav in self.viewControllers) [t applyToNavigationBar:nav.navigationBar];
    [t applyToTabBar:self.tabBar];
    [[UIApplication sharedApplication] setStatusBarStyle:[t statusBarStyle] animated:NO];
}

- (void)tabBarController:(UITabBarController *)tabBarController didSelectViewController:(UIViewController *)viewController
{
    [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger)self.selectedIndex forKey:@"lastTab"];
}

- (void)openChannelLogin:(NSString *)login watch:(BOOL)watch
{
    if (watch) [TWNavigator watchChannelLogin:login from:self];
    else {
        self.selectedViewController = self.searchNav;
        [TWNavigator openChannelLogin:login from:self.searchNav];
    }
}

#pragma mark - Rotation

- (BOOL)shouldAutorotate
{
    return YES;
}

- (NSUInteger)supportedInterfaceOrientations
{
    return TWIsPad() ? UIInterfaceOrientationMaskAll : UIInterfaceOrientationMaskAllButUpsideDown;
}

@end
