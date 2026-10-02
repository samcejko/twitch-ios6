#import <UIKit/UIKit.h>

// A list of options with a checkmark on the chosen one
@interface TWChoiceViewController : UITableViewController
@property (nonatomic, strong) NSArray *titles;
@property (nonatomic, strong) NSArray *subtitles;       // optional, same count
@property (nonatomic) NSInteger selectedIndex;
@property (nonatomic, copy) void (^completion)(NSInteger index);
@end

// One line of text to enter (a Client ID)
@interface TWTextEntryViewController : UIViewController
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSString *placeholder;
@property (nonatomic, copy) NSString *explanation;
@property (nonatomic, copy) void (^completion)(NSString *text);   // nil when cancelled
@end
