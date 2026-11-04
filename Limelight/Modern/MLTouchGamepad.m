//
//  MLTouchGamepad.m
//  Moonlight Duo
//
//  Portions derived from nxnative (https://github.com/seedds/nxnative), Copyright (c) 2026 seedds,
//  used under the MIT License; see THIRD_PARTY_NOTICES.md.
//
//  Port of nxnative's virtual gamepad (seedds/nxnative, dm/ios/Sources/DmGamepad.m):
//    2D: top corners LT above LB (one column), RT above RB, teardrops with the tip toward
//        the screen corner; Back and Start side by side at the top centre with the layout
//        button between them; the left stick in the bottom-left corner (fixed ring, tilt from
//        the ring centre, small dead zone); the face diamond in the bottom-right corner,
//        sliding a finger between keys switches keys.
//    3D: everything in 2D plus a D-pad (inward of and below the left stick, 8-way), L3 / R3
//        (small round keys in the top row) and a right stick that is not drawn: a touch that
//        lands in the right third on no control holds it, centred where it lands and dragged
//        along once the finger passes the stick radius.
//    Tap: only the layout button; every other touch goes to the stream (mouse / touch).
//  Touch-down ownership: locked keys first, then whichever of the diamond, the D-pad and the
//  left stick has the smallest distance / grab radius, then (3D) the right stick. Touches no
//  control takes fall through to the stream view (pointInside: says NO).
//  Face keys go by position, Xbox style (bottom A, right B, left X, top Y); Swap A/B and X/Y
//  gives the Nintendo positions nxnative uses (right A, bottom B, top X, left Y).
//  Additions for Moonlight Duo: a portrait arrangement (D-pad above the left stick), sizing
//  for a dedicated control area (iPhone Duo tabletop / portrait split layout), and the top
//  centre keys moving clear of an active fold.
//

#import "MLTouchGamepad.h"
#import "ControllerSupport.h"
#import "Controller.h"
#import "MLDuoBridge.h"

@import GameController;
@import CoreText;

#include <Limelight.h>

NSString *const MLPadLayoutDefaultsKey = @"MLPadLayout";
NSString *const MLPadHapticsDefaultsKey = @"MLPadHaptics";

enum { B_A = 0, B_B, B_X, B_Y, B_LS, B_RS, B_L, B_R, B_ZL, B_ZR, B_PLUS, B_MINUS, B_LEFT, B_UP, B_RIGHT, B_DOWN, B_N };
// B_A..B_Y are positions as in nxnative: right, bottom, top, left.
enum { C_NONE = 0, C_STICK, C_DPAD, C_FACE, C_BTN, C_SWAP };

// ---- Layout constants (in u; x measured from the outer edge, the right half mirrors) — nxnative's values ----
static const CGFloat
    K_ZL_X = 44, K_ZL_Y = 40, K_ZL_R = 26,
    K_L_X = 44, K_L_Y = 108, K_L_R = 24,
    K_DROP_TIP = 1.45,
    K_CORNER_IN = 0.5,
    K_FACE_X = 81, K_PAD_Y = 82,
    K_FACE_GAP = 50, K_FACE_R = 27,
    K_PILL_DX = 52, K_PILL_Y = 22, K_PILL_W = 50, K_PILL_H = 28,
    K_SWAP_R = 15,
    K_STICK_X = 81, K_STICK_R = 77, K_KNOB_R = 30,
    K_STICK_GRAB = 1.4,
    K_FULL = 0.8,
    K_DEAD = 0.1,
    K_LOW_X = 231, K_LOW_Y = 64,
    K_DPAD_R = 48, K_ARM_W = 17, K_ARM_IN = 11,
    K_DPAD_GRAB = 1.3,
    K_RSTICK_R = 60,
    K_RSWIPE = 1.0 / 3,
    K_CLICK_X = 102, K_CLICK_R = 17;
static const int k_btns[] = {B_ZL, B_L, B_ZR, B_R, B_MINUS, B_PLUS, B_LS, B_RS};

static UIColor *k_idle, *k_on, *k_line, *k_ringFill, *k_text, *k_textOn;

static BOOL fullOnly(int b) { return b == B_LS || b == B_RS || b >= B_LEFT; }
static BOOL isDrop(int b) { return b == B_ZL || b == B_L || b == B_ZR || b == B_R; }
static BOOL isClick(int b) { return b == B_LS || b == B_RS; }
static CGFloat dist(CGPoint a, CGPoint b) { return hypot(a.x - b.x, a.y - b.y); }
static CGPoint side(CGRect s, int right, CGFloat dx, CGFloat y) { return CGPointMake(right ? CGRectGetMaxX(s) - dx : CGRectGetMinX(s) + dx, y); }

@implementation MLTouchGamepad {
    __weak ControllerSupport *_cs;
    Controller *_osc;
    BOOL _swapABXY;
    NSInteger _settingsLevel;

    NSMapTable<UITouch *, NSNumber *> *_owner;
    UITouch *_stick[2]; CGPoint _stickNow[2];
    CGPoint _rCentre;
    uint64_t _faceBits, _dpadBits, _btnBits;
    NSMapTable<UITouch *, NSNumber *> *_faceOf;
    CAShapeLayer *_key[B_N]; CATextLayer *_label[B_N];
    CAShapeLayer *_ring, *_knob;
    CAShapeLayer *_swap; CATextLayer *_swapLabel; BOOL _swapHeld;
    UIImpactFeedbackGenerator *_touchFeedback;
    unsigned _hapticSticks;
    BOOL _stickShown;
    BOOL _full, _tap;
    CALayer *_controls;
    BOOL _hiddenForPad;
    CGFloat _topCentreX;      // where the Back / layout / Start group is centred (moved off a fold)
    CGFloat _topGroupSplit;   // extra half-gap between Back and Start for a fold between them
    BOOL _swapOffFold;        // a fold runs through the middle of the top group: the layout button moves left of Back
}

