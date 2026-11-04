//
//  MLDuoBridge.m
//  Moonlight Duo
//

#import "MLDuoBridge.h"
#import "DataManager.h"
#import "TemporarySettings.h"
#import "TemporaryApp.h"
#import "TemporaryHost.h"
#import "StreamConfiguration.h"
#import "StreamFrameViewController.h"
#import "ControllerSupport.h"
#import "AppAssetManager.h"
#import "HttpManager.h"
#import "HttpRequest.h"
#import "HttpResponse.h"
#import "ServerInfoResponse.h"
#import "AppListResponse.h"
#import "ConnectionHelper.h"
#import "PairManager.h"

@import ImageIO;
@import AVFoundation;
@import VideoToolbox;

#include <Limelight.h>

NSNotificationName const MLStreamDidEndNotification = @"MLStreamDidEndNotification";

static NSString *const kResolutionModeKey = @"MLResolutionMode";
static NSString *const kAutomaticBitrateKey = @"MLAutomaticBitrate";
static NSString *const kSplitLayoutKey = @"MLSplitLayout";

#pragma mark - Settings

@implementation MLSettings

+ (void)registerDefaults {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{
            kResolutionModeKey: @1,
            @"MLPadHaptics": @YES,
            kAutomaticBitrateKey: @YES,
            kSplitLayoutKey: @YES,
        }];
    });
}

+ (MLSettings *)current {
    [self registerDefaults];
    TemporarySettings *s = [[[DataManager alloc] init] getSettings];
    MLSettings *m = [[MLSettings alloc] init];
    m.bitrate = s.bitrate.integerValue;
    m.framerate = s.framerate.integerValue;
    m.width = s.width.integerValue;
    m.height = s.height.integerValue;
    m.onscreenControls = s.onscreenControls.integerValue;
    switch (s.preferredCodec) {
        case CODEC_PREF_H264: m.codec = 1; break;
        case CODEC_PREF_HEVC: m.codec = 2; break;
        case CODEC_PREF_AV1:  m.codec = 3; break;
        default:              m.codec = 0; break;
    }
    m.optimizeGames = s.optimizeGames;
    m.multiController = s.multiController;
    m.swapABXYButtons = s.swapABXYButtons;
    m.playAudioOnPC = s.playAudioOnPC;
    m.useFramePacing = s.useFramePacing;
    m.enableHdr = s.enableHdr;
    m.btMouseSupport = s.btMouseSupport;
    m.absoluteTouchMode = s.absoluteTouchMode;
    m.statsOverlay = s.statsOverlay;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    m.resolutionMode = [d integerForKey:kResolutionModeKey];
    m.padHaptics = [d boolForKey:@"MLPadHaptics"];
    m.automaticBitrate = [d boolForKey:kAutomaticBitrateKey];
    m.splitLayout = [d boolForKey:kSplitLayoutKey];
    return m;
}

- (void)save {
    uint32_t codec;
    switch (self.codec) {
        case 1: codec = CODEC_PREF_H264; break;
        case 2: codec = CODEC_PREF_HEVC; break;
        case 3: codec = CODEC_PREF_AV1; break;
        default: codec = CODEC_PREF_AUTO; break;
    }
    DataManager *dataMan = [[DataManager alloc] init];
    if ([[dataMan getSettings].onscreenControls integerValue] != self.onscreenControls) {
        // A new On-Screen Controls choice resets the gamepad's remembered 2D / 3D / Tap layout.
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"MLPadLayout"];
    }
    [dataMan saveSettingsWithBitrate:self.bitrate
                                              framerate:self.framerate
                                                 height:self.height
                                                  width:self.width
                                            audioConfig:2 // Stereo
                                       onscreenControls:self.onscreenControls
                                          optimizeGames:self.optimizeGames
                                        multiController:self.multiController
                                        swapABXYButtons:self.swapABXYButtons
                                              audioOnPC:self.playAudioOnPC
                                         preferredCodec:codec
                                         useFramePacing:self.useFramePacing
                                              enableHdr:self.enableHdr
                                         btMouseSupport:self.btMouseSupport
                                      absoluteTouchMode:self.absoluteTouchMode
                                           statsOverlay:self.statsOverlay];
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setInteger:self.resolutionMode forKey:kResolutionModeKey];
    [d setBool:self.padHaptics forKey:@"MLPadHaptics"];
    [d setBool:self.automaticBitrate forKey:kAutomaticBitrateKey];
    [d setBool:self.splitLayout forKey:kSplitLayoutKey];
}

