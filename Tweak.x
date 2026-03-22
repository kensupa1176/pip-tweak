#import <UIKit/UIKit.h>
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>

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
+ (AVPlayerLayer *)findPlayerLayer:(CALayer *)layer;
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
        if (![AVPictureInPictureController isPictureInPictureSupported]) {
            NSLog(@"[PiPTweak] PiP not supported on this device");
            return;
        }

        UIWindowScene *ws = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]]) {
                ws = (UIWindowScene *)s; break;
            }
        }
        if (!ws) return;

        AVPlayerLayer *found = nil;
        for (UIWindow *win in ws.windows) {
            found = [self findPlayerLayer:win.layer];
            if (found) break;
        }

        if (found) {
            NSLog(@"[PiPTweak] found AVPlayerLayer, starting PiP");
            pipController = [[AVPictureInPictureController alloc] initWithPlayerLayer:found];
            pipController.requiresLinearPlayback = NO;
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    [pipController startPictureInPicture];
                }
            );
        } else {
            NSLog(@"[PiPTweak] AVPlayerLayer not found");
        }
    } @catch (NSException *e) {
        NSLog(@"[PiPTweak] tap: %@", e);
    }
}

+ (AVPlayerLayer *)findPlayerLayer:(CALayer *)layer {
    if (!layer) return nil;
    if ([layer isKindOfClass:[AVPlayerLayer class]]) {
        AVPlayerLayer *pl = (AVPlayerLayer *)layer;
        if (pl.player) return pl;
    }
    for (CALayer *sub in layer.sublayers) {
        AVPlayerLayer *f = [self findPlayerLayer:sub];
        if (f) return f;
    }
    return nil;
}

+ (void)onPan:(UIPanGestureRecognizer *)pan {
    CGPoint d = [pan translationInView:floatWindow];
    CGPoint center = floatWindow.center;
    center.x += d.x;
    center.y += d.y;

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
