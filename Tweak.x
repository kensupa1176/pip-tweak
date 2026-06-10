#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ============================================================
// 定数定義
// ============================================================
#define kFloatWindowLevel     UIWindowLevelAlert + 100
#define kAlertWindowLevel     UIWindowLevelAlert + 200
#define kPiPRetryCount        5
#define kPiPRetryInterval     0.6
#define kInitDelay            2.0

// ============================================================
// 静的変数
// ============================================================
static UIWindow *floatWindow = nil;
static UIWindow *alertWindow = nil;
static UILabel *statusLabel = nil;
static UILabel *urlCountLabel = nil;
static BOOL isPiPActive = NO;
static BOOL isInitialized = NO;
static NSMutableArray *capturedVideoURLs = nil;
static NSMutableDictionary *videoStats = nil;
static NSString *lastErrorLog = nil;

// ============================================================
// ログマクロ（デバッグ用）
// ============================================================
#ifdef DEBUG_MODE
#define PTLog(fmt, ...) NSLog(@"[PiPTweak] " fmt, ##__VA_ARGS__)
#else
#define PTLog(fmt, ...) 
#endif

// ============================================================
// NSURLSession スウィズリング（動画URLキャプチャ）
// ============================================================
static id (*orig_dataTaskWithRequest)(id, SEL, id, id) = NULL;

static id swizzled_dataTaskWithRequest(id self, SEL _cmd, NSURLRequest *request, id handler) {
    NSString *urlStr = request.URL.absoluteString ?: @"";
    
    // 動画関連URLのパターン
    NSArray *videoPatterns = @[@".m3u8", @".mp4", @".mkv", @".webm", @".ts", @".m4s", @".ts?"];
    
    BOOL isVideoURL = NO;
    for (NSString *pattern in videoPatterns) {
        if ([urlStr containsString:pattern]) {
            isVideoURL = YES;
            break;
        }
    }
    
    if (isVideoURL && ![capturedVideoURLs containsObject:urlStr]) {
        @synchronized(capturedVideoURLs) {
            if (![capturedVideoURLs containsObject:urlStr]) {
                [capturedVideoURLs addObject:urlStr];
                PTLog(@"📹 Video URL captured: %@", [urlStr substringToIndex:MIN(60, urlStr.length)]);
                
                // 動画統計を更新
                @synchronized(videoStats) {
                    NSInteger count = [videoStats[@"totalCaptures"] integerValue] + 1;
                    videoStats[@"totalCaptures"] = @(count);
                    if (urlCountLabel) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            urlCountLabel.text = [NSString stringWithFormat:@"📹%ld", (long)count];
                        });
                    }
                }
            }
        }
    }
    
    return orig_dataTaskWithRequest(self, _cmd, request, handler);
}

// ============================================================
// WKWebView 初期化スウィズリング（PiP設定注入）
// ============================================================
static id (*orig_initWithFrame_config)(id, SEL, CGRect, id) = NULL;

