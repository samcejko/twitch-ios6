#import "TWSettingsViewController.h"
#import "TWChoiceViewController.h"
#import "TWLoginViewController.h"
#import "TWAuth.h"
#import "TWSettings.h"
#import "TWTheme.h"
#import "TWTLSSocket.h"
#import "TWHTTP.h"
#import "TWImageLoader.h"
#import "TWUtils.h"
#import "TWCommon.h"

typedef NS_ENUM(NSInteger, TWSettingsSection) {
    TWSectionAccount = 0,
    TWSectionPlayback,
    TWSectionChat,
    TWSectionAppearance,
    TWSectionAdvanced,
    TWSectionAbout,
    TWSectionCount,
};

@interface TWSettingsViewController () <UIActionSheetDelegate>
@property (nonatomic, copy) NSString *cacheSizeText;
@property (nonatomic, copy) NSString *connectionTestText;
@property (nonatomic, strong) TWHTTPTask *testTask;
@end

@implementation TWSettingsViewController

- (instancetype)init
{
    self = [super initWithStyle:UITableViewStyleGrouped];
    if (self) self.title = L(@"Settings");
    return self;
}

- (void)dealloc
{
    [_testTask cancel];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(authChanged) name:TWAuthDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applyTheme) name:TWThemeDidChangeNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self applyTheme];
    [self.tableView reloadData];
    __weak TWSettingsViewController *weakSelf = self;
    [[TWImageLoader shared] diskUsage:^(unsigned long long bytes) {
        weakSelf.cacheSizeText = [TWUtils formatFileSize:bytes];
        [weakSelf.tableView reloadData];
    }];
}

- (void)applyTheme
{
    TWTheme *t = [TWTheme shared];
    [t applyToTableView:self.tableView];
    [t applyToNavigationBar:self.navigationController.navigationBar];
    [self.tableView reloadData];
}

- (void)authChanged
{
    [self.tableView reloadData];
}

#pragma mark - Helpers

- (NSInteger)tagForSection:(NSInteger)section row:(NSInteger)row
{
    return section * 100 + row;
}

- (UISwitch *)switchOn:(BOOL)on tag:(NSInteger)tag
{
    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectZero];
    sw.on = on;
    sw.tag = tag;
    [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    return sw;
}

- (UISegmentedControl *)segmentedWithItems:(NSArray *)items selected:(NSInteger)selected tag:(NSInteger)tag width:(CGFloat)width
{
    UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:items];
    seg.segmentedControlStyle = UISegmentedControlStyleBar;
    seg.frame = CGRectMake(0, 0, width, 30);
    seg.selectedSegmentIndex = selected;
    seg.tag = tag;
    [seg addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
    return seg;
}

+ (NSArray *)qualityKeys
{
    return @[ TWQualityAuto, TWQualitySource, @"1080", @"720", @"480", @"360", @"160", TWQualityAudio ];
}

+ (NSString *)qualityTitle:(NSString *)key
{
    if ([key isEqualToString:TWQualityAuto]) return L(@"Automatic");
    if ([key isEqualToString:TWQualitySource]) return L(@"Source (best)");
    if ([key isEqualToString:TWQualityAudio]) return L(@"Audio only");
    return [NSString stringWithFormat:@"%@p", key];
}

