#import "TWImageLoader.h"
#import "TWHTTP.h"
#import "TWUtils.h"
#import "TWCommon.h"
#import <ImageIO/ImageIO.h>

NSString * const TWImageDidLoadNotification = @"TWImageDidLoadNotification";

static const NSUInteger TWMaxImageFileBytes = 6 * 1024 * 1024;
static const NSInteger TWMaxConcurrentLoads = 4;
static const NSTimeInterval TWFailureRetryInterval = 45;          // a failed image is asked for again after this
static const NSTimeInterval TWDiskMaxAge = 10 * 86400.0;
static const unsigned long long TWDiskMaxBytes = 120ULL * 1024 * 1024;
static const NSUInteger TWMaxAnimationEntries = 600;              // frames after spreading unequal delays

#pragma mark - Decoding (any thread)

// A bitmap copy of the image: decoded now, on this thread, instead of at the first draw on the main thread.
static CGImageRef TWCreateDecodedImage(CGImageRef source)
{
    size_t w = CGImageGetWidth(source), h = CGImageGetHeight(source);
    if (w == 0 || h == 0 || w > 8192 || h > 8192) return NULL;
    CGImageAlphaInfo alpha = CGImageGetAlphaInfo(source);
    BOOL opaque = alpha == kCGImageAlphaNone || alpha == kCGImageAlphaNoneSkipFirst || alpha == kCGImageAlphaNoneSkipLast;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo info = (CGBitmapInfo)(kCGBitmapByteOrder32Little | (opaque ? kCGImageAlphaNoneSkipFirst : kCGImageAlphaPremultipliedFirst));
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, space, info);
    CGColorSpaceRelease(space);
    if (!ctx) return NULL;
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), source);
    CGImageRef result = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return result;
}

static NSInteger TWGCD(NSInteger a, NSInteger b)
{
    while (b != 0) { NSInteger t = a % b; a = b; b = t; }
    return a;
}

// Every frame of a GIF as one animated image; nil when the frames would take more than `budget` bytes.
static UIImage *TWAnimatedImage(CGImageSourceRef source, size_t count, NSUInteger budget, NSUInteger *costOut)
{
    NSMutableArray *frames = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray *delays = [NSMutableArray arrayWithCapacity:count];   // hundredths of a second
    NSUInteger bytes = 0;
    for (size_t i = 0; i < count; i++) {
        @autoreleasepool {
            CGImageRef raw = CGImageSourceCreateImageAtIndex(source, i, NULL);
            if (!raw) continue;
            CGImageRef decoded = TWCreateDecodedImage(raw);
            CGImageRelease(raw);
            if (!decoded) continue;
            NSUInteger frameBytes = CGImageGetBytesPerRow(decoded) * CGImageGetHeight(decoded);
            bytes += frameBytes;
            if (i == 0 && frameBytes * count > budget) {
                CGImageRelease(decoded);
                return nil;
            }
            [frames addObject:[UIImage imageWithCGImage:decoded scale:1.0 orientation:UIImageOrientationUp]];
            CGImageRelease(decoded);
            double delay = 0.1;
            CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(source, i, NULL);
            if (props) {
                NSDictionary *gif = TWDict(((__bridge NSDictionary *)props)[(__bridge NSString *)kCGImagePropertyGIFDictionary]);
                NSNumber *n = gif[(__bridge NSString *)kCGImagePropertyGIFUnclampedDelayTime];
                if (![n isKindOfClass:[NSNumber class]] || n.doubleValue <= 0) n = gif[(__bridge NSString *)kCGImagePropertyGIFDelayTime];
                if ([n isKindOfClass:[NSNumber class]] && n.doubleValue > 0) delay = n.doubleValue;
                CFRelease(props);
            }
            if (delay < 0.011) delay = 0.1;   // (as browsers do: "as fast as possible" means a tenth of a second)
            [delays addObject:@((NSInteger)lrint(delay * 100.0))];
        }
    }
    if (frames.count < 2) return nil;
    NSInteger gcd = 0, total = 0;
    for (NSNumber *d in delays) {
        gcd = gcd == 0 ? d.integerValue : TWGCD(gcd, d.integerValue);
        total += d.integerValue;
    }
    if (gcd < 1) gcd = 1;
    NSArray *sequence = frames;
    if ((NSUInteger)(total / gcd) <= TWMaxAnimationEntries && (NSUInteger)(total / gcd) != frames.count) {
        // UIImage shows every entry for the same time: a frame that stays longer is entered several times
        NSMutableArray *spread = [NSMutableArray arrayWithCapacity:(NSUInteger)(total / gcd)];
        for (NSUInteger i = 0; i < frames.count; i++) {
            NSInteger repeat = [delays[i] integerValue] / gcd;
            for (NSInteger k = 0; k < repeat; k++) [spread addObject:frames[i]];
        }
        if (spread.count) sequence = spread;
    }
    if (costOut) *costOut = bytes;
    return [UIImage animatedImageWithImages:sequence duration:total / 100.0];
}

