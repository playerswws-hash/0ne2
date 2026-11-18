#import <UIKit/UIKit.h>
#import <CallKit/CallKit.h>
#import <dlfcn.h>

// ======== Геометрия (pt, iPhone 11) — всё правится здесь ========
#define BAR_H        34.0    // чёрная полоса, скрывающая вырез
#define PILL_Y       40.0    // верх острова: чуть ниже выреза
#define PILL_W       126.0   // compact, как у оригинала
#define PILL_H       37.0
#define EXP_MARGIN   11.0    // отступ expanded от краёв экрана
#define EXP_H_MEDIA  162.0
#define EXP_H_CALL   84.0

typedef void    (*MRGetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void    (*MRRegisterFn)(dispatch_queue_t);
typedef Boolean (*MRSendFn)(int, id);
static MRGetInfoFn MRGetInfo; static MRRegisterFn MRRegister; static MRSendFn MRSend;

@interface UIWindow (ISLPriv) - (void)_setSecure:(BOOL)s; @end

static inline CGFloat ISLFullW(void) { return UIScreen.mainScreen.bounds.size.width - 2 * EXP_MARGIN; }
static NSString *ISLFmt(double s) { if (s < 0) s = 0; int t = (int)s; return [NSString stringWithFormat:@"%d:%02d", t / 60, t % 60]; }
static UIImage *ISLSym(NSString *n, CGFloat sz) {
    return [UIImage systemImageNamed:n withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:sz weight:UIImageSymbolWeightSemibold]];
}
// Средний цвет обложки (для эквалайзера, как в оригинале)
static UIColor *ISLAvgColor(UIImage *img) {
    if (!img.CGImage) return UIColor.systemPinkColor;
    unsigned char px[4] = {0, 0, 0, 0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, 1, 1, 8, 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return UIColor.systemPinkColor;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
    CGContextDrawImage(ctx, CGRectMake(0, 0, 1, 1), img.CGImage);
    CGContextRelease(ctx);
    UIColor *c = [UIColor colorWithRed:px[0] / 255.0 green:px[1] / 255.0 blue:px[2] / 255.0 alpha:1];
    CGFloat h = 0, s = 0, b = 0, a = 0;
    [c getHue:&h saturation:&s brightness:&b alpha:&a];
    return [UIColor colorWithHue:h saturation:MIN(1.0, s * 1.1) brightness:MAX(b, 0.8) alpha:1];
}

// ================= Эквалайзер (4 полоски) =================
@interface ISLEQ : UIView
@property (nonatomic) BOOL running;
@property (nonatomic, strong) UIColor *color;
@end

@implementation ISLEQ { NSArray<CALayer *> *_bars; }
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        NSMutableArray *a = [NSMutableArray array];
        for (int i = 0; i < 4; i++) {
            CALayer *l = [CALayer layer];
            l.cornerRadius = 1.5;
            l.anchorPoint = CGPointMake(0.5, 1.0);
            [self.layer addSublayer:l];
            [a addObject:l];
        }
        _bars = a;
        _color = UIColor.systemPinkColor;
        [self restart];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CGFloat h = self.bounds.size.height;
    for (int i = 0; i < 4; i++) {
        CALayer *l = _bars[i];
        l.bounds = CGRectMake(0, 0, 3, h);
        l.position = CGPointMake(1.5 + i * 5, h);
        l.backgroundColor = self.color.CGColor;
    }
    [CATransaction commit];
}
- (void)setColor:(UIColor *)c {
    _color = c;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CALayer *l in _bars) l.backgroundColor = c.CGColor;
    [CATransaction commit];
}
- (void)setRunning:(BOOL)r { if (_running == r) return; _running = r; [self restart]; }
- (void)restart {
    static const double dur[4] = {0.42, 0.58, 0.36, 0.50};
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (int i = 0; i < 4; i++) {
        CALayer *l = _bars[i];
        [l removeAllAnimations];
        l.transform = CATransform3DMakeScale(1, 0.2, 1);
        if (!_running) continue;
        CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"transform.scale.y"];
        a.fromValue = @0.2; a.toValue = @1.0;
        a.duration = dur[i]; a.autoreverses = YES; a.repeatCount = HUGE_VALF;
        a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [l addAnimation:a forKey:@"eq"];
    }
    [CATransaction commit];
}
@end

