local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local LogView = require "core.logview"


local fullscreen = false


-- folder picker typed into the command view, suggesting only folders
local function pick_folder_with_command_view()
  core.command_view:enter("Open Folder", function(text)
    text = text:gsub("^~", os.getenv("HOME") or "~")
    core.open_folder(text)
  end, function(text)
    text = text:gsub("^~", os.getenv("HOME") or "~")
    local res = {}
    for _, path in ipairs(common.path_suggest(text)) do
      if path:sub(-1) == PATHSEP then table.insert(res, path) end
    end
    return res
  end)
  local start = core.project_dir or os.getenv("HOME") or ""
  core.command_view:set_text(start .. PATHSEP)
end


local dialog_tool
local function find_dialog_tool()
  if dialog_tool == nil then
    dialog_tool = false
    if PATHSEP == "/" then
      for _, tool in ipairs({ "zenity", "kdialog" }) do
        local fp = io.popen("command -v " .. tool .. " 2>/dev/null")
        local found = fp and fp:read("*l")
        if fp then fp:close() end
        if found and found ~= "" then dialog_tool = tool; break end
      end
    end
  end
  return dialog_tool
end

local shell_quote = common.shell_quote

local function pick_folder_with_dialog()
  local tool = find_dialog_tool()
  if not tool then return false end
  local start = (core.project_dir or os.getenv("HOME") or "/") .. "/"
  local cmd
  if tool == "zenity" then
    cmd = "zenity --file-selection --directory --title='Open Folder - Byte' --filename=" .. shell_quote(start)
  else
    cmd = "kdialog --title 'Open Folder - Byte' --getexistingdirectory " .. shell_quote(start)
  end
  local out = os.tmpname()
  local done = out .. ".done"
  system.exec("(" .. cmd .. " > " .. shell_quote(out) .. " 2>/dev/null; touch " .. shell_quote(done) .. ")")
  core.add_thread(function()
    while not system.get_file_info(done) do coroutine.yield(0.1) end
    local fp = io.open(out, "r")
    local path = fp and fp:read("*l")
    if fp then fp:close() end
    os.remove(out)
    os.remove(done)
    if path and path ~= "" then core.open_folder(path) end
  end)
  return true
end

command.add(nil, {
  ["core:quit"] = function()
    core.quit()
  end,

  ["core:force-quit"] = function()
    core.quit(true)
  end,

  ["core:toggle-fullscreen"] = function()
    fullscreen = not fullscreen
    system.set_window_mode(fullscreen and "fullscreen" or "normal")
  end,

  ["core:reload-module"] = function()
    core.command_view:enter("Reload Module", function(text, item)
      local text = item and item.text or text
      core.reload_module(text)
      core.log("Reloaded module %q", text)
    end, function(text)
      local items = {}
      for name in pairs(package.loaded) do
        table.insert(items, name)
      end
      return common.fuzzy_match(items, text)
    end)
  end,

  ["core:find-command"] = function()
    local commands = command.get_all_valid()
    core.command_view:enter("Do Command", function(text, item)
      if item then
        command.perform(item.command)
      end
    end, function(text)
      local res = common.fuzzy_match(commands, text)
      for i, name in ipairs(res) do
        res[i] = {
          text = command.prettify_name(name),
          info = keymap.get_binding(name),
          command = name,
        }
      end
      return res
    end)
  end,

  ["core:find-file"] = function()
    core.command_view:enter("Open File From Project", function(text, item)
      text = item and item.text or text
      core.root_view:open_doc(core.open_doc(text))
    end, function(text)
      local files = {}
      for _, item in pairs(core.project_files) do
        if item.type == "file" then
          table.insert(files, item.filename)
        end
      end
      return common.fuzzy_match(files, text)
    end)
  end,

  ["core:new-doc"] = function()
    core.root_view:open_doc(core.open_doc())
  end,

  ["core:open-file"] = function()
    core.command_view:enter("Open File", function(text)
      core.root_view:open_doc(core.open_doc(text))
    end, common.path_suggest)
  end,

  ["core:open-log"] = function()
    local node = core.root_view:get_active_node()
    node:add_view(LogView())
  end,

  ["core:open-user-module"] = function()
    core.root_view:open_doc(core.open_doc(EXEDIR .. "/data/user/init.lua"))
  end,

  ["core:open-folder"] = function()
    if not pick_folder_with_dialog() then pick_folder_with_command_view() end
  end,

  ["core:open-folder-by-path"] = pick_folder_with_command_view,

  ["core:close-folder"] = function()
    core.close_folder()
  end,

  ["core:open-project-module"] = function()
    local filename = ".byte_project.lua"
    if system.get_file_info(filename) then
      core.root_view:open_doc(core.open_doc(filename))
    else
      local doc = core.open_doc()
      core.root_view:open_doc(doc)
      doc:save(filename)
    end
  end,
})
