#import "TWPlayerViewController.h"
#import "TWPlayerView.h"
#import "TWChatView.h"
#import "TWPlayback.h"
#import "TWMediaProxy.h"
#import "TWGQL.h"
#import "TWHelix.h"
#import "TWAuth.h"
#import "TWIRC.h"
#import "TWEmotes.h"
#import "TWFavorites.h"
#import "TWNavigator.h"
#import "TWSettings.h"
#import "TWTheme.h"
#import "TWUtils.h"
#import "TWCommon.h"
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MPNowPlayingInfoCenter.h>
#import <MediaPlayer/MPMediaItem.h>

typedef NS_ENUM(NSInteger, TWPlayerMode) {
    TWPlayerModeLive = 0,
    TWPlayerModeVideo,
    TWPlayerModeClip,
};

static void *TWStatusContext = &TWStatusContext;
static void *TWBufferEmptyContext = &TWBufferEmptyContext;
static void *TWKeepUpContext = &TWKeepUpContext;
static const NSTimeInterval TWStallReloadAfter = 20;      // seconds without progress while playing
static const NSInteger TWMaxAutomaticReloads = 3;
static const NSTimeInterval TWInfoRefreshInterval = 60;
static const NSTimeInterval TWLivePauseReloadAfter = 40;   // paused this long: back to the live edge with a fresh playlist

@interface TWPlayerViewController () <TWPlayerViewDelegate, TWChatViewDelegate, TWIRCDelegate, UIActionSheetDelegate>
@property (nonatomic) TWPlayerMode mode;
@property (nonatomic, copy) NSString *login;
@property (nonatomic, strong) TWStream *stream;
@property (nonatomic, strong) TWVideo *video;
@property (nonatomic, strong) TWClip *clip;
@property (nonatomic, strong) TWChannel *channel;
@property (nonatomic, copy) NSString *channelId;
// playback
@property (nonatomic, strong) NSArray *variants;          // TWVariant (live, video)
@property (nonatomic, strong) NSArray *clipSources;       // dictionaries (clip)
@property (nonatomic, strong) TWVariant *currentVariant;  // nil = automatic
@property (nonatomic, copy) NSString *quality;            // the preference in use
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerItem *item;
@property (nonatomic, strong) TWHTTPTask *loadTask;
@property (nonatomic, strong) TWHTTPTask *infoTask;
@property (nonatomic, strong) NSTimer *tickTimer;
@property (nonatomic) BOOL wantsToPlay;
@property (nonatomic) BOOL itemReady;
@property (nonatomic) BOOL ended;
@property (nonatomic) NSInteger automaticReloads;
@property (nonatomic) NSTimeInterval lastProgressTime;    // wall clock of the last change of the playback position
@property (nonatomic) double lastPosition;
@property (nonatomic) NSTimeInterval pausedAt;
@property (nonatomic) NSTimeInterval lastInfoRefresh;
@property (nonatomic) NSUInteger proxyGeneration;
@property (nonatomic) BOOL inBackground;
@property (nonatomic) double pendingSeek;                 // seconds to seek to once the item is ready (-1 = none)
// views
@property (nonatomic, strong) TWPlayerView *playerView;
@property (nonatomic, strong) TWChatView *chatView;
@property (nonatomic) BOOL fullscreen;
@property (nonatomic) BOOL chatVisible;
// chat
@property (nonatomic, strong) TWIRC *irc;
@property (nonatomic, strong) NSMutableDictionary *awaitingEcho;   // message id -> text (sent, echo not yet seen)
@property (nonatomic, strong) NSMutableArray *replayQueue;         // comments waiting for their time (TWChatMessage)
@property (nonatomic) NSInteger replayFetchedUpTo;                 // offset of the last fetched comment
@property (nonatomic) BOOL replayLoading;
@property (nonatomic) BOOL replayExhausted;
@property (nonatomic, strong) TWHTTPTask *replayTask;
@end

@implementation TWPlayerViewController

#pragma mark - Init

- (instancetype)initCommon
{
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        self.wantsFullScreenLayout = YES;
        _quality = [TWSettings preferredQuality];
        _chatVisible = [TWSettings showChat];
        _awaitingEcho = [NSMutableDictionary dictionary];
        _replayQueue = [NSMutableArray array];
        _pendingSeek = -1;
        _wantsToPlay = YES;
    }
    return self;
}

- (instancetype)initWithChannelLogin:(NSString *)login stream:(TWStream *)stream
{
    self = [self initCommon];
    if (self) {
        _mode = TWPlayerModeLive;
        _login = [login lowercaseString];
        _stream = stream;
        _channelId = stream.userId;
    }
    return self;
}

- (instancetype)initWithVideo:(TWVideo *)video
{
    self = [self initCommon];
    if (self) {
        _mode = TWPlayerModeVideo;
        _video = video;
        _login = video.ownerLogin;
    }
    return self;
}

- (instancetype)initWithClip:(TWClip *)clip
{
    self = [self initCommon];
    if (self) {
        _mode = TWPlayerModeClip;
        _clip = clip;
        _login = clip.broadcasterLogin;
    }
    return self;
}

