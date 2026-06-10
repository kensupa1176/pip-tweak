#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <AVFoundation/AVFoundation.h>

// ============================================================
// 定数定義 - 強化版
// ============================================================
#define kFloatWindowLevel     UIWindowLevelAlert + 100
#define kAlertWindowLevel     UIWindowLevelAlert + 200
#define kPiPRetryCount        8
#define kPiPRetryInterval     0.4
#define kInitDelay            2.5
#define kMaxVideoCheckDelay   3.0
#define kMutationBatchSize    50

// ============================================================
// ログレベル
// ============================================================
typedef NS_ENUM(NSInteger, PTLogLevel) {
    PTLogLevelDebug = 0,
    PTLogLevelInfo = 1,
    PTLogLevelWarning = 2,
    PTLogLevelError = 3
};

static PTLogLevel globalLogLevel = PTLogLevelDebug;

#define PTLog(level, fmt, ...) do { \
    if (level >= globalLogLevel) { \
        NSLog(@"[PiPTweak] " fmt, ##__VA_ARGS__); \
    } \
} while(0)

#define PTDebug(fmt, ...) PTLog(PTLogLevelDebug, @"[DEBUG] " fmt, ##__VA_ARGS__)
#define PTInfo(fmt, ...) PTLog(PTLogLevelInfo, @"[INFO] " fmt, ##__VA_ARGS__)
#define PTWarn(fmt, ...) PTLog(PTLogLevelWarning, @"[WARN] " fmt, ##__VA_ARGS__)
#define PTError(fmt, ...) PTLog(PTLogLevelError, @"[ERROR] " fmt, ##__VA_ARGS__)

// ============================================================
// 静的変数
// ============================================================
static UIWindow *floatWindow = nil;
static UIWindow *alertWindow = nil;
static UILabel *statusLabel = nil;
static UILabel *urlCountLabel = nil;
static UILabel *streamTypeLabel = nil;
static BOOL isPiPActive = NO;
static BOOL isInitialized = NO;
static BOOL isDownloading = NO;
static NSMutableArray *capturedVideoURLs = nil;
static NSMutableDictionary *videoStats = nil;
static NSMutableDictionary *streamInfo = nil;
static NSString *lastErrorLog = nil;
static NSTimer *retryTimer = nil;
static NSInteger currentRetryCount = 0;
static WKWebView *targetWebView = nil;

