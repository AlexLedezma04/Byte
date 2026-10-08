local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local StatusView = require "core.statusview"

local ok_native, libterminal = pcall(require, "libterminal")
if not ok_native then
  core.error("terminal: this Byte build has no libterminal module")
  return
end

local is_windows = PATHSEP == "\\"

local default_shell = os.getenv("SHELL")
  or (is_windows and (os.getenv("COMSPEC") or "c:\\windows\\system32\\cmd.exe"))
  or "sh"

local defaults = {
  shell = default_shell,
  arguments = {},
  environment = {},
  term = "xterm-256color",
  scrollback_limit = 10000,
  drawer_height = 250 * SCALE,
  inversion_key = "shift",
  omit_escapes = nil,
  newline = default_shell:find("cmd.exe") and "\r\n" or "\r",
  backspace = "\x7F",
  delete = "\x1B[3~",
  padding = { x = 8 * SCALE, y = 4 * SCALE },
  minimum_contrast_ratio = 3,
  bold_text_in_bright_colors = true,
  scrolling_speed = 0.01,
  debug = false,
}
config.terminal = config.terminal or {}
for k, v in pairs(defaults) do
  if config.terminal[k] == nil then config.terminal[k] = v end
end
local cfg = config.terminal

-- colors (override with style.terminal_* or config.terminal.colors)
local function palette()
  if cfg.colors then return cfg.colors end
  local hex = {
    "#000000", "#aa0000", "#44aa44", "#aa5500", "#0039aa", "#aa22aa", "#1a92aa", "#aaaaaa",
    "#777777", "#ff8787", "#4ce64c", "#ded82c", "#295fcc", "#cc58cc", "#4ccce6", "#ffffff",
  }
  local colors = {}
  for i, h in ipairs(hex) do colors[i - 1] = { common.color(h) } end
  -- 6x6x6 color cube
  local steps = { 0, 95, 135, 175, 215, 255 }
  for i = 0, 215 do
    local r, g, b = math.floor(i / 36), math.floor(i / 6) % 6, i % 6
    colors[16 + i] = { steps[r + 1], steps[g + 1], steps[b + 1], 255 }
  end
  -- grayscale ramp
  for i = 0, 23 do
    local v = 8 + i * 10
    colors[232 + i] = { v, v, v, 255 }
  end
  cfg.colors = colors
  return colors
end

local function background() return style.terminal_background or style.background end
local function foreground() return style.terminal_text or style.syntax.normal end
local function font() return style.terminal_font or style.code_font end


-- utf-8 helpers (Byte has no string.ulen / string.usub)
local function ulen(s)
  local _, n = s:gsub("[^\128-\191]", "")
  return n
end

local function usub(s, i, j)
  local n = ulen(s)
  j = j or n
  if i < 0 then i = n + i + 1 end
  if j < 0 then j = n + j + 1 end
  if i < 1 then i = 1 end
  if j > n then j = n end
  if i > j then return "" end
  local pos, ci, bi, bj = 1, 0, nil, #s
  while pos <= #s do
    ci = ci + 1
    if ci == i then bi = pos end
    local c = s:byte(pos)
    local len = c >= 0xF0 and 4 or c >= 0xE0 and 3 or c >= 0xC0 and 2 or 1
    if ci == j then bj = pos + len - 1; break end
    pos = pos + len
  end
  return s:sub(bi or 1, bj)
end


-- color handling
local function contrast_ratio(l1, l2)
  if l1 < l2 then return (l2 + 0.05) / (l1 + 0.05) end
  return (l1 + 0.05) / (l2 + 0.05)
end

local function luminance(c)
  local function ch(v)
    v = v / 255
    return v <= 0.03928 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4
  end
  return ch(c[1]) * 0.2126 + ch(c[2]) * 0.7152 + ch(c[3]) * 0.0722
end

local function reduce_luminance(bg, fg, ratio)
  local bgl = luminance(bg)
  local n = { fg[1], fg[2], fg[3], fg[4] or 255 }
  local cr = contrast_ratio(luminance(n), bgl)
  while cr < ratio and (n[1] > 0 or n[2] > 0 or n[3] > 0) do
    for k = 1, 3 do n[k] = n[k] - math.max(0, math.ceil(n[k] * 0.1)) end
    cr = contrast_ratio(luminance(n), bgl)
  end
  return n
end

