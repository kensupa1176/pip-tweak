#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static UIWindow *floatWindow;
static UIWindow *alertWindow;
static UILabel *statusLabel;
static BOOL isPiPActive = NO;

static id (*orig_initWithFrame_config)(id, SEL, CGRect, id) = NULL;
static id swizzled_initWithFrame_config(id self, SEL _cmd, CGRect frame, WKWebViewConfiguration *config) {
    config.allowsPictureInPictureMediaPlayback = YES;
    config.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;

    NSString *src = @""
        "(function(){"
        "  function setup(){"
        "    document.querySelectorAll('video').forEach(function(v){"
        "      v.setAttribute('playsinline','');"
        "      v.setAttribute('webkit-playsinline','');"
        "      v.setAttribute('x-webkit-airplay','allow');"
        "    });"
        "  }"
        "  new MutationObserver(setup).observe(document.documentElement,{childList:true,subtree:true});"
        "  setup();"
        "})();";

    WKUserScript *script = [[WKUserScript alloc]
        initWithSource:src
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart
        forMainFrameOnly:NO];
    [config.userContentController addUserScript:script];
    return orig_initWithFrame_config(self, _cmd, frame, config);
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
+ (void)showAlert:(NSString *)msg;
+ (void)collectWebViews:(UIView *)view into:(NSMutableArray *)arr;
+ (void)triggerPiP:(WKWebView *)wv toggle:(BOOL)toggle;
+ (void)updateButtonState;
@end

@implementation PiPButton

+ (void)updateButtonState {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!floatWindow) return;
        UIButton *btn = nil;
        for (UIView *v in floatWindow.rootViewController.view.subviews) {
            if ([v isKindOfClass:[UIButton class]]) { btn = (UIButton *)v; break; }
        }
        if (!btn) return;
        if (isPiPActive) {
            btn.backgroundColor = [UIColor colorWithRed:0.0 green:0.5 blue:1.0 alpha:0.9];
            statusLabel.text = @"ON";
        } else {
            btn.backgroundColor = [UIColor colorWithRed:0.2 green:0.2 blue:0.2 alpha:0.9];
            statusLabel.text = @"OFF";
        }
    });
}

+ (void)showAlert:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (alertWindow) return;
        UIWindowScene *ws = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes)
            if ([s isKindOfClass:[UIWindowScene class]]) { ws=(UIWindowScene*)s; break; }
        if (!ws) return;
        alertWindow = [[UIWindow alloc] initWithWindowScene:ws];
        alertWindow.windowLevel = UIWindowLevelAlert + 200;
        alertWindow.backgroundColor = [UIColor clearColor];
        UIViewController *vc = [UIViewController new];
        alertWindow.rootViewController = vc;
        alertWindow.hidden = NO;
        [alertWindow makeKeyAndVisible];
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"PiP" message:msg
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
            style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a){ alertWindow.hidden=YES; alertWindow=nil; }]];
        [vc presentViewController:alert animated:YES completion:nil];
    });
}

+ (void)collectWebViews:(UIView *)view into:(NSMutableArray *)arr {
    if ([view isKindOfClass:[WKWebView class]]) [arr addObject:view];
    for (UIView *sub in view.subviews) [self collectWebViews:sub into:arr];
}

+ (void)triggerPiP:(WKWebView *)wv toggle:(BOOL)toggle {
    @try { [wv setValue:@YES forKeyPath:@"configuration.allowsPictureInPictureMediaPlayback"]; } @catch(NSException *e){}

    // toggleがYESならPiP終了、NOなら開始
    NSString *js = toggle
        ? @"(function(){"
          "  var vids=document.querySelectorAll('video');"
          "  if(!vids.length) return null;"
          "  var v=vids[0];"
          "  try{"
          "    if(v.webkitPresentationMode==='picture-in-picture'){"
          "      v.webkitSetPresentationMode('inline');"
          "      return 'STOPPED';"
          "    }"
          "  }catch(e){}"
          "  try{"
          "    if(document.pictureInPictureElement){"
          "      document.exitPictureInPicture();"
          "      return 'STOPPED';"
          "    }"
          "  }catch(e){}"
          "  return null;"
          "})();"
        : @"(function(){"
          "  var vids=document.querySelectorAll('video');"
          "  if(!vids.length) return null;"
          "  var v=vids[0];"
          "  var dbg='v:'+vids.length+' src:'+!!v.currentSrc+' paused:'+v.paused;"
          "  try{"
          "    if(v.webkitSupportsPresentationMode&&v.webkitSupportsPresentationMode('picture-in-picture')){"
          "      v.webkitSetPresentationMode('picture-in-picture');"
          "      return 'OK-webkit';"
          "    }"
          "  }catch(e){dbg+=' wkErr:'+e.message;}"
          "  try{"
          "    v.requestPictureInPicture();"
          "    return 'OK-pip';"
          "  }catch(e){dbg+=' pipErr:'+e.message;}"
          "  return dbg;"
          "})();";

    SEL sel = NSSelectorFromString(@"_evaluateJavaScript:inFrame:inContentWorld:withUserGesture:completionHandler:");
    void (^handler)(id, NSError *) = ^(id result, NSError *error) {
        if (!result || [result isEqual:[NSNull null]]) return;
        NSString *str = [NSString stringWithFormat:@"%@", result];
        NSLog(@"[PiPTweak] result: %@", str);
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([str hasPrefix:@"OK"]) {
                isPiPActive = YES;
                [PiPButton updateButtonState];
            } else if ([str isEqualToString:@"STOPPED"]) {
                isPiPActive = NO;
                [PiPButton updateButtonState];
            } else if (str.length > 2) {
                [PiPButton showAlert:str];
                if (statusLabel) statusLabel.text = @"詳細";
            }
        });
    };

    if ([wv respondsToSelector:sel]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wundeclared-selector"
        typedef void (*EvalIMP)(id, SEL, NSString*, id, id, BOOL, id);
        EvalIMP imp = (EvalIMP)objc_msgSend;
        imp(wv, sel, js, nil, WKContentWorld.pageWorld, YES, handler);
        #pragma clang diagnostic pop
    } else {
        [wv evaluateJavaScript:js completionHandler:handler];
    }
}

