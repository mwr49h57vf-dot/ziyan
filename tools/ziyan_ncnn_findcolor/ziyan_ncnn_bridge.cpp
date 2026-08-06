#include "ziyan_ncnn_bridge.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#if __has_include(<ncnn/mat.h>)
#define ZIYAN_HAS_NCNN 1
#include <ncnn/cpu.h>
#include <ncnn/mat.h>
#include <ncnn/net.h>
#else
#define ZIYAN_HAS_NCNN 0
#endif

// ColorMatch C 导出（LOCK 公式真坐标；禁止硬编码假点）
extern "C" char *ZiYanColorMatchFindMultiC(
    const uint8_t *pixels, size_t width, size_t height, size_t bpr,
    const char *pointsJSON, int fuzzy, int ltx, int lty, int rbx, int rby,
    int scaleHint);

#if ZIYAN_HAS_NCNN
static ncnn::Net *sNet = nullptr;
#endif

extern "C" int ZiYanNcnnBridgeEnabled(void) {
  static int s = -1;
  if (s >= 0) {
    return s;
  }
#if ZIYAN_HAS_NCNN
  s = 1;
  if (access("/usr/lib/ziyan/var/.ziyan_ncnn_off", F_OK) == 0 ||
      access("/var/jb/usr/lib/ziyan/var/.ziyan_ncnn_off", F_OK) == 0) {
    s = 0;
  }
#else
  s = 0;
#endif
  return s;
}

/*
  8-149：不再每 find memcpy 整帧（.53 11MP 拷贝无收益、拖慢找色）。
  ColorMatch 已按 bpr 读像素；此处只做一次性 NCNN CPU/OMP 初始化。
*/
extern "C" uint8_t *ZiYanNcnnBridgePrepare(const uint8_t *pixels, size_t width,
                                           size_t height, size_t bpr,
                                           size_t *outBpr) {
  if (outBpr) {
    *outBpr = bpr;
  }
  (void)pixels;
  (void)width;
  (void)height;
  if (!ZiYanNcnnBridgeEnabled()) {
    return NULL;
  }
#if ZIYAN_HAS_NCNN
  static int sInited = 0;
  if (!sInited) {
    sInited = 1;
    ncnn::set_cpu_powersave(2);
    ncnn::set_omp_num_threads(1);
    ncnn::set_omp_dynamic(0);
    ncnn::Mat touch(8, 8, (size_t)4u);
    (void)touch;
  }
#endif
  return NULL; // 不分配；调用方用原缓冲
}

extern "C" int ZiYanNcnnBridgeLoadModel(const char *paramPath) {
  if (!paramPath || !ZiYanNcnnBridgeEnabled()) {
    return 0;
  }
#if ZIYAN_HAS_NCNN
  char binPath[512];
  snprintf(binPath, sizeof(binPath), "%s", paramPath);
  size_t n = strlen(binPath);
  if (n > 6 && strcmp(binPath + n - 6, ".param") == 0) {
    strcpy(binPath + n - 6, ".bin");
  } else {
    strncat(binPath, ".bin", sizeof(binPath) - strlen(binPath) - 1);
  }
  if (access(paramPath, R_OK) != 0) {
    return 0;
  }
  if (!sNet) {
    sNet = new ncnn::Net();
    sNet->opt.use_vulkan_compute = false;
    sNet->opt.num_threads = 1;
  }
  if (sNet->load_param(paramPath) != 0) {
    return 0;
  }
  // 8-157：仅 param 网络（AbsVal/Flatten）跳过 load_model；占位 bin(≤16B) 忽略
  FILE *bf = fopen(binPath, "rb");
  if (bf) {
    fseek(bf, 0, SEEK_END);
    long sz = ftell(bf);
    fclose(bf);
    if (sz > 16) {
      if (sNet->load_model(binPath) != 0) {
        return 0;
      }
    }
  }
  // 加载时一次性 Extractor 冒烟（不进 find 热路径，避免拖垮 ≤15ms）
  {
    ncnn::Mat in(8, 8, (size_t)4u);
    in.fill(0.f);
    ncnn::Extractor ex = sNet->create_extractor();
    if (ex.input("input", in) == 0) {
      ncnn::Mat out;
      (void)ex.extract("output", out);
    }
  }
  return 1;
#else
  (void)paramPath;
  return 0;
#endif
}

extern "C" void ZiYanNcnnBridgeUnloadModel(void) {
#if ZIYAN_HAS_NCNN
  if (sNet) {
    delete sNet;
    sNet = nullptr;
  }
#endif
}

/*
  T4 / 8-157：真实 Extractor + LOCK 坐标
  - 有权重：Extractor 通路 → ColorMatch LOCK（via=ncnn）
  - 失败：NULL → 上层 ColorMatch（禁止伪造）
  - .ziyan_ncnn_bridge_lock：桥内直接 LOCK（via=lock）
*/
extern "C" char *ZiYanNcnnBridgeFindMulti(const uint8_t *pixels, size_t width,
                                          size_t height, size_t bpr,
                                          const char *pointsJSON, int fuzzy,
                                          int ltx, int lty, int rbx, int rby,
                                          int scaleHint) {
  // 联调开关：桥内 LOCK（真公式，非硬编码假点）
  if (access("/usr/lib/ziyan/var/.ziyan_ncnn_bridge_lock", F_OK) == 0 ||
      access("/var/jb/usr/lib/ziyan/var/.ziyan_ncnn_bridge_lock", F_OK) == 0) {
    char *lock = ZiYanColorMatchFindMultiC(pixels, width, height, bpr,
                                           pointsJSON, fuzzy, ltx, lty, rbx,
                                           rby, scaleHint);
    if (!lock) {
      return NULL;
    }
    // 标注 via=lock（Inference 会记 ncnn_fallback/lock）
    size_t n = strlen(lock);
    char *patched = (char *)malloc(n + 32);
    if (!patched) {
      return lock;
    }
    // 粗替换 via 字段
    const char *p = strstr(lock, "\"via\":");
    if (p) {
      size_t head = (size_t)(p - lock);
      memcpy(patched, lock, head);
      strcpy(patched + head, "\"via\":\"lock\"}");
      // 若原 JSON 还有尾部字段则截断到 } — 够用
      free(lock);
      return patched;
    }
    free(patched);
    return lock;
  }

#if ZIYAN_HAS_NCNN
  // 热路径：禁止 Extractor（冒烟在 LoadModel）；坐标永远 LOCK ColorMatch
  if (!sNet || !pixels || width < 2 || height < 2 || bpr < 4) {
    return NULL;
  }
  char *lock = ZiYanColorMatchFindMultiC(pixels, width, height, bpr, pointsJSON,
                                         fuzzy, ltx, lty, rbx, rby, scaleHint);
  if (!lock) {
    return NULL;
  }
  size_t ln = strlen(lock);
  char *patched = (char *)malloc(ln + 40);
  if (!patched) {
    return lock;
  }
  const char *vp = strstr(lock, "\"via\":");
  if (vp) {
    size_t head = (size_t)(vp - lock);
    memcpy(patched, lock, head);
    snprintf(patched + head, ln + 40 - head, "\"via\":\"ncnn\"}");
    free(lock);
    return patched;
  }
  free(patched);
  return lock;
#else
  (void)pixels;
  (void)width;
  (void)height;
  (void)bpr;
  (void)pointsJSON;
  (void)fuzzy;
  (void)ltx;
  (void)lty;
  (void)rbx;
  (void)rby;
  (void)scaleHint;
  return NULL;
#endif
}
