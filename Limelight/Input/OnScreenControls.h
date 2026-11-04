//
//  OnScreenControls.h
//  Moonlight
//
//  Created by Diego Waxemberg on 12/28/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import <Foundation/Foundation.h>

@class ControllerSupport;
@class StreamConfiguration;

@interface OnScreenControls : NSObject

typedef NS_ENUM(NSInteger, OnScreenControlsLevel) {
    OnScreenControlsLevelOff,
    OnScreenControlsLevelAuto,
    OnScreenControlsLevelSimple,
    OnScreenControlsLevelFull,
    
    // Internal levels selected by ControllerSupport
    OnScreenControlsLevelAutoGCGamepad,
    OnScreenControlsLevelAutoGCExtendedGamepad,
    OnScreenControlsLevelAutoGCExtendedGamepadWithStickButtons
};

- (id) initWithView:(UIView*)view controllerSup:(ControllerSupport*)controllerSupport streamConfig:(StreamConfiguration*)streamConfig;
- (BOOL) handleTouchDownEvent:(NSSet*)touches;
- (BOOL) handleTouchUpEvent:(NSSet*)touches;
- (BOOL) handleTouchMovedEvent:(NSSet*)touches;
- (void) setLevel:(OnScreenControlsLevel)level;
- (OnScreenControlsLevel) getLevel;
- (void) show;
/// Lays the controls out inside `area` (view coordinates), nudging them clear of
/// `avoidRects` (the fold and camera). `largeLayout` keeps them in the lower half
/// with the sticks near the sides, as on iPad and the iPhone Duo inner display.
- (void) updateLayoutWithControlArea:(CGRect)area largeLayout:(BOOL)largeLayout avoidRects:(NSArray<NSValue*>*)avoidRects;

@end