static id swizzled_initWithFrame_config(id self, SEL _cmd, CGRect frame, WKWebViewConfiguration *config) {
    // PiP設定
    config.allowsPictureInPictureMediaPlayback = YES;
    config.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
    
    // 自動再生設定
    config.allowsInlineMediaPlayback = YES;
    
    // 動画関連イベント監視用JavaScript
    NSString *src = @"(function(){var _pipSetupDone=false;function setupVideos(){document.querySelectorAll('video').forEach(function(v,i){if(!v.hasAttribute('playsinline'))v.setAttribute('playsinline','');if(!v.hasAttribute('webkit-playsinline'))v.setAttribute('webkit-playsinline','');v.setAttribute('x-webkit-airplay','allow');v.setAttribute('airplay','allow');if(!v._pipListened){v._pipListened=true;v.addEventListener('webkitpresentationmodechanged',function(e){var mode=v.webkitPresentationMode||'unknown';if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.pipState){window.webkit.messageHandlers.pipState.postMessage({type:'mode',value:mode});}});v.addEventListener('enterpictureinpicture',function(){if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.pipState){window.webkit.messageHandlers.pipState.postMessage({type:'enterPiP'});}});v.addEventListener('leavepictureinpicture',function(){if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.pipState){window.webkit.messageHandlers.pipState.postMessage({type:'leavePiP'});}});v.addEventListener('playing',function(){if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.pipState){window.webkit.messageHandlers.pipState.postMessage({type:'playing',videoIndex:i});}});v.addEventListener('pause',function(){if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.pipState){window.webkit.messageHandlers.pipState.postMessage({type:'paused',videoIndex:i});}});}}});}new MutationObserver(function(mutations){var shouldSetup=false;mutations.forEach(function(m){if(m.addedNodes.length)shouldSetup=true;});if(shouldSetup)setupVideos();}).observe(document.documentElement,{childList:true,subtree:true});if(document.readyState==='loading'){document.addEventListener('DOMContentLoaded',setupVideos);}else{setupVideos();}window._pipHelper={getVideoInfo:function(){var vids=document.querySelectorAll('video');var info=[];vids.forEach(function(v,i){info.push({index:i,paused:v.paused,duration:v.duration||0,currentTime:v.currentTime||0,src:v.currentSrc||'',webkitMode:v.webkitPresentationMode||'none',supportsPiP:!!(v.webkitSupportsPresentationMode&&v.webkitSupportsPresentationMode('picture-in-picture')),supportsNativePiP:!!(v.requestPictureInPicture)});});return info;},getBestVideo:function(){var vids=document.querySelectorAll('video');var best=null;var bestDuration=0;vids.forEach(function(v){if(v.duration>bestDuration&&v.currentSrc){bestDuration=v.duration;best=v;}});if(!best&&vids.length>0)best=vids[0];return best;}};})();";
    
    WKUserScript *script = [[WKUserScript alloc]
        initWithSource:src
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart
        forMainFrameOnly:NO];
    [config.userContentController addUserScript:script];
    
    return orig_initWithFrame_config(self, _cmd, frame, config);
}

// ============================================================
// PassthroughWindow（画面タップ透過ウィンドウ）
// ============================================================
@interface PassthroughWindow : UIWindow
@end

@implementation PassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}
@end

// ============================================================
// PiPButton インターフェース
// ============================================================
@interface PiPButton : NSObject
+ (void)show;
+ (void)hide;
+ (void)onTap;
+ (void)onDownloadTap;
+ (void)onSettingsTap;
+ (void)onPan:(UIPanGestureRecognizer *)pan;
+ (void)showAlert:(NSString *)msg;
+ (void)showAlertWithTitle:(NSString *)title message:(NSString *)msg;
+ (void)collectWebViews:(UIView *)view into:(NSMutableArray *)arr;
+ (void)updateButtonState;
+ (void)evalWithGesture:(NSString *)js inWebView:(WKWebView *)wv completion:(void(^)(id, NSError*))handler;
+ (void)startDownload:(NSString *)urlStr;
+ (void)attemptPiPInWebView:(WKWebView *)wv retryCount:(NSInteger)retry;
+ (void)attemptPiPInAllWebViews;
+ (void)stopPiPInAllWebViews;
+ (void)checkVideoStatus;
+ (void)refreshVideoList;
+ (NSArray *)getCapturedURLs;
+ (void)clearCapturedURLs;
@end

// ============================================================
// PiPButton 実装
// ============================================================
@implementation PiPButton

+ (void)updateButtonState {
    if (!floatWindow) return;
    
    UIButton *pipBtn = nil;
    UIButton *dlBtn = nil;
    for (UIView *v in floatWindow.rootViewController.view.subviews) {
        if ([v isKindOfClass:[UIButton class]]) {
            if (((UIButton*)v).tag == 1) pipBtn = (UIButton*)v;
            if (((UIButton*)v).tag == 2) dlBtn = (UIButton*)v;
        }
    }
    
    if (pipBtn) {
        pipBtn.backgroundColor = isPiPActive
            ? [UIColor colorWithRed:0.0 green:0.6 blue:1.0 alpha:0.95]
            : [UIColor colorWithRed:0.15 green:0.15 blue:0.15 alpha:0.92];
    }
    
    if (statusLabel) {
        statusLabel.text = isPiPActive ? @"ON" : @"OFF";
    }
}

+ (void)showAlert:(NSString *)msg {
    [self showAlertWithTitle:@"PiPTweak" message:msg];
}