// Same curve as Moonlight Qt / the original settings screen.
+ (NSInteger)defaultBitrateForWidth:(NSInteger)width height:(NSInteger)height fps:(NSInteger)fps {
    float frameRateFactor = (fps <= 60 ? fps : (sqrtf(fps / 60.f) * 60.f)) / 30.f;
    struct { NSInteger pixels; int factor; } table[] = {
        { 640 * 360, 1 }, { 854 * 480, 2 }, { 1280 * 720, 5 }, { 1920 * 1080, 10 },
        { 2560 * 1440, 20 }, { 3840 * 2160, 40 }, { -1, -1 }
    };
    float resolutionFactor = 10;
    NSInteger pixels = width * height;
    for (int i = 0;; i++) {
        if (pixels == table[i].pixels) { resolutionFactor = table[i].factor; break; }
        else if (table[i].pixels == -1) { resolutionFactor = table[i - 1].factor; break; }
        else if (pixels < table[i].pixels) {
            if (i == 0) { resolutionFactor = table[i].factor; }
            else {
                resolutionFactor = ((float)(pixels - table[i - 1].pixels) / (table[i].pixels - table[i - 1].pixels))
                    * (table[i].factor - table[i - 1].factor) + table[i - 1].factor;
            }
            break;
        }
    }
    NSInteger bitrate = (NSInteger)round(resolutionFactor * frameRateFactor) * 1000;
    return MIN(bitrate, 100000);
}

@end

#pragma mark - Bridge

@implementation MLDuoBridge

+ (CGSize)nativeStreamSizeForWindow:(UIWindow *)window {
    if (window == nil) {
        return CGSizeMake(1920, 1080);
    }
    CGFloat scale = window.traitCollection.displayScale > 0 ? window.traitCollection.displayScale : 3.0;
    CGFloat w = window.bounds.size.width * scale;
    CGFloat h = window.bounds.size.height * scale;
    CGFloat longSide = MAX(w, h), shortSide = MIN(w, h);
    // Encoders want even dimensions.
    NSInteger lw = ((NSInteger)floor(longSide)) & ~1;
    NSInteger sh = ((NSInteger)floor(shortSide)) & ~1;
    return CGSizeMake(MIN(lw, 4096), MIN(sh, 4096));
}

+ (CGSize)safeAreaStreamSizeForWindow:(UIWindow *)window {
    if (window == nil) {
        return [self nativeStreamSizeForWindow:nil];
    }
    CGFloat scale = window.traitCollection.displayScale > 0 ? window.traitCollection.displayScale : 3.0;
    CGSize b = window.bounds.size;
    UIEdgeInsets i = window.safeAreaInsets;
    CGFloat longSide, shortSide;
    if (b.width >= b.height) {
        longSide = (b.width - i.left - i.right) * scale;
        shortSide = b.height * scale;
    } else {
        longSide = (b.height - i.top - i.bottom) * scale;
        shortSide = b.width * scale;
    }
    NSInteger lw = ((NSInteger)floor(longSide)) & ~1;
    NSInteger sh = ((NSInteger)floor(shortSide)) & ~1;
    return CGSizeMake(MIN(lw, 4096), MIN(sh, 4096));
}

+ (NSInteger)maximumFramesPerSecondForWindow:(UIWindow *)window {
    UIScreen *screen = window.windowScene.screen;
    NSInteger fps = screen != nil ? screen.maximumFramesPerSecond : 60;
    return fps > 0 ? fps : 60;
}

+ (BOOL)hevcSupported { return VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC); }
+ (BOOL)av1Supported { return VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1); }
+ (BOOL)hdrSupported {
    return [self hevcSupported] && AVPlayer.eligibleForHDRPlayback;
}

