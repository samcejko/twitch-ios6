#import <Foundation/Foundation.h>
#import "TWChatMessage.h"

typedef NS_ENUM(NSInteger, TWIRCState) {
    TWIRCStateDisconnected = 0,
    TWIRCStateConnecting,
    TWIRCStateConnected,       // joined the channel
    TWIRCStateReconnecting,    // lost the connection, trying again in a moment
};

@class TWIRC;

// Everything arrives on the main thread.
@protocol TWIRCDelegate <NSObject>
- (void)irc:(TWIRC *)irc didReceiveMessages:(NSArray *)messages;                  // TWChatMessage, in order, batched
- (void)irc:(TWIRC *)irc didChangeState:(TWIRCState)state;
@optional
// keys: emoteOnly, subscribersOnly, uniqueOnly (NSNumber BOOL), followersOnly (minutes, -1 = off), slow (seconds)
- (void)irc:(TWIRC *)irc didUpdateRoomState:(NSDictionary *)state;
// A moderator removed the messages of a user (login nil = the whole chat); seconds > 0 = timeout, 0 = ban or clear
- (void)irc:(TWIRC *)irc didClearMessagesOfUser:(NSString *)login seconds:(NSInteger)seconds;
- (void)irc:(TWIRC *)irc didDeleteMessageWithId:(NSString *)messageId;
@end

// The chat of one channel, read as a visitor over Twitch's IRC (TLS through the app's own stack). Reconnects by
// itself; answers the server's pings. Messages are sent through the Helix API (TWHelix), not here.
@interface TWIRC : NSObject

- (instancetype)initWithChannel:(NSString *)login;

@property (nonatomic, weak) id<TWIRCDelegate> delegate;
@property (nonatomic, readonly, copy) NSString *channel;
@property (nonatomic, readonly) TWIRCState state;
@property (nonatomic, copy) NSString *ownLogin;        // marks mentions and the user's own messages

- (void)connect;
- (void)disconnect;

@end
