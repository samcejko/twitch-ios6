#import <UIKit/UIKit.h>
#import "TWModels.h"

// A category: box art and numbers on top, below the live channels (grid) or the top clips (list)
@interface TWGameViewController : UIViewController
- (instancetype)initWithGame:(TWGame *)game;
@end
