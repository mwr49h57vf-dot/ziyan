#import "ZiYanFrameShm.h"
#import <fcntl.h>
#import <stdio.h>
#import <string.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <unistd.h>

/*
 * 阶段2：共享帧唯一真相
 * - header 仍 64B；version=2 启用 commit_seq / provider / status
 * - 写：先标 writing(奇数 commit) → memcpy 像素 → 偶数 commit + seq 提交
 * - 读：commit 偶数且前后一致，禁半帧
 * - 同几何复用 inode；几何变才 tmp+rename
 * 内存风险：禁逐帧 unlink 风暴；Clear 仍用 rename 避 SIGBUS
 */

static uint32_t sShmSeq = 1;
static NSString *sPathOverride = nil;
static ZiYanFrameResidentHooks sResidentHooks;

void ZiYanFrameShmSetPathOverrideForTest(NSString *path) {
  sPathOverride = [path copy];
}

void ZiYanFrameShmSetResidentHooks(const ZiYanFrameResidentHooks *hooks) {
  if (hooks) {
    sResidentHooks = *hooks;
  } else {
    memset(&sResidentHooks, 0, sizeof(sResidentHooks));
  }
}

static void ZFS_ResidentRenew(const void *pixels, size_t width, size_t height,
                              size_t bpr, uint8_t provider, uint8_t orient,
                              uint32_t frontHash, uint8_t status, uint32_t seq,
                              uint64_t ts_ms) {
  if (sResidentHooks.renew) {
    sResidentHooks.renew(pixels, width, height, bpr, provider, orient, frontHash,
                         status, seq, ts_ms);
  }
}

static void ZFS_ResidentMark(uint8_t status, BOOL touchTs) {
  if (sResidentHooks.markStatus) {
    sResidentHooks.markStatus(status, touchTs);
  }
}

static void ZFS_ResidentClear(void) {
  if (sResidentHooks.clear) {
    sResidentHooks.clear();
  }
}

static NSString *ZFS_Path(void) {
  if (sPathOverride.length) {
    return sPathOverride;
  }
  return ZiYanFrameShmPath();
}

uint32_t ZiYanFrameShmHashFrontBid(NSString *bid) {
  if (bid.length < 1) {
    return 0;
  }
  const char *s = bid.UTF8String;
  if (!s) {
    return 0;
  }
  uint32_t h = 2166136261u;
  for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
    h ^= (uint32_t)(*p);
    h *= 16777619u;
  }
  return h ? h : 1u;
}

static BOOL ZFS_MagicOK(const ZiYanFrameShmHeader *hdr) {
  return hdr && hdr->magic[0] == 'Z' && hdr->magic[1] == 'Y' &&
         hdr->magic[2] == 'F' && hdr->magic[3] == 'R';
}

static BOOL ZFS_VersionOK(const ZiYanFrameShmHeader *hdr) {
  return hdr && (hdr->version == 1 || hdr->version == 2);
}

/// 偏移40=released_v1（v1/v2 共用）；v2 另看 status
static BOOL ZFS_IsReleasedHdr(const ZiYanFrameShmHeader *hdr) {
  if (!hdr) {
    return NO;
  }
  if (hdr->released_v1 != 0) {
    return YES;
  }
  if (hdr->version >= 2) {
    return hdr->status == ZiYanFrameStatusReleased ||
           hdr->status == ZiYanFrameStatusWriting;
  }
  return NO;
}

static BOOL ZFS_IsWritingHdr(const ZiYanFrameShmHeader *hdr) {
  if (!hdr || !ZFS_VersionOK(hdr)) {
    return NO;
  }
  if (hdr->version >= 2) {
    return (hdr->commit_seq & 1u) != 0 ||
           hdr->status == ZiYanFrameStatusWriting;
  }
  return NO;
}

static BOOL ZFS_GeomPayloadOK(const ZiYanFrameShmHeader *hdr) {
  if (!hdr || hdr->width < 2 || hdr->height < 2) {
    return NO;
  }
  if (hdr->bpr < hdr->width * 4u) {
    return NO;
  }
  uint64_t expect = (uint64_t)hdr->bpr * (uint64_t)hdr->height;
  return hdr->payload == expect && hdr->payload >= 4;
}

BOOL ZiYanFrameShmEnsureFile(void) {
  ZiYanEnsureVarDirectory();
  NSString *path = ZFS_Path();
  if (!path.length) {
    return NO;
  }
  // 189：清几何切换残留 .ziyan_frame_shm.<pid>.tmp（占盘/脏写）
  {
    NSString *dir = [path stringByDeletingLastPathComponent];
    NSString *base = [path lastPathComponent];
    NSArray *ents =
        [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir
                                                            error:nil];
    for (NSString *e in ents) {
      if ([e hasPrefix:[base stringByAppendingString:@"."]] &&
          [e hasSuffix:@".tmp"]) {
        [[NSFileManager defaultManager]
            removeItemAtPath:[dir stringByAppendingPathComponent:e]
                       error:nil];
      }
    }
  }
  const char *cpath = path.fileSystemRepresentation;
  int fd = open(cpath, O_RDWR | O_CREAT, 0666);
  if (fd < 0) {
    return NO;
  }
  close(fd);
  chmod(cpath, 0666);
  return YES;
}

