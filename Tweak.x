#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static UIWindow *floatWindow;
static UIWindow *alertWindow;
static UILabel *statusLabel;
static BOOL isPiPActive = NO;
static NSURLSessionDownloadTask *downloadTask = nil;

// WKWebView設定をswizzle
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
        "      v.addEventListener('webkitpresentationmodechanged',function(){"
        "        window.webkit&&window.webkit.messageHandlers&&"
        "        window.webkit.messageHandlers.pipState&&"
        "        window.webkit.messageHandlers.pipState.postMessage(v.webkitPresentationMode||'unknown');"
        "      });"
        "      v.addEventListener('enterpictureinpicture',function(){"
        "        window.webkit&&window.webkit.messageHandlers&&"
        "        window.webkit.messageHandlers.pipState&&"
        "        window.webkit.messageHandlers.pipState.postMessage('picture-in-picture');"
        "      });"
        "      v.addEventListener('leavepictureinpicture',function(){"
        "        window.webkit&&window.webkit.messageHandlers&&"
        "        window.webkit.messageHandlers.pipState&&"
        "        window.webkit.messageHandlers.pipState.postMessage('inline');"
        "      });"
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

@interface PiPButton : NSObject <WKScriptMessageHandler>
+ (instancetype)shared;
+ (void)show;
+ (void)onTap;
+ (void)onDownloadTap;
+ (void)onPan:(UIPanGestureRecognizer *)pan;
+ (void)showAlert:(NSString *)msg;
+ (void)collectWebViews:(UIView *)view into:(NSMutableArray *)arr;
+ (void)updateButtonState;
+ (WKWebView *)findActiveWebView;
+ (void)evalWithGesture:(NSString *)js inWebView:(WKWebView *)wv completion:(void(^)(id,NSError*))handler;
@end

@implementation PiPButton

+ (instancetype)shared {
    static PiPButton *instance = nil;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ instance = [PiPButton new]; });
    return instance;
}

- (void)userContentController:(WKUserContentController *)ctrl didReceiveScriptMessage:(WKScriptMessage *)msg {
    if (![msg.name isEqualToString:@"pipState"]) return;
    NSString *mode = [NSString stringWithFormat:@"%@", msg.body];
    dispatch_async(dispatch_get_main_queue(), ^{
        isPiPActive = [mode isEqualToString:@"picture-in-picture"];
        [PiPButton updateButtonState];
    });
}

+ (void)updateButtonState {
    if (!floatWindow) return;
    UIButton *btn = nil;
    for (UIView *v in floatWindow.rootViewController.view.subviews)
        if ([v isKindOfClass:[UIButton class]] && v.tag == 1) { btn=(UIButton*)v; break; }
    if (!btn) return;
    btn.backgroundColor = isPiPActive
        ? [UIColor colorWithRed:0.0 green:0.6 blue:1.0 alpha:0.95]
        : [UIColor colorWithRed:0.15 green:0.15 blue:0.15 alpha:0.92];
    statusLabel.text = isPiPActive ? @"ON" : @"OFF";
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
            alertControllerWithTitle:@"PiPTweak" message:msg
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

+ (WKWebView *)findActiveWebView {
    UIWindowScene *ws = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes)
        if ([s isKindOfClass:[UIWindowScene class]]) { ws=(UIWindowScene*)s; break; }
    if (!ws) return nil;

    NSMutableArray *all = [NSMutableArray array];
    for (UIWindow *win in ws.windows) {
        if (win == floatWindow || win == alertWindow) continue;
        [self collectWebViews:win into:all];
    }
    // messageHandlerが登録されてるWebViewを優先
    for (WKWebView *wv in all) {
        NSString *url = wv.URL.absoluteString ?: @"";
        if (![url isEqualToString:@"about:blank"] && url.length > 0) return wv;
    }
    return all.firstObject;
}

