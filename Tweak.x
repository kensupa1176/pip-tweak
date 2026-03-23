#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

static UIWindow *floatWindow;
static UILabel *statusLabel;


static WKWebView *findWebView(UIView *view) {
    if ([view isKindOfClass:[WKWebView class]]) return (WKWebView *)view;
    for (UIView *sub in view.subviews) {
        WKWebView *found = findWebView(sub);
        if (found) return found;
    }
    return nil;
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
        if (!ws) return;

        // WKWebViewを探す
        WKWebView *webView = nil;
        for (UIWindow *win in ws.windows) {
            webView = findWebView(win);
            if (webView) break;
        }

        if (!webView) {
            statusLabel.text = @"WebViewなし";
            NSLog(@"[PiPTweak] no WKWebView found");
            return;
        }

        statusLabel.text = @"JS注入中";

        // video要素にPiPを起動するJS
        NSString *js = @""
            "var videos = document.querySelectorAll('video');"
            "var result = '動画なし';"
            "for (var i = 0; i < videos.length; i++) {"
            "  var v = videos[i];"
            "  if (!v.paused || v.currentTime > 0) {"
            "    if (v.webkitSupportsPresentationMode && v.webkitSupportsPresentationMode('picture-in-picture')) {"
            "      v.webkitSetPresentationMode('picture-in-picture');"
            "      result = 'OK';"
            "      break;"
            "    } else if (document.pictureInPictureEnabled) {"
            "      v.requestPictureInPicture();"
            "      result = 'OK2';"
            "      break;"
            "    } else {"
            "      result = '非対応';"
            "    }"
            "  }"
            "}"
            "result;";

        [webView evaluateJavaScript:js completionHandler:^(id result, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error) {
                    statusLabel.text = @"JSエラー";
                    NSLog(@"[PiPTweak] JS error: %@", error);
                } else {
                    statusLabel.text = [NSString stringWithFormat:@"%@", result ?: @"?"];
                    NSLog(@"[PiPTweak] JS result: %@", result);
                }
            });
        }];
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
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            [PiPButton show];
        }
    );
}