- (void)dealloc
{
    [self teardownPlayback];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - View

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.playerView = [[TWPlayerView alloc] initWithFrame:self.view.bounds];
    self.playerView.delegate = self;
    self.playerView.isLive = self.mode == TWPlayerModeLive;
    self.playerView.chatButtonHidden = self.mode == TWPlayerModeClip;
    [self.view addSubview:self.playerView];

    if (self.mode != TWPlayerModeClip) {
        self.chatView = [[TWChatView alloc] initWithFrame:CGRectZero];
        self.chatView.delegate = self;
        self.chatView.channelId = self.channelId;
        self.chatView.channelLogin = self.login;
        self.chatView.replayMode = self.mode == TWPlayerModeVideo;
        [self.view addSubview:self.chatView];
    } else {
        self.chatVisible = NO;
    }
    self.playerView.chatVisible = self.chatVisible;
    [self updateTitles];

    NSError *audioError = nil;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&audioError];
    [[AVAudioSession sharedInstance] setActive:YES error:NULL];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(didEnterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [nc addObserver:self selector:@selector(willEnterForeground) name:UIApplicationWillEnterForegroundNotification object:nil];
    [nc addObserver:self selector:@selector(authChanged) name:TWAuthDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(themeChanged) name:TWThemeDidChangeNotification object:nil];

    self.playerView.closeIsBack = NO;
    self.playerView.qualityTitle = L(@"Quality");
    [self startPlayback];
    [self startChat];
    if (self.mode == TWPlayerModeLive && !self.stream) [self refreshInfo];
    else if (self.mode == TWPlayerModeLive) [self loadChannelDetails];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self updateStatusBar];
    [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
    [self becomeFirstResponder];
    if (!self.tickTimer) self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [self updateIdleTimer];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self.tickTimer invalidate];
    self.tickTimer = nil;
    [UIApplication sharedApplication].idleTimerDisabled = NO;
    [[UIApplication sharedApplication] setStatusBarHidden:NO withAnimation:UIStatusBarAnimationNone];
    [[UIApplication sharedApplication] setStatusBarStyle:[[TWTheme shared] statusBarStyle] animated:NO];
}

- (BOOL)canBecomeFirstResponder
{
    return YES;
}

- (void)updateStatusBar
{
    UIApplication *app = [UIApplication sharedApplication];
    BOOL hide = self.fullscreen || (!TWIsPad() && UIInterfaceOrientationIsLandscape(self.interfaceOrientation));
    [app setStatusBarHidden:hide withAnimation:UIStatusBarAnimationFade];
    if (!hide) [app setStatusBarStyle:UIStatusBarStyleBlackOpaque animated:NO];
    self.playerView.topInset = hide ? 0 : 20;
    [self.view setNeedsLayout];
}

- (void)viewWillLayoutSubviews
{
    [super viewWillLayoutSubviews];
    CGRect b = self.view.bounds;
    BOOL showChat = self.chatVisible && self.chatView && !self.fullscreen;
    self.chatView.hidden = !showChat;
    if (!showChat) {
        self.playerView.frame = b;
        return;
    }
    BOOL landscape = b.size.width > b.size.height;
    if (landscape) {
        CGFloat chatW = TWIsPad() ? 340 : 190;
        CGFloat top = self.playerView.topInset;   // (the status bar, when it shows)
        self.playerView.frame = CGRectMake(0, 0, b.size.width - chatW, b.size.height);
        self.chatView.frame = CGRectMake(b.size.width - chatW, top, chatW, b.size.height - top);
    } else {
        CGFloat top = self.playerView.topInset;
        CGFloat videoH = floor(b.size.width * 9.0 / 16.0) + top;
        if (TWIsPad()) videoH = MAX(videoH, floor(b.size.height * 0.5));
        self.playerView.frame = CGRectMake(0, 0, b.size.width, videoH);
        self.chatView.frame = CGRectMake(0, videoH, b.size.width, b.size.height - videoH);
    }
}

- (void)willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration
{
    [super willAnimateRotationToInterfaceOrientation:toInterfaceOrientation duration:duration];
    UIApplication *app = [UIApplication sharedApplication];
    BOOL hide = self.fullscreen || (!TWIsPad() && UIInterfaceOrientationIsLandscape(toInterfaceOrientation));
    [app setStatusBarHidden:hide withAnimation:UIStatusBarAnimationNone];
    self.playerView.topInset = hide ? 0 : 20;
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
}

- (BOOL)shouldAutorotate
{
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    return TWIsPad() ? UIInterfaceOrientationMaskAll : UIInterfaceOrientationMaskAllButUpsideDown;
}

- (void)themeChanged
{
    [self.chatView applyTheme];
}

- (void)updateIdleTimer
{
    [UIApplication sharedApplication].idleTimerDisabled = [TWSettings keepScreenOn] && self.wantsToPlay && !self.ended;
}

#pragma mark - Titles and info

- (void)updateTitles
{
    NSString *title = nil, *subtitle = nil;
    switch (self.mode) {
        case TWPlayerModeLive:
            title = self.stream.title.length ? self.stream.title : (self.channel.displayName ?: self.login);
            subtitle = self.stream.gameName.length ? [NSString stringWithFormat:@"%@ · %@", self.stream.displayName ?: self.login, self.stream.gameName] : (self.stream.displayName ?: self.login);
            break;
        case TWPlayerModeVideo:
            title = self.video.title.length ? self.video.title : L(@"Video");
            subtitle = self.video.gameName.length ? [NSString stringWithFormat:@"%@ · %@", self.video.ownerName ?: self.login, self.video.gameName] : (self.video.ownerName ?: self.login);
            break;
        case TWPlayerModeClip:
            title = self.clip.title.length ? self.clip.title : L(@"Clip");
            subtitle = self.clip.gameName.length ? [NSString stringWithFormat:@"%@ · %@", self.clip.broadcasterName ?: self.login, self.clip.gameName] : (self.clip.broadcasterName ?: self.login);
            break;
    }
    self.playerView.title = title;
    self.playerView.subtitle = subtitle;
    [self updateStatusText];
    [self updateNowPlaying];
}