#pragma mark - Table structure

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return TWSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch ((TWSettingsSection)section) {
        case TWSectionAccount: return 2;
        case TWSectionPlayback: return 3;
        case TWSectionChat: return 6;
        case TWSectionAppearance: return 1;
        case TWSectionAdvanced: return 3;
        case TWSectionAbout: return 4;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch ((TWSettingsSection)section) {
        case TWSectionAccount: return L(@"Twitch account");
        case TWSectionPlayback: return L(@"Playback");
        case TWSectionChat: return L(@"Chat");
        case TWSectionAppearance: return L(@"Appearance");
        case TWSectionAdvanced: return L(@"Advanced");
        case TWSectionAbout: return L(@"About");
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    switch ((TWSettingsSection)section) {
        case TWSectionAccount: return L(@"Watching and reading the chat work without an account. Logging in shows the channels you follow and lets you write in the chat.");
        case TWSectionPlayback: return L(@"This device decodes H.264 up to 1080p at 30 frames per second; renditions beyond that are left out of \"Automatic\".");
        case TWSectionAdvanced: return L(@"Turn certificate verification off only if the device clock is wrong or the certificate bundle is outdated.");
        default: return nil;
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == TWSectionAccount && indexPath.row == 0) return 56;
    if (indexPath.section == TWSectionAdvanced && indexPath.row == 2) return 56;
    return 44;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    TWTheme *t = [TWTheme shared];
    TWAuth *auth = [TWAuth shared];
    NSInteger sec = indexPath.section, row = indexPath.row;
    NSInteger tag = [self tagForSection:sec row:row];
    BOOL subtitle = (sec == TWSectionAccount && row == 0) || (sec == TWSectionAdvanced && row == 2);
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:subtitle ? UITableViewCellStyleSubtitle : UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.detailTextLabel.numberOfLines = 2;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:subtitle ? 12 : 15];
    cell.selectionStyle = UITableViewCellSelectionStyleBlue;
    CGFloat segW = TWIsPad() ? 260 : 190;

    switch ((TWSettingsSection)sec) {
        case TWSectionAccount:
            if (row == 0) {
                cell.textLabel.text = L(@"Account");
                if (auth.isLoggedIn) {
                    cell.detailTextLabel.text = [NSString stringWithFormat:L(@"Logged in as %@"), auth.displayName ?: auth.login];
                } else {
                    cell.detailTextLabel.text = L(@"Not logged in");
                }
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
            } else {
                cell.textLabel.text = auth.isLoggedIn ? L(@"Log Out") : L(@"Log In");
                cell.textLabel.textColor = auth.isLoggedIn ? [UIColor colorWithRed:0.75 green:0.1 blue:0.1 alpha:1] : [t accentColor];
                cell.textLabel.textAlignment = NSTextAlignmentCenter;
            }
            break;
        case TWSectionPlayback:
            if (row == 0) {
                cell.textLabel.text = L(@"Quality");
                cell.detailTextLabel.text = [TWSettingsViewController qualityTitle:[TWSettings preferredQuality]];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            } else if (row == 1) {
                cell.textLabel.text = L(@"Sound in background");
                cell.accessoryView = [self switchOn:[TWSettings backgroundAudio] tag:tag];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
            } else {
                cell.textLabel.text = L(@"Keep screen on");
                cell.accessoryView = [self switchOn:[TWSettings keepScreenOn] tag:tag];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
            }
            break;
        case TWSectionChat:
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            if (row == 0) {
                cell.textLabel.text = L(@"Text size");
                cell.accessoryView = [self segmentedWithItems:@[ L(@"Small"), L(@"Medium"), L(@"Large") ] selected:[TWSettings chatFontSize] tag:tag width:segW];
            } else if (row == 1) {
                cell.textLabel.text = L(@"Timestamps");
                cell.accessoryView = [self switchOn:[TWSettings chatTimestamps] tag:tag];
            } else if (row == 2) {
                cell.textLabel.text = L(@"Animated emotes");
                cell.accessoryView = [self switchOn:[TWSettings animatedEmotes] tag:tag];
            } else if (row == 3) {
                cell.textLabel.text = L(@"BetterTTV, FFZ, 7TV emotes");
                cell.accessoryView = [self switchOn:[TWSettings thirdPartyEmotes] tag:tag];
            } else if (row == 4) {
                cell.textLabel.text = L(@"Show deleted messages");
                cell.accessoryView = [self switchOn:[TWSettings showDeletedMessages] tag:tag];
            } else {
                cell.textLabel.text = L(@"Lines between messages");
                cell.accessoryView = [self switchOn:[TWSettings chatSeparators] tag:tag];
            }
            break;
        case TWSectionAppearance:
            cell.textLabel.text = L(@"Theme");
            cell.accessoryView = [self segmentedWithItems:@[ L(@"Light"), L(@"Dark") ] selected:t.isDark ? 1 : 0 tag:tag width:TWIsPad() ? 200 : 150];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        case TWSectionAdvanced:
            if (row == 0) {
                cell.textLabel.text = L(@"Verify certificates");
                cell.accessoryView = [self switchOn:[TWSettings verifyTLS] tag:tag];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
            } else if (row == 1) {
                cell.textLabel.text = L(@"Clear image cache");
                cell.detailTextLabel.text = self.cacheSizeText ?: @"";
            } else {
                cell.textLabel.text = L(@"Connection test");
                cell.detailTextLabel.text = self.connectionTestText ?: L(@"Tap to test the connection to Twitch");
            }
            break;
        case TWSectionAbout:
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            if (row == 0) {
                cell.textLabel.text = L(@"Version");
                cell.detailTextLabel.text = [TWUtils appVersion];
            } else if (row == 1) {
                cell.textLabel.text = L(@"Author");
                cell.detailTextLabel.text = @"samcejko";
            } else if (row == 2) {
                cell.textLabel.text = L(@"Root certificates");
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld", (long)[TWTLSSocket caCertificateCount]];
            } else {
                cell.textLabel.text = L(@"Device");
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · iOS %@", [TWUtils deviceModel], [UIDevice currentDevice].systemVersion];
            }
            break;
        default:
            break;
    }
    UIColor *keep = (sec == TWSectionAccount && row == 1) ? cell.textLabel.textColor : nil;
    [t styleCell:cell];
    if (keep) cell.textLabel.textColor = keep;
    return cell;
}

