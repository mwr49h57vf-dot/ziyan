#include <windows.h>
#define LUA_TMPNAMBUFSIZE MAX_PATH
#define lua_tmpnam(b,e) { char zyl_tmpdir[MAX_PATH]; e = (GetTempPathA(MAX_PATH,zyl_tmpdir)==0 || GetTempFileNameA(zyl_tmpdir,"zyl",0,b)==0); }
#undef LoadString
