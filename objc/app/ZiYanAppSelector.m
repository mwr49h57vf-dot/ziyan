#import "ZiYanAppSelector.h"
#import <objc/runtime.h>

@implementation ZiYanAppPick
@end

@implementation ZiYanAppSelector

+ (void)addPick:(ZiYanAppPick *)p
        into:(NSMutableArray<ZiYanAppPick *> *)out
       seen:(NSMutableSet<NSString *> *)seen {
  if (!p.bundleId.length || [seen containsObject:p.bundleId]) {
    return;
  }
  [seen addObject:p.bundleId];
  [out addObject:p];
}

/// 解析 Info.plist（二进制/XML）取 bid / 显示名
+ (nullable ZiYanAppPick *)pickFromAppBundle:(NSString *)appPath {
  if (appPath.length == 0) {
    return nil;
  }
  NSString *infoPath = [appPath stringByAppendingPathComponent:@"Info.plist"];
  NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
  if (![info isKindOfClass:[NSDictionary class]]) {
    return nil;
  }
  NSString *bid = info[@"CFBundleIdentifier"];
  if (![bid isKindOfClass:[NSString class]] || bid.length == 0) {
    return nil;
  }
  // 过滤系统杂项
  if ([bid hasPrefix:@"com.apple."] && ![bid containsString:@"AppStore"]) {
    return nil;
  }
  NSString *name = info[@"CFBundleDisplayName"];
  if (![name isKindOfClass:[NSString class]] || name.length == 0) {
    name = info[@"CFBundleName"];
  }
  if (![name isKindOfClass:[NSString class]] || name.length == 0) {
    name = bid;
  }
  ZiYanAppPick *p = [ZiYanAppPick new];
  p.bundleId = bid;
  p.displayName = name;
  p.bundlePath = appPath;
  return p;
}

/// 文件系统兜底：iOS13 rootful 容器多为 …/UUID/Foo.app（无 Payload）
+ (void)enumerateViaFilesystem:(NSMutableArray<ZiYanAppPick *> *)out
                          seen:(NSMutableSet<NSString *> *)seen {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSArray *roots = @[
    @"/var/containers/Bundle/Application",
    @"/var/mobile/Containers/Bundle/Application",
    @"/Applications",
  ];
  for (NSString *root in roots) {
    NSArray *uuids = [fm contentsOfDirectoryAtPath:root error:nil];
    for (NSString *leaf in uuids ?: @[]) {
      NSString *dir = [root stringByAppendingPathComponent:leaf];
      BOOL isDir = NO;
      if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) {
        continue;
      }
      // /Applications/*.app 或 UUID 下 *.app
      if ([leaf hasSuffix:@".app"]) {
        ZiYanAppPick *p = [self pickFromAppBundle:dir];
        [self addPick:p into:out seen:seen];
        continue;
      }
      NSArray *kids = [fm contentsOfDirectoryAtPath:dir error:nil];
      for (NSString *k in kids ?: @[]) {
        if (![k hasSuffix:@".app"]) {
          continue;
        }
        NSString *app = [dir stringByAppendingPathComponent:k];
        ZiYanAppPick *p = [self pickFromAppBundle:app];
        [self addPick:p into:out seen:seen];
      }
      // Payload/*.app（少数包）
      NSString *payload = [dir stringByAppendingPathComponent:@"Payload"];
      NSArray *pays = [fm contentsOfDirectoryAtPath:payload error:nil];
      for (NSString *k in pays ?: @[]) {
        if (![k hasSuffix:@".app"]) {
          continue;
        }
        ZiYanAppPick *p =
            [self pickFromAppBundle:[payload stringByAppendingPathComponent:k]];
        [self addPick:p into:out seen:seen];
      }
    }
  }
}

