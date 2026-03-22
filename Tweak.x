#import <UIKit/UIKit.h>

static UIWindow *floatWindow;

__attribute__((constructor))
static void PiPTweakInit() {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            @try {
                UIWindowScene *ws = nil;
                for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                    if ([s isKindOfClass:[UIWindowScene class]]) {
                        ws = (UIWindowScene *)s; break;
                    }
                }
                if (!ws) return;

                floatWindow = [[UIWindow alloc] initWithWindowScene:ws];
                floatWindow.frame = CGRectMake(20, 120, 60, 60);
                floatWindow.windowLevel = UIWindowLevelAlert + 100;
                floatWindow.rootViewController = [UIViewController new];
                floatWindow.hidden = NO;

                UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
                btn.frame = CGRectMake(0, 0, 60, 60);
                btn.backgroundColor = [UIColor redColor];
                btn.layer.cornerRadius = 30;
                [btn setTitle:@"PiP" forState:UIControlStateNormal];
                [floatWindow.rootViewController.view addSubview:btn];
            } @catch (NSException *e) {
                NSLog(@"[PiPTweak] %@", e);
            }
        }
    );
}
