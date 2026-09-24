-- Operações no projeto do REAPER: andamento, marcadores, faixas TAB e MIDI.

local render = require("tabtrack.render")
local gp = require("tabtrack.gp")

local M = {}

local EXT_SECTION = "TabTrack"
local TRACK_TAG = "P_EXT:tabtrack"
local TAB_HEIGHT = 170

------------------------------------------------------------------------
-- Utilidades
------------------------------------------------------------------------
function M.sep() return package.config:sub(1, 1) == "\\" and "\\" or "/" end

function M.project_saved()
  return reaper.GetProjectName(0, "") ~= ""
end

function M.base_dir()
  return reaper.GetProjectPath("") .. M.sep() .. "TabTrack"
end

function M.safe_name(s)
  return (s or "tab"):gsub("[^%w%-_ ]", "_")
end

function M.copy_file(src, dst)
  if src == dst then return true end
  local fi = io.open(src, "rb")
  if not fi then return false end
  local data = fi:read("*a")
  fi:close()
  local fo = io.open(dst, "wb")
  if not fo then return false end
  fo:write(data)
  fo:close()
  return true
end

function M.get_state(key)
  local _, v = reaper.GetProjExtState(0, EXT_SECTION, key)
  return v ~= "" and v or nil
end

function M.set_state(key, value)
  reaper.SetProjExtState(0, EXT_SECTION, key, value or "")
end

local function track_tag(tr)
  local _, v = reaper.GetSetMediaTrackInfo_String(tr, TRACK_TAG, "", false)
  return v
end

local function set_tag(tr, tag)
  reaper.GetSetMediaTrackInfo_String(tr, TRACK_TAG, tag, true)
end

function M.find_track(tag)
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    if track_tag(tr) == tag then return tr end
  end
end

