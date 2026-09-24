-- @description Tab Track: tablatura rítmica de arquivos Guitar Pro na timeline
-- @version 0.3.0
-- @changelog
--   Importa o áudio baixado do Songsterr (WAV ou MP3) numa faixa alinhada à TAB,
--   com ajuste fino em milissegundos e opção de silenciar o MIDI.
-- @author Tab Track
-- @about
--   Busca a música no Songsterr, detecta o arquivo Guitar Pro (.gp) baixado
--   e cria no projeto uma faixa TAB rítmica sincronizada, faixas MIDI de cada
--   instrumento e marcadores de seção. Permite trocar o instrumento exibido
--   e silenciar o MIDI dele para tocar junto.
--
--   Requer ReaImGui e js_ReaScriptAPI (repositório ReaTeam Extensions).
-- @provides
--   [nomain] tabtrack/*.lua

------------------------------------------------------------------------
-- Dependências
------------------------------------------------------------------------
local function missing_deps()
  local missing = {}
  if not reaper.APIExists("ImGui_GetBuiltinPath") then missing[#missing + 1] = "ReaImGui" end
  if not reaper.APIExists("JS_LICE_CreateBitmap") then missing[#missing + 1] = "js_ReaScriptAPI" end
  return missing
end

local missing = missing_deps()
if #missing > 0 then
  local list = table.concat(missing, " e ")
  local msg = "O Tab Track precisa de " .. list .. ".\n\n"
  if reaper.APIExists("ReaPack_BrowsePackages") then
    reaper.ShowMessageBox(msg .. "Vou abrir o ReaPack filtrado no pacote. Instale, reinicie o REAPER e rode o Tab Track de novo.", "Tab Track", 0)
    reaper.ReaPack_BrowsePackages(missing[1])
  else
    reaper.ShowMessageBox(msg .. "Instale o ReaPack (reapack.com) e depois esses pacotes pelo menu Extensions > ReaPack.", "Tab Track", 0)
  end
  return
end

local script_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])")
package.path = script_dir .. "?.lua;" .. package.path
package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path

local ImGui = require("imgui")("0.9")
local gp = require("tabtrack.gp")
local project = require("tabtrack.project")

------------------------------------------------------------------------
-- Estado
------------------------------------------------------------------------
local ctx = ImGui.CreateContext("Tab Track")

local st = {
  search = "",
  gp_path = nil,        -- arquivo carregado
  audio_path = nil,     -- WAV/MP3 do Songsterr (opcional)
  opt_audio = true,
  opt_audio_only = true, -- silenciar o MIDI quando houver áudio
  nudge = 0,            -- ajuste do áudio em ms
  score = nil,
  load_error = nil,
  selected = nil,       -- instrumento (índice)
  offset = 1,           -- compasso inicial no projeto
  opt_tempo = true,
  opt_markers = true,
  opt_midi = true,
  sound = "reasynth",
  opt_mute = true,
  watching = false,
  snapshot = {},
  last_scan = 0,
  job = nil,
  job_label = "",
  progress = 0,
  status = nil,
  status_ok = true,
  project_key = nil,
}

local COL_OK    = 0x6BD68BFF
local COL_WARN  = 0xE8B04BFF
local COL_ERR   = 0xF07070FF
local COL_MUTED = 0x9A9AA0FF

------------------------------------------------------------------------
-- Downloads
------------------------------------------------------------------------
local function downloads_dir()
  local home = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
  return home .. project.sep() .. "Downloads"
end

local function file_kind(f)
  local ext = f:lower():match("%.(%w+)$")
  if ext == "gp" then return "gp" end
  if ext == "wav" or ext == "mp3" then return "audio" end
end

local function list_download_files()
  local dir = downloads_dir()
  local files = {}
  reaper.EnumerateFiles(dir, -1) -- limpa o cache da pasta
  local i = 0
  while true do
    local f = reaper.EnumerateFiles(dir, i)
    if not f then break end
    if file_kind(f) then files[f] = true end
    i = i + 1
  end
  return files
end

local function start_watching()
  st.snapshot = list_download_files()
  st.watching = true
end

local function url_encode(s)
  return (s:gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function open_url(url)
  if reaper.APIExists("CF_ShellExecute") then
    reaper.CF_ShellExecute(url)
  elseif reaper.GetOS():find("Win") then
    os.execute('start "" "' .. url .. '"')
  else
    os.execute("open '" .. url:gsub("'", "") .. "'")
  end
end

------------------------------------------------------------------------
-- Carregar arquivo
------------------------------------------------------------------------
local function first_playable(s)
  for i, t in ipairs(s.tracks) do
    if not t.drums and t.strings > 0 and t.note_count > 0 then return i end
  end
end

local function load_gp(path)
  local s, err = gp.load(path)
  if not s then
    st.load_error = err
    return false
  end
  st.score, st.gp_path, st.load_error = s, path, nil
  st.selected = tonumber(project.get_state("selected") or "") or first_playable(s)
  st.status = nil
  return true
end

-- Vigia Downloads: carrega o .gp e o WAV/MP3 que aparecerem depois do início.
-- Continua aguardando até ter os dois (ou o usuário parar).
local function check_downloads()
  if not st.watching then return end
  local now = reaper.time_precise()
  if now - st.last_scan < 1 then return end
  st.last_scan = now
  for f in pairs(list_download_files()) do
    if not st.snapshot[f] then
      st.snapshot[f] = true
      local path = downloads_dir() .. project.sep() .. f
      if file_kind(f) == "gp" then load_gp(path) else st.audio_path = path end
    end
  end
  if st.score and st.audio_path then st.watching = false end
end

-- Ao abrir (ou trocar de) projeto, recarrega a música salva nele.
local function sync_with_project()
  local key = tostring((reaper.EnumProjects(-1)))
  if key == st.project_key then return end
  st.project_key = key
  st.score, st.gp_path, st.selected, st.audio_path = nil, nil, nil, nil
  st.offset = tonumber(project.get_state("offset") or "") or 1
  st.nudge = tonumber(project.get_state("nudge") or "") or 0
  local saved = project.get_state("gp")
  if saved and reaper.file_exists(saved) then load_gp(saved) end
  local audio = project.get_state("audio")
  if audio and reaper.file_exists(audio) then st.audio_path = audio end
end

------------------------------------------------------------------------
-- Tarefas (rodam em partes para não travar a janela)
------------------------------------------------------------------------
local editing = false

local function begin_edit()
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  editing = true
end

local function end_edit(desc)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock(desc, -1)
  editing = false
end

local function run_job(label, fn)
  st.job_label, st.progress, st.status = label, 0, nil
  st.job = coroutine.create(fn)
end

local function step_job()
  if not st.job then return end
  local ok, err = coroutine.resume(st.job)
  if not ok then
    st.status, st.status_ok = "Erro: " .. tostring(err), false
    st.job = nil
    if editing then end_edit("Tab Track (erro)") end
  elseif coroutine.status(st.job) == "dead" then
    st.job = nil
  end
end

local function build_all()
  local s, ti, offset = st.score, st.selected, st.offset - 1
  run_job("Gerando a tablatura…", function()
    project.render_images(s, ti, function(p) st.progress = p end)

    begin_edit()

    reaper.RecursiveCreateDirectory(project.base_dir(), 0)
    local name = st.gp_path:match("([^/\\]+)$")
    local stored = project.base_dir() .. project.sep() .. name
    if project.copy_file(st.gp_path, stored) then st.gp_path = stored end
    project.set_state("gp", st.gp_path)
    project.set_state("offset", tostring(st.offset))
    project.set_state("selected", tostring(ti))

    if st.opt_tempo then project.apply_tempo_map(s, offset) end
    if st.opt_markers then project.set_section_markers(s, offset) end
    if st.opt_midi then project.build_midi_tracks(s, offset, st.sound) end
    project.build_tab_track(s, ti, offset)
    project.show_instrument(ti, st.opt_mute)

    if st.audio_path and st.opt_audio then
      local aname = st.audio_path:match("([^/\\]+)$")
      local astored = project.base_dir() .. project.sep() .. aname
      if project.copy_file(st.audio_path, astored) then st.audio_path = astored end
      project.set_state("audio", st.audio_path)
      project.set_state("nudge", tostring(st.nudge))
      project.import_audio(st.audio_path, offset, st.nudge)
    end
    project.set_midi_muted(st.opt_audio_only and project.has_audio_track())

    end_edit("Tab Track: criar faixas")
    st.status, st.status_ok = "Faixas criadas.", true
  end)
end

local function switch_instrument(ti)
  st.selected = ti
  local s, offset = st.score, st.offset - 1
  run_job("Trocando instrumento…", function()
    project.render_images(s, ti, function(p) st.progress = p end)
    begin_edit()
    if not project.find_track("tab:" .. ti) then project.build_tab_track(s, ti, offset) end
    project.show_instrument(ti, st.opt_mute)
    project.set_state("selected", tostring(ti))
    end_edit("Tab Track: trocar instrumento")
    st.status, st.status_ok = "Mostrando: " .. s.tracks[ti].name, true
  end)
end

------------------------------------------------------------------------
-- Interface
------------------------------------------------------------------------
local function instrument_label(i, t)
  local kind = t.drums and "bateria" or (t.strings .. " cordas")
  return string.format("%d. %s (%s)", i, t.name, kind)
end

local function section_search()
  ImGui.SeparatorText(ctx, "1 · Buscar música")
  ImGui.SetNextItemWidth(ctx, -150)
  local enter
  enter, st.search = ImGui.InputTextWithHint(ctx, "##search", "Artista ou música", st.search,
    ImGui.InputTextFlags_EnterReturnsTrue)
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Abrir no Songsterr", -1) or enter then
    local q = gp.trim(st.search)
    local url = q ~= "" and ("https://www.songsterr.com/?pattern=" .. url_encode(q)) or "https://www.songsterr.com/"
    start_watching()
    open_url(url)
  end
end

local function section_file()
  ImGui.SeparatorText(ctx, "2 · Baixe o arquivo Guitar Pro no site")
  if st.watching then
    ImGui.TextColored(ctx, COL_MUTED, "Aguardando um novo .gp em Downloads…")
  elseif st.score then
    local name = st.gp_path:match("([^/\\]+)$")
    ImGui.TextColored(ctx, COL_OK, "Carregado: " .. name)
  else
    ImGui.TextColored(ctx, COL_MUTED, "Nenhum arquivo carregado.")
  end
  if st.load_error then ImGui.TextColored(ctx, COL_ERR, st.load_error) end

  if ImGui.Button(ctx, st.watching and "Parar de aguardar" or "Aguardar download") then
    if st.watching then st.watching = false else start_watching() end
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Escolher arquivo…") then
    local ok, path = reaper.GetUserFileNameForRead(downloads_dir() .. project.sep(), "Abrir arquivo Guitar Pro", "gp")
    if ok then load_gp(path) end
  end

  ImGui.Spacing(ctx)
  if st.audio_path then
    ImGui.TextColored(ctx, COL_OK, "Áudio: " .. st.audio_path:match("([^/\\]+)$"))
  else
    ImGui.TextColored(ctx, COL_MUTED, "Áudio (opcional): baixe o WAV ou MP3 no site")
  end
  if ImGui.Button(ctx, "Escolher áudio…") then
    local ok, path = reaper.GetUserFileNameForRead(downloads_dir() .. project.sep(), "Abrir áudio do Songsterr", "wav;*.mp3")
    if ok and file_kind(path) == "audio" then st.audio_path = path end
  end
end

local function section_audio()
  if not st.audio_path then return end
  ImGui.SeparatorText(ctx, "Áudio do Songsterr")
  local rv
  rv, st.opt_audio = ImGui.Checkbox(ctx, "Importar o áudio numa faixa", st.opt_audio)
  rv, st.opt_audio_only = ImGui.Checkbox(ctx, "Tocar só o áudio (silenciar o MIDI)", st.opt_audio_only)
  if rv then project.set_midi_muted(st.opt_audio_only and project.has_audio_track()) end
  ImGui.SetNextItemWidth(ctx, 100)
  rv, st.nudge = ImGui.InputInt(ctx, "Ajuste do áudio (ms)", st.nudge, 10, 100)
  ImGui.SameLine(ctx)
  ImGui.BeginDisabled(ctx, not project.has_audio_track())
  if ImGui.Button(ctx, "Aplicar ajuste") then
    project.reposition_audio(st.offset - 1, st.nudge)
    project.set_state("nudge", tostring(st.nudge))
  end
  ImGui.EndDisabled(ctx)
  ImGui.TextColored(ctx, COL_MUTED, "Negativo adianta o áudio. Use se ele não bater com a TAB.")
end

local function section_instrument()
  ImGui.SeparatorText(ctx, "3 · Instrumento")
  local s = st.score
  local preview = st.selected and instrument_label(st.selected, s.tracks[st.selected]) or "Escolha…"
  ImGui.SetNextItemWidth(ctx, -1)
  if ImGui.BeginCombo(ctx, "##inst", preview) then
    for i, t in ipairs(s.tracks) do
      local disabled = t.drums or t.strings == 0 or t.note_count == 0
      ImGui.BeginDisabled(ctx, disabled)
      if ImGui.Selectable(ctx, instrument_label(i, t), st.selected == i) and i ~= st.selected then
        if project.get_state("gp") == st.gp_path and project.find_track("tab:" .. (st.selected or 0)) then
          switch_instrument(i)
        else
          st.selected = i
        end
      end
      ImGui.EndDisabled(ctx)
    end
    ImGui.EndCombo(ctx)
  end
  local rv
  rv, st.opt_mute = ImGui.Checkbox(ctx, "Silenciar o MIDI deste instrumento (tocar junto)", st.opt_mute)
  if rv and st.selected and project.has_midi_tracks() then project.show_instrument(st.selected, st.opt_mute) end
end

local function section_options()
  ImGui.SeparatorText(ctx, "4 · Opções")
  local rv
  ImGui.SetNextItemWidth(ctx, 100)
  rv, st.offset = ImGui.InputInt(ctx, "Compasso inicial no projeto", st.offset)
  if st.offset < 1 then st.offset = 1 end
  rv, st.opt_tempo = ImGui.Checkbox(ctx, "Aplicar andamento e compassos (substitui os do projeto)", st.opt_tempo)
  rv, st.opt_markers = ImGui.Checkbox(ctx, "Marcadores de seção", st.opt_markers)
  rv, st.opt_midi = ImGui.Checkbox(ctx, "Criar faixas MIDI de todos os instrumentos", st.opt_midi)
  ImGui.BeginDisabled(ctx, not st.opt_midi)
  ImGui.Indent(ctx)
  ImGui.Text(ctx, "Som dos instrumentos:")
  if ImGui.RadioButton(ctx, "ReaSynth (básico)", st.sound == "reasynth") then st.sound = "reasynth" end
  if ImGui.RadioButton(ctx, "Nenhum (vou colocar meus plugins)", st.sound == "none") then st.sound = "none" end
  ImGui.Unindent(ctx)
  ImGui.EndDisabled(ctx)
end

local function section_build()
  ImGui.Spacing(ctx)
  if not project.project_saved() then
    ImGui.TextColored(ctx, COL_WARN, "Salve o projeto antes: as imagens ficam na pasta dele.")
  end
  local built = project.get_state("gp") ~= nil
  ImGui.BeginDisabled(ctx, st.job ~= nil or not st.selected or not project.project_saved())
  if ImGui.Button(ctx, built and "Recriar faixas" or "Criar faixas", -1, 30) then build_all() end
  ImGui.EndDisabled(ctx)

  if st.job then
    ImGui.ProgressBar(ctx, st.progress, -1, 0, st.job_label)
  elseif st.status then
    ImGui.TextColored(ctx, st.status_ok and COL_OK or COL_ERR, st.status)
  end
end

local function loop()
  sync_with_project()
  check_downloads()
  step_job()

  ImGui.SetNextWindowSize(ctx, 460, 560, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, "Tab Track", true)
  if visible then
    section_search()
    section_file()
    if st.score then
      section_instrument()
      section_audio()
      section_options()
      section_build()
    end
    ImGui.End(ctx)
  end
  if open then reaper.defer(loop) end
end

reaper.defer(loop)
