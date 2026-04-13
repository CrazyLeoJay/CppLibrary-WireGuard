#parse("myDest.txt")
#parse("C File Header.h")
#if ($HAS_HEADER)
#[[#include]]# "${NAME}.h"
#end