#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach/mach_port.h>
#import <mach_debug/ipc_info.h>

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/*
 * 一次性读取目标进程 Mach port-space 基础计数。
 *
 * 不常驻、不创建 dispatch source；task_for_pid 拿到的 task port 在每次
 * 采样结束前 mach_port_deallocate。用于定位 PORT_SPACE 增长边界，不能
 * 作为点击或 SpringBoard 稳定性的成功结论。
 */
static int SamplePortSpace(pid_t pid) {
  task_t task = MACH_PORT_NULL;
  kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
  if (kr != KERN_SUCCESS || task == MACH_PORT_NULL) {
    printf("{\"ok\":false,\"error\":\"task_for_pid_failed\",\"kr\":%d,"
           "\"pid\":%d}\n",
           (int)kr, (int)pid);
    return 1;
  }

  ipc_info_space_basic_t info;
  memset(&info, 0, sizeof(info));
  kr = mach_port_space_basic_info(task, &info);
  kern_return_t releaseKr = mach_port_deallocate(mach_task_self(), task);
  if (kr != KERN_SUCCESS) {
    printf("{\"ok\":false,\"error\":\"mach_port_space_basic_info_failed\","
           "\"kr\":%d,\"release_kr\":%d,\"pid\":%d}\n",
           (int)kr, (int)releaseKr, (int)pid);
    return 1;
  }

  printf("{\"ok\":true,\"pid\":%d,\"table_size\":%u,\"table_next\":%u,"
         "\"table_inuse\":%u,\"genno_mask\":%u,\"release_kr\":%d}\n",
         (int)pid, info.iisb_table_size, info.iisb_table_next,
         info.iisb_table_inuse, info.iisb_genno_mask, (int)releaseKr);
  return releaseKr == KERN_SUCCESS ? 0 : 1;
}

int main(int argc, char *argv[]) {
  @autoreleasepool {
    if (argc != 2) {
      fprintf(stderr, "usage: %s <pid>\n", argv[0]);
      return 2;
    }
    char *end = NULL;
    errno = 0;
    long rawPid = strtol(argv[1], &end, 10);
    if (errno != 0 || end == argv[1] || *end != '\0' || rawPid <= 0 ||
        rawPid > INT_MAX) {
      fprintf(stderr, "invalid pid: %s\n", argv[1]);
      return 2;
    }
    return SamplePortSpace((pid_t)rawPid);
  }
}
