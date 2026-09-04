#import "ZiYanFrameResident.h"
#import "ZiYanFrameKeep.h"
#import "ZiYanPaths.h"
#import <dispatch/dispatch.h>
#import <math.h>
#import <pthread.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>

/*
 * 174/204：自有常驻帧（仿触动 createScreenIOSurface，不链 TS）
 * - 双槽定容复用：renew 写 inactive → 原子切换；同几何不 malloc/free
 * - 两槽像素总预算 ≤6MB；超预算则整数下采样（文件 shm 仍可全尺寸中继）
 * - 禁 sticky 系统合成层；本槽为 ZiYan 自有 heap
 */

static ZiYanFrameShmHeader sHdr[2];
static NSMutableData *sBuf[2] = {nil, nil}; // 整槽：header64 + pixels
static atomic_int sActive = 0;              // 0/1 可读面
static BOOL sReady = NO;
static BOOL sPinned = NO; // 178：keepScreen 钉槽，禁 SB renew 覆盖
static uint8_t sResPixFmt = ZiYanFramePixelFormatRGBA8888;

void ZiYanFrameResidentSetWritePixelFormat(uint8_t pixelFormat) {
  sResPixFmt = (pixelFormat == ZiYanFramePixelFormatBGRA8888)
                   ? ZiYanFramePixelFormatBGRA8888
                   : ZiYanFramePixelFormatRGBA8888;
}
// C-65.11-65：Resident 是一个跨三线程数据结构（ServeLoop、
// 1ms color_offload、embed Lua）。旧版只原子切 active 索引，却对
// NSMutableData 的 retain/setLength/nil 完全无锁，真机稳定崩在
// libobjc!objc_retain+16。writer 只复用无读者的 inactive 槽；MapRead
// 返回读票，调用方释放后才允许复用/清槽。不拷贝整帧。
// Theos iPhoneOS SDK 的 PTHREAD_*_INITIALIZER 会展开为未导出的
// _PTHREAD_*_SIG_init，不能用静态初始化器。用零值 dispatch_once
// 在首次访问前创建 mutex/cond，同时保证多线程首次进入安全。
static pthread_mutex_t sResidentMu;
static pthread_cond_t sResidentCv;
static dispatch_once_t sResidentSyncOnce;
static void ZFR_EnsureSync(void) {
  dispatch_once(&sResidentSyncOnce, ^{
    pthread_mutex_init(&sResidentMu, NULL);
    pthread_cond_init(&sResidentCv, NULL);
  });
}
static unsigned sReaders[2] = {0, 0};
static atomic_uint sOutstandingTickets = 0;
static atomic_ullong sTicketMapCount = 0;
static atomic_ullong sTicketUnmapCount = 0;
static atomic_ullong sWriterWaitCount = 0;
// token 不能只表示槽号：重复/延迟 Unmap 会误减同槽的其他
// 读者，随后 writer 就可能在真实读者仍扫描时复用缓冲。
// 使用固定票表（热路径无 malloc/free），token 编码票表索引+
// 40-bit generation。目标为 arm64，整个 token 不超过 47 bit，仅作
// void * 往返传递，从不解引用。
enum {
  ZFR_TICKET_CAP = 64,
  ZFR_TICKET_INDEX_BITS = 7,
  ZFR_TICKET_INDEX_MASK = (1u << ZFR_TICKET_INDEX_BITS) - 1u,
};
static const uint64_t ZFR_TICKET_GENERATION_MASK = 0xffffffffffULL;
typedef struct {
  uint64_t generation;
  uint8_t slot;
  BOOL active;
} ZFRReadTicket;
static ZFRReadTicket sTickets[ZFR_TICKET_CAP];
static uint64_t sNextTicketGeneration = 0;
static atomic_ullong sInvalidTicketUnmapCount = 0;
static atomic_ullong sTicketExhaustCount = 0;
enum {
  ZFR_MAX_WORKSET = 6u * 1024u * 1024u,
  ZFR_SLOT_BUDGET = ZFR_MAX_WORKSET / 2u,
};

static void *ZFR_MakeTicketToken(unsigned index, uint64_t generation) {
  uintptr_t raw = ((uintptr_t)generation << ZFR_TICKET_INDEX_BITS) |
                  (uintptr_t)(index + 1u);
  return (void *)raw;
}

static BOOL ZFR_DecodeTicketToken(void *token, unsigned *outIndex,
                                  uint64_t *outGeneration) {
  uintptr_t raw = (uintptr_t)token;
  unsigned encodedIndex = (unsigned)(raw & ZFR_TICKET_INDEX_MASK);
  uint64_t generation = (uint64_t)(raw >> ZFR_TICKET_INDEX_BITS);
  if (encodedIndex < 1u || encodedIndex > ZFR_TICKET_CAP || generation == 0) {
    return NO;
  }
  if (outIndex) {
    *outIndex = encodedIndex - 1u;
  }
  if (outGeneration) {
    *outGeneration = generation;
  }
  return YES;
}