- (instancetype)initWithControllerSupport:(ControllerSupport *)controllerSupport swapABXY:(BOOL)swapABXY settingsLevel:(NSInteger)settingsLevel {
    if ((self = [super initWithFrame:CGRectZero])) {
        _cs = controllerSupport;
        _osc = [controllerSupport getOscController];
        _swapABXY = swapABXY;
        _settingsLevel = settingsLevel;
        _avoidRects = @[];
        self.multipleTouchEnabled = YES; self.opaque = NO; self.backgroundColor = UIColor.clearColor;
        self.accessibilityIdentifier = @"MLTouchGamepad";

        NSNumber *haptics = [NSUserDefaults.standardUserDefaults objectForKey:MLPadHapticsDefaultsKey];
        if (haptics == nil || haptics.boolValue) {
            _touchFeedback = [UIImpactFeedbackGenerator feedbackGeneratorWithStyle:UIImpactFeedbackStyleLight forView:self];
            [_touchFeedback prepare];
        }
        _owner = [NSMapTable strongToStrongObjectsMapTable]; _faceOf = [NSMapTable strongToStrongObjectsMapTable];
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            k_idle = [UIColor colorWithWhite:1 alpha:0.14]; k_on = [UIColor colorWithWhite:1 alpha:0.45]; k_line = [UIColor colorWithWhite:1 alpha:0.38];
            k_ringFill = [UIColor colorWithWhite:1 alpha:0.06]; k_text = [UIColor colorWithWhite:1 alpha:0.6]; k_textOn = [UIColor colorWithWhite:0 alpha:0.7];
        });
        _controls = [CALayer layer]; [self.layer addSublayer:_controls];
        _ring = [self shapeIn:_controls]; _ring.fillColor = k_ringFill.CGColor;
        _knob = [self shapeIn:_controls];
        CAShapeLayer *inner = [CAShapeLayer layer]; inner.fillColor = nil; inner.strokeColor = k_line.CGColor; inner.lineWidth = 1.5;
        [_knob addSublayer:inner];
        for (int b = 0; b < B_N; b++) {
            _key[b] = [self shapeIn:_controls];
            NSString *name = [self nameOf:b];
            if (name) _label[b] = [self labelIn:_key[b] text:name];
        }
        _swap = [self shapeIn:_controls]; _swapLabel = [self labelIn:_swap text:@""];

        NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:MLPadLayoutDefaultsKey];
        NSInteger l = saved ? saved.integerValue : (settingsLevel == 2 ? MLPadLayout2D : MLPadLayout3D);
        _full = l == MLPadLayout3D; _tap = l == MLPadLayoutTap;
        [self applyLayout];

        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        for (NSNotificationName n in @[GCControllerDidConnectNotification, GCControllerDidDisconnectNotification,
                                       GCKeyboardDidConnectNotification, GCKeyboardDidDisconnectNotification,
                                       GCMouseDidConnectNotification, GCMouseDidDisconnectNotification]) {
            [nc addObserver:self selector:@selector(padsChanged:) name:n object:nil];
        }
        [self padsChanged:nil];
    }
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (NSString *)nameOf:(int)b {
    switch (b) {
        case B_A: return _swapABXY ? @"A" : @"B";   // right
        case B_B: return _swapABXY ? @"B" : @"A";   // bottom
        case B_X: return _swapABXY ? @"X" : @"Y";   // top
        case B_Y: return _swapABXY ? @"Y" : @"X";   // left
        case B_LS: return @"L3";
        case B_RS: return @"R3";
        case B_L: return @"LB";
        case B_R: return @"RB";
        case B_ZL: return @"LT";
        case B_ZR: return @"RT";
        case B_PLUS: return @"Start";
        case B_MINUS: return @"Back";
        default: return nil;   // the D-pad arms carry no label
    }
}

- (int)flagOf:(int)b {
    switch (b) {
        case B_A: return _swapABXY ? A_FLAG : B_FLAG;
        case B_B: return _swapABXY ? B_FLAG : A_FLAG;
        case B_X: return _swapABXY ? X_FLAG : Y_FLAG;
        case B_Y: return _swapABXY ? Y_FLAG : X_FLAG;
        case B_LS: return LS_CLK_FLAG;
        case B_RS: return RS_CLK_FLAG;
        case B_L: return LB_FLAG;
        case B_R: return RB_FLAG;
        case B_PLUS: return PLAY_FLAG;
        case B_MINUS: return BACK_FLAG;
        case B_LEFT: return LEFT_FLAG;
        case B_UP: return UP_FLAG;
        case B_RIGHT: return RIGHT_FLAG;
        case B_DOWN: return DOWN_FLAG;
        default: return 0;   // LT / RT are triggers
    }
}

- (CAShapeLayer *)shapeIn:(CALayer *)parent {
    CAShapeLayer *l = [CAShapeLayer layer];
    l.fillColor = k_idle.CGColor; l.strokeColor = k_line.CGColor; l.lineWidth = 1.5;
    l.shadowColor = UIColor.blackColor.CGColor; l.shadowOpacity = 0.2; l.shadowRadius = 3; l.shadowOffset = CGSizeMake(0, 1);
    [parent addSublayer:l]; return l;
}

- (CATextLayer *)labelIn:(CALayer *)parent text:(NSString *)s {
    CATextLayer *t = [CATextLayer layer];
    t.string = s; t.alignmentMode = kCAAlignmentCenter; t.foregroundColor = k_text.CGColor;
    t.contentsScale = self.traitCollection.displayScale > 0 ? self.traitCollection.displayScale : 3;
    [parent addSublayer:t]; return t;
}

#pragma mark - State

- (MLPadLayout)layout { return _tap ? MLPadLayoutTap : (_full ? MLPadLayout3D : MLPadLayout2D); }
- (BOOL)wantsArea { return _active && !_hiddenForPad; }

- (void)setActive:(BOOL)active {
    _active = active;
    [self updateVisibility];
}

- (void)setDedicatedArea:(BOOL)dedicatedArea {
    if (_dedicatedArea == dedicatedArea) return;
    _dedicatedArea = dedicatedArea;
    [self setNeedsLayout];
}

- (void)setAvoidRects:(NSArray<NSValue *> *)avoidRects {
    if ([_avoidRects isEqualToArray:avoidRects]) return;
    _avoidRects = [avoidRects copy];
    [self setNeedsLayout];
}

