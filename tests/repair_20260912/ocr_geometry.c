#include <assert.h>
#include "../../tools/ziyan_ocr/ZiYanOCRGeometry.h"
int main(void) {
 double w,h;
 ZiYanOCRRegion a=ZiYanOCRResolveRegion(3000,2000,0,0,0,0,0);
 ZiYanOCRRegion b=ZiYanOCRResolveRegion(3000,2000,1,0,0,-1,-1);
 ZiYanOCRRegion c=ZiYanOCRResolveRegion(3000,2000,1,0,0,3000,2000);
 assert(a.valid&&b.valid&&c.valid&&!a.cropped&&!b.cropped&&!c.cropped);
 assert(ZiYanOCRTargetSize(a.w,a.h,a.cropped,&w,&h)&&w==900&&h==600);
 assert(ZiYanOCRTargetSize(b.w,b.h,b.cropped,&w,&h)&&w==900&&h==600);
 assert(ZiYanOCRTargetSize(c.w,c.h,c.cropped,&w,&h)&&w==900&&h==600);
 c=ZiYanOCRResolveRegion(3000,2000,1,10,10,60,60);
 assert(c.cropped&&ZiYanOCRTargetSize(c.w,c.h,c.cropped,&w,&h)&&w==220&&h==220);
 assert(ZiYanOCRTargetSize(3000,10,1,&w,&h)&&w==900&&h==3);
 assert(!ZiYanOCRResolveRegion(3000,2000,1,9000,9000,9900,9900).valid);
 assert(!ZiYanOCRResolveRegion(3000,2000,1,NAN,0,100,100).valid);
 assert(!ZiYanOCRResolveRegion(0,0,0,0,0,0,0).valid);
 return 0;
}
