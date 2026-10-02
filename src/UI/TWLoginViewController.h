#import <UIKit/UIKit.h>

// The Twitch login: shows the code to type at twitch.tv/activate and waits for the confirmation
@interface TWLoginViewController : UIViewController
+ (void)presentFrom:(UIViewController *)controller;
@end