+ (StreamConfiguration *)streamConfigurationForApp:(TemporaryApp *)app window:(UIWindow *)window {
    StreamConfiguration *config = [[StreamConfiguration alloc] init];
    config.host = app.host.activeAddress;
    config.httpsPort = app.host.httpsPort;
    config.appID = app.id;
    config.appName = app.name;
    config.serverCert = app.host.serverCert;

    MLSettings *settings = [MLSettings current];
    TemporarySettings *raw = [[[DataManager alloc] init] getSettings];

    config.frameRate = (int)settings.framerate;
    NSInteger maxFps = [self maximumFramesPerSecondForWindow:window];
    if (config.frameRate > maxFps) {
        Log(LOG_W, @"Clamping FPS to maximum refresh rate: %d", (int)maxFps);
        config.frameRate = (int)maxFps;
    }

    if (settings.resolutionMode == 1 || settings.resolutionMode == 2) {
        CGSize native = settings.resolutionMode == 2 ? [self safeAreaStreamSizeForWindow:window] : [self nativeStreamSizeForWindow:window];
        config.width = (int)native.width;
        config.height = (int)native.height;
        Log(LOG_I, @"Matching display resolution: %dx%d", config.width, config.height);
    } else {
        config.width = (int)settings.width;
        config.height = (int)settings.height;
    }

    config.bitRate = settings.automaticBitrate
        ? (int)[MLSettings defaultBitrateForWidth:config.width height:config.height fps:config.frameRate]
        : (int)settings.bitrate;
    config.optimizeGameSettings = settings.optimizeGames;
    config.playAudioOnPC = settings.playAudioOnPC;
    config.useFramePacing = settings.useFramePacing;
    config.swapABXYButtons = settings.swapABXYButtons;

    // multiController must be set before calling getConnectedGamepadMask
    config.multiController = settings.multiController;
    config.gamepadMask = [ControllerSupport getConnectedGamepadMask:config];

    int physicalOutputChannels = (int)[AVAudioSession sharedInstance].maximumOutputNumberOfChannels;
    int numberOfChannels = MIN([raw.audioConfig intValue], physicalOutputChannels);
    if (numberOfChannels >= 8) {
        config.audioConfiguration = AUDIO_CONFIGURATION_71_SURROUND;
    } else if (numberOfChannels >= 6) {
        config.audioConfiguration = AUDIO_CONFIGURATION_51_SURROUND;
    } else {
        config.audioConfiguration = AUDIO_CONFIGURATION_STEREO;
    }

    config.serverCodecModeSupport = app.host.serverCodecModeSupport;

    switch (raw.preferredCodec) {
        case CODEC_PREF_AV1:
            if (VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)) {
                config.supportedVideoFormats |= VIDEO_FORMAT_AV1_MAIN8;
            }
            // Fall-through
        case CODEC_PREF_AUTO:
        case CODEC_PREF_HEVC:
            if (VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) {
                config.supportedVideoFormats |= VIDEO_FORMAT_H265;
            }
            // Fall-through
        case CODEC_PREF_H264:
            config.supportedVideoFormats |= VIDEO_FORMAT_H264;
            break;
    }

    if ((config.width > 4096 || config.height > 4096 || raw.enableHdr) && VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) {
        config.supportedVideoFormats |= VIDEO_FORMAT_H265;
        if (raw.enableHdr && AVPlayer.eligibleForHDRPlayback) {
            config.supportedVideoFormats |= VIDEO_FORMAT_H265_MAIN10;
        }
    }

    if ((config.supportedVideoFormats & VIDEO_FORMAT_MASK_AV1) && raw.enableHdr &&
        VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) && AVPlayer.eligibleForHDRPlayback) {
        config.supportedVideoFormats |= VIDEO_FORMAT_AV1_MAIN10;
    }

    return config;
}

+ (UIViewController *)streamViewControllerWithConfiguration:(StreamConfiguration *)config {
    StreamFrameViewController *vc = [[StreamFrameViewController alloc] init];
    vc.streamConfig = config;
    vc.modalPresentationStyle = UIModalPresentationFullScreen;
    vc.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    return vc;
}