+ (void)showAlertWithTitle:(NSString *)title message:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (alertWindow) {
            alertWindow.hidden = YES;
            alertWindow = nil;
        }
        
        UIWindowScene *ws = [self getWindowScene];
        if (!ws) return;
        
        alertWindow = [[UIWindow alloc] initWithWindowScene:ws];
        alertWindow.windowLevel = kAlertWindowLevel;
        alertWindow.backgroundColor = [UIColor clearColor];
        UIViewController *vc = [UIViewController new];
        alertWindow.rootViewController = vc;
        alertWindow.hidden = NO;
        [alertWindow makeKeyAndVisible];
        
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:title message:msg
            preferredStyle:UIAlertControllerStyleAlert];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
            style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a){
                alertWindow.hidden = YES;
                alertWindow = nil;
            }]];
        
        [vc presentViewController:alert animated:YES completion:nil];
    });
}

+ (UIWindowScene *)getWindowScene {
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) {
            return (UIWindowScene *)s;
        }
    }
    return nil;
}

+ (void)collectWebViews:(UIView *)view into:(NSMutableArray *)arr {
    if ([view isKindOfClass:[WKWebView class]]) {
        [arr addObject:view];
    }
    for (UIView *sub in view.subviews) {
        [self collectWebViews:sub into:arr];
    }
}

+ (void)evalWithGesture:(NSString *)js inWebView:(WKWebView *)wv completion:(void(^)(id, NSError*))handler {
    @try {
        [wv setValue:@YES forKeyPath:@"configuration.allowsPictureInPictureMediaPlayback"];
    } @catch (NSException *e) {
        PTLog(@"KVC PiP setting failed: %@", e);
    }
    
    SEL sel = NSSelectorFromString(@"_evaluateJavaScript:inFrame:inContentWorld:withUserGesture:completionHandler:");
    if ([wv respondsToSelector:sel]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wundeclared-selector"
        typedef void (*EvalIMP)(id, SEL, NSString*, id, id, BOOL, id);
        ((EvalIMP)objc_msgSend)(wv, sel, js, nil, WKContentWorld.pageWorld, YES, handler);
        #pragma clang diagnostic pop
    } else {
        [wv evaluateJavaScript:js completionHandler:handler];
    }
}

+ (void)attemptPiPInWebView:(WKWebView *)wv retryCount:(NSInteger)retry {
    PTLog(@"PiP attempt in webview, retry: %ld", (long)retry);
    
    if (retry <= 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (statusLabel) statusLabel.text = @"失敗";
            lastErrorLog = @"PiP起動リトライ回数超過";
        });
        return;
    }
    
    NSString *prepareJS = @" (function(){var info=window._pipHelper?window._pipHelper.getVideoInfo():[];if(!info.length){var vids=document.querySelectorAll('video');vids.forEach(function(v,i){info.push({index:i,paused:v.paused,duration:v.duration||0,currentTime:v.currentTime||0,src:v.currentSrc||'',webkitMode:v.webkitPresentationMode||'none',supportsPiP:!!(v.webkitSupportsPresentationMode&&v.webkitSupportsPresentationMode('picture-in-picture')),supportsNativePiP:!!(v.requestPictureInPicture)});});}var best=window._pipHelper?window._pipHelper.getBestVideo():null;return JSON.stringify({videos:info,bestIndex:best?Array.from(document.querySelectorAll('video')).indexOf(best):-1,hasPlaying:info.some(function(v){return !v.paused;})});})(); ";
    
    [self evalWithGesture:prepareJS inWebView:wv completion:^(id result, NSError *error) {
        if (!result || [result isEqual:[NSNull null]]) {
            PTLog(@"Video check failed, retrying...");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPiPRetryInterval * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    [self attemptPiPInWebView:wv retryCount:retry - 1];
                });
            return;
        }
        
        NSData *jsonData = [result dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *videoInfo = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
        
        NSArray *videos = videoInfo[@"videos"];
        BOOL hasPlaying = [videoInfo[@"hasPlaying"] boolValue];
        
        PTLog(@"Video info: %ld videos, hasPlaying: %@", (long)videos.count, hasPlaying ? @"YES" : @"NO");
        
        if (!videos.count) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPiPRetryInterval * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    [self attemptPiPInWebView:wv retryCount:retry - 1];
                });
            return;
        }
        
        if (!hasPlaying) {
            NSString *playJS = @"(function(){var vids=document.querySelectorAll('video');for(var i=0;i<vids.length;i++){var v=vids[i];if(v.currentSrc&&!v.paused){return {played:true,index:i};}}for(var i=0;i<vids.length;i++){var v=vids[i];if(v.currentSrc){v.play().catch(function(){});return {played:true,index:i};}}return {played:false};})();";
            
            [self evalWithGesture:playJS inWebView:wv completion:^(id r, NSError *e) {
                [self triggerPiPInWebView:wv retryCount:retry];
            }];
        } else {
            [self triggerPiPInWebView:wv retryCount:retry];
        }
    }];
}

