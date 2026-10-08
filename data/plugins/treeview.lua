local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local logo = require "core.logo"

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
  self.panels = { { id = "project", name = "Project" } }
  self.panel = "project"
  self.panel_scroll = {}
end


-- `panel` = { id, name, draw(view, x, y, w) -> content height,
--   on_mouse_moved(view, x, y), on_mouse_pressed(view, button, x, y, clicks) }
function TreeView:add_panel(panel)
  table.insert(self.panels, panel)
  core.redraw = true
end


function TreeView:get_panel()
  for _, p in ipairs(self.panels) do
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
  local h = #self.panels > 1 and self:get_item_height() + style.padding.y or 0
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
  local tw = w / #self.panels
  for i, p in ipairs(self.panels) do
    local tx = x + math.floor((i - 1) * tw)
    local tw2 = math.floor(i * tw) - math.floor((i - 1) * tw)
    local active = p.id == self.panel
    if self.hovered_tab == p.id and not active then
      renderer.draw_rect(tx, y, tw2, h, style.line_highlight)
    end
    local color = active and style.accent or style.dim
    common.draw_text(style.sidebar_tab_font, color, p.name, "center", tx, y, tw2, h)
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