void ZiYanFrameShmInvalidateForNextFind(void) {
  NSString *path = ZFS_Path();
  if (!path.length) {
    return;
  }
  int fd = open(path.fileSystemRepresentation, O_RDWR);
  if (fd < 0) {
    return;
  }
  ZiYanFrameShmHeader hdr;
  memset(&hdr, 0, sizeof(hdr));
  if (pread(fd, &hdr, sizeof(hdr), 0) != (ssize_t)sizeof(hdr) ||
      !ZFS_MagicOK(&hdr) || !ZFS_VersionOK(&hdr) || hdr.width < 2) {
    close(fd);
    return;
  }
  hdr.released_v1 = 1; // 偏移40：新旧读者都能看到
  if (hdr.version >= 2) {
    hdr.status = ZiYanFrameStatusReleased;
    // 保持 commit 为偶，避免读者误判 writing
    if (hdr.commit_seq & 1u) {
      hdr.commit_seq += 1u;
    }
  }
  (void)pwrite(fd, &hdr, sizeof(hdr), 0);
  close(fd);
  // 178：文件 shm 可标 released；常驻槽由 pin/Valid 策略自管，禁毒化 find 主缓冲
  // （触动：Invalidate 合成路径 ≠ 拆 keepScreen surface）
}

void ZiYanFrameShmMarkStale(void) {
  NSString *path = ZFS_Path();
  if (!path.length) {
    return;
  }
  int fd = open(path.fileSystemRepresentation, O_RDWR);
  if (fd < 0) {
    return;
  }
  ZiYanFrameShmHeader hdr;
  memset(&hdr, 0, sizeof(hdr));
  if (pread(fd, &hdr, sizeof(hdr), 0) != (ssize_t)sizeof(hdr) ||
      !ZFS_MagicOK(&hdr) || !ZFS_VersionOK(&hdr) || hdr.width < 2) {
    close(fd);
    return;
  }
  // 切前台：保留像素与 seq；清 released；标 stale（禁删槽）
  hdr.released_v1 = 0;
  if (hdr.version >= 2) {
    hdr.status = ZiYanFrameStatusStale;
    if (hdr.commit_seq & 1u) {
      hdr.commit_seq += 1u;
    }
  } else {
    // v1 无 status：用 released 表达「勿当热帧」（与旧 Invalidate 行为接近但本 API 名 stale）
    hdr.released_v1 = 1;
  }
  (void)pwrite(fd, &hdr, sizeof(hdr), 0);
  close(fd);
  // 178：stale 只落文件 shm；禁 MarkStatus(Stale) 进常驻（find 主缓冲保持可扫）
}

/// 162：keepScreen 对齐 — 保留像素并标 Valid（min 后小窗阶段仍可扫 App 缓冲）
void ZiYanFrameShmMarkValidKeepPixels(void) {
  NSString *path = ZFS_Path();
  if (!path.length) {
    return;
  }
  int fd = open(path.fileSystemRepresentation, O_RDWR);
  if (fd < 0) {
    return;
  }
  ZiYanFrameShmHeader hdr;
  memset(&hdr, 0, sizeof(hdr));
  if (pread(fd, &hdr, sizeof(hdr), 0) != (ssize_t)sizeof(hdr) ||
      !ZFS_MagicOK(&hdr) || !ZFS_VersionOK(&hdr) || hdr.width < 2) {
    close(fd);
    return;
  }
  hdr.released_v1 = 0;
  if (hdr.version >= 2) {
    hdr.status = ZiYanFrameStatusValid;
    // 刷新时间戳，避免 IsFresh/超龄灌 SB
    hdr.ts_ms = (uint64_t)(NSDate.date.timeIntervalSince1970 * 1000.0);
    if (hdr.commit_seq & 1u) {
      hdr.commit_seq += 1u;
    }
  }
  (void)pwrite(fd, &hdr, sizeof(hdr), 0);
  close(fd);
  ZFS_ResidentMark(ZiYanFrameStatusValid, YES);
}

BOOL ZiYanFrameShmIsReleased(void) {
  NSString *path = ZFS_Path();
  if (!path.length) {
    return NO;
  }
  int fd = open(path.fileSystemRepresentation, O_RDONLY);
  if (fd < 0) {
    return NO;
  }
  ZiYanFrameShmHeader hdr;
  memset(&hdr, 0, sizeof(hdr));
  ssize_t n = pread(fd, &hdr, sizeof(hdr), 0);
  close(fd);
  if (n != (ssize_t)sizeof(hdr) || !ZFS_MagicOK(&hdr) || !ZFS_VersionOK(&hdr) ||
      hdr.width < 2) {
    return NO;
  }
  return ZFS_IsReleasedHdr(&hdr);
}

