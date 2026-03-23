#import <UIKit/UIKit.h>
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

static UIWindow *floatWindow;
static AVPictureInPictureController *pipController;
static NSMutableArray *capturedPlayers = nil;
static UILabel *statusLabel = nil;
static UIView *pipHostView = nil;

static id (*orig_initWithPlayerItem)(id, SEL, id) = NULL;
static id swizzled_initWithPlayerItem(id self, SEL _cmd, id item) {
    id player = orig_initWithPlayerItem(self, _cmd, item);
    if (player && ![capturedPlayers containsObject:player]) {
        [capturedPlayers addObject:player];
        dispatch_async(dispatch_get_main_queue(), ^{
            statusLabel.text = [NSString stringWithFormat:@"▶%lu", (unsigned long)capturedPlayers.count];
        });
    }
    return player;
}

static id (*orig_initWithURL)(id, SEL, id) = NULL;
static id swizzled_initWithURL(id self, SEL _cmd, id url) {
    id player = orig_initWithURL(self, _cmd, url);
    if (player && ![capturedPlayers containsObject:player]) {
        [capturedPlayers addObject:player];
        dispatch_async(dispatch_get_main_queue(), ^{
            statusLabel.text = [NSString stringWithFormat:@"▶%lu", (unsigned long)capturedPlayers.count];
        });
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
        floatWindow.frame = CGRectMake(20, 120, 70, 80);
        floatWindow.windowLevel = UIWindowLevelAlert + 100;
        floatWindow.backgroundColor = [UIColor clearColor];
        floatWindow.rootViewController = [UIViewController new];
        floatWindow.rootViewController.view.backgroundColor = [UIColor clearColor];
        floatWindow.hidden = NO;

        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(5, 5, 60, 60);
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

        // プレイヤー数表示ラベル
        statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 65, 70, 15)];
        statusLabel.textColor = [UIColor yellowColor];
        statusLabel.font = [UIFont systemFontOfSize:10];
        statusLabel.textAlignment = NSTextAlignmentCenter;
        statusLabel.text = @"0";

        [floatWindow.rootViewController.view addSubview:btn];
        [floatWindow.rootViewController.view addSubview:statusLabel];
    } @catch (NSException *e) {
        NSLog(@"[PiPTweak] show: %@", e);
    }
}

+ (void)onTap {
    @try {
        if (![AVPictureInPictureController isPictureInPictureSupported]) {
            statusLabel.text = @"非対応";
            return;
        }

        if (capturedPlayers.count == 0) {
            statusLabel.text = @"なし";
            return;
        }

        [[AVAudioSession sharedInstance]
            setCategory:AVAudioSessionCategoryPlayback error:nil];
        [[AVAudioSession sharedInstance] setActive:YES error:nil];

        // 全プレイヤーを試す
        for (AVPlayer *player in [capturedPlayers reverseObjectEnumerator]) {
            if (!player) continue;

            if (!pipHostView) {
                UIWindowScene *ws = nil;
                for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                    if ([s isKindOfClass:[UIWindowScene class]]) {
                        ws = (UIWindowScene *)s; break;
                    }
                }
                UIWindow *mainWin = ws.windows.firstObject;
                pipHostView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
                pipHostView.alpha = 0.01;
                [mainWin addSubview:pipHostView];
            }

            if (pipController) {
                [pipController stopPictureInPicture];
                pipController = nil;
            }

            AVPlayerLayer *layer = [AVPlayerLayer playerLayerWithPlayer:player];
            layer.frame = pipHostView.bounds;
            [pipHostView.layer addSublayer:layer];

            pipController = [[AVPictureInPictureController alloc] initWithPlayerLayer:layer];

            NSInteger idx = [capturedPlayers indexOfObject:player];
            statusLabel.text = [NSString stringWithFormat:@"P%ld試中", (long)idx];

            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    if ([pipController isPictureInPicturePossible]) {
                        [pipController startPictureInPicture];
                        statusLabel.text = @"OK!";
                    } else {
                        statusLabel.text = @"NG";
                    }
                }
            );
            break;
        }
    } @catch (NSException *e) {
        statusLabel.text = @"ERR";
        NSLog(@"[PiPTweak] tap: %@", e);
    }
}

+ (void)onPan:(UIPanGestureRecognizer *)pan {
    CGPoint d = [pan translationInView:floatWindow];
    CGPoint center = floatWindow.center;
    center.x += d.x;
    center.y += d.y;
    CGSize screen = [UIScreen mainScreen].bounds.size;
    center.x = MAX(35, MIN(center.x, screen.width - 35));
    center.y = MAX(60, MIN(center.y, screen.height - 60));
    floatWindow.center = center;
    [pan setTranslation:CGPointZero inView:floatWindow];
}

@end

__attribute__((constructor))
static void PiPTweakInit() {
    capturedPlayers = [NSMutableArray array];

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

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            [PiPButton show];
        }
    );
}