- (void)updateVisibility {
    BOOL show = _active && !_hiddenForPad;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _controls.hidden = !show;
    [CATransaction commit];
    if (!show) [self reset];
    // The stream view gives the gamepad its own area in portrait / tabletop: lay out again.
    [self.superview setNeedsLayout];
}

- (void)applyLayout {
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) _key[b].hidden = _tap || (fullOnly(b) && !_full);
    _ring.hidden = _knob.hidden = _tap;
    _swapLabel.string = _tap ? @"Tap" : _full ? @"3D" : @"2D";
    [CATransaction commit];
}

- (void)nextLayout {   // 2D → 3D → Tap → 2D; release every touch first so no key stays held
    MLPadLayout l = _tap ? MLPadLayout2D : (_full ? MLPadLayoutTap : MLPadLayout3D);
    [self reset];
    _full = l == MLPadLayout3D; _tap = l == MLPadLayoutTap;
    [NSUserDefaults.standardUserDefaults setInteger:l forKey:MLPadLayoutDefaultsKey];
    [self applyLayout]; [self setNeedsLayout];
}

#pragma mark - Geometry (points, inside the safe area)

- (BOOL)tall { return self.bounds.size.width < self.bounds.size.height * 1.3; }
- (CGFloat)u {
    CGSize s = self.bounds.size;
    CGFloat byHeight = s.height / (_dedicatedArea ? 330.0 : 430.0);
    CGFloat byWidth = s.width / (self.tall ? 500.0 : (_dedicatedArea ? 600.0 : 700.0));
    return MAX(0.5, MIN(MIN(byHeight, byWidth), 1.3));
}
- (CGRect)safe { return UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets); }
- (CGRect)corner { UIEdgeInsets i = self.safeAreaInsets; i.left *= K_CORNER_IN; i.right *= K_CORNER_IN; return UIEdgeInsetsInsetRect(self.bounds, i); }
- (CGPoint)faceCenter { CGRect s = self.corner; CGFloat u = self.u; return side(s, 1, K_FACE_X * u, CGRectGetMaxY(s) - K_PAD_Y * u); }
- (CGFloat)faceGap { return K_FACE_GAP * self.u; }
- (CGFloat)faceR { return K_FACE_R * self.u; }
- (CGPoint)facePos:(int)b { CGPoint c = self.faceCenter; CGFloat g = self.faceGap;
    switch (b) { case B_A: return CGPointMake(c.x + g, c.y); case B_B: return CGPointMake(c.x, c.y + g); case B_X: return CGPointMake(c.x, c.y - g); default: return CGPointMake(c.x - g, c.y); } }
- (CGPoint)stickHome { CGRect s = self.corner; return side(s, 0, K_STICK_X * self.u, CGRectGetMaxY(s) - K_PAD_Y * self.u); }
- (CGPoint)stickCentre:(int)i { return i ? _rCentre : self.stickHome; }
- (CGFloat)stickR:(int)i { return (i ? K_RSTICK_R : K_STICK_R) * self.u; }
- (BOOL)inRightArea:(CGPoint)p { CGRect b = self.bounds; return p.x >= CGRectGetMaxX(b) - b.size.width * K_RSWIPE; }
- (CGPoint)dpadCenter {
    CGRect s = self.corner; CGFloat u = self.u;
    if (self.tall) {   // portrait: above the left stick, where a narrow screen has room
        CGPoint h = self.stickHome;
        return CGPointMake(h.x, h.y - (K_STICK_R + K_DPAD_R + 14) * u);
    }
    return side(s, 0, K_LOW_X * u, CGRectGetMaxY(s) - K_LOW_Y * u);
}
- (CGFloat)dpadR { return K_DPAD_R * self.u; }
- (CGPoint)dropCenter:(int)b { CGRect s = self.safe; CGFloat u = self.u; BOOL z = b == B_ZL || b == B_ZR;
    return side(s, b == B_ZR || b == B_R, (z ? K_ZL_X : K_L_X) * u, CGRectGetMinY(s) + (z ? K_ZL_Y : K_L_Y) * u); }
- (CGFloat)dropR:(int)b { return (b == B_ZL || b == B_ZR ? K_ZL_R : K_L_R) * self.u; }
- (CGPoint)clickCenter:(int)b { CGRect s = self.safe; CGFloat u = self.u; return side(s, b == B_RS, K_CLICK_X * u, CGRectGetMinY(s) + K_ZL_Y * u); }
- (CGRect)pillRect:(int)b { CGRect s = self.safe; CGFloat u = self.u, w = K_PILL_W * u, h = K_PILL_H * u;
    CGFloat dx = K_PILL_DX * u + _topGroupSplit;
    CGPoint c = CGPointMake(_topCentreX + (b == B_PLUS ? dx : -dx), CGRectGetMinY(s) + K_PILL_Y * u);
    return CGRectMake(c.x - w / 2, c.y - h / 2, w, h); }
- (CGPoint)swapCenter {
    CGRect s = self.safe; CGFloat u = self.u;
    CGFloat y = CGRectGetMinY(s) + K_PILL_Y * u;
    if (_swapOffFold) {   // a fold runs between Back and Start: the layout button goes left of Back
        CGRect back = [self pillRect:B_MINUS];
        return CGPointMake(CGRectGetMinX(back) - (K_SWAP_R + 8) * u, y);
    }
    return CGPointMake(_topCentreX, y);
}

// Keep the Back / layout / Start group off a hinge that runs down the middle of the view.
- (void)placeTopGroup {
    CGRect s = self.safe; CGFloat u = self.u;
    _topCentreX = CGRectGetMidX(s);
    _topGroupSplit = 0;
    _swapOffFold = NO;
    CGFloat reach = (K_PILL_DX + K_PILL_W / 2) * u;
    CGFloat top = CGRectGetMinY(s), bottom = top + (K_PILL_Y + K_PILL_H) * u;
    for (NSValue *v in _avoidRects) {
        CGRect r = v.CGRectValue;
        if (r.size.height < r.size.width) continue;                      // only vertical hinges
        if (CGRectGetMaxY(r) < top || CGRectGetMinY(r) > bottom) continue;
        if (CGRectGetMaxX(r) < _topCentreX - reach || CGRectGetMinX(r) > _topCentreX + reach) continue;
        // Open the gap between Back and Start so each pill sits fully on one side of the hinge.
        CGFloat needed = MAX(_topCentreX - CGRectGetMinX(r), CGRectGetMaxX(r) - _topCentreX) + 6 * u;
        CGFloat innerEdge = K_PILL_DX * u - K_PILL_W * u / 2;
        _topGroupSplit = MAX(0, needed - innerEdge);
        _topCentreX = CGRectGetMidX(r);
        _swapOffFold = YES;
    }
}

