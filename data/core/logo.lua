local logo = {}

local BARS = {
  { 44, 20, 72 }, { 44, 41, 94 }, { 44, 62, 94 }, { 44, 83, 66 },
  { 44, 103, 72 }, { 44, 124, 108 }, { 44, 145, 108 }, { 44, 166, 78 },
}
local BAR_H, RADIUS = 14, 7
local LEFT, TOP, RIGHT, BOTTOM = 44, 20, 152, 180


-- width of the mark when drawn `height` pixels tall
function logo.get_width(height)
  return height * (RIGHT - LEFT) / (BOTTOM - TOP)
end


local function draw_snapped(x, y, height, color)
  local s = height / (BOTTOM - TOP)
  local bar = math.max(1, math.floor(BAR_H * s))
  local gap = math.max(1, math.floor((height - bar * #BARS) / (#BARS - 1)))
  local total = bar * #BARS + gap * (#BARS - 1)
  local top = y + math.floor((height - total) / 2)
  for i, b in ipairs(BARS) do
    local w = math.max(bar, math.floor(b[3] * s + 0.5))
    renderer.draw_rect(math.floor(x + 0.5), top + (i - 1) * (bar + gap), w, bar, color)
  end
end


function logo.draw(x, y, height, color)
  if height < 48 then
    draw_snapped(x, y, height, color)
    return logo.get_width(height)
  end
  local s = height / (BOTTOM - TOP)
  local rows = math.ceil(height)
  for row = 0, rows - 1 do
    local py0, py1 = row / s + TOP, (row + 1) / s + TOP
    for _, bar in ipairs(BARS) do
      local bx, by, bw = bar[1], bar[2], bar[3]
      local top, bottom = math.max(py0, by), math.min(py1, by + BAR_H)
      if bottom > top then
        local coverage = (bottom - top) / (py1 - py0)
        local dy = math.abs((top + bottom) / 2 - (by + BAR_H / 2))
        local inset = RADIUS - math.sqrt(math.max(0, RADIUS * RADIUS - dy * dy))
        local x0 = x + (bx + inset - LEFT) * s
        local x1 = x + (bx + bw - inset - LEFT) * s
        x0, x1 = math.floor(x0 + 0.5), math.floor(x1 + 0.5)
        if x1 > x0 then
          local a = math.floor((color[4] or 255) * coverage + 0.5)
          renderer.draw_rect(x0, y + row, x1 - x0, 1, { color[1], color[2], color[3], a })
        end
      end
    end
  end
  return logo.get_width(height)
end



-- wordmark: the mark followed by "byte"
local LETTERS = {
  "M200 62V138M200 94H220A22 22 0 0 1 220 138H200",
  "M268 94V117A21 21 0 0 0 310 117M310 94V150A21 21 0 0 1 268 150",
  "M338 94H374M352 66V116A22 22 0 0 0 374 138H382",
  "M408 116H452A22 22 0 1 0 445.56 131.56",
}
local LETTER_DY, STROKE = -10, 12
local WORD_RIGHT = 452 + STROKE / 2


local function arc_points(x1, y1, r, large, sweep, x2, y2, out)
  local dx, dy = (x1 - x2) / 2, (y1 - y2) / 2
  local d2 = dx * dx + dy * dy
  r = math.max(r, math.sqrt(d2))
  local f = math.sqrt(math.max(0, (r * r - d2) / d2))
  if large == sweep then f = -f end
  local cx = (x1 + x2) / 2 + f * dy
  local cy = (y1 + y2) / 2 - f * dx
  local a1 = math.atan2(y1 - cy, x1 - cx)
  local a2 = math.atan2(y2 - cy, x2 - cx)
  local delta = a2 - a1
  if sweep == 1 and delta < 0 then delta = delta + 2 * math.pi end
  if sweep == 0 and delta > 0 then delta = delta - 2 * math.pi end
  local steps = math.max(4, math.ceil(math.abs(delta) * r / 2))
  for i = 1, steps do
    local a = a1 + delta * i / steps
    out[#out + 1] = { cx + r * math.cos(a), cy + r * math.sin(a) }
  end
end


local segments
local function get_segments()
  if segments then return segments end
  segments = {}
  for _, d in ipairs(LETTERS) do
    local x, y = 0, 0
    for cmd, args in d:gmatch("([MHVA])([^MHVA]*)") do
      local n = {}
      for v in args:gmatch("[%-%d%.]+") do n[#n + 1] = tonumber(v) end
      local points = {}
      if cmd == "M" then x, y = n[1], n[2]
      elseif cmd == "H" then points[1] = { n[1], y }
      elseif cmd == "V" then points[1] = { x, n[1] }
      elseif cmd == "A" then arc_points(x, y, n[1], n[4], n[5], n[6], n[7], points) end
      for _, pt in ipairs(points) do
        segments[#segments + 1] = { x, y + LETTER_DY, pt[1], pt[2] + LETTER_DY }
        x, y = pt[1], pt[2]
      end
    end
  end
  return segments
end


local function distance2(px, py, s)
  local x1, y1, x2, y2 = s[1], s[2], s[3], s[4]
  local vx, vy = x2 - x1, y2 - y1
  local len2 = vx * vx + vy * vy
  local t = len2 > 0 and math.max(0, math.min(1, ((px - x1) * vx + (py - y1) * vy) / len2)) or 0
  local qx, qy = x1 + t * vx - px, y1 + t * vy - py
  return qx * qx + qy * qy
end


-- coverage of the letters per pixel, as runs { row, x, width, alpha }
local letter_cache = {}
local function letter_runs(height)
  if letter_cache[height] then return letter_cache[height] end
  local s = height / (BOTTOM - TOP)
  local segs = get_segments()
  local half2 = (STROKE / 2) ^ 2
  local x0 = 200 - STROKE / 2
  local width = math.ceil((WORD_RIGHT - x0) * s)
  local ss = 4
  local runs = {}
  for row = 0, math.ceil(height) - 1 do
    local ly0, ly1 = row / s + TOP - STROKE / 2, (row + 1) / s + TOP + STROKE / 2
    local near = {}
    for _, sg in ipairs(segs) do
      if math.max(sg[2], sg[4]) >= ly0 and math.min(sg[2], sg[4]) <= ly1 then near[#near + 1] = sg end
    end
    if #near > 0 then
      local run_x, run_a
      for col = 0, width do
        local hits = 0
        for sy = 0, ss - 1 do
          local py = (row + (sy + 0.5) / ss) / s + TOP
          for sx = 0, ss - 1 do
            local px = x0 + (col + (sx + 0.5) / ss) / s
            for _, sg in ipairs(near) do
              if distance2(px, py, sg) <= half2 then hits = hits + 1; break end
            end
          end
        end
        local a = math.floor(hits * 255 / (ss * ss) / 32 + 0.5) * 32
        if a > 255 then a = 255 end
        if a ~= run_a then
          if run_a and run_a > 0 then runs[#runs + 1] = { row, run_x, col - run_x, run_a } end
          run_x, run_a = col, a
        end
      end
      if run_a and run_a > 0 then runs[#runs + 1] = { row, run_x, width + 1 - run_x, run_a } end
    end
  end
  letter_cache[height] = runs
  return runs
end


-- width of the wordmark when drawn `height` pixels tall
function logo.get_wordmark_width(height)
  return height * (WORD_RIGHT - LEFT) / (BOTTOM - TOP)
end


-- draws the mark and "byte" with the top-left corner at x, y; returns the width
function logo.draw_wordmark(x, y, height, color)
  height = math.floor(height + 0.5)
  logo.draw(x, y, height, color)
  local s = height / (BOTTOM - TOP)
  local lx = math.floor(x + (200 - STROKE / 2 - LEFT) * s + 0.5)
  local ca = color[4] or 255
  for _, r in ipairs(letter_runs(height)) do
    renderer.draw_rect(lx + r[2], y + r[1], r[3], 1,
      { color[1], color[2], color[3], math.floor(ca * r[4] / 255) })
  end
  return logo.get_wordmark_width(height)
end


return logo