static UIImage *TWDecodeImage(NSData *data, CGFloat maxPixels, BOOL animate, NSUInteger animationBudget, NSUInteger *costOut)
{
    if (!data.length) return nil;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return nil;
    UIImage *result = nil;
    size_t count = CGImageSourceGetCount(source);
    if (count > 1 && animate) result = TWAnimatedImage(source, count, animationBudget, costOut);
    if (!result && count > 0) {
        CGFloat limit = maxPixels > 0 ? maxPixels : 1024;
        CGImageRef image = NULL;
        CGImageRef raw = CGImageSourceCreateImageAtIndex(source, 0, NULL);
        if (raw && (CGFloat)MAX(CGImageGetWidth(raw), CGImageGetHeight(raw)) > limit) {
            NSDictionary *options = @{
                (__bridge id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                (__bridge id)kCGImageSourceThumbnailMaxPixelSize: @(limit),
                (__bridge id)kCGImageSourceCreateThumbnailWithTransform: @YES,
            };
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
        } else if (raw) {
            image = TWCreateDecodedImage(raw);
            if (!image) image = CGImageRetain(raw);
        }
        if (raw) CGImageRelease(raw);
        if (image) {
            if (costOut) *costOut = CGImageGetBytesPerRow(image) * CGImageGetHeight(image);
            result = [UIImage imageWithCGImage:image scale:1.0 orientation:UIImageOrientationUp];
            CGImageRelease(image);
        }
    }
    CFRelease(source);
    return result;
}

#pragma mark - Bookkeeping

@interface TWImageToken : NSObject
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) void (^completion)(UIImage *image);
@end

@implementation TWImageToken
@end

@interface TWImageJob : NSObject
@property (nonatomic, copy) NSString *url;
@property (nonatomic) CGFloat maxPixels;
@property (nonatomic, strong) NSMutableArray *tokens;
@property (nonatomic) BOOL notify;      // somebody asked through -imageForURL:
@property (nonatomic) BOOL started;
@end

@implementation TWImageJob
@end

@interface TWImageLoader ()
@property (nonatomic, strong) NSCache *memory;
@property (nonatomic, strong) NSMutableDictionary *jobs;      // url -> TWImageJob
@property (nonatomic, strong) NSMutableArray *queue;          // jobs not started yet, the newest last
@property (nonatomic, strong) NSMutableDictionary *failed;    // url -> NSDate
@property (nonatomic) NSInteger running;
@property (nonatomic, strong) dispatch_queue_t workQueue;
@property (nonatomic, copy) NSString *directory;
@end

@implementation TWImageLoader

+ (instancetype)shared
{
    static TWImageLoader *loader;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ loader = [[TWImageLoader alloc] init]; });
    return loader;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _memory = [[NSCache alloc] init];
        _memory.totalCostLimit = ([TWUtils physicalMemoryMB] >= 400 ? 24 : 10) * 1024 * 1024;
        _jobs = [NSMutableDictionary dictionary];
        _queue = [NSMutableArray array];
        _failed = [NSMutableDictionary dictionary];
        _animationAllowed = YES;
        _workQueue = dispatch_queue_create("com.samcejko.twitcher.images", DISPATCH_QUEUE_CONCURRENT);
        _directory = [[TWUtils cachesPath] stringByAppendingPathComponent:@"images"];
        [[NSFileManager defaultManager] createDirectoryAtPath:_directory withIntermediateDirectories:YES attributes:nil error:NULL];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(clearMemory)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    }
    return self;
}

- (NSString *)pathForURL:(NSString *)url
{
    return [self.directory stringByAppendingPathComponent:[TWUtils sha1:url]];
}

- (NSUInteger)animationBudget
{
    return ([TWUtils physicalMemoryMB] >= 400 ? 4 : 2) * 1024 * 1024;
}

#pragma mark - Lookup

- (UIImage *)cachedImageForURL:(NSString *)url
{
    return url.length ? [self.memory objectForKey:url] : nil;
}

