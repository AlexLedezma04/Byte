local core = require "core"
local common = require "core.common"
local style = require "core.style"
local keymap = require "core.keymap"
local command = require "core.command"
local Object = require "core.object"
local View = require "core.view"
local DocView = require "core.docview"
local logo = require "core.logo"


local EmptyView = View:extend()

local HINTS_NO_FOLDER = {
  { "run a command", "core:find-command" },
  { "open a folder", "core:open-folder" },
  { "open a file", "core:open-file" },
  { "create a new file", "core:new-doc" },
  { "open a terminal", "terminal:swap-drawer" },
}
local HINTS_FOLDER = {
  { "run a command", "core:find-command" },
  { "open a file from the folder", "core:find-file" },
  { "search the folder", "project-search:find" },
  { "create a new file", "core:new-doc" },
  { "open a terminal", "terminal:swap-drawer" },
  { "show Git changes", "git:show-changes" },
  { "close the folder", "core:close-folder" },
}

local function get_hints()
  local lines = {}
  for _, hint in ipairs(core.project_dir and HINTS_FOLDER or HINTS_NO_FOLDER) do
    local binding = keymap.get_binding(hint[2])
    local cmd = command.map[hint[2]]
    if binding and cmd and cmd.predicate() then
      table.insert(lines, binding .. " to " .. hint[1])
    end
  end
  return lines
end

local function draw_text(x, y, color)
  local lines = get_hints()
  local th = style.font:get_height()
  local big = style.big_font:get_height()
  local hints_h = #lines * th + (#lines - 1) * style.padding.y
  local dh = math.max(big, hints_h) + style.padding.y * 2
  local mark_h = math.min(dh, math.floor(big * 1.6))
  x = x + logo.draw(x, y + math.floor((dh - mark_h) / 2), mark_h, color)
  x = x + style.padding.x
  renderer.draw_rect(x, y, math.ceil(1 * SCALE), dh, color)
  y = y + (dh - hints_h) / 2
  local w = 0
  for _, text in ipairs(lines) do
    w = math.max(w, renderer.draw_text(style.font, text, x + style.padding.x, y, color))
    y = y + th + style.padding.y
  end
  return w, dh
end

function EmptyView:draw()
  self:draw_background(style.background)
  local w, h = draw_text(0, 0, { 0, 0, 0, 0 })
  local x = self.position.x + math.max(style.padding.x, (self.size.x - w) / 2)
  local y = self.position.y + (self.size.y - h) / 2
  draw_text(x, y, style.dim)
end



-- placeholder tab for files the editor can't show
local UnreadableView = View:extend()

function UnreadableView:new(doc)
  UnreadableView.super.new(self)
  self.doc = doc
end

function UnreadableView:get_name()
  return (self.doc:get_name():match("[^/%\\]*$"))
end

-- callers that jump to a position after opening a doc
function UnreadableView:scroll_to_line() end

function UnreadableView:draw()
  self:draw_background(style.background)
  local font = style.sidebar_font or style.font
  local th = style.big_font:get_height()
  local lh = font:get_height()
  local gap = style.padding.y
  local reason = type(self.doc.unreadable) == "string" and self.doc.unreadable
  local h = th + gap + lh + (reason and lh + gap or 0)
  local x, y, w = self.position.x, self.position.y + (self.size.y - h) / 2, self.size.x
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  common.draw_text(style.big_font, style.dim, "Can't open this file", "center", x, y, w, th)
  y = y + th + gap
  common.draw_text(font, style.text, self.doc:get_name(), "center", x, y, w, lh)
  y = y + lh + gap
  if reason then common.draw_text(font, style.dim, reason, "center", x, y, w, lh) end
  core.pop_clip_rect()
end



local Node = Object:extend()

function Node:new(type)
  self.type = type or "leaf"
  self.position = { x = 0, y = 0 }
  self.size = { x = 0, y = 0 }
  self.views = {}
  self.divider = 0.5
  if self.type == "leaf" then
    self:add_view(EmptyView())
  end
end


function Node:propagate(fn, ...)
  self.a[fn](self.a, ...)
  self.b[fn](self.b, ...)
end


function Node:on_mouse_moved(x, y, ...)
  self.hovered_tab = self:get_tab_overlapping_point(x, y)
  self.hovered_close = self.hovered_tab and self:tab_close_overlapping_point(self.hovered_tab, x, y)
  if self.type == "leaf" then
    self.active_view:on_mouse_moved(x, y, ...)
  else
    self:propagate("on_mouse_moved", x, y, ...)
  end