- (void)updateStatusText
{
    if (self.mode != TWPlayerModeLive) return;
    NSMutableArray *parts = [NSMutableArray array];
    if (self.stream.viewers > 0) [parts addObject:[TWUtils formatViewers:self.stream.viewers]];
    if (self.stream.startedAt) [parts addObject:[TWUtils formatUptimeSince:self.stream.startedAt]];
    self.playerView.statusText = [parts componentsJoinedByString:@" · "];
}

- (void)updateNowPlaying
{
    Class center = NSClassFromString(@"MPNowPlayingInfoCenter");
    if (!center) return;
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (self.playerView.title.length) info[MPMediaItemPropertyTitle] = self.playerView.title;
    NSString *artist = self.stream.displayName ?: (self.video.ownerName ?: (self.clip.broadcasterName ?: self.login));
    if (artist.length) info[MPMediaItemPropertyArtist] = artist;
    NSString *game = self.stream.gameName ?: (self.video.gameName ?: self.clip.gameName);
    if (game.length) info[MPMediaItemPropertyAlbumTitle] = game;
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = info;
}

// The stream's title, game and viewers, refreshed now and then
- (void)refreshInfo
{
    if (self.mode != TWPlayerModeLive || self.infoTask) return;
    self.lastInfoRefresh = [NSDate timeIntervalSinceReferenceDate];
    __weak TWPlayerViewController *weakSelf = self;
    self.infoTask = [TWGQL channel:self.login completion:^(TWChannel *channel, NSError *error) {
        TWPlayerViewController *s = weakSelf;
        if (!s) return;
        s.infoTask = nil;
        if (!channel) return;
        s.channel = channel;
        [[TWFavorites shared] rememberChannel:channel];
        if (channel.stream) s.stream = channel.stream;
        if (!s.channelId.length && channel.userId.length) {
            s.channelId = channel.userId;
            s.chatView.channelId = channel.userId;
            [[TWEmoteStore shared] loadChannel:channel.userId login:s.login];
        }
        [s updateTitles];
    }];
}

- (void)loadChannelDetails
{
    // the stream is known: the channel's badges and emotes may load right away
    if (self.channelId.length) [[TWEmoteStore shared] loadChannel:self.channelId login:self.login];
    else [self refreshInfo];
}

#pragma mark - Playback

- (void)startPlayback
{
    [self.loadTask cancel];
    self.ended = NO;
    self.itemReady = NO;
    [self.playerView showMessage:nil retryTitle:nil];
    self.playerView.controlsLocked = NO;
    [self.playerView setBuffering:YES];
    __weak TWPlayerViewController *weakSelf = self;
    // (each case in braces: a block literal is a declaration the compiler will not let a later case jump over)
    switch (self.mode) {
        case TWPlayerModeLive: {
            self.loadTask = [TWPlayback variantsForChannel:self.login completion:^(NSArray *variants, NSError *error) {
                TWPlayerViewController *s = weakSelf;
                if (!s) return;
                s.loadTask = nil;
                if (error) { [s failWithError:error]; return; }
                s.variants = variants;
                [s playVariants];
            }];
            break;
        }
        case TWPlayerModeVideo: {
            self.loadTask = [TWPlayback variantsForVideo:self.video.videoId completion:^(NSArray *variants, NSError *error) {
                TWPlayerViewController *s = weakSelf;
                if (!s) return;
                s.loadTask = nil;
                if (error) { [s failWithError:error]; return; }
                s.variants = variants;
                if (s.pendingSeek < 0) {
                    NSTimeInterval resume = [TWSettings resumePositionForVideo:s.video.videoId];
                    if (resume > 10 && resume < s.video.length - 30) s.pendingSeek = resume;
                }
                [s playVariants];
            }];
            break;
        }
        case TWPlayerModeClip: {
            self.loadTask = [TWGQL clipSources:self.clip.slug completion:^(NSArray *sources, NSError *error) {
                TWPlayerViewController *s = weakSelf;
                if (!s) return;
                s.loadTask = nil;
                if (error) { [s failWithError:error]; return; }
                s.clipSources = sources;
                [s playClip];
            }];
            break;
        }
    }
}

- (void)playVariants
{
    TWVariant *chosen = nil;
    NSURL *url = [TWPlayback playerURLForVariants:self.variants quality:self.quality chosen:&chosen];
    if (!url) {
        [self failWithError:TWMakeError(TWErrorNetwork, L(@"The local video proxy could not start."))];
        return;
    }
    self.currentVariant = chosen;
    self.proxyGeneration = [TWMediaProxy shared].generation;
    self.playerView.qualityTitle = chosen ? [chosen title] : L(@"Auto");
    NSMutableArray *names = [NSMutableArray array];   // (renditions beyond this device marked with a cross)
    for (TWVariant *v in self.variants) [names addObject:[v.name stringByAppendingString:[TWPlayback deviceCanPlay:v] ? @"" : @"✗"]];
    TWLog(@"Renditions: %@; quality %@ -> %@", [names componentsJoinedByString:@", "], self.quality ?: @"auto", chosen ? chosen.name : @"auto (master playlist)");
    [self loadItemWithURL:url];
}

