#import <Foundation/Foundation.h>
#import "ZiYanPaths.h"

/*
 * ZiYanFsCloak — 8-67 停用（空壳）
 *
 * 学习对照（免费开源 / 原理，不拷贝专有实现）：
 * - Shadow https://github.com/jjolano/shadow ：仅在目标 App 内 hook 文件系统/检测 API
 * - FlyJB / Liberty Lite / tsProtector：同属「App 内绕过」，不碰 AFC/lockdownd
 *
 * 历史错误：向 afc2d rename/hook → .166 Media 错误13、afc2d 崩溃、.53 爱思转圈。
 * 越狱路径伪装改由 ZiYanDefense（UIKit App 内）承担；USB/爱思保持系统原生 AFC。
 */

__attribute__((constructor)) static void ZiYanFsCloakInit(void) {
  @autoreleasepool {
    // 故意不安装任何 Hook；Filter 亦指向不存在 Bundle
    ZiYanEnsureVarDirectory();
    [@"disabled_867 path_hook_removed use_Defense_only\n"
        writeToFile:ZiYanVarFile(@".ziyan_fs_cloak_log")
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
  }
}