end


function Node:on_mouse_released(...)
  if self.type == "leaf" then
    self.active_view:on_mouse_released(...)
  else
    self:propagate("on_mouse_released", ...)
  end
end


function Node:consume(node)
  for k, _ in pairs(self) do self[k] = nil end
  for k, v in pairs(node) do self[k] = v   end
end


local type_map = { up="vsplit", down="vsplit", left="hsplit", right="hsplit" }

function Node:split(dir, view, locked)
  assert(self.type == "leaf", "Tried to split non-leaf node")
  local type = assert(type_map[dir], "Invalid direction")
  local last_active = core.active_view
  local child = Node()
  child:consume(self)
  self:consume(Node(type))
  self.a = child
  self.b = Node()
  if view then self.b:add_view(view) end
  if locked then
    self.b.locked = locked
    core.set_active_view(last_active)
  end
  if dir == "up" or dir == "left" then
    self.a, self.b = self.b, self.a
  end
  return child
end


-- removes a view from this node, collapsing the node into its sibling if it was the last one
function Node:remove_view(root, view)
  if #self.views > 1 then
    local idx = self:get_view_idx(view)
    table.remove(self.views, idx)
    if self.active_view == view then
      self:set_active_view(self.views[idx] or self.views[#self.views])
    end
  else
    local parent = self:get_parent_node(root)
    local is_a = (parent.a == self)
    local other = parent[is_a and "b" or "a"]
    if other:get_locked_size() then
      self.views = {}
      self:add_view(EmptyView())
    else
      parent:consume(other)
      local p = parent
      while p.type ~= "leaf" do
        p = p[is_a and "a" or "b"]
      end
      p:set_active_view(p.active_view)
    end
  end
  core.last_active_view = nil
end


function Node:close_active_view(root)
  local view = self.active_view
  view:try_close(function() self:remove_view(root, view) end)
end


function Node:add_view(view)
  assert(self.type == "leaf", "Tried to add view to non-leaf node")
  assert(not self.locked, "Tried to add view to locked node")
  if self.views[1] and self.views[1]:is(EmptyView) then
    table.remove(self.views)
  end
  table.insert(self.views, view)
  self:set_active_view(view)
end


function Node:set_active_view(view)
  assert(self.type == "leaf", "Tried to set active view on non-leaf node")
  self.active_view = view
  core.set_active_view(view)
end


function Node:get_view_idx(view)
  for i, v in ipairs(self.views) do
    if v == view then return i end
  end
end


function Node:get_node_for_view(view)
  for _, v in ipairs(self.views) do
    if v == view then return self end
  end
  if self.type ~= "leaf" then
    return self.a:get_node_for_view(view) or self.b:get_node_for_view(view)
  end
end


function Node:get_parent_node(root)
  if root.a == self or root.b == self then
    return root
  elseif root.type ~= "leaf" then
    return self:get_parent_node(root.a) or self:get_parent_node(root.b)
  end
end


function Node:get_children(t)
  t = t or {}
  for _, view in ipairs(self.views) do
    table.insert(t, view)
  end
  if self.a then self.a:get_children(t) end
  if self.b then self.b:get_children(t) end
  return t
end


function Node:get_divider_drag_target()
  for _, child in ipairs({ self.a, self.b }) do
    if child:get_locked_size() then
      local view = child.type == "leaf" and child.active_view
      return view and view.on_divider_dragged and view or false
    end
  end
  return true
end


function Node:get_divider_overlapping_point(px, py)
  if self.type ~= "leaf" then
    local p = 6
    local x, y, w, h = self:get_divider_rect()
    x, y = x - p, y - p
    w, h = w + p * 2, h + p * 2
    if px > x and py > y and px < x + w and py < y + h and self:get_divider_drag_target() then
      return self
    end
    return self.a:get_divider_overlapping_point(px, py)
        or self.b:get_divider_overlapping_point(px, py)
  end
end


-- documents always get a tab bar
function Node:has_tabs()
  if self.type ~= "leaf" or self.locked then return false end
  return #self.views > 1 or (self.views[1] ~= nil and not self.views[1]:is(EmptyView))
end


function Node:get_tab_overlapping_point(px, py)
  if not self:has_tabs() then return nil end
  local x, y, w, h = self:get_tab_rect(1)
  if px >= x and py >= y and px < x + w * #self.views and py < y + h then
    return math.floor((px - x) / w) + 1
  end
end


function Node:get_child_overlapping_point(x, y)
  local child
  if self.type == "leaf" then
    return self
  elseif self.type == "hsplit" then
    child = (x < self.b.position.x) and self.a or self.b
  elseif self.type == "vsplit" then
    child = (y < self.b.position.y) and self.a or self.b
  end
  return child:get_child_overlapping_point(x, y)
end


function Node:get_tab_rect(idx)
  local tw = math.min(style.tab_width, math.ceil(self.size.x / #self.views))
  local h = style.font:get_height() + style.padding.y * 2
  return self.position.x + (idx-1) * tw, self.position.y, tw, h
end


function Node:get_tab_close_rect(idx)
  local x, y, w, h = self:get_tab_rect(idx)
  local size = style.font:get_height()
  return x + w - size - style.padding.x / 2, y + (h - size) / 2, size, size
end


function Node:tab_close_overlapping_point(idx, px, py)
  return common.point_in_rect(px, py, self:get_tab_close_rect(idx))
end


function Node:get_divider_rect()
  local x, y = self.position.x, self.position.y
  if self.type == "hsplit" then
    return x + self.a.size.x, y, style.divider_size, self.size.y
  elseif self.type == "vsplit" then
    return x, y + self.a.size.y, self.size.x, style.divider_size
  end
end


function Node:get_locked_size()
  if self.type == "leaf" then
    if self.locked then
      local size = self.active_view.size
      return size.x, size.y
    end
  else
    local x1, y1 = self.a:get_locked_size()
    local x2, y2 = self.b:get_locked_size()
    if x1 and x2 then
      local dsx = (x1 < 1 or x2 < 1) and 0 or style.divider_size
      local dsy = (y1 < 1 or y2 < 1) and 0 or style.divider_size
      return x1 + x2 + dsx, y1 + y2 + dsy
    end
  end
end


local function copy_position_and_size(dst, src)
  dst.position.x, dst.position.y = src.position.x, src.position.y
  dst.size.x, dst.size.y = src.size.x, src.size.y
end


-- calculating the sizes is the same for hsplits and vsplits, except the x/y
-- axis are swapped; this function lets us use the same code for both
local function calc_split_sizes(self, x, y, x1, x2)
  local n
  local ds = (x1 and x1 < 1 or x2 and x2 < 1) and 0 or style.divider_size
  if x1 then
    n = x1 + ds
  elseif x2 then
    n = self.size[x] - x2
  else
    n = math.floor(self.size[x] * self.divider)
  end
  self.a.position[x] = self.position[x]
  self.a.position[y] = self.position[y]
  self.a.size[x] = n - ds
  self.a.size[y] = self.size[y]
  self.b.position[x] = self.position[x] + n
  self.b.position[y] = self.position[y]
  self.b.size[x] = self.size[x] - n
  self.b.size[y] = self.size[y]
end


function Node:update_layout()
  if self.type == "leaf" then
    local av = self.active_view
    if self:has_tabs() then
      local _, _, _, th = self:get_tab_rect(1)
      av.position.x, av.position.y = self.position.x, self.position.y + th
      av.size.x, av.size.y = self.size.x, self.size.y - th
    else
      copy_position_and_size(av, self)
    end
  else
    local x1, y1 = self.a:get_locked_size()
    local x2, y2 = self.b:get_locked_size()
    if self.type == "hsplit" then
      calc_split_sizes(self, "x", "y", x1, x2)
    elseif self.type == "vsplit" then
      calc_split_sizes(self, "y", "x", y1, y2)
    end
    self.a:update_layout()
    self.b:update_layout()
  end
end


function Node:update()
  if self.type == "leaf" then
    for _, view in ipairs(self.views) do
      view:update()
    end
  else
    self.a:update()
    self.b:update()
  end
end


function Node:draw_tabs()
  local x, y, _, h = self:get_tab_rect(1)
  local ds = style.divider_size
  core.push_clip_rect(x, y, self.size.x, h)
  renderer.draw_rect(x, y, self.size.x, h, style.background2)
  renderer.draw_rect(x, y + h - ds, self.size.x, ds, style.divider)

  for i, view in ipairs(self.views) do
    local x, y, w, h = self:get_tab_rect(i)
    local text = view:get_name()
    local color = style.dim
    if view == self.active_view then
      color = style.text
      renderer.draw_rect(x, y, w, h, style.background)
      renderer.draw_rect(x + w, y, ds, h, style.divider)
      renderer.draw_rect(x - ds, y, ds, h, style.divider)
    end
    if i == self.hovered_tab then
      color = style.text
    end
    local cx, cy, cw, ch = self:get_tab_close_rect(i)
    if view == self.active_view or i == self.hovered_tab then
      local hovered = i == self.hovered_tab and self.hovered_close
      if hovered then renderer.draw_rect(cx, cy, cw, ch, style.line_highlight) end
      common.draw_text(style.font, hovered and style.accent or style.dim, "×", "center", cx, cy, cw, ch)
    end
    core.push_clip_rect(x, y, cx - x, h)
    x, w = x + style.padding.x, cx - x - style.padding.x
    local align = style.font:get_width(text) > w and "left" or "center"
    common.draw_text(style.font, color, text, align, x, y, w, h)
    core.pop_clip_rect()
  end

  core.pop_clip_rect()
end


function Node:draw()
  if self.type == "leaf" then
    if self:has_tabs() then
      self:draw_tabs()
    end
    local pos, size = self.active_view.position, self.active_view.size
    core.push_clip_rect(pos.x, pos.y, size.x + pos.x % 1, size.y + pos.y % 1)
    self.active_view:draw()
    core.pop_clip_rect()
  else
    local x, y, w, h = self:get_divider_rect()
    renderer.draw_rect(x, y, w, h, style.divider)
    self:propagate("draw")
  end
end



local RootView = View:extend()

function RootView:new()
  RootView.super.new(self)
  self.root_node = Node()
  self.deferred_draws = {}
  self.mouse = { x = 0, y = 0 }
end


function RootView:defer_draw(fn, ...)
  table.insert(self.deferred_draws, 1, { fn = fn, ... })
end


function RootView:get_active_node()
  return self.root_node:get_node_for_view(core.active_view)
end


function RootView:open_doc(doc)
  local node = self:get_active_node()
  if node.locked and core.last_active_view then
    core.set_active_view(core.last_active_view)
    node = self:get_active_node()
  end
  assert(not node.locked, "Cannot open doc on locked node")
  for i, view in ipairs(node.views) do
    if view.doc == doc then
      node:set_active_view(node.views[i])
      return view
    end
  end
  local view = doc.unreadable and UnreadableView(doc) or DocView(doc)
  node:add_view(view)
  self.root_node:update_layout()
  view:scroll_to_line(view.doc:get_selection(), true, true)
  return view
end


function RootView:on_mouse_pressed(button, x, y, clicks)
  local div = self.root_node:get_divider_overlapping_point(x, y)
  if div then
    self.dragged_divider = div
    return
  end
  local node = self.root_node:get_child_overlapping_point(x, y)
  local idx = node:get_tab_overlapping_point(x, y)
  if idx then
    node:set_active_view(node.views[idx])
    if button == "middle"
    or (button == "left" and node:tab_close_overlapping_point(idx, x, y)) then
      node:close_active_view(self.root_node)
    elseif button == "left" then
      self:start_drag({ node = node, view = node.views[idx] }, x, y)
    end
  else
    core.set_active_view(node.active_view)
    node.active_view:on_mouse_pressed(button, x, y, clicks)
  end
end


function RootView:on_mouse_released(...)
  if self.dragged_divider then
    self.dragged_divider = nil
  end
  if self.dragged_tab then
    self:end_drag()
  end
  self.root_node:on_mouse_released(...)
end


function RootView:on_mouse_moved(x, y, dx, dy)
  if self.dragged_divider then
    local node = self.dragged_divider
    local target = node:get_divider_drag_target()
    if target ~= true then
      local d = node.type == "hsplit" and dx or dy
      target:on_divider_dragged(node.b.active_view == target and -d or d)
      return
    end
    if node.type == "hsplit" then
      node.divider = node.divider + dx / node.size.x
    else
      node.divider = node.divider + dy / node.size.y
    end
    node.divider = common.clamp(node.divider, 0.01, 0.99)
    return
  end

  if self.dragged_tab then
    self:update_drag(x, y)
  end

  self.mouse.x, self.mouse.y = x, y
  self.root_node:on_mouse_moved(x, y, dx, dy)

  local node = self.root_node:get_child_overlapping_point(x, y)
  local div = self.root_node:get_divider_overlapping_point(x, y)
  if div then
    system.set_cursor(div.type == "hsplit" and "sizeh" or "sizev")
  elseif node:get_tab_overlapping_point(x, y) then
    system.set_cursor("arrow")
  else
    system.set_cursor(node.active_view.cursor)
  end
end


-- Dragging
local drag_threshold = 6

function RootView:start_drag(drag, x, y)
  drag.x, drag.y = x, y
  self.dragged_tab = drag
  self.drop_target = nil
end


function RootView:get_drop_target(x, y)
  local node = self.root_node:get_child_overlapping_point(x, y)
  if node.type ~= "leaf" or node.locked or node:get_locked_size() then return end
  local _, ty, _, th = node:get_tab_rect(1)
  if node:has_tabs() and y < ty + th then
    return { node = node, dir = "middle" }
  end
  local rx = (x - node.position.x) / node.size.x
  local ry = (y - node.position.y) / node.size.y
  local dir = "middle"
  local edge = math.min(rx, 1 - rx, ry, 1 - ry)
  if edge < 0.25 then
    if edge == rx then dir = "left"
    elseif edge == 1 - rx then dir = "right"
    elseif edge == ry then dir = "up"
    else dir = "down" end
  end
  return { node = node, dir = dir }
end


function RootView:update_drag(x, y)
  local drag = self.dragged_tab
  if not drag.moved then
    if math.abs(x - drag.x) < drag_threshold and math.abs(y - drag.y) < drag_threshold then
      return
    end
    drag.moved = true
  end
  core.redraw = true
  self.drop_target = nil

  -- reorder tabs within the source tab bar
  if drag.view then
    local node, views = drag.node, drag.node.views
    local _, ty, tw, th = node:get_tab_rect(1)
    if y >= ty and y < ty + th
    and x >= node.position.x and x < node.position.x + node.size.x then
      local from = node:get_view_idx(drag.view)
      local to = node:get_tab_overlapping_point(x, y) or #views
      if from and to ~= from then
        table.remove(views, from)
        table.insert(views, to, drag.view)
        node.hovered_tab = to
      end
      return
    end
  end

  local target = self:get_drop_target(x, y)
  -- dropping a node's only tab back onto itself would do nothing
  if target and drag.view and target.node == drag.node
  and (#drag.node.views == 1 or target.dir == "middle") then
    target = nil
  end
  self.drop_target = target
end


function RootView:end_drag()
  local drag, target = self.dragged_tab, self.drop_target
  self.dragged_tab, self.drop_target = nil, nil
  core.redraw = true

  if drag.filename then
    if not drag.moved then
      core.try(function() self:open_doc(core.open_doc(drag.filename)) end)
    elseif target then
      core.try(function()
        local doc = core.open_doc(drag.filename)
        if target.dir == "middle" then
          core.set_active_view(target.node.active_view)
          self:open_doc(doc)
        else
          target.node:split(target.dir, DocView(doc))
        end
      end)
    end
    return
  end

  if not target then return end
  local view, src, dst = drag.view, drag.node, target.node
  if src == dst then
    src:remove_view(self.root_node, view)
    src:split(target.dir, view)
  else
    if target.dir == "middle" then
      dst:add_view(view)
    else
      dst:split(target.dir, view)
    end
    src:remove_view(self.root_node, view)
    core.set_active_view(view)
  end
end


function RootView:draw_drop_target()
  local t = self.drop_target
  if not t then return end
  local x, y = t.node.position.x, t.node.position.y
  local w, h = t.node.size.x, t.node.size.y
  if t.dir == "left" then w = w / 2
  elseif t.dir == "right" then x, w = x + w / 2, w / 2
  elseif t.dir == "up" then h = h / 2
  elseif t.dir == "down" then y, h = y + h / 2, h / 2 end
  local c = style.accent
  renderer.draw_rect(x, y, w, h, { c[1], c[2], c[3], 50 })
  local b = style.divider_size * 2
  renderer.draw_rect(x, y, w, b, c)
  renderer.draw_rect(x, y + h - b, w, b, c)
  renderer.draw_rect(x, y, b, h, c)
  renderer.draw_rect(x + w - b, y, b, h, c)
end


function RootView:on_mouse_wheel(...)
  local x, y = self.mouse.x, self.mouse.y
  local node = self.root_node:get_child_overlapping_point(x, y)
  node.active_view:on_mouse_wheel(...)
end


function RootView:on_text_input(...)
  core.active_view:on_text_input(...)
end


function RootView:update()
  copy_position_and_size(self.root_node, self)
  self.root_node:update()
  self.root_node:update_layout()
end


function RootView:draw()
  self.root_node:draw()
  while #self.deferred_draws > 0 do
    local t = table.remove(self.deferred_draws)
    t.fn(table.unpack(t))
  end
  self:draw_drop_target()
end


return RootView