- (NSDictionary *)clipSourceForQuality
{
    NSArray *sources = self.clipSources;
    if (!sources.count) return nil;
    NSInteger wanted = 720;
    if ([self.quality isEqualToString:TWQualitySource]) wanted = 100000;
    else if ([self.quality integerValue] > 0) wanted = [self.quality integerValue];
    else if ([self.quality isEqualToString:TWQualityAudio]) wanted = 360;
    BOOL old = [TWUtils deviceIsOldGeneration];
    NSDictionary *best = nil;
    for (NSDictionary *s in sources) {
        NSInteger q = [s[@"quality"] integerValue];
        NSInteger fps = [s[@"fps"] integerValue];
        if (q > 1080 || (q >= 1080 && fps > 30) || (old && (q > 720 || (q >= 720 && fps > 30)))) continue;
        if (q <= wanted) { best = s; break; }   // (sources are sorted best first)
    }
    return best ?: [sources lastObject];
}

- (void)playClip
{
    NSDictionary *source = [self clipSourceForQuality];
    NSString *url = source[@"url"];
    if (!url.length) { [self failWithError:TWMakeError(TWErrorAPI, L(@"This clip is not available any more."))]; return; }
    TWMediaProxy *proxy = [TWMediaProxy shared];
    [proxy ensureRunning];
    [proxy resetPlaybackState];
    NSString *proxied = [proxy proxyURLForURL:[NSURL URLWithString:url]];
    if (!proxied) { [self failWithError:TWMakeError(TWErrorNetwork, L(@"The local video proxy could not start."))]; return; }
    self.proxyGeneration = proxy.generation;
    self.playerView.qualityTitle = [NSString stringWithFormat:@"%@p", source[@"quality"]];
    [self loadItemWithURL:[NSURL URLWithString:proxied]];
}

- (void)loadItemWithURL:(NSURL *)url
{
    [self detachItem];
    TWLog(@"Playing %@ (%@)", self.login, url.lastPathComponent);
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    self.item = item;
    [item addObserver:self forKeyPath:@"status" options:0 context:TWStatusContext];
    [item addObserver:self forKeyPath:@"playbackBufferEmpty" options:0 context:TWBufferEmptyContext];
    [item addObserver:self forKeyPath:@"playbackLikelyToKeepUp" options:0 context:TWKeepUpContext];
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(itemDidPlayToEnd:) name:AVPlayerItemDidPlayToEndTimeNotification object:item];
    [nc addObserver:self selector:@selector(itemFailed:) name:AVPlayerItemFailedToPlayToEndTimeNotification object:item];
    [nc addObserver:self selector:@selector(itemStalled:) name:AVPlayerItemPlaybackStalledNotification object:item];
    if (!self.player) {
        self.player = [AVPlayer playerWithPlayerItem:item];
        // (the proxy lives on this device only: a remote AirPlay screen could not reach it)
        self.player.allowsExternalPlayback = NO;
        self.playerView.player = self.player;
    } else {
        [self.player replaceCurrentItemWithPlayerItem:item];
        if (!self.inBackground) self.playerView.player = self.player;
    }
    self.lastProgressTime = [NSDate timeIntervalSinceReferenceDate];
    self.lastPosition = -1;
    [self.playerView setBuffering:YES];
    if (self.wantsToPlay) {
        [self.player play];
        self.playerView.playing = YES;
    }
}

- (void)detachItem
{
    if (!self.item) return;
    @try {
        [self.item removeObserver:self forKeyPath:@"status" context:TWStatusContext];
        [self.item removeObserver:self forKeyPath:@"playbackBufferEmpty" context:TWBufferEmptyContext];
        [self.item removeObserver:self forKeyPath:@"playbackLikelyToKeepUp" context:TWKeepUpContext];
    } @catch (NSException *e) {}
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:self.item];
    [nc removeObserver:self name:AVPlayerItemFailedToPlayToEndTimeNotification object:self.item];
    [nc removeObserver:self name:AVPlayerItemPlaybackStalledNotification object:self.item];
    self.item = nil;
}

