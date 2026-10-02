#import <UIKit/UIKit.h>
#import "TWChatMessage.h"
#import "TWChatLayout.h"

@class TWChatView;

@protocol TWChatViewDelegate <NSObject>
@optional
- (void)chatView:(TWChatView *)chatView didTapName:(NSString *)login displayName:(NSString *)displayName;
- (void)chatView:(TWChatView *)chatView didTapLink:(NSString *)url;
- (void)chatView:(TWChatView *)chatView wantsToSend:(NSString *)text;        // the input bar's send button
- (void)chatViewDidChangeKeyboard:(TWChatView *)chatView visible:(BOOL)visible;
@end

// One chat line in the table
@interface TWChatCell : UITableViewCell
+ (NSString *)reuseIdentifier;
- (void)configureWithMessage:(TWChatMessage *)message layout:(TWChatLayout *)layout style:(TWChatStyle *)style alternate:(BOOL)alternate;
- (void)refreshImages;                 // an image arrived
@property (nonatomic, readonly, strong) TWChatMessage *message;
@property (nonatomic, readonly, strong) TWChatLayout *layout;
@end

// The chat of a channel: the messages (scrolling with the newest at the bottom, a "new messages" button when the
// user scrolled up), an input bar with an emote picker when the user can write. Fed by TWIRC through -appendMessages:.
@interface TWChatView : UIView

@property (nonatomic, weak) id<TWChatViewDelegate> delegate;
@property (nonatomic, copy) NSString *channelId;
@property (nonatomic, copy) NSString *channelLogin;
@property (nonatomic) BOOL canSend;                   // shows the input bar
@property (nonatomic, readonly) BOOL keyboardVisible;
@property (nonatomic) BOOL replayMode;                // a video's chat: timestamps are offsets, no input

- (void)appendMessages:(NSArray *)messages;           // TWChatMessage
- (void)appendNotice:(NSString *)text;
- (void)clearMessagesOfUser:(NSString *)login seconds:(NSInteger)seconds;   // nil = everything
- (void)deleteMessageWithId:(NSString *)messageId;
- (void)removeAllMessages;
- (void)insertMention:(NSString *)login;               // "@name " into the input
- (void)setSending:(BOOL)sending;                      // disables the send button while a message is on its way
- (void)clearInput;
- (void)dismissKeyboard;
- (void)applyTheme;
- (void)scrollToBottom;

@end