// ============================================================
// 強化されたJavaScript - CodePush動的コンテンツ対応
// ============================================================
static NSString *const kEnhancedVideoSetupJS = @"(function(){"
    "var _pipSetupDone=false;"
    "var _discoveredVideos=new Set();"
    "var _pendingMutations=[];"
    "var _mutationBatchTimer=null;"
    ""
    "function getVideoKey(v){return v.currentSrc||'index:'+Array.from(document.querySelectorAll('video')).indexOf(v);}"
    ""
    "function processVideos(videos,source){"
    "videos.forEach(function(v,i){"
    "if(_discoveredVideos.has(getVideoKey(v)))return;"
    "if(!v.currentSrc&&!v.src)return;"
    "_discoveredVideos.add(getVideoKey(v));"
    ""
    "// playsinline強制"
    "if(!v.hasAttribute('playsinline'))v.setAttribute('playsinline','');"
    "if(!v.hasAttribute('webkit-playsinline'))v.setAttribute('webkit-playsinline','');"
    ""
    "// AirPlay許可"
    "v.setAttribute('x-webkit-airplay','allow');"
    "v.setAttribute('airplay','allow');"
    ""
    "// PiP関連イベント"
    "['webkitpresentationmodechanged','enterpictureinpicture','leavepictureinpicture','playing','pause','loadedmetadata'].forEach(function(evt){"
    "v.addEventListener(evt,function(e){"
    "if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.pipState){"
    "window.webkit.messageHandlers.pipState.postMessage({type:evt,videoIndex:i,source:source||'unknown'});"
    "}});"
    "});"
    "});"
    "}"
    ""
    "function scanDocument(source){"
    "var videos=document.querySelectorAll('video');"
    "processVideos(Array.from(videos),source);"
    "// iframe内もスキャン"
    "document.querySelectorAll('iframe').forEach(function(iframe){"
    "try{if(iframe.contentDocument)processVideos(Array.from(iframe.contentDocument.querySelectorAll('video')),'iframe:'+iframe.src);}catch(e){}"
    "});"
    "}"
    ""
    "function batchProcessMutations(){"
    "var allNodes=[];"
    "_pendingMutations.forEach(function(m){"
    "if(m.addedNodes)Array.from(m.addedNodes).forEach(function(n){allNodes.push(n);});"
    "});"
    "allNodes.forEach(function(node){"
    "if(node.nodeType!==1)return;"
    "var videos=node.tagName==='VIDEO'?[node]:node.querySelectorAll?node.querySelectorAll('video'):[];"
    "processVideos(Array.from(videos),'mutation');"
    "});"
    "_pendingMutations=[];"
    "}"
    ""
    "// MutationObserver設定"
    "var observer=new MutationObserver(function(mutations){"
    "_pendingMutations=_pendingMutations.concat(mutations);"
    "if(_mutationBatchTimer)clearTimeout(_mutationBatchTimer);"
    "_mutationBatchTimer=setTimeout(batchProcessMutations,100);"
    "});"
    "observer.observe(document.documentElement,{childList:true,subtree:true,attributes:true,attributeFilter:['src']});"
    ""
    "// 初回スキャン"
    "if(document.readyState==='loading'){"
    "document.addEventListener('DOMContentLoaded',function(){scanDocument('domready');});"
    "}else{scanDocument('interactive');}"
    ""
    "// iframe動的検出"
    "setInterval(function(){"
    "document.querySelectorAll('iframe').forEach(function(iframe){"
    "try{if(iframe.contentDocument&&iframe._lastCheck!==iframe.src){"
    "iframe._lastCheck=iframe.src;"
    "processVideos(Array.from(iframe.contentDocument.querySelectorAll('video')),'iframe:'+iframe.src);"
    "}}catch(e){}"
    "});"
    "},2000);"
    ""
    "window._pipHelper={"
    "getVideoInfo:function(){"
    "var vids=document.querySelectorAll('video');"
    "var info=[];"
    "vids.forEach(function(v,i){"
    "info.push({"
    "index:i,"
    "paused:v.paused,"
    "duration:v.duration||0,"
    "currentTime:v.currentTime||0,"
    "src:v.currentSrc||v.src||'',"
    "webkitMode:v.webkitPresentationMode||'none',"
    "supportsPiP:!!(v.webkitSupportsPresentationMode&&v.webkitSupportsPresentationMode('picture-in-picture')),"
    "supportsNativePiP:!!(v.requestPictureInPicture),"
    "readyState:v.readyState,"
    "videoWidth:v.videoWidth,"
    "videoHeight:v.videoHeight"
    "});"
    "});"
    "return info;"
    "},"
    "getBestVideo:function(){"
    "var vids=document.querySelectorAll('video');"
    "var best=null;"
    "var bestScore=0;"
    "vids.forEach(function(v,i){"
    "var score=0;"
    "if(v.duration>10)score+=100;"
    "if(!v.paused)score+=50;"
    "if(v.currentSrc)score+=30;"
    "if(v.readyState>=3)score+=20;"
    "if(v.videoWidth>100)score+=10;"
    "if(score>bestScore){bestScore=score;best=v;}"
    "});"
    "return best;"
    "},"
    "playAndPiP:function(){"
    "var best=this.getBestVideo();"
    "if(!best)return{status:'NO_VIDEO'};"
    "if(best.paused){best.play().catch(function(e){});}"
    "var result={status:'OK',method:null};"
    "try{if(best.webkitSupportsPresentationMode&&best.webkitSupportsPresentationMode('picture-in-picture')){best.webkitSetPresentationMode('picture-in-picture');result.method='webkit';return result;}}catch(e){}"
    "try{if(best.requestPictureInPicture){best.requestPictureInPicture().then(function(){}).catch(function(e){});result.method='pip';return result;}}catch(e){}"
    "result.status='FAIL';return result;"
    "},"
    "forcePiP:function(){"
    "var vids=document.querySelectorAll('video');"
    "for(var i=0;i<vids.length;i++){"
    "var v=vids[i];"
    "if(!v.currentSrc||v.paused)continue;"
    "try{if(v.webkitSupportsPresentationMode&&v.webkitSupportsPresentationMode('picture-in-picture')){v.webkitSetPresentationMode('picture-in-picture');return{status:'OK',method:'webkit',index:i};}}catch(e){}"
    "try{if(v.requestPictureInPicture){v.requestPictureInPicture().catch(function(e){});return{status:'OK',method:'pip',index:i};}}catch(e){}"
    "}"
    "return{status:'NO_ACTIVE_VIDEO'};"
    "},"
    "getStreamInfo:function(){"
    "var urls=new Set();"
    "document.querySelectorAll('video').forEach(function(v){"
    "if(v.currentSrc)urls.add(v.currentSrc);"
    "});"
    "document.querySelectorAll('source').forEach(function(s){"
    "if(s.src)urls.add(s.src);"
    "});"
    "return Array.from(urls);"
    "},"
    "getAllIframeSources:function(){"
    "var sources=[];"
    "document.querySelectorAll('iframe').forEach(function(iframe){"
    "try{sources.push({src:iframe.src,loaded:!!iframe.contentDocument});}catch(e){}"
    "});"
    "return sources;"
    "}"
    "};"
    "})();";