- (void)teardownPlayback
{
    [self.loadTask cancel];
    self.loadTask = nil;
    [self.infoTask cancel];
    self.infoTask = nil;
    [self.replayTask cancel];
    self.replayTask = nil;
    [self.tickTimer invalidate];
    self.tickTimer = nil;
    [self rememberPosition];
    [self.player pause];
    [self detachItem];
    self.playerView.player = nil;
    self.player = nil;
    [self.irc disconnect];
    self.irc.delegate = nil;
    self.irc = nil;
    Class center = NSClassFromString(@"MPNowPlayingInfoCenter");
    if (center) [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = nil;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context != TWStatusContext && context != TWBufferEmptyContext && context != TWKeepUpContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    if (![NSThread isMainThread]) {
        // (AVFoundation reports from its own threads now and then)
        dispatch_async(dispatch_get_main_queue(), ^{ [self observeValueForKeyPath:keyPath ofObject:object change:change context:context]; });
        return;
    }
    if (object != self.item) return;
    if (context == TWStatusContext) {
        if (self.item.status == AVPlayerItemStatusFailed) {
            NSError *error = self.item.error;
            TWLog(@"Item failed: %@", error);
            [self handlePlaybackFailure:error];
        } else if (self.item.status == AVPlayerItemStatusReadyToPlay) {
            self.itemReady = YES;
            self.automaticReloads = 0;
            [self.playerView setBuffering:NO];
            if (self.pendingSeek >= 0) {
                double seek = self.pendingSeek;
                self.pendingSeek = -1;
                [self.player seekToTime:CMTimeMakeWithSeconds(seek, 600)];
            }
            if (self.wantsToPlay) [self.player play];
            [self updateNowPlaying];
        }
    } else if (context == TWBufferEmptyContext) {
        if (self.item.playbackBufferEmpty && self.wantsToPlay) [self.playerView setBuffering:YES];
    } else if (context == TWKeepUpContext) {
        if (self.item.playbackLikelyToKeepUp) {
            [self.playerView setBuffering:NO];
            if (self.wantsToPlay && self.player.rate == 0 && !self.ended) [self.player play];
        }
    }
}

- (void)itemDidPlayToEnd:(NSNotification *)note
{
    if (self.mode == TWPlayerModeLive) {
        // the playlist ended: the stream is over (or the proxy's playlist failed and the player gave up)
        [self streamEnded];
        return;
    }
    self.ended = YES;
    self.wantsToPlay = NO;
    self.playerView.playing = NO;
    if (self.mode == TWPlayerModeVideo) [TWSettings setResumePosition:0 forVideo:self.video.videoId];
    self.playerView.controlsLocked = YES;
    [self.playerView showMessage:nil retryTitle:nil];
    [self updateIdleTimer];
}

- (void)itemFailed:(NSNotification *)note
{
    NSError *error = note.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
    TWLog(@"Failed to play to end: %@", error);
    [self handlePlaybackFailure:error];
}

- (void)itemStalled:(NSNotification *)note
{
    TWLog(@"Playback stalled");
    if (self.wantsToPlay) [self.playerView setBuffering:YES];
}

- (void)streamEnded
{
    self.ended = YES;
    self.wantsToPlay = NO;
    self.playerView.playing = NO;
    [self.playerView setBuffering:NO];
    [self.playerView showMessage:L(@"The stream has ended.") retryTitle:L(@"Try Again")];
    __weak TWPlayerViewController *weakSelf = self;
    self.playerView.retryHandler = ^{ [weakSelf retryTapped]; };
    [self updateIdleTimer];
}

- (void)handlePlaybackFailure:(NSError *)error
{
    if (self.ended) return;
    if (self.mode == TWPlayerModeLive && self.automaticReloads < TWMaxAutomaticReloads) {
        // a hiccup of the stream (a new playlist, a dropped segment): a fresh start usually helps
        self.automaticReloads++;
        TWLog(@"Reloading the stream (%ld)", (long)self.automaticReloads);
        [self.playerView setBuffering:YES];
        __weak TWPlayerViewController *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            TWPlayerViewController *s = weakSelf;
            if (s && !s.ended && s.wantsToPlay) [s startPlayback];
        });
        return;
    }
    NSString *message = error.localizedDescription;
    if (self.mode == TWPlayerModeLive) message = L(@"The stream could not be played. It may have ended, or the connection is too slow.");
    else if (!message.length) message = L(@"The video could not be played.");
    [self failWithError:TWMakeError(TWErrorNetwork, message)];
}

- (void)failWithError:(NSError *)error
{
    [self.playerView setBuffering:NO];
    self.playerView.playing = NO;
    NSString *message = error.localizedDescription ?: L(@"Playback failed.");
    if (error.code == TWErrorOffline) message = L(@"The channel is not live right now.");
    [self.playerView showMessage:message retryTitle:L(@"Try Again")];
    __weak TWPlayerViewController *weakSelf = self;
    self.playerView.retryHandler = ^{ [weakSelf retryTapped]; };
    [self updateIdleTimer];
}

- (void)retryTapped
{
    self.automaticReloads = 0;
    self.wantsToPlay = YES;
    self.ended = NO;
    [self startPlayback];
    [self updateIdleTimer];
}

- (void)rememberPosition
{
    if (self.mode != TWPlayerModeVideo || !self.item || !self.itemReady) return;
    double position = CMTimeGetSeconds(self.player.currentTime);
    if (position > 0 && !isnan(position)) [TWSettings setResumePosition:position forVideo:self.video.videoId];
}

#pragma mark - Tick

- (void)tick
{
    if (!self.item) return;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    double position = CMTimeGetSeconds(self.player.currentTime);
    if (isnan(position)) position = 0;
    if (self.mode != TWPlayerModeLive) {
        double duration = CMTimeGetSeconds(self.item.duration);
        if (isnan(duration) || duration <= 0) duration = self.mode == TWPlayerModeVideo ? self.video.length : self.clip.duration;
        if (duration > 0) [self.playerView setProgress:position / duration duration:duration position:position];
        [self feedReplayForPosition:position];
    }
    // progress watch: a playing stream whose position does not move for a long time is started again
    if (fabs(position - self.lastPosition) > 0.01) {
        self.lastPosition = position;
        self.lastProgressTime = now;
    } else if (self.wantsToPlay && self.itemReady && !self.ended && now - self.lastProgressTime > TWStallReloadAfter) {
        TWLog(@"No progress for %.0f s, reloading", now - self.lastProgressTime);
        self.lastProgressTime = now;
        if (self.mode == TWPlayerModeLive) [self startPlayback];
        else { [self.player pause]; [self.player play]; }
    }
    TWMediaProxy *proxy = [TWMediaProxy shared];
    self.playerView.adBreak = proxy.adBreakActive && self.mode == TWPlayerModeLive;
    if (self.mode == TWPlayerModeLive && now - self.lastInfoRefresh > TWInfoRefreshInterval) [self refreshInfo];
    if (self.mode == TWPlayerModeLive) [self updateStatusText];
    if (self.mode == TWPlayerModeVideo && ((NSInteger)now % 15 == 0)) [self rememberPosition];
}

#pragma mark - Player view delegate