- (BOOL)hasFailed:(NSString *)url
{
    NSDate *when = url.length ? self.failed[url] : nil;
    if (!when) return NO;
    if (-[when timeIntervalSinceNow] > TWFailureRetryInterval) {
        [self.failed removeObjectForKey:url];
        return NO;
    }
    return YES;
}

- (TWImageJob *)jobForURL:(NSString *)url maxPixels:(CGFloat)maxPixels
{
    TWImageJob *job = self.jobs[url];
    if (!job) {
        job = [[TWImageJob alloc] init];
        job.url = url;
        job.maxPixels = maxPixels;
        job.tokens = [NSMutableArray array];
        self.jobs[url] = job;
        [self.queue addObject:job];
    } else if (!job.started) {
        // asked for again: to the front of the line
        [self.queue removeObjectIdenticalTo:job];
        [self.queue addObject:job];
    }
    return job;
}

- (UIImage *)imageForURL:(NSString *)url
{
    if (!url.length) return nil;
    UIImage *image = [self.memory objectForKey:url];
    if (image) return image;
    if ([self hasFailed:url]) return nil;
    TWImageJob *job = [self jobForURL:url maxPixels:0];
    job.notify = YES;
    [self pump];
    return nil;
}

- (id)loadImage:(NSString *)url maxPixels:(CGFloat)maxPixels completion:(void (^)(UIImage *))completion
{
    if (!url.length) {
        if (completion) completion(nil);
        return nil;
    }
    UIImage *image = [self.memory objectForKey:url];
    if (image || [self hasFailed:url]) {
        if (completion) completion(image);
        return nil;
    }
    TWImageJob *job = [self jobForURL:url maxPixels:maxPixels];
    TWImageToken *token = [[TWImageToken alloc] init];
    token.url = url;
    token.completion = completion;
    [job.tokens addObject:token];
    [self pump];
    return token;
}

- (void)cancelToken:(id)token
{
    if (![token isKindOfClass:[TWImageToken class]]) return;
    TWImageToken *t = token;
    t.completion = nil;
    TWImageJob *job = t.url ? self.jobs[t.url] : nil;
    if (!job) return;
    [job.tokens removeObjectIdenticalTo:t];
    if (!job.started && !job.notify && job.tokens.count == 0) {
        [self.queue removeObjectIdenticalTo:job];
        [self.jobs removeObjectForKey:job.url];
    }
}

#pragma mark - Loading

- (void)pump
{
    while (self.running < TWMaxConcurrentLoads && self.queue.count) {
        TWImageJob *job = [self.queue lastObject];
        [self.queue removeLastObject];
        job.started = YES;
        self.running++;
        [self startJob:job];
    }
}

- (void)startJob:(TWImageJob *)job
{
    NSString *url = job.url;
    NSString *path = [self pathForURL:url];
    CGFloat maxPixels = job.maxPixels;
    BOOL animate = self.animationAllowed;
    NSUInteger budget = [self animationBudget];
    dispatch_async(self.workQueue, ^{
        @autoreleasepool {
            NSData *data = [NSData dataWithContentsOfFile:path];
            NSUInteger cost = 0;
            UIImage *image = data.length ? TWDecodeImage(data, maxPixels, animate, budget, &cost) : nil;
            if (image) {
                dispatch_async(dispatch_get_main_queue(), ^{ [self finishJob:job image:image cost:cost]; });
                return;
            }
            if (data) [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];   // (unreadable: fetched again)
            dispatch_async(dispatch_get_main_queue(), ^{ [self downloadJob:job path:path]; });
        }
    });
}

- (void)downloadJob:(TWImageJob *)job path:(NSString *)path
{
    CGFloat maxPixels = job.maxPixels;
    BOOL animate = self.animationAllowed;
    NSUInteger budget = [self animationBudget];
    NSDictionary *headers = @{ @"Accept": @"image/png,image/gif,image/jpeg,image/*;q=0.8,*/*;q=0.5" };
    [TWHTTP get:job.url headers:headers completion:^(NSInteger status, NSData *body, NSDictionary *responseHeaders, NSError *error) {
        if (error || status != 200 || body.length == 0 || body.length > TWMaxImageFileBytes) {
            [self finishJob:job image:nil cost:0];
            return;
        }
        dispatch_async(self.workQueue, ^{
            @autoreleasepool {
                NSUInteger cost = 0;
                UIImage *image = TWDecodeImage(body, maxPixels, animate, budget, &cost);
                if (image) [body writeToFile:path atomically:YES];
                dispatch_async(dispatch_get_main_queue(), ^{ [self finishJob:job image:image cost:cost]; });
            }
        });
    }];
}

