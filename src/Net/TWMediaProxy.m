#import "TWMediaProxy.h"
#import "TWHTTPRequest.h"
#import "TWSettings.h"
#import "TWCommon.h"

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <poll.h>

static const NSUInteger TWProxyMaxFileEntries = 3000;      // (a live stream registers every segment it lists)
static const NSUInteger TWProxyMaxPlaylistEntries = 300;
static const int TWProxyMaxRedirects = 6;

typedef NS_ENUM(NSInteger, TWProxyEntryKind) {
    TWProxyEntryFile = 0,       // /<secret>/u/<id>/<name>: one absolute URL
    TWProxyEntryDirectory,      // /<secret>/d/<id>/<path>: a playlist and whatever it names relative to itself
    TWProxyEntryText,           // /<secret>/t/<id>/<name>: a playlist written by the app
};

@interface TWProxyEntry : NSObject
@property (nonatomic) TWProxyEntryKind kind;
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, copy) NSString *text;
@end

@implementation TWProxyEntry
@end

@interface TWMediaProxy ()
@property (atomic) int listenFD;
@property (atomic) uint16_t port;
@property (atomic, copy) NSString *secret;
@property (atomic) NSUInteger generation;
@property (atomic) BOOL adBreakActive;
@property (atomic) NSTimeInterval lastRequestTime;
@property (nonatomic, strong) NSMutableDictionary *entries;     // id -> TWProxyEntry
@property (nonatomic, strong) NSMutableDictionary *idsByURL;    // "u:"/"d:" + absolute URL -> id
@property (nonatomic, strong) NSMutableArray *fileOrder;        // ids of file entries, oldest first
@property (nonatomic, strong) NSMutableArray *playlistOrder;    // ids of directory and text entries, oldest first
@property (nonatomic) NSUInteger nextId;
@end

static NSString * const TWProxyPlaylistName = @"playlist.m3u8";

static BOOL TWSendAll(int fd, const void *bytes, size_t length)
{
    const char *p = bytes;
    while (length > 0) {
        ssize_t n = send(fd, p, length, 0);
        if (n < 0) { if (errno == EINTR) continue; return NO; }
        if (n == 0) return NO;
        p += n;
        length -= (size_t)n;
    }
    return YES;
}

static BOOL TWSendString(int fd, NSString *s)
{
    NSData *d = [s dataUsingEncoding:NSISOLatin1StringEncoding allowLossyConversion:YES];
    return TWSendAll(fd, d.bytes, d.length);
}

static NSString *TWReasonPhrase(NSInteger status)
{
    switch (status) {
        case 200: return @"OK";
        case 206: return @"Partial Content";
        case 304: return @"Not Modified";
        case 403: return @"Forbidden";
        case 404: return @"Not Found";
        case 416: return @"Range Not Satisfiable";
        case 502: return @"Bad Gateway";
        default: return @"Status";
    }
}

static void TWSendStatus(int fd, NSInteger status)
{
    TWSendString(fd, [NSString stringWithFormat:@"HTTP/1.1 %ld %@\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", (long)status, TWReasonPhrase(status)]);
}

// What the player should take the file for: Twitch's servers call segments and clips "application/octet-stream".
static NSString *TWContentTypeForPath(NSString *path, NSString *upstream)
{
    NSString *ext = [[path pathExtension] lowercaseString];
    if ([ext isEqualToString:@"ts"]) return @"video/MP2T";
    if ([ext isEqualToString:@"mp4"] || [ext isEqualToString:@"m4v"]) return @"video/mp4";
    if ([ext isEqualToString:@"m4s"]) return @"video/iso.segment";
    if ([ext isEqualToString:@"aac"]) return @"audio/aac";
    if ([ext isEqualToString:@"m3u8"]) return @"application/vnd.apple.mpegurl";
    return upstream.length ? upstream : @"application/octet-stream";
}

// The response head for the player: the headers of the file (the length only when the body is passed as it came)
static NSString *TWResponseHead(NSInteger status, NSDictionary *headers, NSString *contentType, BOOL keepLength)
{
    NSMutableString *s = [NSMutableString stringWithFormat:@"HTTP/1.1 %ld %@\r\n", (long)status, TWReasonPhrase(status)];
    if (contentType.length) [s appendFormat:@"Content-Type: %@\r\n", contentType];
    NSArray *names = @[@[@"content-length", @"Content-Length"], @[@"content-range", @"Content-Range"],
                       @[@"accept-ranges", @"Accept-Ranges"], @[@"last-modified", @"Last-Modified"], @[@"etag", @"ETag"]];
    for (NSArray *n in names) {
        NSString *v = headers[n[0]];
        if (!v.length || ([n[0] isEqualToString:@"content-length"] && !keepLength)) continue;
        [s appendFormat:@"%@: %@\r\n", n[1], v];
    }
    [s appendString:@"Connection: close\r\n\r\n"];
    return s;
}