+ (void)evalWithGesture:(NSString *)js inWebView:(WKWebView *)wv completion:(void(^)(id,NSError*))handler {
    @try { [wv setValue:@YES forKeyPath:@"configuration.allowsPictureInPictureMediaPlayback"]; } @catch(NSException *e){}

    SEL sel = NSSelectorFromString(@"_evaluateJavaScript:inFrame:inContentWorld:withUserGesture:completionHandler:");
    if ([wv respondsToSelector:sel]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wundeclared-selector"
        typedef void (*EvalIMP)(id,SEL,NSString*,id,id,BOOL,id);
        ((EvalIMP)objc_msgSend)(wv, sel, js, nil, WKContentWorld.pageWorld, YES, handler);
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
        floatWindow.frame = CGRectMake(20, 120, 70, 145);
        floatWindow.windowLevel = UIWindowLevelAlert + 100;
        floatWindow.backgroundColor = [UIColor clearColor];
        UIViewController *vc = [UIViewController new];
        vc.view.backgroundColor = [UIColor clearColor];
        floatWindow.rootViewController = vc;
        floatWindow.hidden = NO;

        // PiPボタン
        UIButton *pipBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        pipBtn.tag = 1;
        pipBtn.frame = CGRectMake(5, 5, 60, 60);
        pipBtn.backgroundColor = [UIColor colorWithRed:0.15 green:0.15 blue:0.15 alpha:0.92];
        pipBtn.layer.cornerRadius = 30;
        pipBtn.layer.borderWidth = 1.5;
        pipBtn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.4].CGColor;
        pipBtn.clipsToBounds = YES;
        [pipBtn setTitle:@"📺" forState:UIControlStateNormal];
        pipBtn.titleLabel.font = [UIFont systemFontOfSize:26];
        [pipBtn addTarget:self action:@selector(onTap) forControlEvents:UIControlEventTouchUpInside];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:self action:@selector(onPan:)];
        [pipBtn addGestureRecognizer:pan];

        // ステータスラベル
        statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 67, 70, 16)];
        statusLabel.textColor = [UIColor whiteColor];
        statusLabel.font = [UIFont boldSystemFontOfSize:10];
        statusLabel.textAlignment = NSTextAlignmentCenter;
        statusLabel.text = @"OFF";

        // ダウンロードボタン
        UIButton *dlBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        dlBtn.tag = 2;
        dlBtn.frame = CGRectMake(10, 88, 50, 50);
        dlBtn.backgroundColor = [UIColor colorWithRed:0.15 green:0.15 blue:0.15 alpha:0.92];
        dlBtn.layer.cornerRadius = 25;
        dlBtn.layer.borderWidth = 1.5;
        dlBtn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.4].CGColor;
        dlBtn.clipsToBounds = YES;
        [dlBtn setTitle:@"⬇️" forState:UIControlStateNormal];
        dlBtn.titleLabel.font = [UIFont systemFontOfSize:20];
        [dlBtn addTarget:self action:@selector(onDownloadTap) forControlEvents:UIControlEventTouchUpInside];

        [vc.view addSubview:pipBtn];
        [vc.view addSubview:statusLabel];
        [vc.view addSubview:dlBtn];
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

        NSMutableArray *all = [NSMutableArray array];
        for (UIWindow *win in ws.windows) {
            if (win == floatWindow || win == alertWindow) continue;
            [self collectWebViews:win into:all];
        }
        if (!all.count) { [self showAlert:@"WebViewなし"]; return; }

        // 確認+起動を1つのJSにまとめる
        NSString *startJS = @""
            "(function(){"
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

        NSString *stopJS = @""
            "(function(){"
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
            "})();";

        NSString *js = isPiPActive ? stopJS : startJS;
        __block BOOL handled = NO;

        for (WKWebView *wv in all) {
            [self evalWithGesture:js inWebView:wv completion:^(id result, NSError *error) {
                if (handled) return;
                if (!result || [result isEqual:[NSNull null]]) return;
                NSString *str = [NSString stringWithFormat:@"%@", result];
                if (str.length < 2) return;
                handled = YES;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if ([str hasPrefix:@"OK"]) {
                        isPiPActive = YES;
                        [PiPButton updateButtonState];
                    } else if ([str isEqualToString:@"STOPPED"]) {
                        isPiPActive = NO;
                        [PiPButton updateButtonState];
                    } else {
                        [PiPButton showAlert:str];
                        if (statusLabel) statusLabel.text = @"ERR";
                    }
                });
            }];
        }
    } @catch (NSException *e) {
        [self showAlert:[NSString stringWithFormat:@"ERR:%@",e]];
    }
}

