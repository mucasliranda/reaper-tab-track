-- Desenho de um compasso de tablatura rítmica em PNG (js_ReaScriptAPI / LICE).

local M = {}

M.PPQ     = 64   -- pixels por semínima
M.PAD     = 14   -- margem lateral
M.LINE_SP = 12   -- espaço entre linhas da tab
M.TOP     = 18   -- espaço acima da primeira linha

local COL_BG    = 0xFF1C1C1E
local COL_LINE  = 0xFF5A5A5E
local COL_BAR   = 0xFF8A8A90
local COL_TEXT  = 0xFFF2F2F2
local COL_MUTED = 0xFF8A8A90
local COL_STEM  = 0xFFB0B0B5

function M.available()
  return reaper.APIExists("JS_LICE_CreateBitmap") and reaper.APIExists("JS_LICE_WritePNG")
end

function M.measure_png(file, beats, nstr, qn, label)
  local PPQ, PAD, LINE_SP, TOP = M.PPQ, M.PAD, M.LINE_SP, M.TOP
  local W = math.floor(PAD * 2 + qn * PPQ)
  local staff_bot = TOP + (nstr - 1) * LINE_SP
  local stem_top, stem_bot = staff_bot + 8, staff_bot + 30
  local H = stem_bot + 16

  local bmp = reaper.JS_LICE_CreateBitmap(true, W, H)
  reaper.JS_LICE_Clear(bmp, COL_BG)

  local gdi = reaper.JS_GDI_CreateFont(13, 700, 0, false, false, false, "Arial")
  local font = reaper.JS_LICE_CreateFont()
  reaper.JS_LICE_SetFontFromGDI(font, gdi, "")
  local gdi_s = reaper.JS_GDI_CreateFont(11, 400, 0, false, false, false, "Arial")
  local font_s = reaper.JS_LICE_CreateFont()
  reaper.JS_LICE_SetFontFromGDI(font_s, gdi_s, "")

  local function line(x1, y1, x2, y2, col) reaper.JS_LICE_Line(bmp, x1, y1, x2, y2, col, 1, "COPY", true) end
  local function rect(x, y, w, h, col) reaper.JS_LICE_FillRect(bmp, x, y, w, h, col, 1, "COPY") end
  local function text(f, col, str, x, y, w, h)
    reaper.JS_LICE_SetFontColor(f, col)
    reaper.JS_LICE_DrawText(bmp, f, str, #str, x, y, x + w, y + h)
  end

  -- cabeçalho, linhas e barras de compasso
  text(font_s, COL_MUTED, label, 3, 1, W - 6, 14)
  for i = 0, nstr - 1 do line(0, TOP + i * LINE_SP, W, TOP + i * LINE_SP, COL_LINE) end
  line(0, TOP, 0, staff_bot, COL_BAR)
  line(W - 1, TOP, W - 1, staff_bot, COL_BAR)

  local function bx(b) return PAD + b.t * PPQ end

  -- números das casas
  for _, b in ipairs(beats) do
    local x = bx(b)
    for _, n in ipairs(b.notes) do
      local str = n.tied and ("(" .. n.fret .. ")") or n.fret
      local w = #str * 7 + 4
      local y = TOP + n.line * LINE_SP
      local x0 = math.max(1, math.min(W - w - 1, math.floor(x - w / 2)))
      rect(x0, y - 7, w, 14, COL_BG)
      text(font, COL_TEXT, str, x0 + 2, y - 7, w, 14)
    end
  end

  -- hastes, pausas e pontos de aumento
  for _, b in ipairs(beats) do
    local x = math.floor(bx(b))
    if b.rest then
      rect(x - 3, stem_top + 8, 6, 3, COL_STEM)
    elseif b.r.base >= 4 then
      -- semibreve: sem haste
    elseif b.r.base >= 2 then
      line(x, stem_bot - 10, x, stem_bot, COL_STEM)
    else
      line(x, stem_top, x, stem_bot, COL_STEM)
    end
    if b.r.dots > 0 then rect(x + 4, stem_bot - 3, 2, 2, COL_STEM) end
    if b.r.dots > 1 then rect(x + 8, stem_bot - 3, 2, 2, COL_STEM) end
  end

  -- colcheias: agrupa por tempo (semínima), sem cruzar pausas
  local i = 1
  while i <= #beats do
    local b = beats[i]
    if not b.rest and b.r.base < 1 then
      local group = { b }
      local q = math.floor(b.t + 1e-6)
      local j = i + 1
      while j <= #beats and not beats[j].rest and beats[j].r.base < 1
            and math.floor(beats[j].t + 1e-6) == q do
        group[#group + 1] = beats[j]
        j = j + 1
      end
      if #group == 1 then
        local x = math.floor(bx(b))
        line(x, stem_bot, x + 6, stem_bot - 6, COL_STEM)
        if b.r.base <= 0.25 then line(x, stem_bot - 5, x + 6, stem_bot - 11, COL_STEM) end
      else
        local x1, x2 = math.floor(bx(group[1])), math.floor(bx(group[#group]))
        rect(x1, stem_bot - 2, x2 - x1 + 1, 3, COL_STEM)
        for k = 1, #group - 1 do
          if group[k].r.base <= 0.25 and group[k + 1].r.base <= 0.25 then
            local a, c = math.floor(bx(group[k])), math.floor(bx(group[k + 1]))
            rect(a, stem_bot - 7, c - a + 1, 3, COL_STEM)
          end
        end
      end
      if b.r.tuplet then
        local x1, x2 = math.floor(bx(group[1])), math.floor(bx(group[#group]))
        text(font_s, COL_MUTED, tostring(b.r.tuplet), math.floor((x1 + x2) / 2) - 3, stem_bot + 2, 12, 12)
      end
      i = j
    else
      i = i + 1
    end
  end

  reaper.JS_LICE_WritePNG(file, bmp, false)
  reaper.JS_LICE_DestroyFont(font)
  reaper.JS_LICE_DestroyFont(font_s)
  reaper.JS_GDI_DeleteObject(gdi)
  reaper.JS_GDI_DeleteObject(gdi_s)
  reaper.JS_LICE_DestroyBitmap(bmp)
end

return M
