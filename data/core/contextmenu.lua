local core = require "core"
local common = require "core.common"
local style = require "core.style"

-- a right-click popup: a list of { text, fn } items drawn over everything
local ContextMenu = {}

local menu -- { items, x, y, w, hovered }

local function item_height()
  return style.font:get_height() + style.padding.y
end

local function rect()
  local h = item_height() * #menu.items + style.padding.y
  return menu.x, menu.y, menu.w, h
end

function ContextMenu.show(items, x, y)
  if #items == 0 then return end
  local w = 0
  for _, item in ipairs(items) do w = math.max(w, style.font:get_width(item[1])) end
  w = w + style.padding.x * 4
  local h = item_height() * #items + style.padding.y
  local root = core.root_view
  -- keep it on screen
  x = math.min(x, root.position.x + root.size.x - w)
  y = math.min(y, root.position.y + root.size.y - h)
  menu = { items = items, x = x, y = y, w = w }
  core.redraw = true
end

function ContextMenu.hide()
  menu = nil
  core.redraw = true
end

function ContextMenu.is_open()
  return menu ~= nil
end

local function item_at(x, y)
  if not menu or not common.point_in_rect(x, y, rect()) then return nil end
  local i = math.floor((y - menu.y - style.padding.y / 2) / item_height()) + 1
  return menu.items[i] and i
end

-- returns true when the menu took the event
function ContextMenu.on_mouse_moved(x, y)
  if not menu then return false end
  local i = item_at(x, y)
  if i ~= menu.hovered then menu.hovered = i; core.redraw = true end
  if i then system.set_cursor("arrow") end
  return i ~= nil
end

function ContextMenu.on_mouse_pressed(button, x, y)
  if not menu then return false end
  local i = item_at(x, y)
  local item = i and menu.items[i]
  ContextMenu.hide()
  if item and button == "left" then core.try(item[2]) end
  return true
end

function ContextMenu.draw()
  if not menu then return end
  local x, y, w, h = rect()
  local b = style.divider_size
  renderer.draw_rect(x - b, y - b, w + b * 2, h + b * 2, style.divider)
  renderer.draw_rect(x, y, w, h, style.background2)
  local ih = item_height()
  y = y + style.padding.y / 2
  for i, item in ipairs(menu.items) do
    local color = style.text
    if i == menu.hovered then
      renderer.draw_rect(x, y, w, ih, style.line_highlight)
      color = style.accent
    end
    common.draw_text(style.font, color, item[1], nil, x + style.padding.x * 2, y, 0, ih)
    y = y + ih
  end
end

return ContextMenu
