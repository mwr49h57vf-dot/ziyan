#include <stdio.h>
#include "../../objc/app/ZiYanScriptDependencies.h"
int main(void) {
  char source[65536]; size_t n=fread(source,1,sizeof(source)-1,stdin);source[n]=0;
  unsigned int mask=0;int result=ZiYanScriptDependencyCheck(source,&mask);
  printf("%d %u\n",result,mask);return 0;
}
