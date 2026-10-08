local core = require "core"
local syntax = require "core.syntax"

local tokenizer = {}
local bad_patterns = {}


local function push_token(t, type, text)
  type = type or "normal"
  local prev_type = t[#t-1]
  local prev_text = t[#t]
  if prev_type and (prev_type == type or prev_text:find("^%s*$")) then
    t[#t-1] = type
    t[#t] = prev_text .. text
  else
    table.insert(t, type)
    table.insert(t, text)
  end
end


-- find_results: { start, end, [position captures...] };
local function push_tokens(t, syn, pattern, full_text, find_results)
  if #find_results > 2 then
    if find_results[3] ~= find_results[1] then
      table.insert(find_results, 3, find_results[1])
    end
    table.insert(find_results, find_results[2] + 1)
    for i = 3, #find_results - 1 do
      local start = find_results[i]
      local fin = find_results[i + 1] - 1
      local type = pattern.type[i - 2]
      local text = full_text:sub(start, fin)
      push_token(t, syn.symbols[text] or type, text)
    end
  else
    local start, fin = find_results[1], find_results[2]
    local text = full_text:sub(start, fin)
    push_token(t, syn.symbols[text] or pattern.type, text)
  end
end


-- PCRE subset -> Lua pattern
local magic = "^$()%.[]*+-?"

-- translates the regex features language plugins commonly use
local function translate_regex(re)
  local out, i, n = {}, 1, #re
  local last_atom_start
  local function emit_atom(s) last_atom_start = #out + 1; out[#out + 1] = s end
  while i <= n do
    local c = re:sub(i, i)
    if c == "\\" then
      local d = re:sub(i + 1, i + 1)
      local classes = { d = "%d", D = "%D", w = "[%w_]", W = "[^%w_]", s = "%s", S = "%S", n = "\n", t = "\t" }
      if classes[d] then emit_atom(classes[d])
      elseif d:match("%p") then emit_atom("%" .. d)
      else emit_atom(d) end
      i = i + 2
    elseif c == "[" then
      local j, parts = i + 1, { "[" }
      if re:sub(j, j) == "^" then parts[#parts + 1] = "^"; j = j + 1 end
      while j <= n and re:sub(j, j) ~= "]" do
        local d = re:sub(j, j)
        if d == "\\" then
          local e = re:sub(j + 1, j + 1)
          local classes = { d = "%d", w = "%w_", s = "%s" }
          parts[#parts + 1] = classes[e] or ("%" .. e)
          j = j + 2
        else
          parts[#parts + 1] = (d == "%" and "%%") or d
          j = j + 1
        end
      end
      if j > n then return nil end
      parts[#parts + 1] = "]"
      emit_atom(table.concat(parts))
      i = j + 1
    elseif c == "{" then
      local a, b, close = re:match("^{(%d*),?(%d*)}()", i)
      local has_comma = re:sub(i, close or i):find(",")
      if not a or not last_atom_start then return nil end
      local atom = table.concat(out, "", last_atom_start)
      for k = #out, last_atom_start, -1 do out[k] = nil end
      a = tonumber(a) or 0
      b = has_comma and tonumber(b) or (has_comma and nil or a)
      for _ = 1, a do out[#out + 1] = atom end
      if b then
        for _ = a + 1, b do out[#out + 1] = atom .. "?" end
      else
        out[#out + 1] = atom .. "*"
      end
      last_atom_start = nil
      i = close
    elseif c == "*" or c == "+" or c == "?" then
      if not last_atom_start then return nil end
      out[#out + 1] = c
      last_atom_start = nil
      i = i + 1
    elseif c == "(" or c == ")" or c == "|" then
      return nil
    elseif c == "." then
      emit_atom(".")
      i = i + 1
    elseif c == "^" and i == 1 then
      out[#out + 1] = "^"
      i = i + 1
    elseif c == "$" and i == n then
      out[#out + 1] = "$"
      i = i + 1
    else
      emit_atom(magic:find(c, 1, true) and ("%" .. c) or c)
      i = i + 1
    end
  end
  return table.concat(out)
end

-- turn `regex` patterns into `pattern` ones once per syntax
local function prepare_patterns(syn)
  if syn.prepared then return end
  syn.prepared = true
  syn.symbols = syn.symbols or {}
  for _, p in ipairs(syn.patterns or {}) do
    if p.regex and not p.pattern then
      if type(p.regex) == "table" then
        local start = translate_regex(p.regex[1])
        local fin = translate_regex(p.regex[2])
        if start and fin then
          p.pattern = { start, fin, p.regex[3] }
        else
          p.disabled = true
        end
      else
        p.pattern = translate_regex(p.regex)
        p.disabled = p.pattern == nil
      end
      if p.disabled then
        core.log_quiet("Syntax %s: unsupported regex %s skipped",
          syn.name or "?", tostring(type(p.regex) == "table" and p.regex[1] or p.regex))
      end
    end
  end
end


-- subsyntax state
local function get_syntax(ref)
  local syn = type(ref) == "table" and ref or syntax.get(ref)
  prepare_patterns(syn)
  return syn
end

local function retrieve_syntax_state(incoming_syntax, state)
  local current_syntax, subsyntax_info, current_pattern_idx, current_level =
    incoming_syntax, nil, state:byte(1) or 0, 1
  if current_pattern_idx > 0 and current_syntax.patterns[current_pattern_idx] then
    for i = 1, #state do
      local target = state:byte(i)
      if target ~= 0 then
        local p = current_syntax.patterns[target]
        if p and p.syntax then
          subsyntax_info = p
          current_syntax = get_syntax(p.syntax)
          current_pattern_idx = 0
          current_level = i + 1
        else
          current_pattern_idx = p and target or 0
          break
        end
      else
        break
      end
    end
  end
  return current_syntax, subsyntax_info, current_pattern_idx, current_level
end

local function report_bad_pattern(syn, pattern_idx, msg, ...)
  bad_patterns[syn] = bad_patterns[syn] or {}
  if bad_patterns[syn][pattern_idx] then return end
  bad_patterns[syn][pattern_idx] = true
  local p = syn.patterns[pattern_idx]
  core.log_quiet("Malformed pattern #%d <%s> in %s language plugin. " .. msg,
    pattern_idx, tostring(type(p.pattern) == "table" and p.pattern[1] or p.pattern),
    syn.name or "unnamed", ...)
end


function tokenizer.tokenize(incoming_syntax, text, state)
  local res = {}
  local i = 1

  state = state or string.char(0)
  prepare_patterns(incoming_syntax)

  if #incoming_syntax.patterns == 0 then
    return { "normal", text }, state
  end

  local current_syntax, subsyntax_info, current_pattern_idx, current_level =
    retrieve_syntax_state(incoming_syntax, state)

  local function set_subsyntax_pattern_idx(pattern_idx)
    current_pattern_idx = pattern_idx
    local state_len = #state
    if current_level > state_len then
      state = state .. string.char(pattern_idx)
    elseif state_len == 1 then
      state = string.char(pattern_idx)
    else
      state = state:sub(1, current_level - 1) .. string.char(pattern_idx) .. state:sub(current_level + 1)
    end
  end

  local function push_subsyntax(entering_syntax, pattern_idx)
    set_subsyntax_pattern_idx(pattern_idx)
    current_level = current_level + 1
    subsyntax_info = entering_syntax
    current_syntax = get_syntax(entering_syntax.syntax)
    current_pattern_idx = 0
  end

  local function pop_subsyntax()
    current_level = current_level - 1
    state = state:sub(1, current_level)
    set_subsyntax_pattern_idx(0)
    current_syntax, subsyntax_info, current_pattern_idx, current_level =
      retrieve_syntax_state(incoming_syntax, state)
  end

  local function find_text(text, p, offset, at_start, close)
    if p.disabled then return end
    local target, found = p.pattern, { 1, offset - 1 }
    local p_idx = close and 2 or 1
    local code = type(target) == "table" and target[p_idx] or target

    if p.whole_line == nil then p.whole_line = {} end
    if p.whole_line[p_idx] == nil then
      p.whole_line[p_idx] = code:find("^%^") and true or false
      if p.whole_line[p_idx] then
        if type(target) == "table" then
          target[p_idx] = code:sub(2)
          code = target[p_idx]
        else
          p.pattern = code:sub(2)
          code = p.pattern
        end
      end
    end

    repeat
      local next = found[2] + 1
      if p.whole_line[p_idx] and next > 1 then return end
      found = { text:find((at_start or p.whole_line[p_idx]) and "^" .. code or code, next) }
      if found[1] and type(target) == "table" and target[3] then
        local count = 0
        for k = found[1] - 1, 1, -1 do
          if text:byte(k) ~= target[3]:byte() then break end
          count = count + 1
        end
        if count % 2 == 0 then
          break
        elseif not close then
          return
        end
      end
    until not found[1] or not close or type(target) ~= "table" or not target[3]
    return table.unpack(found)
  end

  local text_len = #text
  while i <= text_len do
    if current_pattern_idx > 0 then
      local p = current_syntax.patterns[current_pattern_idx]
      local find_results = { find_text(text, p, i, false, true) }
      local s, e = find_results[1], find_results[2]

      local cont = true
      if subsyntax_info then
        local ss = find_text(text, subsyntax_info, i, false, true)
        if ss and (s == nil or ss < s) then
          push_token(res, p.type, text:sub(i, ss - 1))
          i = ss
          cont = false
        end
      end
      if cont then
        if s then
          if s > i then push_token(res, p.type, text:sub(i, s - 1)) end
          push_tokens(res, current_syntax, p, text, find_results)
          set_subsyntax_pattern_idx(0)
          i = e + 1
        else
          push_token(res, p.type, text:sub(i))
          break
        end
      end
    end

    -- end of the current subsyntax
    while subsyntax_info do
      local s, e = find_text(text, subsyntax_info, i, true, true)
      if s then
        push_token(res, subsyntax_info.type, text:sub(i, e))
        pop_subsyntax()
        i = e + 1
      else
        break
      end
    end
    if i > text_len then break end

    -- find matching pattern
    local matched = false
    for n, p in ipairs(current_syntax.patterns) do
      local find_results = { find_text(text, p, i, true, false) }
      if find_results[1] and find_results[1] > find_results[2] then
        report_bad_pattern(current_syntax, n, "Pattern matched, but nothing was captured.")
      elseif find_results[1] then
        local type_is_table = type(p.type) == "table"
        local n_types = type_is_table and #p.type or 1
        if #find_results == 2 and type_is_table then
          report_bad_pattern(current_syntax, n, "Token type is a table, but a string was expected.")
          p.type = p.type[1]
        elseif #find_results - 1 > n_types then
          report_bad_pattern(current_syntax, n, "Not enough token types: got %d needed %d.", n_types, #find_results - 1)
        end

        push_tokens(res, current_syntax, p, text, find_results)
        if type(p.pattern) == "table" then
          if p.syntax then
            push_subsyntax(p, n)
          else
            set_subsyntax_pattern_idx(n)
          end
        end
        i = find_results[2] + 1
        matched = true
        break
      end
    end

    -- consume character if we didn't match
    if not matched then
      push_token(res, "normal", text:sub(i, i))
      i = i + 1
    end
  end

  return res, state
end


local function iter(t, i)
  i = i + 2
  local type, text = t[i], t[i+1]
  if type then
    return i, type, text
  end
end

function tokenizer.each_token(t)
  return iter, t, -1
end


return tokenizer
