#import "TWLoginViewController.h"
#import "TWAuth.h"
#import "TWSettings.h"
#import "TWNavigator.h"
#import "TWTheme.h"
#import "TWUtils.h"
#import "TWCommon.h"

@interface TWLoginViewController () <UIAlertViewDelegate>
@property (nonatomic, strong) UILabel *introLabel;
@property (nonatomic, strong) UILabel *codeLabel;
@property (nonatomic, strong) UILabel *addressLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIButton *codeCopyButton;
@property (nonatomic, strong) UIButton *browserButton;
@property (nonatomic, copy) NSString *userCode;
@property (nonatomic, copy) NSString *verificationURL;
@property (nonatomic) BOOL finished;
@end

@implementation TWLoginViewController

+ (void)presentFrom:(UIViewController *)controller
{
    if (![[TWAuth shared] hasClientId]) {
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:L(@"Client ID needed")
                                                        message:L(@"Logging in needs a Twitch application Client ID. Register one for free at dev.twitch.tv (type \"Public\") and enter it in Settings > Account.")
                                                       delegate:nil cancelButtonTitle:L(@"OK") otherButtonTitles:nil];
        [alert show];
        return;
    }
    TWLoginViewController *vc = [[TWLoginViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = TWIsPad() ? UIModalPresentationFormSheet : UIModalPresentationFullScreen;
    [[TWTheme shared] applyToNavigationBar:nav.navigationBar];
    [[TWNavigator presenterFrom:controller] presentViewController:nav animated:YES completion:nil];
}

- (instancetype)init
{
    self = [super initWithNibName:nil bundle:nil];
    if (self) self.title = L(@"Log in to Twitch");
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    TWTheme *t = [TWTheme shared];
    self.view.backgroundColor = [t backgroundColor];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancelTapped)];

    self.introLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.introLabel.backgroundColor = [UIColor clearColor];
    self.introLabel.numberOfLines = 0;
    self.introLabel.textAlignment = NSTextAlignmentCenter;
    self.introLabel.font = [UIFont systemFontOfSize:15];
    self.introLabel.textColor = [t primaryTextColor];
    self.introLabel.text = L(@"On a computer or phone, open the address below, log in to Twitch and enter this code:");
    [self.view addSubview:self.introLabel];

    self.codeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.codeLabel.backgroundColor = [UIColor clearColor];
    self.codeLabel.textAlignment = NSTextAlignmentCenter;
    self.codeLabel.font = [UIFont fontWithName:@"Courier-Bold" size:40] ?: [UIFont boldSystemFontOfSize:40];
    self.codeLabel.textColor = [t accentColor];
    self.codeLabel.adjustsFontSizeToFitWidth = YES;
    self.codeLabel.text = @"········";
    [self.view addSubview:self.codeLabel];

    self.addressLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.addressLabel.backgroundColor = [UIColor clearColor];
    self.addressLabel.textAlignment = NSTextAlignmentCenter;
    self.addressLabel.font = [UIFont boldSystemFontOfSize:18];
    self.addressLabel.textColor = [t primaryTextColor];
    self.addressLabel.text = @"twitch.tv/activate";
    [self.view addSubview:self.addressLabel];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusLabel.backgroundColor = [UIColor clearColor];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.font = [UIFont systemFontOfSize:14];
    self.statusLabel.textColor = [t secondaryTextColor];
    self.statusLabel.text = L(@"Asking Twitch for a code…");
    [self.view addSubview:self.statusLabel];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:[t spinnerStyle]];
    [self.spinner startAnimating];
    [self.view addSubview:self.spinner];

    self.codeCopyButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.codeCopyButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [self.codeCopyButton setTitle:L(@"Copy Code") forState:UIControlStateNormal];
    [self.codeCopyButton setTitleColor:[t primaryTextColor] forState:UIControlStateNormal];
    [self.codeCopyButton setBackgroundImage:[t buttonImageHighlighted:NO] forState:UIControlStateNormal];
    [self.codeCopyButton setBackgroundImage:[t buttonImageHighlighted:YES] forState:UIControlStateHighlighted];
    [self.codeCopyButton addTarget:self action:@selector(codeCopyTapped) forControlEvents:UIControlEventTouchUpInside];
    self.codeCopyButton.hidden = YES;
    [self.view addSubview:self.codeCopyButton];

    // the user's own browser app (Surfari) opens pages this device's Safari cannot
    BOOL hasBrowser = [[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:@"browser:home"]];
    self.browserButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.browserButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [self.browserButton setTitle:hasBrowser ? L(@"Open in Surfari") : L(@"Open in Safari") forState:UIControlStateNormal];
    [self.browserButton setTitleColor:[t primaryTextColor] forState:UIControlStateNormal];
    [self.browserButton setBackgroundImage:[t buttonImageHighlighted:NO] forState:UIControlStateNormal];
    [self.browserButton setBackgroundImage:[t buttonImageHighlighted:YES] forState:UIControlStateHighlighted];
    [self.browserButton addTarget:self action:@selector(browserTapped) forControlEvents:UIControlEventTouchUpInside];
    self.browserButton.hidden = YES;
    [self.view addSubview:self.browserButton];

    [self start];
}

