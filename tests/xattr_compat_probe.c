/* Run against a fresh directory with xattr-only.dylib injected. */
extern int printf(const char *, ...);
extern int *__error(void);
extern long getxattr(const char *,const char *,void *,unsigned long,unsigned int,int);
extern int setxattr(const char *,const char *,const void *,unsigned long,unsigned int,int);
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    const char *name = "org.chromium.crashpad.macoblox-regression";
    char b[4] = {0};
    if (getxattr(argv[1],name,b,4,0,0) != -1 || *__error() != 93) return 10;
    if (setxattr(argv[1],name,"ok",2,0,0) != 0) return 11;
    if (getxattr(argv[1],name,0,0,0,0) != 2) return 12;
    if (getxattr(argv[1],name,b,1,0,0) != -1 || *__error() != 34) return 13;
    if (getxattr(argv[1],name,b,4,0,0) != 2 || b[0]!='o' || b[1]!='k') return 14;
    if (getxattr("/macoblox-nonexistent",name,b,4,0,0) != -1 || *__error()!=2) return 15;
    /* Non-Crashpad names retain the native Linux namespace behavior. */
    if (setxattr(argv[1],"user.macoblox-native","n",1,0,0) != -1 || *__error()!=2) return 16;
    printf("PASS: missing attribute, persistence, size query, short buffer, missing path, passthrough\n");
    return 0;
}
