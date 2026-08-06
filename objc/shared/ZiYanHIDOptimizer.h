#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/*
  8-150 / 终稿 P2-14：HID 预构造模板 + 热路径注入
  LOCK_TOUCH：坐标仍由调用方 MapLogicToNorm 后传入；本类不改几何/OrientMap
  内存风险：最多 9×3 个 IOHIDEvent 常驻；失败回退现场 Create
*/

@interface ZiYanHIDOptimizer : NSObject

+ (instancetype)shared;
+ (uint64_t)monoMs;
+ (void)noteInjectMs:(double)ms;
+ (double)lastInjectMs;

/// SB 启动预热：加载 IOHID 符号并预构造 finger 1..9 的 down/move/up 壳
- (void)prewarmTemplates;

/// 设备实测 P0-2：检测 IOHID 关键符号是否可用
+ (BOOL)checkHIDSymbols;

/// 游戏路径：仅 finger 事件（skipHand=YES）；桌面可 skipHand=NO（仍现场拼 hand）
/// nx/ny：已归一化竖屏玻璃坐标（0..1），非逻辑像素
- (BOOL)injectNormPhase:(NSString *)phase
                 finger:(int)finger
                     nx:(double)nx
                     ny:(double)ny
               skipHand:(BOOL)skipHand;

/// 逻辑坐标 tap（内部仍须调用方已完成 OrientMap；此处仅做 phase 批处理）
/// 注意：x/y 为归一化坐标时请用 injectNormPhase；本方法假定 nx/ny 已归一化
- (BOOL)injectTapNormX:(double)nx
                     y:(double)ny
                finger:(int)finger
                holdMs:(int)ms;

/// 同上；桌面用 hand+finger，App 前台可用 finger-only。
- (BOOL)injectTapNormX:(double)nx
                     y:(double)ny
                finger:(int)finger
                holdMs:(int)ms
              skipHand:(BOOL)skipHand;

@end

NS_ASSUME_NONNULL_END
