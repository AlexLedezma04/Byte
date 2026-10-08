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
    command.perform("git:show-changes")
    return
  end
  return old_sv_pressed(self, button, x, y, clicks)
end

-- compare view: HEAD on the left (read-only), the working copy on the right.
local CompareView = DocView:extend()
CompareView.is_git_diff_view = true

-- read-only Doc used only for syntax highlighting
local function snapshot_doc(filename, lines)
  local d = Doc()
  d.filename = filename
  d.lines = {}
  for i, l in ipairs(lines) do d.lines[i] = l .. "\n" end
  if #d.lines == 0 then d.lines[1] = "\n" end
  d:reset_syntax()
  d.highlighter:reset()
  return d
end

-- pairs old/new lines into rows; changed regions are padded so both sides align
local function build_rows(old, new, hunks)
  local rows, starts = {}, {}
  local i, j = 1, 1
  for _, h in ipairs(hunks) do
    while i < h.old_start do
      rows[#rows + 1] = { l = i, r = j, kind = "same" }
      i, j = i + 1, j + 1
    end
    starts[#starts + 1] = #rows + 1
    for k = 0, math.max(h.old_count, h.new_count) - 1 do
      rows[#rows + 1] = {
        l = k < h.old_count and h.old_start + k or nil,
        r = k < h.new_count and h.new_start + k or nil,
        kind = h.kind,
      }
    end
    i, j = h.old_start + h.old_count, h.new_start + h.new_count
  end
  while i <= #old or j <= #new do
    rows[#rows + 1] = { l = i <= #old and i or nil, r = j <= #new and j or nil, kind = "same" }
    i, j = i + 1, j + 1
  end
  return rows, starts
end

local function is_binary_file(abs)
  local fp = io.open(abs, "rb")
  if not fp then return false end
  local head = fp:read(8000) or ""
  fp:close()
  return head:find("\0", 1, true) ~= nil
end

local function read_only(doc)
  doc.insert = function() end
  doc.remove = function() end
  doc.save = function() end
  return doc
end

function CompareView:new(abs, status)
  self.abs, self.status = abs, status
  local doc
  if status ~= "deleted" then
    self.file_binary = is_binary_file(abs)
    if not self.file_binary then
      local ok, d = core.try(core.open_doc, abs)
      if ok then doc = d end
    end
  end
  self.read_only = doc == nil
  CompareView.super.new(self, doc or read_only(snapshot_doc(abs, {})))
  self.rows, self.hunk_starts, self.line_row = {}, {}, {}
  self.old_max_width = 0
end

function CompareView:get_name()
  local post = (not self.read_only and self.doc:is_dirty()) and "*" or ""
  return "Diff: " .. common.basename(self.abs) .. post
end

function CompareView:get_header_height()
  return style.font:get_height() + style.padding.y * 2
end

function CompareView:get_pane_layout()
  local font = self:get_font()
  local old_n = self.old_doc and #self.old_doc.lines or 0
  local digits = math.max(old_n, #self.doc.lines, 99)
  local gutter = font:get_width(tostring(digits)) + style.padding.x * 2
  local half = math.floor(self.size.x / 2)
  local text_w = self.size.x - half - gutter - style.scrollbar_size
  return half, gutter, text_w
end

function CompareView:get_gutter_width()
  local half, gutter = self:get_pane_layout()
  return half + gutter
end

-- base (HEAD) version, reloaded whenever the repository changes
function CompareView:load_base()
  local rel = repo.root and rel_path(self.abs)
  local old, binary = {}, false
  if rel and self.status ~= "untracked" then
    local text, code = git(repo.root, { "show", "HEAD:" .. rel })
    if code == 0 and text then
      binary = text:find("\0", 1, true) ~= nil
      old = split_lines(text)
    end
  end
  if binary then old = {} end
  self.base_binary = binary
  self.base = old
  self.old_doc = snapshot_doc(self.abs, old)
  local font, w = self:get_font(), 0
  for _, l in ipairs(old) do w = math.max(w, font:get_width(l)) end
  self.old_max_width = w
  self.rows_cid = nil
  core.redraw = true
end

-- aligns the document with the base; cheap enough to redo on every edit
function CompareView:sync_rows()
  if not self.base then return end
  local cid = self.doc:get_change_id()
  if self.rows_cid == cid and self.rows_base == self.base then return end
  self.rows_cid, self.rows_base = cid, self.base
  local new = self.read_only and {} or doc_lines(self.doc)
  self.rows, self.hunk_starts = build_rows(self.base, new, diff_lines(self.base, new, cfg.max_diff_lines))
  local line_row = {}
  for i, row in ipairs(self.rows) do
    if row.r then line_row[row.r] = i end
  end
  -- an empty document still has one (empty) line to put the caret on
  if not self.read_only then
    for k = #line_row + 1, #self.doc.lines do
      self.rows[#self.rows + 1] = { r = k, kind = "same" }
      line_row[k] = #self.rows
    end
  end
  self.line_row = line_row
end

function CompareView:update()
  if self.base_rev ~= rev and not self.loading then
    self.base_rev, self.loading = rev, true
    core.add_thread(function()
      core.try(self.load_base, self)
      self.loading = false
    end)
  end
  self:sync_rows()
  CompareView.super.update(self)
end

-- row-based geometry: document lines are placed on their aligned rows
function CompareView:row_of(line)
  local r = self.line_row[line]
  if r then return r end
  local n = #self.line_row
  return (n > 0 and self.line_row[n] or 0) + (line - n)
end

function CompareView:get_rows_top()
  local _, oy = self:get_content_offset()
  return oy + self:get_header_height() + style.padding.y
end

function CompareView:get_row_count()
  return math.max(#self.rows, #self.doc.lines)
end

function CompareView:get_scrollable_size()
  return self:get_header_height() + style.padding.y
    + self:get_line_height() * (self:get_row_count() - 1) + self.size.y
end

function CompareView:get_line_screen_position(idx)
  local half, gutter = self:get_pane_layout()
  local x = self.position.x + half + gutter - self.scroll.x
  return x, self:get_rows_top() + (self:row_of(idx) - 1) * self:get_line_height()
end

function CompareView:get_visible_rows()
  local lh = self:get_line_height()
  local top = self:get_rows_top()
  local first = math.max(1, math.floor((self.position.y + self:get_header_height() - top) / lh) + 1)
  local last = math.min(self:get_row_count(), math.floor((self.position.y + self.size.y - top) / lh) + 1)
  return first, last
end

function CompareView:get_visible_line_range()
  local first, last = self:get_visible_rows()
  if #self.rows == 0 then
    return math.min(first, #self.doc.lines), math.min(last, #self.doc.lines)
  end
  local minl, maxl
  for i = first, last do
    local row = self.rows[i]
    if row and row.r then minl = minl or row.r; maxl = row.r end
  end
  return minl or 1, maxl or 1
end

function CompareView:row_at(y)
  return math.floor((y - self:get_rows_top()) / self:get_line_height()) + 1
end

function CompareView:resolve_screen_position(x, y)
  local row = self:row_at(y)
  local line
  if #self.rows == 0 then
    line = row
  else
    row = common.clamp(row, 1, #self.rows)
    for i = row, #self.rows do
      if self.rows[i].r then line = self.rows[i].r; break end
    end
    if not line then
      for i = row, 1, -1 do
        if self.rows[i].r then line = self.rows[i].r; break end
      end
    end
  end
  line = common.clamp(line or #self.doc.lines, 1, #self.doc.lines)
  local tx = self:get_line_screen_position(line)
  return line, self:get_x_offset_col(line, x - tx)
end

function CompareView:get_row_y(line)
  return self:get_header_height() + style.padding.y + (self:row_of(line) - 1) * self:get_line_height()
end

function CompareView:scroll_to_line(line, ignore_if_visible, instant)
  local min, max = self:get_visible_line_range()
  if ignore_if_visible and line > min and line < max then return end
  self.scroll.to.y = math.max(0, self:get_row_y(line) - self.size.y / 2)
  if instant then self.scroll.y = self.scroll.to.y end
end

function CompareView:scroll_to_make_visible(line, col)
  local lh = self:get_line_height()
  local ry = self:get_row_y(line)
  self.scroll.to.y = math.min(self.scroll.to.y, ry - self:get_header_height() - lh)
  self.scroll.to.y = math.max(self.scroll.to.y, ry + lh * 2 - self.size.y, 0)
  local _, _, text_w = self:get_pane_layout()
  local xoffset = self:get_col_x_offset(line, col)
  self.scroll.to.x = math.max(0, xoffset - text_w + text_w / 5)
end

function CompareView:get_h_scroll_limit()
  local _, _, text_w = self:get_pane_layout()
  local w = math.max(self.old_max_width, self:get_max_line_width())
  return math.max(0, w + self:get_font():get_width(" ") * 4 - text_w)
end

function CompareView:get_h_scrollbar_rect()
  return 0, 0, 0, 0
end

-- only the working copy (right pane) takes the mouse for editing
function CompareView:in_edit_area(x, y)
  local half = self:get_pane_layout()
  return not self.read_only and x >= self.position.x + half
    and y >= self.position.y + self:get_header_height()
end

function CompareView:on_mouse_pressed(button, x, y, clicks)
  if self:scrollbar_overlaps_point(x, y) or self:in_edit_area(x, y) then
    return CompareView.super.on_mouse_pressed(self, button, x, y, clicks)
  end
  return true
end

function CompareView:on_mouse_moved(x, y, ...)
  CompareView.super.on_mouse_moved(self, x, y, ...)
  if not self:in_edit_area(x, y) then self.cursor = "arrow" end
end

function CompareView:goto_hunk(dir)
  local starts = self.hunk_starts
  if #starts == 0 then return end
  local lh = self:get_line_height()
  local cur = math.floor(self.scroll.to.y / lh) + 1 + 2
  local target
  if dir > 0 then
    for _, r in ipairs(starts) do if r > cur then target = r; break end end
    target = target or starts[1]
  else
    for k = #starts, 1, -1 do if starts[k] < cur then target = starts[k]; break end end
    target = target or starts[#starts]
  end
  self.scroll.to.y = math.max(0, (target - 3) * lh)
  -- put the caret on the change so typing edits it right away
  local row = self.rows[target]
  if row and row.r and not self.read_only then self.doc:set_selection(row.r, 1) end
end

local function tint(color, a) return { color[1], color[2], color[3], a } end

function CompareView:draw_old_line(idx, x, y, w, gutter, lh, bg)
  local font = self:get_font()
  if bg then renderer.draw_rect(x, y, w, lh, bg) end
  if not idx then return end
  local ty = y + self:get_line_text_y_offset()
  renderer.draw_text(font, tostring(idx), x + style.padding.x, ty, style.line_number)
  core.push_clip_rect(x + gutter, y, w - gutter, lh)
  local tx = x + gutter - self.scroll.x
  for _, type, text in self.old_doc.highlighter:each_token(idx) do
    tx = renderer.draw_text(font, text, tx, ty, style.syntax[type])
  end
  core.pop_clip_rect()
end

-- a hint centered inside one pane, so it never crosses the divider
local function draw_pane_message(text, x, y, w, h)
  core.push_clip_rect(x, y, w, h)
  common.draw_text(style.sidebar_font or style.font, style.dim, text, "center", x, y, w, h)
  core.pop_clip_rect()
end

function CompareView:draw()
  self:sync_rows()
  self:draw_background(style.background)
  local px, py, sw = self.position.x, self.position.y, self.size.x
  local hh = self:get_header_height()
  local font = self:get_font()
  font:set_tab_width(font:get_width(" ") * config.indent_size)
  local half, gutter = self:get_pane_layout()
  local rw = sw - half
  local lh = self:get_line_height()
  local c = colors()
  local filler = style.background2
  local top = self:get_rows_top()

  core.push_clip_rect(px, py + hh, sw, self.size.y - hh)
  if self.base then
    local first, last = self:get_visible_rows()
    local line1, _, line2 = self.doc:get_selection(true)
    for i = first, math.min(last, #self.rows) do
      local row = self.rows[i]
      local y = top + (i - 1) * lh
      local lbg, rbg
      if row.kind == "mod" then
        lbg, rbg = tint(c.modified, 38), tint(c.modified, 38)
      elseif row.kind == "del" then
        lbg = tint(c.deleted, 45)
      elseif row.kind == "add" then
        rbg = tint(c.added, 40)
      end
      if row.kind ~= "same" then
        if not row.l then lbg = filler end
        if not row.r then rbg = filler end
      end
      self:draw_old_line(row.l, px, y, half, gutter, lh, lbg)
      if rbg then renderer.draw_rect(px + half, y, rw, lh, rbg) end
      if row.r and not self.read_only then
        local color = (row.r >= line1 and row.r <= line2) and style.line_number2 or style.line_number
        renderer.draw_text(font, tostring(row.r), px + half + style.padding.x,
          y + self:get_line_text_y_offset(), color)
        core.push_clip_rect(px + half + gutter, y, rw - gutter, lh)
        self:draw_line_body(row.r, px + half + gutter - self.scroll.x, y)
        core.pop_clip_rect()
      end
    end

    -- per-pane notes for sides that have nothing to show
    local binary = self.file_binary or self.base_binary
    local msg_y, msg_h = top, lh * 2
    local left_msg = binary and "Binary file"
      or ((self.status == "untracked" or self.status == "added") and "Not in HEAD (new file)")
      or nil
    local right_msg = binary and "Binary file"
      or (self.status == "deleted" and "File deleted")
      or (self.read_only and "Cannot be shown") or nil
    if left_msg then draw_pane_message(left_msg, px, msg_y, half, msg_h) end
    if right_msg then draw_pane_message(right_msg, px + half, msg_y, rw, msg_h) end
  else
    draw_pane_message("Loading...", px, top, half, lh * 2)
    draw_pane_message("Loading...", px + half, top, rw, lh * 2)
  end
  core.pop_clip_rect()

  -- center divider
  renderer.draw_rect(px + half - style.divider_size, py, style.divider_size, self.size.y, style.divider)

  -- header: what each side shows
  renderer.draw_rect(px, py, sw, hh, style.background2)
  renderer.draw_rect(px, py + hh - style.divider_size, sw, style.divider_size, style.divider)
  local rel = rel_path(self.abs) or common.basename(self.abs)
  local left = (self.status == "untracked" or self.status == "added") and "(new file)" or "HEAD"
  local right = self.status == "deleted" and "(deleted)" or "Working copy"
  local bold, regular = style.sidebar_tab_font or style.font, style.sidebar_font or style.font
  core.push_clip_rect(px, py, half - style.padding.x, hh)
  local x = common.draw_text(bold, style.accent, left, nil, px + style.padding.x, py, 0, hh)
  common.draw_text(regular, style.dim, "  " .. rel, nil, x, py, 0, hh)
  core.pop_clip_rect()
  core.push_clip_rect(px + half, py, rw, hh)
  x = common.draw_text(bold, style.accent, right, nil, px + half + style.padding.x, py, 0, hh)
  local n = #self.hunk_starts
  local info = n == 1 and "  1 change" or ("  " .. n .. " changes")
  if not self.read_only then info = info .. "  ·  editable" end
  common.draw_text(regular, style.dim, info, nil, x, py, 0, hh)
  core.pop_clip_rect()

  self:draw_scrollbar()
end

-- opens (or focuses) the compare view for `abs` in the editor area
local function open_compare(abs, status)
  for _, v in ipairs(core.root_view.root_node:get_children()) do
    if v.is_git_diff_view and v.abs == abs then
      v.status = status or v.status
      local node = core.root_view.root_node:get_node_for_view(v)
      node:set_active_view(v)
      core.set_active_view(v)
      return v
    end
  end
  local node = core.root_view:get_active_node()
  if node.locked and core.last_active_view then
    core.set_active_view(core.last_active_view)
    node = core.root_view:get_active_node()
  end
  local view = CompareView(abs, status or repo.files[abs] or "modified")
  node:add_view(view)
  core.root_view.root_node:update_layout()
  core.redraw = true
  return view
end

-- commands
local function in_repo_docview()
  local v = core.active_view
  return v and v:is(DocView) and not v.is_git_diff_view and v.doc.filename
    and repo.root and rel_path(doc_abs(v.doc)) ~= nil
end

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
    open_compare(doc_abs(core.active_view.doc))
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

command.add(function() return core.active_view and core.active_view.is_git_diff_view end, {
  ["git:compare-next-change"] = function() core.active_view:goto_hunk(1) end,
  ["git:compare-previous-change"] = function() core.active_view:goto_hunk(-1) end,
})

command.add(function() return core.active_view and core.active_view.git_popup ~= nil end, {
  ["git:close-popup"] = function() close_popup(core.active_view) end,
})

-- sidebar "Git" tab: changed files grouped like IntelliJ's commit window
local GROUPS = {
  { id = "changes", name = "Changes",       statuses = { modified = true, conflict = true } },
  { id = "new",     name = "New files",     statuses = { added = true, untracked = true } },
  { id = "deleted", name = "Deleted files", statuses = { deleted = true } },
}

local git_panel = { id = "git", name = "Git", collapsed = {} }

-- grouped, sorted file entries; rebuilt only when the status changes
local function panel_groups()
  if git_panel.cache_sig == repo.signature and git_panel.cache_root == repo.root then
    return git_panel.cache
  end
  local groups = {}
  for _, g in ipairs(GROUPS) do groups[#groups + 1] = { def = g, files = {} } end
  for abs, st in pairs(repo.files) do
    for _, g in ipairs(groups) do
      if g.def.statuses[st] then
        local rel = rel_path(abs) or abs
        g.files[#g.files + 1] = {
          abs = abs, rel = rel, status = st,
          name = rel:match("[^/]+$"), dir = rel:match("^(.*)/[^/]+$"),
        }
      end
    end
  end
  for _, g in ipairs(groups) do
    table.sort(g.files, function(a, b) return a.rel < b.rel end)
  end
  git_panel.cache, git_panel.cache_sig, git_panel.cache_root = groups, repo.signature, repo.root
  return groups
end

local STATUS_LETTER = { modified = "M", added = "A", untracked = "U", deleted = "D", conflict = "C" }

function git_panel.draw(view, x, y, w)
  local h = view:get_item_height()
  local pad = style.padding.x
  local font = style.sidebar_font
  local c = colors()
  git_panel.hits = {}
  y = y + style.padding.y
  if not repo.root then
    local msg = core.project_dir and "Not a git repository" or "No folder open"
    common.draw_text(font, style.dim, msg, nil, x + pad, y, 0, h)
    return y + h
  end

  -- branch: label, then name with ahead/behind badges
  view:draw_label("Branch", x + pad, y, h, style.dim)
  y = y + h
  local bx = common.draw_text(font, style.accent, repo.branch or "?", nil, x + pad, y, 0, h)
  bx = bx + math.floor(6 * SCALE)
  if repo.ahead > 0 then
    bx = bx + view:draw_badge("↑" .. repo.ahead, bx, y, h, c.added) + math.floor(4 * SCALE)
  end
  if repo.behind > 0 then
    view:draw_badge("↓" .. repo.behind, bx, y, h, c.modified)
  end
  y = y + h + style.padding.y
  renderer.draw_rect(x + pad, y - math.floor(style.padding.y / 2), w - pad * 2,
    style.divider_size, style.divider)

  local active = core.active_view
  local active_abs = active and active.is_git_diff_view and active.abs
  local icon_w = style.icon_font:get_width("D")
  local chevron_w = style.icon_font:get_width("+")
  local guide_color = { style.dim[1], style.dim[2], style.dim[3], 110 }
  local accent_bar = math.max(2, math.floor(2 * SCALE))
  local label_w = 0
  for _, l in pairs(STATUS_LETTER) do label_w = math.max(label_w, style.sidebar_label_font:get_width(l)) end
  local any = false
  for _, g in ipairs(panel_groups()) do
    if #g.files > 0 then
      any = true
      local id = g.def.id
      local hovered = git_panel.hovered == id
      if hovered then renderer.draw_rect(x, y, w, h, style.line_highlight) end
      local color = hovered and style.accent or style.text
      local collapsed = git_panel.collapsed[id]
      common.draw_text(style.icon_font, style.dim, collapsed and "+" or "-", nil, x + pad, y, 0, h)
      view:draw_label(g.def.name, x + pad + chevron_w + math.floor(6 * SCALE), y, h, color)
      view:draw_badge(tostring(#g.files), x + w - pad, y, h, style.text, true)
      git_panel.hits[#git_panel.hits + 1] = { y = y, h = h, group = id }
      y = y + h
      if not collapsed then
        local first_y = y
        for _, f in ipairs(g.files) do
          if f.abs == active_abs then
            renderer.draw_rect(x, y, w, h, style.line_highlight)
            renderer.draw_rect(x, y, accent_bar, h, style.caret)
          elseif git_panel.hovered == f.abs then
            renderer.draw_rect(x, y, w, h, style.line_highlight)
          end
          local fc = c[f.status] or c.modified
          local right = x + w - pad
          -- status letter on the right, like IntelliJ / VS Code
          common.draw_text(style.sidebar_label_font, fc, STATUS_LETTER[f.status] or "?",
            "center", right - label_w, y, label_w, h)
          right = right - label_w - math.floor(8 * SCALE)
          local tx = x + pad * 2
          common.draw_text(style.icon_font, fc, "f", nil, tx, y, 0, h)
          tx = tx + icon_w + font:get_width(" ")
          core.push_clip_rect(tx, y, math.max(0, right - tx), h)
          tx = common.draw_text(font, fc, f.name, nil, tx, y, 0, h)
          if f.dir then
            common.draw_text(font, style.dim, "  " .. f.dir, nil, tx, y, 0, h)
          end
          core.pop_clip_rect()
          git_panel.hits[#git_panel.hits + 1] = { y = y, h = h, file = f }
          y = y + h
        end
        -- guide tying the files to their group
        local gx = x + pad + math.floor(chevron_w / 2)
        renderer.draw_rect(gx, first_y, style.divider_size, y - first_y, guide_color)
      end
      y = y + math.floor(style.padding.y / 2)
    end
  end
  if not any then
    common.draw_text(font, style.dim, "No changes", nil, x + pad, y, 0, h)
    y = y + h
  end
  return y
end

local function panel_hit(py)
  for _, hit in ipairs(git_panel.hits or {}) do
    if py >= hit.y and py < hit.y + hit.h then return hit end
  end
end

function git_panel.on_mouse_moved(view, px, py)
  local hit = panel_hit(py)
  local id = hit and (hit.group or hit.file.abs)
  if git_panel.hovered ~= id then git_panel.hovered = id; core.redraw = true end
  view.cursor = hit and "hand" or "arrow"
end

function git_panel.on_mouse_pressed(view, button, px, py)
  local hit = panel_hit(py)
  if not hit or button ~= "left" then return end
  if hit.group then
    git_panel.collapsed[hit.group] = not git_panel.collapsed[hit.group]
    core.redraw = true
  else
    open_compare(hit.file.abs, hit.file.status)
  end
end

if ok_tv and type(tv) == "table" and tv.add_panel then
  tv:add_panel(git_panel)
end

command.add(nil, {
  ["git:refresh"] = request_refresh,

  ["git:show-changes"] = function()
    if not (ok_tv and tv.set_panel) then return end
    tv.visible = true
    tv:set_panel("git")
    request_refresh()
  end,
})

keymap.add {
  ["escape"] = "git:close-popup",
  ["ctrl+alt+d"] = "git:diff-file",
  ["ctrl+alt+shift+d"] = "git:show-changes",
  ["ctrl+alt+."] = { "git:next-hunk", "git:compare-next-change" },
  ["ctrl+alt+,"] = { "git:previous-hunk", "git:compare-previous-change" },
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
