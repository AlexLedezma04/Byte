local core = require "core"
local common = require "core.common"
local icons = require "core.icons"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local logo = require "core.logo"
local ContextMenu = require "core.contextmenu"

config.treeview_size = 200 * SCALE
config.treeview_min_size = 140 * SCALE

-- the width the user dragged the sidebar to, kept across restarts
local function width_file()
  return core.get_config_dir() .. PATHSEP .. "treeview_width"
end

do
  local fp = io.open(width_file(), "r")
  if fp then
    local w = tonumber(fp:read("*l"))
    fp:close()
    if w and w > 0 then config.treeview_size = w * SCALE end
  end
end

local function save_width()
  local dir = core.get_config_dir()
  if not system.get_file_info(dir) then return end
  local fp = io.open(width_file(), "w")
  if fp then
    fp:write(string.format("%d\n", math.floor(config.treeview_size / SCALE + 0.5)))
    fp:close()
  end
end

-- sidebar typography (Inter): regular for rows, semibold for tabs and labels
style.sidebar_font = style.sidebar_font
  or style.load_font(EXEDIR .. "/data/fonts/sidebar.ttf", 13 * SCALE)
style.sidebar_tab_font = style.sidebar_tab_font
  or style.load_font(EXEDIR .. "/data/fonts/sidebar-bold.ttf", 12.5 * SCALE)
style.sidebar_label_font = style.sidebar_label_font
  or style.load_font(EXEDIR .. "/data/fonts/sidebar-bold.ttf", 10.5 * SCALE)

local function get_depth(filename)
  local n = 0
  for sep in filename:gmatch("[\\/]") do
    n = n + 1
  end
  return n
end


local TreeView = View:extend()

function TreeView:new()
  TreeView.super.new(self)
  self.scrollable = true
  self.visible = true
  self.init_size = true
  self.cache = {}
  -- sidebar tabs; other plugins add theirs with add_panel()
  self.panels = { { id = "project", name = "Project", icon = "folder" } }
  self.panel = "project"
  self.panel_scroll = {}
end


function TreeView:add_panel(panel)
  table.insert(self.panels, panel)
  core.redraw = true
end


