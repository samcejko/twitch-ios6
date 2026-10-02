#import "TWConnectionPool.h"
#import "TWTLSSocket.h"
#import "TWCommon.h"

static const NSTimeInterval TWIdleTimeout = 25;     // most servers drop idle connections after 5 to 60 s
static const NSUInteger TWMaxIdlePerKey = 6;
static const NSUInteger TWMaxIdleTotal = 24;

@interface TWPooledConnection : NSObject
@property (nonatomic, strong) TWTLSSocket *socket;
@property (nonatomic) NSTimeInterval lastUsed;
@end

@implementation TWPooledConnection
@end

@implementation TWConnectionPool {
    NSMutableDictionary *_idle;     // key -> NSMutableArray<TWPooledConnection>
    NSUInteger _count;
    NSUInteger _reuses;
}

+ (instancetype)shared
{
    static TWConnectionPool *pool;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ pool = [[TWConnectionPool alloc] init]; });
    return pool;
}

- (instancetype)init
{
    self = [super init];
    if (self) _idle = [NSMutableDictionary dictionary];
    return self;
}

// Must be called with the lock held. Moves expired connections into `dead`.
- (void)pruneLocked:(NSMutableArray *)dead
{
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSMutableArray *emptyKeys = [NSMutableArray array];
    for (NSString *key in _idle) {
        NSMutableArray *list = _idle[key];
        for (NSInteger i = (NSInteger)list.count - 1; i >= 0; i--) {
            TWPooledConnection *c = list[(NSUInteger)i];
            if (now - c.lastUsed > TWIdleTimeout) {
                [dead addObject:c.socket];
                [list removeObjectAtIndex:(NSUInteger)i];
                _count--;
            }
        }
        if (!list.count) [emptyKeys addObject:key];
    }
    [_idle removeObjectsForKeys:emptyKeys];
}

- (TWTLSSocket *)checkoutSocketForKey:(NSString *)key
{
    if (!key) return nil;
    NSMutableArray *dead = [NSMutableArray array];
    TWTLSSocket *result = nil;
    @synchronized (self) {
        [self pruneLocked:dead];
        NSMutableArray *list = _idle[key];
        while (list.count && !result) {
            TWPooledConnection *c = [list lastObject];
            [list removeLastObject];
            _count--;
            if ([c.socket isLikelyAlive]) result = c.socket;
            else [dead addObject:c.socket];
        }
        if (result) _reuses++;
    }
    for (TWTLSSocket *s in dead) [s close];
    return result;
}

- (void)checkinSocket:(TWTLSSocket *)socket forKey:(NSString *)key
{
    if (!socket || !key) return;
    NSMutableArray *dead = [NSMutableArray array];
    @synchronized (self) {
        [self pruneLocked:dead];
        NSMutableArray *list = _idle[key];
        if (!list) {
            list = [NSMutableArray array];
            _idle[key] = list;
        }
        if (list.count >= TWMaxIdlePerKey || _count >= TWMaxIdleTotal) {
            [dead addObject:socket];
        } else {
            TWPooledConnection *c = [[TWPooledConnection alloc] init];
            c.socket = socket;
            c.lastUsed = [NSDate timeIntervalSinceReferenceDate];
            [list addObject:c];
            _count++;
        }
    }
    for (TWTLSSocket *s in dead) [s close];
}

- (void)drain
{
    NSMutableArray *dead = [NSMutableArray array];
    @synchronized (self) {
        for (NSString *key in _idle) {
            for (TWPooledConnection *c in _idle[key]) [dead addObject:c.socket];
        }
        [_idle removeAllObjects];
        _count = 0;
    }
    for (TWTLSSocket *s in dead) [s close];
    if (dead.count) TWLog(@"Connection pool drained (%lu closed)", (unsigned long)dead.count);
}

- (NSUInteger)idleCount
{
    @synchronized (self) { return _count; }
}

- (NSUInteger)reuseCount
{
    @synchronized (self) { return _reuses; }
}

@end
