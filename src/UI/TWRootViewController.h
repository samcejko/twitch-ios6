#import <UIKit/UIKit.h>

// The tab bar: Following, Live, Categories, Search, Settings
@interface TWRootViewController : UITabBarController
- (void)applyTheme;
// Deep links (twitcher:channel/<login>, twitcher:open?channel=<login>)
- (void)openChannelLogin:(NSString *)login watch:(BOOL)watch;
@end

// The live channels tab: a grid with the language filter in the navigation bar
@interface TWBrowseViewController : UIViewController
@end