- (void)viewWillLayoutSubviews
{
    [super viewWillLayoutSubviews];
    CGRect b = self.view.bounds;
    CGFloat w = MIN(b.size.width - 40, 440);
    CGFloat x = floor((b.size.width - w) / 2);
    CGFloat y = 24;
    self.introLabel.frame = CGRectMake(x, y, w, 60);
    y += 70;
    self.addressLabel.frame = CGRectMake(x, y, w, 24);
    y += 34;
    self.codeLabel.frame = CGRectMake(x, y, w, 50);
    y += 62;
    self.codeCopyButton.frame = CGRectMake(floor((b.size.width - 250) / 2), y, 120, 34);
    self.browserButton.frame = CGRectMake(floor((b.size.width - 250) / 2) + 130, y, 120, 34);
    y += 50;
    self.spinner.center = CGPointMake(b.size.width / 2, y + 10);
    y += 30;
    self.statusLabel.frame = CGRectMake(x, y, w, 60);
}

- (void)start
{
    __weak TWLoginViewController *weakSelf = self;
    [[TWAuth shared] beginDeviceFlow:^(NSString *userCode, NSString *verificationURL, NSError *error) {
        TWLoginViewController *s = weakSelf;
        if (!s) return;
        if (error) {
            [s.spinner stopAnimating];
            s.statusLabel.text = error.localizedDescription;
            return;
        }
        s.userCode = userCode;
        s.verificationURL = verificationURL;
        s.codeLabel.text = userCode;
        s.codeCopyButton.hidden = NO;
        s.browserButton.hidden = NO;
        s.statusLabel.text = L(@"Waiting for the confirmation on twitch.tv… this screen finishes by itself.");
    } completion:^(NSError *error) {
        TWLoginViewController *s = weakSelf;
        if (!s || s.finished) return;
        s.finished = YES;
        [s.spinner stopAnimating];
        if (error) {
            s.statusLabel.text = error.localizedDescription;
            s.codeCopyButton.hidden = YES;
            s.browserButton.hidden = YES;
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:L(@"Login failed") message:error.localizedDescription delegate:s
                                                  cancelButtonTitle:L(@"Close") otherButtonTitles:L(@"Try Again"), nil];
            [alert show];
            return;
        }
        NSString *name = [TWAuth shared].displayName ?: [TWAuth shared].login ?: @"";
        s.statusLabel.text = [NSString stringWithFormat:L(@"Logged in as %@."), name];
        [s dismissViewControllerAnimated:YES completion:nil];
    }];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (buttonIndex == alertView.cancelButtonIndex) {
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    self.finished = NO;
    self.codeLabel.text = @"········";
    self.statusLabel.text = L(@"Asking Twitch for a code…");
    [self.spinner startAnimating];
    [self start];
}

- (void)cancelTapped
{
    self.finished = YES;
    [[TWAuth shared] cancelDeviceFlow];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)codeCopyTapped
{
    if (!self.userCode.length) return;
    [UIPasteboard generalPasteboard].string = self.userCode;
    self.statusLabel.text = L(@"Code copied. Waiting for the confirmation on twitch.tv…");
}

- (void)browserTapped
{
    NSString *target = self.verificationURL.length ? self.verificationURL : @"https://www.twitch.tv/activate";
    NSURL *browser = [NSURL URLWithString:[@"browser:" stringByAppendingString:target]];
    UIApplication *app = [UIApplication sharedApplication];
    if ([app canOpenURL:browser]) [app openURL:browser];
    else [app openURL:[NSURL URLWithString:target]];
}

@end