local function tracks_with_prefix(prefix)
  local out = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local tag = track_tag(tr)
    if tag:sub(1, #prefix) == prefix then
      out[#out + 1] = { track = tr, index = tonumber(tag:sub(#prefix + 1)) }
    end
  end
  return out
end

local function measure_time(m)
  return reaper.TimeMap2_beatsToTime(0, 0, m)
end

------------------------------------------------------------------------
-- Andamento e marcadores
------------------------------------------------------------------------
function M.apply_tempo_map(s, offset)
  for i = reaper.CountTempoTimeSigMarkers(0) - 1, 0, -1 do
    reaper.DeleteTempoTimeSigMarker(0, i)
  end
  local tempo_at = {}
  for _, tp in ipairs(s.tempos) do
    tempo_at[tp.bar] = tempo_at[tp.bar] or {}
    table.insert(tempo_at[tp.bar], tp)
  end
  local bpm = s.tempos[1] and s.tempos[1].bpm or 120
  local num, den
  for i, mb in ipairs(s.masterbars) do
    local bar = i - 1
    local ts_changed = mb.num ~= num or mb.den ~= den
    local list = tempo_at[bar] or {}
    local at_start = list[1] and list[1].pos == 0
    if at_start then bpm = list[1].bpm end
    if ts_changed or at_start then
      reaper.SetTempoTimeSigMarker(0, -1, -1, offset + bar, 0, bpm,
        ts_changed and mb.num or 0, ts_changed and mb.den or 0, false)
      num, den = mb.num, mb.den
    end
    for _, tp in ipairs(list) do
      if tp.pos > 0 then
        bpm = tp.bpm
        reaper.SetTempoTimeSigMarker(0, -1, -1, offset + bar, tp.pos * mb.num * 4 / mb.den, bpm, 0, 0, false)
      end
    end
  end
  reaper.UpdateTimeline()
end

function M.set_section_markers(s, offset)
  for id in (M.get_state("markers") or ""):gmatch("%d+") do
    reaper.DeleteProjectMarker(0, tonumber(id), false)
  end
  local ids = {}
  for i, mb in ipairs(s.masterbars) do
    if mb.section then
      ids[#ids + 1] = reaper.AddProjectMarker2(0, false, measure_time(offset + i - 1), 0, mb.section, -1, 0)
    end
  end
  M.set_state("markers", table.concat(ids, " "))
end

------------------------------------------------------------------------
-- Faixa TAB
------------------------------------------------------------------------
function M.image_dir(s, ti)
  local song = M.safe_name((s.artist ~= "" and (s.artist .. " - ") or "") .. s.title)
  return M.base_dir() .. M.sep() .. song .. M.sep() .. "t" .. ti
end

function M.image_file(s, ti, mi)
  return string.format("%s%sm%04d.png", M.image_dir(s, ti), M.sep(), mi)
end

local function measure_label(s, mi)
  local sec = s.masterbars[mi].section
  return tostring(mi) .. (sec and ("  " .. sec) or "")
end

-- Gera as imagens que faltam; chama progress(fração) e coroutine.yield() entre lotes.
function M.render_images(s, ti, progress)
  reaper.RecursiveCreateDirectory(M.image_dir(s, ti), 0)
  local n = #s.masterbars
  local trk = s.tracks[ti]
  for mi = 1, n do
    local file = M.image_file(s, ti, mi)
    if not reaper.file_exists(file) then
      local mb = s.masterbars[mi]
      render.measure_png(file, gp.measure_beats(s, mi, ti), trk.strings, mb.num * 4 / mb.den, measure_label(s, mi))
      if mi % 6 == 0 then
        if progress then progress(mi / n) end
        coroutine.yield()
      end
    end
  end
  if progress then progress(1) end
end

local function attach_image(item, file)
  local _, chunk = reaper.GetItemStateChunk(item, "", false)
  local extra = string.format('RESOURCEFN "%s"\nIMGRESOURCEFLAGS 0\n>', file)
  chunk = chunk:gsub(">%s*$", function() return extra .. "\n" end)
  reaper.SetItemStateChunk(item, chunk, false)
end

local function clear_items(tr)
  for i = reaper.CountTrackMediaItems(tr) - 1, 0, -1 do
    reaper.DeleteTrackMediaItem(tr, reaper.GetTrackMediaItem(tr, i))
  end
end

function M.build_tab_track(s, ti, offset)
  local tag = "tab:" .. ti
  local tr = M.find_track(tag)
  if not tr then
    reaper.InsertTrackAtIndex(0, true)
    tr = reaper.GetTrack(0, 0)
    set_tag(tr, tag)
  end
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "TAB · " .. s.tracks[ti].name, true)
  reaper.SetMediaTrackInfo_Value(tr, "C_BEATATTACHMODE", 1)
  reaper.SetMediaTrackInfo_Value(tr, "I_HEIGHTOVERRIDE", TAB_HEIGHT)
  reaper.SetMediaTrackInfo_Value(tr, "B_SHOWINMIXER", 0)
  clear_items(tr)
  for mi = 1, #s.masterbars do
    local m = offset + mi - 1
    local t0, t1 = measure_time(m), measure_time(m + 1)
    local item = reaper.AddMediaItemToTrack(tr)
    reaper.SetMediaItemInfo_Value(item, "D_POSITION", t0)
    reaper.SetMediaItemInfo_Value(item, "D_LENGTH", t1 - t0)
    attach_image(item, M.image_file(s, ti, mi))
  end
  return tr
end

------------------------------------------------------------------------
-- Faixas MIDI
------------------------------------------------------------------------
local function delete_tagged(prefix)
  for _, t in ipairs(tracks_with_prefix(prefix)) do reaper.DeleteTrack(t.track) end
end

function M.build_midi_tracks(s, offset, add_synth)
  delete_tagged("midi:")
  local folder = M.find_track("folder")
  if folder then reaper.DeleteTrack(folder) end

  local base = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(base, true)
  folder = reaper.GetTrack(0, base)
  set_tag(folder, "folder")
  local title = s.title ~= "" and s.title or "Música"
  reaper.GetSetMediaTrackInfo_String(folder, "P_NAME", "MIDI · " .. title, true)
  reaper.SetMediaTrackInfo_Value(folder, "I_FOLDERDEPTH", 1)

  local t_start = measure_time(offset)
  local t_end = measure_time(offset + #s.masterbars)
  local last

  for ti, trk in ipairs(s.tracks) do
    if trk.note_count > 0 then
      local idx = reaper.CountTracks(0)
      reaper.InsertTrackAtIndex(idx, true)
      local tr = reaper.GetTrack(0, idx)
      set_tag(tr, "midi:" .. ti)
      reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", string.format("%d · %s", ti, trk.name), true)
      reaper.SetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH", 0)
      if add_synth and not trk.drums then reaper.TrackFX_AddByName(tr, "ReaSynth", false, -1) end

      local item = reaper.CreateNewMIDIItemInProj(tr, t_start, t_end, false)
      local take = reaper.GetActiveTake(item)
      local chan = trk.drums and 9 or 0
      local open = {} -- nota soando por corda (para ligaduras)

      local function flush(key)
        local n = open[key]
        if n then
          reaper.MIDI_InsertNote(take, false, false,
            reaper.MIDI_GetPPQPosFromProjQN(take, n.qs), reaper.MIDI_GetPPQPosFromProjQN(take, n.qe),
            chan, n.pitch, n.vel, true)
          open[key] = nil
        end
      end

      for mi = 1, #s.masterbars do
        local qn0 = reaper.TimeMap2_timeToQN(0, measure_time(offset + mi - 1))
        for _, b in ipairs(gp.measure_beats(s, mi, ti)) do
          local qs, qe = qn0 + b.t, qn0 + b.t + b.r.dur
          for _, n in ipairs(b.notes) do
            if n.midi then
              local key = trk.drums and ("d" .. n.midi) or n.string
              local o = open[key]
              if n.tied and o and o.pitch == n.midi then
                o.qe = qe
              else
                flush(key)
                open[key] = { qs = qs, qe = qe, pitch = n.midi, vel = b.vel }
              end
            end
          end
        end
      end
      for key in pairs(open) do flush(key) end
      reaper.MIDI_Sort(take)
      last = tr
    end
  end

  if last then
    reaper.SetMediaTrackInfo_Value(last, "I_FOLDERDEPTH", -1)
  else
    reaper.SetMediaTrackInfo_Value(folder, "I_FOLDERDEPTH", 0)
  end
end

------------------------------------------------------------------------
-- Troca de instrumento
------------------------------------------------------------------------
function M.show_instrument(ti, mute_selected)
  for _, t in ipairs(tracks_with_prefix("tab:")) do
    reaper.SetMediaTrackInfo_Value(t.track, "B_SHOWINTCP", t.index == ti and 1 or 0)
  end
  for _, t in ipairs(tracks_with_prefix("midi:")) do
    reaper.SetMediaTrackInfo_Value(t.track, "B_MUTE", (mute_selected and t.index == ti) and 1 or 0)
  end
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
end

function M.has_midi_tracks()
  return #tracks_with_prefix("midi:") > 0
end

return M