+ (UIViewController *)previewStreamViewControllerWithWidth:(int)width height:(int)height appName:(NSString *)appName {
    StreamConfiguration *config = [[StreamConfiguration alloc] init];
    config.width = width;
    config.height = height;
    config.frameRate = 60;
    config.appName = appName;
    StreamFrameViewController *vc = (StreamFrameViewController *)[self streamViewControllerWithConfiguration:config];
#if DEBUG
    vc.previewMode = YES;
#endif
    return vc;
}

+ (UIImage *)decodedBoxArtForApp:(TemporaryApp *)app {
    NSData *imageData = [NSData dataWithContentsOfFile:[AppAssetManager boxArtPathForApp:app]];
    if (imageData == nil) {
        return nil;
    }
    UIImage *image = [UIImage imageWithData:imageData];
    // Decode now so scrolling the grid never decodes on the main thread.
    return [image imageByPreparingForDisplay] ?: image;
}

+ (NSString *)runNetworkTest {
    unsigned int result = LiTestClientConnectivity(CONN_TEST_SERVER, 443, ML_PORT_FLAG_ALL);
    if (result == 0) {
        return @"This network does not appear to be blocking Moonlight. If you still have trouble connecting, check your PC's firewall settings.";
    } else if (result == ML_TEST_RESULT_INCONCLUSIVE) {
        return @"The network test could not be performed because none of Moonlight's connection testing servers were reachable. Check your Internet connection or try again later.";
    } else {
        char blockedPorts[512];
        LiStringifyPortFlags(result, "\n", blockedPorts, sizeof(blockedPorts));
        return [NSString stringWithFormat:@"Your current network connection seems to be blocking Moonlight. Streaming may not work while connected to this network.\n\nThe following network ports were blocked:\n%s", blockedPorts];
    }
}

+ (BOOL)hostPortsBlocked {
    unsigned int result = LiTestClientConnectivity(CONN_TEST_SERVER, 443, ML_PORT_FLAG_TCP_47984 | ML_PORT_FLAG_TCP_47989);
    return result != ML_TEST_RESULT_INCONCLUSIVE && result != 0;
}

