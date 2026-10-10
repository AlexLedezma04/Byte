local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local DocView = require "core.docview"

config.minimap = config.minimap ~= false
config.minimap_width = config.minimap_width or 110 * SCALE

local LINE_H = math.max(2, math.floor(2 * SCALE))
local CHAR_W = math.max(1, SCALE)

function DocView:minimap_row_count() return #self.doc.lines end
function DocView:minimap_each_token(row) return self.doc.highlighter:each_token(row) end
function DocView:minimap_caret_row() return (self.doc:get_selection()) end
function DocView:minimap_rows_offset() return style.padding.y end
function DocView:minimap_header_height() return 0 end

if not DocView.minimap_marks then
  function DocView:minimap_marks() return {} end
end

local function enabled(dv)
  return config.minimap and (getmetatable(dv) == DocView or dv.has_minimap)
    and dv.size.x > config.minimap_width * 4
end

local function get_rect(dv)
  local w = config.minimap_width
  local hh = dv:minimap_header_height()
  return dv.position.x + dv.size.x - style.scrollbar_size - w, dv.position.y + hh, w, dv.size.y - hh
end

local function get_top(dv)
  local n = dv:minimap_row_count()
  local _, _, _, h = get_rect(dv)
  local fits = math.floor(h / LINE_H)
  if n <= fits then return 1 end
  local max = dv:get_scrollable_size() - dv.size.y
  local ratio = max > 0 and common.clamp(dv.scroll.y / max, 0, 1) or 0
  return 1 + math.floor(ratio * (n - fits))
end

local function scroll_to_point(dv, y)
  local _, ry, _, h = get_rect(dv)
  local n = dv:minimap_row_count()
  local lh = dv:get_line_height()
  local row
  if n <= math.floor(h / LINE_H) then
    row = (y - ry) / LINE_H + 1
  else
    row = common.clamp((y - ry) / h, 0, 1) * n + 1
  end
  dv.scroll.to.y = dv:minimap_rows_offset() + (row - 1) * lh - dv.size.y / 2
end

function DocView:get_minimap_width()
  return enabled(self) and config.minimap_width or 0
end


local old_limit = DocView.get_h_scroll_limit
function DocView:get_h_scroll_limit()
  local limit = old_limit(self)
  if not enabled(self) then return limit end
  local visible = self.size.x - self:get_gutter_width() - style.scrollbar_size
  local margin = self:get_font():get_width(" ") * 4
  return math.max(0, self:get_max_line_width() + margin - (visible - config.minimap_width))
end


local function alpha(c, a)
  return { c[1], c[2], c[3], a }
end

local function draw_pill(x, y, w, h, color)
  local r = math.min(math.floor(w / 2), math.floor(h / 2), math.floor(SCALE + 0.5))
  if r < 1 or w < 4 or h <= r * 2 then return renderer.draw_rect(x, y, w, h, color) end
  renderer.draw_rect(x + r, y, w - r * 2, r, color)
  renderer.draw_rect(x, y + r, w, h - r * 2, color)
  renderer.draw_rect(x + r, y + h - r, w - r * 2, r, color)
end


local old_draw = DocView.draw
function DocView:draw()
  old_draw(self)
  self:draw_minimap()
end

function DocView:draw_minimap()
  if not enabled(self) then return end
  local x, y, w, h = get_rect(self)
  local bg, t = style.background, style.text
  renderer.draw_rect(x, y, w, h, bg)
  renderer.draw_rect(x, y, w, h, alpha(t, 6))
  core.push_clip_rect(x, y, w, h)

  local top = get_top(self)
  local last = math.min(self:minimap_row_count(), top + math.floor(h / LINE_H))
  local gutter = math.floor(8 * SCALE)
  local pad = math.floor(4 * SCALE)
  local max_cols = math.floor((w - gutter - pad) / CHAR_W)
  local tab = config.indent_size

  local lh = self:get_line_height()
  local first = (self.scroll.y - self:minimap_rows_offset()) / lh + 1
  local vy = math.floor(y + (first - top) * LINE_H)
  local vh = math.max(LINE_H, math.floor(self.size.y / lh * LINE_H))
  if vy < y then vh, vy = math.max(LINE_H, vh - (y - vy)), y end
  local active = self.hovering_minimap or self.dragging_minimap
  renderer.draw_rect(x, vy, w, vh, alpha(t, active and 28 or 14))

  local caret = self:minimap_caret_row()
  if caret and caret >= top and caret <= last then
    renderer.draw_rect(x + gutter, y + (caret - top) * LINE_H, w - gutter, LINE_H, alpha(style.caret, 70))
  end

  local block_h = math.max(1, LINE_H - math.max(1, math.floor(SCALE / 2 + 0.5)))
  local tx = x + gutter
  local ly = y
  for i = top, last do
    local col = 0
    for _, type, text in self:minimap_each_token(i) do
      local color = alpha(style.syntax[type] or t, type == "comment" and 70 or 115)
      local run_start
      for ch in text:gmatch(utf8.charpattern) do
        if col >= max_cols then break end
        local space = ch == " " or ch == "\t" or ch == "\n" or ch == "\r"
        if space and run_start then
          renderer.draw_rect(tx + run_start * CHAR_W, ly, (col - run_start) * CHAR_W, block_h, color)
          run_start = nil
        elseif not space and not run_start then
          run_start = col
        end
        col = col + (ch == "\t" and tab or 1)
      end
      if run_start then
        renderer.draw_rect(tx + run_start * CHAR_W, ly, (col - run_start) * CHAR_W, block_h, color)
      end
      if col >= max_cols then break end
    end
    ly = ly + LINE_H
  end

  local bw = math.max(2, math.floor(3 * SCALE))
  local bx = x + math.floor(2 * SCALE)
  for _, m in ipairs(self:minimap_marks()) do
    local my = math.floor(y + (m.start - top) * LINE_H)
    if m.count == 0 then
      local th = math.max(1, math.floor(SCALE))
      for k = 0, 2 do
        renderer.draw_rect(bx, my - th * 2 + k * th, bw + (2 - k) * th * 2, th, m.color)
      end
    else
      draw_pill(bx, my, bw, math.max(LINE_H * 2, m.count * LINE_H), m.color)
    end
  end

  core.pop_clip_rect()
end


local old_pressed = DocView.on_mouse_pressed
function DocView:on_mouse_pressed(button, x, y, clicks)
  if enabled(self) and common.point_in_rect(x, y, get_rect(self)) then
    if button == "left" then
      self.dragging_minimap = true
      scroll_to_point(self, y)
    end
    return true
  end
  return old_pressed(self, button, x, y, clicks)
end


local old_moved = DocView.on_mouse_moved
function DocView:on_mouse_moved(x, y, ...)
  if self.dragging_minimap then
    scroll_to_point(self, y)
    self.cursor = "arrow"
    return
  end
  old_moved(self, x, y, ...)
  local over = enabled(self) and common.point_in_rect(x, y, get_rect(self))
  if over ~= self.hovering_minimap then self.hovering_minimap = over; core.redraw = true end
  if over then self.cursor = "arrow" end
end


local old_released = DocView.on_mouse_released
function DocView:on_mouse_released(...)
  self.dragging_minimap = false
  return old_released(self, ...)
end