#pragma mark - Hit testing

- (int)btnAt:(CGPoint)p {
    CGFloat u = self.u;
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if (fullOnly(b) && !_full) continue;
        BOOL hit = isDrop(b) ? dist(p, [self dropCenter:b]) <= [self dropR:b] * 1.35
                 : isClick(b) ? dist(p, [self clickCenter:b]) <= K_CLICK_R * u * 1.35
                 : CGRectContainsPoint(CGRectInset([self pillRect:b], -8 * u, -8 * u), p);
        if (hit) return b; }
    return -1;
}
- (BOOL)inSwap:(CGPoint)p { return dist(p, self.swapCenter) <= K_SWAP_R * self.u * 1.6; }
- (uint64_t)faceAt:(CGPoint)p {
    uint64_t m = 0; CGFloat r = self.faceR * 1.25;
    for (int b = B_A; b <= B_Y; b++) if (dist(p, [self facePos:b]) <= r) m |= 1ull << b;
    return m;
}
- (uint64_t)dpadAt:(CGPoint)p {
    CGPoint c = self.dpadCenter; CGFloat dx = p.x - c.x, dy = p.y - c.y;
    if (hypot(dx, dy) < self.dpadR * 0.25) return 0;
    double a = atan2(-dy, dx) * 180 / M_PI; uint64_t m = 0;
    if (a > -67.5 && a < 67.5) m |= 1ull << B_RIGHT;
    if (a > 22.5 && a < 157.5) m |= 1ull << B_UP;
    if (a > 112.5 || a < -112.5) m |= 1ull << B_LEFT;
    if (a < -22.5 && a > -157.5) m |= 1ull << B_DOWN;
    return m;
}
- (CGPoint)knobOffset:(int)i {
    if (!_stick[i]) return CGPointZero;
    CGPoint h = [self stickCentre:i]; CGFloat dx = _stickNow[i].x - h.x, dy = _stickNow[i].y - h.y, d = hypot(dx, dy), R = [self stickR:i];
    if (d > R) { dx *= R / d; dy *= R / d; }
    return CGPointMake(dx, dy);
}

// Which control a touch landing at p would take (C_NONE: it goes to the stream).
- (int)claimAt:(CGPoint)p index:(int *)index {
    *index = 0;
    if (!_tap && [self btnAt:p] >= 0) return C_BTN;
    if ([self inSwap:p]) return C_SWAP;
    if (_tap) return C_NONE;
    CGFloat best = 1; int kind = C_NONE;
    CGFloat f = dist(p, self.faceCenter) / (self.faceGap + self.faceR * 1.6); if (f <= best) { best = f; kind = C_FACE; }
    if (_full) { CGFloat d = dist(p, self.dpadCenter) / (self.dpadR * K_DPAD_GRAB); if (d < best) { best = d; kind = C_DPAD; } }
    if (!_stick[0]) { CGFloat s = dist(p, self.stickHome) / ([self stickR:0] * K_STICK_GRAB); if (s < best) { best = s; kind = C_STICK; } }
    if (kind == C_NONE && _full && !_stick[1] && [self inRightArea:p]) { kind = C_STICK; *index = 1; }
    return kind;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (!_active || _hiddenForPad || !CGRectContainsPoint(self.bounds, point)) return NO;
    int idx;
    return [self claimAt:point index:&idx] != C_NONE;
}

#pragma mark - Touch

- (void)recompute {
    uint64_t face = 0; for (UITouch *t in _faceOf) face |= [_faceOf objectForKey:t].unsignedLongLongValue;
    uint64_t btn = 0, dpad = 0; BOOL swap = NO;
    for (UITouch *t in _owner) { uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff);
        if (c == C_BTN) btn |= 1ull << (v >> 8);
        else if (c == C_DPAD) dpad |= [self dpadAt:[t locationInView:self]];
        else if (c == C_SWAP) swap = YES; }
    BOOL changed = face != _faceBits || dpad != _dpadBits || btn != _btnBits || swap != _swapHeld;
    uint64_t pressed = (face | dpad | btn) & ~(_faceBits | _dpadBits | _btnBits);
    unsigned gripping = (_stick[0] ? 1u : 0) | (_stick[1] ? 2u : 0);
    if (pressed || (swap && !_swapHeld) || (gripping & ~_hapticSticks)) {
        [_touchFeedback impactOccurredWithIntensity:0.6]; [_touchFeedback prepare];
    }
    _hapticSticks = gripping;
    _faceBits = face; _dpadBits = dpad; _btnBits = btn; _swapHeld = swap;
    [self send];
    BOOL stick = _stick[0] != nil;
    if (changed || stick || _stickShown) [self refresh];
    _stickShown = stick;
}

- (void)send {
    ControllerSupport *cs = _cs;
    if (cs == nil || _osc == nil) return;
    uint64_t all = _faceBits | _dpadBits | _btnBits;
    int flags = 0;
    for (int b = 0; b < B_N; b++) if ((all >> b) & 1) flags |= [self flagOf:b];
    short ax[4] = {0};
    for (int i = 0; i < 2; i++) {
        CGPoint o = [self knobOffset:i]; CGFloat R = [self stickR:i], d = hypot(o.x, o.y), dz = R * K_DEAD;
        if (d <= dz) continue;
        CGFloat m = fmin((d - dz) / (R * K_FULL - dz), 1) / d;
        ax[i * 2] = (short)lrint(o.x * m * 32766); ax[i * 2 + 1] = (short)lrint(-o.y * m * 32766);
    }
    [cs updateLeftStick:_osc x:ax[0] y:ax[1]];
    [cs updateRightStick:_osc x:ax[2] y:ax[3]];
    [cs updateTriggers:_osc left:((all >> B_ZL) & 1) ? 0xFF : 0 right:((all >> B_ZR) & 1) ? 0xFF : 0];
    [cs updateButtonFlags:_osc flags:flags];
    [cs updateFinished:_osc];
}

- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    for (UITouch *t in ts) {
        CGPoint p = [t locationInView:self]; int idx = 0;
        int kind = [self claimAt:p index:&idx];
        if (kind == C_BTN) [_owner setObject:@(C_BTN | (uint64_t)[self btnAt:p] << 8) forKey:t];
        else if (kind == C_SWAP) [_owner setObject:@(C_SWAP) forKey:t];
        else if (kind == C_FACE) { [_owner setObject:@(C_FACE) forKey:t]; [_faceOf setObject:@([self faceAt:p]) forKey:t]; }
        else if (kind == C_DPAD) [_owner setObject:@(C_DPAD) forKey:t];
        else if (kind == C_STICK) { if (idx == 1) _rCentre = p; [_owner setObject:@(C_STICK | (uint64_t)idx << 8) forKey:t]; _stick[idx] = t; _stickNow[idx] = p; }
    }
    [self recompute];
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    for (UITouch *t in ts) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff); CGPoint p = [t locationInView:self];
        if (c == C_FACE) [_faceOf setObject:@([self faceAt:p]) forKey:t];
        else if (c == C_STICK) { _stickNow[v >> 8] = p;
            if ((v >> 8) == 1) { CGFloat d = dist(p, _rCentre), R = [self stickR:1];
                if (d > R) _rCentre = CGPointMake(p.x - (p.x - _rCentre.x) * R / d, p.y - (p.y - _rCentre.y) * R / d); } }
    }
    [self recompute];
}
- (void)endTouches:(NSSet<UITouch *> *)ts tapped:(BOOL)ended {
    BOOL swap = NO;
    for (UITouch *t in ts) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue;
        if (ended && (v & 0xff) == C_SWAP && [self inSwap:[t locationInView:self]]) swap = YES;
        [_owner removeObjectForKey:t]; [_faceOf removeObjectForKey:t]; for (int i = 0; i < 2; i++) if (t == _stick[i]) _stick[i] = nil;
    }
    [self recompute];
    if (swap) [self nextLayout];
}
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts tapped:YES]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts tapped:NO]; }
- (void)reset { [_owner removeAllObjects]; [_faceOf removeAllObjects]; _stick[0] = _stick[1] = nil; [self recompute]; }

#pragma mark - Shapes

static CGPathRef circlePath(CGPoint c, CGFloat r) { return CGPathCreateWithEllipseInRect(CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r), NULL); }
static CGPathRef dropPath(CGPoint c, CGFloat r, CGFloat tipAngle, CGFloat round) {
    CGFloat d = r * K_DROP_TIP, th = acos(r / d);
    CGPoint tip = CGPointMake(c.x + d * cos(tipAngle), c.y + d * sin(tipAngle));
    CGPoint p1 = CGPointMake(c.x + r * cos(tipAngle + th), c.y + r * sin(tipAngle + th)), p2 = CGPointMake(c.x + r * cos(tipAngle - th), c.y + r * sin(tipAngle - th));
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, p2.x, p2.y);
    CGPathAddArcToPoint(p, NULL, tip.x, tip.y, p1.x, p1.y, round);
    CGPathAddArc(p, NULL, c.x, c.y, r, tipAngle + th, tipAngle - th + 2 * M_PI, false);
    CGPathCloseSubpath(p); return p;
}
static CGPathRef armPath(CGPoint c, CGFloat R, CGFloat w, CGFloat in, CGFloat angle, CGFloat round) {
    CGPoint v[5] = {{-w, -R}, {w, -R}, {w, -(in + w)}, {0, -in}, {-w, -(in + w)}};
    CGFloat cs = cos(angle), sn = sin(angle);
    for (int i = 0; i < 5; i++) v[i] = CGPointMake(c.x + v[i].x * cs - v[i].y * sn, c.y + v[i].x * sn + v[i].y * cs);
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, (v[4].x + v[0].x) / 2, (v[4].y + v[0].y) / 2);
    for (int i = 0; i < 5; i++) CGPathAddArcToPoint(p, NULL, v[i].x, v[i].y, v[(i + 1) % 5].x, v[(i + 1) % 5].y, round);
    CGPathCloseSubpath(p); return p;
}
static void setPath(CAShapeLayer *l, CGPathRef p) { l.path = p; l.shadowPath = p; CGPathRelease(p); }
static void placeLabel(CATextLayer *t, CGPoint c, CGFloat fs) {
    CTFontRef f = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, fs, NULL);
    t.font = f; t.fontSize = fs;
    CGFloat h = CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f), w = fs * 4;
    t.frame = CGRectMake(c.x - w / 2, c.y - h / 2, w, h);
    CFRelease(f);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (CGRectIsEmpty(self.bounds)) return;
    [self placeTopGroup];
    CGFloat u = self.u;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _controls.frame = self.layer.bounds;
    for (int b = B_A; b <= B_Y; b++) { CGPoint c = [self facePos:b]; setPath(_key[b], circlePath(c, self.faceR)); placeLabel(_label[b], c, 20 * u); }
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if (isDrop(b)) {
            BOOL right = b == B_ZR || b == B_R; CGPoint c = [self dropCenter:b];
            setPath(_key[b], dropPath(c, [self dropR:b], right ? -M_PI_4 : -3 * M_PI_4, 4 * u)); placeLabel(_label[b], c, 15 * u);
        } else if (isClick(b)) {
            CGPoint c = [self clickCenter:b]; setPath(_key[b], circlePath(c, K_CLICK_R * u)); placeLabel(_label[b], c, 13 * u);
        } else {
            CGRect rc = [self pillRect:b];
            setPath(_key[b], CGPathCreateWithRoundedRect(rc, rc.size.height / 2, rc.size.height / 2, NULL)); placeLabel(_label[b], CGPointMake(CGRectGetMidX(rc), CGRectGetMidY(rc)), 12 * u);
        }
    }
    static const struct { int b; CGFloat angle; } arms[] = {{B_UP, 0}, {B_RIGHT, M_PI_2}, {B_DOWN, M_PI}, {B_LEFT, -M_PI_2}};
    for (int i = 0; i < 4; i++) setPath(_key[arms[i].b], armPath(self.dpadCenter, self.dpadR, K_ARM_W * u, K_ARM_IN * u, arms[i].angle, 6 * u));
    CGPoint sc = self.swapCenter; setPath(_swap, circlePath(sc, K_SWAP_R * u)); placeLabel(_swapLabel, sc, 11 * u);
    setPath(_ring, circlePath(self.stickHome, [self stickR:0]));
    CGFloat k = K_KNOB_R * u; _knob.bounds = CGRectMake(0, 0, 2 * k, 2 * k);
    setPath(_knob, circlePath(CGPointMake(k, k), k));
    CAShapeLayer *inner = (CAShapeLayer *)_knob.sublayers.firstObject; CGPathRef ip = circlePath(CGPointMake(k, k), k * 0.62);
    inner.frame = _knob.bounds; inner.path = ip; CGPathRelease(ip);
    [CATransaction commit];
    [self refresh];
}
- (void)safeAreaInsetsDidChange { [super safeAreaInsetsDidChange]; [self setNeedsLayout]; }
- (void)refresh {
    uint64_t all = _faceBits | _dpadBits | _btnBits;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) { BOOL on = (all >> b) & 1;
        _key[b].fillColor = (on ? k_on : k_idle).CGColor; _label[b].foregroundColor = (on ? k_textOn : k_text).CGColor; }
    _swap.fillColor = (_swapHeld ? k_on : k_idle).CGColor; _swapLabel.foregroundColor = (_swapHeld ? k_textOn : k_text).CGColor;
    CGPoint h = self.stickHome, o = [self knobOffset:0];
    _knob.position = CGPointMake(h.x + o.x, h.y + o.y); _knob.fillColor = (_stick[0] ? k_on : k_idle).CGColor;
    [CATransaction commit];
}

