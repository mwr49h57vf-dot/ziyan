#ifndef ZIYAN_SCRIPT_DEPENDENCIES_H
#define ZIYAN_SCRIPT_DEPENDENCIES_H
#include <ctype.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>
typedef struct { const char *p; int kind, truncated; char value[256]; } ZiYanLuaToken;
static inline int ZiYanLuaLong(const char *p, const char **body, const char **end) {
  if (*p != '[') return 0;
  const char *q=p+1;
  while (*q=='=') q++;
  if (*q!='[') return 0;
  size_t equals=(size_t)(q-p-1);
  *body=++q;
  for (;*q;q++) if (*q==']') {
    const char *r=q+1; size_t n=0;
    while (*r=='=') {n++;r++;}
    if (n==equals && *r==']') {*end=r+1;return 1;}
  }
  return -1;
}
static inline ZiYanLuaToken ZiYanLuaNext(const char *p) {
  ZiYanLuaToken t; memset(&t,0,sizeof(t));
  for (;;) {
    while (*p && isspace((unsigned char)*p)) p++;
    if (p[0]!='-' || p[1]!='-') break;
    p+=2; const char *body=NULL,*end=NULL;
    int islong=ZiYanLuaLong(p,&body,&end);
    if (islong<0) {t.kind=-1;t.p=p+strlen(p);return t;}
    if (islong) p=end; else while (*p && *p!='\n' && *p!='\r') p++;
  }
  const char *body=NULL,*end=NULL; size_t n=0;
  int islong=ZiYanLuaLong(p,&body,&end);
  if (islong<0) {t.kind=-1;t.p=p+strlen(p);return t;}
  if (islong) {
    const char *q=p+1; while (*q=='=') q++;
    size_t closeLength=(size_t)(q-p+1);
    size_t length=(size_t)(end-body)-closeLength;
    if (length && *body=='\n') {body++;length--;}
    t.truncated=length>255; n=length<255?length:255; memcpy(t.value,body,n); t.kind=2;p=end;
  } else if (*p=='\'' || *p=='"') {
    char quote=*p++; t.kind=2;
    while (*p && *p!=quote) {
      unsigned int c=(unsigned char)*p++;
      if (c=='\n'||c=='\r') {t.kind=-1;break;}
      if (c=='\\') {
        if (!*p) {t.kind=-1;break;}
        c=(unsigned char)*p++;
        if (c=='z') {while (*p && isspace((unsigned char)*p)) p++;continue;}
        if (isdigit(c)) {int k=1;c-='0';while(k<3&&isdigit((unsigned char)*p)){c=c*10+(unsigned char)*p++-'0';k++;}}
        else if (c=='x') {
          if (!isxdigit((unsigned char)p[0]) || !p[1] || !isxdigit((unsigned char)p[1])) {t.kind=-1;break;}
          char hex[3]={p[0],p[1],0};c=(unsigned int)strtoul(hex,NULL,16);p+=2;
        } else if (c=='u' && *p=='{') {
          char *stop=NULL;c=(unsigned int)strtoul(p+1,&stop,16);
          if(stop==p+1||*stop!='}') {t.kind=-1;break;}p=stop+1;
        } else if (c=='n') c='\n'; else if (c=='r') c='\r'; else if (c=='t') c='\t';
      }
      if (n<255) t.value[n++]=(c>0&&c<128)?(char)c:'?'; else t.truncated=1;
    }
    if (t.kind!=-1 && *p==quote) p++; else t.kind=-1;
  } else if (isalpha((unsigned char)*p)||*p=='_') {
    t.kind=1;while(isalnum((unsigned char)*p)||*p=='_'){if(n<255)t.value[n++]=*p;p++;}
  } else if (*p) {t.kind=3;t.value[n++]=*p++;}
  t.value[n]=0;t.p=p;return t;
}
static inline int ZiYanForbiddenModule(const char *name) {
  const char *base=name;
  for(const char *p=name;*p;p++) if(*p=='/'||*p=='\\') base=p+1;
  const char *banned[]={"TSLib","ts","sz"};
  for(size_t i=0;i<3;i++) {
    size_t n=strlen(banned[i]);
    if(strncmp(base,banned[i],n)==0 && (base[n]==0||base[n]=='.')) return 1;
  }
  return 0;
}
// 0 allowed, 1 prohibited dependency, 2 malformed token, 3 unresolved loader.
// This is a dependency contract, not a Lua sandbox or a complete parser.
static inline int ZiYanScriptDependencyCheck(const char *source, unsigned int *businessMask) {
  const char *p=source?source:""; unsigned int mask=0; int afterFunction=0;
  for (;;) {
    ZiYanLuaToken t=ZiYanLuaNext(p);p=t.p;
    if(t.kind<0)return 2;
    if(!t.kind)break;
    if(t.kind!=1){afterFunction=0;continue;}
    if(strcmp(t.value,"TSLib")==0)return 1;
    if(strcmp(t.value,"load")==0||strcmp(t.value,"loadstring")==0||strcmp(t.value,"_G")==0||strcmp(t.value,"_ENV")==0||strcmp(t.value,"getfenv")==0||strcmp(t.value,"setfenv")==0||strcmp(t.value,"package")==0)return 3;
    const char *required[]={"phase_login","phase_role_select","phase_enter_game","phase_auto_battle"};
    ZiYanLuaToken lookahead=ZiYanLuaNext(p);
    for(unsigned int i=0;i<4;i++)if(afterFunction && strcmp(t.value,required[i])==0 && lookahead.kind==3 && lookahead.value[0]=='(')mask|=1u<<i;
    if(strcmp(t.value,"runApp")==0 && lookahead.kind==3 && lookahead.value[0]=='(' && !afterFunction)mask|=16;
    afterFunction=strcmp(t.value,"function")==0;
    if(strcmp(t.value,"require")==0||strcmp(t.value,"dofile")==0||strcmp(t.value,"loadfile")==0) {
      t=ZiYanLuaNext(p);p=t.p;
      int parenthesized=t.kind==3 && t.value[0]=='(';
      if(parenthesized){t=ZiYanLuaNext(p);p=t.p;}
      if(t.kind<0)return 2;
      if(t.kind!=2||t.truncated)return 3;
      if(ZiYanForbiddenModule(t.value))return 1;
      ZiYanLuaToken next=ZiYanLuaNext(p);
      if(parenthesized && !(next.kind==3 && next.value[0]==')'))return 3;
      if(!parenthesized && next.kind==3 && next.value[0]=='.')return 3;
    }
  }
  if(businessMask)*businessMask=mask;
  return 0;
}
#endif