+ (void)onDownloadTap {
    @try {
        UIWindowScene *ws = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes)
            if ([s isKindOfClass:[UIWindowScene class]]) { ws=(UIWindowScene*)s; break; }
        if (!ws) return;

        NSMutableArray *all = [NSMutableArray array];
        for (UIWindow *win in ws.windows) {
            if (win == floatWindow || win == alertWindow) continue;
            [self collectWebViews:win into:all];
        }
        if (!all.count) { [self showAlert:@"WebViewなし"]; return; }

        NSString *srcJS = @""
            "(function(){"
            "  var vids=document.querySelectorAll('video');"
            "  if(!vids.length) return 'NO_VIDEO';"
            "  var v=vids[0];"
            "  var src=v.currentSrc||v.src||'';"
            "  if(!src){"
            "    var se=v.querySelector('source');"
            "    if(se) src=se.src||'';"
            "  }"
            "  if(!src) return 'NO_SRC';"
            "  if(src.indexOf('blob:')==0){"
            "    var srcs=document.querySelectorAll('video source');"
            "    for(var i=0;i<srcs.length;i++){"
            "      var u=srcs[i].src;"
            "      if(u&&u.indexOf('blob:')!=0&&u.indexOf('data:')!=0) return u;"
            "    }"
            "    return 'BLOB_URL';"
            "  }"
            "  return src;"
            "})();";

        for (WKWebView *wv in all) {
            [wv evaluateJavaScript:srcJS completionHandler:^(id result, NSError *error) {
                if (!result || [result isEqual:[NSNull null]]) return;
                NSString *urlStr = [NSString stringWithFormat:@"%@", result];
                if (!urlStr.length || [urlStr isEqualToString:@"null"]) return;

                if ([urlStr isEqualToString:@"NO_VIDEO"]) {
                    dispatch_async(dispatch_get_main_queue(), ^{ [PiPButton showAlert:@"動画が見つかりません"]; });
                    return;
                }
                if ([urlStr isEqualToString:@"NO_SRC"]) {
                    dispatch_async(dispatch_get_main_queue(), ^{ [PiPButton showAlert:@"動画URLを取得できません"]; });
                    return;
                }
                if ([urlStr isEqualToString:@"BLOB_URL"]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [PiPButton showAlert:@"この動画はblob URLを使用しており直接ダウンロードできません\n(DRM・暗号化コンテンツ)"];
                    });
                    return;
                }
                if ([urlStr.lowercaseString hasSuffix:@".m3u8"]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [PiPButton showAlert:@"HLSストリーミング(.m3u8)は直接ダウンロードできません"];
                    });
                    return;
                }

                dispatch_async(dispatch_get_main_queue(), ^{
                    // ダウンロード確認アラート
                    if (alertWindow) return;
                    alertWindow = [[UIWindow alloc] initWithWindowScene:ws];
                    alertWindow.windowLevel = UIWindowLevelAlert + 200;
                    alertWindow.backgroundColor = [UIColor clearColor];
                    UIViewController *vc = [UIViewController new];
                    alertWindow.rootViewController = vc;
                    alertWindow.hidden = NO;
                    [alertWindow makeKeyAndVisible];

                    NSString *shortURL = urlStr.length > 60 ? [urlStr substringToIndex:60] : urlStr;
                    UIAlertController *alert = [UIAlertController
                        alertControllerWithTitle:@"⬇️ ダウンロード"
                        message:shortURL
                        preferredStyle:UIAlertControllerStyleAlert];

                    [alert addAction:[UIAlertAction actionWithTitle:@"ダウンロード"
                        style:UIAlertActionStyleDefault
                        handler:^(UIAlertAction *a){
                            alertWindow.hidden=YES; alertWindow=nil;
                            [PiPButton startDownload:urlStr];
                        }]];
                    [alert addAction:[UIAlertAction actionWithTitle:@"キャンセル"
                        style:UIAlertActionStyleCancel
                        handler:^(UIAlertAction *a){ alertWindow.hidden=YES; alertWindow=nil; }]];
                    [vc presentViewController:alert animated:YES completion:nil];
                });
            }];
        }
    } @catch (NSException *e) {
        [self showAlert:[NSString stringWithFormat:@"DL ERR:%@",e]];
    }
}

+ (void)startDownload:(NSString *)urlStr {
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) { [self showAlert:@"URLが無効です"]; return; }
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) {
        [self showAlert:[NSString stringWithFormat:@"サポートされていないURL形式: %@\nblob/dataスキームは非対応です", scheme]];
        return;
    }

    if (statusLabel) statusLabel.text = @"DL中";

    // ダウンロードボタンを更新
    UIButton *dlBtn = nil;
    for (UIView *v in floatWindow.rootViewController.view.subviews)
        if ([v isKindOfClass:[UIButton class]] && v.tag == 2) { dlBtn=(UIButton*)v; break; }
    dlBtn.backgroundColor = [UIColor colorWithRed:1.0 green:0.6 blue:0.0 alpha:0.92];

    NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
    downloadTask = [session downloadTaskWithURL:url completionHandler:^(NSURL *loc, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            dlBtn.backgroundColor = [UIColor colorWithRed:0.15 green:0.15 blue:0.15 alpha:0.92];

            if (err || !loc) {
                [PiPButton showAlert:[NSString stringWithFormat:@"DL失敗:\n%@", err.localizedDescription ?: @"不明"]];
                if (statusLabel) statusLabel.text = @"ERR";
                return;
            }

            // Filesアプリ(Documents)に保存
            NSString *filename = resp.suggestedFilename ?: @"video.mp4";
            NSURL *dest = [[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject
                URLByAppendingPathComponent:filename];

            NSError *moveErr;
            [NSFileManager.defaultManager moveItemAtURL:loc toURL:dest error:&moveErr];

            if (moveErr) {
                [PiPButton showAlert:[NSString stringWithFormat:@"保存失敗:\n%@", moveErr.localizedDescription]];
                if (statusLabel) statusLabel.text = @"ERR";
            } else {
                [PiPButton showAlert:[NSString stringWithFormat:@"✅ 保存完了!\n%@\n\nFilesアプリ→このiPhone→pip-tweakで確認", filename]];
                if (statusLabel) statusLabel.text = @"完了";
            }
            downloadTask = nil;
        });
    }];
    [downloadTask resume];
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