// ================= Чёрная полоса + время/батарея =================
@interface ISLBar : UIView
@property (nonatomic, strong) UILabel *timeL, *batL;
@property (nonatomic, strong) UIImageView *batI;
@property (nonatomic, strong) NSDateFormatter *fmt;
@end

@implementation ISLBar
- (instancetype)init {
    CGFloat sw = UIScreen.mainScreen.bounds.size.width;
    if ((self = [super initWithFrame:CGRectMake(0, 0, sw, BAR_H)])) {
        self.backgroundColor = UIColor.blackColor;
        self.userInteractionEnabled = NO;
        _fmt = [NSDateFormatter new]; _fmt.dateFormat = @"HH:mm";
        _timeL = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 102, BAR_H)];
        _timeL.textAlignment = NSTextAlignmentCenter; _timeL.textColor = UIColor.whiteColor;
        _timeL.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        _batL = [[UILabel alloc] initWithFrame:CGRectMake(sw - 72, 0, 36, BAR_H)];
        _batL.textAlignment = NSTextAlignmentRight; _batL.textColor = UIColor.whiteColor;
        _batL.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        _batI = [[UIImageView alloc] initWithFrame:CGRectMake(sw - 34, 8, 26, 18)];
        _batI.contentMode = UIViewContentModeScaleAspectFit;
        [self addSubview:_timeL]; [self addSubview:_batL]; [self addSubview:_batI];
        UIDevice.currentDevice.batteryMonitoringEnabled = YES;
        [self tick]; [self updateBattery];
        [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(tick) userInfo:nil repeats:YES];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateBattery) name:UIDeviceBatteryLevelDidChangeNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateBattery) name:UIDeviceBatteryStateDidChangeNotification object:nil];
    }
    return self;
}
- (void)tick { self.timeL.text = [self.fmt stringFromDate:NSDate.date]; }
- (void)updateBattery {
    UIDevice *d = UIDevice.currentDevice;
    int pct = d.batteryLevel < 0 ? 0 : (int)roundf(d.batteryLevel * 100);
    BOOL chg = d.batteryState == UIDeviceBatteryStateCharging || d.batteryState == UIDeviceBatteryStateFull;
    self.batL.text = [NSString stringWithFormat:@"%d", pct];
    self.batI.image = [UIImage systemImageNamed:chg ? @"battery.100percent.bolt" : @"battery.100percent"];
    self.batI.tintColor = chg ? UIColor.systemGreenColor : (pct <= 20 ? UIColor.systemRedColor : UIColor.whiteColor);
}
@end

// ================= Остров =================
typedef NS_ENUM(NSInteger, ISLMode) { ISLModeNone = 0, ISLModeMedia, ISLModeCall };

@interface ISLPill : UIView
@property (nonatomic) ISLMode mode;
@property (nonatomic) BOOL expanded, inCall, callConnected, callOutgoing;
@property (nonatomic, strong) NSDate *callStart;
- (void)updateMedia:(NSDictionary *)info;
- (void)showCall;
@end

@implementation ISLPill {
    UIView *_compact, *_full, *_track, *_fill;
    UIImageView *_cArt, *_art;
    ISLEQ *_cEQ, *_eq;
    UILabel *_cTime, *_titleL, *_artistL, *_elL, *_remL;
    UIButton *_prev, *_play, *_next;
    NSTimer *_timer;
    double _el, _du, _rate;
    NSDate *_ts;
}

