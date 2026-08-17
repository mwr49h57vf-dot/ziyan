#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

/// C-65.11-94：自有 Tesseract 5（不链触动 OcrPlugin）。
/// lang 例：chi_sim / eng。失败返回 @""。
NSString *ZiYanRunTess(UIImage *img, NSString *lang, NSString **viaOut);

#ifdef __cplusplus
}
#endif
