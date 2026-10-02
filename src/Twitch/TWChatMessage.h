#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// One line of the IRC protocol, split up: @tags :nick!user@host COMMAND params :trailing
@interface TWIRCLine : NSObject
@property (nonatomic, strong) NSDictionary *tags;     // values unescaped; "" for tags without a value
@property (nonatomic, copy) NSString *nick;
@property (nonatomic, copy) NSString *command;
@property (nonatomic, strong) NSArray *params;        // without the trailing parameter
@property (nonatomic, copy) NSString *trailing;
+ (instancetype)lineWithString:(NSString *)raw;
- (NSString *)channel;                                 // the first "#channel" parameter without the "#", or nil
@end

typedef NS_ENUM(NSInteger, TWChatKind) {
    TWChatKindMessage = 0,     // somebody wrote something (also /me)
    TWChatKindNotice,          // a line from the system or the app: grey text, no author
    TWChatKindUserNotice,      // a subscription, a raid...: systemText, and maybe a message from the user as well
};

// A Twitch emote inside the text
@interface TWChatEmoteRange : NSObject
@property (nonatomic, copy) NSString *emoteId;
@property (nonatomic) NSRange range;                   // in UTF-16 units of `text`
@end

// One entry of a chat: a message, or a notice
@interface TWChatMessage : NSObject

@property (nonatomic) TWChatKind kind;
@property (nonatomic, copy) NSString *messageId;
@property (nonatomic, copy) NSString *login;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *userId;
@property (nonatomic, copy) NSString *text;             // what the user wrote ("" for pure notices)
@property (nonatomic, copy) NSString *systemText;       // "X subscribed for 12 months", "Chat was cleared"...
@property (nonatomic, copy) NSString *colorHex;         // the user's name colour, "#RRGGBB" or nil
@property (nonatomic, copy) NSString *noticeType;       // the msg-id tag: sub, resub, raid, announcement, highlighted-message...
@property (nonatomic, copy) NSString *replyParentName;  // when the message answers another one
@property (nonatomic, copy) NSString *replyParentText;
@property (nonatomic, strong) NSArray *badges;          // @[ @[set, version] ]
@property (nonatomic, strong) NSArray *emotes;          // TWChatEmoteRange, by position
@property (nonatomic, strong) NSDate *timestamp;
@property (nonatomic) NSInteger bits;
@property (nonatomic) BOOL isAction;                    // /me
@property (nonatomic) BOOL isDeleted;                   // removed by a moderator
@property (nonatomic) BOOL isMention;                   // names the logged-in user
@property (nonatomic) BOOL isFirstMessage;              // the user's first message in this channel
@property (nonatomic) BOOL isHighlighted;               // channel points highlight
@property (nonatomic) BOOL isOwn;                       // written by the logged-in user

// Layout cache used by the chat view (TWChatLayout); dropped when the width or the style changes
@property (nonatomic, strong) id layout;
@property (nonatomic) CGFloat layoutWidth;
@property (nonatomic) NSUInteger layoutStyleVersion;

// A PRIVMSG or USERNOTICE line; nil for anything else. ownLogin marks mentions and the user's own messages.
+ (instancetype)messageFromIRCLine:(TWIRCLine *)line ownLogin:(NSString *)ownLogin;
// A grey line of the system or the app
+ (instancetype)noticeWithText:(NSString *)text;
// A comment of a video's chat replay, as TWGQL delivers it
+ (instancetype)messageFromComment:(NSDictionary *)comment;

- (NSString *)nameForDisplay;                           // display name (login) when they differ (localized names)
- (NSString *)colorKey;                                 // the name's colour, or a stable default colour from the login

@end
