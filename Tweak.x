#import <Foundation/Foundation.h>

__attribute__((constructor))
static void PiPTweakInit() {
    NSLog(@"[PiPTweak] loaded OK");
}