#pragma mark - Physical controllers

// In Automatic, the gamepad hides while a controller (or a keyboard / mouse, as Moonlight's
// automatic on-screen controls did) is connected and comes back when it is removed.
- (void)padsChanged:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL hide = NO;
        if (self->_settingsLevel == 1) {
            for (GCController *c in GCController.controllers) if (c.extendedGamepad) hide = YES;
            if (GCKeyboard.coalescedKeyboard != nil || GCMouse.mice.count > 0) hide = YES;
        }
        if (hide != self->_hiddenForPad) {
            self->_hiddenForPad = hide;
            [self updateVisibility];
        }
    });
}

@end

#if DEBUG
#import "StreamConfiguration.h"

@interface MLFakeTouch : NSObject
@property (nonatomic) CGPoint point;
@end
@implementation MLFakeTouch
- (CGPoint)locationInView:(UIView *)view { return _point; }
@end

@implementation MLTouchGamepad (SelfTest)

static NSString *MLCheck(NSMutableArray *out, int *fails, BOOL ok, NSString *name, NSString *detail) {
    if (!ok) (*fails)++;
    NSString *line = [NSString stringWithFormat:@"%@  %@%@", ok ? @"PASS" : @"FAIL", name, detail.length ? [NSString stringWithFormat:@"  (%@)", detail] : @""];
    [out addObject:line];
    return line;
}

- (void)debugDown:(MLFakeTouch *)t at:(CGPoint)p { t.point = p; [self touchesBegan:(NSSet *)[NSSet setWithObject:t] withEvent:nil]; }
- (void)debugMove:(MLFakeTouch *)t to:(CGPoint)p { t.point = p; [self touchesMoved:(NSSet *)[NSSet setWithObject:t] withEvent:nil]; }
- (void)debugUp:(MLFakeTouch *)t { [self touchesEnded:(NSSet *)[NSSet setWithObject:t] withEvent:nil]; }

// The drawn shape of every visible control (name -> path), for the overlap check.
- (NSArray<NSArray *> *)debugControlShapes {
    NSMutableArray *c = [NSMutableArray array];
    for (int b = 0; b < B_N; b++) {
        if (_key[b].hidden || _key[b].path == NULL) continue;
        NSString *group = b <= B_Y ? @"face" : (b >= B_LEFT ? @"dpad" : ([self nameOf:b] ?: @"?"));
        [c addObject:@[group, [self nameOf:b] ?: @"arm", (__bridge id)_key[b].path]];
    }
    if (!_ring.hidden) [c addObject:@[@"stick", @"stick", (__bridge id)_ring.path]];
    [c addObject:@[@"layout", @"layout button", (__bridge id)_swap.path]];
    return c;
}

- (void)debugPressSequence {
    void (^log)(NSString *) = ^(NSString *s) { [MLDuoBridge debugAppend:[@"pad probe: " stringByAppendingString:s] toFile:@"stream-status.txt"]; };
    log([NSString stringWithFormat:@"gamepad %@ (level %d, layout %@, hidden for controller/keyboard/mouse: %@; GCControllers %d, keyboard %@, mice %d)",
         self->_controls.hidden ? @"HIDDEN" : @"visible", (int)self->_settingsLevel, self->_tap ? @"Tap" : (self->_full ? @"3D" : @"2D"),
         self->_hiddenForPad ? @"yes" : @"no", (int)GCController.controllers.count, GCKeyboard.coalescedKeyboard ? @"yes" : @"no", (int)GCMouse.mice.count]);
    if (self->_tap) { log(@"Tap layout: no buttons to press"); return; }
    Controller *osc = self->_osc;
    MLFakeTouch *t = [MLFakeTouch new];
    CGPoint a = [self facePos:B_B], h = self.stickHome; CGFloat R = [self stickR:0];
    [self debugDown:t at:a];
    log([NSString stringWithFormat:@"A down -> buttons 0x%x", osc.lastButtonFlags]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self debugUp:t];
        log([NSString stringWithFormat:@"A up -> buttons 0x%x", osc.lastButtonFlags]);
        [self debugDown:t at:h]; [self debugMove:t to:CGPointMake(h.x + R, h.y)];
        log([NSString stringWithFormat:@"left stick right -> x %d y %d", osc.lastLeftStickX, osc.lastLeftStickY]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self debugUp:t];
            log([NSString stringWithFormat:@"stick released -> x %d y %d", osc.lastLeftStickX, osc.lastLeftStickY]);
            if (!self->_full) { log(@"2D layout: D-pad skipped"); return; }
            CGPoint d = self.dpadCenter;
            [self debugDown:t at:CGPointMake(d.x, d.y - self.dpadR * 0.7)];
            log([NSString stringWithFormat:@"D-pad up -> buttons 0x%x", osc.lastButtonFlags]);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
                [self debugUp:t];
                log([NSString stringWithFormat:@"D-pad up released -> buttons 0x%x; done", osc.lastButtonFlags]);
            });
        });
    });
}

