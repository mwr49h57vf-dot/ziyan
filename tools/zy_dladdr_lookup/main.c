#include <dlfcn.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s <address> [address...]\n", argv[0]);
    return 2;
  }
  int bad = 0;
  for (int i = 1; i < argc; i++) {
    char *end = NULL;
    uint64_t value = strtoull(argv[i], &end, 0);
    if (!end || *end != '\0') {
      fprintf(stderr, "invalid address: %s\n", argv[i]);
      bad = 1;
      continue;
    }
    Dl_info info;
    if (!dladdr((void *)(uintptr_t)value, &info)) {
      printf("addr=0x%" PRIx64 " found=0\n", value);
      bad = 1;
      continue;
    }
    uintptr_t image = (uintptr_t)info.dli_fbase;
    uintptr_t symbol = (uintptr_t)info.dli_saddr;
    printf("addr=0x%" PRIx64
           " found=1 image=%s image_base=0x%" PRIxPTR
           " image_off=0x%" PRIx64
           " symbol=%s symbol_addr=0x%" PRIxPTR
           " symbol_off=0x%" PRIx64 "\n",
           value, info.dli_fname ? info.dli_fname : "-", image,
           value >= image ? value - image : 0,
           info.dli_sname ? info.dli_sname : "-", symbol,
           symbol && value >= symbol ? value - symbol : 0);
  }
  return bad ? 1 : 0;
}
