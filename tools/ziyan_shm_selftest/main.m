#import "ZiYanFrameShm.h"
#import <Foundation/Foundation.h>
#import <stdio.h>

/// 阶段2：共享帧 shm 本地自检入口（不依赖真机部署）
/// 用法：ziyan_shm_selftest [workDir]
int main(int argc, char *argv[]) {
  @autoreleasepool {
    NSString *work = argc > 1
                         ? [NSString stringWithUTF8String:argv[1]]
                         : [NSTemporaryDirectory()
                               stringByAppendingPathComponent:@"ziyan_shm_st"];
    NSString *report = nil;
    BOOL ok = ZiYanFrameShmRunSelfTests(work, &report);
    if (report.length) {
      fputs(report.UTF8String, ok ? stdout : stderr);
    }
    printf("ZIYAN_SHM_SELFTEST=%s work=%s sizeof_hdr=%zu\n",
           ok ? "PASS" : "FAIL", work.UTF8String ?: "",
           sizeof(ZiYanFrameShmHeader));
    return ok ? 0 : 1;
  }
}
