#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

/// C-65.11-94：系统字体点阵 OCR（对齐触动 tsOcrText 思路，不链 TS 插件）。
/// 用于 iOS13 Vision 无中文时的印刷体中文。失败返回 @""。
NSString *ZiYanRunFontOCR(UIImage *img);

#ifdef __cplusplus
}
#endif