+ (void)triggerPiPInWebView:(WKWebView *)wv retryCount:(NSInteger)retry {
    NSString *pipJS = @"(function(){var vids=document.querySelectorAll('video');if(!vids.length)return {status:'NO_VIDEO'};var target=null;for(var i=0;i<vids.length;i++){if(!vids[i].paused&&vids[i].currentSrc){target=vids[i];break;}}if(!target&&vids.length>0){for(var i=0;i<vids.length;i++){if(vids[i].currentSrc){target=vids[i];break;}}}if(!target)return {status:'NO_TARGET_VIDEO'};var v=target;var errors=[];try{if(v.webkitSupportsPresentationMode&&v.webkitSupportsPresentationMode('picture-in-picture')){v.webkitSetPresentationMode('picture-in-picture');return {status:'OK',method:'webkit',videoIndex:Array.from(vids).indexOf(v)};}}catch(e){errors.push('webkit:'+e.message);}try{if(v.requestPictureInPicture){var p=v.requestPictureInPicture();if(p&&p.then){p.then(function(){}).catch(function(e){errors.push('pip-reject:'+e.message);});}return {status:'OK',method:'pip',videoIndex:Array.from(vids).indexOf(v)};}}catch(e){errors.push('pip:'+e.message);}return {status:'FAIL',errors:errors};})();";
    
    [self evalWithGesture:pipJS inWebView:wv completion:^(id r, NSError *e) {
        if (!r || [r isEqual:[NSNull null]]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPiPRetryInterval * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    [self attemptPiPInWebView:wv retryCount:retry - 1];
                });
            return;
        }
        
        NSString *str = [NSString stringWithFormat:@"%@", r];
        PTLog(@"PiP result: %@", str);
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([str containsString:@"OK"]) {
                isPiPActive = YES;
                [self updateButtonState];
                if (statusLabel) statusLabel.text = @"ON";
            } else if ([str containsString:@"FAIL"] || [str containsString:@"NO_TARGET"]) {
                if (retry > 1) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPiPRetryInterval * 1.5 * NSEC_PER_SEC)),
                        dispatch_get_main_queue(), ^{
                            [self attemptPiPInWebView:wv retryCount:retry - 1];
                        });
                } else {
                    if (statusLabel) statusLabel.text = @"失敗";
                    lastErrorLog = str;
                }
            }
        });
    }];
}

+ (void)attemptPiPInAllWebViews {
    UIWindowScene *ws = [self getWindowScene];
    if (!ws) return;
    
    NSMutableArray *all = [NSMutableArray array];
    for (UIWindow *win in ws.windows) {
        if (win == floatWindow || win == alertWindow) continue;
        [self collectWebViews:win into:all];
    }
    
    if (!all.count) {
        [self showAlert:@"WebViewが見つかりません"];
        return;
    }
    
    if (statusLabel) statusLabel.text = @"起動中";
    
    __block NSInteger foundCount = 0;
    __block NSInteger currentIndex = 0;
    
    for (WKWebView *wv in all) {
        [wv evaluateJavaScript:@"document.querySelectorAll('video').length"
             completionHandler:^(id result, NSError *error) {
            currentIndex++;
            if ([result integerValue] > 0) {
                foundCount++;
                if (foundCount == 1) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self attemptPiPInWebView:wv retryCount:kPiPRetryCount];
                    });
                }
            }
            
            if (currentIndex == all.count && foundCount == 0) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self showAlert:@"動画要素が見つかりません\nページを読み込んでください"];
                    if (statusLabel) statusLabel.text = @"OFF";
                });
            }
        }];
    }
}

