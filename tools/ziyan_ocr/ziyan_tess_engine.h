#ifndef ZIYAN_TESS_ENGINE_H
#define ZIYAN_TESS_ENGINE_H

#ifdef __cplusplus
extern "C" {
#endif

/* 返回 malloc 字符串，调用方 free。失败返回 NULL。 */
char *ZiYanTessOCRGray(const unsigned char *gray, int w, int h,
                       const char *datapath, const char *lang);

#ifdef __cplusplus
}
#endif

#endif