+ (NSString *)appVersion {
    NSDictionary *info = [NSBundle mainBundle].infoDictionary;
    return [NSString stringWithFormat:@"%@ (%@)", info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"]];
}

#pragma mark Host operations

static NSError *MLError(NSString *message) {
    return [NSError errorWithDomain:@"MoonlightDuo" code:1
                           userInfo:@{NSLocalizedDescriptionKey: message.length > 0 ? message : @"The PC didn't respond."}];
}

+ (BOOL)refreshServerInfoForHost:(TemporaryHost *)host error:(NSError **)error {
    HttpManager *hMan = [[HttpManager alloc] initWithHost:host];
    ServerInfoResponse *serverInfoResp = [[ServerInfoResponse alloc] init];
    [hMan executeRequestSynchronously:[HttpRequest requestForResponse:serverInfoResp
                                                       withUrlRequest:[hMan newServerInfoRequest:false]
                                                        fallbackError:401
                                                      fallbackRequest:[hMan newHttpServerInfoRequest]]];
    if (![serverInfoResp isStatusOk]) {
        Log(LOG_W, @"Failed to get server info: %@", serverInfoResp.statusMessage);
        if (error) *error = MLError(serverInfoResp.statusMessage);
        return NO;
    }
    [serverInfoResp populateHost:host];
    return YES;
}

+ (NSArray<TemporaryApp *> *)fetchAppListForHost:(TemporaryHost *)host error:(NSError **)error {
    AppListResponse *resp = [ConnectionHelper getAppListForHost:host];
    if (![resp isStatusOk] || [resp getAppList] == nil) {
        Log(LOG_W, @"Failed to get applist: %@", resp.statusMessage);
        if (error) *error = MLError(resp.statusMessage);
        return nil;
    }
    return [[resp getAppList] allObjects];
}

+ (BOOL)quitRunningAppOnHost:(TemporaryHost *)host error:(NSError **)error {
    HttpManager *hMan = [[HttpManager alloc] initWithHost:host];
    HttpResponse *quitResponse = [[HttpResponse alloc] init];
    [hMan executeRequestSynchronously:[HttpRequest requestForResponse:quitResponse withUrlRequest:[hMan newQuitAppRequest]]];
    if (quitResponse.statusCode == 200) {
        ServerInfoResponse *serverInfoResp = [[ServerInfoResponse alloc] init];
        [hMan executeRequestSynchronously:[HttpRequest requestForResponse:serverInfoResp
                                                           withUrlRequest:[hMan newServerInfoRequest:false]
                                                            fallbackError:401
                                                          fallbackRequest:[hMan newHttpServerInfoRequest]]];
        if (![serverInfoResp isStatusOk] || [[serverInfoResp getStringTag:@"state"] hasSuffix:@"_SERVER_BUSY"]) {
            // Newer GFE reports success even when another client's app didn't quit.
            quitResponse.statusCode = 599;
        }
        else {
            [serverInfoResp populateHost:host];
        }
    }
    if (quitResponse.statusCode != 200) {
        if (error) *error = MLError(@"Failed to quit the app. If another device started it, quit it from that device.");
        return NO;
    }
    host.currentGame = @"0";
    return YES;
}

+ (void)pairWithHost:(TemporaryHost *)host clientCert:(NSData *)clientCert callback:(id)callback queue:(NSOperationQueue *)queue {
    HttpManager *hMan = [[HttpManager alloc] initWithHost:host];
    PairManager *pMan = [[PairManager alloc] initWithManager:hMan clientCert:clientCert callback:(id<PairCallback>)callback];
    [queue addOperation:pMan];
}

#pragma mark Host bookkeeping

+ (void)mergeAppList:(NSArray<TemporaryApp *> *)newList intoHost:(TemporaryHost *)host {
    DataManager *database = [[DataManager alloc] init];
    NSMutableSet *merged = [NSMutableSet setWithSet:host.appList];

    for (TemporaryApp *app in newList) {
        BOOL known = NO;
        for (TemporaryApp *saved in merged) {
            if ([app.id isEqualToString:saved.id]) {
                saved.name = app.name;
                saved.hdrSupported = app.hdrSupported;
                // Local "hidden" state wins
                known = YES;
                break;
            }
        }
        if (!known) {
            app.host = host;
            [merged addObject:app];
        }
    }

    NSMutableSet<NSString *> *liveIds = [NSMutableSet set];
    for (TemporaryApp *app in newList) {
        if (app.id) [liveIds addObject:app.id];
    }
    for (TemporaryApp *app in [merged allObjects]) {
        if (![liveIds containsObject:app.id]) {
            [merged removeObject:app];
            // Remove the record too, or appList no longer matches the database
            [database removeApp:app];
        }
    }

    host.appList = merged;
    [database updateAppsForExistingHost:host];
}

+ (void)saveApp:(TemporaryApp *)app {
    TemporaryHost *host = app.host;
    if (host == nil) return;
    DataManager *database = [[DataManager alloc] init];
    NSMutableSet *apps = [NSMutableSet setWithSet:host.appList];
    for (TemporaryApp *saved in apps) {
        if ([saved.id isEqualToString:app.id]) {
            saved.name = app.name;
            saved.hdrSupported = app.hdrSupported;
            saved.hidden = app.hidden;
            host.appList = apps;
            [database updateAppsForExistingHost:host];
            return;
        }
    }
}

+ (NSArray<TemporaryHost *> *)loadSavedHosts {
    NSArray<TemporaryHost *> *hosts = [[[DataManager alloc] init] getHosts];
    for (TemporaryHost *host in hosts) {
        if (host.activeAddress == nil) host.activeAddress = host.localAddress;
        if (host.activeAddress == nil) host.activeAddress = host.externalAddress;
        if (host.activeAddress == nil) host.activeAddress = host.address;
        if (host.activeAddress == nil) host.activeAddress = host.ipv6Address;
    }
    return hosts;
}

#if DEBUG
+ (StreamConfiguration *)legacyStreamConfigurationForApp:(TemporaryApp *)app {
    Class legacy = NSClassFromString(@"MainFrameViewController");
    id vc = [[legacy alloc] init];
    SEL prepare = NSSelectorFromString(@"prepareToStreamApp:");
    if (vc == nil || ![vc respondsToSelector:prepare]) {
        return nil;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [vc performSelector:prepare withObject:app];
#pragma clang diagnostic pop
    return [vc valueForKey:@"_streamConfig"];
}
#endif

#pragma mark Reserved regions

+ (NSString *)simulatedFold {
#if DEBUG
    NSString *fold = [[NSUserDefaults standardUserDefaults] stringForKey:@"MLSimulateFold"];
    if ([fold isEqualToString:@"horizontal"] || [fold isEqualToString:@"vertical"]) {
        return fold;
    }
#endif
    return nil;
}

+ (NSArray<NSValue *> *)simulatedDivisionInView:(UIView *)view {
    NSString *fold = [self simulatedFold];
    UIView *reference = view.window;
    // In the DEBUG layout harness the "display" is the harness root, not the window.
    for (UIView *v = view; v != nil; v = v.superview) {
        if ([v.accessibilityIdentifier isEqualToString:@"MLHarnessRoot"]) { reference = v; break; }
    }
    if (fold == nil || reference == nil) {
        return @[];
    }
    CGRect wb = reference.bounds;
    // Only the large inner display folds.
    if (MIN(wb.size.width, wb.size.height) < 560) {
        return @[];
    }
    const CGFloat band = 32;
    CGRect r;
    if ([fold isEqualToString:@"horizontal"]) {
        // Laptop / tabletop: the hinge runs across the display.
        if (wb.size.height < wb.size.width) return @[];
        r = CGRectMake(0, CGRectGetMidY(wb) - band / 2, wb.size.width, band);
    } else {
        // Book: the hinge runs down the middle of the landscape display.
        if (wb.size.width < wb.size.height) return @[];
        r = CGRectMake(CGRectGetMidX(wb) - band / 2, 0, band, wb.size.height);
    }
    return @[[NSValue valueWithCGRect:[view convertRect:r fromView:reference]]];
}

+ (NSArray<NSValue *> *)activeRectsOfDivisionKind:(BOOL)division inView:(UIView *)view {
    NSMutableArray<NSValue *> *rects = [NSMutableArray array];
    if (@available(iOS 27.1, tvOS 27.1, *)) {
        UIViewReservedRegionKind *kind = division ? [UIViewReservedRegionKind divisionRegionKind]
                                                  : [UIViewReservedRegionKind occlusionRegionKind];
        for (UIViewReservedRegion *region in [view reservedRegionsOfKind:kind]) {
            if (region.isActive && !CGRectIsEmpty(region.frame)) {
                [rects addObject:[NSValue valueWithCGRect:region.frame]];
            }
        }
    }
    if (division && rects.count == 0) {
        [rects addObjectsFromArray:[self simulatedDivisionInView:view]];
    }
    return rects;
}

+ (NSArray<NSValue *> *)activeDivisionRectsInView:(UIView *)view {
    return [self activeRectsOfDivisionKind:YES inView:view];
}

+ (NSArray<NSValue *> *)activeOcclusionRectsInView:(UIView *)view {
    return [self activeRectsOfDivisionKind:NO inView:view];
}

#if DEBUG
+ (void)debugAppend:(NSString *)line toFile:(NSString *)name {
    NSURL *docs = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *url = [docs URLByAppendingPathComponent:name];
    NSISO8601DateFormatter *f = [NSISO8601DateFormatter new];
    NSData *data = [[NSString stringWithFormat:@"%@  %@\n", [f stringFromDate:NSDate.date], line] dataUsingEncoding:NSUTF8StringEncoding];
    @synchronized (self) {
        NSFileHandle *h = [NSFileHandle fileHandleForWritingToURL:url error:nil];
        if (h) { [h seekToEndOfFile]; [h writeData:data]; [h closeFile]; }
        else { [data writeToURL:url atomically:YES]; }
    }
    NSLog(@"MLDebug %@", line);
}
#endif

@end