// ============================================================
// NSURLSession スウィズリング（動画URLキャプチャ強化版）
// ============================================================
static id (*orig_dataTaskWithRequest)(id, SEL, id, id) = NULL;

static id swizzled_dataTaskWithRequest(id self, SEL _cmd, NSURLRequest *request, id handler) {
    NSString *urlStr = request.URL.absoluteString ?: @"";
    
    // 動画関連URL拡張パターン
    NSArray *videoPatterns = @[
        @".m3u8", @".mp4", @".mkv", @".webm", @".ts", @".m4s",
        @".ts?", @"manifest", @"segment", @"playlist",
        @"blob:", @"googlevideo", @"videocdn", @"cdnvideo",
        @".mpd", @"//playback.", @"//dash.", @"//hls."
    ];
    
    BOOL isVideoURL = NO;
    NSString *detectedType = @"unknown";
    
    for (NSString *pattern in videoPatterns) {
        if ([urlStr containsString:pattern]) {
            isVideoURL = YES;
            if ([pattern isEqualToString:@".m3u8"]) detectedType = @"HLS";
            else if ([pattern isEqualToString:@".mp4"]) detectedType = @"MP4";
            else if ([pattern containsString:@"blob"]) detectedType = @"BLOB";
            else detectedType = @"STREAM";
            break;
        }
    }
    
    if (isVideoURL && ![capturedVideoURLs containsObject:urlStr]) {
        @synchronized(capturedVideoURLs) {
            if (![capturedVideoURLs containsObject:urlStr]) {
                [capturedVideoURLs addObject:urlStr];
                PTDebug(@"📹 [%@] URL: %@", detectedType, [urlStr substringToIndex:MIN(80, urlStr.length)]);
                
                @synchronized(videoStats) {
                    NSInteger count = [videoStats[@"totalCaptures"] integerValue] + 1;
                    videoStats[@"totalCaptures"] = @(count);
                    videoStats[@"lastType"] = detectedType;
                    
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (urlCountLabel) {
                            urlCountLabel.text = [NSString stringWithFormat:@"📹%ld", (long)count];
                        }
                        if (streamTypeLabel) {
                            streamTypeLabel.text = [NSString stringWithFormat:@"[%@]", detectedType];
                        }
                    });
                }
            }
        }
    }
    
    return orig_dataTaskWithRequest(self, _cmd, request, handler);
}

// ============================================================
// WKWebView 初期化スウィズリング（PiP設定注入強化版）
// ============================================================
static id (*orig_initWithFrame_config)(id, SEL, CGRect, id) = NULL;

static id swizzled_initWithFrame_config(id self, SEL _cmd, CGRect frame, WKWebViewConfiguration *config) {
    // PiP設定強化
    config.allowsPictureInPictureMediaPlayback = YES;
    config.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
    config.allowsInlineMediaPlayback = YES;
    
    // WKUserContentControllerが存在するか確認
    if (config.userContentController) {
        WKUserScript *script = [[WKUserScript alloc]
            initWithSource:kEnhancedVideoSetupJS
            injectionTime:WKUserScriptInjectionTimeAtDocumentStart
            forMainFrameOnly:NO];
        [config.userContentController addUserScript:script];
        
        // PiP状態受信用ハンドラ追加
        [config.userContentController addScriptMessageHandler:self name:@"pipState"];
    }
    
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
// PiPButtonEnhanced インターフェース
// ============================================================
@interface PiPButtonEnhanced : NSObject
+ (void)show;
+ (void)hide;
+ (void)onTap;
+ (void)onDownloadTap;
+ (void)onPan:(UIPanGestureRecognizer *)pan;
+ (void)showAlert:(NSString *)msg;
+ (void)showAlertWithTitle:(NSString *)title message:(NSString *)msg;
+ (NSArray *)getCapturedURLs;
+ (void)clearCapturedURLs;
+ (void)startDownload:(NSString *)urlStr;
+ (void)refreshVideoList;
+ (void)checkStreamInfo;
+ (void)toggleVerboseLogging;
+ (NSString *)getLastError;
@end

// ============================================================
// PiPButtonEnhanced 実装
// ============================================================
@implementation PiPButtonEnhanced

+ (UIWindowScene *)getWindowScene {
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) {
            return (UIWindowScene *)s;
        }
    }
    return nil;
}

