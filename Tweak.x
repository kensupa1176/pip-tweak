#import <UIKit/UIKit.h>
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

static UIWindow *floatWindow;
static AVPictureInPictureController *pipController;
static AVPlayer *capturedPlayer = nil;
static AVPlayerLayer *pipPlayerLayer = nil;
static UIView *hiddenPlayerView = nil;

// AVPlayer initをフックしてインスタンスを捕まえる
static id (*orig_initWithPlayerItem)(id, SEL, id) = NULL;
static id swizzled_initWithPlayerItem(id self, SEL _cmd, id item) {
    id player = orig_initWithPlayerItem(self, _cmd, item);
    if (player) {
        capturedPlayer = player;
        NSLog(@"[PiPTweak] captured AVPlayer");
    }
    return player;
}

static id (*orig_initWithURL)(id, SEL, id) = NULL;
static id swizzled_initWithURL(id self, SEL _cmd, id url) {
    id player = orig_initWithURL(self, _cmd, url);
    if (player) {
        capturedPlayer = player;
        NSLog(@"[PiPTweak] captured AVPlayer via URL");
    }
    return player;
}

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

        if (!capturedPlayer) {
            NSLog(@"[PiPTweak] no player yet - play a video first");
            return;
        }

        // オーディオセッション設定
        [[AVAudioSession sharedInstance]
            setCategory:AVAudioSessionCategoryPlayback
            error:nil];
        [[AVAudioSession sharedInstance] setActive:YES error:nil];

        // 非表示のviewにAVPlayerLayerを追加
        if (!hiddenPlayerView) {
            UIWindowScene *ws = nil;
            for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                if ([s isKindOfClass:[UIWindowScene class]]) {
                    ws = (UIWindowScene *)s; break;
                }
            }
            UIWindow *mainWin = ws.windows.firstObject;
            hiddenPlayerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
            hiddenPlayerView.alpha = 0.01;
            [mainWin addSubview:hiddenPlayerView];
        }

        // 既存のpipControllerをクリア
        if (pipController) {
            [pipController stopPictureInPicture];
            pipController = nil;
        }
        if (pipPlayerLayer) {
            [pipPlayerLayer removeFromSuperlayer];
            pipPlayerLayer = nil;
        }

        pipPlayerLayer = [AVPlayerLayer playerLayerWithPlayer:capturedPlayer];
        pipPlayerLayer.frame = hiddenPlayerView.bounds;
        [hiddenPlayerView.layer addSublayer:pipPlayerLayer];

        pipController = [[AVPictureInPictureController alloc] initWithPlayerLayer:pipPlayerLayer];

        // PiPが準備できるまで待つ
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                if ([pipController isPictureInPicturePossible]) {
                    [pipController startPictureInPicture];
                    NSLog(@"[PiPTweak] PiP started");
                } else {
                    NSLog(@"[PiPTweak] not possible yet, retrying...");
                    dispatch_after(
                        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                        dispatch_get_main_queue(), ^{
                            [pipController startPictureInPicture];
                        }
                    );
                }
            }
        );
    } @catch (NSException *e) {
        NSLog(@"[PiPTweak] tap: %@", e);
    }
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
    Class playerClass = [AVPlayer class];

    Method m1 = class_getInstanceMethod(playerClass, @selector(initWithPlayerItem:));
    if (m1) {
        orig_initWithPlayerItem = (id(*)(id,SEL,id))method_getImplementation(m1);
        method_setImplementation(m1, (IMP)swizzled_initWithPlayerItem);
    }

    Method m2 = class_getInstanceMethod(playerClass, @selector(initWithURL:));
    if (m2) {
        orig_initWithURL = (id(*)(id,SEL,id))method_getImplementation(m2);
        method_setImplementation(m2, (IMP)swizzled_initWithURL);
    }

    NSLog(@"[PiPTweak] initialized");

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            [PiPButton show];
        }
    );
}
