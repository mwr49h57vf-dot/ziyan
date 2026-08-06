#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Mac 侧车客户端：优先 HTTP POST /v1/*，失败回退文件投递
/// 真机不加载 Transformer；完整推理在侧车。
/// URL：Media/ZiYan/.ziyan_sidecar_url 或默认 http://127.0.0.1:8765
@interface ZiYanLLMSidecarClient : NSObject

/// models_status ready_count 是否达到 want（默认 3）
+ (BOOL)modelsReadyWant:(NSInteger)want statusOut:(NSString *_Nullable *_Nullable)statusOut;

/// POST /v1/scriptgen/run → 文件 scriptgen_req/result.json
+ (nullable NSDictionary *)runScriptGen:(NSDictionary *)req
                            timeoutSec:(NSTimeInterval)timeoutSec
                                 error:(NSString *_Nullable *_Nullable)errOut;

/// POST /v1/dump_analyze/run → 文件 dump_analyze_req/result.json
+ (nullable NSDictionary *)runDumpAnalyze:(NSDictionary *)req
                              timeoutSec:(NSTimeInterval)timeoutSec
                                 error:(NSString *_Nullable *_Nullable)errOut;

/// POST /v1/vision/analyze → LiveLearn OCR/色参分桶
+ (nullable NSDictionary *)runVisionAnalyze:(NSDictionary *)req
                                timeoutSec:(NSTimeInterval)timeoutSec
                                     error:(NSString *_Nullable *_Nullable)errOut;

@end

NS_ASSUME_NONNULL_END