+ (NSArray<NSString *> *)debugSelfTest {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    int fails = 0;
    StreamConfiguration *config = [[StreamConfiguration alloc] init];
    config.width = 1920; config.height = 1080; config.frameRate = 60;
    ControllerSupport *cs = [[ControllerSupport alloc] initWithConfig:config delegate:nil];
    Controller *osc = [cs getOscController];
    id savedLayout = [NSUserDefaults.standardUserDefaults objectForKey:MLPadLayoutDefaultsKey];

    for (int swap = 0; swap < 2; swap++) {
        [NSUserDefaults.standardUserDefaults setInteger:MLPadLayout3D forKey:MLPadLayoutDefaultsKey];
        MLTouchGamepad *g = [[MLTouchGamepad alloc] initWithControllerSupport:cs swapABXY:swap settingsLevel:3];
        g.frame = CGRectMake(0, 0, 874, 402);   // an iPhone in landscape
        g.active = YES;
        [g layoutIfNeeded];
        NSString *tag = swap ? @"[swap A/B X/Y] " : @"";
        MLFakeTouch *t = [MLFakeTouch new];
        struct { int key; int flag; NSString *name; } keys[] = {
            {B_B, swap ? B_FLAG : A_FLAG, @"bottom face key"}, {B_A, swap ? A_FLAG : B_FLAG, @"right face key"},
            {B_Y, swap ? Y_FLAG : X_FLAG, @"left face key"}, {B_X, swap ? X_FLAG : Y_FLAG, @"top face key"},
        };
        for (int i = 0; i < 4; i++) {
            [g debugDown:t at:[g facePos:keys[i].key]];
            MLCheck(out, &fails, osc.lastButtonFlags == keys[i].flag, [NSString stringWithFormat:@"%@%@ sends %@", tag, keys[i].name, [g nameOf:keys[i].key]],
                    [NSString stringWithFormat:@"flags 0x%x", osc.lastButtonFlags]);
            [g debugUp:t];
        }
        if (swap) continue;
        MLCheck(out, &fails, osc.lastButtonFlags == 0, @"release clears the buttons", [NSString stringWithFormat:@"flags 0x%x", osc.lastButtonFlags]);

        struct { CGPoint p; int flag; NSString *name; } btns[] = {
            {CGPointMake(CGRectGetMidX([g pillRect:B_MINUS]), CGRectGetMidY([g pillRect:B_MINUS])), BACK_FLAG, @"Back"},
            {CGPointMake(CGRectGetMidX([g pillRect:B_PLUS]), CGRectGetMidY([g pillRect:B_PLUS])), PLAY_FLAG, @"Start"},
            {[g dropCenter:B_L], LB_FLAG, @"LB"}, {[g dropCenter:B_R], RB_FLAG, @"RB"},
            {[g clickCenter:B_LS], LS_CLK_FLAG, @"L3"}, {[g clickCenter:B_RS], RS_CLK_FLAG, @"R3"},
        };
        for (int i = 0; i < 6; i++) {
            [g debugDown:t at:btns[i].p];
            MLCheck(out, &fails, osc.lastButtonFlags == btns[i].flag, [NSString stringWithFormat:@"%@ sends its button", btns[i].name], [NSString stringWithFormat:@"flags 0x%x", osc.lastButtonFlags]);
            [g debugUp:t];
        }
        [g debugDown:t at:[g dropCenter:B_ZL]];
        MLCheck(out, &fails, osc.lastLeftTrigger == 0xFF && osc.lastRightTrigger == 0, @"LT pulls the left trigger fully", [NSString stringWithFormat:@"L %d R %d", osc.lastLeftTrigger, osc.lastRightTrigger]);
        [g debugUp:t];
        [g debugDown:t at:[g dropCenter:B_ZR]];
        MLCheck(out, &fails, osc.lastRightTrigger == 0xFF && osc.lastLeftTrigger == 0, @"RT pulls the right trigger fully", [NSString stringWithFormat:@"L %d R %d", osc.lastLeftTrigger, osc.lastRightTrigger]);
        [g debugUp:t];

        CGPoint d = g.dpadCenter; CGFloat r = g.dpadR * 0.7;
        struct { CGPoint p; int flag; NSString *name; } dirs[] = {
            {CGPointMake(d.x, d.y - r), UP_FLAG, @"up"}, {CGPointMake(d.x, d.y + r), DOWN_FLAG, @"down"},
            {CGPointMake(d.x - r, d.y), LEFT_FLAG, @"left"}, {CGPointMake(d.x + r, d.y), RIGHT_FLAG, @"right"},
            {CGPointMake(d.x + r * 0.7, d.y - r * 0.7), UP_FLAG | RIGHT_FLAG, @"up-right diagonal"},
        };
        for (int i = 0; i < 5; i++) {
            [g debugDown:t at:dirs[i].p];
            MLCheck(out, &fails, osc.lastButtonFlags == dirs[i].flag, [NSString stringWithFormat:@"D-pad %@", dirs[i].name], [NSString stringWithFormat:@"flags 0x%x", osc.lastButtonFlags]);
            [g debugUp:t];
        }
        // Slide across the D-pad without lifting: the direction follows the finger.
        [g debugDown:t at:dirs[0].p]; [g debugMove:t to:dirs[3].p];
        MLCheck(out, &fails, osc.lastButtonFlags == RIGHT_FLAG, @"D-pad slide up -> right", [NSString stringWithFormat:@"flags 0x%x", osc.lastButtonFlags]);
        [g debugUp:t];

        CGPoint h = g.stickHome; CGFloat R = [g stickR:0];
        [g debugDown:t at:h]; [g debugMove:t to:CGPointMake(h.x + R, h.y)];
        MLCheck(out, &fails, osc.lastLeftStickX == 32766 && osc.lastLeftStickY == 0, @"left stick full right", [NSString stringWithFormat:@"x %d y %d", osc.lastLeftStickX, osc.lastLeftStickY]);
        [g debugMove:t to:CGPointMake(h.x, h.y - R)];
        MLCheck(out, &fails, osc.lastLeftStickX == 0 && osc.lastLeftStickY == 32766, @"left stick full up (up is positive)", [NSString stringWithFormat:@"x %d y %d", osc.lastLeftStickX, osc.lastLeftStickY]);
        [g debugMove:t to:CGPointMake(h.x + R * 0.05, h.y)];
        MLCheck(out, &fails, osc.lastLeftStickX == 0, @"left stick dead zone", [NSString stringWithFormat:@"x %d", osc.lastLeftStickX]);
        [g debugUp:t];
        MLCheck(out, &fails, osc.lastLeftStickX == 0 && osc.lastLeftStickY == 0, @"left stick recentres on release", nil);

        CGPoint rs = CGPointMake(874 - 230, 200);   // right third, on no control
        MLCheck(out, &fails, [g pointInside:rs withEvent:nil], @"3D: right third takes the right stick", nil);
        [g debugDown:t at:rs]; [g debugMove:t to:CGPointMake(rs.x - [g stickR:1], rs.y)];
        MLCheck(out, &fails, osc.lastRightStickX == -32766, @"right stick swipe left", [NSString stringWithFormat:@"x %d", osc.lastRightStickX]);
        [g debugUp:t];

        // Two fingers at once: stick and a face key.
        MLFakeTouch *t2 = [MLFakeTouch new];
        [g debugDown:t at:h]; [g debugMove:t to:CGPointMake(h.x - R, h.y)];
        [g debugDown:t2 at:[g facePos:B_B]];
        MLCheck(out, &fails, osc.lastLeftStickX == -32766 && osc.lastButtonFlags == A_FLAG, @"stick and A held together", nil);
        [g debugUp:t2]; [g debugUp:t];

        CGPoint mid = CGPointMake(437, 220);
        MLCheck(out, &fails, ![g pointInside:mid withEvent:nil], @"touch on no control goes to the stream (mouse)", nil);

        // Layout button: 3D -> Tap -> 2D -> 3D, remembered.
        [g debugDown:t at:g.swapCenter]; [g debugUp:t];
        MLCheck(out, &fails, g.layout == MLPadLayoutTap && ![g pointInside:[g facePos:B_B] withEvent:nil], @"layout button 3D -> Tap (controls let touches through)", nil);
        [g debugDown:t at:g.swapCenter]; [g debugUp:t];
        MLCheck(out, &fails, g.layout == MLPadLayout2D && ![g pointInside:rs withEvent:nil], @"Tap -> 2D (no right stick)", nil);
        [g debugDown:t at:g.swapCenter]; [g debugUp:t];
        MLCheck(out, &fails, g.layout == MLPadLayout3D && [NSUserDefaults.standardUserDefaults integerForKey:MLPadLayoutDefaultsKey] == MLPadLayout3D, @"2D -> 3D, saved", nil);
    }

    // Overlap check at the sizes the gamepad gets on iPhone Duo and other iPhones.
    struct { CGFloat w, h; BOOL dedicated; NSString *name; } sizes[] = {
        {874, 402, NO, @"iPhone landscape (overlay)"}, {678, 466, NO, @"Duo outer, landscape (overlay)"},
        {466, 330, YES, @"Duo outer, portrait split area"}, {890, 626, NO, @"Duo inner, landscape (overlay)"},
        {626, 890, NO, @"Duo inner, portrait (overlay)"}, {626, 429, YES, @"Duo inner, tabletop lower half"},
        {626, 460, YES, @"Duo inner, portrait split area"},
    };
    for (int layout = MLPadLayout2D; layout <= MLPadLayout3D; layout++) {
        for (int i = 0; i < (int)(sizeof sizes / sizeof *sizes); i++) {
            [NSUserDefaults.standardUserDefaults setInteger:layout forKey:MLPadLayoutDefaultsKey];
            MLTouchGamepad *g = [[MLTouchGamepad alloc] initWithControllerSupport:cs swapABXY:NO settingsLevel:3];
            g.frame = CGRectMake(0, 0, sizes[i].w, sizes[i].h);
            g.dedicatedArea = sizes[i].dedicated;
            [g layoutIfNeeded];
            NSArray *shapes = [g debugControlShapes];
            NSMutableArray *problems = [NSMutableArray array];
            CGRect area = CGRectInset(g.bounds, -1, -1);
            for (NSUInteger a = 0; a < shapes.count; a++) {
                CGPathRef pa = (__bridge CGPathRef)shapes[a][2];
                if (!CGRectContainsRect(area, CGPathGetBoundingBox(pa))) [problems addObject:[NSString stringWithFormat:@"%@ off screen", shapes[a][1]]];
                for (NSUInteger b = a + 1; b < shapes.count; b++) {
                    if ([shapes[a][0] isEqualToString:shapes[b][0]]) continue;   // keys of one control (diamond, D-pad)
                    if (CGPathIntersectsPath(pa, (__bridge CGPathRef)shapes[b][2], false)) [problems addObject:[NSString stringWithFormat:@"%@/%@", shapes[a][1], shapes[b][1]]];
                }
            }
            MLCheck(out, &fails, problems.count == 0,
                    [NSString stringWithFormat:@"%@ %@ %.0fx%.0f: no overlapping controls", layout ? @"3D" : @"2D", sizes[i].name, sizes[i].w, sizes[i].h],
                    problems.count ? [problems componentsJoinedByString:@", "] : [NSString stringWithFormat:@"u %.2f", g.u]);
        }
    }

    if (savedLayout) [NSUserDefaults.standardUserDefaults setObject:savedLayout forKey:MLPadLayoutDefaultsKey];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:MLPadLayoutDefaultsKey];
    [cs cleanup];
    [out insertObject:[NSString stringWithFormat:@"Touch gamepad: %d/%d passed", (int)out.count - fails, (int)out.count] atIndex:0];
    return out;
}

@end
#endif
