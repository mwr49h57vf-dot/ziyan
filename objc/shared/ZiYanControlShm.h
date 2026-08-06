#import <Foundation/Foundation.h>
#include <stdint.h>

/*
  8-150 / 终稿 P0-6：控制面 shm v2（4096B 一页）
  - v1：stop/pause/active 标志 + 心跳占位
  - v2：color/touch/toast 环形槽（双写；.ziyan_shm_disabled 可关）
  内存风险：单页 mmap；写失败回退文件 IPC，禁止阻塞 >50ms
*/

NS_ASSUME_NONNULL_BEGIN

#define ZIYAN_CTRL_SHM_MAGIC 0x5A590001u
#define ZIYAN_CTRL_SHM_VERSION 2u
#define ZIYAN_CTRL_FLAG_ACTIVE (1u << 0)
#define ZIYAN_CTRL_FLAG_STOP (1u << 1)
#define ZIYAN_CTRL_FLAG_PAUSED (1u << 2)
#define ZIYAN_CTRL_FLAG_USER_STOPPED (1u << 3)

#define ZIYAN_SHM_ST_EMPTY 0u
#define ZIYAN_SHM_ST_WRITTEN 1u
#define ZIYAN_SHM_ST_READY 2u
#define ZIYAN_SHM_ST_CONSUMED 3u

typedef struct {
  uint32_t magic;
  uint32_t version;
  uint64_t timestamp_ms;
  uint32_t flags;
  uint32_t _pad0;
  char open_app_bid[256];
  char close_app_bid[256];
  char front_bid[256];
  uint32_t lua_heartbeat;
  uint32_t daemon_heartbeat;
  uint32_t framecap_heartbeat;
  uint32_t sb_heartbeat;

  struct {
    uint32_t seq;
    uint32_t state;
    int32_t main_color;
    char points_json[1024];
    int32_t fuzzy;
    int32_t x1, y1, x2, y2;
    uint64_t nonce;
  } color_req;

  struct {
    uint32_t seq;
    uint32_t state;
    int32_t result_x;
    int32_t result_y;
    int32_t match_count;
    char via[16];
    uint64_t nonce;
  } color_rep;

  struct {
    uint32_t seq;
    uint32_t state;
    int32_t type; // 1=tap 2=down 3=up 4=move
    int32_t x, y;
    int32_t hold_ms;
    int32_t finger;
    uint64_t nonce;
  } touch_req;

  struct {
    uint32_t seq;
    uint32_t state;
    int32_t ok;
    uint64_t nonce;
  } touch_rep;

  struct {
    uint32_t seq;
    uint32_t state;
    char text[512];
    int32_t duration_ms;
    uint32_t seq_consumed;
  } toast_cmd;

  // T6：App ↔ daemon 指令（音量/toast/暂停）
  struct {
    uint32_t seq;
    uint32_t state; // WRITTEN→CONSUMED
    int32_t type;   // 1=vol_up 2=vol_down 3=toast 4=pause 5=stop
    int32_t duration_ms;
    char text[248];
    uint64_t nonce;
  } app_cmd;

  struct {
    uint32_t seq;
    uint32_t state;
    int32_t ok;
    uint32_t _pad1;
    uint64_t nonce;
  } app_rep;

  char _pad[1288]; // sizeof==4096
} ZiYanControlShmLayout;

BOOL ZiYanControlShmEnsure(void);
BOOL ZiYanControlShmDisabled(void);
void ZiYanControlShmSetFlag(uint32_t bit, BOOL on);
BOOL ZiYanControlShmTestFlag(uint32_t bit);
void ZiYanControlShmSyncFromFiles(void);
NSString *ZiYanControlShmPath(void);

void ZiYanControlShmBridge_SetStop(BOOL on);
void ZiYanControlShmBridge_SetPaused(BOOL on);
void ZiYanControlShmBridge_SetActive(BOOL on);

BOOL ZiYanControlShmWriteColorReq(int32_t mainColor, NSString *pointsJSON,
                                  int fuzzy, int x1, int y1, int x2, int y2,
                                  uint64_t nonce);
/// 消费 color_req（state WRITTEN→CONSUMED）；有请求返回 YES
BOOL ZiYanControlShmTakeColorReq(int32_t *outMain, NSString *_Nullable *_Nonnull outPts,
                                 int *outFuzzy, int *x1, int *y1, int *x2, int *y2,
                                 uint64_t *outNonce);
BOOL ZiYanControlShmWriteColorRep(int32_t x, int32_t y, int32_t count,
                                  NSString *via, uint64_t nonce);
BOOL ZiYanControlShmReadColorRep(int32_t *outX, int32_t *outY, int32_t *outCount,
                                 NSString *_Nullable *_Nonnull outVia,
                                 uint64_t *outNonce);

BOOL ZiYanControlShmWriteTouchReq(int type, int x, int y, int holdMs, int finger,
                                  uint64_t nonce);
BOOL ZiYanControlShmTakeTouchReq(int *outType, int *outX, int *outY, int *outHold,
                                 int *outFinger, uint64_t *outNonce);
BOOL ZiYanControlShmWriteTouchRep(BOOL ok, uint64_t nonce);
BOOL ZiYanControlShmReadTouchRep(BOOL *outOk, uint64_t *outNonce);

BOOL ZiYanControlShmWriteToast(NSString *text, int durationMs);
BOOL ZiYanControlShmTakeToast(NSString *_Nullable *_Nonnull outText,
                              int *outDurationMs);

void ZiYanControlShmWriteHeartbeat(NSString *name);
BOOL ZiYanControlShmTestHeartbeatFresh(NSString *name, NSTimeInterval maxAge);

/// control.lua：读/写暂停停止
BOOL ZiYanControlShmReadControlFlags(BOOL *outPaused, BOOL *outStopped);
BOOL ZiYanControlShmWriteControlFlags(BOOL paused, BOOL stopped);

/// T6 App↔daemon
BOOL ZiYanControlShmWriteAppCmd(int type, NSString *_Nullable text, int durationMs,
                                uint64_t nonce);
BOOL ZiYanControlShmTakeAppCmd(int *outType, NSString *_Nullable *_Nonnull outText,
                               int *outDurationMs, uint64_t *outNonce);
BOOL ZiYanControlShmWriteAppRep(BOOL ok, uint64_t nonce);

NS_ASSUME_NONNULL_END
