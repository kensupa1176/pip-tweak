#import <UIKit/UIKit.h>
#import <AVKit/AVKit.h>

static UIWindow *floatWindow;
static AVPictureInPictureController *pipController;

@interface PassthroughWindow : UIWindow
@end

@implementation PassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}
@end

@interface PiPButton : NSObject
+ (void)show;
+ (void)onTap;
+ (void)onPan:(UIPanGestureRecognizer *)pan;
+ (AVPlayerViewController *)findPlayer:(UIViewController *)vc;
@end

@implementation PiPButton

+ (void)show {
    if (floatWindow) return;
    @try {
        UIWindowScene *ws = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]]) {
                ws = (UIWindowScene *)s; break;
            }
        }
        if (!ws) return;

        floatWindow = [[PassthroughWindow alloc] initWithWindowScene:ws];
        floatWindow.frame = CGRectMake(20, 120, 60, 60);
        floatWindow.windowLevel = UIWindowLevelAlert + 100;
        floatWindow.backgroundColor = [UIColor clearColor];
        floatWindow.rootViewController = [UIViewController new];
        floatWindow.rootViewController.view.backgroundColor = [UIColor clearColor];
        floatWindow.hidden = NO;

        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(0, 0, 60, 60);
        btn.backgroundColor = [UIColor colorWithRed:0.85 green:0.0 blue:0.0 alpha:0.9];
        btn.layer.cornerRadius = 30;
        btn.layer.borderWidth = 2.0;
        btn.layer.borderColor = [UIColor whiteColor].CGColor;
        btn.clipsToBounds = YES;
        [btn setTitle:@"PiP" forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        [btn addTarget:self action:@selector(onTap) forControlEvents:UIControlEventTouchUpInside];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:self action:@selector(onPan:)];
        [btn addGestureRecognizer:pan];

        [floatWindow.rootViewController.view addSubview:btn];
    } @catch (NSException *e) {
        NSLog(@"[PiPTweak] show: %@", e);
    }
}

+ (void)onTap {
    @try {
        UIWindowScene *ws = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]]) {
                ws = (UIWindowScene *)s; break;
            }
        }
        UIWindow *win = ws.windows.firstObject;
        if (!win) return;

        AVPlayerViewController *pvc = [self findPlayer:win.rootViewController];
        if (pvc && pvc.player) {
            AVPlayerLayer *layer = [AVPlayerLayer playerLayerWithPlayer:pvc.player];
            if ([AVPictureInPictureController isPictureInPictureSupported]) {
                pipController = [[AVPictureInPictureController alloc] initWithPlayerLayer:layer];
                [pipController startPictureInPicture];
            }
        } else {
            NSLog(@"[PiPTweak] player not found");
        }
    } @catch (NSException *e) {
        NSLog(@"[PiPTweak] tap: %@", e);
    }
}

+ (AVPlayerViewController *)findPlayer:(UIViewController *)vc {
    if (!vc) return nil;
    if ([vc isKindOfClass:[AVPlayerViewController class]]) return (AVPlayerViewController *)vc;
    for (UIViewController *c in vc.childViewControllers) {
        AVPlayerViewController *f = [self findPlayer:c];
        if (f) return f;
    }
    if (vc.presentedViewController) return [self findPlayer:vc.presentedViewController];
    return nil;
}

+ (void)onPan:(UIPanGestureRecognizer *)pan {
    CGPoint d = [pan translationInView:floatWindow];
    CGPoint center = floatWindow.center;
    center.x += d.x;
    center.y += d.y;

    // 画面外に出ないようにする
    CGSize screen = [UIScreen mainScreen].bounds.size;
    center.x = MAX(30, MIN(center.x, screen.width - 30));
    center.y = MAX(60, MIN(center.y, screen.height - 60));

    floatWindow.center = center;
    [pan setTranslation:CGPointZero inView:floatWindow];
}

@end

__attribute__((constructor))
static void PiPTweakInit() {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            [PiPButton show];
        }
    );
}
