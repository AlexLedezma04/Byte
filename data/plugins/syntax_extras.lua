local syntax = require "core.syntax"

require "plugins.language_sh"
require "plugins.language_make"

local function extend(name, files, headers)
  for _, s in ipairs(syntax.items) do
    if s.name == name then
      if type(s.files) == "string" then s.files = { s.files } end
      s.files = s.files or {}
      for _, f in ipairs(files) do table.insert(s.files, f) end
      if headers then s.headers = headers end
      return
    end
  end
end

extend("Shell script",
  { "%.bash$", "%.zsh$", "%.ksh$", "%.bashrc$", "%.bash_profile$", "%.bash_aliases$",
    "%.zshrc$", "%.profile$", "%.env$" },
  nil)
extend("Makefile", { "^GNUmakefile$", "%.make$" })
