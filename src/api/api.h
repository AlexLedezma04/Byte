#ifndef API_H
#define API_H

#include "lib/lua/lua.h"
#include "lib/lua/lauxlib.h"
#include "lib/lua/lualib.h"

#define API_TYPE_FONT "Font"

void api_load_libs(lua_State *L);

#endif
