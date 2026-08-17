#include <dlfcn.h>
#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>
#include <unistd.h>

/*
 * iOS 13 LaunchDaemon 启动初始 band 约 6MB；framecap 在 main() 里再抬
 * 上限有机会还没进入入口就被 Jetsam。这个极小 launcher 先抬当前 task，
 * 再 exec 真正 framecap，exec 后保留同一 task 的限制。
 */
typedef int (*zy_memstatus_fn)(uint32_t, int32_t, uint32_t, void *, size_t);

int main(int argc, char **argv) {
  if (argc < 2 || !argv[1] || !argv[1][0]) {
    return 64;
  }
  zy_memstatus_fn fn =
      (zy_memstatus_fn)dlsym(RTLD_DEFAULT, "memorystatus_control");
  if (fn) {
    (void)fn(6u, (int32_t)getpid(), 384u, NULL, 0u);
  }
  execv(argv[1], &argv[1]);
  return 127;
}