function TreeView:get_shown_panels()
  local t = {}
  for _, p in ipairs(self.panels) do
    if not p.shown or p.shown() then t[#t + 1] = p end
  end
  return t
end


function TreeView:get_panel()
  for _, p in ipairs(self:get_shown_panels()) do
    if p.id == self.panel then return p end
  end
  return self.panels[1]
end


function TreeView:set_panel(id)
  if id == self.panel then return end
  self.panel_scroll[self.panel] = self.scroll.to.y
  self.panel = id
  local y = self.panel_scroll[id] or 0
  self.scroll.to.y, self.scroll.y = y, y
  self.hovered_item, self.hovered_header = nil, false
  core.redraw = true
end


function TreeView:get_cached(item)
  local t = self.cache[item.filename]
  if not t then
    t = {}
    t.filename = item.filename
    t.abs_filename = system.absolute_path(item.filename)
    t.name = t.filename:match("[^\\/]+$")
    t.depth = get_depth(t.filename)
    t.type = item.type
    self.cache[t.filename] = t
  end
  return t
end


function TreeView:get_name()
  return "---"
end


function TreeView:get_item_height()
  return style.sidebar_font:get_height() + style.padding.y + math.floor(2 * SCALE)
end


-- uppercase, letter-spaced section label; returns the x after it
function TreeView:draw_label(text, x, y, h, color)
  local font = style.sidebar_label_font
  local gap = math.max(1, math.floor(SCALE))
  text = text:upper()
  for ch in text:gmatch(utf8.charpattern) do
    x = common.draw_text(font, color, ch, nil, x, y, 0, h) + gap
  end
  return x
end


function TreeView:get_label_width(text)
  local font = style.sidebar_label_font
  local gap = math.max(1, math.floor(SCALE))
  local w = 0
  for ch in text:upper():gmatch(utf8.charpattern) do
    w = w + font:get_width(ch) + gap
  end
  return w
end


-- small count/status badge; returns its width
function TreeView:draw_badge(text, x, y, h, color, right_aligned)
  local font = style.sidebar_label_font
  local px = math.floor(5 * SCALE)
  local bw = font:get_width(text) + px * 2
  local bh = font:get_height() + math.floor(2 * SCALE)
  if right_aligned then x = x - bw end
  local by = y + math.floor((h - bh) / 2)
  renderer.draw_rect(x, by, bw, bh, style.line_highlight)
  common.draw_text(font, color, text, "center", x, by, bw, bh)
  return bw
end


function TreeView:check_cache()
  if core.project_dir ~= self.last_project_dir then
    self.cache = {}
    self.hovered_item = nil
    self.scroll.to.y, self.scroll.y = 0, 0
    self.last_project_dir = core.project_dir
  end
  if core.project_files ~= self.last_project_files then
    for _, v in pairs(self.cache) do
      v.skip = nil
    end
    self.last_project_files = core.project_files
  end
end


-- tab strip pinned to the top of the panel (hidden with a single panel)
function TreeView:get_tabs_rect()
  local h = #self:get_shown_panels() > 1 and self:get_item_height() + style.padding.y or 0
  return self.position.x, self.position.y, self.size.x, h
end


-- where the scrolling content of the current panel starts
function TreeView:get_body_top()
  local _, oy = self:get_content_offset()
  local _, _, _, th = self:get_tabs_rect()
  return oy + th
end


function TreeView:get_header_rect()
  return self.position.x - self.scroll.x, self:get_body_top() + style.padding.y,
    self.size.x, self:get_item_height()
end


-- footer pinned to the bottom of the panel: the Byte wordmark
function TreeView:get_footer_rect()
  local h = self:get_item_height() + style.padding.y
  return self.position.x, self.position.y + self.size.y - h, self.size.x, h
end


-- content height recorded by draw(), plus room to scroll past the footer
function TreeView:get_scrollable_size()
  local _, _, _, fh = self:get_footer_rect()
  local _, _, _, th = self:get_tabs_rect()
  return (self.content_height or 0) + fh + th
end


function TreeView:get_header_close_rect()
  local x, y, w, h = self:get_header_rect()
  local size = style.sidebar_font:get_height()
  return x + w - size - style.padding.x, y + (h - size) / 2, size, size
end


local inside = common.point_in_rect


function TreeView:each_item()
  return coroutine.wrap(function()
    self:check_cache()
    local ox = self:get_content_offset()
    local _, hy, _, hh = self:get_header_rect()
    local y = hy + hh
    local w = self.size.x
    local h = self:get_item_height()

    local i = 1
    while i <= #core.project_files do
      local item = core.project_files[i]
      local cached = self:get_cached(item)

      coroutine.yield(cached, ox, y, w, h)
      y = y + h
      i = i + 1

      if not cached.expanded then
        if cached.skip then
          i = cached.skip
        else
          local depth = cached.depth
          while i <= #core.project_files do
            local filename = core.project_files[i].filename
            if get_depth(filename) <= depth then break end
            i = i + 1
          end
          cached.skip = i
        end
      end
    end
  end)
end


function TreeView:on_mouse_moved(px, py)
  TreeView.super.on_mouse_moved(self, px, py)
  self.hovered_item = nil
  self.hovered_tab = nil
  if inside(px, py, self:get_tabs_rect()) then
    self.hovered_header, self.hovered_header_close = false, false
    for _, t in ipairs(self.tab_rects or {}) do
      if inside(px, py, t.x, t.y, t.w, t.h) then self.hovered_tab = t.id end
    end
    return
  end
  if inside(px, py, self:get_footer_rect()) then
    self.hovered_header, self.hovered_header_close = false, false
    return
  end
  local panel = self:get_panel()
  if panel.on_mouse_moved then
    self.hovered_header, self.hovered_header_close = false, false
    return panel.on_mouse_moved(self, px, py)
  end
  self.hovered_header = core.project_dir and inside(px, py, self:get_header_rect())
  self.hovered_header_close = self.hovered_header and inside(px, py, self:get_header_close_rect())
  for item, x,y,w,h in self:each_item() do
    if px > x and py > y and px <= x + w and py <= y + h then
      self.hovered_item = item
      break
    end
  end
end


function TreeView:on_mouse_pressed(button, x, y, clicks)
  if self.hovered_tab then
    self:set_panel(self.hovered_tab)
    return
  end
  local panel = self:get_panel()
  if panel.on_mouse_pressed then
    if not inside(x, y, self:get_footer_rect()) then
      panel.on_mouse_pressed(self, button, x, y, clicks)
    end
    return
  end
  if not core.project_dir then
    command.perform("core:open-folder")
    return
  elseif button == "right" then
    local item = self.hovered_item
    self:show_file_menu(item and item.abs_filename, item and item.type, x, y)
    return
  elseif self.hovered_header_close then
    command.perform("core:close-folder")
    return
  elseif self.hovered_header then
    command.perform("core:open-folder")
    return
  elseif not self.hovered_item then
    return
  elseif self.hovered_item.type == "dir" then
    self.hovered_item.expanded = not self.hovered_item.expanded
  elseif button == "left" then
    -- opened on release so the file can be dragged into a split instead
    core.root_view:start_drag({ filename = self.hovered_item.filename }, x, y)
  end
end


-- dragging the divider between the sidebar and the editor resizes it
function TreeView:on_divider_dragged(delta)
  if not self.visible then return end
  local max = math.max(config.treeview_min_size, core.root_view.size.x * 0.7)
  config.treeview_size = common.clamp(config.treeview_size + delta,
    config.treeview_min_size, max)
  self.size.x = config.treeview_size
  self.resized_at = system.get_time()
  core.redraw = true
end


function TreeView:update()
  -- persist the width shortly after a drag ends
  if self.resized_at and system.get_time() - self.resized_at > 0.5 then
    self.resized_at = nil
    core.try(save_width)
  elseif self.resized_at then
    core.redraw = true
  end

  -- update width
  local dest = self.visible and config.treeview_size or 0
  if self.init_size then
    self.size.x = dest
    self.init_size = false
  else
    self:move_towards(self.size, "x", dest)
  end

  TreeView.super.update(self)
end


function TreeView:get_item_color(item, active, hovered)
  -- highlight active_view doc and hovered item
  if active or hovered then
    return style.accent
  end
  return style.text
end


-- `text`, shortened with "…" to fit `room` pixels; cached while unchanged
function TreeView:fit_label(text, room)
  local c = self.fit_cache
  local font = style.sidebar_label_font
  if c and c.text == text and c.room == room and c.font == font then return c.label end
  local label = text
  if self:get_label_width(label) > room then
    while #label > 0 and self:get_label_width(label .. "…") > room do
      -- drop one whole UTF-8 character
      label = label:sub(1, -2):gsub("[\128-\191]+$", ""):gsub("[\192-\255]$", "")
    end
    label = label .. "…"
  end
  self.fit_cache = { text = text, room = room, font = font, label = label }
  return label
end


function TreeView:draw()
  self:draw_background(style.background2)
  local panel = self:get_panel()
  if panel.draw then
    local top = self:get_body_top()
    local bottom = panel.draw(self, self.position.x - self.scroll.x, top, self.size.x)
    self.content_height = bottom - top + style.padding.y
  else
    self:draw_project()
  end
  self:draw_tabs()
  self:draw_footer()
end


function TreeView:draw_tabs()
  local x, y, w, h = self:get_tabs_rect()
  self.tab_rects = {}
  if h == 0 then return end
  renderer.draw_rect(x, y, w, h, style.background2)
  local panels = self:get_shown_panels()
  local tw = w / #panels
  for i, p in ipairs(panels) do
    local tx = x + math.floor((i - 1) * tw)
    local tw2 = math.floor(i * tw) - math.floor((i - 1) * tw)
    local active = p.id == self.panel
    if self.hovered_tab == p.id and not active then
      renderer.draw_rect(tx, y, tw2, h, style.line_highlight)
    end
    local color = (active or self.hovered_tab == p.id) and style.text or style.dim
    if p.icon then
      icons.draw(p.icon, color, tx, y, tw2, h)
    else
      common.draw_text(style.sidebar_tab_font, color, p.name, "center", tx, y, tw2, h)
    end
    if active then
      local bar = math.max(2, math.floor(2 * SCALE))
      renderer.draw_rect(tx, y + h - bar, tw2, bar, style.caret)
    end
    if i > 1 then renderer.draw_rect(tx, y, style.divider_size, h, style.divider) end
    self.tab_rects[i] = { id = p.id, x = tx, y = y, w = tw2, h = h }
  end
  renderer.draw_rect(x, y + h - style.divider_size, w, style.divider_size, style.divider)
end


function TreeView:draw_project()
  if not core.project_dir then
    -- no folder: a hint that doubles as a button (any click opens a folder)
    local _, y, _, h = self:get_header_rect()
    local x = self.position.x + style.padding.x
    common.draw_text(style.sidebar_font, style.dim, "No folder open", nil, x, y, 0, h)
    return
  end

  -- folder row: folder name and close button
  do
    local x, y, w, h = self:get_header_rect()
    if self.hovered_header and not self.hovered_header_close then
      renderer.draw_rect(x, y, w, h, style.line_highlight)
    end
    local cx, cy, cw, ch = self:get_header_close_rect()
    local name = common.basename(core.project_dir)
    core.push_clip_rect(x, y, cx - x, h)
    -- folder name as a section label, shortened with "…" if it doesn't fit
    local lx = x + style.padding.x
    local room = cx - lx - style.padding.x / 2
    local color = self.hovered_header and style.accent or style.text
    self:draw_label(self:fit_label(name, room), lx, y, h, color)
    core.pop_clip_rect()
    if self.hovered_header_close then
      renderer.draw_rect(cx, cy, cw, ch, style.line_highlight)
    end
    common.draw_text(style.sidebar_font, self.hovered_header_close and style.accent or style.dim,
      "×", "center", cx, cy, cw, ch)
  end

  local icon_width = style.icon_font:get_width("D")
  local spacing = style.sidebar_font:get_width(" ")
  local guide_color = { style.dim[1], style.dim[2], style.dim[3], 110 }
  local chevron_w = style.icon_font:get_width("+")
  local accent_bar = math.max(2, math.floor(2 * SCALE))

  local doc = core.active_view.doc
  local active_filename = doc and system.absolute_path(doc.filename or "")

  local content_top = self:get_body_top()
  local _, hy, _, hh = self:get_header_rect()
  local bottom = hy + hh
  for item, x,y,w,h in self:each_item() do
    bottom = y + h
    local active = item.abs_filename == active_filename
    local hovered = item == self.hovered_item
    local color = self:get_item_color(item, active, hovered)

    -- active / hovered item background
    if active then
      renderer.draw_rect(x, y, w, h, style.line_highlight)
      renderer.draw_rect(x, y, accent_bar, h, style.caret)
    elseif hovered then
      renderer.draw_rect(x, y, w, h, style.line_highlight)
    end

    -- indent guides, one per ancestor folder
    for d = 0, item.depth - 1 do
      local gx = x + d * style.padding.x + style.padding.x + math.floor(chevron_w / 2)
      renderer.draw_rect(gx, y, style.divider_size, h, guide_color)
    end

    -- icons
    x = x + item.depth * style.padding.x + style.padding.x
    if item.type == "dir" then
      local icon1 = item.expanded and "-" or "+"
      local icon2 = item.expanded and "D" or "d"
      common.draw_text(style.icon_font, color, icon1, nil, x, y, 0, h)
      x = x + style.padding.x
      common.draw_text(style.icon_font, color, icon2, nil, x, y, 0, h)
      x = x + icon_width
    else
      x = x + style.padding.x
      common.draw_text(style.icon_font, color, "f", nil, x, y, 0, h)
      x = x + icon_width
    end

    -- text
    x = x + spacing
    x = common.draw_text(style.sidebar_font, color, item.name, nil, x, y, 0, h)
  end
  self.content_height = bottom - content_top + style.padding.y
end


-- the Byte wordmark, pinned to the bottom of the panel over the file list
function TreeView:draw_footer()
  local x, y, w, h = self:get_footer_rect()
  renderer.draw_rect(x, y, w, h, style.background2)
  renderer.draw_rect(x, y, w, style.divider_size, style.divider)
  local lh = math.min(h - 4, style.sidebar_font:get_height() + 2)
  logo.draw_wordmark(x + style.padding.x, y + math.floor((h - lh) / 2), lh, style.accent)
end


-- file operations for the right-click menu
local function check(ok, err)
  if not ok then error(err, 0) end
end

local function delete_path(path)
  local info = system.get_file_info(path)
  if info and info.type == "dir" then
    for _, name in ipairs(system.list_dir(path) or {}) do
      delete_path(path .. PATHSEP .. name)
    end
  end
  check(system.remove(path))
end

local function copy_path(src, dst)
  local info = system.get_file_info(src)
  if info and info.type == "dir" then
    check(system.mkdir(dst))
    for _, name in ipairs(system.list_dir(src) or {}) do
      copy_path(src .. PATHSEP .. name, dst .. PATHSEP .. name)
    end
  else
    check(system.copy_file(src, dst))
  end
end

local function ask_path(label, text, fn)
  core.command_view:set_text(text)
  core.command_view:enter(label, function(path)
    if path == "" then return end
    if system.get_file_info(path) then
      core.error("%s already exists", path)
      return
    end
    core.try(fn, path)
    core.rescan_project()
  end, common.path_suggest)
end

-- menu for `path` (nil: the project folder); `type` is "dir" or "file"
function TreeView:show_file_menu(path, type, x, y)
  local dir = path and (type == "dir" and path or common.dirname(path)) or core.project_dir
  local items = {}
  if path then
    table.insert(items, { "Copy", function()
      ask_path("Copy To", path, function(dst) copy_path(path, dst) end)
    end })
    table.insert(items, { "Move", function()
      ask_path("Move To", path, function(dst) check(system.rename(path, dst)) end)
    end })
    table.insert(items, { "Delete", function()
      local name = common.basename(path)
      if system.show_confirm_dialog("Delete", "Permanently delete \"" .. name .. "\"?") then
        core.try(delete_path, path)
        core.rescan_project()
      end
    end })
  end
  table.insert(items, { "New File", function()
    ask_path("New File", dir .. PATHSEP, function(file)
      local fp = assert(io.open(file, "w"))
      fp:close()
      core.root_view:open_doc(core.open_doc(file))
    end)
  end })
  table.insert(items, { "New Directory", function()
    ask_path("New Directory", dir .. PATHSEP, function(d) check(system.mkdir(d)) end)
  end })
  ContextMenu.show(items, x, y)
end


-- init
local view = TreeView()
local node = core.root_view:get_active_node()
node:split("left", view, true)

-- register commands and keymap
command.add(nil, {
  ["treeview:toggle"] = function()
    view.visible = not view.visible
  end,

  ["treeview:show-project"] = function()
    view.visible = true
    view:set_panel("project")
  end,
})

keymap.add { ["ctrl+\\"] = "treeview:toggle" }

return view
