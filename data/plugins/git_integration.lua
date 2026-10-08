local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local Doc = require "core.doc"
local DocView = require "core.docview"
local StatusView = require "core.statusview"

local defaults = {
  poll_interval = 3,
  live_diff = true,
  max_diff_lines = 1000,
  color_tree = true,
  gutter = true,
  statusbar = true,
}
config.git_integration = config.git_integration or {}
for k, v in pairs(defaults) do
  if config.git_integration[k] == nil then config.git_integration[k] = v end
end

local cfg = config.git_integration

-- helpers
local default_colors = {
  added    = { common.color "#6bd16b" },
  modified = { common.color "#e0b34a" },
  deleted  = { common.color "#e05c5c" },
}

local function colors()
  local added = style.git_added or default_colors.added
  local modified = style.git_modified or default_colors.modified
  local deleted = style.git_deleted or default_colors.deleted
  return {
    added     = added,
    untracked = added,
    modified  = modified,
    deleted   = deleted,
    conflict  = deleted,
  }
end

-- status priority when propagating to parent folders
local PRIORITY = { conflict = 5, deleted = 4, modified = 3, added = 2, untracked = 1 }

local is_windows = PATHSEP == "\\"
local quote = common.shell_quote

-- Runs `git` in `cwd` and returns stdout (string) and exit code.
local function git(cwd, args)
  local cmd = { "git", "-C", quote(cwd), "-c", "core.quotepath=off", "--no-pager" }
  for _, a in ipairs(args) do cmd[#cmd + 1] = quote(a) end
  local line = table.concat(cmd, " ") .. (is_windows and " 2>NUL" or " 2>/dev/null")
  if is_windows then line = '"' .. line .. '"' end
  local fp = io.popen(line, "r")
  if not fp then return nil, -1 end
  local out = fp:read("*a")
  local _, _, code = fp:close()
  local _, is_main = coroutine.running()
  if not is_main then coroutine.yield() end
  return out, code or 0
end

local function split_lines(text)
  local lines, pos = {}, 1
  while pos <= #text do
    local nl = text:find("\n", pos, true)
    local line
    if nl then line = text:sub(pos, nl - 1); pos = nl + 1
    else line = text:sub(pos); pos = #text + 1 end
    lines[#lines + 1] = (line:gsub("\r$", ""))
  end
  return lines
end

-- repository state
local repo = {
  root = nil,
  branch = nil,
  ahead = 0,
  behind = 0,
  files = {},
  dirs = {},
  counts = { modified = 0, added = 0, deleted = 0, untracked = 0, conflict = 0 },
  signature = "",
  project = nil,
}

local function classify(x, y)
  if x == "?" and y == "?" then return "untracked" end
  if x == "U" or y == "U" or (x == "A" and y == "A") or (x == "D" and y == "D") then
    return "conflict"
  end
  if x == "D" or y == "D" then return "deleted" end
  if x == "A" or x == "R" or x == "C" then
    if y == "M" then return "modified" end
    return "added"
  end
  return "modified"
end

local function parse_status(root, out)
  local files, dirs = {}, {}
  local counts = { modified = 0, added = 0, deleted = 0, untracked = 0, conflict = 0 }
  local branch, ahead, behind
  local entries = {}
  for e in out:gmatch("([^\0]+)") do entries[#entries + 1] = e end
  local i = 1
  while i <= #entries do
    local e = entries[i]
    if e:sub(1, 3) == "## " then
      local head = e:sub(4)
      local b = head:match("^No commits yet on (.+)$") or head:match("^Initial commit on (.+)$")
      b = b or head:match("^(.-)%.%.%.") or head:match("^(.-) %[") or head
      if b:match("^HEAD %(no branch%)") then b = "HEAD (detached)" end
      branch = b
      ahead = tonumber(head:match("ahead (%d+)")) or 0
      behind = tonumber(head:match("behind (%d+)")) or 0
    else
      local x, y, path = e:sub(1, 1), e:sub(2, 2), e:sub(4)
      if x == "R" or x == "C" then i = i + 1 end -- skip the original name
      local st = classify(x, y)
      local abs = root .. PATHSEP .. path
      files[abs] = st
      counts[st] = counts[st] + 1
      local dir = abs
      while true do
        dir = dir:match("^(.*)[/\\][^/\\]*$")
        if not dir or #dir < #root then break end
        local old = dirs[dir]
        if not old or PRIORITY[st] > PRIORITY[old] then dirs[dir] = st end
        if dir == root then break end
      end
    end
    i = i + 1
  end
  return files, dirs, counts, branch, ahead, behind
end

local rev = 0

local function refresh_status()
  local project = core.project_dir
  if not project then
    if repo.root then
      repo.root, repo.files, repo.dirs, repo.signature = nil, {}, {}, ""
      core.redraw = true
    end
    return
  end
  local top = git(project, { "rev-parse", "--show-toplevel" })
  top = top and top:gsub("%s+$", "") or ""
  if top == "" then
    if repo.root then
      repo.root, repo.files, repo.dirs = nil, {}, {}
      core.redraw = true
    end
    return
  end
  if PATHSEP == "\\" then top = top:gsub("/", "\\") end
  local out = git(top, { "status", "--porcelain=v1", "-z", "-b", "--untracked-files=all" })
  if not out then return end
  local head = git(top, { "rev-parse", "HEAD" })
  local signature = out .. "\0" .. (head or "")
  if repo.root == top and signature == repo.signature then return end
  if (head or "") ~= (repo.head or "") then rev = rev + 1 end
  local files, dirs, counts, branch, ahead, behind = parse_status(top, out)
  repo.root, repo.files, repo.dirs, repo.counts = top, files, dirs, counts
  repo.branch, repo.ahead, repo.behind = branch, ahead, behind
  repo.signature, repo.head = signature, head
  rev = rev + 1
  core.redraw = true
end

local refresh_requested = true
local function request_refresh() refresh_requested = true end

core.add_thread(function()
  local last = -math.huge
  local last_project = core.project_dir
  while true do
    local now = system.get_time()
    if core.project_dir ~= last_project then
      last_project = core.project_dir
      repo.root, repo.files, repo.dirs, repo.signature = nil, {}, {}, ""
      refresh_requested = true
    end
    local interval = tonumber(cfg.poll_interval) or 0
    local due = interval > 0 and system.window_has_focus() and now - last >= interval
    if refresh_requested or due then
      refresh_requested = false
      last = now
      core.try(refresh_status)
    end
    coroutine.yield(0.25)
  end
end)

local function doc_abs(doc)
  return doc.filename and system.absolute_path(doc.filename)
end

-- line diff (document vs HEAD)
local function diff_lines(old, new, max)
  local n, m = #old, #new
  local lo = 1
  while lo <= n and lo <= m and old[lo] == new[lo] do lo = lo + 1 end
  local hi_o, hi_n = n, m
  while hi_o >= lo and hi_n >= lo and old[hi_o] == new[hi_n] do
    hi_o, hi_n = hi_o - 1, hi_n - 1
  end
  local on, nn = hi_o - lo + 1, hi_n - lo + 1
  if on <= 0 and nn <= 0 then return {} end

  local function make(os, oc, ns, nc)
    local kind = (oc == 0) and "add" or (nc == 0) and "del" or "mod"
    return { old_start = os, old_count = oc, new_start = ns, new_count = nc, kind = kind }
  end

  if on == 0 or nn == 0 or on * nn > (max or 1000) * (max or 1000) then
    return { make(lo, math.max(on, 0), lo, math.max(nn, 0)) }
  end

  local L = {}
  for i = on + 1, 1, -1 do
    local row = {}
    L[i] = row
    if i == on + 1 then
      for j = 1, nn + 1 do row[j] = 0 end
    else
      local below = L[i + 1]
      local oi = old[lo + i - 1]
      row[nn + 1] = 0
      for j = nn, 1, -1 do
        if oi == new[lo + j - 1] then
          row[j] = below[j + 1] + 1
        else
          local a, b = below[j], row[j + 1]
          row[j] = a > b and a or b
        end
      end
    end
  end

  local hunks = {}
  local i, j = 1, 1
  local hs_i, hs_j
  local function close()
    if hs_i then
      hunks[#hunks + 1] = make(lo + hs_i - 1, i - hs_i, lo + hs_j - 1, j - hs_j)
      hs_i, hs_j = nil, nil
    end
  end
  while i <= on or j <= nn do
    if i <= on and j <= nn and old[lo + i - 1] == new[lo + j - 1] then
      close()
      i, j = i + 1, j + 1
    else
      if not hs_i then hs_i, hs_j = i, j end
      if j > nn or (i <= on and L[i + 1][j] >= L[i][j + 1]) then i = i + 1
      else j = j + 1 end
    end
  end
  close()
  return hunks
end

local doc_state = setmetatable({}, { __mode = "k" })

local function doc_lines(doc)
  local t = {}
  for i, l in ipairs(doc.lines) do t[i] = (l:gsub("\r?\n$", "")) end
  if #t == 1 and t[1] == "" then t[1] = nil end
  return t
end

local function get_state(doc)
  local st = doc_state[doc]
  if not st then
    st = { hunks = {}, change_id = -1, rev = -1, last_change = 0 }
    doc_state[doc] = st
  end
  return st
end

local function rel_path(abs)
  if not repo.root or abs:sub(1, #repo.root + 1) ~= repo.root .. PATHSEP then return nil end
  return (abs:sub(#repo.root + 2):gsub("\\", "/"))
end

local function load_base(doc)
  local abs = doc_abs(doc)
  local st = get_state(doc)
  st.loading = true
  local want_rev = rev
  local rel = abs and rel_path(abs)
  local base = false
  if rel then
    local status = repo.files[abs]
    if status == "untracked" then
      base = {}
    else
      local tracked = git(repo.root, { "ls-files", "--", rel })
      if tracked and tracked ~= "" then
        local text, code = git(repo.root, { "show", "HEAD:" .. rel })
        if code == 0 and text then base = split_lines(text) else base = {} end
      end
    end
  end
  st.base, st.rev, st.loading = base, want_rev, false
  st.change_id = -1
  core.redraw = true
end

local function recompute(doc, st)
  st.change_id = doc:get_change_id()
  if not st.base then st.hunks = {}; return end
  st.hunks = diff_lines(st.base, doc_lines(doc), cfg.max_diff_lines)
  core.redraw = true
end

local function update_doc_state(dv)
  local doc = dv.doc
  if not doc.filename or not repo.root then return end
  local st = get_state(dv.doc)
  if not st.loading and st.rev ~= rev then
    core.add_thread(function() core.try(load_base, doc) end)
    return
  end
  if st.loading then return end
  local cid = doc:get_change_id()
  if cid ~= st.change_id then
    if not cfg.live_diff and doc:is_dirty() and st.change_id ~= -1 then return end
    local now = system.get_time()
    if st.pending_cid ~= cid then st.pending_cid, st.last_change = cid, now end
    if st.change_id == -1 or now - st.last_change > 0.12 then recompute(doc, st) end
    core.redraw = true
  end
end

-- gutter
local old_dv_update = DocView.update
function DocView:update()
  old_dv_update(self)
  if cfg.gutter and self.doc and not self.is_git_diff_view then
    update_doc_state(self)
  end
end

local old_draw_gutter = DocView.draw_line_gutter
function DocView:draw_line_gutter(line, x, y)
  old_draw_gutter(self, line, x, y)
  local lh = self:get_line_height()
  local st = cfg.gutter and not self.is_git_diff_view and doc_state[self.doc]
  if not st or #st.hunks == 0 then return end
  local c = colors()
  local bar = math.max(3, math.floor(3 * SCALE))
  for _, h in ipairs(st.hunks) do
    if h.kind == "del" then
      local at = h.new_start
      if line == at or (at > #self.doc.lines and line == #self.doc.lines) then
        local yy = (line == at) and y or (y + lh)
        local tw = math.max(6, math.floor(7 * SCALE))
        local th = math.max(1, math.floor(SCALE))
        for k = 0, 3 do
          renderer.draw_rect(x, yy - 3 * th + k * th, tw - k * 2 * th, th, c.deleted)
        end
      end
    elseif line >= h.new_start and line < h.new_start + h.new_count then
      renderer.draw_rect(x, y, bar, lh, h.kind == "add" and c.added or c.modified)
    end
  end
end

-- tree view
local ok_tv, tv = pcall(require, "plugins.treeview")
if ok_tv and type(tv) == "table" and tv.get_item_color then
  local old_color = tv.get_item_color
  function tv:get_item_color(item, active, hovered)
    local color = old_color(self, item, active, hovered)
    if cfg.color_tree and repo.root and not hovered and not active then
      local abs = item.abs_filename
      local st = abs and (repo.files[abs] or (item.type == "dir" and repo.dirs[abs]))
      if st then color = colors()[st] end
    end
    return color
  end
end

-- status bar
local function status_items()
  local c, k = colors(), repo.counts
  local t = { style.font, style.text, repo.branch or "?" }
  if repo.ahead > 0 then t[#t + 1] = style.dim; t[#t + 1] = " ahead " .. repo.ahead end
  if repo.behind > 0 then t[#t + 1] = style.dim; t[#t + 1] = " behind " .. repo.behind end
  local function add(n, color, sign)
    if n > 0 then t[#t + 1] = color; t[#t + 1] = "  " .. sign .. n end
  end
  add(k.added, c.added, "+")
  add(k.modified, c.modified, "~")
  add(k.deleted, c.deleted, "-")
  add(k.untracked, c.untracked, "?")
  add(k.conflict, c.conflict, "!")
  return t
end

local function items_width(items)
  local font, w = style.font, 0
  for _, item in ipairs(items) do
    if type(item) == "userdata" then font = item
    elseif type(item) ~= "table" then w = w + font:get_width(tostring(item)) end
  end
  return w
end

local old_get_items = StatusView.get_items
function StatusView:get_items()
  local left, right = old_get_items(self)
  self.git_click_x = nil
  if cfg.statusbar and repo.root then
    local items = status_items()
    self.git_click_x = self.position.x + self.size.x - style.padding.x - items_width(items)
    right[#right + 1] = style.font
    right[#right + 1] = style.dim
    right[#right + 1] = self.separator2
    for _, item in ipairs(items) do right[#right + 1] = item end
  end
  return left, right
end

local old_sv_pressed = StatusView.on_mouse_pressed
function StatusView:on_mouse_pressed(button, x, y, clicks)
  if self.git_click_x and x >= self.git_click_x then
    core.set_active_view(core.last_active_view)
    command.perform("git:diff-all")
    return
  end
  return old_sv_pressed(self, button, x, y, clicks)
end

-- diff view
local DiffView = DocView:extend()
DiffView.is_git_diff_view = true

function DiffView:draw_line_body(line, x, y)
  local text = self.doc.lines[line] or ""
  local c = colors()
  local bg
  if text:match("^@@") then bg = style.accent
  elseif text:match("^%+") and not text:match("^%+%+%+") then bg = c.added
  elseif text:match("^%-") and not text:match("^%-%-%-") then bg = c.deleted
  elseif text:match("^diff ") then bg = style.dim end
  if bg then
    local color = { bg[1], bg[2], bg[3], text:match("^diff ") and 60 or 45 }
    local gw = self:get_gutter_width()
    renderer.draw_rect(self.position.x + gw, y, self.size.x - gw, self:get_line_height(), color)
  end
  return DiffView.super.draw_line_body(self, line, x, y)
end

local function open_diff(title, text)
  local doc = Doc()
  doc:insert(1, 1, text ~= "" and text or "No changes.\n")
  doc:clean()
  doc.get_name = function() return title end
  doc.insert = function() end
  doc.remove = function() end
  doc.save = function() end
  local node = core.root_view:get_active_node()
  local view = DiffView(doc)
  node:add_view(view)
  core.root_view.root_node:update_layout()
  view.scroll.to.y = 0
  core.redraw = true
end

local function diff_for_file(abs)
  local rel = rel_path(abs)
  if not rel then return "" end
  if repo.files[abs] == "untracked" then
    local out = git(repo.root, { "diff", "--no-color", "--no-index", "--", "/dev/null", rel })
    return out or ""
  end
  local out, code = git(repo.root, { "diff", "--no-color", "HEAD", "--", rel })
  if (not out or out == "") and code ~= 0 then
    out = git(repo.root, { "diff", "--no-color", "--cached", "--", rel })
  end
  return out or ""
end

-- commands
local function in_repo_docview()
  local v = core.active_view
  return v and v:is(DocView) and not v.is_git_diff_view and v.doc.filename
    and repo.root and rel_path(doc_abs(v.doc)) ~= nil
end

local function in_repo() return repo.root ~= nil end

local function current_hunk_index(st, line)
  for idx, h in ipairs(st.hunks) do
    local first = h.new_start
    local last = h.kind == "del" and h.new_start or (h.new_start + h.new_count - 1)
    if line >= first and line <= last then return idx end
  end
end

-- hunk popup: click a gutter marker to see the previous version
local function revert_hunk(doc, st, h)
  local old = {}
  for k = h.old_start, h.old_start + h.old_count - 1 do old[#old + 1] = st.base[k] .. "\n" end
  local text = table.concat(old)
  local last = #doc.lines
  if h.new_count > 0 then
    local l2 = h.new_start + h.new_count
    if l2 > last then
      if text == "" and h.new_start > 1 then
        doc:remove(h.new_start - 1, math.huge, last, math.huge)
      else
        doc:remove(h.new_start, 1, last, math.huge)
        if text ~= "" then doc:insert(h.new_start, 1, (text:gsub("\n$", ""))) end
      end
    else
      doc:remove(h.new_start, 1, l2, 1)
      if text ~= "" then doc:insert(h.new_start, 1, text) end
    end
  else
    if h.new_start > last then
      doc:insert(last, math.huge, "\n" .. (text:gsub("\n$", "")))
    else
      doc:insert(h.new_start, 1, text)
    end
  end
  doc:set_selection(math.min(h.new_start, #doc.lines), 1)
  st.change_id = -1
  core.redraw = true
end

local POPUP_ROWS = 14
local POPUP_BUTTONS = { "Rollback", "Copy", "Prev", "Next", "Close" }

local function bar_zone(dv, x)
  return x >= dv.position.x and x < dv.position.x + style.padding.x
end

local function hunk_at_line(doc, line)
  local st = doc_state[doc]
  if not st then return end
  local idx = current_hunk_index(st, line)
  return idx, st
end

local function hunk_anchor(dv, h)
  local line = (h.kind == "del") and h.new_start or (h.new_start + h.new_count - 1)
  return math.max(1, math.min(line, #dv.doc.lines))
end

local function close_popup(dv)
  dv.git_popup = nil
  core.redraw = true
end

local function popup_old_lines(h, st)
  local old = {}
  for k = h.old_start, h.old_start + h.old_count - 1 do old[#old + 1] = st.base[k] end
  return old
end

local function popup_action(dv, name)
  local p = dv.git_popup
  local st = doc_state[dv.doc]
  local h = p and st and st.hunks[p.idx]
  if not h then return close_popup(dv) end
  if name == "Rollback" then
    revert_hunk(dv.doc, st, h)
    close_popup(dv)
  elseif name == "Copy" then
    system.set_clipboard(table.concat(popup_old_lines(h, st), "\n"))
    core.log("Git: copied previous version")
  elseif name == "Prev" or name == "Next" then
    local n = #st.hunks
    p.idx = (name == "Next") and (p.idx % n + 1) or ((p.idx - 2) % n + 1)
    dv:scroll_to_line(hunk_anchor(dv, st.hunks[p.idx]), false, true)
    core.redraw = true
  else
    close_popup(dv)
  end
end

local function draw_popup(dv)
  local p = dv.git_popup
  local st = doc_state[dv.doc]
  local h = p and st and st.hunks[p.idx]
  if not h then dv.git_popup = nil; return end

  local font, ui = dv:get_font(), style.font
  local lh = dv:get_line_height()
  local pad = math.floor(8 * SCALE)
  local gw = dv:get_gutter_width()
  local old = popup_old_lines(h, st)
  local shown = math.min(#old, POPUP_ROWS)
  local rows = (#old == 0) and 1 or (shown + (#old > shown and 1 or 0))
  local bh = ui:get_height() + pad

  -- width: widest of toolbar / content
  local tb_w = pad
  for _, name in ipairs(POPUP_BUTTONS) do tb_w = tb_w + ui:get_width(name) + pad * 2 end
  local label = (#old == 0) and "Added lines" or (h.kind == "del" and "Deleted lines" or "Previous version")
  tb_w = tb_w + ui:get_width(label) + pad * 2
  local w = tb_w
  for i = 1, shown do
    w = math.max(w, font:get_width((old[i]:gsub("\t", "    "))) + pad * 2)
  end
  w = math.min(w, dv.size.x - gw - pad * 2)
  local height = bh + rows * lh + pad

  local anchor = hunk_anchor(dv, h)
  local _, ay = dv:get_line_screen_position(anchor)
  local x = dv.position.x + gw
  local y = ay + lh
  if y + height > dv.position.y + dv.size.y then
    local first = (h.kind == "del") and anchor or math.max(1, h.new_start)
    local _, fy = dv:get_line_screen_position(first)
    y = math.max(dv.position.y, fy - height)
  end

  core.push_clip_rect(dv.position.x, dv.position.y, dv.size.x, dv.size.y)
  local c = colors()
  renderer.draw_rect(x + 2, y + 2, w, height, { 0, 0, 0, 70 })
  renderer.draw_rect(x - 1, y - 1, w + 2, height + 2, style.divider)
  renderer.draw_rect(x, y, w, height, style.background2)

  -- toolbar
  renderer.draw_rect(x, y, w, bh, style.background3)
  local tx = x + pad
  common.draw_text(ui, style.dim, label, "left", tx, y, 0, bh)
  tx = tx + ui:get_width(label) + pad * 2
  p.buttons = {}
  for _, name in ipairs(POPUP_BUTTONS) do
    local bw = ui:get_width(name) + pad * 2
    local bx = tx
    p.buttons[#p.buttons + 1] = { name = name, x = bx, y = y, w = bw, h = bh }
    tx = tx + bw
  end
  local shift = (x + w) - tx - pad
  for _, b in ipairs(p.buttons) do
    b.x = b.x + shift
    if p.hover == b.name then renderer.draw_rect(b.x, b.y, b.w, b.h, style.selection) end
    local color = (b.name == "Rollback") and c.deleted or style.text
    common.draw_text(ui, color, b.name, "center", b.x, b.y, b.w, b.h)
  end

  -- previous content
  local cy = y + bh
  if #old == 0 then
    common.draw_text(font, style.dim, "(these lines did not exist before)", "left", x + pad, cy, 0, lh)
  else
    for i = 1, shown do
      renderer.draw_rect(x, cy, w, lh, { c.deleted[1], c.deleted[2], c.deleted[3], 38 })
      local text = old[i]:gsub("\t", "    ")
      common.draw_text(font, style.text, text, "left", x + pad, cy, 0, lh)
      cy = cy + lh
    end
    if #old > shown then
      common.draw_text(font, style.dim, string.format("... %d more lines", #old - shown), "left", x + pad, cy, 0, lh)
    end
  end
  core.pop_clip_rect()
  p.rect = { x = x, y = y, w = w, h = height }
end

local old_dv_draw = DocView.draw
function DocView:draw()
  old_dv_draw(self)
  if self.git_popup then draw_popup(self) end
end

local old_dv_pressed = DocView.on_mouse_pressed
function DocView:on_mouse_pressed(button, x, y, clicks)
  local p = self.git_popup
  if p and p.rect then
    local r = p.rect
    if common.point_in_rect(x, y, r.x, r.y, r.w, r.h) then
      if button == "left" then
        for _, b in ipairs(p.buttons or {}) do
          if common.point_in_rect(x, y, b.x, b.y, b.w, b.h) then
            popup_action(self, b.name)
            break
          end
        end
      end
      return true
    end
    close_popup(self)
  end
  if button == "left" and cfg.gutter and not self.is_git_diff_view and bar_zone(self, x) then
    local idx = hunk_at_line(self.doc, (self:resolve_screen_position(x, y)))
    if idx then
      self.git_popup = { idx = idx, buttons = {} }
      core.redraw = true
      return true
    end
  end
  return old_dv_pressed(self, button, x, y, clicks)
end

local old_dv_moved = DocView.on_mouse_moved
function DocView:on_mouse_moved(x, y, ...)
  old_dv_moved(self, x, y, ...)
  local p = self.git_popup
  if p and p.rect then
    local r, over = p.rect, nil
    for _, b in ipairs(p.buttons or {}) do
      if common.point_in_rect(x, y, b.x, b.y, b.w, b.h) then over = b.name end
    end
    if p.hover ~= over then p.hover = over; core.redraw = true end
    if common.point_in_rect(x, y, r.x, r.y, r.w, r.h) then
      self.cursor = over and "hand" or "arrow"
    end
  elseif cfg.gutter and not self.is_git_diff_view and bar_zone(self, x)
      and hunk_at_line(self.doc, (self:resolve_screen_position(x, y))) then
    self.cursor = "hand"
  end
end


command.add(in_repo_docview, {
  ["git:diff-file"] = function()
    local doc = core.active_view.doc
    local abs, name = doc_abs(doc), doc:get_name()
    core.add_thread(function()
      local text = diff_for_file(abs)
      open_diff("diff: " .. common.basename(name), text)
    end)
  end,

  ["git:stage-file"] = function()
    local doc = core.active_view.doc
    local rel = rel_path(doc_abs(doc))
    core.add_thread(function()
      git(repo.root, { "add", "--", rel })
      core.log("Staged %s", rel)
      request_refresh()
    end)
  end,

  ["git:unstage-file"] = function()
    local doc = core.active_view.doc
    local rel = rel_path(doc_abs(doc))
    core.add_thread(function()
      local _, code = git(repo.root, { "restore", "--staged", "--", rel })
      if code ~= 0 then git(repo.root, { "reset", "-q", "HEAD", "--", rel }) end
      core.log("Unstaged %s", rel)
      request_refresh()
    end)
  end,

  ["git:revert-hunk"] = function()
    local doc = core.active_view.doc
    local st = doc_state[doc]
    if not st or not st.base then return core.log("Git: no base version for this file") end
    recompute(doc, st)
    local idx = current_hunk_index(st, (doc:get_selection()))
    if not idx then return core.log("Git: no change under the cursor") end
    revert_hunk(doc, st, st.hunks[idx])
  end,

  ["git:next-hunk"] = function()
    local dv = core.active_view
    local st = doc_state[dv.doc]
    if not st or #st.hunks == 0 then return end
    local line = dv.doc:get_selection()
    local target
    for _, h in ipairs(st.hunks) do
      if h.new_start > line then target = h; break end
    end
    target = target or st.hunks[1]
    local l = math.min(target.new_start, #dv.doc.lines)
    dv.doc:set_selection(l, 1)
    dv:scroll_to_line(l, true, true)
  end,

  ["git:previous-hunk"] = function()
    local dv = core.active_view
    local st = doc_state[dv.doc]
    if not st or #st.hunks == 0 then return end
    local line = dv.doc:get_selection()
    local target
    for k = #st.hunks, 1, -1 do
      if st.hunks[k].new_start < line then target = st.hunks[k]; break end
    end
    target = target or st.hunks[#st.hunks]
    local l = math.min(target.new_start, #dv.doc.lines)
    dv.doc:set_selection(l, 1)
    dv:scroll_to_line(l, true, true)
  end,
})

command.add(in_repo, {
  ["git:diff-all"] = function()
    core.add_thread(function()
      local out, code = git(repo.root, { "diff", "--no-color", "HEAD" })
      if (not out or out == "") and code ~= 0 then
        out = git(repo.root, { "diff", "--no-color", "--cached" })
      end
      local extra = {}
      for abs, st in pairs(repo.files) do
        if st == "untracked" then extra[#extra + 1] = rel_path(abs) end
      end
      table.sort(extra)
      out = out or ""
      if #extra > 0 then
        out = out .. "\n# Untracked files\n" .. table.concat(extra, "\n") .. "\n"
      end
      open_diff("diff: all changes", out)
    end)
  end,
})

command.add(function() return core.active_view and core.active_view.git_popup ~= nil end, {
  ["git:close-popup"] = function() close_popup(core.active_view) end,
})

command.add(nil, {
  ["git:refresh"] = request_refresh,
})

keymap.add {
  ["escape"] = "git:close-popup",
  ["ctrl+alt+d"] = "git:diff-file",
  ["ctrl+alt+shift+d"] = "git:diff-all",
  ["ctrl+alt+."] = "git:next-hunk",
  ["ctrl+alt+,"] = "git:previous-hunk",
}

-- refresh right after saving
local old_save = Doc.save
function Doc:save(...)
  local ret = old_save(self, ...)
  request_refresh()
  local st = doc_state[self]
  if st then st.change_id = -1 end
  return ret
end

repo.doc_state = doc_state
return repo