- (UIImageView *)iv {
    UIImageView *v = [[UIImageView alloc] initWithFrame:CGRectZero];
    v.clipsToBounds = YES;
    v.layer.cornerCurve = kCACornerCurveContinuous;
    return v;
}
- (UILabel *)lbl:(UIFont *)f color:(UIColor *)c {
    UILabel *l = [UILabel new]; l.font = f; l.textColor = c; return l;
}
- (UIButton *)btnSF:(NSString *)sf size:(CGFloat)sz tag:(int)t {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.tag = t; b.tintColor = UIColor.whiteColor;
    [b setImage:ISLSym(sf, sz) forState:UIControlStateNormal];
    [b addTarget:self action:@selector(cmd:) forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (instancetype)init {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.backgroundColor = UIColor.blackColor;
        self.clipsToBounds = YES;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        CGFloat W = ISLFullW();

        // --- compact ---
        _compact = [[UIView alloc] initWithFrame:CGRectMake(0, 0, PILL_W, PILL_H)];
        _cArt = [self iv]; _cArt.frame = CGRectMake(8, 6, 25, 25);
        _cEQ = [[ISLEQ alloc] initWithFrame:CGRectMake(PILL_W - 10 - 18, (PILL_H - 14) / 2, 18, 14)];
        _cTime = [self lbl:[UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold] color:UIColor.systemGreenColor];
        _cTime.frame = CGRectMake(PILL_W - 8 - 60, 0, 60, PILL_H);
        _cTime.textAlignment = NSTextAlignmentRight;
        for (UIView *v in @[_cArt, _cEQ, _cTime]) [_compact addSubview:v];

        // --- expanded ---
        _full = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, EXP_H_MEDIA)];
        _art = [self iv];
        _titleL = [self lbl:[UIFont systemFontOfSize:16 weight:UIFontWeightSemibold] color:UIColor.whiteColor];
        _artistL = [self lbl:[UIFont systemFontOfSize:14] color:[UIColor colorWithWhite:0.62 alpha:1]];
        _eq = [[ISLEQ alloc] initWithFrame:CGRectZero];
        UIFont *mono = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium];
        UIColor *dim = [UIColor colorWithWhite:1 alpha:0.6];
        _elL = [self lbl:mono color:dim]; _elL.textAlignment = NSTextAlignmentLeft;
        _remL = [self lbl:mono color:dim]; _remL.textAlignment = NSTextAlignmentRight;
        _track = [UIView new]; _track.backgroundColor = [UIColor colorWithWhite:1 alpha:0.3];
        _track.clipsToBounds = YES; _track.layer.cornerRadius = 2;
        _fill = [UIView new]; _fill.backgroundColor = UIColor.whiteColor;
        [_track addSubview:_fill];
        _prev = [self btnSF:@"backward.fill" size:24 tag:5];
        _play = [self btnSF:@"pause.fill" size:30 tag:2];
        _next = [self btnSF:@"forward.fill" size:24 tag:4];
        for (UIView *v in @[_art, _titleL, _artistL, _eq, _elL, _track, _remL, _prev, _play, _next]) [_full addSubview:v];

        [self addSubview:_full];
        [self addSubview:_compact];
        _full.alpha = 0; _full.transform = CGAffineTransformMakeScale(0.9, 0.9);
        _compact.alpha = 0;

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped)];
        [self addGestureRecognizer:tap];
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressed:)];
        lp.minimumPressDuration = 0.35;
        [self addGestureRecognizer:lp];
        UISwipeGestureRecognizer *up = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(swipedUp)];
        up.direction = UISwipeGestureRecognizerDirectionUp;
        [self addGestureRecognizer:up];

        self.alpha = 0;
        self.frame = [self targetFrame];
        self.layer.cornerRadius = self.frame.size.height / 2;
    }
    return self;
}

#pragma mark - Действия
- (void)cmd:(UIButton *)b { if (MRSend) MRSend((int)b.tag, nil); }
- (void)tapped { if (_mode != ISLModeNone) self.expanded = !_expanded; }
- (void)longPressed:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan && _mode != ISLModeNone && !_expanded) self.expanded = YES;
}
- (void)swipedUp { self.expanded = NO; }