@implementation TWMediaProxy

+ (instancetype)shared
{
    static TWMediaProxy *proxy;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        proxy = [[TWMediaProxy alloc] init];
        [proxy ensureRunning];
    });
    return proxy;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _listenFD = -1;
        _entries = [NSMutableDictionary dictionary];
        _idsByURL = [NSMutableDictionary dictionary];
        _fileOrder = [NSMutableArray array];
        _playlistOrder = [NSMutableArray array];
    }
    return self;
}

#pragma mark - Server

// Whether something still answers on the port (a socket the system reclaimed refuses the connection)
static BOOL TWProxyPortAnswers(uint16_t port)
{
    int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) return NO;
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    BOOL ok = NO;
    int rc = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (rc == 0) {
        ok = YES;
    } else if (errno == EINPROGRESS) {
        struct pollfd pfd = { fd, POLLOUT, 0 };
        if (poll(&pfd, 1, 300) > 0) {
            int soerr = 0;
            socklen_t len = sizeof(soerr);
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &len);
            ok = soerr == 0;
        }
    }
    close(fd);
    return ok;
}

- (BOOL)ensureRunning
{
    @synchronized (self) {
        if (self.listenFD >= 0) {
            if (TWProxyPortAnswers(self.port)) return YES;
            TWLog(@"Media proxy: port %u does not answer any more, starting again", self.port);
            close(self.listenFD);   // (the accept thread of that socket ends with the error this gives it)
            self.listenFD = -1;
        }
        return [self startServer];
    }
}

// (with the lock held)
- (BOOL)startServer
{
    int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) { TWLog(@"Media proxy: no socket (%d)", errno); return NO; }
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = 0;   // (any free port)
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    socklen_t length = sizeof(addr);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 32) != 0 || getsockname(fd, (struct sockaddr *)&addr, &length) != 0) {
        TWLog(@"Media proxy: cannot listen (%d)", errno);
        close(fd);
        return NO;
    }
    NSMutableString *secret = [NSMutableString string];
    for (int i = 0; i < 4; i++) [secret appendFormat:@"%08x", arc4random()];
    self.secret = secret;
    self.port = ntohs(addr.sin_port);
    self.listenFD = fd;
    self.generation = self.generation + 1;
    [self.entries removeAllObjects];
    [self.idsByURL removeAllObjects];
    [self.fileOrder removeAllObjects];
    [self.playlistOrder removeAllObjects];
    [NSThread detachNewThreadSelector:@selector(acceptLoop:) toTarget:self withObject:@(fd)];
    TWLog(@"Media proxy listening on 127.0.0.1:%u", self.port);
    return YES;
}

- (void)acceptLoop:(NSNumber *)socketNumber
{
    @autoreleasepool { [[NSThread currentThread] setName:@"TWMediaProxy"]; }
    int listenFD = socketNumber.intValue;
    int failures = 0;
    for (;;) {
        @autoreleasepool {
            int c = accept(listenFD, NULL, NULL);
            if (c < 0) {
                int err = errno;
                if (err == EINTR) continue;
                if (self.listenFD != listenFD) return;   // closed by ensureRunning: another socket took over
                if (++failures < 6) { usleep(100000); continue; }
                TWLog(@"Media proxy: accept keeps failing (%d), the listening socket is given up", err);
                @synchronized (self) {
                    if (self.listenFD == listenFD) {
                        close(listenFD);
                        self.listenFD = -1;
                    }
                }
                return;
            }
            failures = 0;
            int on = 1;
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
            [NSThread detachNewThreadSelector:@selector(serveConnection:) toTarget:self withObject:@(c)];
        }
    }
}

#pragma mark - Entries