+ (NSArray *)collectWebViews {
    UIWindowScene *ws = [self getWindowScene];
    if (!ws) return @[];
    
    NSMutableArray *all = [NSMutableArray array];
    for (UIWindow *win in ws.windows) {
        if (win == floatWindow || win == alertWindow) continue;
        [self collectWebViewsRecursively:win into:all];
    }
    return all;
}

+ (void)collectWebViewsRecursively:(UIView *)view into:(NSMutableArray *)arr {
    if ([view isKindOfClass:[WKWebView class]]) {
        [arr addObject:view];
    }
    for (UIView *sub in view.subviews) {
        [self collectWebViewsRecursively:sub into:arr];
    }
}

+ (void)evalJS:(NSString *)js inWebView:(WKWebView *)wv completion:(void(^)(id, NSError*))handler {
    @try {
        [wv setValue:@YES forKeyPath:@"configuration.allowsPictureInPictureMediaPlayback"];
    } @catch (NSException *e) {
        PTDebug(@"KVC PiP setting: %@", e);
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

+ (void)attemptPiP {
    NSArray *webViews = [self collectWebViews];
    
    if (!webViews.count) {
        [self showAlert:@"WebViewが見つかりません"];
        return;
    }
    
    if (statusLabel) statusLabel.text = @"検索中";
    
    // まず動画の存在を確認
    __block BOOL foundVideo = NO;
    __block NSInteger checked = 0;
    
    for (WKWebView *wv in webViews) {
        [self evalJS:@"window._pipHelper?window._pipHelper.getVideoInfo().length:document.querySelectorAll('video').length"
           inWebView:wv completion:^(id result, NSError *error) {
            checked++;
            if ([result integerValue] > 0) {
                foundVideo = YES;
                targetWebView = wv;
            }
            
            if (checked == webViews.count) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (foundVideo) {
                        [self startPiPAttempts];
                    } else {
                        [self showAlert:@"動画要素が見つかりません\nページを読み込んでから\n再度タップしてください"];
                        if (statusLabel) statusLabel.text = @"OFF";
                    }
                });
            }
        }];
    }
}

+ (void)startPiPAttempts {
    currentRetryCount = kPiPRetryCount;
    [self attemptPiPWithRetry];
}

+ (void)attemptPiPWithRetry {
    if (currentRetryCount <= 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (statusLabel) statusLabel.text = @"失敗";
        });
        PTError(@"PiP retry exhausted: %@", lastErrorLog ?: @"unknown");
        return;
    }
    
    if (!targetWebView) {
        NSArray *webViews = [self collectWebViews];
        for (WKWebView *wv in webViews) {
            targetWebView = wv;
            break;
        }
    }
    
    if (!targetWebView) {
        [self showAlert:@"WebView参照失効"];
        return;
    }
    
    PTDebug(@"PiP attempt %ld/%ld", (long)(kPiPRetryCount - currentRetryCount + 1), (long)kPiPRetryCount);
    
    // まずforcePiPを試行
    [self evalJS:@"window._pipHelper?window._pipHelper.forcePiP():{status:'NO_HELPER'}"
       inWebView:targetWebView completion:^(id result, NSError *error) {
        if (result && ![result isEqual:[NSNull null]]) {
            NSString *str = [NSString stringWithFormat:@"%@", result];
            PTDebug(@"forcePiP result: %@", str);
            
            if ([str containsString:@"OK"]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    isPiPActive = YES;
                    [self updateButtonState];
                    if (statusLabel) statusLabel.text = @"ON";
                });
                return;
            }
        }
        
        // 再生→PiPシーケンス
        [self evalJS:@"var best=window._pipHelper?window._pipHelper.getBestVideo():null;if(!best){var vids=document.querySelectorAll('video');for(var i=0;i<vids.length;i++){if(vids[i].currentSrc){best=vids[i];break;}}}if(best&&best.paused){best.play().catch(function(){});}true;"
           inWebView:targetWebView completion:^(id r, NSError *e) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    [self evalJS:@"var v=window._pipHelper?window._pipHelper.getBestVideo():null;if(!v){v=document.querySelectorAll('video')[0];}if(v){try{if(v.webkitSupportsPresentationMode&&v.webkitSupportsPresentationMode('picture-in-picture')){v.webkitSetPresentationMode('picture-in-picture');window._pipResult='webkit';return;}}catch(e){}try{if(v.requestPictureInPicture){v.requestPictureInPicture().then(function(){}).catch(function(){});window._pipResult='pip';return;}}catch(e){}}window._pipResult='fail';"
                       inWebView:targetWebView completion:^(id r2, NSError *e2) {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                            dispatch_get_main_queue(), ^{
                                [self evalJS:@"window._pipResult||'none'"
                                   inWebView:targetWebView completion:^(id r3, NSError *e3) {
                                    NSString *resultStr = [NSString stringWithFormat:@"%@", r3 ?: @"none"];
                                    PTDebug(@"PiP method: %@", resultStr);
                                    
                                    if ([resultStr containsString:@"webkit"] || [resultStr containsString:@"pip"]) {
                                        isPiPActive = YES;
                                        [self updateButtonState];
                                        if (statusLabel) statusLabel.text = @"ON";
                                    } else {
                                        currentRetryCount--;
                                        [self attemptPiPWithRetry];
                                    }
                                }];
                            });
                    }];
                });
        }];
    }];
}

