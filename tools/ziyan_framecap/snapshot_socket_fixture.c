/* Runs the production transport on real Windows sockets, without iOS capture. */
#include <winsock2.h>
#include <windows.h>
#include <errno.h>
#include <stdio.h>
#include "ZiYanSnapshotTransport.h"

typedef struct { SOCKET socket; } Connection;
static double ticks(void *p) { (void)p; return GetTickCount64()/1000.0; }
static int ready(void *p,int writing,double deadline) {
  Connection *c=p;
  double left=deadline-ticks(NULL);
  if (left<=0) return 0;
  fd_set fds; FD_ZERO(&fds); FD_SET(c->socket,&fds);
  struct timeval tv={(long)left,(long)((left-(long)left)*1000000)};
  return select(0,writing?NULL:&fds,writing?&fds:NULL,NULL,&tv);
}
static long read_bytes(void *p,void *out,size_t length) {
  int n=recv(((Connection *)p)->socket,out,(int)length,0);
  if (n==SOCKET_ERROR) errno=WSAGetLastError()==WSAEWOULDBLOCK?EAGAIN:EIO;
  return n;
}
static long write_bytes(void *p,const void *in,size_t length) {
  int n=send(((Connection *)p)->socket,in,(int)length,0);
  if (n==SOCKET_ERROR) errno=WSAGetLastError()==WSAEWOULDBLOCK?EAGAIN:EIO;
  return n;
}
int main(int argc,char **argv) {
  WSADATA wsa;
  if (WSAStartup(MAKEWORD(2,2),&wsa)) return 2;
  SOCKET listener=socket(AF_INET,SOCK_STREAM,0);
  struct sockaddr_in address; memset(&address,0,sizeof(address));
  address.sin_family=AF_INET; address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
  if (bind(listener,(struct sockaddr *)&address,sizeof(address)) || listen(listener,4)) return 3;
  int address_length=sizeof(address);
  getsockname(listener,(struct sockaddr *)&address,&address_length);
  printf("%u\n",ntohs(address.sin_port)); fflush(stdout);
  int request_count=argc>1?atoi(argv[1]):2;
  for (int request_number=0;request_number<request_count;request_number++) {
    Connection c={accept(listener,NULL,NULL)};
    if (c.socket==INVALID_SOCKET) return 4;
    u_long nonblocking=1; ioctlsocket(c.socket,FIONBIO,&nonblocking);
    int send_buffer=4096; setsockopt(c.socket,SOL_SOCKET,SO_SNDBUF,(const char *)&send_buffer,sizeof(send_buffer));
    ZYSnapshotIO io={&c,ticks,ready,read_bytes,write_bytes,NULL};
    ZYSnapshotRequest request;
    int status=ZYSnapshotReceive(&io,&request,ticks(NULL)+.4);
    if (status==200 && (!strcmp(request.target,"/large") || !strcmp(request.target,"/complete"))) {
      int slow=!strcmp(request.target,"/large");
      size_t length=slow?16*1024*1024:2*1024*1024;
      char *data=malloc(length); memset(data,'x',length);
      double start=ticks(NULL),deadline=start+(slow?.2:2.0);
      char header[100];
      snprintf(header,sizeof(header),"HTTP/1.0 200 OK\r\nContent-Length: %u\r\n\r\n",(unsigned)length);
      int complete=ZYSnapshotSend(&io,header,strlen(header),deadline) && ZYSnapshotSend(&io,data,length,deadline);
      printf("slow_complete=%d elapsed=%.3f\n",complete,ticks(NULL)-start); fflush(stdout);
      free(data);
    } else {
      const char *body=status==200?(!strcmp(request.target,"/echo")?request.body:"ok\n"):"";
      char header[100];
      snprintf(header,sizeof(header),"HTTP/1.0 %d Result\r\nContent-Length: %u\r\n\r\n",status,(unsigned)strlen(body));
      double deadline=ticks(NULL)+.2;
      ZYSnapshotSend(&io,header,strlen(header),deadline);
      ZYSnapshotSend(&io,body,strlen(body),deadline);
    }
    closesocket(c.socket);
  }
  closesocket(listener); WSACleanup(); return 0;
}
