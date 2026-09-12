#ifndef ZIYAN_OCR_GEOMETRY_H
#define ZIYAN_OCR_GEOMETRY_H
#include <math.h>
typedef struct { double x,y,w,h; int cropped,valid; } ZiYanOCRRegion;
static inline ZiYanOCRRegion ZiYanOCRResolveRegion(double w,double h,int has,double x,double y,double x1,double y1) {
  ZiYanOCRRegion r={0,0,w,h,0,1};
  if (!isfinite(w)||!isfinite(h)||w<1||h<1) { r.valid=0; return r; }
  if (!has) return r;
  if (!isfinite(x)||!isfinite(y)||!isfinite(x1)||!isfinite(y1)) { r.valid=0; return r; }
  if (x1<0||y1<0) return r;
  x=fmax(0,x); y=fmax(0,y);
  double left=fmax(0,fmin(x,x1)), top=fmax(0,fmin(y,y1));
  double right=fmin(w,fmax(x,x1)), bottom=fmin(h,fmax(y,y1));
  if (left>=w||top>=h||right<=left||bottom<=top) { r.valid=0; return r; }
  r.x=left; r.y=top; r.w=right-left; r.h=bottom-top;
  r.cropped=left>0||top>0||right<w||bottom<h;
  return r;
}
static inline int ZiYanOCRTargetSize(double w,double h,int cropped,double *outW,double *outH) {
  if (!isfinite(w)||!isfinite(h)||w<1||h<1) return 0;
  double factor=1;
  if (cropped && fmin(w,h)<220) factor=fmin(8,220/fmin(w,h));
  factor=fmin(factor,900/fmax(w,h));
  *outW=fmax(1,floor(w*factor)); *outH=fmax(1,floor(h*factor));
  return 1;
}
#endif