+ (void)stopPiP {
    NSArray *webViews = [self collectWebViews];
    
    NSString *stopJS = @"(function(){var stopped=false;"
    "document.querySelectorAll('video').forEach(function(v){"
    "try{if(v.webkitPresentationMode==='picture-in-picture'){v.webkitSetPresentationMode('inline');stopped=true;}}catch(e){}"
    "});"
    "try{if(document.pictureInPictureElement){document.exitPictureInPicture();stopped=true;}}catch(e){}"
    "return stopped?'STOPPED':'NOT_ACTIVE';"
    "})();";
    
    for (WKWebView *wv in webViews) {
        [self evalJS:stopJS inWebView:wv completion:^(id r, NSError *e) {
            if (r && ![r isEqual:[NSNull null]]) {
                NSString *str = [NSString stringWithFormat:@"%@", r];
                if ([str isEqualToString:@"STOPPED"]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        isPiPActive = NO;
                        [self updateButtonState];
                        if (statusLabel) statusLabel.text = @"OFF";
                    });
                }
            }
        }];
    }
}

+ (void)checkStreamInfo {
    NSArray *webViews = [self collectWebViews];
    
    for (WKWebView *wv in webViews) {
        [self evalJS:@"JSON.stringify({videoCount:window._pipHelper?window._pipHelper.getVideoInfo().length:0,urls:window._pipHelper?window._pipHelper.getStreamInfo():[],iframes:window._pipHelper?window._pipHelper.getAllIframeSources():[]})"
           inWebView:wv completion:^(id r, NSError *e) {
            if (r && ![r isEqual:[NSNull null]]) {
                PTInfo(@"Stream info: %@", r);
            }
        }];
    }
}

+ (void)refreshVideoList {
    NSArray *webViews = [self collectWebViews];
    
    // 強制再スキャン
    NSString *rescanJS = @"(function(){if(window._pipHelper){var vids=document.querySelectorAll('video');var info=window._pipHelper.getVideoInfo();return 'Videos:'+info.length+' / Active:'+(info.filter(function(v){return !v.paused}).length);}return 'No helper';})();";
    
    for (WKWebView *wv in webViews) {
        [self evalJS:rescanJS inWebView:wv completion:^(id r, NSError *e) {
            if (r && ![r isEqual:[NSNull null]]) {
                PTInfo(@"Video list: %@", r);
            }
        }];
    }
}

+ (void)updateButtonState {
    if (!floatWindow) return;
    
    UIButton *pipBtn = nil;
    for (UIView *v in floatWindow.rootViewController.view.subviews) {
        if ([v isKindOfClass:[UIButton class]] && ((UIButton*)v).tag == 1) {
            pipBtn = (UIButton*)v;
            break;
        }
    }
    
    if (pipBtn) {
        pipBtn.backgroundColor = isPiPActive
            ? [UIColor colorWithRed:0.0 green:0.7 blue:1.0 alpha:0.95]
            : [UIColor colorWithRed:0.15 green:0.15 blue:0.15 alpha:0.92];
    }
    
    if (statusLabel) {
        statusLabel.text = isPiPActive ? @"ON" : @"OFF";
    }
}

