//
//  MLDuoBridge.h
//  Moonlight Duo
//
//  Objective-C surface the SwiftUI shell uses: settings, stream setup,
//  box art, network test and reserved-region (fold/camera) helpers.
//

#import <UIKit/UIKit.h>

@class TemporaryApp;
@class TemporaryHost;
@class StreamConfiguration;

NS_ASSUME_NONNULL_BEGIN

/// Posted on the main thread after a stream view controller is dismissed.
FOUNDATION_EXPORT NSNotificationName const MLStreamDidEndNotification;

@interface MLSettings : NSObject
@property (nonatomic) NSInteger bitrate;          // kbps
@property (nonatomic) NSInteger framerate;
@property (nonatomic) NSInteger width;
@property (nonatomic) NSInteger height;
@property (nonatomic) NSInteger onscreenControls; // 0 off, 1 auto, 2 simple, 3 full
@property (nonatomic) NSInteger codec;            // 0 auto, 1 H.264, 2 HEVC, 3 AV1
@property (nonatomic) BOOL optimizeGames;
@property (nonatomic) BOOL multiController;
@property (nonatomic) BOOL swapABXYButtons;
@property (nonatomic) BOOL playAudioOnPC;
@property (nonatomic) BOOL useFramePacing;
@property (nonatomic) BOOL enableHdr;
@property (nonatomic) BOOL btMouseSupport;
@property (nonatomic) BOOL absoluteTouchMode;
@property (nonatomic) BOOL statsOverlay;
/// 0: the fixed width × height above; 1: the full native resolution of the display the
/// stream starts on; 2: that display's safe area (the old "Safe Area" choice).
@property (nonatomic) NSInteger resolutionMode;
/// Light haptic tap on each touch-gamepad press.
@property (nonatomic) BOOL padHaptics;
/// Derive the bitrate from resolution and frame rate at stream start.
@property (nonatomic) BOOL automaticBitrate;
/// Put the video above the fold (tabletop) or on top (portrait) with controls below.
@property (nonatomic) BOOL splitLayout;

+ (MLSettings *)current;
- (void)save;
+ (NSInteger)defaultBitrateForWidth:(NSInteger)width height:(NSInteger)height fps:(NSInteger)fps;
@end

@interface MLDuoBridge : NSObject

/// Landscape-normalised pixel size of the window, rounded down to even numbers.
+ (CGSize)nativeStreamSizeForWindow:(nullable UIWindow *)window;
/// Like the original "Safe Area" resolution: the long side minus the safe-area insets along it.
+ (CGSize)safeAreaStreamSizeForWindow:(nullable UIWindow *)window;
+ (NSInteger)maximumFramesPerSecondForWindow:(nullable UIWindow *)window;
+ (BOOL)hevcSupported;
+ (BOOL)av1Supported;
+ (BOOL)hdrSupported;

+ (StreamConfiguration *)streamConfigurationForApp:(TemporaryApp *)app window:(nullable UIWindow *)window;
+ (UIViewController *)streamViewControllerWithConfiguration:(StreamConfiguration *)config;
+ (nullable UIImage *)decodedBoxArtForApp:(TemporaryApp *)app;

/// Blocking: runs Moonlight's port test and returns a user-facing message.
+ (NSString *)runNetworkTest;
/// Blocking: YES when the network blocks the ports needed to add a host.
+ (BOOL)hostPortsBlocked;
+ (NSString *)appVersion;

#pragma mark Host operations (blocking; call off the main thread)

/// GET /serverinfo with the HTTP fallback, then copies the result into the host.
+ (BOOL)refreshServerInfoForHost:(TemporaryHost *)host error:(NSError **)error;
+ (nullable NSArray<TemporaryApp *> *)fetchAppListForHost:(TemporaryHost *)host error:(NSError **)error;
/// Quits the running app; fails when another device started it.
+ (BOOL)quitRunningAppOnHost:(TemporaryHost *)host error:(NSError **)error;
/// Starts pairing on `queue`; progress arrives on the PairCallback.
+ (void)pairWithHost:(TemporaryHost *)host clientCert:(NSData *)clientCert callback:(id)callback queue:(NSOperationQueue *)queue;

#pragma mark Host bookkeeping (main thread)

/// Merges a fresh app list into the host and the database, keeping local "hidden" flags.
+ (void)mergeAppList:(NSArray<TemporaryApp *> *)apps intoHost:(TemporaryHost *)host;
/// Saves one app's name / HDR / hidden flags.
+ (void)saveApp:(TemporaryApp *)app;
+ (NSArray<TemporaryHost *> *)loadSavedHosts;

/// Active fold (division) and camera (occlusion) rects in the view's coordinates.
+ (NSArray<NSValue *> *)activeDivisionRectsInView:(UIView *)view;
+ (NSArray<NSValue *> *)activeOcclusionRectsInView:(UIView *)view;
/// DEBUG only: "horizontal" or "vertical" from -MLSimulateFold, otherwise nil.
+ (nullable NSString *)simulatedFold;

#if DEBUG
/// The stream configuration the original MainFrameViewController builds for this app from
/// the same stored settings (its -prepareToStreamApp:), for the settings self-test.
+ (nullable StreamConfiguration *)legacyStreamConfigurationForApp:(TemporaryApp *)app;
#endif

/// DEBUG only (returns a normal stream controller in Release): a stream view with
/// a test-pattern video layer and full on-screen controls, no network.
+ (UIViewController *)previewStreamViewControllerWithWidth:(int)width height:(int)height appName:(NSString *)appName;

#if DEBUG
/// Appends a timestamped line to Documents/<name> (test hooks).
+ (void)debugAppend:(NSString *)line toFile:(NSString *)name;
#endif

@end

NS_ASSUME_NONNULL_END
