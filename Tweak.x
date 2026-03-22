#import <AVKit/AVKit.h>
#import <UIKit/UIKit.h>

@interface FloatingButton : NSObject
+ (void)show;
@end

static UIWindow *floatWindow;

@implementation FloatingButton

+ (void)show {
    if (floatWindow) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        floatWindow = [[UIWindow alloc] initWithFrame:CGRectMake(20, 100, 60, 60)];
        floatWindow.windowLevel = UIWindowLevelAlert + 1;
        floatWindow.hidden = NO;

        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = floatWindow.bounds;
        btn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
        btn.layer.cornerRadius = 30;
        btn.layer.borderWidth = 2;
        btn.layer.borderColor = [UIColor whiteColor].CGColor;
        [btn setTitle:@"PiP" forState:UIControlStateNormal];
        [btn addTarget:[FloatingButton class] action:@selector(onTap) forControlEvents:UIControlEventTouchUpInside];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:[FloatingButton class] action:@selector(onPan:)];
        [btn addGestureRecognizer:pan];

        [floatWindow addSubview:btn];
        floatWindow.rootViewController = [UIViewController new];
    });
}

+ (void)onTap {
    UIViewController *root = [UIApplication sharedApplication].keyWindow.rootViewController;
    AVPlayerViewController *pvc = [self findPlayer:root];
    if (pvc) {
        pvc.allowsPictureInPicturePlayback = YES;
        [pvc.pictureInPictureController startPictureInPicture];
    }
}

+ (AVPlayerViewController *)findPlayer:(UIViewController *)vc {
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
    floatWindow.center = CGPointMake(floatWindow.center.x + d.x, floatWindow.center.y + d.y);
    [pan setTranslation:CGPointZero inView:floatWindow];
}

@end

%hook UIApplication
- (void)applicationDidBecomeActive:(UIApplication *)app {
    %orig;
    [FloatingButton show];
}
%end