- (void)finishJob:(TWImageJob *)job image:(UIImage *)image cost:(NSUInteger)cost
{
    self.running--;
    if (self.jobs[job.url] == job) [self.jobs removeObjectForKey:job.url];
    if (image) {
        [self.memory setObject:image forKey:job.url cost:MAX(cost, (NSUInteger)1024)];
        [self.failed removeObjectForKey:job.url];
    } else {
        self.failed[job.url] = [NSDate date];
    }
    for (TWImageToken *token in [job.tokens copy]) {
        void (^completion)(UIImage *) = token.completion;
        token.completion = nil;
        if (completion) completion(image);
    }
    if (job.notify) {
        [[NSNotificationCenter defaultCenter] postNotificationName:TWImageDidLoadNotification object:self userInfo:@{ @"url": job.url }];
    }
    [self pump];
}

#pragma mark - Housekeeping

- (void)clearMemory
{
    [self.memory removeAllObjects];
}

- (void)clearDiskWithCompletion:(dispatch_block_t)completion
{
    [self clearMemory];
    [self.failed removeAllObjects];
    NSString *dir = self.directory;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        NSFileManager *fm = [[NSFileManager alloc] init];
        [fm removeItemAtPath:dir error:NULL];
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
    });
}

- (void)diskUsage:(void (^)(unsigned long long))completion
{
    NSString *dir = self.directory;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        NSFileManager *fm = [[NSFileManager alloc] init];
        unsigned long long total = 0;
        for (NSString *name in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
            total += [[fm attributesOfItemAtPath:[dir stringByAppendingPathComponent:name] error:NULL] fileSize];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(total); });
    });
}

- (void)pruneDisk
{
    NSString *dir = self.directory;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        @autoreleasepool {
            NSFileManager *fm = [[NSFileManager alloc] init];
            NSMutableArray *files = [NSMutableArray array];   // @[date, size, path]
            unsigned long long total = 0;
            NSDate *now = [NSDate date];
            NSUInteger removed = 0;
            for (NSString *name in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
                NSString *path = [dir stringByAppendingPathComponent:name];
                NSDictionary *attributes = [fm attributesOfItemAtPath:path error:NULL];
                NSDate *modified = [attributes fileModificationDate] ?: now;
                if ([now timeIntervalSinceDate:modified] > TWDiskMaxAge) {
                    [fm removeItemAtPath:path error:NULL];
                    removed++;
                    continue;
                }
                total += [attributes fileSize];
                [files addObject:@[modified, @([attributes fileSize]), path]];
            }
            if (total > TWDiskMaxBytes) {
                [files sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [a[0] compare:b[0]]; }];
                for (NSArray *f in files) {
                    if (total <= TWDiskMaxBytes * 3 / 4) break;
                    [fm removeItemAtPath:f[2] error:NULL];
                    total -= MIN(total, [f[1] unsignedLongLongValue]);
                    removed++;
                }
            }
            if (removed) TWLog(@"Image cache: %lu old files removed, %@ kept", (unsigned long)removed, [TWUtils formatFileSize:total]);
        }
    });
}

@end

#pragma mark - Image view

@interface TWImageView ()
@property (nonatomic, copy, readwrite) NSString *imageURL;
@property (nonatomic, strong) id token;
@end

@implementation TWImageView

- (void)dealloc
{
    if (_token) [[TWImageLoader shared] cancelToken:_token];
}

- (void)setImageURL:(NSString *)url placeholder:(UIImage *)placeholder
{
    TWImageLoader *loader = [TWImageLoader shared];
    if (self.token) {
        [loader cancelToken:self.token];
        self.token = nil;
    }
    self.imageURL = url;
    if (!url.length) {
        self.image = placeholder;
        return;
    }
    UIImage *cached = [loader cachedImageForURL:url];
    if (cached) {
        self.image = cached;
        return;
    }
    self.image = placeholder;
    __weak TWImageView *weakSelf = self;
    NSString *expected = [url copy];
    __block BOOL answered = NO;
    id token = [loader loadImage:url maxPixels:self.maxPixels completion:^(UIImage *image) {
        answered = YES;
        TWImageView *view = weakSelf;
        if (!view || ![view.imageURL isEqualToString:expected]) return;
        view.token = nil;
        if (image) view.image = image;
    }];
    if (!answered) self.token = token;
}

@end