- (void)playerViewDidTapPlayPause:(TWPlayerView *)view
{
    if (self.ended) {
        if (self.mode == TWPlayerModeLive) { [self retryTapped]; return; }
        // a finished video: from the start
        self.ended = NO;
        self.wantsToPlay = YES;
        [self.player seekToTime:kCMTimeZero];
        [self.player play];
        self.playerView.playing = YES;
        self.playerView.controlsLocked = NO;
        [self updateIdleTimer];
        return;
    }
    if (self.wantsToPlay) {
        self.wantsToPlay = NO;
        [self.player pause];
        self.pausedAt = [NSDate timeIntervalSinceReferenceDate];
        self.playerView.playing = NO;
        self.playerView.controlsLocked = YES;
        [self rememberPosition];
    } else {
        self.wantsToPlay = YES;
        self.playerView.playing = YES;
        self.playerView.controlsLocked = NO;
        if (self.mode == TWPlayerModeLive && [NSDate timeIntervalSinceReferenceDate] - self.pausedAt > TWLivePauseReloadAfter) {
            [self startPlayback];   // (back to the live edge: the old playlist window is gone)
        } else {
            [self.player play];
        }
    }
    [self updateIdleTimer];
}

- (void)playerViewDidTapClose:(TWPlayerView *)view
{
    [self teardownPlayback];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)playerViewDidTapQuality:(TWPlayerView *)view fromView:(UIView *)anchor
{
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:L(@"Quality") delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
    sheet.tag = 1;
    if (self.mode == TWPlayerModeClip) {
        for (NSDictionary *s in self.clipSources) [sheet addButtonWithTitle:[NSString stringWithFormat:@"%@p", s[@"quality"]]];
    } else {
        [sheet addButtonWithTitle:L(@"Auto")];
        for (TWVariant *v in self.variants) {
            NSString *title = [v title];
            if (![TWPlayback deviceCanPlay:v]) title = [title stringByAppendingString:L(@" (too much for this device)")];
            [sheet addButtonWithTitle:title];
        }
    }
    sheet.cancelButtonIndex = [sheet addButtonWithTitle:L(@"Cancel")];
    if (TWIsPad()) [sheet showFromRect:anchor.bounds inView:anchor animated:YES];
    else [sheet showInView:self.view];
    self.playerView.controlsLocked = YES;
}

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex
{
    self.playerView.controlsLocked = !self.wantsToPlay;
    if (actionSheet.tag != 1 || buttonIndex < 0 || buttonIndex == actionSheet.cancelButtonIndex) return;
    double position = self.item ? CMTimeGetSeconds(self.player.currentTime) : 0;
    if (self.mode == TWPlayerModeClip) {
        NSDictionary *s = self.clipSources[(NSUInteger)buttonIndex];
        self.quality = s[@"quality"];
        if (!isnan(position) && position > 0) self.pendingSeek = position;
        [self playClip];
        return;
    }
    if (buttonIndex == 0) {
        self.quality = TWQualityAuto;
    } else if ((NSUInteger)(buttonIndex - 1) < self.variants.count) {
        TWVariant *v = self.variants[(NSUInteger)(buttonIndex - 1)];
        self.quality = [v qualityKey];
    } else {
        return;
    }
    [TWSettings setPreferredQuality:self.quality];
    [TWSettings save];
    if (self.mode == TWPlayerModeVideo && !isnan(position) && position > 0) self.pendingSeek = position;
    self.ended = NO;
    [self playVariants];
}

- (void)playerViewDidTapChat:(TWPlayerView *)view
{
    self.chatVisible = !self.chatVisible;
    [TWSettings setShowChat:self.chatVisible];
    self.playerView.chatVisible = self.chatVisible;
    [self.view setNeedsLayout];
    [UIView animateWithDuration:0.25 animations:^{ [self.view layoutIfNeeded]; }];
    if (!self.chatVisible) [self.chatView dismissKeyboard];
}

- (void)playerViewDidTapFullscreen:(TWPlayerView *)view
{
    self.fullscreen = !self.fullscreen;
    self.playerView.fullscreen = self.fullscreen;
    [self updateStatusBar];
    [UIView animateWithDuration:0.25 animations:^{ [self.view layoutIfNeeded]; }];
    if (self.fullscreen) [self.chatView dismissKeyboard];
}

- (void)playerViewDidTapChannel:(TWPlayerView *)view
{
    if (!self.login.length) return;
    [TWNavigator openChannelLogin:self.login from:self];
}

- (void)playerView:(TWPlayerView *)view didSeekToFraction:(double)fraction
{
    double duration = CMTimeGetSeconds(self.item.duration);
    if (isnan(duration) || duration <= 0) duration = self.mode == TWPlayerModeVideo ? self.video.length : self.clip.duration;
    if (duration <= 0) return;
    double target = fraction * duration;
    [self seekTo:target];
}

- (void)playerView:(TWPlayerView *)view didSkipSeconds:(double)seconds
{
    double position = CMTimeGetSeconds(self.player.currentTime);
    if (isnan(position)) position = 0;
    [self seekTo:MAX(0, position + seconds)];
}

- (void)seekTo:(double)seconds
{
    if (!self.item) return;
    self.ended = NO;
    [self.playerView setBuffering:YES];
    [self.player seekToTime:CMTimeMakeWithSeconds(seconds, 600) toleranceBefore:CMTimeMakeWithSeconds(2, 600) toleranceAfter:CMTimeMakeWithSeconds(2, 600)];
    if (self.wantsToPlay) [self.player play];
    [self resetReplayToPosition:seconds];
}

- (void)playerViewDidTapGoLive:(TWPlayerView *)view
{
    if (self.mode != TWPlayerModeLive) return;
    self.wantsToPlay = YES;
    self.playerView.playing = YES;
    self.playerView.controlsLocked = NO;
    [self startPlayback];
}

#pragma mark - Background

