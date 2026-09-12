#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include "ZiYanSnapshotTransport.h"

typedef struct { const char *input; size_t pos, len, chunk, sent; double now; int stuck, interrupted; } Fake;
static double now(void *p) { return ((Fake *)p)->now; }
static int wait_io(void *p, int writing, double deadline) {
  Fake *f = p; (void)writing;
  f->now += .01;
  return f->now < deadline;
}
static long read_io(void *p, void *out, size_t n) {
  Fake *f = p;
  if (f->stuck) { errno = EAGAIN; return -1; }
  if (f->pos == f->len) return 0;
  if (n > f->chunk) n = f->chunk;
  if (n > f->len-f->pos) n = f->len-f->pos;
  memcpy(out,f->input+f->pos,n); f->pos += n; return (long)n;
}
static long write_io(void *p, const void *in, size_t n) {
  Fake *f = p; (void)in;
  if (f->interrupted==2) { errno=EPIPE; return -1; }
  if (f->interrupted==3) return 0;
  if (f->stuck || f->interrupted) { errno = f->interrupted ? EINTR : EAGAIN; return -1; }
  if (n > f->chunk) n = f->chunk;
  f->sent += n; return (long)n;
}
static int still_authorized(void *p) { return ((Fake *)p)->now<.025; }
static ZYSnapshotIO io(Fake *f) { ZYSnapshotIO out = {f,now,wait_io,read_io,write_io,NULL}; return out; }
static int receive(const char *raw, size_t chunk, ZYSnapshotRequest *r) {
  Fake f = {raw,0,strlen(raw),chunk,0,0,0,0}; ZYSnapshotIO i=io(&f);
  return ZYSnapshotReceive(&i,r,5.0);
}
int main(void) {
  ZYSnapshotRequest r;
  const char *valid="POST /findtest?orient=1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 6\r\nContent-Type: application/x-www-form-urlencoded\r\nAuthorization: Bearer abc\r\n\r\nmain=1";
  assert(receive(valid,1,&r)==200);
  assert(!strcmp(r.method,"POST") && !strcmp(r.body,"main=1") && !strcmp(r.bearer,"abc"));
  assert(receive(valid,8192,&r)==200);
  assert(receive("POST /findtest HTTP/1.1\r\nContent-Length: 8\r\n\r\nmain=1",1,&r)==400);
  assert(receive("POST /findtest HTTP/1.1\r\n\r\n",1,&r)==411);
  assert(receive("POST /findtest HTTP/1.1\r\nContent-Length: -1\r\n\r\n",1,&r)==400);
  assert(receive("POST /findtest HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\na",1,&r)==400);
  assert(receive("POST /findtest HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",1,&r)==501);
  assert(receive("POST /findtest HTTP/1.1\r\nContent-Length: 65537\r\n\r\n",1,&r)==413);
  assert(receive("OPTIONS /snapshot HTTP/1.1\r\n\r\n",1,&r)==405);
  assert(receive("GET /snapshot HTTP/1.1\r\nOrigin: https://untrusted.invalid\r\n\r\n",1,&r)==200 && r.has_origin);
  assert(receive("GET /snapshot HTTP/1.1\r\nContent-Length: 1\r\n\r\na",1,&r)==400);
  assert(receive("POST /findtest HTTP/1.1\r\nContent-Length: 0\r\n\r\n",1,&r)==411);
  char huge_header[8300]; memset(huge_header,'a',sizeof(huge_header)-1); huge_header[sizeof(huge_header)-1]=0;
  memcpy(huge_header,"GET /snapshot HTTP/1.1\r\nX: ",25);
  assert(receive(huge_header,100,&r)==431);
  char large[6000]; size_t header=(size_t)sprintf(large,"POST /findtest HTTP/1.1\r\nContent-Length: 5000\r\n\r\n");
  memset(large+header,'x',5000); large[header+5000]=0;
  assert(receive(large,13,&r)==200 && r.body_length==5000);
  Fake f={"",0,0,10,0,0,1,0}; ZYSnapshotIO i=io(&f);
  assert(ZYSnapshotReceive(&i,&r,.1)==408 && f.now<.12);
  f.now=0; assert(!ZYSnapshotSend(&i,large,5000,.1) && f.now<.12);
  f.now=0; f.stuck=0; f.interrupted=1;
  assert(!ZYSnapshotSend(&i,large,5000,.1) && f.now<.12);
  f.now=0; f.interrupted=0; f.chunk=2000;
  assert(ZYSnapshotSend(&i,large,5000,1) && f.sent==5000);
  f.now=0; f.sent=0; i.allowed=still_authorized;
  assert(!ZYSnapshotSend(&i,large,5000,1) && f.sent==4000);
  i.allowed=NULL;
  f.now=0; f.sent=0; f.interrupted=2;
  assert(!ZYSnapshotSend(&i,large,5000,1) && !f.sent);
  f.now=0; f.interrupted=3;
  assert(!ZYSnapshotSend(&i,large,5000,1) && !f.sent);
  ZYSnapshotAuth a={0};
  assert(!ZYSnapshotAuthorized(&a,0,"x",42,1));
  ZYSnapshotPairingBegin(&a,"code",1);
  assert(!ZYSnapshotPair(&a,"wrong","token",42,2));
  assert(ZYSnapshotPair(&a,"code","token",42,2));
  assert(!ZYSnapshotPair(&a,"code","another",42,3));
  assert(ZYSnapshotAuthorized(&a,0,"token",42,3));
  assert(!ZYSnapshotAuthorized(&a,0,"token",43,3));
  assert(!ZYSnapshotAuthorized(&a,0,"bad",42,3));
  assert(!ZYSnapshotAuthorized(&a,0,"token",42,903));
  unsigned old_generation=a.generation;
  ZYSnapshotPairingStop(&a);
  assert(a.generation!=old_generation);
  assert(!ZYSnapshotAuthorized(&a,0,"token",42,3));
  assert(ZYSnapshotAuthorized(&a,1,"",0,3));
  ZYSnapshotPairingBegin(&a,"code",1);
  assert(!ZYSnapshotPair(&a,"code","token",42,122));
  puts("SNAPSHOT_TRANSPORT_CONTRACT=PASS");
  return 0;
}