local function increase_luminance(bg, fg, ratio)
  local bgl = luminance(bg)
  local n = { fg[1], fg[2], fg[3], fg[4] or 255 }
  local cr = contrast_ratio(luminance(n), bgl)
  while cr < ratio and (n[1] < 255 or n[2] < 255 or n[3] < 255) do
    for k = 1, 3 do n[k] = math.min(255, n[k] + math.ceil((255 - n[k]) * 0.1)) end
    cr = contrast_ratio(luminance(n), bgl)
  end
  return n
end

local function ensure_contrast(bg, fg, ratio)
  local bgl, fgl = luminance(bg), luminance(fg)
  if contrast_ratio(bgl, fgl) >= ratio then return fg end
  local first, second = increase_luminance, reduce_luminance
  if fgl < bgl then first, second = reduce_luminance, increase_luminance end
  local a = first(bg, fg, ratio)
  local ar = contrast_ratio(bgl, luminance(a))
  if ar >= ratio then return a end
  local b = second(bg, fg, ratio)
  return ar > contrast_ratio(bgl, luminance(b)) and a or b
end

-- a color from libterminal is a 32-bit number: attributes << 24 | r << 16 | g << 8 | b
local function decode(v, target, bright)
  local attr = math.floor(v / 16777216)
  local kind = attr % 8
  local bold = math.floor(attr / 8) % 2 == 1
  if kind == 2 then
    local index = math.floor(v / 65536) % 256
    if index < 8 and bright and bold then index = index + 8 end
    return palette()[index] or foreground(), bold
  elseif kind == 3 then
    return { math.floor(v / 65536) % 256, math.floor(v / 256) % 256, v % 256, 255 }, bold
  elseif kind == 1 then
    return target == "fg" and background() or foreground(), bold
  end
  return target == "fg" and foreground() or background(), bold
end

-- contrast-adjusted foreground per (background, foreground) color value;
-- number keys, so the per-frame lookup allocates nothing
local contrast_cache = {}
local function cell_colors(fgv, bgv)
  local bg = decode(bgv, "bg")
  local fg = decode(fgv, "fg", cfg.bold_text_in_bright_colors)
  if (cfg.minimum_contrast_ratio or 0) > 0 then
    local by_bg = contrast_cache[bgv]
    if not by_bg then by_bg = {}; contrast_cache[bgv] = by_bg end
    local c = by_bg[fgv]
    if not c then c = ensure_contrast(bg, fg, cfg.minimum_contrast_ratio); by_bg[fgv] = c end
    fg = c
  end
  return fg, bg
end


-- TerminalView
local TerminalView = View:extend()

local BLINK_PERIOD = 0.8

function TerminalView:new(drawer)
  TerminalView.super.new(self)
  self.drawer = drawer
  self.cursor = "ibeam"
  self.scrollable = true
  self.focused = false
  self.modified_since_last_focus = false
  self.blink_start = system.get_time()
  if drawer then
    self.visible = false
    self.height = cfg.drawer_height
    self.size.y = 0
  end
end

function TerminalView:get_name()
  local name = self.terminal and self.terminal:name() or "Terminal"
  return (self.modified_since_last_focus and "* " or "") .. name
end

function TerminalView:get_cell_size()
  return font():get_width("W"), font():get_height()
end

function TerminalView:get_grid_size()
  local cw, lh = self:get_cell_size()
  local h = self.drawer and self.height or self.size.y
  local cols = math.floor((self.size.x - cfg.padding.x * 2 - style.scrollbar_size) / cw)
  local lines = math.floor((h - cfg.padding.y * 2) / lh)
  return math.max(cols, 1), math.max(lines, 1)
end