- (void)didEnterBackground
{
    self.inBackground = YES;
    TWLog(@"Background: %@", self.wantsToPlay ? ([TWSettings backgroundAudio] ? @"the sound goes on" : @"paused") : @"not playing");
    if (self.wantsToPlay && [TWSettings backgroundAudio] && !self.ended) {
        // without a picture to draw the sound goes on; with the layer attached iOS pauses the player
        self.playerView.player = nil;
        __weak TWPlayerViewController *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            TWPlayerViewController *s = weakSelf;
            if (s && s.inBackground && s.wantsToPlay) [s.player play];
        });
    } else if (self.wantsToPlay) {
        [self.player pause];
        self.pausedAt = [NSDate timeIntervalSinceReferenceDate];
    }
    [self rememberPosition];
}

- (void)willEnterForeground
{
    self.inBackground = NO;
    self.playerView.player = self.player;
    TWMediaProxy *proxy = [TWMediaProxy shared];
    [proxy ensureRunning];
    TWLog(@"Foreground: proxy generation %ld (was %ld)", (long)proxy.generation, (long)self.proxyGeneration);
    if (proxy.generation != self.proxyGeneration && !self.ended) {
        // the proxy was restarted while we were away: the old addresses are void
        if (self.wantsToPlay) [self startPlayback];
        return;
    }
    if (self.wantsToPlay && !self.ended) {
        if (self.mode == TWPlayerModeLive && ![TWSettings backgroundAudio] && [NSDate timeIntervalSinceReferenceDate] - self.pausedAt > TWLivePauseReloadAfter) [self startPlayback];
        else [self.player play];
    }
    [self updateStatusBar];
}

- (void)remoteControlReceivedWithEvent:(UIEvent *)event
{
    if (event.type != UIEventTypeRemoteControl) return;
    switch (event.subtype) {
        case UIEventSubtypeRemoteControlTogglePlayPause:
            [self playerViewDidTapPlayPause:self.playerView];
            break;
        case UIEventSubtypeRemoteControlPlay:
            if (!self.wantsToPlay) [self playerViewDidTapPlayPause:self.playerView];
            break;
        case UIEventSubtypeRemoteControlPause:
        case UIEventSubtypeRemoteControlStop:
            if (self.wantsToPlay) [self playerViewDidTapPlayPause:self.playerView];
            break;
        default:
            break;
    }
}

#pragma mark - Chat (live)

- (void)startChat
{
    if (self.mode == TWPlayerModeClip) return;
    [[TWEmoteStore shared] loadGlobalsIfNeeded];
    if (self.mode == TWPlayerModeVideo) {
        [[TWEmoteStore shared] loadChannel:self.channelId login:self.login];
        [self.chatView appendNotice:L(@"Chat replay: the messages appear as they did during the broadcast.")];
        return;
    }
    if (self.channelId.length) [[TWEmoteStore shared] loadChannel:self.channelId login:self.login];
    [self updateCanSend];
    self.irc = [[TWIRC alloc] initWithChannel:self.login];
    self.irc.delegate = self;
    self.irc.ownLogin = [TWAuth shared].login;
    [self.irc connect];
}

- (void)updateCanSend
{
    self.chatView.canSend = [TWAuth shared].isLoggedIn && self.mode == TWPlayerModeLive;
}

- (void)authChanged
{
    [self updateCanSend];
    self.irc.ownLogin = [TWAuth shared].login;
}

- (void)irc:(TWIRC *)irc didReceiveMessages:(NSArray *)messages
{
    if (self.awaitingEcho.count) {
        for (TWChatMessage *m in messages) if (m.messageId) [self.awaitingEcho removeObjectForKey:m.messageId];
    }
    [self.chatView appendMessages:messages];
}

- (void)irc:(TWIRC *)irc didChangeState:(TWIRCState)state
{
    if (state == TWIRCStateConnected) [self.chatView appendNotice:[NSString stringWithFormat:L(@"Connected to the chat of %@."), self.login]];
}

- (void)irc:(TWIRC *)irc didUpdateRoomState:(NSDictionary *)state
{
    NSMutableArray *modes = [NSMutableArray array];
    if ([state[@"emoteOnly"] boolValue]) [modes addObject:L(@"emotes only")];
    if ([state[@"subscribersOnly"] boolValue]) [modes addObject:L(@"subscribers only")];
    NSInteger followers = state[@"followersOnly"] ? [state[@"followersOnly"] integerValue] : -1;
    if (followers >= 0) [modes addObject:followers > 0 ? [NSString stringWithFormat:L(@"followers only (%ld min)"), (long)followers] : L(@"followers only")];
    NSInteger slow = [state[@"slow"] integerValue];
    if (slow > 0) [modes addObject:[NSString stringWithFormat:L(@"slow mode %ld s"), (long)slow]];
    if (modes.count && self.chatView.canSend) [self.chatView appendNotice:[NSString stringWithFormat:L(@"Chat mode: %@."), [modes componentsJoinedByString:@", "]]];
}

- (void)irc:(TWIRC *)irc didClearMessagesOfUser:(NSString *)login seconds:(NSInteger)seconds
{
    [self.chatView clearMessagesOfUser:login seconds:seconds];
}

- (void)irc:(TWIRC *)irc didDeleteMessageWithId:(NSString *)messageId
{
    [self.chatView deleteMessageWithId:messageId];
}

- (void)chatView:(TWChatView *)chatView didTapName:(NSString *)login displayName:(NSString *)displayName
{
    if (login.length) [TWNavigator openChannelLogin:login from:self];
}

