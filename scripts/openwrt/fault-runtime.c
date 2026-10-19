/* Disposable x86 VM fault injector, never shipped in owner installer.
 * Observe real filesystem writes; kill only the explicitly started setsid group.
 */
#include <sys/inotify.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>
#include <signal.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
static void receipt(const char *p,const char *s) {
 int f=open(p,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600);
 if(f<0 || write(f,s,strlen(s))!=(ssize_t)strlen(s) || fsync(f) || close(f))exit(10);
}
int main(int argc,char **argv) {
 if(argc!=5)return 2;
 int fd=inotify_init1(IN_CLOEXEC);if(fd<0 || inotify_add_watch(fd,argv[1],IN_CLOSE_WRITE)<0)return 3;
 receipt(argv[4],"READY\n");
 unsigned count=0;char buffer[8192] __attribute__((aligned(__alignof__(struct inotify_event))));
 for(;;) {
  struct pollfd p={.fd=fd,.events=POLLIN};if(poll(&p,1,180000)!=1)return 4;
  ssize_t n=read(fd,buffer,sizeof(buffer));if(n<=0)return 5;
  for(char *p=buffer;p<buffer+n;) {
   struct inotify_event *e=(void *)p;p+=sizeof(*e)+e->len;
   if(!(e->mask&IN_CLOSE_WRITE) || !e->len || !strcmp(e->name,"owner"))continue;
   if(++count!=2)continue;
   FILE *f=fopen(argv[2],"r");long number=0;char extra;
   if(!f || fscanf(f,"%ld %c",&number,&extra)!=1 || fclose(f) || number<2 || number>2147483647L)return 6;
   pid_t pid=(pid_t)number;
   if(getsid(pid)!=pid || getpgid(pid)!=pid || kill(-pid,SIGSTOP))return 7;
   receipt(argv[3],"SIGKILL\n");
   return kill(-pid,SIGKILL)?8:0;
  }
 }
}
