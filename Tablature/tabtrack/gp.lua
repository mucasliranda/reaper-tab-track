-- Leitura de arquivos Guitar Pro 7/8 (.gp): um ZIP com Content/score.gpif (XML).

local M = {}

------------------------------------------------------------------------
-- Parser XML mínimo (suficiente para o score.gpif)
------------------------------------------------------------------------
function M.parse_xml(s)
  local root = { tag = "#root", attr = {}, children = {} }
  local stack = { root }
  local i = 1
  while true do
    local ts = s:find("<", i, true)
    if not ts then break end
    local top = stack[#stack]
    if ts > i then
      local txt = s:sub(i, ts - 1)
      if txt:find("%S") then top.text = (top.text or "") .. txt end
    end
    if s:sub(ts, ts + 8) == "<![CDATA[" then
      local e = s:find("]]>", ts + 9, true)
      top.text = (top.text or "") .. s:sub(ts + 9, e - 1)
      i = e + 3
    elseif s:sub(ts, ts + 3) == "<!--" then
      i = s:find("-->", ts + 4, true) + 3
    else
      local e = s:find(">", ts, true)
      local c = s:sub(ts + 1, ts + 1)
      if c == "?" or c == "!" then
        i = e + 1
      elseif c == "/" then
        stack[#stack] = nil
        i = e + 1
      else
        local body = s:sub(ts + 1, e - 1)
        local selfclose = body:sub(-1) == "/"
        if selfclose then body = body:sub(1, -2) end
        local node = { tag = body:match("^([%w_:%.%-]+)"), attr = {}, children = {} }
        for k, v in body:gmatch('([%w_:%-]+)%s*=%s*"([^"]*)"') do node.attr[k] = v end
        top.children[#top.children + 1] = node
        if not selfclose then stack[#stack + 1] = node end
        i = e + 1
      end
    end
  end
  return root
end

local function trim(s) return s and (s:gsub("^%s+", ""):gsub("%s+$", "")) end
M.trim = trim

local function child(node, tag)
  if not node then return nil end
  for _, c in ipairs(node.children) do
    if c.tag == tag then return c end
  end
end

local function ctext(node, tag)
  local c = child(node, tag)
  return c and trim(c.text or "")
end

local function find_desc(node, pred)
  for _, c in ipairs(node.children) do
    if pred(c) then return c end
    local r = find_desc(c, pred)
    if r then return r end
  end
end

local function prop(node, name)
  local props = child(node, "Properties")
  if not props then return nil end
  for _, p in ipairs(props.children) do
    if p.attr.name == name then return p end
  end
end

local function words(s)
  local t = {}
  for w in (s or ""):gmatch("%S+") do t[#t + 1] = w end
  return t
end

local function index_by_id(section)
  local t = {}
  for _, c in ipairs(section.children) do t[c.attr.id] = c end
  return t
end

------------------------------------------------------------------------
-- Arquivo
------------------------------------------------------------------------
local function is_windows()
  return package.config:sub(1, 1) == "\\"
end

function M.read_gpif(path)
  local cmd
  if is_windows() then
    cmd = 'tar -xOf "' .. path .. '" Content/score.gpif'
  else
    cmd = "unzip -p '" .. path:gsub("'", "'\\''") .. "' Content/score.gpif"
  end
  local p = io.popen(cmd)
  if not p then return nil end
  local data = p:read("*a")
  p:close()
  if not data or #data == 0 then return nil end
  return data
end

------------------------------------------------------------------------
-- Score
------------------------------------------------------------------------
local NOTE_VALUE = {
  Whole = 4, Half = 2, Quarter = 1, Eighth = 0.5, ["16th"] = 0.25,
  ["32nd"] = 0.125, ["64th"] = 0.0625, ["128th"] = 0.03125,
}

local VELOCITY = { PPP = 20, PP = 33, P = 49, MP = 64, MF = 80, F = 96, FF = 112, FFF = 127 }

local function rhythm_info(rh)
  local base = NOTE_VALUE[ctext(rh, "NoteValue")] or 1
  local dur = base
  local dots = 0
  local dot = child(rh, "AugmentationDot")
  if dot then
    dots = tonumber(dot.attr.count) or 1
    dur = base * (dots == 2 and 1.75 or 1.5)
  end
  local tup = child(rh, "PrimaryTuplet")
  local tuplet
  if tup then
    local num, den = tonumber(tup.attr.num), tonumber(tup.attr.den)
    dur = dur * den / num
    tuplet = num
  end
  return { base = base, dur = dur, dots = dots, tuplet = tuplet }
end

function M.load_xml(data)
  local gpif = child(M.parse_xml(data), "GPIF")
  if not gpif then return nil end
  local score = child(gpif, "Score")
  local s = {
    title = score and ctext(score, "Title") or "",
    artist = score and ctext(score, "Artist") or "",
    tracks = {}, masterbars = {}, tempos = {}, rhythms = {},
    bars = index_by_id(child(gpif, "Bars")),
    voices = index_by_id(child(gpif, "Voices")),
    beats = index_by_id(child(gpif, "Beats")),
    notes = index_by_id(child(gpif, "Notes")),
  }
  for id, rh in pairs(index_by_id(child(gpif, "Rhythms"))) do s.rhythms[id] = rhythm_info(rh) end

  for _, t in ipairs(child(gpif, "Tracks").children) do
    local tuning = find_desc(t, function(n) return n.tag == "Property" and n.attr.name == "Tuning" end)
    local pitches = tuning and words(ctext(tuning, "Pitches")) or {}
    local iset = child(t, "InstrumentSet")
    local itype = iset and ctext(iset, "Type") or ""
    s.tracks[#s.tracks + 1] = {
      name = (ctext(t, "Name") or ""):gsub("%s+", " "),
      strings = #pitches,
      drums = itype:lower():find("drum") ~= nil,
      note_count = 0,
    }
  end

  for _, m in ipairs(child(gpif, "MasterBars").children) do
    local num, den = (ctext(m, "Time") or "4/4"):match("(%d+)/(%d+)")
    local sec = child(m, "Section")
    local secname
    if sec then
      local txt, letter = ctext(sec, "Text"), ctext(sec, "Letter")
      secname = (txt and txt ~= "") and txt or letter
    end
    s.masterbars[#s.masterbars + 1] = {
      num = tonumber(num), den = tonumber(den),
      bars = words(ctext(m, "Bars")),
      section = secname,
    }
  end

  local mt = child(gpif, "MasterTrack")
  local autos = mt and child(mt, "Automations")
  if autos then
    for _, a in ipairs(autos.children) do
      if ctext(a, "Type") == "Tempo" then
        local v = words(ctext(a, "Value"))
        s.tempos[#s.tempos + 1] = {
          bar = tonumber(ctext(a, "Bar")) or 0,
          pos = tonumber(ctext(a, "Position")) or 0,
          bpm = tonumber(v[1]) or 120,
        }
      end
    end
    table.sort(s.tempos, function(a, b) return a.bar + a.pos < b.bar + b.pos end)
  end

  for ti, trk in ipairs(s.tracks) do
    for mi = 1, #s.masterbars do
      for _, b in ipairs(M.measure_beats(s, mi, ti)) do trk.note_count = trk.note_count + #b.notes end
    end
  end
  return s
end

function M.load(path)
  local data = M.read_gpif(path)
  if not data then return nil, "Não consegui abrir o arquivo. Ele precisa ser Guitar Pro 7/8 (.gp)." end
  local s = M.load_xml(data)
  if not s then return nil, "O arquivo não parece ser um Guitar Pro 7/8 válido." end
  return s
end

-- Tempos (beats) de um compasso de uma faixa, só a voz 1.
-- Cada beat: { t = posição em semínimas, r = ritmo, vel, rest, notes = { line, string, fret, midi, tied } }
function M.measure_beats(s, mb_index, track_index)
  local mb = s.masterbars[mb_index]
  local bar = s.bars[mb.bars[track_index]]
  local out = {}
  if not bar then return out end
  local vid = words(ctext(bar, "Voices"))[1]
  local voice = vid and vid ~= "-1" and s.voices[vid]
  if not voice then return out end
  local nstr = s.tracks[track_index].strings
  local t = 0
  for _, bid in ipairs(words(ctext(voice, "Beats"))) do
    local b = s.beats[bid]
    if b and not child(b, "GraceNotes") then
      local r = s.rhythms[child(b, "Rhythm").attr.ref] or { base = 1, dur = 1, dots = 0 }
      local beat = { t = t, r = r, vel = VELOCITY[ctext(b, "Dynamic") or ""] or 96, notes = {} }
      for _, nid in ipairs(words(ctext(b, "Notes"))) do
        local n = s.notes[nid]
        if n then
          local fp, sp, mp = prop(n, "Fret"), prop(n, "String"), prop(n, "Midi")
          local fret = fp and ctext(fp, "Fret")
          local str = sp and tonumber(ctext(sp, "String"))
          local tie = child(n, "Tie")
          if fret and str then
            beat.notes[#beat.notes + 1] = {
              line = nstr - 1 - str, -- 0 = linha de cima (corda mais aguda)
              string = str,
              fret = fret,
              midi = mp and tonumber(ctext(mp, "Number")),
              tied = tie and tie.attr.destination == "true",
            }
          end
        end
      end
      beat.rest = #beat.notes == 0
      out[#out + 1] = beat
      t = t + r.dur
    end
  end
  return out
end

return M