- (void)chatView:(TWChatView *)chatView didTapLink:(NSString *)url
{
    NSURL *u = [NSURL URLWithString:url];
    if (!u) return;
    UIApplication *app = [UIApplication sharedApplication];
    // the user's own browser app knows today's web; this device's Safari does not
    NSURL *browser = [NSURL URLWithString:[@"browser:" stringByAppendingString:url]];
    if ([app canOpenURL:browser]) [app openURL:browser];
    else [app openURL:u];
}

- (void)chatView:(TWChatView *)chatView wantsToSend:(NSString *)text
{
    if (!self.channelId.length) {
        [TWUtils alertWithTitle:L(@"Please wait") message:L(@"The channel details are still loading.")];
        return;
    }
    [self.chatView setSending:YES];
    __weak TWPlayerViewController *weakSelf = self;
    NSString *sent = text;
    [TWHelix sendChatMessage:text toBroadcaster:self.channelId replyTo:nil completion:^(NSString *messageId, NSString *dropReason, NSError *error) {
        TWPlayerViewController *s = weakSelf;
        if (!s) return;
        [s.chatView setSending:NO];
        if (error) {
            [TWUtils alertWithTitle:L(@"Not sent") message:error.localizedDescription];
            return;
        }
        if (dropReason.length) {
            [s.chatView appendNotice:[NSString stringWithFormat:L(@"Not sent: %@"), dropReason]];
            return;
        }
        [s.chatView clearInput];
        if (messageId.length) {
            // the message comes back through the chat connection; when it does not, it is shown from here
            s.awaitingEcho[messageId] = sent;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                TWPlayerViewController *inner = weakSelf;
                if (!inner) return;
                NSString *pending = inner.awaitingEcho[messageId];
                if (!pending) return;
                [inner.awaitingEcho removeObjectForKey:messageId];
                TWChatMessage *m = [[TWChatMessage alloc] init];
                m.kind = TWChatKindMessage;
                m.messageId = messageId;
                m.login = [TWAuth shared].login;
                m.displayName = [TWAuth shared].displayName ?: m.login;
                m.text = pending;
                m.badges = @[];
                m.emotes = @[];
                m.timestamp = [NSDate date];
                m.isOwn = YES;
                [inner.chatView appendMessages:@[ m ]];
            });
        }
    }];
}

- (void)chatViewDidChangeKeyboard:(TWChatView *)chatView visible:(BOOL)visible
{
    // (nothing to move: the chat view shrinks its own table)
}

#pragma mark - Chat replay (videos)

- (void)resetReplayToPosition:(double)seconds
{
    if (self.mode != TWPlayerModeVideo) return;
    [self.replayTask cancel];
    self.replayTask = nil;
    [self.replayQueue removeAllObjects];
    [self.chatView removeAllMessages];
    self.replayFetchedUpTo = (NSInteger)MAX(0, seconds - 20);
    self.replayExhausted = NO;
    self.replayLoading = NO;
}

- (void)feedReplayForPosition:(double)seconds
{
    if (self.mode != TWPlayerModeVideo || !self.chatVisible) return;
    // release what is due
    NSMutableArray *due = [NSMutableArray array];
    while (self.replayQueue.count) {
        TWChatMessage *m = self.replayQueue[0];
        if ([m.timestamp timeIntervalSince1970] > seconds) break;
        [due addObject:m];
        [self.replayQueue removeObjectAtIndex:0];
    }
    if (due.count) [self.chatView appendMessages:due];
    // fetch ahead
    if (!self.replayLoading && !self.replayExhausted && (self.replayQueue.count < 30 || self.replayFetchedUpTo < seconds)) {
        self.replayLoading = YES;
        NSInteger offset = MAX(self.replayFetchedUpTo, (NSInteger)seconds - 5);
        __weak TWPlayerViewController *weakSelf = self;
        self.replayTask = [TWGQL commentsForVideo:self.video.videoId offset:offset completion:^(NSArray *comments, BOOL hasMore, NSError *error) {
            TWPlayerViewController *s = weakSelf;
            if (!s) return;
            s.replayLoading = NO;
            s.replayTask = nil;
            if (error) {
                TWLog(@"Chat replay: %@", error.localizedDescription);
                s.replayExhausted = YES;   // (tried again after the next seek)
                return;
            }
            NSMutableSet *known = [NSMutableSet set];
            for (TWChatMessage *m in s.replayQueue) if (m.messageId) [known addObject:m.messageId];
            NSInteger last = s.replayFetchedUpTo;
            for (NSDictionary *c in comments) {
                TWChatMessage *m = [TWChatMessage messageFromComment:c];
                if (!m || [known containsObject:m.messageId]) continue;
                double at = [m.timestamp timeIntervalSince1970];
                if (at < seconds - 30) continue;   // (too old to show)
                [s.replayQueue addObject:m];
                last = MAX(last, (NSInteger)at);
            }
            if (!comments.count || (NSInteger)last <= s.replayFetchedUpTo) {
                // nothing new at this offset: skip ahead or stop
                if (!hasMore) s.replayExhausted = YES;
                else s.replayFetchedUpTo = s.replayFetchedUpTo + 30;
            } else {
                s.replayFetchedUpTo = last;
            }
            if (!hasMore && !comments.count) s.replayExhausted = YES;
        }];
    }
}

#pragma mark - Replacement

- (void)replaceWithPlayer:(TWPlayerViewController *)player
{
    UIViewController *presenter = self.presentingViewController;
    [self teardownPlayback];
    [self dismissViewControllerAnimated:NO completion:^{
        player.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
        [presenter presentViewController:player animated:YES completion:nil];
    }];
}

@end
