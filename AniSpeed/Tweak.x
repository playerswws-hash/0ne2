#import <UIKit/UIKit.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <string.h>
#import <math.h>
#import <stdlib.h>

// ---------- Настройки ----------
#define SPEED_X   12.0    // отступ слева
#define SPEED_Y   46.0    // отступ сверху (46 = сразу под статус-баром iPhone 11)
#define SPEED_W   156.0   // ширина плашки
#define SPEED_H   14.0    // высота плашки
#define SPEED_BG  0.45    // прозрачность чёрного фона плашки (0 = без фона)
#define RESPRING_HOLD 0.8 // сколько секунд держать плашку для Respring

// Окно размером с плашку; касания принимает только сама плашка
@interface ASSWindow : UIWindow
@end
@implementation ASSWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:p withEvent:e];
    if (v == self || v == self.rootViewController.view) return nil;
    return v;
}
@end

@interface ASSMeter : NSObject
@property (nonatomic, strong) ASSWindow *window;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, assign) uint64_t lastRx;
@property (nonatomic, assign) uint64_t lastTx;
@property (nonatomic, assign) CFAbsoluteTime lastTime;
@property (nonatomic, assign) BOOL started;
+ (instancetype)shared;
- (void)start;
@end

static void ASSReadCounters(uint64_t *rx, uint64_t *tx) {
    *rx = 0; *tx = 0;
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return;
    for (struct ifaddrs *a = list; a; a = a->ifa_next) {
        if (!a->ifa_addr || a->ifa_addr->sa_family != AF_LINK) continue;
        if (!(a->ifa_flags & IFF_UP)) continue;
        const char *n = a->ifa_name;
        BOOL wifi = (strcmp(n, "en0") == 0);
        BOOL cell = (strncmp(n, "pdp_ip", 6) == 0);
        if (!wifi && !cell) continue;
        struct if_data *d = (struct if_data *)a->ifa_data;
        if (!d) continue;
        *rx += d->ifi_ibytes;
        *tx += d->ifi_obytes;
    }
    freeifaddrs(list);
}

static NSString *ASSBat(void) {
    float lvl = UIDevice.currentDevice.batteryLevel;
    if (lvl < 0) return @"";
    UIDeviceBatteryState st = UIDevice.currentDevice.batteryState;
    BOOL chg = (st == UIDeviceBatteryStateCharging || st == UIDeviceBatteryStateFull);
    return [NSString stringWithFormat:@" · %@%d%%", chg ? @"⚡" : @"", (int)roundf(lvl * 100)];
}

static NSString *ASSFmt(double b) {
    if (b < 1024.0) return [NSString stringWithFormat:@"%.0fB", b];
    if (b < 1024.0 * 1024.0) return [NSString stringWithFormat:@"%.0fK", b / 1024.0];
    return [NSString stringWithFormat:@"%.1fM", b / 1048576.0];
}

@implementation ASSMeter

+ (instancetype)shared {
    static ASSMeter *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [ASSMeter new]; });
    return s;
}

- (void)buildWindow {
    if (self.window) return;
    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
    }
    CGRect f = CGRectMake(SPEED_X, SPEED_Y, SPEED_W, SPEED_H);
    ASSWindow *w = scene ? [[ASSWindow alloc] initWithWindowScene:scene]
                         : [[ASSWindow alloc] initWithFrame:f];
    w.frame = f;
    w.windowLevel = UIWindowLevelAlert + 900;
    w.backgroundColor = UIColor.clearColor;

    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.clearColor;
    w.rootViewController = vc;

    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, SPEED_W, SPEED_H)];
    l.textAlignment = NSTextAlignmentCenter;
    l.textColor = UIColor.whiteColor;
    l.font = [UIFont monospacedDigitSystemFontOfSize:9 weight:UIFontWeightMedium];
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:SPEED_BG];
    l.layer.cornerRadius = SPEED_H / 2;
    l.clipsToBounds = YES;
    l.text = @"↓ 0B  ↑ 0B";
    l.userInteractionEnabled = YES;
    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(respring:)];
    lp.minimumPressDuration = RESPRING_HOLD;
    [l addGestureRecognizer:lp];
    [vc.view addSubview:l];

    w.hidden = NO;
    self.window = w; self.label = l;
}

- (void)respring:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    [[UIImpactFeedbackGenerator new] impactOccurred];
    self.label.text = @"Respring...";
    self.started = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ exit(0); });
}

- (void)tick {
    uint64_t rx, tx;
    ASSReadCounters(&rx, &tx);
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (self.lastTime > 0 && rx >= self.lastRx && tx >= self.lastTx) {
        double dt = now - self.lastTime;
        if (dt > 0.2) {
            double down = (double)(rx - self.lastRx) / dt;
            double up = (double)(tx - self.lastTx) / dt;
            self.label.text = [NSString stringWithFormat:@"↓ %@  ↑ %@%@", ASSFmt(down), ASSFmt(up), ASSBat()];
        }
    }
    self.lastRx = rx; self.lastTx = tx; self.lastTime = now;
}

- (void)start {
    if (self.started) return;
    self.started = YES;
    UIDevice.currentDevice.batteryMonitoringEnabled = YES;
    [self buildWindow];
    [self tick];
    NSTimer *t = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *x) { [self tick]; }];
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
}
@end

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[ASSMeter shared] start];
    });
}
%end