void ZiYanFrameShmClearReleasedAndTouch(void) {
  NSString *path = ZFS_Path();
  if (!path.length) {
    return;
  }
  int fd = open(path.fileSystemRepresentation, O_RDWR);
  if (fd < 0) {
    return;
  }
  ZiYanFrameShmHeader hdr;
  memset(&hdr, 0, sizeof(hdr));
  if (pread(fd, &hdr, sizeof(hdr), 0) != (ssize_t)sizeof(hdr) ||
      !ZFS_MagicOK(&hdr) || !ZFS_VersionOK(&hdr) || hdr.width < 2) {
    close(fd);
    return;
  }
  hdr.ts_ms = (uint64_t)(NSDate.date.timeIntervalSince1970 * 1000.0);
  hdr.released_v1 = 0;
  if (hdr.version >= 2) {
    if (hdr.status == ZiYanFrameStatusReleased ||
        hdr.status == ZiYanFrameStatusWriting) {
      hdr.status = ZiYanFrameStatusStale; // 软续命：可有像素但标 stale
    }
    if (hdr.commit_seq & 1u) {
      hdr.commit_seq += 1u;
    }
  }
  (void)pwrite(fd, &hdr, sizeof(hdr), 0);
  close(fd);
}

void ZiYanFrameShmClear(void) {
  ZFS_ResidentClear();
  NSString *path = ZFS_Path();
  if (!path.length) {
    return;
  }
  if (!ZiYanFrameShmEnsureFile()) {
    return;
  }
  NSString *tmp = [path
      stringByAppendingString:[NSString stringWithFormat:@".clr.%d.tmp", getpid()]];
  const char *ctmp = tmp.fileSystemRepresentation;
  const char *cpath = path.fileSystemRepresentation;
  int fd = open(ctmp, O_RDWR | O_CREAT | O_TRUNC, 0666);
  if (fd < 0) {
    return;
  }
  close(fd);
  if (rename(ctmp, cpath) != 0) {
    unlink(ctmp);
    return;
  }
  chmod(cpath, 0666);
}

static uint32_t ZFS_NextSeq(uint32_t prev) {
  uint32_t next = prev + 1;
  if (next < 1) {
    next = 1;
  }
  if (sShmSeq > next) {
    next = sShmSeq++;
  } else {
    sShmSeq = next + 1;
  }
  return next;
}

static void ZFS_FillV2Meta(ZiYanFrameShmHeader *hdr, uint8_t provider,
                           uint8_t orient, uint32_t frontHash, uint8_t status) {
  hdr->version = 2;
  // framecap Capture 写的是 R,G,B,A 字节序（已从 IOSurface BGRA 交换）
  hdr->pixel_format = ZiYanFramePixelFormatRGBA8888;
  hdr->orient = orient;
  hdr->provider = provider;
  hdr->status = status;
  hdr->front_hash = frontHash;
  hdr->flags = 0;
  memset(hdr->pad_meta, 0, sizeof(hdr->pad_meta));
  memset(hdr->reserved2, 0, sizeof(hdr->reserved2));
  // 偏移40 与 status 同步，避免旧读者/新读者对 released 分歧
  hdr->released_v1 = (status == ZiYanFrameStatusReleased) ? 1 : 0;
}

