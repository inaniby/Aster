#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef int32_t (*read_fn)(int32_t *, int32_t);
typedef int32_t (*write_fn)(int32_t *, int32_t, int32_t);
static void *sym(void *h,const char*n){dlerror();void*p=dlsym(h,n);const char*e=dlerror();if(e||!p){fprintf(stderr,"FAIL: dlsym %s: %s\n",n,e?e:"null");exit(3);}return p;}
int main(int argc,char**argv){const char*path=argc>1?argv[1]:"./libaster_ptr_index.so";void*h=dlopen(path,RTLD_NOW|RTLD_LOCAL);if(!h){fprintf(stderr,"FAIL: dlopen: %s\n",dlerror());return 2;}void*s=sym(h,"aster_index_read");read_fn read=NULL;memcpy(&read,&s,sizeof(read));s=sym(h,"aster_index_write");write_fn write=NULL;memcpy(&write,&s,sizeof(write));int32_t a[4]={11,22,33,44};
// p[i] must stride 4 bytes: a[1] is the second int, not the second byte.
if(read(a,0)!=11){fprintf(stderr,"FAIL: read(a,0)=%d\n",read(a,0));return 4;}
if(read(a,1)!=22){fprintf(stderr,"FAIL: read(a,1)=%d\n",read(a,1));return 5;}
if(read(a,2)!=33){fprintf(stderr,"FAIL: read(a,2)=%d\n",read(a,2));return 6;}
if(read(a,3)!=44){fprintf(stderr,"FAIL: read(a,3)=%d\n",read(a,3));return 7;}
printf("reads: %d %d %d %d\n",read(a,0),read(a,1),read(a,2),read(a,3));
// writes through the Aster-side pointer must be visible to C.
if(write(a,2,999)!=999){fputs("FAIL: write return mismatch\n",stderr);return 8;}
if(a[2]!=999){fprintf(stderr,"FAIL: C observes a[2]=%d\n",a[2]);return 9;}
write(a,0,-7);
if(a[0]!=-7){fprintf(stderr,"FAIL: negative store a[0]=%d\n",a[0]);return 10;}
printf("writes visible: a[0]=%d a[2]=%d\n",a[0],a[2]);
// dynamic index variable must behave like the constant ones.
int32_t k=1;
if(read(a,k)!=22){fputs("FAIL: dynamic index read\n",stderr);return 11;}
puts("PASS: C -> Aster p[i] pointer indexing (4-byte stride, both directions)");
puts("PASS: Aster v0.22.49-dev pointer index ABI test");
dlclose(h);return 0;}
