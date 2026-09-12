#ifndef ZIYAN_SNAPSHOT_TRANSPORT_H
#define ZIYAN_SNAPSHOT_TRANSPORT_H

/* Portable HTTP boundary. All deadlines use the caller's monotonic clock. */
#include <ctype.h>
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define ZY_SNAPSHOT_HEADER_LIMIT 8192
#define ZY_SNAPSHOT_BODY_LIMIT 65536
#define ZY_SNAPSHOT_RECEIVE_SECONDS 5.0
#define ZY_SNAPSHOT_SEND_SECONDS 8.0

typedef struct {
  void *context;
  double (*now)(void *);
  int (*wait)(void *, int writing, double deadline);
  long (*read)(void *, void *, size_t);
  long (*write)(void *, const void *, size_t);
  int (*allowed)(void *); /* Rechecked between sends, including after wait. */
} ZYSnapshotIO;

typedef struct {
  char raw[ZY_SNAPSHOT_HEADER_LIMIT + ZY_SNAPSHOT_BODY_LIMIT + 1];
  char method[8], target[2048], bearer[129];
  char *body;
  size_t body_length;
  int has_origin;
} ZYSnapshotRequest;

static inline int ZYSnapshotEqualName(const char *a, size_t n, const char *b) {
  if (strlen(b)!=n) return 0;
  for (size_t j=0;j<n;j++) if (tolower((unsigned char)a[j])!=tolower((unsigned char)b[j])) return 0;
  return 1;
}

static inline int ZYSnapshotReceive(ZYSnapshotIO *io, ZYSnapshotRequest *r, double deadline) {
  memset(r,0,sizeof(*r));
  size_t used=0, header=0, length=0;
  int content_length_seen=0;
  while (!header || used<header+length) {
    if (io->now(io->context)>=deadline || io->wait(io->context,0,deadline)<=0) return 408;
    size_t limit=header ? header+length : ZY_SNAPSHOT_HEADER_LIMIT;
    if (used>=limit) return 431;
    long got=io->read(io->context,r->raw+used,limit-used);
    if (got<0) {
      if (errno==EINTR || errno==EAGAIN || errno==EWOULDBLOCK) continue;
      return 400;
    }
    if (!got) return 400;
    if (memchr(r->raw+used,0,(size_t)got)) return 400;
    used+=(size_t)got; r->raw[used]=0;
    if (header) continue;
    char *end=strstr(r->raw,"\r\n\r\n");
    if (!end) { if (used==ZY_SNAPSHOT_HEADER_LIMIT) return 431; continue; }
    header=(size_t)(end-r->raw)+4;
    char *line_end=strstr(r->raw,"\r\n");
    char *sp=strchr(r->raw,' ');
    if (!sp || sp>=line_end || (size_t)(sp-r->raw)>=sizeof(r->method)) return 400;
    memcpy(r->method,r->raw,(size_t)(sp-r->raw));
    char *sp2=strchr(sp+1,' ');
    if (!sp2 || sp2>=line_end || (size_t)(sp2-sp-1)>=sizeof(r->target) || sp[1]!='/') return 400;
    memcpy(r->target,sp+1,(size_t)(sp2-sp-1));
    if ((size_t)(line_end-sp2)!=9 || (memcmp(sp2+1,"HTTP/1.1",8) && memcmp(sp2+1,"HTTP/1.0",8))) return 400;
    if (strcmp(r->method,"GET") && strcmp(r->method,"POST")) return 405;
    for (char *line=line_end+2;line<end;line=line_end+2) {
      line_end=strstr(line,"\r\n");
      char *colon=memchr(line,':',(size_t)(line_end-line));
      if (!colon || colon==line || isspace((unsigned char)*line)) return 400;
      for (char *k=line;k<colon;k++) if (!(isalnum((unsigned char)*k) || *k=='-')) return 400;
      char *value=colon+1;
      while (value<line_end && (*value==' ' || *value=='\t')) value++;
      char *value_end=line_end;
      while (value_end>value && (value_end[-1]==' ' || value_end[-1]=='\t')) value_end--;
      size_t vn=(size_t)(value_end-value), kn=(size_t)(colon-line);
      if (ZYSnapshotEqualName(line,kn,"Content-Length")) {
        if (content_length_seen++ || !vn) return 400;
        for (size_t j=0;j<vn;j++) {
          if (value[j]<'0' || value[j]>'9') return 400;
          length=length*10+(size_t)(value[j]-'0');
          if (length>ZY_SNAPSHOT_BODY_LIMIT) return 413;
        }
      } else if (ZYSnapshotEqualName(line,kn,"Transfer-Encoding")) return 501;
      else if (ZYSnapshotEqualName(line,kn,"Expect")) return 417;
      else if (ZYSnapshotEqualName(line,kn,"Origin")) r->has_origin=1;
      else if (ZYSnapshotEqualName(line,kn,"Authorization")) {
        if (r->bearer[0] || vn<=7 || vn-7>=sizeof(r->bearer) || memcmp(value,"Bearer ",7)) return 400;
        memcpy(r->bearer,value+7,vn-7);
      }
    }
    if (!strcmp(r->method,"POST") && (!content_length_seen || !length)) return 411;
    if (!strcmp(r->method,"GET") && length) return 400;
    if (used>header+length) return 400; /* no pipelining / trailing requests */
  }
  r->body=r->raw+header; r->body_length=length;
  return 200;
}