static size_t ZFR_ResidentPayloadBytes(void) {
  size_t total = 0;
  for (int i = 0; i < 2; i++) {
    if (sBuf[i] && sBuf[i].length >= sizeof(ZiYanFrameShmHeader)) {
      total += sBuf[i].length - sizeof(ZiYanFrameShmHeader);
    }
  }
  return total;
}

static void ZFR_WriteDiag(size_t activePayload, uint32_t seq, uint32_t w,
                          uint32_t h, int scale) {
  size_t residentBytes = ZFR_ResidentPayloadBytes();
  int overBudget = residentBytes > ZFR_MAX_WORKSET ? 1 : 0;
  NSString *path = ZiYanVarFile(@".ziyan_resident_bytes");
  NSString *body = [NSString
      stringWithFormat:
          @"%zu via=heap_double active=%zu budget=%u over=%d scale=%d seq=%u "
          @"%ux%u readers=%u tickets=%u maps=%llu unmaps=%llu writer_waits=%llu "
          @"invalid_unmaps=%llu ticket_exhausts=%llu\n",
          residentBytes, activePayload, (unsigned)ZFR_MAX_WORKSET, overBudget,
          scale, seq, w, h, sReaders[0] + sReaders[1],
          atomic_load(&sOutstandingTickets),
          (unsigned long long)atomic_load(&sTicketMapCount),
          (unsigned long long)atomic_load(&sTicketUnmapCount),
          (unsigned long long)atomic_load(&sWriterWaitCount),
          (unsigned long long)atomic_load(&sInvalidTicketUnmapCount),
          (unsigned long long)atomic_load(&sTicketExhaustCount)];
  [body writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
  ZiYanWriteVarText(
      @".ziyan_workset_bytes",
      [NSString stringWithFormat:@"%zu active=%zu over=%d scale=%d %ux%u\n",
                                 residentBytes, activePayload, overBudget, scale,
                                 w, h]);
}

static void ZFR_FillHdr(ZiYanFrameShmHeader *hdr, size_t width, size_t height,
                        size_t bpr, uint8_t provider, uint8_t orient,
                        uint32_t frontHash, uint8_t status, uint32_t seq,
                        uint64_t ts_ms) {
  memset(hdr, 0, sizeof(*hdr));
  hdr->magic[0] = 'Z';
  hdr->magic[1] = 'Y';
  hdr->magic[2] = 'F';
  hdr->magic[3] = 'R';
  hdr->version = 2;
  hdr->width = (uint32_t)width;
  hdr->height = (uint32_t)height;
  hdr->bpr = (uint32_t)bpr;
  hdr->payload = (uint64_t)(bpr * height);
  hdr->seq = seq;
  hdr->ts_ms = ts_ms;
  hdr->pixel_format = sResPixFmt;
  sResPixFmt = ZiYanFramePixelFormatRGBA8888;
  hdr->orient = orient;
  hdr->provider = provider;
  hdr->status = status;
  hdr->front_hash = frontHash;
  hdr->released_v1 = (status == ZiYanFrameStatusReleased) ? 1 : 0;
  hdr->commit_seq = 2;
}

void ZiYanFrameResidentSetPinned(BOOL pinned) {
  ZFR_EnsureSync();
  pthread_mutex_lock(&sResidentMu);
  sPinned = pinned;
  pthread_mutex_unlock(&sResidentMu);
  NSString *path = ZiYanVarFile(@".ziyan_resident_pin");
  if (pinned) {
    [@"1\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding
                  error:nil];
  } else {
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
  }
}

BOOL ZiYanFrameResidentIsPinned(void) {
  ZFR_EnsureSync();
  pthread_mutex_lock(&sResidentMu);
  BOOL pinned = sPinned;
  pthread_mutex_unlock(&sResidentMu);
  return pinned;
}

BOOL ZiYanFrameResidentRenew(const void *pixels, size_t width, size_t height,
                             size_t bpr, uint8_t provider, uint8_t orient,
                             uint32_t frontHash, uint8_t status, uint32_t seq,
                             uint64_t ts_ms) {
  ZFR_EnsureSync();
  if (!pixels || width < 2 || height < 2 || bpr < width * 4 || seq < 1) {
    return NO;
  }
  size_t payload = bpr * height;
  if (payload == 0 || payload / bpr != height) {
    return NO;
  }
  if (status == ZiYanFrameStatusWriting) {
    status = ZiYanFrameStatusValid;
  }
  pthread_mutex_lock(&sResidentMu);
  // pin 期间拒绝覆盖（触动 keep 后 Home 不换 surface 内容）
  if (sPinned && sReady) {
    pthread_mutex_unlock(&sResidentMu);
    return NO;
  }
  // 204：双槽总预算 ≤6MB；单槽按 3MB 选整数缩放。
  // 直接写 inactive 槽，禁每次 renew 另建 2~3MB scaled 临时缓冲。
  int scale = 1;
  size_t srcW = width, srcH = height;
  size_t srcBpr = bpr;
  const uint8_t *srcPix = (const uint8_t *)pixels;
  if (payload > ZFR_SLOT_BUDGET) {
    double ratio = (double)payload / (double)ZFR_SLOT_BUDGET;
    scale = (int)ceil(sqrt(ratio));
    if (scale < 2) {
      scale = 2;
    }
    if (scale > 8) {
      scale = 8;
    }
    size_t dw = width / (size_t)scale;
    size_t dh = height / (size_t)scale;
    if (dw < 2) {
      dw = 2;
    }
    if (dh < 2) {
      dh = 2;
    }
    size_t dbpr = dw * 4;
    size_t dpay = dbpr * dh;
    width = dw;
    height = dh;
    bpr = dbpr;
    payload = dpay;
    status = ZiYanFrameStatusDownsampled;
  }
  if (payload > ZFR_SLOT_BUDGET) {
    pthread_mutex_unlock(&sResidentMu);
    return NO;
  }
  size_t total = sizeof(ZiYanFrameShmHeader) + payload;
  int cur = atomic_load(&sActive);
  int wr = 1 - (cur & 1);

  // inactive 槽可能仍被上一轮找色持有。等读票释放后再
  // setLength/改 bytes，否则是稳定的 use-after-realloc。
  if (sReaders[wr] > 0) {
    atomic_fetch_add(&sWriterWaitCount, 1);
  }
  while (sReaders[wr] > 0) {
    pthread_cond_wait(&sResidentCv, &sResidentMu);
  }

  if (!sBuf[wr]) {
    sBuf[wr] = [[NSMutableData alloc] initWithLength:total];
  } else if (sBuf[wr].length != total) {
    [sBuf[wr] setLength:total];
  }
  if (sBuf[wr].length < total) {
    pthread_mutex_unlock(&sResidentMu);
    return NO;
  }

  ZiYanFrameShmHeader tmp;
  ZFR_FillHdr(&tmp, width, height, bpr, provider, orient, frontHash, status, seq,
              ts_ms);
  // flags 低 8 位存 scale（1=原尺寸）
  tmp.flags = (uint32_t)((tmp.flags & ~0xffu) | (uint32_t)(scale & 0xff));
  uint8_t *base = (uint8_t *)sBuf[wr].mutableBytes;
  memcpy(base, &tmp, sizeof(tmp));
  uint8_t *dst = base + sizeof(ZiYanFrameShmHeader);
  if (scale == 1) {
    memcpy(dst, srcPix, payload);
  } else {
    for (size_t y = 0; y < height; y++) {
      const uint8_t *srow = srcPix + (y * (size_t)scale) * srcBpr;
      uint8_t *drow = dst + y * bpr;
      for (size_t x = 0; x < width; x++) {
        const uint8_t *sp = srow + (x * (size_t)scale) * 4;
        uint8_t *dp = drow + x * 4;
        dp[0] = sp[0];
        dp[1] = sp[1];
        dp[2] = sp[2];
        dp[3] = sp[3];
      }
    }
  }
  sHdr[wr] = tmp;

  atomic_store(&sActive, wr);
  sReady = YES;
  ZFR_WriteDiag(payload, seq, (uint32_t)width, (uint32_t)height, scale);
  // 工作集元数据：脚本逻辑坐标 = workset * scale（native）
  NSString *meta = [NSString
      stringWithFormat:
          @"scale=%d\nnative_w=%zu\nnative_h=%zu\nwork_w=%zu\nwork_h=%zu\n"
          @"payload=%zu\nseq=%u\n",
          scale, srcW, srcH, width, height, payload, seq];
  ZiYanWriteVarText(@".ziyan_workset_meta", meta);
  pthread_mutex_unlock(&sResidentMu);
  return YES;
}

void ZiYanFrameResidentMarkStatus(uint8_t status, BOOL touchTs) {
  ZFR_EnsureSync();
  pthread_mutex_lock(&sResidentMu);
  if (!sReady) {
    pthread_mutex_unlock(&sResidentMu);
    return;
  }
  // 178：pin/热常驻时禁把 Valid 槽打成 Released/Stale（文件 shm 可脏，find 仍读本槽）
  if (sPinned && (status == ZiYanFrameStatusReleased ||
                  status == ZiYanFrameStatusStale)) {
    pthread_mutex_unlock(&sResidentMu);
    return;
  }
  int cur = atomic_load(&sActive) & 1;
  if (sReaders[cur] > 0) {
    atomic_fetch_add(&sWriterWaitCount, 1);
  }
  while (sReaders[cur] > 0) {
    pthread_cond_wait(&sResidentCv, &sResidentMu);
  }
  sHdr[cur].status = status;
  sHdr[cur].released_v1 = (status == ZiYanFrameStatusReleased) ? 1 : 0;
  if (touchTs) {
    sHdr[cur].ts_ms =
        (uint64_t)(NSDate.date.timeIntervalSince1970 * 1000.0);
  }
  if (sBuf[cur] && sBuf[cur].length >= sizeof(ZiYanFrameShmHeader)) {
    memcpy(sBuf[cur].mutableBytes, &sHdr[cur], sizeof(ZiYanFrameShmHeader));
  }
  pthread_mutex_unlock(&sResidentMu);
}

void ZiYanFrameResidentClear(void) {
  ZFR_EnsureSync();
  pthread_mutex_lock(&sResidentMu);
  // 178：pin 时禁清槽（对标触动 keepScreen 不拆 surface）
  if (sPinned) {
    pthread_mutex_unlock(&sResidentMu);
    return;
  }
  if (sReaders[0] > 0 || sReaders[1] > 0) {
    atomic_fetch_add(&sWriterWaitCount, 1);
  }
  while (sReaders[0] > 0 || sReaders[1] > 0) {
    pthread_cond_wait(&sResidentCv, &sResidentMu);
  }
  sReady = NO;
  atomic_store(&sActive, 0);
  memset(&sHdr[0], 0, sizeof(sHdr));
  sBuf[0] = nil;
  sBuf[1] = nil;
  pthread_mutex_unlock(&sResidentMu);
  NSString *path = ZiYanVarFile(@".ziyan_resident_bytes");
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

BOOL ZiYanFrameResidentMapRead(
    const ZiYanFrameShmHeader *_Nullable *_Nonnull outHdr,
    const uint8_t *_Nullable *_Nonnull outPixels, size_t *_Nonnull outMapLen,
    void *_Nullable *_Nonnull outMap) {
  ZFR_EnsureSync();
  *outHdr = NULL;
  *outPixels = NULL;
  *outMapLen = 0;
  *outMap = NULL;
  pthread_mutex_lock(&sResidentMu);
  if (!sReady) {
    pthread_mutex_unlock(&sResidentMu);
    return NO;
  }
  int cur = atomic_load(&sActive) & 1;
  if (sHdr[cur].width < 2 || (sHdr[cur].commit_seq & 1u) ||
      sHdr[cur].status == ZiYanFrameStatusWriting ||
      sHdr[cur].status == ZiYanFrameStatusReleased ||
      sHdr[cur].status == ZiYanFrameStatusStale) {
    pthread_mutex_unlock(&sResidentMu);
    return NO;
  }
  if (!sBuf[cur] ||
      sBuf[cur].length <
          sizeof(ZiYanFrameShmHeader) + (size_t)sHdr[cur].payload) {
    pthread_mutex_unlock(&sResidentMu);
    return NO;
  }
  int ticketIndex = -1;
  for (unsigned i = 0; i < ZFR_TICKET_CAP; i++) {
    if (!sTickets[i].active) {
      ticketIndex = (int)i;
      break;
    }
  }
  if (ticketIndex < 0) {
    atomic_fetch_add(&sTicketExhaustCount, 1);
    pthread_mutex_unlock(&sResidentMu);
    return NO;
  }
  sNextTicketGeneration =
      (sNextTicketGeneration + 1u) & ZFR_TICKET_GENERATION_MASK;
  if (sNextTicketGeneration == 0) {
    sNextTicketGeneration = 1;
  }
  sTickets[ticketIndex].generation = sNextTicketGeneration;
  sTickets[ticketIndex].slot = (uint8_t)cur;
  sTickets[ticketIndex].active = YES;
  sReaders[cur]++;
  atomic_fetch_add(&sOutstandingTickets, 1);
  atomic_fetch_add(&sTicketMapCount, 1);
  *outHdr = (const ZiYanFrameShmHeader *)sBuf[cur].bytes;
  *outPixels =
      (const uint8_t *)sBuf[cur].bytes + sizeof(ZiYanFrameShmHeader);
  *outMapLen = 0;
  *outMap = ZFR_MakeTicketToken((unsigned)ticketIndex,
                                sNextTicketGeneration);
  pthread_mutex_unlock(&sResidentMu);
  return YES;
}

void ZiYanFrameResidentUnmap(void *token, size_t mapLen) {
  ZFR_EnsureSync();
  (void)mapLen;
  unsigned ticketIndex = 0;
  uint64_t generation = 0;
  if (!ZFR_DecodeTicketToken(token, &ticketIndex, &generation)) {
    atomic_fetch_add(&sInvalidTicketUnmapCount, 1);
    return;
  }
  pthread_mutex_lock(&sResidentMu);
  ZFRReadTicket *ticket = &sTickets[ticketIndex];
  if (!ticket->active || ticket->generation != generation || ticket->slot > 1 ||
      sReaders[ticket->slot] == 0) {
    atomic_fetch_add(&sInvalidTicketUnmapCount, 1);
    pthread_mutex_unlock(&sResidentMu);
    return;
  }
  int slot = ticket->slot;
  ticket->active = NO;
  ticket->generation = 0;
  ticket->slot = 0;
  sReaders[slot]--;
  atomic_fetch_sub(&sOutstandingTickets, 1);
  atomic_fetch_add(&sTicketUnmapCount, 1);
  if (sReaders[slot] == 0) {
    pthread_cond_broadcast(&sResidentCv);
  }
  pthread_mutex_unlock(&sResidentMu);
}

uint32_t ZiYanFrameResidentOutstandingTickets(void) {
  return atomic_load(&sOutstandingTickets);
}

uint64_t ZiYanFrameResidentTicketMapCount(void) {
  return (uint64_t)atomic_load(&sTicketMapCount);
}

uint64_t ZiYanFrameResidentTicketUnmapCount(void) {
  return (uint64_t)atomic_load(&sTicketUnmapCount);
}

uint64_t ZiYanFrameResidentWriterWaitCount(void) {
  return (uint64_t)atomic_load(&sWriterWaitCount);
}

uint64_t ZiYanFrameResidentInvalidTicketUnmapCount(void) {
  return (uint64_t)atomic_load(&sInvalidTicketUnmapCount);
}

uint64_t ZiYanFrameResidentTicketExhaustCount(void) {
  return (uint64_t)atomic_load(&sTicketExhaustCount);
}

uint32_t ZiYanFrameResidentPeekSeq(void) {
  ZFR_EnsureSync();
  pthread_mutex_lock(&sResidentMu);
  if (!sReady) {
    pthread_mutex_unlock(&sResidentMu);
    return 0;
  }
  int cur = atomic_load(&sActive) & 1;
  if ((sHdr[cur].commit_seq & 1u) || sHdr[cur].seq < 1) {
    pthread_mutex_unlock(&sResidentMu);
    return 0;
  }
  uint32_t seq = sHdr[cur].seq;
  pthread_mutex_unlock(&sResidentMu);
  return seq;
}

BOOL ZiYanFrameResidentHasPixels(size_t *outW, size_t *outH, size_t *outBPR) {
  ZFR_EnsureSync();
  pthread_mutex_lock(&sResidentMu);
  if (!sReady) {
    pthread_mutex_unlock(&sResidentMu);
    return NO;
  }
  int cur = atomic_load(&sActive) & 1;
  if (sHdr[cur].width < 2 || sHdr[cur].height < 2 ||
      sHdr[cur].status == ZiYanFrameStatusReleased) {
    pthread_mutex_unlock(&sResidentMu);
    return NO;
  }
  if (outW)
    *outW = sHdr[cur].width;
  if (outH)
    *outH = sHdr[cur].height;
  if (outBPR)
    *outBPR = sHdr[cur].bpr;
  pthread_mutex_unlock(&sResidentMu);
  return YES;
}

uint8_t ZiYanFrameResidentPeekStatus(void) {
  ZFR_EnsureSync();
  pthread_mutex_lock(&sResidentMu);
  if (!sReady) {
    pthread_mutex_unlock(&sResidentMu);
    return ZiYanFrameStatusStale;
  }
  int cur = atomic_load(&sActive) & 1;
  uint8_t status = sHdr[cur].status;
  pthread_mutex_unlock(&sResidentMu);
  return status;
}

uint8_t ZiYanFrameResidentPeekPixelFormat(void) {
  ZFR_EnsureSync();
  pthread_mutex_lock(&sResidentMu);
  if (!sReady) {
    pthread_mutex_unlock(&sResidentMu);
    return ZiYanFramePixelFormatRGBA8888;
  }
  int cur = atomic_load(&sActive) & 1;
  uint8_t fmt = sHdr[cur].pixel_format;
  pthread_mutex_unlock(&sResidentMu);
  return fmt;
}

uint64_t ZiYanFrameResidentPeekTsMs(void) {
  ZFR_EnsureSync();
  pthread_mutex_lock(&sResidentMu);
  if (!sReady) {
    pthread_mutex_unlock(&sResidentMu);
    return 0;
  }
  int cur = atomic_load(&sActive) & 1;
  uint64_t ts = sHdr[cur].ts_ms;
  pthread_mutex_unlock(&sResidentMu);
  return ts;
}

BOOL ZiYanFrameResidentIsReleased(void) {
  ZFR_EnsureSync();
  pthread_mutex_lock(&sResidentMu);
  if (!sReady) {
    pthread_mutex_unlock(&sResidentMu);
    return NO;
  }
  int cur = atomic_load(&sActive) & 1;
  BOOL released = sHdr[cur].released_v1 ||
                  sHdr[cur].status == ZiYanFrameStatusReleased;
  pthread_mutex_unlock(&sResidentMu);
  return released;
}

size_t ZiYanFrameResidentPayloadBytes(void) {
  ZFR_EnsureSync();
  pthread_mutex_lock(&sResidentMu);
  if (!sReady) {
    pthread_mutex_unlock(&sResidentMu);
    return 0;
  }
  int cur = atomic_load(&sActive) & 1;
  size_t payload = (size_t)sHdr[cur].payload;
  pthread_mutex_unlock(&sResidentMu);
  return payload;
}

static void ZFR_HookRenew(const void *pixels, size_t width, size_t height,
                          size_t bpr, uint8_t provider, uint8_t orient,
                          uint32_t frontHash, uint8_t status, uint32_t seq,
                          uint64_t ts_ms) {
  (void)ZiYanFrameResidentRenew(pixels, width, height, bpr, provider, orient,
                                frontHash, status, seq, ts_ms);
}

static void ZFR_HookMark(uint8_t status, BOOL touchTs) {
  ZiYanFrameResidentMarkStatus(status, touchTs);
}

static void ZFR_HookClear(void) { ZiYanFrameResidentClear(); }

void ZiYanFrameResidentRegisterHooks(void) {
  ZFR_EnsureSync();
  ZiYanFrameResidentHooks hooks = {
      .renew = ZFR_HookRenew,
      .markStatus = ZFR_HookMark,
      .clear = ZFR_HookClear,
  };
  ZiYanFrameShmSetResidentHooks(&hooks);
  // 178：serve 重启恢复 pin（Home keep App 表面跨 framecap 拉起）
  if (access(ZiYanVarFile(@".ziyan_resident_pin").fileSystemRepresentation,
             F_OK) == 0) {
    pthread_mutex_lock(&sResidentMu);
    sPinned = YES;
    pthread_mutex_unlock(&sResidentMu);
  }
}

BOOL ZiYanFrameResidentMirrorFromShm(void) {
  const ZiYanFrameShmHeader *hdr = NULL;
  const uint8_t *pix = NULL;
  size_t mapLen = 0;
  void *map = NULL;
  if (!ZiYanFrameShmMapRead(&hdr, &pix, &mapLen, &map) || !hdr || !pix) {
    return NO;
  }
  uint32_t local = ZiYanFrameResidentPeekSeq();
  if (local == hdr->seq && local > 0) {
    ZiYanFrameShmUnmap(map, mapLen);
    return YES; // 已对齐
  }
  BOOL ok = ZiYanFrameResidentRenew(
      pix, hdr->width, hdr->height, hdr->bpr, hdr->provider, hdr->orient,
      hdr->front_hash, hdr->status, hdr->seq, hdr->ts_ms);
  ZiYanFrameShmUnmap(map, mapLen);
  return ok;
}

NSString *ZiYanFrameStatusName(uint8_t status) {
  switch (status) {
  case ZiYanFrameStatusValid:
    return @"valid";
  case ZiYanFrameStatusStale:
    return @"stale";
  case ZiYanFrameStatusReleased:
    return @"released";
  case ZiYanFrameStatusLockedBlack:
    return @"locked_black";
  case ZiYanFrameStatusSuspectBlack:
    return @"suspect_black";
  case ZiYanFrameStatusDownsampled:
    return @"downsampled";
  case ZiYanFrameStatusWriting:
    return @"writing";
  default:
    return @"unknown";
  }
}

NSString *ZiYanFramePixelFormatName(uint8_t fmt) {
  if (fmt == ZiYanFramePixelFormatBGRA8888) {
    return @"BGRA8888";
  }
  return @"RGBA8888";
}

static uint8_t ZFR_ParsePixelFormatToken(NSString *raw) {
  if (raw.length < 1) {
    return 0xFF;
  }
  NSString *s = raw.uppercaseString;
  if ([s isEqualToString:@"0"] || [s isEqualToString:@"BGRA"] ||
      [s isEqualToString:@"BGRA8888"]) {
    return ZiYanFramePixelFormatBGRA8888;
  }
  if ([s isEqualToString:@"1"] || [s isEqualToString:@"RGBA"] ||
      [s isEqualToString:@"RGBA8888"]) {
    return ZiYanFramePixelFormatRGBA8888;
  }
  return 0xFF;
}

void ZiYanCanonicalFrameTokenFill(ZiYanCanonicalFrameToken *tok,
                                  const ZiYanFrameShmHeader *hdr,
                                  uint32_t generation, NSString *frontBid,
                                  const char *source) {
  if (!tok) {
    return;
  }
  memset(tok, 0, sizeof(*tok));
  tok->generation = generation;
  if (hdr) {
    tok->frame_seq = hdr->seq;
    tok->front_hash = hdr->front_hash;
    tok->pixel_format = (hdr->version >= 2)
                            ? hdr->pixel_format
                            : ZiYanFramePixelFormatRGBA8888;
    tok->width = hdr->width;
    tok->height = hdr->height;
    tok->bpr = hdr->bpr;
    tok->capture_ts_ms = hdr->ts_ms;
    tok->status = hdr->status;
  }
  NSString *bid = [frontBid
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]];
  if (bid.length > 0 && ![bid isEqualToString:@"-"] &&
      ![bid.lowercaseString isEqualToString:@"stale"]) {
    strncpy(tok->front_bid, bid.UTF8String, sizeof(tok->front_bid) - 1);
  }
  const char *src = (source && source[0]) ? source : "none";
  strncpy(tok->source, src, sizeof(tok->source) - 1);
  NSString *stName = hdr ? ZiYanFrameStatusName(tok->status) : @"unavailable";
  strncpy(tok->frame_status, stName.UTF8String,
          sizeof(tok->frame_status) - 1);
  NSString *fmtName = ZiYanFramePixelFormatName(tok->pixel_format);
  strncpy(tok->pixel_format_name, fmtName.UTF8String,
          sizeof(tok->pixel_format_name) - 1);
  if (!hdr) {
    strncpy(tok->source, "none", sizeof(tok->source) - 1);
    strncpy(tok->frame_status, "unavailable", sizeof(tok->frame_status) - 1);
  }
}

static void ZFR_TokenUnavailable(ZiYanCanonicalFrameToken *tok,
                                 const char *source) {
  if (!tok) return;
  memset(tok, 0, sizeof(*tok));
  strncpy(tok->source, source && source[0] ? source : "none",
          sizeof(tok->source) - 1);
  strncpy(tok->frame_status, "unavailable", sizeof(tok->frame_status) - 1);
}

BOOL ZiYanCanonicalFrameTokenFillCommitted(ZiYanCanonicalFrameToken *tok,
                                           const ZiYanFrameShmHeader *hdr,
                                           const char *source) {
  if (!tok || !hdr || hdr->seq < 1 || (hdr->commit_seq & 1u) ||
      hdr->status == ZiYanFrameStatusWriting) {
    ZFR_TokenUnavailable(tok, source);
    return NO;
  }
  uint32_t frontGen = ZiYanFrameKeepReadFrontGeneration();
  uint32_t capturedGen = ZiYanFrameKeepReadCapturedGeneration();
  NSString *captured = ZiYanFrameKeepReadCapturedFront();
  NSString *front = ZiYanFrameKeepReadFrontBid();
  if (frontGen == 0 || capturedGen == 0 || frontGen != capturedGen ||
      captured.length < 1 || front.length < 1 || ![captured isEqualToString:front] ||
      hdr->front_hash == 0 ||
      hdr->front_hash != ZiYanFrameShmHashFrontBid(captured)) {
    ZFR_TokenUnavailable(tok, source);
    return NO;
  }
  ZiYanCanonicalFrameTokenFill(tok, hdr, capturedGen, captured, source);
  snprintf(tok->publish_token, sizeof(tok->publish_token),
           "g%u-s%u-h%08x-t%llu", tok->generation, tok->frame_seq,
           tok->front_hash, (unsigned long long)tok->capture_ts_ms);
  return YES;
}

BOOL ZiYanCanonicalCurrentFrameMapRead(
    BOOL allowFileShm, const ZiYanFrameShmHeader **outHdr,
    const uint8_t **outPixels, size_t *outMapLen, void **outMap,
    BOOL *outResident) {
  if (outHdr) {
    *outHdr = NULL;
  }
  if (outPixels) {
    *outPixels = NULL;
  }
  if (outMapLen) {
    *outMapLen = 0;
  }
  if (outMap) {
    *outMap = NULL;
  }
  if (outResident) {
    *outResident = NO;
  }
  if (ZiYanFrameResidentHasPixels(NULL, NULL, NULL) &&
      ZiYanFrameResidentMapRead(outHdr, outPixels, outMapLen, outMap) &&
      outHdr && *outHdr && outPixels && *outPixels && outMap) {
    // 新 writer 已提交 SHM 时，旧 resident 不能作为 canonical current-frame。
    // 非 pin 状态下尝试镜像当前 SHM；失败则 fail-closed，杜绝旧帧回放。
    uint32_t residentSeq = (*outHdr)->seq;
    uint32_t shmSeq = ZiYanFrameShmPeekSeq();
    if (!ZiYanFrameResidentIsPinned() && shmSeq > 0 && residentSeq != shmSeq) {
      ZiYanFrameResidentUnmap(*outMap, *outMapLen);
      *outHdr = NULL;
      *outPixels = NULL;
      *outMapLen = 0;
      *outMap = NULL;
      if (!ZiYanFrameResidentMirrorFromShm() ||
          !ZiYanFrameResidentMapRead(outHdr, outPixels, outMapLen, outMap) ||
          !*outHdr || !*outPixels || (*outHdr)->seq != ZiYanFrameShmPeekSeq()) {
        if (*outMap) ZiYanFrameResidentUnmap(*outMap, *outMapLen);
        *outHdr = NULL;
        *outPixels = NULL;
        *outMapLen = 0;
        *outMap = NULL;
        return NO;
      }
    }
    if (outResident) {
      *outResident = YES;
    }
    return YES;
  }
  if (!allowFileShm) {
    return NO;
  }
  if (!ZiYanFrameShmHasPixels(NULL, NULL, NULL)) {
    return NO;
  }
  if (ZiYanFrameShmMapRead(outHdr, outPixels, outMapLen, outMap) && outHdr &&
      *outHdr && outPixels && *outPixels) {
    if (outResident) {
      *outResident = NO;
    }
    return YES;
  }
  return NO;
}

BOOL ZiYanCanonicalFrameTokenReadCommitted(ZiYanCanonicalFrameToken *tok,
                                           BOOL allowFileShm) {
  if (!tok) return NO;
  const ZiYanFrameShmHeader *hdr = NULL;
  const uint8_t *pixels = NULL;
  size_t mapLen = 0;
  void *map = NULL;
  BOOL resident = NO;
  if (!ZiYanCanonicalCurrentFrameMapRead(allowFileShm, &hdr, &pixels, &mapLen,
                                         &map, &resident) ||
      !hdr || !pixels) {
    ZFR_TokenUnavailable(tok, "none");
    return NO;
  }
  ZiYanFrameShmHeader snapshot = *hdr;
  BOOL ok = ZiYanCanonicalFrameTokenFillCommitted(
      tok, &snapshot, resident ? "resident" : "shm");
  ZiYanCanonicalCurrentFrameUnmap(map, mapLen, resident);
  return ok;
}

void ZiYanCanonicalCurrentFrameUnmap(void *map, size_t mapLen,
                                     BOOL resident) {
  if (resident) {
    ZiYanFrameResidentUnmap(map, mapLen);
  } else {
    ZiYanFrameShmUnmap(map, mapLen);
  }
}

BOOL ZiYanCanonicalFrameTokenMatchesRequest(
    const ZiYanCanonicalFrameToken *cur, NSString *frameSeq,
    NSString *generation, NSString *frontBid, NSString *pixelFormat) {
  if (!cur) {
    return NO;
  }
  NSString *seqS = [frameSeq
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]];
  NSString *genS = [generation
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]];
  NSString *bidS = [frontBid
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]];
  NSString *fmtS = [pixelFormat
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]];
  if (seqS.length > 0) {
    uint32_t want = (uint32_t)strtoul(seqS.UTF8String, NULL, 10);
    if (want != cur->frame_seq) {
      return NO;
    }
  }
  if (genS.length > 0) {
    uint32_t want = (uint32_t)strtoul(genS.UTF8String, NULL, 10);
    if (want != cur->generation) {
      return NO;
    }
  }
  if (bidS.length > 0) {
    if (![bidS isEqualToString:@(cur->front_bid)]) {
      return NO;
    }
  }
  if (fmtS.length > 0) {
    uint8_t want = ZFR_ParsePixelFormatToken(fmtS);
    if (want == 0xFF || want != cur->pixel_format) {
      return NO;
    }
  }
  return YES;
}

