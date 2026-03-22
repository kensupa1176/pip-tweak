#import <AVKit/AVKit.h>
#import <UIKit/UIKit.h>

static UIWindow *floatWindow;
static AVPictureInPictureController *pipController;

@interface FloatingButton : NSObject
+ (void)show;
@end

@implementation FloatingButton

+ (UIWindow *)getKeyWindow {
    NSSet *scenes = [UIApplication sharedApplication].connectedScenes;
    for (UIScene *scene in scenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow) return w;
        }
    }
    return nil;
}

+ (void)show {
    if (floatWindow) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIWindowScene *ws = nil;
            for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                if ([s isKindOfClass:[UIWindowScene class]]) {
                    ws = (UIWindowScene *)s;
                    break;
                }
            }
            if (!ws) return;

            floatWindow = [[UIWindow alloc] initWithWindowScene:ws];
            floatWindow.frame = CGRectMake(20, 100, 60, 60);
            floatWindow.windowLevel = UIWindowLevelAlert + 1;
            floatWindow.hidden = NO;
            floatWindow.rootViewController = [UIViewController new];

            UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
            btn.frame = CGRectMake(0, 0, 60, 60);
            btn.backgroundColor = [UIColor colorWithRed:0.8 green:0 blue:0 alpha:0.85];
            btn.layer.cornerRadius = 30;
            btn.layer.borderWidth = 2;
            btn.layer.borderColor = [UIColor whiteColor].CGColor;
            [btn setTitle:@"PiP" forState:UIControlStateNormal];
            btn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
            [btn addTarget:[FloatingButton class]
                    action:@selector(onTap)
          forControlEvents:UIControlEventTouchUpInside];

            UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                initWithTarget:[FloatingButton class]
                        action:@selector(onPan:)];
            [btn addGestureRecognizer:pan];

            [floatWindow addSubview:btn];
        } @catch (NSException *e) {
            NSLog(@"[PiPTweak] show error: %@", e);
        }
    });
}

+ (void)onTap {
    @try {
        UIWindow *win = [self getKeyWindow];
        if (!win) return;
        AVPlayerViewController *pvc = [self findPlayer:win.rootViewController];
        if (pvc && pvc.player) {
            AVPlayerLayer *layer = [AVPlayerLayer playerLayerWithPlayer:pvc.player];
            if ([AVPictureInPictureController isPictureInPictureSupported]) {
                pipController = [[AVPictureInPictureController alloc] initWithPlayerLayer:layer];
                [pipController startPictureInPicture];
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[PiPTweak] tap error: %@", e);
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
    floatWindow.center = CGPointMake(floatWindow.center.x + d.x,
                                     floatWindow.center.y + d.y);
    [pan setTranslation:CGPointZero inView:floatWindow];
}

@end

%hook UIApplication
- (void)applicationDidBecomeActive:(UIApplication *)app {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [FloatingButton show];
    });
}
%end
