#import "TWIRC.h"
#import "TWTLSSocket.h"
#import "TWSettings.h"
#import "TWCommon.h"

#include <poll.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>

static NSString * const TWIRCHost = @"irc.chat.twitch.tv";
static const int TWIRCPort = 6697;
static const NSTimeInterval TWIRCIdlePing = 300;        // our own PING when nothing came for this long
static const NSTimeInterval TWIRCIdleGiveUp = 400;      // ...and a new connection when still nothing
static const NSTimeInterval TWIRCBatchDelay = 0.15;     // messages are handed over in batches this often
static const NSUInteger TWIRCBatchMax = 40;

@interface TWIRC ()
@property (nonatomic, copy) NSString *channel;
@property (nonatomic) TWIRCState state;
@property (nonatomic, strong) NSThread *thread;
@property (atomic, strong) TWTLSSocket *socket;         // used from the IRC thread; -cancel reaches it from the main thread
@property (nonatomic) NSUInteger generation;            // bumped by -disconnect: the thread of an old generation ends
@property (nonatomic) NSInteger attempts;
@end

@implementation TWIRC {
    int _wakePipe[2];
    NSMutableArray *_outgoing;                          // lines to send, guarded by @synchronized (self)
}

- (instancetype)initWithChannel:(NSString *)login
{
    self = [super init];
    if (self) {
        _channel = [login lowercaseString];
        _outgoing = [NSMutableArray array];
        _wakePipe[0] = _wakePipe[1] = -1;
    }
    return self;
}

- (void)dealloc
{
    [self closeWakePipe];
}

- (void)closeWakePipe
{
    if (_wakePipe[0] >= 0) close(_wakePipe[0]);
    if (_wakePipe[1] >= 0) close(_wakePipe[1]);
    _wakePipe[0] = _wakePipe[1] = -1;
}

#pragma mark - Control (main thread)

- (void)connect
{
    if (self.thread) return;
    if (!self.channel.length) return;
    self.generation++;
    self.attempts = 0;
    [self setStateOnMain:TWIRCStateConnecting];
    NSUInteger generation = self.generation;
    self.thread = [[NSThread alloc] initWithTarget:self selector:@selector(threadMain:) object:@(generation)];
    self.thread.name = @"TWIRC";
    [self.thread start];
}

- (void)disconnect
{
    if (!self.thread) return;
    self.generation++;
    [self.socket cancel];
    [self wake];
    self.thread = nil;
    [self setStateOnMain:TWIRCStateDisconnected];
}

- (void)queueLine:(NSString *)line
{
    @synchronized (self) { [_outgoing addObject:line]; }
    [self wake];
}

- (void)wake
{
    int fd = _wakePipe[1];
    if (fd >= 0) { char c = 1; write(fd, &c, 1); }
}

- (void)setStateOnMain:(TWIRCState)state
{
    TWMain(^{
        if (self.state == state) return;
        self.state = state;
        [self.delegate irc:self didChangeState:state];
    });
}

- (void)deliver:(NSArray *)messages
{
    if (!messages.count) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.state == TWIRCStateDisconnected) return;
        [self.delegate irc:self didReceiveMessages:messages];
    });
}

#pragma mark - Thread

- (void)threadMain:(NSNumber *)generationNumber
{
    @autoreleasepool {
        NSUInteger generation = generationNumber.unsignedIntegerValue;
        if (pipe(_wakePipe) != 0) {
            _wakePipe[0] = _wakePipe[1] = -1;
        } else {
            // (the drain below must never block: whatever is in the pipe is read, then the read says "nothing")
            fcntl(_wakePipe[0], F_SETFL, fcntl(_wakePipe[0], F_GETFL, 0) | O_NONBLOCK);
        }
        while (generation == self.generation) {
            @autoreleasepool {
                NSError *error = nil;
                BOOL connected = [self runConnectionGeneration:generation error:&error];
                if (generation != self.generation) break;
                // the connection ended: wait a while and try again (longer each time, up to a minute)
                self.attempts = connected ? 1 : self.attempts + 1;
                NSTimeInterval delay = MIN(2.0 * (1 << MIN(self.attempts, (NSInteger)5)), 60.0);
                if (error) TWLog(@"Chat %@: %@, reconnecting in %.0f s", self.channel, error.localizedDescription, delay);
                [self setStateOnMain:TWIRCStateReconnecting];
                [self deliver:@[ [TWChatMessage noticeWithText:L(@"Connection to the chat lost. Reconnecting…")] ]];
                NSDate *until = [NSDate dateWithTimeIntervalSinceNow:delay];
                while (generation == self.generation && [until timeIntervalSinceNow] > 0) usleep(250000);
            }
        }
        [self closeWakePipe];
    }
}