// (with the lock held)
- (NSString *)addEntry:(TWProxyEntry *)entry key:(NSString *)key
{
    NSString *ident = [NSString stringWithFormat:@"%lu", (unsigned long)++self.nextId];
    self.entries[ident] = entry;
    if (key) self.idsByURL[key] = ident;
    NSMutableArray *order = entry.kind == TWProxyEntryFile ? self.fileOrder : self.playlistOrder;
    NSUInteger limit = entry.kind == TWProxyEntryFile ? TWProxyMaxFileEntries : TWProxyMaxPlaylistEntries;
    [order addObject:ident];
    while (order.count > limit) {
        NSString *old = order[0];
        TWProxyEntry *e = self.entries[old];
        if (e.url) {
            [self.idsByURL removeObjectForKey:[(e.kind == TWProxyEntryFile ? @"u:" : @"d:") stringByAppendingString:e.url.absoluteString]];
        }
        [self.entries removeObjectForKey:old];
        [order removeObjectAtIndex:0];
    }
    return ident;
}

- (NSString *)proxyURLForURL:(NSURL *)url
{
    NSString *absolute = url.absoluteString;
    if (!absolute.length || !url.host.length) return nil;
    BOOL playlist = [[url.path lowercaseString] hasSuffix:@".m3u8"];
    @synchronized (self) {
        if (self.listenFD < 0) return nil;
        NSString *key = [(playlist ? @"d:" : @"u:") stringByAppendingString:absolute];
        NSString *ident = self.idsByURL[key];
        if (!ident) {
            TWProxyEntry *entry = [[TWProxyEntry alloc] init];
            entry.kind = playlist ? TWProxyEntryDirectory : TWProxyEntryFile;
            entry.url = url;
            ident = [self addEntry:entry key:key];
        }
        if (playlist) {
            return [NSString stringWithFormat:@"http://127.0.0.1:%u/%@/d/%@/%@", self.port, self.secret, ident, TWProxyPlaylistName];
        }
        // (the extension tells the player the kind of file; the names themselves are hundreds of characters long)
        NSString *ext = [[url.path pathExtension] lowercaseString];
        NSCharacterSet *other = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
        if (!ext.length || ext.length > 5 || [ext rangeOfCharacterFromSet:other].location != NSNotFound) ext = @"bin";
        return [NSString stringWithFormat:@"http://127.0.0.1:%u/%@/u/%@/file.%@", self.port, self.secret, ident, ext];
    }
}

- (NSString *)proxyURLForPlaylistText:(NSString *)text
{
    if (!text.length) return nil;
    @synchronized (self) {
        if (self.listenFD < 0) return nil;
        TWProxyEntry *entry = [[TWProxyEntry alloc] init];
        entry.kind = TWProxyEntryText;
        entry.text = text;
        NSString *ident = [self addEntry:entry key:nil];
        return [NSString stringWithFormat:@"http://127.0.0.1:%u/%@/t/%@/master.m3u8", self.port, self.secret, ident];
    }
}

- (void)resetPlaybackState
{
    self.adBreakActive = NO;
}

#pragma mark - Connections