NSDictionary *ZiYanCanonicalFrameTokenDictionary(
    const ZiYanCanonicalFrameToken *tok) {
  if (!tok) {
    return @{
      @"front_bid" : @"",
      @"frame_seq" : @0,
      @"generation" : @0,
      @"front_hash" : @0,
      @"publish_token" : @"",
      @"pixel_format" : @"",
      @"width" : @0,
      @"height" : @0,
      @"bpr" : @0,
      @"capture_ts_ms" : @0,
      @"source" : @"none",
      @"frame_status" : @"unavailable"
    };
  }
  return @{
    @"front_bid" : @(tok->front_bid),
    @"frame_seq" : @(tok->frame_seq),
    @"generation" : @(tok->generation),
    @"front_hash" : @(tok->front_hash),
    @"publish_token" : @(tok->publish_token),
    @"pixel_format" : @(tok->pixel_format_name),
    @"width" : @(tok->width),
    @"height" : @(tok->height),
    @"bpr" : @(tok->bpr),
    @"capture_ts_ms" : @((unsigned long long)tok->capture_ts_ms),
    @"source" : @(tok->source),
    @"frame_status" : @(tok->frame_status)
  };
}

NSString *ZiYanCanonicalFrameJSONByAddingToken(
    NSString *json, const ZiYanCanonicalFrameToken *tok) {
  NSMutableDictionary *md = nil;
  if (json.length > 1) {
    NSData *jd = [json dataUsingEncoding:NSUTF8StringEncoding];
    id obj =
        jd ? [NSJSONSerialization JSONObjectWithData:jd options:0 error:nil]
           : nil;
    if ([obj isKindOfClass:[NSDictionary class]]) {
      md = [obj mutableCopy];
    }
  }
  if (!md) {
    md = [NSMutableDictionary dictionary];
    md[@"ok"] = @NO;
    md[@"x"] = @(-1);
    md[@"y"] = @(-1);
  }
  [md addEntriesFromDictionary:ZiYanCanonicalFrameTokenDictionary(tok)];
  NSData *out =
      [NSJSONSerialization dataWithJSONObject:md options:0 error:nil];
  if (!out) {
    return json.length ? json
                       : @"{\"ok\":false,\"x\":-1,\"y\":-1,\"err\":\"json\"}";
  }
  return [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding];
}

void ZiYanCanonicalFrameTokenWriteLast(const ZiYanCanonicalFrameToken *tok) {
  NSDictionary *d = ZiYanCanonicalFrameTokenDictionary(tok);
  NSData *jd = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
  if (!jd) {
    return;
  }
  NSString *path = ZiYanVarFile(@".ziyan_last_frame_token");
  [jd writeToFile:path atomically:YES];
}
