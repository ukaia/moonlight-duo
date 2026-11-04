//
//  MLTouchGamepad.h
//  Moonlight Duo
//
//  The nxnative touch gamepad (dm/ios/Sources/DmGamepad.m), ported to Moonlight:
//  same shapes, positions, sizes, touch ownership and 2D / 3D / Tap layouts, sending
//  Xbox-style input through ControllerSupport's on-screen-controls controller.
//

#import <UIKit/UIKit.h>

@class ControllerSupport;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MLPadLayout) {
    MLPadLayout2D = 0,   // shoulders, Select / Start, left stick, face buttons
    MLPadLayout3D = 1,   // 2D plus D-pad, L3 / R3 and an undrawn right stick (swipe in the right third)
    MLPadLayoutTap = 2,  // only the layout button: every other touch drives the mouse
};

@interface MLTouchGamepad : UIView

/// `settingsLevel` is the On-Screen Controls setting (1 auto, 2 simple, 3 full). In auto
/// the gamepad hides while a physical controller is connected, as in nxnative.
- (instancetype)initWithControllerSupport:(ControllerSupport *)controllerSupport
                                 swapABXY:(BOOL)swapABXY
                            settingsLevel:(NSInteger)settingsLevel NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(CGRect)frame NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/// Shows the controls (the stream calls this once the connection is up).
@property (nonatomic) BOOL active;
/// YES while the gamepad wants screen space (active and not hidden for a physical controller).
@property (nonatomic, readonly) BOOL wantsArea;
/// YES when the gamepad has an area of its own (portrait / tabletop) instead of sitting over the video.
@property (nonatomic) BOOL dedicatedArea;
/// Reserved regions (fold, camera) in this view's coordinates; controls move clear of them.
@property (nonatomic, copy) NSArray<NSValue *> *avoidRects;
@property (nonatomic, readonly) MLPadLayout layout;

/// Releases every key and stick (sends a neutral state).
- (void)reset;

#if DEBUG
/// Presses every control with synthetic touches and checks what reaches Moonlight's
/// controller state, then checks that no two controls overlap at the iPhone Duo sizes.
+ (NSArray<NSString *> *)debugSelfTest;
/// Live-stream probe: presses A, pushes the left stick right, then D-pad up through the real
/// touch handlers, logging the controller state Moonlight sends (Documents/stream-status.txt).
- (void)debugPressSequence;
#endif

@end

/// NSUserDefaults key holding the last chosen MLPadLayout.
FOUNDATION_EXPORT NSString *const MLPadLayoutDefaultsKey;
/// NSUserDefaults key: light haptic tap on each press (default YES).
FOUNDATION_EXPORT NSString *const MLPadHapticsDefaultsKey;

NS_ASSUME_NONNULL_END