- (void)serveConnection:(NSNumber *)socketNumber
{
    @autoreleasepool {
        int fd = socketNumber.intValue;
        [[NSThread currentThread] setName:@"TWMediaProxy connection"];
        struct timeval tv = { 30, 0 };
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        NSMutableData *buffer = [NSMutableData data];
        NSData *blank = [@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
        NSRange end = NSMakeRange(NSNotFound, 0);
        char chunk[4096];
        while (buffer.length < 32768) {
            ssize_t n = recv(fd, chunk, sizeof(chunk), 0);
            if (n <= 0) break;
            [buffer appendBytes:chunk length:(NSUInteger)n];
            end = [buffer rangeOfData:blank options:0 range:NSMakeRange(0, buffer.length)];
            if (end.location != NSNotFound) break;
        }
        if (end.location == NSNotFound) { close(fd); return; }
        NSString *head = [[NSString alloc] initWithData:[buffer subdataWithRange:NSMakeRange(0, end.location)] encoding:NSISOLatin1StringEncoding] ?: @"";
        NSArray *lines = [head componentsSeparatedByString:@"\r\n"];
        NSArray *requestLine = [lines.firstObject componentsSeparatedByString:@" "];
        NSString *method = requestLine.count >= 2 ? [requestLine[0] uppercaseString] : nil;
        NSMutableDictionary *headers = [NSMutableDictionary dictionary];
        for (NSUInteger i = 1; i < lines.count; i++) {
            NSRange colon = [lines[i] rangeOfString:@":"];
            if (colon.location == NSNotFound) continue;
            headers[[[lines[i] substringToIndex:colon.location] lowercaseString]] =
                [[lines[i] substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }
        if (requestLine.count < 2 || !([method isEqualToString:@"GET"] || [method isEqualToString:@"HEAD"])) {
            TWSendStatus(fd, 404);
            close(fd);
            return;
        }
        self.lastRequestTime = [NSDate timeIntervalSinceReferenceDate];
        [self serveTarget:requestLine[1] method:method headers:headers to:fd];
        close(fd);
    }
}

// "/<secret>/<kind>/<id>/<rest>"
- (void)serveTarget:(NSString *)target method:(NSString *)method headers:(NSDictionary *)headers to:(int)fd
{
    NSArray *parts = [target componentsSeparatedByString:@"/"];
    if (parts.count < 5 || ![parts[1] isEqualToString:self.secret]) { TWSendStatus(fd, 404); return; }
    NSString *kind = parts[2];
    NSString *rest = [[parts subarrayWithRange:NSMakeRange(4, parts.count - 4)] componentsJoinedByString:@"/"];
    TWProxyEntry *entry;
    @synchronized (self) { entry = self.entries[parts[3]]; }
    if (!entry) { TWSendStatus(fd, 404); return; }

    if (entry.kind == TWProxyEntryText && [kind isEqualToString:@"t"]) {
        [self sendPlaylist:entry.text method:method to:fd];
        return;
    }
    if (entry.kind == TWProxyEntryFile && [kind isEqualToString:@"u"]) {
        [self relayURL:entry.url method:method headers:headers viaDirectory:NO to:fd];
        return;
    }
    if (entry.kind == TWProxyEntryDirectory && [kind isEqualToString:@"d"]) {
        NSURL *url = entry.url;
        NSString *name = rest;
        NSRange query = [name rangeOfString:@"?"];
        if (query.location != NSNotFound) name = [name substringToIndex:query.location];
        if (![name isEqualToString:TWProxyPlaylistName]) {
            // something the playlist names relative to itself
            if (!rest.length || [rest hasPrefix:@"/"] || [rest rangeOfString:@".."].location != NSNotFound) { TWSendStatus(fd, 404); return; }
            url = [[NSURL URLWithString:rest relativeToURL:entry.url] absoluteURL];
            if (!url.host.length) { TWSendStatus(fd, 404); return; }
        }
        [self relayURL:url method:method headers:headers viaDirectory:YES to:fd];
        return;
    }
    TWSendStatus(fd, 404);
}

- (void)sendPlaylist:(NSString *)text method:(NSString *)method to:(int)fd
{
    NSData *body = [text dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    NSString *head = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: %lu\r\n"
                                                 "Cache-Control: no-cache\r\nConnection: close\r\n\r\n", (unsigned long)body.length];
    if (TWSendString(fd, head) && ![method isEqualToString:@"HEAD"]) TWSendAll(fd, body.bytes, body.length);
}

// One request of the player, through the app's network layer, on this thread: redirects followed here, the body
// passed on as it comes (a player that lets go ends the request), a playlist rewritten first.
- (void)relayURL:(NSURL *)startURL method:(NSString *)method headers:(NSDictionary *)playerHeaders viaDirectory:(BOOL)viaDirectory to:(int)fd
{
    NSURL *url = startURL;
    for (int hop = 0; hop < TWProxyMaxRedirects; hop++) {
        BOOL playlistByName = [[url.path lowercaseString] hasSuffix:@".m3u8"];
        NSMutableDictionary *h = [NSMutableDictionary dictionary];
        h[@"Accept"] = @"*/*";
        if (!playlistByName) {
            if (playerHeaders[@"range"]) h[@"Range"] = playerHeaders[@"range"];
            if (playerHeaders[@"if-range"]) h[@"If-Range"] = playerHeaders[@"if-range"];
        }
        TWHTTPRequest *r = [[TWHTTPRequest alloc] initWithMethod:method URL:url];
        r.headers = h;
        r.verifyTLS = [TWSettings verifyTLS];
        r.highPriority = YES;   // (never behind image downloads)
        r.noCompression = !playlistByName;
        r.connectTimeout = 15;
        r.readTimeout = 30;
        __block NSURL *redirect = nil;
        __block BOOL playlist = NO, headSent = NO, broken = NO;
        __block NSInteger playlistStatus = 200;
        NSMutableData *collected = [NSMutableData data];
        NSURL *current = url;
        __weak TWHTTPRequest *weakRequest = r;
        r.onHeaders = ^(NSInteger status, NSDictionary *hdrs) {
            NSString *location = hdrs[@"location"];
            if (status >= 300 && status < 400 && status != 304 && location.length) {
                redirect = [[NSURL URLWithString:location relativeToURL:current] absoluteURL];
                return;
            }
            NSString *type = [hdrs[@"content-type"] lowercaseString] ?: @"";
            playlist = status < 300 && (playlistByName || [type rangeOfString:@"mpegurl"].location != NSNotFound);
            if (playlist) { playlistStatus = status; return; }
            NSString *encoding = [hdrs[@"content-encoding"] lowercaseString] ?: @"";
            BOOL keepLength = !encoding.length || [encoding isEqualToString:@"identity"];
            headSent = YES;
            NSString *contentType = status < 300 ? TWContentTypeForPath(current.path, hdrs[@"content-type"]) : hdrs[@"content-type"];
            if (!TWSendString(fd, TWResponseHead(status, hdrs, contentType, keepLength))) { broken = YES; [weakRequest cancel]; }
        };
        r.onData = ^(NSData *data) {
            if (redirect || broken) return;
            if (playlist) { [collected appendData:data]; return; }
            if (!TWSendAll(fd, data.bytes, data.length)) { broken = YES; [weakRequest cancel]; }
        };
        __block NSError *failure = nil;
        r.onComplete = ^(NSError *error) { failure = error; };
        [r runSynchronously];
        if (broken) return;
        if (redirect.host.length) { url = redirect; continue; }
        if (playlist) {
            if (failure) { TWSendStatus(fd, 502); return; }
            NSString *text = [[NSString alloc] initWithData:collected encoding:NSUTF8StringEncoding] ?: [[NSString alloc] initWithData:collected encoding:NSISOLatin1StringEncoding] ?: @"";
            [self sendPlaylist:[self rewritePlaylist:text baseURL:url viaDirectory:viaDirectory] method:method to:fd];
            return;
        }
        if (!headSent) {
            if (failure) TWLog(@"Media proxy: %@ failed: %@", url.host, failure.localizedDescription);
            TWSendStatus(fd, 502);
        }
        return;
    }
    TWSendStatus(fd, 502);
}

#pragma mark - Playlists

// A playlist for the player: URIs through the proxy, and only the tags the HLS of 2012 knows. Twitch adds its own
// (#EXT-X-TWITCH-..., #EXT-X-DATERANGE with session data and URLs of hundreds of characters) to every reload.
- (NSString *)rewritePlaylist:(NSString *)text baseURL:(NSURL *)base viaDirectory:(BOOL)viaDirectory
{
    static NSRegularExpression *uriAttribute;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        uriAttribute = [NSRegularExpression regularExpressionWithPattern:@"URI=\"([^\"]+)\"" options:0 error:NULL];
    });
    NSMutableArray *out = [NSMutableArray array];
    BOOL media = NO, ad = NO;
    for (NSString *line in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!t.length) continue;
        if ([t hasPrefix:@"#"]) {
            if ([t hasPrefix:@"#EXT-X-DATERANGE"]) {
                if ([t rangeOfString:@"stitched-ad"].location != NSNotFound) ad = YES;
                continue;
            }
            if ([t hasPrefix:@"#EXT-X-TWITCH-"] || [t hasPrefix:@"#EXT-X-PROGRAM-DATE-TIME"] || [t hasPrefix:@"#EXT-X-SESSION-"]) continue;
            if ([t hasPrefix:@"#EXTINF"]) media = YES;
            NSArray *found = [uriAttribute matchesInString:t options:0 range:NSMakeRange(0, t.length)];
            if (!found.count) { [out addObject:t]; continue; }
            NSMutableString *m = [t mutableCopy];
            for (NSTextCheckingResult *r in [found reverseObjectEnumerator]) {
                NSURL *abs = [[NSURL URLWithString:[t substringWithRange:[r rangeAtIndex:1]] relativeToURL:base] absoluteURL];
                NSString *proxied = abs ? [self proxyURLForURL:abs] : nil;
                if (proxied) [m replaceCharactersInRange:[r rangeAtIndex:1] withString:proxied];
            }
            [out addObject:m];
            continue;
        }
        // a URI line: what the directory entry reaches by itself stays as it is (thousands of lines in a long video)
        BOOL hasScheme = [t rangeOfString:@"://"].location != NSNotFound;
        if (viaDirectory && !hasScheme && ![t hasPrefix:@"/"] && [t rangeOfString:@".."].location == NSNotFound) {
            [out addObject:t];
            continue;
        }
        NSURL *abs = [[NSURL URLWithString:t relativeToURL:base] absoluteURL];
        [out addObject:(abs ? [self proxyURLForURL:abs] : nil) ?: t];
    }
    if (media) self.adBreakActive = ad;
    return [[out componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
}

@end
