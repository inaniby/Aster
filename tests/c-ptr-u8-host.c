#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef int32_t (*load_fn)(uint8_t *);
typedef int32_t (*store_fn)(uint8_t *, int32_t);
static void *sym(void *h,const char*n){dlerror();void*p=dlsym(h,n);const char*e=dlerror();if(e||!p){fprintf(stderr,"FAIL: dlsym %s: %s\n",n,e?e:"null");exit(3);}return p;}
int main(int argc,char**argv){const char*path=argc>1?argv[1]:"./libaster_ptr_u8.so";void*h=dlopen(path,RTLD_NOW|RTLD_LOCAL);if(!h){fprintf(stderr,"FAIL: dlopen: %s\n",dlerror());return 2;}void*s=sym(h,"aster_load_u8");load_fn load=NULL;memcpy(&load,&s,sizeof(load));s=sym(h,"aster_store_u8");store_fn store=NULL;memcpy(&store,&s,sizeof(store));uint8_t v=0x80;int32_t got=load(&v);printf("load_0x80=%d\n",got);if(got!=128){fputs("FAIL: u8 load did not zero-extend\n",stderr);return 4;}store(&v,0x1ff);printf("stored_low_byte=0x%02x\n",(unsigned)v);if(v!=0xff){fputs("FAIL: u8 store did not truncate to low byte\n",stderr);return 5;}store(&v,-1);if(v!=0xff){fputs("FAIL: negative value low byte mismatch\n",stderr);return 6;}puts("PASS: C -> Aster unsigned byte load/store");puts("PASS: Aster v0.22.6-dev u8 memory ABI test");dlclose(h);return 0;}
