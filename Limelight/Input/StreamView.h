//
//  StreamView.h
//  Moonlight
//
//  Created by Cameron Gutman on 10/19/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "ControllerSupport.h"
#import "OnScreenControls.h"
#import "Moonlight-Swift.h"
#import "StreamConfiguration.h"

@protocol UserInteractionDelegate <NSObject>

- (void) userInteractionBegan;
- (void) userInteractionEnded;

@end

#if TARGET_OS_TV
@interface StreamView : UIView <X1KitMouseDelegate, UITextFieldDelegate>
#else
@interface StreamView : UIView <X1KitMouseDelegate, UITextFieldDelegate, UIPointerInteractionDelegate>
#endif

- (void) setupStreamView:(ControllerSupport*)controllerSupport
     interactionDelegate:(id<UserInteractionDelegate>)interactionDelegate
                  config:(StreamConfiguration*)streamConfig;
- (void) showOnScreenControls;
- (OnScreenControlsLevel) getCurrentOscState;
- (void) setOnScreenControlsLevel:(OnScreenControlsLevel)level;

/// Where the video is drawn, in this view's coordinates. Touch and pointer input
/// map through this rect. It moves above the fold in tabletop pose and to the top
/// in portrait so the on-screen controls get their own area.
@property (nonatomic, readonly) CGRect videoRect;

/// DEBUG harness: a test-pattern layer that stands in for the decoder's layer.
- (void) installPreviewVideoLayer;

#if !TARGET_OS_TV
- (void) updateCursorLocation:(CGPoint)location isMouse:(BOOL)isMouse;
#endif

#if DEBUG
- (void)debugRunPadProbe;
#endif

@end
