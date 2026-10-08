local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local logo = require "core.logo"

config.treeview_size = 200 * SCALE

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
  return style.font:get_height() + style.padding.y
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


function TreeView:get_header_rect()
  local ox, oy = self:get_content_offset()
  return ox, oy + style.padding.y, self.size.x, self:get_item_height()
end


-- footer pinned to the bottom of the panel: the Byte wordmark
function TreeView:get_footer_rect()
  local h = self:get_item_height() + style.padding.y
  return self.position.x, self.position.y + self.size.y - h, self.size.x, h
end


-- content height recorded by draw(), plus room to scroll past the footer
function TreeView:get_scrollable_size()
  local _, _, _, fh = self:get_footer_rect()
  return (self.content_height or 0) + fh
end


function TreeView:get_header_close_rect()
  local x, y, w, h = self:get_header_rect()
  local size = style.font:get_height()
  return x + w - size - style.padding.x, y + (h - size) / 2, size, size
end


local inside = common.point_in_rect


function TreeView:each_item()
  return coroutine.wrap(function()
    self:check_cache()
    local ox, oy = self:get_content_offset()
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
  if inside(px, py, self:get_footer_rect()) then
    self.hovered_header, self.hovered_header_close = false, false
    return
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


function TreeView:on_mouse_pressed(button, x, y)
  if not core.project_dir then
    command.perform("core:open-folder")
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
  else
    core.try(function()
      core.root_view:open_doc(core.open_doc(self.hovered_item.filename))
    end)
  end
end


function TreeView:update()
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
  if c and c.text == text and c.room == room and c.font == style.font then return c.label end
  local label = text
  if style.font:get_width(label) > room then
    while #label > 0 and style.font:get_width(label .. "…") > room do
      -- drop one whole UTF-8 character
      label = label:sub(1, -2):gsub("[\128-\191]+$", ""):gsub("[\192-\255]$", "")
    end
    label = label .. "…"
  end
  self.fit_cache = { text = text, room = room, font = style.font, label = label }
  return label
end


function TreeView:draw()
  self:draw_background(style.background2)

  if not core.project_dir then
    -- no folder: a hint that doubles as a button (any click opens a folder)
    local _, y, _, h = self:get_header_rect()
    local x = self.position.x + style.padding.x
    common.draw_text(style.font, style.dim, "No folder open", nil, x, y, 0, h)
    local binding = keymap.get_binding("core:open-folder")
    local label = "Open Folder" .. (binding and ("  (" .. binding .. ")") or "")
    common.draw_text(style.font, style.accent, label, nil, x, y + h, 0, h)
    self:draw_footer()
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
    -- folder name, shortened with "…" if it doesn't fit
    local lx = x + style.padding.x
    local room = cx - lx - style.padding.x / 2
    common.draw_text(style.font, style.accent, self:fit_label(name, room), nil, lx, y, 0, h)
    core.pop_clip_rect()
    if self.hovered_header_close then
      renderer.draw_rect(cx, cy, cw, ch, style.line_highlight)
    end
    common.draw_text(style.font, self.hovered_header_close and style.accent or style.dim,
      "×", "center", cx, cy, cw, ch)
  end

  local icon_width = style.icon_font:get_width("D")
  local spacing = style.font:get_width(" ") * 2

  local doc = core.active_view.doc
  local active_filename = doc and system.absolute_path(doc.filename or "")

  local _, content_top = self:get_content_offset()
  local _, hy, _, hh = self:get_header_rect()
  local bottom = hy + hh
  for item, x,y,w,h in self:each_item() do
    bottom = y + h
    local active = item.abs_filename == active_filename
    local hovered = item == self.hovered_item
    local color = self:get_item_color(item, active, hovered)

    -- hovered item background
    if hovered then
      renderer.draw_rect(x, y, w, h, style.line_highlight)
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
    x = common.draw_text(style.font, color, item.name, nil, x, y, 0, h)
  end
  self.content_height = bottom - content_top + style.padding.y

  self:draw_footer()
end


-- the Byte wordmark, pinned to the bottom of the panel over the file list
function TreeView:draw_footer()
  local x, y, w, h = self:get_footer_rect()
  renderer.draw_rect(x, y, w, h, style.background2)
  renderer.draw_rect(x, y, w, style.divider_size, style.divider)
  local lh = math.min(h - 4, style.font:get_height() + 2)
  logo.draw_wordmark(x + style.padding.x, y + math.floor((h - lh) / 2), lh, style.accent)
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
})

keymap.add { ["ctrl+\\"] = "treeview:toggle" }

return view