BOOL ZiYanFrameShmWriteEx(const void *pixels, size_t width, size_t height,
                          size_t bpr, uint8_t provider, uint8_t orient,
                          uint32_t frontHash, uint8_t status) {
  if (!pixels || width < 2 || height < 2 || bpr < width * 4) {
    return NO;
  }
  size_t payload = bpr * height;
  if (payload == 0 || payload / bpr != height) {
    return NO;
  }
  if (status == ZiYanFrameStatusWriting) {
    status = ZiYanFrameStatusValid;
  }
  if (!ZiYanFrameShmEnsureFile()) {
    return NO;
  }
  NSString *path = ZFS_Path();
  const char *cpath = path.fileSystemRepresentation;
  size_t total = sizeof(ZiYanFrameShmHeader) + payload;

  // 同几何 → 同 inode：writing → pixels → commit
  {
    int fd = open(cpath, O_RDWR);
    if (fd >= 0) {
      struct stat st;
      ZiYanFrameShmHeader oh;
      memset(&oh, 0, sizeof(oh));
      BOOL geomOK = NO;
      if (fstat(fd, &st) == 0 && (size_t)st.st_size == total &&
          pread(fd, &oh, sizeof(oh), 0) == (ssize_t)sizeof(oh) &&
          ZFS_MagicOK(&oh) && ZFS_VersionOK(&oh) &&
          oh.width == (uint32_t)width && oh.height == (uint32_t)height &&
          oh.bpr == (uint32_t)bpr && oh.payload == (uint64_t)payload) {
        geomOK = YES;
      }
      if (geomOK) {
        void *map =
            mmap(NULL, total, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (map != MAP_FAILED) {
          ZiYanFrameShmHeader *hdr = (ZiYanFrameShmHeader *)map;
          // 1) 标 writing（奇数 commit）；seq 暂不递增
          uint32_t c0 = hdr->commit_seq;
          if ((c0 & 1u) == 0) {
            c0 += 1u;
          }
          hdr->commit_seq = c0;
          hdr->status = ZiYanFrameStatusWriting;
          hdr->released_v1 = 0;
          // 189：热路径禁 MS_SYNC（MAP_SHARED 跨进程已可见；SYNC 脏 APFS→diskwrites）
          // 仅对 header 可选 MS_ASYNC，像素靠 commit_seq 奇偶门闩。

          // 2) 像素
          memcpy((uint8_t *)map + sizeof(ZiYanFrameShmHeader), pixels, payload);

          // 3) 原子提交 header
          uint32_t next = ZFS_NextSeq(oh.seq);
          hdr->magic[0] = 'Z';
          hdr->magic[1] = 'Y';
          hdr->magic[2] = 'F';
          hdr->magic[3] = 'R';
          hdr->width = (uint32_t)width;
          hdr->height = (uint32_t)height;
          hdr->bpr = (uint32_t)bpr;
          hdr->payload = (uint64_t)payload;
          hdr->seq = next;
          uint64_t ts =
              (uint64_t)(NSDate.date.timeIntervalSince1970 * 1000.0);
          hdr->ts_ms = ts;
          ZFS_FillV2Meta(hdr, provider, orient, frontHash, status);
          hdr->commit_seq = c0 + 1u; // 变偶
          munmap(map, total);
          close(fd);
          chmod(cpath, 0666);
          // 174：文件镜像提交后，原地 renew 进程内常驻槽（仅 framecap 钩子生效）
          ZFS_ResidentRenew(pixels, width, height, bpr, provider, orient,
                            frontHash, status, next, ts);
          return YES;
        }
      }
      close(fd);
    }
  }

  // 几何变化 / 首帧：tmp 写满再 rename（读者仍见旧 inode）
  NSString *tmp =
      [path stringByAppendingString:[NSString stringWithFormat:@".%d.tmp", getpid()]];
  const char *ctmp = tmp.fileSystemRepresentation;
  int fd = open(ctmp, O_RDWR | O_CREAT | O_TRUNC, 0666);
  if (fd < 0) {
    return NO;
  }
  if (ftruncate(fd, (off_t)total) != 0) {
    close(fd);
    unlink(ctmp);
    return NO;
  }
  void *map = mmap(NULL, total, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (map == MAP_FAILED) {
    close(fd);
    unlink(ctmp);
    return NO;
  }
  ZiYanFrameShmHeader *hdr = (ZiYanFrameShmHeader *)map;
  memset(hdr, 0, sizeof(*hdr));
  hdr->magic[0] = 'Z';
  hdr->magic[1] = 'Y';
  hdr->magic[2] = 'F';
  hdr->magic[3] = 'R';
  hdr->width = (uint32_t)width;
  hdr->height = (uint32_t)height;
  hdr->bpr = (uint32_t)bpr;
  hdr->payload = (uint64_t)payload;
  {
    uint32_t prev = 0;
    int rfd = open(cpath, O_RDONLY);
    if (rfd >= 0) {
      ZiYanFrameShmHeader ph;
      if (pread(rfd, &ph, sizeof(ph), 0) == (ssize_t)sizeof(ph) &&
          ZFS_MagicOK(&ph)) {
        prev = ph.seq;
      }
      close(rfd);
    }
    hdr->seq = ZFS_NextSeq(prev);
  }
  uint64_t ts = (uint64_t)(NSDate.date.timeIntervalSince1970 * 1000.0);
  hdr->ts_ms = ts;
  ZFS_FillV2Meta(hdr, provider, orient, frontHash, status);
  hdr->commit_seq = 2; // 稳定偶
  uint32_t newSeq = hdr->seq;
  memcpy((uint8_t *)map + sizeof(ZiYanFrameShmHeader), pixels, payload);
  // 189：几何切换路径也不 SYNC 整帧（rename 已保证读者见完整 inode）
  munmap(map, total);
  close(fd);
  if (rename(ctmp, cpath) != 0) {
    unlink(ctmp);
    return NO;
  }
  chmod(cpath, 0666);
  ZFS_ResidentRenew(pixels, width, height, bpr, provider, orient, frontHash,
                    status, newSeq, ts);
  return YES;
}

BOOL ZiYanFrameShmWrite(const void *pixels, size_t width, size_t height,
                        size_t bpr) {
  return ZiYanFrameShmWriteEx(pixels, width, height, bpr,
                              ZiYanFrameProviderUnknown, 0, 0,
                              ZiYanFrameStatusValid);
}

BOOL ZiYanFrameShmMapRead(const ZiYanFrameShmHeader *_Nullable *_Nonnull outHdr,
                          const uint8_t *_Nullable *_Nonnull outPixels,
                          size_t *_Nonnull outMapLen,
                          void *_Nullable *_Nonnull outMap) {
  *outHdr = NULL;
  *outPixels = NULL;
  *outMapLen = 0;
  *outMap = NULL;
  NSString *path = ZFS_Path();
  if (!path.length) {
    return NO;
  }
  int fd = open(path.fileSystemRepresentation, O_RDONLY);
  if (fd < 0) {
    return NO;
  }
  ZiYanFrameShmHeader h0;
  memset(&h0, 0, sizeof(h0));
  if (pread(fd, &h0, sizeof(h0), 0) != (ssize_t)sizeof(h0)) {
    close(fd);
    return NO;
  }
  if (!ZFS_MagicOK(&h0) || !ZFS_VersionOK(&h0)) {
    close(fd);
    return NO;
  }
  if (ZFS_IsWritingHdr(&h0)) {
    close(fd);
    return NO;
  }
  if (!ZFS_GeomPayloadOK(&h0)) {
    close(fd);
    return NO;
  }
  struct stat st;
  if (fstat(fd, &st) != 0) {
    close(fd);
    return NO;
  }
  size_t need = sizeof(ZiYanFrameShmHeader) + (size_t)h0.payload;
  if ((size_t)st.st_size < need) {
    close(fd);
    return NO;
  }
  size_t total = (size_t)st.st_size;
  uint32_t commit0 = h0.commit_seq;
  uint32_t seq0 = h0.seq;
  void *map = mmap(NULL, total, PROT_READ, MAP_PRIVATE, fd, 0);
  close(fd);
  if (map == MAP_FAILED) {
    return NO;
  }
  const ZiYanFrameShmHeader *hdr = (const ZiYanFrameShmHeader *)map;
  // 提交序列二次校验（防半帧）
  if (!ZFS_MagicOK(hdr) || !ZFS_VersionOK(hdr) || !ZFS_GeomPayloadOK(hdr)) {
    munmap(map, total);
    return NO;
  }
  if (hdr->version >= 2) {
    if ((hdr->commit_seq & 1u) != 0 || hdr->commit_seq != commit0 ||
        hdr->seq != seq0 || ZFS_IsWritingHdr(hdr)) {
      munmap(map, total);
      return NO;
    }
  } else {
    // v1：无 commit；拒绝明显坏 bpr/payload（已在 GeomPayloadOK）
    (void)commit0;
  }
  size_t need2 = sizeof(ZiYanFrameShmHeader) + (size_t)hdr->payload;
  if (need2 > total) {
    munmap(map, total);
    return NO;
  }
  *outHdr = hdr;
  *outPixels = (const uint8_t *)map + sizeof(ZiYanFrameShmHeader);
  *outMapLen = total;
  *outMap = map;
  return YES;
}

void ZiYanFrameShmUnmap(void *_Nullable map, size_t len) {
  if (map && len > 0) {
    munmap(map, len);
  }
}

static BOOL ZFS_PeekHeader(ZiYanFrameShmHeader *out) {
  memset(out, 0, sizeof(*out));
  NSString *path = ZFS_Path();
  if (!path.length) {
    return NO;
  }
  int fd = open(path.fileSystemRepresentation, O_RDONLY);
  if (fd < 0) {
    return NO;
  }
  ssize_t n = pread(fd, out, sizeof(*out), 0);
  close(fd);
  return n == (ssize_t)sizeof(*out) && ZFS_MagicOK(out) && ZFS_VersionOK(out);
}

uint32_t ZiYanFrameShmPeekSeq(void) {
  ZiYanFrameShmHeader hdr;
  if (!ZFS_PeekHeader(&hdr) || ZFS_IsWritingHdr(&hdr)) {
    return 0;
  }
  return hdr.seq;
}

uint8_t ZiYanFrameShmPeekProvider(void) {
  ZiYanFrameShmHeader hdr;
  if (!ZFS_PeekHeader(&hdr) || hdr.version < 2) {
    return ZiYanFrameProviderUnknown;
  }
  return hdr.provider;
}

uint8_t ZiYanFrameShmPeekStatus(void) {
  ZiYanFrameShmHeader hdr;
  if (!ZFS_PeekHeader(&hdr)) {
    return ZiYanFrameStatusStale;
  }
  if (hdr.version < 2) {
    return ZFS_IsReleasedHdr(&hdr) ? ZiYanFrameStatusReleased
                                   : ZiYanFrameStatusValid;
  }
  return hdr.status;
}

uint8_t ZiYanFrameShmPeekPixelFormat(void) {
  ZiYanFrameShmHeader hdr;
  if (!ZFS_PeekHeader(&hdr) || hdr.version < 2) {
    return ZiYanFramePixelFormatBGRA8888;
  }
  return hdr.pixel_format;
}

uint32_t ZiYanFrameShmPeekFrontHash(void) {
  ZiYanFrameShmHeader hdr;
  if (!ZFS_PeekHeader(&hdr) || hdr.version < 2) {
    return 0;
  }
  return hdr.front_hash;
}

BOOL ZiYanFrameShmIsFresh(NSTimeInterval maxAgeSec, size_t *_Nullable outW,
                          size_t *_Nullable outH, size_t *_Nullable outBPR) {
  ZiYanFrameShmHeader hdr;
  if (!ZFS_PeekHeader(&hdr)) {
    return NO;
  }
  if (ZFS_IsWritingHdr(&hdr) || !ZFS_GeomPayloadOK(&hdr)) {
    return NO;
  }
  if (ZFS_IsReleasedHdr(&hdr)) {
    return NO;
  }
  if (hdr.version >= 2 &&
      (hdr.status == ZiYanFrameStatusStale ||
       hdr.status == ZiYanFrameStatusSuspectBlack)) {
    // stale/suspect：HasPixels 可为真，但 IsFresh=NO（逼重截）
    return NO;
  }
  if (maxAgeSec > 0) {
    double age =
        NSDate.date.timeIntervalSince1970 - ((double)hdr.ts_ms / 1000.0);
    if (age < 0 || age > maxAgeSec) {
      return NO;
    }
  }
  if (outW) {
    *outW = hdr.width;
  }
  if (outH) {
    *outH = hdr.height;
  }
  if (outBPR) {
    *outBPR = hdr.bpr;
  }
  return YES;
}

BOOL ZiYanFrameShmHasPixels(size_t *_Nullable outW, size_t *_Nullable outH,
                            size_t *_Nullable outBPR) {
  NSString *path = ZFS_Path();
  if (!path.length) {
    return NO;
  }
  NSDictionary *attr =
      [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
  unsigned long long sz = [attr[NSFileSize] unsignedLongLongValue];
  if (sz < (unsigned long long)(sizeof(ZiYanFrameShmHeader) + 4)) {
    return NO;
  }
  ZiYanFrameShmHeader hdr;
  if (!ZFS_PeekHeader(&hdr) || ZFS_IsWritingHdr(&hdr) || !ZFS_GeomPayloadOK(&hdr)) {
    return NO;
  }
  if ((size_t)sz < sizeof(ZiYanFrameShmHeader) + (size_t)hdr.payload) {
    return NO;
  }
  double age =
      NSDate.date.timeIntervalSince1970 - ((double)hdr.ts_ms / 1000.0);
  BOOL released = ZFS_IsReleasedHdr(&hdr);
  if (age < 0 || (!released && age > 3600.0)) {
    return NO;
  }
  if (released && age > 7200.0) {
    return NO;
  }
  if (outW) {
    *outW = hdr.width;
  }
  if (outH) {
    *outH = hdr.height;
  }
  if (outBPR) {
    *outBPR = hdr.bpr;
  }
  return YES;
}

BOOL ZiYanSbCaptureThrottleActive(void) {
  NSString *path = ZiYanVarFile(@".ziyan_sb_capture_throttle");
  NSDictionary *attr =
      [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
  if (!attr) {
    return NO;
  }
  NSDate *mod = attr[NSFileModificationDate];
  if (![mod isKindOfClass:[NSDate class]]) {
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    return NO;
  }
  NSTimeInterval age = -[mod timeIntervalSinceNow];
  if (age < 0) {
    age = 0;
  }
  size_t w = 0, h = 0, bpr = 0;
  BOOL hasShm = ZiYanFrameShmIsFresh(3600.0, &w, &h, &bpr) && w >= 2 && h >= 2;
  NSTimeInterval ttl = hasShm ? 120.0 : 30.0;
  if (age > ttl) {
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    return NO;
  }
  return YES;
}

void ZiYanSbMemCooldownArm(NSTimeInterval seconds) {
  if (seconds < 1.0) {
    seconds = 90.0;
  }
  NSString *path = ZiYanVarFile(@".ziyan_sb_mem_cooldown");
  NSString *body = [NSString
      stringWithFormat:@"until=%.0f\n",
                       NSDate.date.timeIntervalSince1970 + seconds];
  [body writeToFile:path
         atomically:NO
           encoding:NSUTF8StringEncoding
              error:nil];
  chmod(path.fileSystemRepresentation, 0666);
}

BOOL ZiYanSbMemCooldownActive(void) {
  NSString *path = ZiYanVarFile(@".ziyan_sb_mem_cooldown");
  NSString *body = [NSString stringWithContentsOfFile:path
                                             encoding:NSUTF8StringEncoding
                                                error:nil];
  if (body.length == 0) {
    return NO;
  }
  NSTimeInterval until = 0;
  for (NSString *line in [body componentsSeparatedByString:@"\n"]) {
    if ([line hasPrefix:@"until="]) {
      until = [line substringFromIndex:6].doubleValue;
      break;
    }
  }
  if (until < 1) {
    NSDictionary *attr =
        [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    NSDate *mod = attr[NSFileModificationDate];
    if ([mod isKindOfClass:[NSDate class]] && -[mod timeIntervalSinceNow] < 90) {
      return YES;
    }
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    return NO;
  }
  if (NSDate.date.timeIntervalSince1970 < until) {
    return YES;
  }
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
  return NO;
}

// ── 阶段2 自检 ──────────────────────────────────────────
BOOL ZiYanFrameShmRunSelfTests(NSString *workDir, NSString **outReport) {
  NSMutableString *rep = [NSMutableString string];
  __block int fail = 0;
  void (^pass)(NSString *) = ^(NSString *n) {
    [rep appendFormat:@"[PASS] %@\n", n];
  };
  void (^bad)(NSString *) = ^(NSString *n) {
    [rep appendFormat:@"[FAIL] %@\n", n];
    fail++;
  };

  if (workDir.length < 1) {
    bad(@"workDir empty");
    if (outReport) {
      *outReport = rep;
    }
    return NO;
  }
  [[NSFileManager defaultManager] createDirectoryAtPath:workDir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
  NSString *shm = [workDir stringByAppendingPathComponent:@"test_frame_shm"];
  [[NSFileManager defaultManager] removeItemAtPath:shm error:nil];
  ZiYanFrameShmSetPathOverrideForTest(shm);

  const size_t W = 32, H = 24, BPR = W * 4;
  size_t payload = BPR * H;
  NSMutableData *pix = [NSMutableData dataWithLength:payload];
  uint8_t *p = pix.mutableBytes;
  for (size_t i = 0; i < payload; i++) {
    p[i] = (uint8_t)(i & 0xff);
  }

  // 1) 正常写读
  if (ZiYanFrameShmWriteEx(p, W, H, BPR, ZiYanFrameProviderIOMFB, 1,
                           ZiYanFrameShmHashFrontBid(@"com.example.app"),
                           ZiYanFrameStatusValid)) {
    pass(@"write_ex ok");
  } else {
    bad(@"write_ex");
  }
  if (ZiYanFrameShmPeekSeq() >= 1 &&
      ZiYanFrameShmPeekProvider() == ZiYanFrameProviderIOMFB &&
      ZiYanFrameShmPeekStatus() == ZiYanFrameStatusValid &&
      ZiYanFrameShmPeekPixelFormat() == ZiYanFramePixelFormatRGBA8888) {
    pass(@"peek meta");
  } else {
    bad(@"peek meta");
  }
  {
    const ZiYanFrameShmHeader *hdr = NULL;
    const uint8_t *rp = NULL;
    size_t ml = 0;
    void *map = NULL;
    if (ZiYanFrameShmMapRead(&hdr, &rp, &ml, &map) && hdr && rp &&
        hdr->version == 2 && hdr->seq >= 1 && rp[0] == p[0] &&
        rp[payload - 1] == p[payload - 1]) {
      pass(@"map_read intact");
    } else {
      bad(@"map_read intact");
    }
    ZiYanFrameShmUnmap(map, ml);
  }

  // 2) 截断 header
  {
    int fd = open(shm.fileSystemRepresentation, O_RDWR | O_TRUNC);
    if (fd >= 0) {
      char junk[16] = {0};
      (void)write(fd, junk, sizeof(junk));
      close(fd);
    }
    const ZiYanFrameShmHeader *hdr = NULL;
    const uint8_t *rp = NULL;
    size_t ml = 0;
    void *map = NULL;
    if (!ZiYanFrameShmMapRead(&hdr, &rp, &ml, &map)) {
      pass(@"truncated reject");
    } else {
      bad(@"truncated reject");
      ZiYanFrameShmUnmap(map, ml);
    }
  }

  // 重建好帧
  (void)ZiYanFrameShmWriteEx(p, W, H, BPR, ZiYanFrameProviderCARender, 0, 0,
                             ZiYanFrameStatusValid);
  uint32_t seqA = ZiYanFrameShmPeekSeq();

  // 3) 错误 bpr 写应失败
  if (!ZiYanFrameShmWrite(p, W, H, W * 2 /* too small */)) {
    pass(@"bad_bpr write reject");
  } else {
    bad(@"bad_bpr write reject");
  }

  // 4) 错误 payload：篡改头 payload
  {
    int fd = open(shm.fileSystemRepresentation, O_RDWR);
    ZiYanFrameShmHeader hdr;
    if (fd >= 0 && pread(fd, &hdr, sizeof(hdr), 0) == (ssize_t)sizeof(hdr)) {
      hdr.payload = 4; // 与 bpr*h 不符
      (void)pwrite(fd, &hdr, sizeof(hdr), 0);
      close(fd);
    }
    const ZiYanFrameShmHeader *h = NULL;
    const uint8_t *rp = NULL;
    size_t ml = 0;
    void *map = NULL;
    if (!ZiYanFrameShmMapRead(&h, &rp, &ml, &map)) {
      pass(@"bad_payload reject");
    } else {
      bad(@"bad_payload reject");
      ZiYanFrameShmUnmap(map, ml);
    }
  }

  // 5) 旧 version=1 兼容读
  {
    (void)ZiYanFrameShmWrite(p, W, H, BPR);
    int fd = open(shm.fileSystemRepresentation, O_RDWR);
    ZiYanFrameShmHeader hdr;
    if (fd >= 0 && pread(fd, &hdr, sizeof(hdr), 0) == (ssize_t)sizeof(hdr)) {
      hdr.version = 1;
      // 清偏移40..63（含 released_v1 / commit / meta）
      memset(&hdr.released_v1, 0, 24);
      (void)pwrite(fd, &hdr, sizeof(hdr), 0);
      close(fd);
    }
    const ZiYanFrameShmHeader *h = NULL;
    const uint8_t *rp = NULL;
    size_t ml = 0;
    void *map = NULL;
    if (ZiYanFrameShmMapRead(&h, &rp, &ml, &map) && h && h->version == 1) {
      pass(@"v1 compat read");
    } else {
      bad(@"v1 compat read");
    }
    ZiYanFrameShmUnmap(map, ml);
  }

  // 6) 并发提交：标 writing 时 MapRead 必须失败
  (void)ZiYanFrameShmWriteEx(p, W, H, BPR, ZiYanFrameProviderBBFrame, 0, 0,
                             ZiYanFrameStatusValid);
  {
    int fd = open(shm.fileSystemRepresentation, O_RDWR);
    ZiYanFrameShmHeader hdr;
    if (fd >= 0 && pread(fd, &hdr, sizeof(hdr), 0) == (ssize_t)sizeof(hdr)) {
      hdr.commit_seq = 7; // odd
      hdr.status = ZiYanFrameStatusWriting;
      (void)pwrite(fd, &hdr, sizeof(hdr), 0);
      close(fd);
    }
    const ZiYanFrameShmHeader *h = NULL;
    const uint8_t *rp = NULL;
    size_t ml = 0;
    void *map = NULL;
    if (!ZiYanFrameShmMapRead(&h, &rp, &ml, &map) &&
        ZiYanFrameShmPeekSeq() == 0) {
      pass(@"writing reject");
    } else {
      bad(@"writing reject");
      ZiYanFrameShmUnmap(map, ml);
    }
  }

  // 7) invalidate → released；HasPixels 仍真；IsFresh 假
  (void)ZiYanFrameShmWriteEx(p, W, H, BPR, ZiYanFrameProviderSBRelay, 2,
                             ZiYanFrameShmHashFrontBid(@"com.apple.springboard"),
                             ZiYanFrameStatusValid);
  ZiYanFrameShmInvalidateForNextFind();
  if (ZiYanFrameShmIsReleased() && ZiYanFrameShmHasPixels(NULL, NULL, NULL) &&
      !ZiYanFrameShmIsFresh(60, NULL, NULL, NULL) &&
      ZiYanFrameShmPeekStatus() == ZiYanFrameStatusReleased) {
    pass(@"invalidate released");
  } else {
    bad(@"invalidate released");
  }

  // 8) 同几何二次写 seq 递增
  (void)ZiYanFrameShmWriteEx(p, W, H, BPR, ZiYanFrameProviderIOMFB, 0, 0,
                             ZiYanFrameStatusValid);
  uint32_t s1 = ZiYanFrameShmPeekSeq();
  p[0] = 0xAB;
  (void)ZiYanFrameShmWriteEx(p, W, H, BPR, ZiYanFrameProviderIOMFB, 0, 0,
                             ZiYanFrameStatusValid);
  uint32_t s2 = ZiYanFrameShmPeekSeq();
  if (s2 > s1 && s1 > 0) {
    pass(@"seq bump in-place");
  } else {
    bad([NSString stringWithFormat:@"seq bump in-place s1=%u s2=%u", s1, s2]);
  }

  // 9) 偏移40=released：正常写必须为0（旧读者不会误判 released）
  {
    int fd = open(shm.fileSystemRepresentation, O_RDONLY);
    ZiYanFrameShmHeader hdr;
    BOOL ok = NO;
    if (fd >= 0 && pread(fd, &hdr, sizeof(hdr), 0) == (ssize_t)sizeof(hdr)) {
      ok = (hdr.released_v1 == 0 && hdr.commit_seq >= 2 &&
            (hdr.commit_seq & 1u) == 0 &&
            offsetof(ZiYanFrameShmHeader, released_v1) == 40 &&
            offsetof(ZiYanFrameShmHeader, commit_seq) == 44);
      close(fd);
    }
    if (ok) {
      pass(@"released_v1 offset40 clear");
    } else {
      bad(@"released_v1 offset40 clear");
    }
  }
  (void)seqA;

  ZiYanFrameShmSetPathOverrideForTest(nil);
  [rep appendFormat:@"summary fail=%d sizeof_hdr=%zu\n", fail,
                    sizeof(ZiYanFrameShmHeader)];
  if (outReport) {
    *outReport = rep;
  }
  return fail == 0;
}