static inline int ZYSnapshotSend(ZYSnapshotIO *io,const void *data,size_t length,double deadline) {
  size_t sent=0;
  while (sent<length) {
    if (io->now(io->context)>=deadline || (io->allowed && !io->allowed(io->context))) return 0;
    if (io->wait(io->context,1,deadline)<=0 || (io->allowed && !io->allowed(io->context))) return 0;
    size_t chunk=length-sent; if (chunk>65536) chunk=65536;
    long n=io->write(io->context,(const char *)data+sent,chunk);
    if (n<0) {
      if (errno==EINTR || errno==EAGAIN || errno==EWOULDBLOCK) continue;
      return 0;
    }
    if (!n) return 0;
    sent+=(size_t)n;
  }
  return 1;
}

typedef struct {
  char code[65], token[65];
  uint32_t peer;
  double pairing_until, session_until;
  unsigned generation;
} ZYSnapshotAuth;

static inline int ZYSnapshotSecretEqual(const char *a,const char *b) {
  size_t an=strlen(a),bn=strlen(b); unsigned diff=(unsigned)(an^bn);
  for (size_t j=0;j<an;j++) diff|=(unsigned char)a[j]^(j<bn?(unsigned char)b[j]:0);
  return diff==0 && an>0;
}
static inline void ZYSnapshotPairingStop(ZYSnapshotAuth *a) {
  unsigned g=a->generation+1; memset(a,0,sizeof(*a)); a->generation=g;
}
static inline void ZYSnapshotPairingBegin(ZYSnapshotAuth *a,const char *code,double now) {
  ZYSnapshotPairingStop(a); strncpy(a->code,code,sizeof(a->code)-1); a->pairing_until=now+120;
}
static inline int ZYSnapshotPair(ZYSnapshotAuth *a,const char *code,const char *token,uint32_t peer,double now) {
  if (now>=a->pairing_until || !ZYSnapshotSecretEqual(a->code,code)) return 0;
  memset(a->code,0,sizeof(a->code)); a->pairing_until=0;
  strncpy(a->token,token,sizeof(a->token)-1); a->peer=peer; a->session_until=now+900;
  return 1;
}
static inline int ZYSnapshotAuthorized(const ZYSnapshotAuth *a,int loopback,const char *token,uint32_t peer,double now) {
  return loopback || (now<a->session_until && a->peer==peer && ZYSnapshotSecretEqual(a->token,token));
}

#endif