function TerminalView:spawn()
  local env = {}
  for k, v in pairs(cfg.environment) do env[k] = type(v) == "function" and v() or v end
  env.PWD = env.PWD or system.absolute_path(".")
  if is_windows then
    local all, t = libterminal.getenv(), {}
    for k, v in pairs(env) do all[k] = v end
    for k, v in pairs(all) do t[#t + 1] = k .. "=" .. v end
    env = table.concat(t, "\0") .. "\0\0"
  end
  self.columns, self.lines = self:get_grid_size()
  self.terminal = libterminal.new(self.columns, self.lines, cfg.scrollback_limit, cfg.term,
    cfg.shell, cfg.arguments, env, cfg.debug)
  self.selection = nil

  -- poll the shell; weak so a closed view can be collected
  local weak = setmetatable({ view = self }, { __mode = "v" })
  core.add_thread(function()
    while weak.view and weak.view.terminal do
      if weak.view:poll() then core.redraw = true end
      coroutine.yield(1 / config.fps)
    end
  end, self)
end

-- reads pending shell output; returns true if anything changed
function TerminalView:poll()
  local shifts = self.terminal:update()
  if not shifts then return false end
  if not self.focused then self.modified_since_last_focus = true end
  if self.selection then
    self.selection[2] = self.selection[2] - shifts
    self.selection[4] = self.selection[4] - shifts
    if math.abs(math.min(self.selection[2], self.selection[4])) > cfg.scrollback_limit then
      self.selection = nil
    end
  end
  return true
end

function TerminalView:shell_exited()
  self.terminal = nil
  self.selection = nil
  if self.drawer then
    -- keep the drawer node; the next open starts a new shell
    self.visible = false
    if core.active_view == self then core.set_active_view(self.return_view or core.last_active_view) end
  else
    self:close_tab()
  end
  core.redraw = true
end

function TerminalView:close_tab()
  local root = core.root_view.root_node
  local node = root:get_node_for_view(self)
  if not node then return end
  self.closing = true
  node:set_active_view(self)
  node:close_active_view(root)
end

function TerminalView:try_close(do_close)
  if self.terminal then self.terminal:close() end
  self.terminal = nil
  do_close()
end

function TerminalView:update()
  if self.drawer then
    local dest = self.visible and self.height or 0
    if math.abs(self.size.y - dest) < 1 then
      self.size.y = dest
    else
      self:move_towards(self.size, "y", dest)
    end
  end

  local shown = self.size.x > 0 and self.size.y > 0
  if shown and not self.terminal and (not self.drawer or self.visible) and not self.closing then
    self:spawn()
  end

  if self.terminal then
    local exited = self.terminal:exited()
    if exited ~= false then
      self:shell_exited()
      return
    end

    -- resize the grid
    local cols, lines = self:get_grid_size()
    if shown and (cols ~= self.columns or lines ~= self.lines) then
      self.columns, self.lines = cols, lines
      self.terminal:size(cols, lines)
    end

    -- focus reporting
    local focused = core.active_view == self
    if focused ~= self.focused then
      self.focused = focused
      self.modified_since_last_focus = false
      self.terminal:focused(focused)
      self.blink_start = system.get_time()
    end

    -- cursor blink
    if focused then
      local _, _, mode = self.terminal:cursor()
      if mode == "blinking" then
        local on = (system.get_time() - self.blink_start) % BLINK_PERIOD < BLINK_PERIOD / 2
        if on ~= self.blink_on then self.blink_on = on; core.redraw = true end
      end
    end

    -- keep scrolling while drag-selecting outside the view
    if self.scrolling_offscreen and (not self.last_scroll_time
        or system.get_time() - self.last_scroll_time > cfg.scrolling_speed) then
      self.last_scroll_time = system.get_time()
      self.terminal:scrollback(self.terminal:scrollback() + self.scrolling_offscreen)
      core.redraw = true
    end

    -- mirror the scrollback position into the view scroll so the scrollbar works
    local _, lh = self:get_cell_size()
    local scrollback, total = self.terminal:scrollback()
    if self.dragging_scrollbar then
      local target = total - math.floor(self.scroll.to.y / lh + 0.5)
      self.terminal:scrollback(common.clamp(target, 0, total))
    else
      self.scroll.to.y = (total - scrollback) * lh
      self.scroll.y = self.scroll.to.y
    end
    self.scroll.to.y = common.clamp(self.scroll.to.y, 0, total * lh)
  end

  self.cursor = (self.terminal and self.terminal:mouse_tracking_mode()) and "arrow" or "ibeam"
  if self.hovered_scrollbar or self.dragging_scrollbar then self.cursor = "arrow" end
end

function TerminalView:get_scrollable_size()
  if not self.terminal then return self.size.y end
  local _, lh = self:get_cell_size()
  local _, total = self.terminal:scrollback()
  return total * lh + self.size.y
end

function TerminalView:sorted_selection()
  local s = self.selection
  if not s or #s < 4 then return nil end
  if s[2] > s[4] or (s[2] == s[4] and s[1] > s[3]) then return { s[3], s[4], s[1], s[2] } end
  return { s[1], s[2], s[3], s[4] }
end

-- splits a run of text into { bg, fg, text } sections for selection and cursor
local function split_sections(text, length, offset, idx, sel, fg, bg, cursor_x)
  local sections = { { bg, fg, text } }
  if sel then
    local s1, l1, s2, l2 = sel[1], sel[2], sel[3], sel[4]
    local starts_before = l1 < idx or (l1 == idx and s1 <= offset)
    local ends_after = l2 > idx or (l2 == idx and s2 >= offset + length)
    if starts_before and ends_after then
      sections = { { fg, bg, text } }
    elseif l1 == idx and l2 == idx and s1 > offset and s2 < offset + length then
      sections = {
        { bg, fg, usub(text, 1, s1 - offset) },
        { fg, bg, usub(text, s1 - offset + 1, s2 - offset) },
        { bg, fg, usub(text, s2 - offset + 1, length) },
      }
    elseif starts_before and l2 == idx and s2 < offset + length and s2 >= offset then
      sections = { { fg, bg, usub(text, 1, s2 - offset) }, { bg, fg, usub(text, s2 - offset + 1, length) } }
    elseif l1 == idx and s1 < offset + length and s1 >= offset and ends_after then
      sections = { { bg, fg, usub(text, 1, s1 - offset) }, { fg, bg, usub(text, s1 - offset + 1, length) } }
    end
  end
  if cursor_x and cursor_x >= offset and cursor_x < offset + length then
    local out, local_offset = {}, offset
    for _, sec in ipairs(sections) do
      local len = ulen(sec[3])
      if cursor_x >= local_offset and cursor_x < local_offset + len then
        local at = cursor_x - local_offset
        if at > 0 then out[#out + 1] = { sec[1], sec[2], usub(sec[3], 1, at) } end
        out[#out + 1] = { sec[2], sec[1], usub(sec[3], at + 1, at + 1) }
        if at < len - 1 then out[#out + 1] = { sec[1], sec[2], usub(sec[3], at + 2) } end
      else
        out[#out + 1] = sec
      end
      local_offset = local_offset + len
    end
    sections = out
  end
  return sections
end

function TerminalView:draw()
  self:draw_background(background())
  if not self.terminal or self.size.y < 1 then return end
  local f = font()
  local cw, lh = self:get_cell_size()
  local cursor_x, cursor_y, mode = self.terminal:cursor()
  local scrollback = self.terminal:scrollback()
  local show_cursor = mode ~= "hidden" and core.active_view == self and scrollback == 0
    and (mode ~= "blinking" or (system.get_time() - self.blink_start) % BLINK_PERIOD < BLINK_PERIOD / 2)
  local sel = self:sorted_selection()
  local default_bg = background()

  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  local y = self.position.y + cfg.padding.y
  for line_idx, line in ipairs(self.terminal:lines()) do
    if y > self.position.y + self.size.y then break end
    local x = self.position.x + cfg.padding.x
    local offset = 0
    local idx = (line_idx - 1) - scrollback
    local cx = show_cursor and line_idx - 1 == cursor_y and cursor_x or nil
    for i = 1, #line, 3 do
      local fg, bg = cell_colors(line[i], line[i + 1])
      local text = line[i + 2]:gsub("\n$", "")
      local length = ulen(text)
      if cx and i + 2 >= #line and cx >= offset + length then
        text = text .. string.rep(" ", cx - offset - length + 1)
        length = ulen(text)
      end
      for _, sec in ipairs(split_sections(text, length, offset, idx, sel, fg, bg, cx)) do
        local sbg, sfg, stext = sec[1], sec[2], sec[3]
        if stext ~= "" then
          local w = ulen(stext) * cw
          if sbg ~= default_bg then renderer.draw_rect(x, y, w, lh, sbg) end
          renderer.draw_text(f, stext, x, y, sfg)
          x = x + w
        end
      end
      offset = offset + length
    end
    y = y + lh
  end
  core.pop_clip_rect()
  self:draw_scrollbar()
end

function TerminalView:convert_coordinates(x, y)
  local cw, lh = self:get_cell_size()
  local col_exact = math.floor((x - self.position.x - cfg.padding.x) / cw)
  local col_approx = common.round((x - self.position.x - cfg.padding.x) / cw)
  local row = math.floor((y - self.position.y - cfg.padding.y) / lh)
  return math.max(0, col_exact), math.max(0, row), math.max(0, col_approx)
end

function TerminalView:get_line_text(row)
  local line = self.terminal:lines()[row + 1]
  if not line then return nil end
  local t = {}
  for i = 1, #line, 3 do t[#t + 1] = line[i + 2] end
  return (table.concat(t):gsub("\n$", ""))
end

function TerminalView:get_word_boundaries(col, row)
  local text = self:get_line_text(row)
  if not text then return end
  row = row - self.terminal:scrollback()
  if text:sub(col + 1, col + 1):match("%s") then return col, row, col + 1, row end
  local next_space = text:find("%s", col + 1) or (#text + 1)
  local last_space = 0
  local idx = text:reverse():find("%s", #text - col)
  if idx then last_space = #text - idx + 1 end
  return last_space, row, next_space - 1, row
end

function TerminalView:send_mouse(button_code, col, row, release)
  local mode = self.terminal:mouse_tracking_mode()
  if mode == "sgr" then
    self.terminal:input("\x1B[<" .. button_code .. ";" .. (col + 1) .. ";" .. (row + 1) .. (release and "m" or "M"))
  elseif mode == "normal" or (mode == "x10" and not release) then
    local b = release and 3 or button_code
    self.terminal:input("\x1B[M" .. string.char(32 + b) .. string.char(32 + col + 1) .. string.char(32 + row + 1))
  end
end

local function inverted()
  return cfg.inversion_key and keymap.modkeys[cfg.inversion_key]
end

function TerminalView:on_mouse_pressed(button, x, y, clicks)
  if TerminalView.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  if not self.terminal then return end
  local col, row = self:convert_coordinates(x, y)
  if button == "middle" then
    command.perform("terminal:paste")
    return true
  end
  if button ~= "left" then return end
  if not inverted() and self.terminal:mouse_tracking_mode() then
    self:send_mouse(0, col, row)
    return true
  end
  local n = (clicks - 1) % 3 + 1
  if n == 1 then
    -- the selection starts where the button went down, not at the first move
    local _, _, col_approx = self:convert_coordinates(x, y)
    self.press_anchor = { col_approx, row - self.terminal:scrollback() }
    self.selection = nil
    self.pressing = true
  elseif n == 2 then
    self.word_selecting = { self:get_word_boundaries(col, row) }
    if #self.word_selecting == 4 then self.selection = { table.unpack(self.word_selecting) } end
  else
    row = row - self.terminal:scrollback()
    self.row_selecting = { 0, row, 0, row + 1 }
    self.selection = { 0, row, 0, row + 1 }
  end
  core.redraw = true
  return true
end

function TerminalView:on_mouse_moved(x, y, dx, dy)
  TerminalView.super.on_mouse_moved(self, x, y, dx, dy)
  if self.dragging_scrollbar or not self.terminal then return end
  self.mouse_x, self.mouse_y = x, y
  if not (self.pressing or self.word_selecting or self.row_selecting) then return end
  if y < self.position.y then self.scrolling_offscreen = 1
  elseif y > self.position.y + self.size.y then self.scrolling_offscreen = -1
  else self.scrolling_offscreen = nil end
  local col, line, col_approx = self:convert_coordinates(x, y)
  local scrollback = self.terminal:scrollback()
  if not self.selection then
    local a = self.press_anchor or { col_approx, line - scrollback }
    self.selection = { a[1], a[2] }
  end
  local s = self.selection
  if self.row_selecting then
    s[1], s[2] = 0, math.min(self.row_selecting[2], line - scrollback)
    s[3], s[4] = 0, math.max(self.row_selecting[4], line - scrollback + 1)
  elseif self.word_selecting and #self.word_selecting == 4 then
    local c1, l1, c2, l2 = self:get_word_boundaries(col, line)
    local w = self.word_selecting
    if not c1 then
      s[3], s[4] = col, line - scrollback
    elseif w[2] > l1 or (w[2] == l1 and w[1] >= c1) then
      s[1], s[2], s[3], s[4] = c1, l1, w[3], w[4]
    else
      s[1], s[2], s[3], s[4] = w[1], w[2], c2, l2
    end
  else
    s[3], s[4] = col_approx, line - scrollback
  end
  core.redraw = true
end

function TerminalView:on_mouse_released(button, x, y)
  TerminalView.super.on_mouse_released(self, button, x, y)
  if button ~= "left" then return end
  self.pressing, self.word_selecting, self.row_selecting = false, nil, nil
  self.scrolling_offscreen = nil
  local s = self.selection
  if s and #s == 4 and s[1] == s[3] and s[2] == s[4] then self.selection = nil end
  if self.terminal and not inverted() and self.terminal:mouse_tracking_mode() then
    local col, row = self:convert_coordinates(x, y)
    self:send_mouse(0, col, row, true)
  end
end

function TerminalView:on_mouse_wheel(amount)
  if not self.terminal or not amount or amount == 0 then return end
  if self.terminal:mouse_tracking_mode() and self.mouse_x then
    local col, row = self:convert_coordinates(self.mouse_x, self.mouse_y)
    self:send_mouse(amount > 0 and 64 or 65, col, row)
  else
    local lines = math.max(1, math.floor(config.mouse_wheel_scroll / select(2, self:get_cell_size()) + 0.5))
    self.terminal:scrollback(math.max(0, self.terminal:scrollback() + (amount > 0 and lines or -lines)))
  end
  core.redraw = true
end

function TerminalView:input(text)
  if not self.terminal then return false end
  self.terminal:input(text)
  if self.terminal:scrollback() ~= 0 then self.terminal:scrollback(0) end
  self.blink_start = system.get_time()
  self:poll()
  core.redraw = true
  return true
end

function TerminalView:on_text_input(text)
  self:input(text)
end

function TerminalView:get_selected_text()
  local s = self:sorted_selection()
  if not s then return nil end
  local col1, line1, col2, line2 = s[1], s[2], s[3], s[4]
  local out = {}
  for line_idx, line in ipairs(self.terminal:lines(line1, line2)) do
    local idx = line_idx - 1 + line1
    local offset = 0
    for i = 1, #line, 3 do
      local text = line[i + 2]
      local length = ulen(text)
      if idx == line1 and idx == line2 then
        if offset + length >= col1 and offset <= col2 then
          out[#out + 1] = usub(text, math.max(col1 - offset, 0) + 1, math.min(col2 - offset, length))
        end
      elseif idx == line1 then
        if offset + length >= col1 then out[#out + 1] = usub(text, math.max(col1 - offset, 0) + 1, length) end
      elseif idx < line2 then
        out[#out + 1] = text
      elseif offset <= col2 then
        out[#out + 1] = usub(text, 1, math.min(col2 - offset, length))
      end
      offset = offset + length
    end
  end
  return table.concat(out)
end


local drawer

local function editor_node()
  local root = core.root_view.root_node
  local node = core.root_view:get_active_node()
  if node and not node.locked then return node end
  if core.last_active_view then
    node = root:get_node_for_view(core.last_active_view)
    if node and not node.locked then return node end
  end
  local found
  local function walk(n)
    if found then return end
    if n.type == "leaf" then
      if not n.locked then found = n end
    else
      walk(n.a); walk(n.b)
    end
  end
  walk(root)
  return found
end

local function get_drawer()
  if not drawer then
    drawer = TerminalView(true)
    local node = editor_node()
    local last = core.active_view
    node:split("down", drawer, true)
    core.set_active_view(last)
  end
  return drawer
end

local function show_drawer(focus)
  local d = get_drawer()
  d.visible = true
  if focus and core.active_view ~= d then
    d.return_view = core.active_view
    core.set_active_view(d)
  end
end

local function hide_drawer()
  if not drawer then return end
  drawer.visible = false
  if core.active_view == drawer then
    core.set_active_view(drawer.return_view or core.last_active_view or core.active_view)
  end
end

-- the drawer is a fixed-size panel; dragging the divider above it resizes it
function TerminalView:on_divider_dragged(delta)
  if not self.drawer then return end
  local parent = core.root_view.root_node:get_node_for_view(self):get_parent_node(core.root_view.root_node)
  self.height = common.clamp(self.height + delta, 30 * SCALE, parent.size.y - 50 * SCALE)
  self.size.y = self.height
end


-- status bar
local old_get_items = StatusView.get_items
function StatusView:get_items()
  local view = core.active_view
  if view and view:is(TerminalView) and view.terminal then
    local cols, lines = view.terminal:size()
    return {
      style.text, style.icon_font, "f",
      style.dim, style.font, self.separator2,
      style.text, view.terminal:name() or cfg.shell,
    }, {
      style.text, style.font, cols .. "x" .. lines,
    }
  end
  return old_get_items(self)
end


-- commands
command.add(nil, {
  ["terminal:toggle-drawer"] = function()
    if drawer and drawer.visible then hide_drawer() else show_drawer(true) end
  end,
  ["terminal:swap-drawer"] = function()
    if core.active_view == drawer then
      core.set_active_view(drawer.return_view or core.last_active_view)
    else
      show_drawer(true)
    end
  end,
  ["terminal:open-tab"] = function()
    local node = editor_node()
    local view = TerminalView(false)
    node:add_view(view)
    core.root_view.root_node:update_layout()
  end,
  ["terminal:execute"] = function()
    core.command_view:enter("Execute In Terminal", function(text)
      show_drawer(true)
      local d = drawer
      -- the shell starts on the next frame; queue the command until then
      core.add_thread(function()
        while not d.terminal do coroutine.yield(0.05) end
        d:input(text .. cfg.newline)
      end)
    end)
  end,
})

local function active_terminal()
  local v = core.active_view
  return v and v:is(TerminalView) and v.terminal ~= nil
end

local function cursor_keys(view, normal, app)
  return view.terminal:cursor_keys_mode() == "application" and app or normal
end

local function send(seq) return function() core.active_view:input(seq) end end

command.add(active_terminal, {
  ["terminal:return"] = function() core.active_view:input(cfg.newline) end,
  ["terminal:backspace"] = function() core.active_view:input(cfg.backspace) end,
  ["terminal:ctrl-backspace"] = function() core.active_view:input(cfg.backspace == "\b" and "\x7F" or "\b") end,
  ["terminal:alt-backspace"] = function() core.active_view:input("\x1B" .. cfg.backspace) end,
  ["terminal:delete"] = function() core.active_view:input(cfg.delete) end,
  ["terminal:insert"] = send("\x1B[2~"),
  ["terminal:tab"] = send("\t"),
  ["terminal:shift-tab"] = send("\x1B[Z"),
  ["terminal:escape"] = send("\x1B"),
  ["terminal:page-up"] = send("\x1B[5~"),
  ["terminal:page-down"] = send("\x1B[6~"),
  ["terminal:up"] = function() local v = core.active_view; v:input(cursor_keys(v, "\x1B[A", "\x1BOA")) end,
  ["terminal:down"] = function() local v = core.active_view; v:input(cursor_keys(v, "\x1B[B", "\x1BOB")) end,
  ["terminal:right"] = function() local v = core.active_view; v:input(cursor_keys(v, "\x1B[C", "\x1BOC")) end,
  ["terminal:left"] = function() local v = core.active_view; v:input(cursor_keys(v, "\x1B[D", "\x1BOD")) end,
  ["terminal:home"] = function() local v = core.active_view; v:input(cursor_keys(v, "\x1B[H", "\x1BOH")) end,
  ["terminal:end"] = function() local v = core.active_view; v:input(cursor_keys(v, "\x1B[F", "\x1BOF")) end,
  ["terminal:jump-up"] = send("\x1B[1;5A"),
  ["terminal:jump-down"] = send("\x1B[1;5B"),
  ["terminal:jump-right"] = send("\x1B[1;5C"),
  ["terminal:jump-left"] = send("\x1B[1;5D"),
  ["terminal:f1"] = send("\x1BOP"), ["terminal:f2"] = send("\x1BOQ"),
  ["terminal:f3"] = send("\x1BOR"), ["terminal:f4"] = send("\x1BOS"),
  ["terminal:f5"] = send("\x1B[15~"), ["terminal:f6"] = send("\x1B[17~"),
  ["terminal:f7"] = send("\x1B[18~"), ["terminal:f8"] = send("\x1B[19~"),
  ["terminal:f9"] = send("\x1B[20~"), ["terminal:f10"] = send("\x1B[21~"),
  ["terminal:f11"] = send("\x1B[23~"), ["terminal:f12"] = send("\x1B[24~"),
  ["terminal:paste"] = function()
    local v = core.active_view
    local text = system.get_clipboard() or ""
    if v.terminal:paste_mode() == "bracketed" then text = "\x1B[200~" .. text .. "\x1B[201~" end
    v:input(text)
  end,
  ["terminal:scroll-up"] = function() local v = core.active_view; v.terminal:scrollback(v.terminal:scrollback() + v.lines) end,
  ["terminal:scroll-down"] = function() local v = core.active_view; v.terminal:scrollback(math.max(0, v.terminal:scrollback() - v.lines)) end,
  ["terminal:scroll-to-top"] = function() local v = core.active_view; v.terminal:scrollback(cfg.scrollback_limit) end,
  ["terminal:scroll-to-end"] = function() core.active_view.terminal:scrollback(0) end,
  ["terminal:clear"] = function() local v = core.active_view; v.terminal:clear(); v:input(cfg.newline) end,
  ["terminal:close"] = function()
    local v = core.active_view
    v.terminal:close()
  end,
})

-- ctrl+<letter> control characters
local control_commands = {}
for c = string.byte("a"), string.byte("z") do
  local ch = string.char(c)
  control_commands["terminal:ctrl-" .. ch] = send(string.char(c - 96))
end
control_commands["terminal:ctrl-["] = send("\x1B")
control_commands["terminal:ctrl-\\"] = send("\x1C")
control_commands["terminal:ctrl-]"] = send("\x1D")
command.add(active_terminal, control_commands)

command.add(function()
  local v = core.active_view
  return v and v:is(TerminalView) and v.terminal and v:sorted_selection() ~= nil
end, {
  ["terminal:copy"] = function()
    local text = core.active_view:get_selected_text()
    if text then system.set_clipboard(text) end
  end,
})


-- keys
keymap.add {
  ["ctrl+shift+`"] = "terminal:open-tab",
  ["alt+t"] = "terminal:swap-drawer",
  ["alt+shift+t"] = "terminal:toggle-drawer",
}

local keys = {
  ["return"] = "terminal:return",
  ["shift+return"] = "terminal:return",
  ["ctrl+return"] = "terminal:return",
  ["keypad enter"] = "terminal:return",
  ["backspace"] = "terminal:backspace",
  ["shift+backspace"] = "terminal:backspace",
  ["ctrl+backspace"] = "terminal:ctrl-backspace",
  ["alt+backspace"] = "terminal:alt-backspace",
  ["delete"] = "terminal:delete",
  ["insert"] = "terminal:insert",
  ["tab"] = "terminal:tab",
  ["shift+tab"] = "terminal:shift-tab",
  ["escape"] = "terminal:escape",
  ["pageup"] = "terminal:page-up",
  ["pagedown"] = "terminal:page-down",
  ["shift+pageup"] = "terminal:scroll-up",
  ["shift+pagedown"] = "terminal:scroll-down",
  ["shift+home"] = "terminal:scroll-to-top",
  ["shift+end"] = "terminal:scroll-to-end",
  ["up"] = "terminal:up",
  ["down"] = "terminal:down",
  ["left"] = "terminal:left",
  ["right"] = "terminal:right",
  ["home"] = "terminal:home",
  ["end"] = "terminal:end",
  ["ctrl+up"] = "terminal:jump-up",
  ["ctrl+down"] = "terminal:jump-down",
  ["ctrl+left"] = "terminal:jump-left",
  ["ctrl+right"] = "terminal:jump-right",
  ["alt+left"] = "terminal:jump-left",
  ["alt+right"] = "terminal:jump-right",
  ["ctrl+shift+c"] = "terminal:copy",
  ["ctrl+shift+v"] = "terminal:paste",
  ["ctrl+["] = "terminal:ctrl-[",
  ["ctrl+\\"] = "terminal:ctrl-\\",
  ["ctrl+]"] = "terminal:ctrl-]",
}
for i = 1, 12 do keys["f" .. i] = "terminal:f" .. i end
for c = string.byte("a"), string.byte("z") do
  local ch = string.char(c)
  keys["ctrl+" .. ch] = "terminal:ctrl-" .. ch
end

-- ctrl+shift+<letter>: run the editor's ctrl+<letter> command from a terminal
if cfg.inversion_key then
  local inv_commands, inv_keys = {}, {}
  for c = string.byte("a"), string.byte("z") do
    local ch = string.char(c)
    local stroke = "ctrl+" .. cfg.inversion_key .. "+" .. ch
    local names = {}
    for _, name in ipairs(keymap.map["ctrl+" .. ch] or {}) do
      if not name:find("^terminal:") then
        local alias = "terminal:editor-" .. name:gsub(":", "-")
        if not command.map[alias] and not inv_commands[alias] then
          inv_commands[alias] = function() command.perform(name) end
        end
        names[#names + 1] = alias
      end
    end
    if #names > 0 and not keys[stroke] then inv_keys[stroke] = names end
  end
  for alias, fn in pairs(inv_commands) do
    inv_commands[alias] = function()
      local v = core.active_view
      if v.drawer and v.return_view and not alias:find("root%-") and not alias:find("core%-") then
        core.set_active_view(v.return_view)
      end
      fn()
    end
  end
  command.add(active_terminal, inv_commands)
  for stroke, names in pairs(inv_keys) do keys[stroke] = names end
end

local filtered = {}
for stroke, cmd in pairs(keys) do
  if not cfg.omit_escapes or not stroke:find(cfg.omit_escapes) then filtered[stroke] = cmd end
end
keymap.add(filtered)

return { class = TerminalView, get_drawer = get_drawer }