#pragma mark - Геометрия
- (CGRect)targetFrame {
    CGFloat sw = UIScreen.mainScreen.bounds.size.width;
    if (_mode == ISLModeNone) { CGFloat w = 70; return CGRectMake((sw - w) / 2, PILL_Y + 4, w, PILL_H - 8); }
    if (_expanded) {
        CGFloat H = (_mode == ISLModeCall) ? EXP_H_CALL : EXP_H_MEDIA;
        return CGRectMake(EXP_MARGIN, PILL_Y, ISLFullW(), H);
    }
    return CGRectMake((sw - PILL_W) / 2, PILL_Y, PILL_W, PILL_H);
}
- (void)layoutFull {
    CGFloat W = ISLFullW();
    if (_mode == ISLModeCall) {
        _art.frame = CGRectMake(20, 12, 60, 60);
        _titleL.frame = CGRectMake(94, 16, W - 94 - 20, 24);
        _artistL.frame = CGRectMake(94, 42, W - 94 - 20, 20);
        return;
    }
    _art.frame = CGRectMake(20, 20, 60, 60);
    _titleL.frame = CGRectMake(94, 24, W - 94 - 52, 22);
    _artistL.frame = CGRectMake(94, 47, W - 94 - 52, 18);
    _eq.frame = CGRectMake(W - 38, 28, 18, 14);
    _elL.frame = CGRectMake(20, 95, 40, 16);
    _track.frame = CGRectMake(68, 101, W - 142, 4);
    _remL.frame = CGRectMake(W - 66, 95, 46, 16);
    CGFloat cx = W / 2;
    _prev.frame = CGRectMake(cx - 100, 114, 56, 40);
    _play.frame = CGRectMake(cx - 28, 114, 56, 40);
    _next.frame = CGRectMake(cx + 44, 114, 56, 40);
}
- (void)configureForMode {
    BOOL call = (_mode == ISLModeCall), media = (_mode == ISLModeMedia);
    if (!call && !media) return;
    _cEQ.hidden = call; _eq.hidden = call; _cTime.hidden = media;
    _track.hidden = call; _elL.hidden = call; _remL.hidden = call;
    _prev.hidden = call; _play.hidden = call; _next.hidden = call;
    if (call) {
        _cArt.contentMode = UIViewContentModeCenter; _cArt.backgroundColor = UIColor.clearColor;
        _cArt.tintColor = UIColor.systemGreenColor; _cArt.layer.cornerRadius = 0;
        _art.contentMode = UIViewContentModeCenter; _art.backgroundColor = UIColor.systemGreenColor;
        _art.tintColor = UIColor.whiteColor; _art.layer.cornerRadius = 30;
    } else {
        _cArt.contentMode = UIViewContentModeScaleAspectFill; _cArt.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
        _cArt.layer.cornerRadius = 7;
        _art.contentMode = UIViewContentModeScaleAspectFill; _art.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
        _art.layer.cornerRadius = 11;
    }
    [self layoutFull];
}

#pragma mark - Состояния
- (void)setMode:(ISLMode)m {
    BOOL changed = (_mode != m);
    _mode = m;
    if (m == ISLModeNone) {
        _expanded = NO;
        [_timer invalidate]; _timer = nil;
    } else if (!_timer) {
        _timer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(tickUI) userInfo:nil repeats:YES];
    }
    if (changed) [self configureForMode];
    [self transition];
    [self tickUI];
}
- (void)setExpanded:(BOOL)e {
    if (_expanded == e) return;
    _expanded = e;
    [self transition];
    [self tickUI];
}

- (void)transition {
    BOOL on = (_mode != ISLModeNone);
    BOOL exp = on && _expanded;
    BOOL showCompact = on && !exp;
    CGRect target = [self targetFrame];
    CGFloat radius = on ? MIN(exp ? 44.0 : PILL_H / 2, target.size.height / 2) : target.size.height / 2;
    UIViewAnimationOptions o = UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction;

    [UIView animateWithDuration:(exp ? 0.55 : 0.5) delay:0 usingSpringWithDamping:(exp ? 0.72 : 0.84)
        initialSpringVelocity:0.3 options:o animations:^{
            self.frame = target;
            self.layer.cornerRadius = radius;
            self.alpha = on ? 1 : 0;
        } completion:nil];
    [UIView animateWithDuration:(showCompact ? 0.25 : 0.1) delay:(showCompact ? 0.15 : 0) options:o animations:^{
        self->_compact.alpha = showCompact ? 1 : 0;
    } completion:nil];
    [UIView animateWithDuration:(exp ? 0.3 : 0.12) delay:(exp ? 0.12 : 0) options:o animations:^{
        self->_full.alpha = exp ? 1 : 0;
        self->_full.transform = exp ? CGAffineTransformIdentity : CGAffineTransformMakeScale(0.9, 0.9);
    } completion:nil];
}

- (void)tickUI {
    if (_mode == ISLModeMedia && _du > 0) {
        NSDate *ts = _ts ?: NSDate.date;
        double cur = _el + (_rate > 0 ? [NSDate.date timeIntervalSinceDate:ts] * _rate : 0);
        cur = MAX(0, MIN(cur, _du));
        _elL.text = ISLFmt(cur);
        _remL.text = [@"-" stringByAppendingString:ISLFmt(_du - cur)];
        _fill.frame = CGRectMake(0, 0, _track.bounds.size.width * (CGFloat)(cur / _du), _track.bounds.size.height);
    } else if (_mode == ISLModeCall) {
        NSString *t = _callStart ? ISLFmt([NSDate.date timeIntervalSinceDate:_callStart]) : @"";
        _cTime.text = t;
        _artistL.text = t;
    }
}

