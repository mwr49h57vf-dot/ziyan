#import <Foundation/Foundation.h>
#import "ZiYanAppSelector.h"
#import "ZiYanScriptGenerator.h"
#import "ZiYanDumpManager.h"

/// .101：list | gen | dump
int main(int argc, char *argv[]) {
  @autoreleasepool {
    NSString *mode = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"gen";
    if ([mode isEqualToString:@"list"]) {
      NSArray<ZiYanAppPick *> *apps = [ZiYanAppSelector enumerateApps];
      for (ZiYanAppPick *p in apps) {
        printf("%s\t%s\t%s\n", p.displayName.UTF8String ?: "",
               p.bundleId.UTF8String ?: "", p.bundlePath.UTF8String ?: "");
      }
      printf("count=%lu\n", (unsigned long)apps.count);
      return 0;
    }
    ZiYanAppPick *app = [ZiYanAppPick new];
    app.displayName =
        argc > 2 ? [NSString stringWithUTF8String:argv[2]] : @"SmokeApp";
    app.bundleId =
        argc > 3 ? [NSString stringWithUTF8String:argv[3]] : @"com.ziyan.smoke";
    app.bundlePath = argc > 4 ? [NSString stringWithUTF8String:argv[4]] : nil;
    if (!app.bundlePath.length) {
      app.bundlePath = @"/Applications/ZiYan.app";
    }
    NSString *err = nil;
    if ([mode isEqualToString:@"dump"]) {
      NSString *dir = [ZiYanDumpManager dumpAndAnalyze:app error:&err];
      printf("dump_dir=%s\nerr=%s\n", dir.UTF8String ?: "",
             err.UTF8String ?: "");
      return dir.length ? 0 : 2;
    }
    NSString *path = [ZiYanScriptGenerator generateForApp:app
                                               resProfile:@"iphone7_13"
                                                    error:&err];
    printf("gen_path=%s\nerr=%s\n", path.UTF8String ?: "", err.UTF8String ?: "");
    return path.length ? 0 : 1;
  }
}
