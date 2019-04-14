package = "sway"
version = "0.1-1"
source = {
   url = "git://github.com/norcalli/lua-sway"
}
description = {
   homepage = "*** please enter a project homepage ***",
   license = "*** please specify a license ***"
}
dependencies = {
   "lua >= 5.1, < 5.4",
	 "stream >= 0.1",
	 "luaposix >= 34.0.0"
}
build = {
   type = "builtin",
   modules = {
      sway = "src/sway.lua"
   }
}
