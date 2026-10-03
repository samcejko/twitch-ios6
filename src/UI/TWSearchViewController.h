#import <UIKit/UIKit.h>

// The "Search" tab: channels and categories by name, recent searches
@interface TWSearchViewController : UITableViewController
- (void)searchFor:(NSString *)text;   // (the twitcher:search?q= link)
@end
