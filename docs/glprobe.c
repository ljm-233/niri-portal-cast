/* glprobe: 数 QQ broadcast-core 的 GL 分配/释放配对（LD_PRELOAD）
 * 每行: [glprobe] <单调微秒> <函数> <字节或个数>
 * 用法: LD_PRELOAD=/tmp/glprobe.so linuxqq-wayland-fix  (共享时看 stderr) */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <time.h>
typedef int GLsizei; typedef unsigned int GLuint, GLenum; typedef long GLsizeiptr;
static long now_us(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1000000L+t.tv_nsec/1000;}
static void L(const char*f,long b){fprintf(stderr,"[glprobe] %ld %s %ld\n",now_us(),f,b);}
#define REAL(ret,name,args,call) static ret(*r_##name)args; if(!r_##name) r_##name=dlsym(RTLD_NEXT,#name); call
void glGenBuffers(GLsizei n, GLuint*b){ REAL(void,glGenBuffers,(GLsizei,GLuint*), L("glGenBuffers",n); r_glGenBuffers(n,b)); }
void glDeleteBuffers(GLsizei n, const GLuint*b){ REAL(void,glDeleteBuffers,(GLsizei,const GLuint*), L("glDeleteBuffers",n); r_glDeleteBuffers(n,b)); }
void glBufferData(GLenum t, GLsizeiptr s, const void*d, GLenum u){ REAL(void,glBufferData,(GLenum,GLsizeiptr,const void*,GLenum), L("glBufferData",(long)s); r_glBufferData(t,s,d,u)); }
void *glMapBuffer(GLenum t, GLenum a){ REAL(void*,glMapBuffer,(GLenum,GLenum), L("glMapBuffer",0); return r_glMapBuffer(t,a)); }
unsigned char glUnmapBuffer(GLenum t){ REAL(unsigned char,glUnmapBuffer,(GLenum), L("glUnmapBuffer",0); return r_glUnmapBuffer(t)); }
void glGenTextures(GLsizei n, GLuint*b){ REAL(void,glGenTextures,(GLsizei,GLuint*), L("glGenTextures",n); r_glGenTextures(n,b)); }
void glDeleteTextures(GLsizei n, const GLuint*b){ REAL(void,glDeleteTextures,(GLsizei,const GLuint*), L("glDeleteTextures",n); r_glDeleteTextures(n,b)); }
void glReadPixels(int x,int y,GLsizei w,GLsizei h,GLenum f,GLenum t,void*p){ REAL(void,glReadPixels,(int,int,GLsizei,GLsizei,GLenum,GLenum,void*), L("glReadPixels",(long)w*h*4); r_glReadPixels(x,y,w,h,f,t,p)); }