+ (void)show {
    if (floatWindow) return;
    @try {
        UIWindowScene *ws = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes)
            if ([s isKindOfClass:[UIWindowScene class]]) { ws=(UIWindowScene*)s; break; }
        if (!ws) return;

        floatWindow = [[PassthroughWindow alloc] initWithWindowScene:ws];
        floatWindow.frame = CGRectMake(20, 120, 70, 90);
        floatWindow.windowLevel = UIWindowLevelAlert + 100;
        floatWindow.backgroundColor = [UIColor clearColor];
        UIViewController *vc = [UIViewController new];
        vc.view.backgroundColor = [UIColor clearColor];
        floatWindow.rootViewController = vc;
        floatWindow.hidden = NO;

        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(5, 5, 60, 60);
        btn.backgroundColor = [UIColor colorWithRed:0.2 green:0.2 blue:0.2 alpha:0.9];
        btn.layer.cornerRadius = 30;
        btn.layer.borderWidth = 2.0;
        btn.layer.borderColor = [UIColor whiteColor].CGColor;
        btn.clipsToBounds = YES;
        [btn setTitle:@"📺" forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:26];
        [btn addTarget:self action:@selector(onTap) forControlEvents:UIControlEventTouchUpInside];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:self action:@selector(onPan:)];
        [btn addGestureRecognizer:pan];

        statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 68, 70, 18)];
        statusLabel.textColor = [UIColor whiteColor];
        statusLabel.font = [UIFont boldSystemFontOfSize:10];
        statusLabel.textAlignment = NSTextAlignmentCenter;
        statusLabel.text = @"OFF";

        [vc.view addSubview:btn];
        [vc.view addSubview:statusLabel];
    } @catch (NSException *e) {
        NSLog(@"[PiPTweak] show error: %@", e);
    }
}

+ (void)onTap {
    @try {
        UIWindowScene *ws = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes)
            if ([s isKindOfClass:[UIWindowScene class]]) { ws=(UIWindowScene*)s; break; }
        if (!ws) return;

        // 毎回WebViewを探し直す
        NSMutableArray *all = [NSMutableArray array];
        for (UIWindow *win in ws.windows) {
            if (win == floatWindow || win == alertWindow) continue;
            [self collectWebViews:win into:all];
        }

        if (!all.count) {
            [self showAlert:@"WebViewなし"];
            return;
        }

        // 動画のあるWebViewだけに絞る
        NSString *checkJS = @"document.querySelectorAll('video').length;";
        __block NSInteger checked = 0;
        NSInteger total = all.count;

        for (WKWebView *wv in all) {
            [wv evaluateJavaScript:checkJS completionHandler:^(id result, NSError *error) {
                checked++;
                NSInteger count = [result integerValue];
                if (count > 0) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [PiPButton triggerPiP:wv toggle:isPiPActive];
                    });
                }
                if (checked == total && !isPiPActive) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (statusLabel) statusLabel.text = @"動画なし";
                    });
                }
            }];
        }
    } @catch (NSException *e) {
        [self showAlert:[NSString stringWithFormat:@"ERR:%@",e]];
    }
}

+ (void)onPan:(UIPanGestureRecognizer *)pan {
    CGPoint d = [pan translationInView:floatWindow];
    CGPoint c = floatWindow.center;
    c.x += d.x; c.y += d.y;
    CGSize s = [UIScreen mainScreen].bounds.size;
    c.x = MAX(35, MIN(c.x, s.width-35));
    c.y = MAX(60, MIN(c.y, s.height-60));
    floatWindow.center = c;
    [pan setTranslation:CGPointZero inView:floatWindow];
}

@end

__attribute__((constructor))
static void PiPTweakInit() {
    Class cls = [WKWebView class];
    Method m = class_getInstanceMethod(cls, @selector(initWithFrame:configuration:));
    if (m) {
        orig_initWithFrame_config = (id(*)(id,SEL,CGRect,id))method_getImplementation(m);
        method_setImplementation(m, (IMP)swizzled_initWithFrame_config);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0*NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{ [PiPButton show]; });
}