+ (void)showAlert:(NSString *)msg {
    [self showAlertWithTitle:@"PiP Tweak" message:msg];
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
            if (streamTypeLabel) streamTypeLabel.text = @"[---]";
        });
    }
    PTInfo(@"URLs cleared");
}

+ (void)startDownload:(NSString *)urlStr {
    if (isDownloading) {
        [self showAlert:@"ダウンロード中..."];
        return;
    }
    
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        [self showAlert:@"URLが無効です"];
        return;
    }
    
    isDownloading = YES;
    if (statusLabel) statusLabel.text = @"DL中";
    
    // ダウンロードボタンにオレンジ色を設定
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIView *v in floatWindow.rootViewController.view.subviews) {
            if ([v isKindOfClass:[UIButton class]] && ((UIButton*)v).tag == 2) {
                ((UIButton*)v).backgroundColor = [UIColor colorWithRed:1.0 green:0.5 blue:0.0 alpha:0.95];
                break;
            }
        }
    });
    
    // HLS検出時の警告
    BOOL isHLS = [urlStr containsString:@".m3u8"];
    
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.HTTPAdditionalHeaders = @{
        @"User-Agent": @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
        @"Referer": @"https://vidlink.pro/",
        @"Accept": @"*/*",
        @"Accept-Language": @"ja-JP,ja;q=0.9,en-US;q=0.8,en;q=0.7"
    };
    config.timeoutIntervalForRequest = 60;
    config.timeoutIntervalForResource = 600;
    
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:nil delegateQueue:[NSOperationQueue mainQueue]];
    
    [[session downloadTaskWithURL:url completionHandler:^(NSURL *loc, NSURLResponse *resp, NSError *err) {
        isDownloading = NO;
        
        // ボタンを元の色に戻す
        dispatch_async(dispatch_get_main_queue(), ^{
            for (UIView *v in floatWindow.rootViewController.view.subviews) {
                if ([v isKindOfClass:[UIButton class]] && ((UIButton*)v).tag == 2) {
                    ((UIButton*)v).backgroundColor = [UIColor colorWithRed:0.15 green:0.15 blue:0.15 alpha:0.92];
                    break;
                }
            }
        });
        
        if (err || !loc) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showAlert:[NSString stringWithFormat:@"DL失敗:\n%@", err.localizedDescription ?: @"不明"]];
                if (statusLabel) statusLabel.text = @"ERR";
            });
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
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (moveErr) {
                [self showAlert:[NSString stringWithFormat:@"保存失敗:\n%@", moveErr.localizedDescription]];
                if (statusLabel) statusLabel.text = @"ERR";
            } else {
                NSString *msg = isHLS
                    ? [NSString stringWithFormat:@"✅ 保存完了!\n%@\n\n⚠️ HLSは分割ファイルです\nVLCで.m3u8を開いてください", filename]
                    : [NSString stringWithFormat:@"✅ 保存完了!\n%@\n\nFilesアプリ→このiPhone内で確認", filename];
                [self showAlert:msg];
                if (statusLabel) statusLabel.text = @"完了";
            }
        });
    }] resume];
}

+ (NSString *)getLastError {
    return lastErrorLog;
}

+ (void)toggleVerboseLogging {
    globalLogLevel = (globalLogLevel == PTLogLevelDebug) ? PTLogLevelInfo : PTLogLevelDebug;
    [self showAlert:[NSString stringWithFormat:@"ログレベル: %@", 
        globalLogLevel == PTLogLevelDebug ? @"詳細" : @"標準"]];
}

+ (void)show {
    if (floatWindow) return;
    
    @try {
        UIWindowScene *ws = [self getWindowScene];
        if (!ws) {
            PTError(@"Failed to get window scene");
            return;
        }
        
        floatWindow = [[PassthroughWindow alloc] initWithWindowScene:ws];
        floatWindow.frame = CGRectMake(20, 120, 80, 200);
        floatWindow.windowLevel = kFloatWindowLevel;
        floatWindow.backgroundColor = [UIColor clearColor];
        UIViewController *vc = [UIViewController new];
        vc.view.backgroundColor = [UIColor clearColor];
        floatWindow.rootViewController = vc;
        floatWindow.hidden = NO;
        
        // ===== PiPボタン =====
        UIButton *pipBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        pipBtn.tag = 1;
        pipBtn.frame = CGR