- (void)updateMedia:(NSDictionary *)i {
    if (_inCall) return;
    id t = i[@"kMRMediaRemoteNowPlayingInfoTitle"];
    id a = i[@"kMRMediaRemoteNowPlayingInfoArtist"];
    id ad = i[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    id ts = i[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    _rate = [i[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] doubleValue];
    _el = [i[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] doubleValue];
    _du = [i[@"kMRMediaRemoteNowPlayingInfoDuration"] doubleValue];
    _ts = [ts isKindOfClass:NSDate.class] ? ts : NSDate.date;
    BOOL has = [t isKindOfClass:NSString.class] && [t length] > 0;
    if (has) {
        _titleL.text = t;
        _artistL.text = [a isKindOfClass:NSString.class] ? a : @"";
        UIImage *img = ([ad isKindOfClass:NSData.class] && [ad length] > 0) ? [UIImage imageWithData:ad] : nil;
        _cArt.image = img; _art.image = img;
        UIColor *c = ISLAvgColor(img);
        _cEQ.color = c; _eq.color = c;
        [_play setImage:ISLSym(_rate > 0 ? @"pause.fill" : @"play.fill", 30) forState:UIControlStateNormal];
        _cEQ.running = _rate > 0; _eq.running = _rate > 0;
    }
    BOOL show = has && (_rate > 0 || _expanded);
    self.mode = show ? ISLModeMedia : ISLModeNone;
}

- (void)showCall {
    _titleL.text = _callConnected ? @"Звонок" : (_callOutgoing ? @"Вызов…" : @"Входящий звонок");
    _art.image = ISLSym(@"phone.fill", 26);
    _cArt.image = ISLSym(@"phone.fill", 15);
    self.mode = ISLModeCall;
}
@end

// ================= Окно, пропускающее касания =================
@interface ISLWindow : UIWindow @end
@implementation ISLWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:p withEvent:e];
    return (v == self || v == self.rootViewController.view) ? nil : v;
}
@end

// ================= Контроллер =================
@interface ISLController : NSObject <CXCallObserverDelegate>
@property (nonatomic, strong) ISLWindow *win;
@property (nonatomic, strong) ISLPill *pill;
@property (nonatomic, strong) ISLBar *bar;
@property (nonatomic, strong) CXCallObserver *calls;
+ (instancetype)shared;
- (void)start;
@end

@implementation ISLController
+ (instancetype)shared {
    static ISLController *c; static dispatch_once_t o;
    dispatch_once(&o, ^{ c = [ISLController new]; });
    return c;
}
- (void)start {
    if (self.win) return;
    self.win = [[ISLWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.win.windowLevel = UIWindowLevelAlert + 3000;
    self.win.backgroundColor = UIColor.clearColor;
    if ([self.win respondsToSelector:@selector(_setSecure:)]) [self.win _setSecure:YES];
    self.win.rootViewController = [UIViewController new];
    self.win.rootViewController.view.backgroundColor = UIColor.clearColor;
    self.bar = [ISLBar new];
    self.pill = [ISLPill new];
    [self.win.rootViewController.view addSubview:self.bar];
    [self.win.rootViewController.view addSubview:self.pill];
    self.win.hidden = NO;

    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (h) {
        MRGetInfo  = (MRGetInfoFn)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
        MRRegister = (MRRegisterFn)dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
        MRSend     = (MRSendFn)dlsym(h, "MRMediaRemoteSendCommand");
    }
    if (MRRegister) MRRegister(dispatch_get_main_queue());
    for (NSString *n in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                          @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"])
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:n object:nil];
    self.calls = [CXCallObserver new];
    [self.calls setDelegate:self queue:dispatch_get_main_queue()];
    [self refresh];
}
- (void)refresh {
    if (!MRGetInfo) return;
    MRGetInfo(dispatch_get_main_queue(), ^(NSDictionary *info) { [self.pill updateMedia:info ?: @{}]; });
}
- (void)callObserver:(CXCallObserver *)o callChanged:(CXCall *)call {
    CXCall *cur = nil;
    for (CXCall *c in o.calls) if (!c.hasEnded) { cur = c; break; }
    if (!cur) {
        self.pill.inCall = NO; self.pill.callStart = nil;
        [self refresh];
        return;
    }
    self.pill.inCall = YES;
    self.pill.callOutgoing = cur.isOutgoing;
    self.pill.callConnected = cur.hasConnected;
    if (cur.hasConnected && !self.pill.callStart) self.pill.callStart = NSDate.date;
    [self.pill showCall];
}
@end

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)app {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ [[ISLController shared] start]; });
}
%end