+ (void)stopPiPInAllWebViews {
    UIWindowScene *ws = [self getWindowScene];
    if (!ws) return;
    
    NSMutableArray *all = [NSMutableArray array];
    for (UIWindow *win in ws.windows) {
        if (win == floatWindow || win == alertWindow) continue;
        [self collectWebViews:win into:all];
    }
    
    NSString *stopJS = @"(function(){var stopped=false;document.querySelectorAll('video').forEach(function(v){try{if(v.webkitPresentationMode==='picture-in-picture'){v.webkitSetPresentationMode('inline');stopped=true;}}catch(e){}});try{if(document.pictureInPictureElement){document.exitPictureInPicture();stopped=true;}}catch(e){}return stopped?'STOPPED':'NOT_ACTIVE';})();";
    
    for (WKWebView *wv in all) {
        [self evalWithGesture:stopJS inWebView:wv completion:^(id r, NSError *e) {
            if (r && ![r isEqual:[NSNull null]]) {
                NSString *str = [NSString stringWithFormat:@"%@", r];
                if ([str isEqualToString:@"STOPPED"]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        isPiPActive = NO;
                        [self updateButtonState];
                    });
                }
            }
        }];
    }
}

+ (void)checkVideoStatus {
    UIWindowScene *ws = [self getWindowScene];
    if (!ws) return;
    
    NSMutableArray *all = [NSMutableArray array];
    for (UIWindow *win in ws.windows) {
        if (win == floatWindow || win == alertWindow) continue;
        [self collectWebViews:win into:all];
    }
    
    NSString *checkJS = @"(function(){var vids=document.querySelectorAll('video');var info=[];vids.forEach(function(v,i){info.push({index:i,paused:v.paused,duration:Math.round(v.duration||0),currentTime:Math.round(v.currentTime||0),webkitMode:v.webkitPresentationMode||'none',hasSrc:!!v.currentSrc});});return JSON.stringify(info);})();";
    
    for (WKWebView *wv in all) {
        [self evalWithGesture:checkJS inWebView:wv completion:^(id r, NSError *e) {
            if (r && ![r isEqual:[NSNull null]]) {
                PTLog(@"Video status: %@", r);
            }
        }];
    }
}

+ (void)refreshVideoList {
    UIWindowScene *ws = [self getWindowScene];
    if (!ws) return;
    
    NSMutableArray *all = [NSMutableArray array];
    for (UIWindow *win in ws.windows) {
        if (win == floatWindow || win == alertWindow) continue;
        [self collectWebViews:win into:all];
    }
    
    NSString *refreshJS = @"(function(){var count=0;document.querySelectorAll('video').forEach(function(v){count++;});return count;})();";
    
    for (WKWebView *wv in all) {
        [self evalWithGesture:refreshJS inWebView:wv completion:^(id r, NSError *e) {
            if (r && ![r isEqual:[NSNull null]]) {
                PTLog(@"Refreshed video list: %@ videos", r);
            }
        }];
    }
}

+ (NSArray *)getCapturedURLs {
    @synchronized(capturedVideoURLs) {
        return [capturedVideoURLs copy];
    }
}

+ (void)clearCapturedURLs {
    @synchronized(capturedVideoURLs) {
        [capturedVideoURLs removeAllObjects];
        @synchronized(videoStats) {
            [videoStats removeAllObjects];
            videoStats[@"totalCaptures"] = @(0);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (urlCountLabel) urlCountLabel.text = @"📹0";
        });
    }
    PTLog(@"Captured URLs cleared");
}

