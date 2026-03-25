#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

static UIWindow *floatWindow;
static UIWindow *alertWindow;
static UILabel *statusLabel;

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
+ (void)showAlert:(NSString *)message;
+ (void)collectWebViews:(UIView *)view into:(NSMutableArray *)arr;
@end

@implementation PiPButton

+ (void)showAlert:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindowScene *ws = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]]) {
                ws = (UIWindowScene *)s; break;
            }
        }
        if (!ws) return;

        alertWindow = [[UIWindow alloc] initWithWindowScene:ws];
        alertWindow.windowLevel = UIWindowLevelAlert + 200;
        alertWindow.backgroundColor = [UIColor clearColor];
        UIViewController *vc = [UIViewController new];
        alertWindow.rootViewController = vc;
        alertWindow.hidden = NO;
        [alertWindow makeKeyAndVisible];

        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"PiP Debug"
            message:message
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction
            actionWithTitle:@"OK"
            style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a) {
                alertWindow.hidden = YES;
                alertWindow = nil;
            }]];
        [vc presentViewController:alert animated:YES completion:nil];
    });
}

+ (void)collectWebViews:(UIView *)view into:(NSMutableArray *)arr {
    if ([view isKindOfClass:[WKWebView class]]) [arr addObject:view];
    for (UIView *sub in view.subviews) [self collectWebViews:sub into:arr];
}

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
        floatWindow.frame = CGRectMake(20, 120, 70, 85);
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

        statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 67, 70, 16)];
        statusLabel.textColor = [UIColor yellowColor];
        statusLabel.font = [UIFont systemFontOfSize:10];
        statusLabel.textAlignment = NSTextAlignmentCenter;
        statusLabel.text = @"待機";

        [floatWindow.rootViewController.view addSubview:btn];
        [floatWindow.rootViewController.view addSubview:statusLabel];
    } @catch (NSException *e) {}
}

+ (void)onTap {
    @try {
        UIWindowScene *ws = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]]) {
                ws = (UIWindowScene *)s; break;
            }
        }
        if (!ws) return;

        NSMutableArray *allWebViews = [NSMutableArray array];
        for (UIWindow *win in ws.windows) {
            [self collectWebViews:win into:allWebViews];
        }

        if (allWebViews.count == 0) {
            [self showAlert:@"WebViewなし"];
            statusLabel.text = @"WebViewなし";
            return;
        }

        statusLabel.text = @"起動中";

        for (WKWebView *wv in allWebViews) {
            NSString *js = @""
                "(function() {"
                "  var videos = document.querySelectorAll('video');"
                "  for (var i = 0; i < videos.length; i++) {"
                "    var v = videos[i];"
                "    if (v.webkitSupportsPresentationMode && v.webkitSupportsPresentationMode('picture-in-picture')) {"
                "      v.webkitSetPresentationMode('picture-in-picture');"
                "      return 'OK-webkit:' + location.href.substring(0,30);"
                "    }"
                "    if (document.pictureInPictureEnabled) {"
                "      v.requestPictureInPicture();"
                "      return 'OK-pip:' + location.href.substring(0,30);"
                "    }"
                "    return 'NG:' + location.href.substring(0,30);"
                "  }"
                "  return null;"
                "})();";

            [wv evaluateJavaScript:js completionHandler:^(id result, NSError *error) {
                if (result && ![result isEqual:[NSNull null]]) {
                    NSString *str = [NSString stringWithFormat:@"%@", result];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if ([str hasPrefix:@"OK"]) {
                            statusLabel.text = @"OK!";
                        } else if ([str hasPrefix:@"NG"]) {
                            statusLabel.text = @"NG";
                            [PiPButton showAlert:[NSString stringWithFormat:@"PiP非対応:\n%@", str]];
                        }
                        NSLog(@"[PiPTweak] result: %@", str);
                    });
                }
            }];
        }
    } @catch (NSException *e) {
        [self showAlert:[NSString stringWithFormat:@"ERR: %@", e]];
        statusLabel.text = @"ERR";
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
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            [PiPButton show];
        }
    );
}