// One connection, until it breaks. Returns YES when the channel was joined (a real connection, not a failure).
- (BOOL)runConnectionGeneration:(NSUInteger)generation error:(NSError **)error
{
    TWTLSSocket *socket = [[TWTLSSocket alloc] init];
    self.socket = socket;
    if (![socket connectToHost:TWIRCHost port:TWIRCPort verify:[TWSettings verifyTLS] connectTimeoutMs:15000 readTimeoutMs:20000 error:error]) {
        [socket close];
        self.socket = nil;
        return NO;
    }
    // a visitor's login: justinfan<number> reads any channel without an account
    NSString *nick = [NSString stringWithFormat:@"justinfan%u", 10000 + arc4random_uniform(80000)];
    NSString *hello = [NSString stringWithFormat:@"CAP REQ :twitch.tv/tags twitch.tv/commands\r\nPASS SCHMOOPIIE\r\nNICK %@\r\nJOIN #%@\r\n", nick, self.channel];
    if (![socket writeData:[hello dataUsingEncoding:NSUTF8StringEncoding] error:error]) {
        [socket close];
        self.socket = nil;
        return NO;
    }
    @synchronized (self) { [_outgoing removeAllObjects]; }

    NSMutableData *buffer = [NSMutableData data];
    NSMutableArray *batch = [NSMutableArray array];
    NSTimeInterval batchStarted = 0;
    NSTimeInterval lastReceived = [NSDate timeIntervalSinceReferenceDate];
    BOOL joined = NO, pinged = NO, ok = YES;
    unsigned char chunk[16384];
    [socket setReadTimeoutMs:20000];

    while (ok && generation == self.generation) {
        @autoreleasepool {
            NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
            // hand over what has gathered
            if (batch.count && (batch.count >= TWIRCBatchMax || now - batchStarted >= TWIRCBatchDelay)) {
                [self deliver:[batch copy]];
                [batch removeAllObjects];
            }
            // anything to send?
            NSArray *pending = nil;
            @synchronized (self) {
                if (_outgoing.count) { pending = [_outgoing copy]; [_outgoing removeAllObjects]; }
            }
            for (NSString *line in pending) {
                if (![socket writeData:[[line stringByAppendingString:@"\r\n"] dataUsingEncoding:NSUTF8StringEncoding] error:error]) { ok = NO; break; }
            }
            if (!ok) break;
            // silence from the server: our own ping, then a new connection
            if (now - lastReceived > TWIRCIdleGiveUp) {
                if (error) *error = TWMakeError(TWErrorTimeout, @"No data from the chat server");
                ok = NO;
                break;
            }
            if (now - lastReceived > TWIRCIdlePing && !pinged) {
                pinged = YES;
                if (![socket writeData:[@"PING :keepalive\r\n" dataUsingEncoding:NSUTF8StringEncoding] error:error]) { ok = NO; break; }
            }
            // wait for data, a wake-up, or the batch deadline
            BOOL readable = [socket hasBufferedData];
            if (!readable) {
                struct pollfd fds[2] = { { socket.fileDescriptor, POLLIN, 0 }, { _wakePipe[0], POLLIN, 0 } };
                int timeout = batch.count ? (int)MAX(10.0, (TWIRCBatchDelay - (now - batchStarted)) * 1000) : 1000;
                int r = poll(fds, _wakePipe[0] >= 0 ? 2 : 1, timeout);
                if (r < 0) {
                    if (errno == EINTR) continue;
                    if (error) *error = TWMakeError(TWErrorConnectionLost, @"poll failed");
                    ok = NO;
                    break;
                }
                if (r == 0) continue;
                if (_wakePipe[0] >= 0 && (fds[1].revents & POLLIN)) {
                    char drain[64];
                    while (read(_wakePipe[0], drain, sizeof(drain)) > 0) {}
                    continue;
                }
                if (fds[0].revents & (POLLERR | POLLHUP | POLLNVAL)) {
                    if (error) *error = TWMakeError(TWErrorConnectionLost, L(@"Connection lost."));
                    ok = NO;
                    break;
                }
                if (!(fds[0].revents & POLLIN)) continue;
            }
            NSError *readError = nil;
            NSInteger n = [socket readIntoBuffer:chunk maxLength:sizeof(chunk) error:&readError];
            if (n == 0) {
                if (error) *error = TWMakeError(TWErrorConnectionLost, L(@"The chat server closed the connection."));
                ok = NO;
                break;
            }
            if (n < 0) {
                if (readError.code == TWErrorTimeout) continue;   // (a record that did not complete in time: the poll loop goes on)
                if (error) *error = readError;
                ok = NO;
                break;
            }
            lastReceived = [NSDate timeIntervalSinceReferenceDate];
            pinged = NO;
            [buffer appendBytes:chunk length:(NSUInteger)n];
            // complete lines
            const uint8_t *bytes = buffer.bytes;
            NSUInteger start = 0, length = buffer.length;
            for (NSUInteger i = 0; i < length; i++) {
                if (bytes[i] != '\n') continue;
                NSUInteger end = (i > start && bytes[i - 1] == '\r') ? i - 1 : i;
                NSString *line = [[NSString alloc] initWithBytes:bytes + start length:end - start encoding:NSUTF8StringEncoding]
                    ?: [[NSString alloc] initWithBytes:bytes + start length:end - start encoding:NSISOLatin1StringEncoding];
                start = i + 1;
                if (!line.length) continue;
                if ([line hasPrefix:@"PING"]) {
                    NSString *pong = [@"PONG" stringByAppendingString:[line substringFromIndex:4]];
                    if (![socket writeData:[[pong stringByAppendingString:@"\r\n"] dataUsingEncoding:NSUTF8StringEncoding] error:error]) { ok = NO; break; }
                    continue;
                }
                TWIRCLine *parsed = [TWIRCLine lineWithString:line];
                if (!parsed) continue;
                NSString *command = parsed.command;
                if ([command isEqualToString:@"PRIVMSG"] || [command isEqualToString:@"USERNOTICE"]) {
                    TWChatMessage *m = [TWChatMessage messageFromIRCLine:parsed ownLogin:self.ownLogin];
                    if (m) {
                        if (!batch.count) batchStarted = [NSDate timeIntervalSinceReferenceDate];
                        [batch addObject:m];
                    }
                } else if ([command isEqualToString:@"JOIN"] && !joined && [parsed.nick isEqualToString:nick]) {
                    joined = YES;
                    self.attempts = 0;
                    [self setStateOnMain:TWIRCStateConnected];
                } else if ([command isEqualToString:@"NOTICE"]) {
                    NSString *text = parsed.trailing;
                    if ([text rangeOfString:@"Login authentication failed"].location != NSNotFound || [text rangeOfString:@"Improperly formatted auth"].location != NSNotFound) {
                        if (error) *error = TWMakeError(TWErrorAuth, text);
                        ok = NO;
                        break;
                    }
                    if (text.length) {
                        if (!batch.count) batchStarted = [NSDate timeIntervalSinceReferenceDate];
                        [batch addObject:[TWChatMessage noticeWithText:text]];
                    }
                } else if ([command isEqualToString:@"ROOMSTATE"]) {
                    [self handleRoomState:parsed.tags];
                } else if ([command isEqualToString:@"CLEARCHAT"]) {
                    NSString *target = [parsed.trailing lowercaseString];
                    NSInteger seconds = [parsed.tags[@"ban-duration"] integerValue];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if ([self.delegate respondsToSelector:@selector(irc:didClearMessagesOfUser:seconds:)]) {
                            [self.delegate irc:self didClearMessagesOfUser:target.length ? target : nil seconds:seconds];
                        }
                    });
                } else if ([command isEqualToString:@"CLEARMSG"]) {
                    NSString *target = parsed.tags[@"target-msg-id"];
                    if (target.length) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if ([self.delegate respondsToSelector:@selector(irc:didDeleteMessageWithId:)]) [self.delegate irc:self didDeleteMessageWithId:target];
                        });
                    }
                } else if ([command isEqualToString:@"RECONNECT"]) {
                    if (error) *error = TWMakeError(TWErrorConnectionLost, @"The server asked for a new connection");
                    ok = NO;
                    break;
                }
            }
            if (start > 0) [buffer replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
            if (buffer.length > 1024 * 1024) [buffer setLength:0];   // (a line that never ends: not IRC)
        }
    }
    if (batch.count) [self deliver:[batch copy]];
    [socket close];
    self.socket = nil;
    return joined;
}

- (void)handleRoomState:(NSDictionary *)tags
{
    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    if (tags[@"emote-only"]) state[@"emoteOnly"] = @([tags[@"emote-only"] isEqualToString:@"1"]);
    if (tags[@"subs-only"]) state[@"subscribersOnly"] = @([tags[@"subs-only"] isEqualToString:@"1"]);
    if (tags[@"r9k"]) state[@"uniqueOnly"] = @([tags[@"r9k"] isEqualToString:@"1"]);
    if (tags[@"followers-only"]) state[@"followersOnly"] = @([tags[@"followers-only"] integerValue]);
    if (tags[@"slow"]) state[@"slow"] = @([tags[@"slow"] integerValue]);
    if (!state.count) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(irc:didUpdateRoomState:)]) [self.delegate irc:self didUpdateRoomState:state];
    });
}

@end
