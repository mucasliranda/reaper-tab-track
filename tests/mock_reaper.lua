-- API do REAPER simulada, só o necessário para os testes do Tab Track.
-- PY (injetado pelo run_tests.py) fornece acesso ao sistema de arquivos.

MOCK = {
  tracks = {}, tempo = {}, markers = {}, next_marker = 1, ext = {},
  refresh = 0, undo = 0, urls = {}, messages = {}, oob = 0, pngs = 0,
  time = 0, deferred = nil,
}

reaper = {}

local function bpm_at(m)
  local bpm = 120
  for _, t in ipairs(MOCK.tempo) do
    if t.measure <= m then bpm = t.bpm end
  end
  return bpm
end

local function measure_time(m)
  local t = 0
  for k = 0, m - 1 do t = t + 4 * 60 / bpm_at(k) end
  return t
end

function reaper.TimeMap2_beatsToTime(_, beats, m)
  return measure_time(m or 0) + beats * 60 / bpm_at(m or 0)
end

function reaper.TimeMap2_timeToQN(_, t)
  local qn, k = 0, 0
  while true do
    local d = 4 * 60 / bpm_at(k)
    if t < d - 1e-9 then return qn + t * bpm_at(k) / 60 end
    t, qn, k = t - d, qn + 4, k + 1
  end
end