#pragma mark - Controls

- (void)switchChanged:(UISwitch *)sw
{
    NSInteger sec = sw.tag / 100, row = sw.tag % 100;
    if (sec == TWSectionPlayback && row == 1) [TWSettings setBackgroundAudio:sw.on];
    else if (sec == TWSectionPlayback && row == 2) [TWSettings setKeepScreenOn:sw.on];
    else if (sec == TWSectionChat && row == 1) [TWSettings setChatTimestamps:sw.on];
    else if (sec == TWSectionChat && row == 2) { [TWSettings setAnimatedEmotes:sw.on]; [TWImageLoader shared].animationAllowed = sw.on; [[TWImageLoader shared] clearMemory]; }
    else if (sec == TWSectionChat && row == 3) [TWSettings setThirdPartyEmotes:sw.on];
    else if (sec == TWSectionChat && row == 4) [TWSettings setShowDeletedMessages:sw.on];
    else if (sec == TWSectionChat && row == 5) [TWSettings setChatSeparators:sw.on];
    else if (sec == TWSectionAdvanced && row == 0) [TWSettings setVerifyTLS:sw.on];
    [TWSettings save];
}

- (void)segmentChanged:(UISegmentedControl *)seg
{
    NSInteger sec = seg.tag / 100, row = seg.tag % 100;
    if (sec == TWSectionChat && row == 0) [TWSettings setChatFontSize:seg.selectedSegmentIndex];
    else if (sec == TWSectionAppearance) [[TWTheme shared] setDark:seg.selectedSegmentIndex == 1];
    [TWSettings save];
}

#pragma mark - Selection

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSInteger sec = indexPath.section, row = indexPath.row;
    if (sec == TWSectionAccount && row == 1) {
        if ([TWAuth shared].isLoggedIn) {
            UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:L(@"Log out of Twitch on this device?") delegate:self
                                                      cancelButtonTitle:L(@"Cancel") destructiveButtonTitle:L(@"Log Out") otherButtonTitles:nil];
            sheet.tag = 1;
            UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
            [sheet showFromRect:cell.bounds inView:cell animated:YES];
        } else {
            [TWLoginViewController presentFrom:self];
        }
    } else if (sec == TWSectionPlayback && row == 0) {
        TWChoiceViewController *vc = [[TWChoiceViewController alloc] init];
        vc.title = L(@"Quality");
        NSArray *keys = [TWSettingsViewController qualityKeys];
        NSMutableArray *titles = [NSMutableArray array];
        for (NSString *k in keys) [titles addObject:[TWSettingsViewController qualityTitle:k]];
        vc.titles = titles;
        vc.subtitles = @[ L(@"The player picks what the connection allows, up to what the device decodes."), L(@"The streamer's own quality, when the device can decode it."),
                          @"", @"", @"", @"", @"", L(@"Just the sound, for the background.") ];
        NSUInteger idx = [keys indexOfObject:[TWSettings preferredQuality]];
        vc.selectedIndex = idx == NSNotFound ? 0 : (NSInteger)idx;
        vc.completion = ^(NSInteger index) {
            [TWSettings setPreferredQuality:keys[(NSUInteger)index]];
            [TWSettings save];
        };
        [self.navigationController pushViewController:vc animated:YES];
    } else if (sec == TWSectionAdvanced && row == 1) {
        self.cacheSizeText = L(@"Clearing…");
        [tableView reloadData];
        __weak TWSettingsViewController *weakSelf = self;
        [[TWImageLoader shared] clearDiskWithCompletion:^{
            weakSelf.cacheSizeText = [TWUtils formatFileSize:0];
            [weakSelf.tableView reloadData];
        }];
    } else if (sec == TWSectionAdvanced && row == 2) {
        [self runConnectionTest];
    }
}

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (actionSheet.tag == 1 && buttonIndex == actionSheet.destructiveButtonIndex) {
        [[TWAuth shared] logout];
        [self.tableView reloadData];
    }
}

- (void)runConnectionTest
{
    if (self.testTask) return;
    self.connectionTestText = L(@"Testing…");
    [self.tableView reloadData];
    NSDate *start = [NSDate date];
    __weak TWSettingsViewController *weakSelf = self;
    self.testTask = [TWHTTP get:@"https://gql.twitch.tv/" headers:nil completion:^(NSInteger status, NSData *body, NSDictionary *headers, NSError *error) {
        TWSettingsViewController *s = weakSelf;
        if (!s) return;
        NSTimeInterval dt = -[start timeIntervalSinceNow];
        if (error) s.connectionTestText = error.localizedDescription;
        else s.connectionTestText = [NSString stringWithFormat:L(@"Twitch answered (HTTP %ld) in %.1f s"), (long)status, dt];
        s.testTask = nil;
        [s.tableView reloadData];
    }];
}

@end