+ (void)show {
    if (floatWindow) return;
    
    @try {
        UIWindowScene *ws = [self getWindowScene];
        if (!ws) {
            PTLog(@"Failed to get window scene");
            return;
        }
        
        floatWindow = [[PassthroughWindow alloc] initWithWindowScene:ws];
        floatWindow.frame = CGRectMake(20, 120, 70, 165);
        floatWindow.windowLevel = kFloatWindowLevel;
        floatWindow.backgroundColor = [UIColor clearColor];
        UIViewController *vc = [UIViewController new];
        vc.view.backgroundColor = [UIColor clearColor];
        floatWindow.rootViewController = vc;
        floatWindow.hidden = NO;
        
        // ===== PiPボタン =====
        UIButton *pipBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        pipBtn.tag = 1;
        pipBtn.frame = CGRectMake(5, 5, 60, 60);
        pipBtn.backgroundColor = [UIColor colorWithRed:0.15 green:0.15 blue:0.15 alpha:0.92];
        pipBtn.layer.cornerRadius = 30;
        pipBtn.layer.borderWidth = 2.0;
        pipBtn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.5].CGColor;
        pipBtn.clipsToBounds = YES;
        pipBtn.layer.shadowColor = [UIColor blackColor].CGColor;
        pipBtn.layer.shadowOffset = CGSizeMake(0, 2);
        pipBtn.layer.shadowOpacity = 0.3;
        pipBtn.layer.shadowRadius = 4;
        [pipBtn setTitle:@"📺" forState:UIControlStateNormal];
        pipBtn.titleLabel.font = [UIFont systemFontOfSize:28];
        [pipBtn addTarget:self action:@selector(onTap) forControlEvents:UIControlEventTouchUpInside];
        
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:self action:@selector(onPan:)];
        [pipBtn addGestureRecognizer:pan];
        
        // ===== ステータスラベル =====
        statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 67, 70, 16)];
        statusLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
        statusLabel.layer.cornerRadius = 4;
        statusLabel.clipsToBounds = YES;
        statusLabel.textColor = [UIColor whiteColor];
        statusLabel.font = [UIFont boldSystemFontOfSize:10];
        statusLabel.textAlignment = NSTextAlignmentCenter;
        statusLabel.text = @"OFF";
        
        // ===== URLカウンターラベル =====
        urlCountLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 85, 70, 14)];
        urlCountLabel.backgroundColor = [UIColor clearColor];
        urlCountLabel.textColor = [UIColor colorWithWhite:1 alpha:0.7];
        urlCountLabel.font = [UIFont systemFontOfSize:9];
        urlCountLabel.textAlignment = NSTextAlignmentCenter;
        NSInteger count = 0;
        @synchronized(videoStats) {
            count = [videoStats[@"totalCaptures"] integerValue];
        }
        urlCountLabel.text = [NSString stringWithFormat:@"📹%ld", (long)count];
        
        // ===== ダウンロードボタン =====
        UIButton *dlBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        dlBtn.tag = 2;
        dlBtn.frame = CGRectMake(10, 102, 50, 50);
        dlBtn.backgroundColor = [UIColor colorWithRed:0.15 green:0.15 blue:0.15 alpha:0.92];
        dlBtn.layer.cornerRadius = 25;
        dlBtn.layer.borderWidth = 2.0;
        dlBtn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.5].CGColor;
        dlBtn.clipsToBounds = YES;
        dlBtn.layer.shadowColor = [UIColor blackColor].CGColor;
        dlBtn.layer.shadowOffset = CGSizeMake(0, 2);
        dlBtn.layer.shadowOpacity = 0.3;
        dlBtn.layer.shadowRadius = 4;
        [dlBtn setTitle:@"⬇️" forState:UIControlStateNormal];
        dlBtn.titleLabel.font = [UIFont systemFontOfSize:22];
        [dlBtn addTarget:self action:@selector(onDownloadTap) forControlEvents:UIControlEventTouchUpInside];
        
        [vc.view addSubview:pipBtn];
        [vc.view addSubview:statusLabel];
        [vc.view addSubview:urlCountLabel];
        [vc.view addSubview:dlBtn];
        
        isInitialized = YES;
        PTLog(@"PiP Tweak UI initialized");
        
    } @catch (NSException *e) {
        PTLog(@"Show error: %@", e);
    }
}

+ (void)hide {
    if (floatWindow) {
        floatWindow.hidden = YES;
        floatWindow = nil;
    }
    isInitialized = NO;
}

+ (void)onTap {
    @try {
        // PiP停止（既にアクティブの場合）
        if (isPiPActive) {
            [self stopPiPInAllWebViews];
            return;
        }
        
        // PiP起動
        [self attemptPiPInAllWebViews];
        
    } @catch (NSException *e) {
        [self showAlert:[NSString stringWithFormat:@"ERR:%@", e]];
    }
}