+ (NSArray<ZiYanAppPick *> *)enumerateApps {
  NSMutableArray<ZiYanAppPick *> *out = [NSMutableArray array];
  NSMutableSet<NSString *> *seen = [NSMutableSet set];

  // 1) LSApplicationWorkspace
  Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
  id ws = nil;
  if (wsCls && [wsCls respondsToSelector:NSSelectorFromString(@"defaultWorkspace")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    ws = [wsCls performSelector:NSSelectorFromString(@"defaultWorkspace")];
#pragma clang diagnostic pop
  }
  NSArray *apps = nil;
  if (ws && [ws respondsToSelector:NSSelectorFromString(@"allInstalledApplications")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    apps = [ws performSelector:NSSelectorFromString(@"allInstalledApplications")];
#pragma clang diagnostic pop
  }
  for (id proxy in apps ?: @[]) {
    NSString *bid = nil;
    NSString *name = nil;
    NSString *path = nil;
    if ([proxy respondsToSelector:NSSelectorFromString(@"applicationIdentifier")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      bid = [proxy performSelector:NSSelectorFromString(@"applicationIdentifier")];
#pragma clang diagnostic pop
    }
    if ([proxy respondsToSelector:NSSelectorFromString(@"localizedName")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      name = [proxy performSelector:NSSelectorFromString(@"localizedName")];
#pragma clang diagnostic pop
    }
    if ([proxy respondsToSelector:NSSelectorFromString(@"bundleURL")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      NSURL *u = [proxy performSelector:NSSelectorFromString(@"bundleURL")];
#pragma clang diagnostic pop
      path = u.path;
    }
    if (bid.length == 0) {
      continue;
    }
    if ([bid hasPrefix:@"com.apple."] && ![bid containsString:@"AppStore"]) {
      continue;
    }
    ZiYanAppPick *p = [ZiYanAppPick new];
    p.bundleId = bid;
    p.displayName = name.length ? name : bid;
    p.bundlePath = path;
    [self addPick:p into:out seen:seen];
  }

  // 2) 文件系统兜底（保证游戏如 血战屠龙/赤沙龙城 可见）
  [self enumerateViaFilesystem:out seen:seen];

  // 用户 App（非 com.apple）排前，便于点选游戏
  [out sortUsingComparator:^NSComparisonResult(ZiYanAppPick *a, ZiYanAppPick *b) {
    BOOL aSys = [a.bundleId hasPrefix:@"com.apple."];
    BOOL bSys = [b.bundleId hasPrefix:@"com.apple."];
    if (aSys != bSys) {
      return aSys ? NSOrderedDescending : NSOrderedAscending;
    }
    return [a.displayName localizedCaseInsensitiveCompare:b.displayName];
  }];

  if (out.count == 0) {
    ZiYanAppPick *hint = [ZiYanAppPick new];
    hint.displayName = @"(无法枚举，可手填 Bundle ID)";
    hint.bundleId = @"com.example.manual";
    [out addObject:hint];
  }
  return out;
}

+ (void)presentFrom:(UIViewController *)host
          completion:(ZiYanAppSelectHandler)completion {
  [self presentFrom:host purpose:@"操作" completion:completion];
}

+ (void)presentFrom:(UIViewController *)host
            purpose:(NSString *)purpose
         completion:(ZiYanAppSelectHandler)completion {
  NSString *pur = purpose.length ? purpose : @"操作";
  NSArray<ZiYanAppPick *> *apps = [self enumerateApps];
  UIAlertController *sheet = [UIAlertController
      alertControllerWithTitle:[NSString stringWithFormat:@"选择目标 App（%@）", pur]
                       message:@"请人工点选；下一步将弹出标识确认"
                preferredStyle:UIAlertControllerStyleActionSheet];
  // 列表略增，避免游戏被截断
  NSUInteger limit = MIN(apps.count, (NSUInteger)60);
  for (NSUInteger i = 0; i < limit; i++) {
    ZiYanAppPick *p = apps[i];
    NSString *title =
        [NSString stringWithFormat:@"%@  (%@)", p.displayName, p.bundleId];
    [sheet addAction:[UIAlertAction
                         actionWithTitle:title
                                   style:UIAlertActionStyleDefault
                                 handler:^(__unused UIAlertAction *a) {
                                   NSString *msg = [NSString
                                       stringWithFormat:
                                           @"名称：%@\n"
                                            @"标识(Bundle ID)：%@\n"
                                            @"路径：%@\n\n"
                                            @"确认后开始「%@」",
                                           p.displayName ?: @"",
                                           p.bundleId ?: @"",
                                           p.bundlePath ?: @"(未知)", pur];
                                   UIAlertController *cfm = [UIAlertController
                                       alertControllerWithTitle:@"确认选中标识"
                                                        message:msg
                                                 preferredStyle:
                                                     UIAlertControllerStyleAlert];
                                   [cfm addAction:[UIAlertAction
                                                      actionWithTitle:@"取消"
                                                                style:
                                                                    UIAlertActionStyleCancel
                                                              handler:^(__unused
                                                                            UIAlertAction
                                                                                *x) {
                                                                if (completion)
                                                                  completion(nil);
                                                              }]];
                                   [cfm addAction:[UIAlertAction
                                                      actionWithTitle:@"确认开始"
                                                                style:
                                                                    UIAlertActionStyleDefault
                                                              handler:^(__unused
                                                                            UIAlertAction
                                                                                *x) {
                                                                if (completion)
                                                                  completion(p);
                                                              }]];
                                   [host presentViewController:cfm
                                                      animated:YES
                                                    completion:nil];
                                 }]];
  }
  [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                            style:UIAlertActionStyleCancel
                                          handler:^(__unused UIAlertAction *a) {
                                            if (completion)
                                              completion(nil);
                                          }]];
  if (sheet.popoverPresentationController) {
    sheet.popoverPresentationController.sourceView = host.view;
    sheet.popoverPresentationController.sourceRect =
        CGRectMake(CGRectGetMidX(host.view.bounds),
                   CGRectGetMaxY(host.view.bounds) - 60, 1, 1);
  }
  [host presentViewController:sheet animated:YES completion:nil];
}

+ (BOOL)isExcludedUserApp:(NSString *)bid {
  if (bid.length == 0) {
    return YES;
  }
  if ([bid isEqualToString:@"com.ziyan.ziyan"] ||
      [bid hasPrefix:@"com.ziyan."]) {
    return YES;
  }
  if ([bid isEqualToString:@"com.example.manual"]) {
    return YES;
  }
  return NO;
}

+ (NSArray<ZiYanAppPick *> *)enumerateUserApps {
  NSMutableArray<ZiYanAppPick *> *out = [NSMutableArray array];
  for (ZiYanAppPick *p in [self enumerateApps]) {
    if ([self isExcludedUserApp:p.bundleId]) {
      continue;
    }
    [out addObject:p];
  }
  return out;
}

+ (void)presentRealAppPickerFrom:(UIViewController *)host
                      completion:(ZiYanAppSelectHandler)completion {
  NSArray<ZiYanAppPick *> *apps = [self enumerateUserApps];
  UIAlertController *sheet = [UIAlertController
      alertControllerWithTitle:@"选择 Agent 游戏"
                       message:nil
                preferredStyle:UIAlertControllerStyleActionSheet];
  NSUInteger limit = MIN(apps.count, (NSUInteger)80);
  for (NSUInteger i = 0; i < limit; i++) {
    ZiYanAppPick *p = apps[i];
    NSString *title =
        [NSString stringWithFormat:@"%@  (%@)", p.displayName, p.bundleId];
    [sheet addAction:[UIAlertAction
                         actionWithTitle:title
                                   style:UIAlertActionStyleDefault
                                 handler:^(__unused UIAlertAction *a) {
                                   NSString *msg = [NSString
                                       stringWithFormat:
                                           @"当前选中：%@\n标识：%@",
                                           p.displayName ?: @"",
                                           p.bundleId ?: @""];
                                   UIAlertController *cfm = [UIAlertController
                                       alertControllerWithTitle:@"确认当前目标"
                                                        message:msg
                                                 preferredStyle:
                                                     UIAlertControllerStyleAlert];
                                   [cfm addAction:[UIAlertAction
                                                      actionWithTitle:@"取消"
                                                                style:
                                                                    UIAlertActionStyleCancel
                                                              handler:^(__unused
                                                                            UIAlertAction
                                                                                *x) {
                                                                if (completion)
                                                                  completion(nil);
                                                              }]];
                                   [cfm addAction:[UIAlertAction
                                                      actionWithTitle:@"确认"
                                                                style:
                                                                    UIAlertActionStyleDefault
                                                              handler:^(__unused
                                                                            UIAlertAction
                                                                                *x) {
                                                                if (completion)
                                                                  completion(p);
                                                              }]];
                                   [host presentViewController:cfm
                                                      animated:YES
                                                    completion:nil];
                                 }]];
  }
  [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                            style:UIAlertActionStyleCancel
                                          handler:^(__unused UIAlertAction *a) {
                                            if (completion)
                                              completion(nil);
                                          }]];
  if (sheet.popoverPresentationController) {
    sheet.popoverPresentationController.sourceView = host.view;
    sheet.popoverPresentationController.sourceRect =
        CGRectMake(CGRectGetMidX(host.view.bounds),
                   CGRectGetMaxY(host.view.bounds) - 60, 1, 1);
  }
  [host presentViewController:sheet animated:YES completion:nil];
}

@end