function reaper.APIExists(name) return reaper[name] ~= nil end
function reaper.GetOS() return "macOS-arm64" end
function reaper.ShowMessageBox(msg) MOCK.messages[#MOCK.messages + 1] = msg return 1 end
function reaper.defer(fn) MOCK.deferred = fn end
function reaper.time_precise() MOCK.time = MOCK.time + 1.1 return MOCK.time end
function reaper.EnumProjects() return "proj1", PROJDIR .. "/test.rpp" end
function reaper.GetProjectName() return "test.rpp" end
function reaper.GetProjectPath() return PROJDIR end
function reaper.GetProjExtState(_, sec, key) local v = MOCK.ext[sec .. "/" .. key] return v and 1 or 0, v or "" end
function reaper.SetProjExtState(_, sec, key, v) MOCK.ext[sec .. "/" .. key] = v end
function reaper.file_exists(p) local f = io.open(p, "rb") if f then f:close() return true end return false end
function reaper.RecursiveCreateDirectory(p) PY.mkdir(p) return 1 end
function reaper.EnumerateFiles(dir, i)
  if i < 0 then return nil end
  local list = PY.listdir(dir)
  return list[i + 1]
end
function reaper.GetUserFileNameForRead() return true, PICK_FILE end
function reaper.CF_ShellExecute(url) MOCK.urls[#MOCK.urls + 1] = url end
function reaper.Undo_BeginBlock() MOCK.undo = MOCK.undo + 1 end
function reaper.Undo_EndBlock() MOCK.undo = MOCK.undo - 1 end
function reaper.PreventUIRefresh(n) MOCK.refresh = MOCK.refresh + n end
function reaper.UpdateArrange() end
function reaper.UpdateTimeline() end
function reaper.TrackList_AdjustWindows() end

-- tempo
function reaper.CountTempoTimeSigMarkers() return #MOCK.tempo end
function reaper.DeleteTempoTimeSigMarker(_, i) table.remove(MOCK.tempo, i + 1) return true end
function reaper.SetTempoTimeSigMarker(_, idx, tpos, measure, beat, bpm, num, den)
  assert(idx == -1 and tpos == -1, "esperado inserir marcador novo por compasso")
  MOCK.tempo[#MOCK.tempo + 1] = { measure = measure, beat = beat, bpm = bpm, num = num, den = den }
  table.sort(MOCK.tempo, function(a, b) return a.measure + a.beat / 100 < b.measure + b.beat / 100 end)
  return true
end

-- marcadores
function reaper.AddProjectMarker2(_, isrgn, pos, _, name)
  local id = MOCK.next_marker
  MOCK.next_marker = id + 1
  MOCK.markers[id] = { pos = pos, name = name }
  return id
end
function reaper.DeleteProjectMarker(_, id) local ok = MOCK.markers[id] ~= nil MOCK.markers[id] = nil return ok end

-- faixas
function reaper.CountTracks() return #MOCK.tracks end
function reaper.GetTrack(_, i) return MOCK.tracks[i + 1] end
function reaper.InsertTrackAtIndex(i) table.insert(MOCK.tracks, i + 1, { str = {}, val = { B_SHOWINTCP = 1 }, items = {}, fx = {} }) end
function reaper.DeleteTrack(tr)
  for i, t in ipairs(MOCK.tracks) do if t == tr then table.remove(MOCK.tracks, i) return end end
end
function reaper.GetSetMediaTrackInfo_String(tr, key, v, set)
  if set then tr.str[key] = v end
  return true, tr.str[key] or ""
end
function reaper.SetMediaTrackInfo_Value(tr, key, v) tr.val[key] = v return true end
function reaper.GetMediaTrackInfo_Value(tr, key) return tr.val[key] or 0 end
function reaper.TrackFX_AddByName(tr, name) tr.fx[#tr.fx + 1] = name return #tr.fx - 1 end

-- itens
function reaper.CountTrackMediaItems(tr) return #tr.items end
function reaper.GetTrackMediaItem(tr, i) return tr.items[i + 1] end
function reaper.DeleteTrackMediaItem(tr, it)
  for i, x in ipairs(tr.items) do if x == it then table.remove(tr.items, i) return true end end
  return false
end
function reaper.AddMediaItemToTrack(tr) local it = { val = {} } tr.items[#tr.items + 1] = it return it end
function reaper.SetMediaItemInfo_Value(it, key, v) it.val[key] = v return true end
function reaper.GetItemStateChunk(it) return true, it.chunk or "<ITEM\nPOSITION 0\n>\n" end
function reaper.SetItemStateChunk(it, c) it.chunk = c return true end

-- MIDI
function reaper.CreateNewMIDIItemInProj(tr, t0, t1)
  local it = reaper.AddMediaItemToTrack(tr)
  it.take = { notes = {}, start_qn = reaper.TimeMap2_timeToQN(0, t0) }
  it.val.D_POSITION, it.val.D_LENGTH = t0, t1 - t0
  return it
end
function reaper.GetActiveTake(it) return it.take end
function reaper.MIDI_GetPPQPosFromProjQN(take, qn) return (qn - take.start_qn) * 960 end
function reaper.MIDI_InsertNote(take, sel, mute, s, e, chan, pitch, vel)
  take.notes[#take.notes + 1] = { s = s, e = e, chan = chan, pitch = pitch, vel = vel }
  return true
end
function reaper.MIDI_Sort(take) take.sorted = true end

-- js_ReaScriptAPI (LICE): confere se tudo é desenhado dentro da imagem
local function inside(b, x, y) if x < 0 or y < 0 or x > b.w or y > b.h then MOCK.oob = MOCK.oob + 1 end end
function reaper.JS_LICE_CreateBitmap(_, w, h) return { w = w, h = h } end
function reaper.JS_LICE_Clear() end
function reaper.JS_GDI_CreateFont() return {} end
function reaper.JS_LICE_CreateFont() return {} end
function reaper.JS_LICE_SetFontFromGDI() end
function reaper.JS_LICE_SetFontColor() end
function reaper.JS_LICE_DrawText(b, _, s, n, x1, y1, x2, y2) inside(b, x1, y1) inside(b, x2, y2) end
function reaper.JS_LICE_Line(b, x1, y1, x2, y2) inside(b, x1, y1) inside(b, x2, y2) end
function reaper.JS_LICE_FillRect(b, x, y, w, h) inside(b, x, y) inside(b, x + w, y + h) end
function reaper.JS_LICE_WritePNG(file)
  local f = assert(io.open(file, "wb")) f:write("png") f:close()
  MOCK.pngs = MOCK.pngs + 1
  return true
end
function reaper.JS_LICE_DestroyFont() end
function reaper.JS_GDI_DeleteObject() end
function reaper.JS_LICE_DestroyBitmap() end

-- ReaImGui: cada quadro executa as ações de FRAME (clicar, escolher, marcar)
FRAME = {}
TEXTS = {}
function reaper.ImGui_GetBuiltinPath() return "MOCK" end
local ImGui = setmetatable({
  Cond_FirstUseEver = 1,
  InputTextFlags_EnterReturnsTrue = 32,
  Begin = function() return true, true end,
  Button = function(_, label) return FRAME.click == label end,
  BeginCombo = function() return FRAME.select ~= nil end,
  Selectable = function(_, label) return FRAME.select ~= nil and label:find(FRAME.select, 1, true) == 1 end,
  Checkbox = function(_, label, v) if FRAME.toggle == label then return true, not v end return false, v end,
  InputInt = function(_, _, v) return false, v end,
  InputTextWithHint = function(_, _, _, v) if FRAME.search then return true, FRAME.search end return false, v end,
  TextColored = function(_, _, s) TEXTS[#TEXTS + 1] = s end,
}, { __index = function() return function() end end })
package.preload["imgui"] = function() return function() return ImGui end end