+ (void)onDownloadTap {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray *urls = [self getCapturedURLs];
        
        if (!urls.count) {
            [self showAlert:@"動画URLが見つかりません\n動画を再生してから\nもう一度タップしてください"];
            return;
        }
        
        // 最適なURLを選択（m3u8 > mp4 > その他）
        NSString *bestURL = nil;
        for (NSString *u in [urls reverseObjectEnumerator]) {
            if ([u containsString:@".m3u8"]) { bestURL = u; break; }
        }
        if (!bestURL) {
            for (NSString *u in [urls reverseObjectEnumerator]) {
                if ([u containsString:@".mp4"]) { bestURL = u; break; }
            }
        }
        if (!bestURL) bestURL = urls.lastObject;
        
        if (alertWindow) return;
        UIWindowScene *ws = [self getWindowScene];
        if (!ws) return;
        
        alertWindow = [[UIWindow alloc] initWithWindowScene:ws];
        alertWindow.windowLevel = kAlertWindowLevel;
        alertWindow.backgroundColor = [UIColor clearColor];
        UIViewController *vc = [UIViewController new];
        alertWindow.rootViewController = vc;
        alertWindow.hidden = NO;
        [alertWindow makeKeyAndVisible];
        
        NSString *shortURL = bestURL.length > 100 ? [bestURL substringToIndex:100] : bestURL;
        BOOL isHLS = [bestURL containsString:@".m3u8"];
        NSString *msg = isHLS
            ? [NSString stringWithFormat:@"HLSストリーム検出\n%@\n\n※URLコピーしてVLCで開くことを推奨", shortURL]
            : shortURL;
        
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"⬇️ ダウンロード"
            message:msg
            preferredStyle:UIAlertControllerStyleAlert];
        
        NSString *finalURL = bestURL;
        
        [alert addAction:[UIAlertAction actionWithTitle:@"ダウンロード"
            style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a){
                alertWindow.hidden = YES;
                alertWindow = nil;
                [PiPButton startDownload:finalURL];
            }]];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"URLをコピー"
            style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a){
                alertWindow.hidden = YES;
                alertWindow = nil;
                [UIPasteboard generalPasteboard].string = finalURL;
                [PiPButton showAlert:@"✅ URLをコピーしました\nVLCなどで開けます"];
            }]];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"全URL一覧"
            style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a){
                alertWindow.hidden = YES;
                alertWindow = nil;
                NSMutableString *allURLs = [NSMutableString string];
                for (NSInteger i = 0; i < urls.count; i++) {
                    [allURLs appendFormat:@"%ld: %@\n\n", (long)(i+1), urls[i]];
                }
                [PiPButton showAlertWithTitle:@"📹 キャプチャ済みURL" message:allURLs];
            }]];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"キャンセル"
            style:UIAlertActionStyleCancel
            handler:^(UIAlertAction *a){
                alertWindow.hidden = YES;
                alertWindow = nil;
            }]];
        
        [vc presentViewController:alert animated:YES completion:nil];
    });
}

