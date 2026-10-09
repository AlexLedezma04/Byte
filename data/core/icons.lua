local icons = {}

local bitmaps = {
  folder = {
    "................",
    "................",
    ".#####..........",
    ".#....#.........",
    ".#.....#######..",
    ".#...........#..",
    ".#...........#..",
    ".#...........#..",
    ".#...........#..",
    ".#...........#..",
    ".#...........#..",
    ".#...........#..",
    ".#############..",
  },
  git = {
    "..###.....###...",
    "..#.#.....#.#...",
    "..###.....###...",
    "...#.......#....",
    "...#.......#....",
    "...#......#.....",
    "...#.....#......",
    "...#...##.......",
    "...#.##.........",
    "...##...........",
    "...#............",
    "..###...........",
    "..#.#...........",
    "..###...........",
  },
  terminal = {
    "############",
    "#..........#",
    "#.#........#",
    "#..#.......#",
    "#...#......#",
    "#..#.......#",
    "#.#..####..#",
    "#..........#",
    "#..........#",
    "############",
  },
}

-- trims empty rows/columns so every icon centers on its visible pixels
local function bounds(bm)
  local x0, y0, x1, y1 = math.huge, math.huge, 0, 0
  for y, row in ipairs(bm) do
    for x = 1, #row do
      if row:sub(x, x) == "#" then
        x0, x1 = math.min(x0, x), math.max(x1, x)
        y0, y1 = math.min(y0, y), math.max(y1, y)
      end
    end
  end
  return x0, y0, x1 - x0 + 1, y1 - y0 + 1
end

for name, bm in pairs(bitmaps) do
  local x0, y0, w, h = bounds(bm)
  bitmaps[name] = { rows = bm, x0 = x0, y0 = y0, w = w, h = h }
end


function icons.get_size(name)
  local bm = bitmaps[name]
  local px = math.max(1, math.floor(SCALE + 0.5))
  return bm.w * px, bm.h * px
end


-- draws icon `name` centered in the rect x, y, w, h
function icons.draw(name, color, x, y, w, h)
  local bm = bitmaps[name]
  local px = math.max(1, math.floor(SCALE + 0.5))
  local iw, ih = bm.w * px, bm.h * px
  local ox, oy = math.floor(x + (w - iw) / 2), math.floor(y + (h - ih) / 2)
  for r = bm.y0, bm.y0 + bm.h - 1 do
    local row = bm.rows[r]
    -- merge horizontal runs into one rect each
    local c = bm.x0
    while c <= bm.x0 + bm.w - 1 do
      if row:sub(c, c) == "#" then
        local s = c
        while row:sub(c + 1, c + 1) == "#" do c = c + 1 end
        renderer.draw_rect(ox + (s - bm.x0) * px, oy + (r - bm.y0) * px,
          (c - s + 1) * px, px, color)
      end
      c = c + 1
    end
  end
end


return icons