+ (void)startDownload:(NSString *)urlStr {
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        [self showAlert:@"URLが無効です"];
        return;
    }
    
    if (statusLabel) statusLabel.text = @"DL中";
    
    UIButton *dlBtn = nil;
    for (UIView *v in floatWindow.rootViewController.view.subviews) {
        if ([v isKindOfClass:[UIButton class]] && ((UIButton*)v).tag == 2) {
            dlBtn = (UIButton*)v;
            break;
        }
    }
    if (dlBtn) {
        dlBtn.backgroundColor = [UIColor colorWithRed:1.0 green:0.6 blue:0.0 alpha:0.92];
    }
    
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.HTTPAdditionalHeaders = @{
        @"User-Agent": @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
        @"Referer": @"https://vidlink.pro/",
        @"Accept": @"*/*",
        @"Accept-Language": @"ja-JP,ja;q=0.9,en-US;q=0.8,en;q=0.7"
    };
    config.timeoutIntervalForRequest = 60;
    config.timeoutIntervalForResource = 300;
    
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    
    [[session downloadTaskWithURL:url completionHandler:^(NSURL *loc, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (dlBtn) {
                dlBtn.backgroundColor = [UIColor colorWithRed:0.15 green:0.15 blue:0.15 alpha:0.92];
            }
            
            if (err || !loc) {
                [PiPButton showAlert:[NSString stringWithFormat:@"DL失敗:\n%@", err.localizedDescription ?: @"不明"]];
                if (statusLabel) statusLabel.text = @"ERR";
                return;
            }
            
            NSString *ext = @"mp4";
            if ([urlStr containsString:@".m3u8"]) ext = @"m3u8";
            else if ([urlStr containsString:@".mkv"]) ext = @"mkv";
            else if ([urlStr containsString:@".webm"]) ext = @"webm";
            else if ([urlStr containsString:@".ts"]) ext = @"ts";
            
            NSString *filename = [NSString stringWithFormat:@"video_%@.%@",
                [[NSUUID UUID].UUIDString substringToIndex:8], ext];
            NSURL *dest = [[NSFileManager.defaultManager
                URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject
                URLByAppendingPathComponent:filename];
            NSError *moveErr;
            [NSFileManager.defaultManager moveItemAtURL:loc toURL:dest error:&moveErr];
            if (moveErr) {
                [PiPButton showAlert:[NSString stringWithFormat:@"保存失敗:\n%@", moveErr.localizedDescription]];
                if (statusLabel) statusLabel.text = @"ERR";
            } else {
                [PiPButton showAlert:[NSString stringWithFormat:@"✅ 保存完了!\n%@\n\nFilesアプリ→このiPhone内で確認", filename]];
                if (statusLabel) statusLabel.text = @"完了";
            }
        });
    }] resume];
}

+ (void)onPan:(UIPanGestureRecognizer *)pan {
    static CGPoint originalCenter;
    
    if (pan.state == UIGestureRecognizerStateBegan) {
        originalCenter = floatWindow.center;
        return;
    }
    
    CGPoint d = [pan translationInView:floatWindow];
    CGPoint c = originalCenter;
    c.x += d.x; c.y += d.y;
    
    CGSize s = [UIScreen mainScreen].bounds.size;
    CGFloat margin = 35;
    c.x = MAX(margin, MIN(c.x, s.width - margin));
    c.y = MAX(60, MIN(c.y, s.height - 60));
    
    floatWindow.center = c;
    [pan setTranslation:CGPointZero inView:floatWindow];
}

@end

// ============================================================
// モジュール初期化（dylibロード時に実行）
// ============================================================
__attribute__((constructor))
static void PiPTweakInit() {
    PTLog(@"PiPTweak initializing...");
    
    // データ構造初期化
    capturedVideoURLs = [NSMutableArray array];
    videoStats = [NSMutableDictionary dictionary];
    videoStats[@"totalCaptures"] = @(0);
    
    // ===== NSURLSession スウィズリング（動画URLキャプチャ） =====
    Class nsCls = [NSURLSession class];
    Method nm = class_getInstanceMethod(nsCls, @selector(dataTaskWithRequest:completionHandler:));
    if (nm) {
        orig_dataTaskWithRequest = (id(*)(id, SEL, id, id))method_getImplementation(nm);
        method_setImplementation(nm, (IMP)swizzled_dataTaskWithRequest);
        PTLog(@"NSURLSession swizzled successfully");
    } else {
        PTLog(@"WARNING: dataTaskWithRequest method not found");
    }
    
    // ===== WKWebView 初期化スウィズリング =====
    Class wkCls = [WKWebView class];
    Method wkm = class_getInstanceMethod(wkCls, @selector(initWithFrame:configuration:));
    if (wkm) {
        orig_initWithFrame_config = (id(*)(id, SEL, CGRect, id))method_getImplementation(wkm);
        method_setImplementation(wkm, (IMP)swizzled_initWithFrame_config);
        PTLog(@"WKWebView swizzled successfully");
    } else {
        PTLog(@"WARNING: initWithFrame:configuration: method not found");
    }
    
    // アプリ起動後少し待ってからUI表示（WebViewの準備を待つ）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kInitDelay * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            [PiPButton show];
            PTLog(@"PiPTweak UI shown");
        });
    
    PTLog(@"PiPTweak initialization complete");
}
