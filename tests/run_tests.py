"""Testes do Tab Track fora do REAPER (Lua embutido via lupa + API simulada).

    pip install lupa
    python tests/run_tests.py                 # usa a música de exemplo (fixture)
    python tests/run_tests.py arquivo.gp      # também testa com um .gp seu
"""
import os, sys, shutil, tempfile, zipfile, pathlib
import lupa

ROOT = pathlib.Path(__file__).resolve().parent.parent
TESTS = ROOT / "tests"
MAIN = ROOT / "Tablature" / "Tab Track.lua"


class Py:
    @staticmethod
    def read_gpif(path):
        with zipfile.ZipFile(path) as z:
            return z.read("Content/score.gpif").decode("utf-8")

    @staticmethod
    def mkdir(path):
        os.makedirs(path, exist_ok=True)

    @staticmethod
    def listdir(path):
        return sorted(os.listdir(path)) if os.path.isdir(path) else []

    @staticmethod
    def copy(src, dst):
        shutil.copy(src, dst)


def new_runtime(tmp):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    g = L.globals()
    py = Py()
    g.PY = L.table_from({
        "read_gpif": py.read_gpif, "mkdir": py.mkdir,
        "listdir": lambda p: L.table_from(py.listdir(p)), "copy": py.copy,
    })
    g.PROJDIR = str(tmp / "project")
    os.makedirs(g.PROJDIR)
    os.makedirs(tmp / "home" / "Downloads")
    L.execute(f'os.getenv = function(k) if k == "HOME" then return [[{tmp / "home"}]] end end')
    L.execute('io.popen = function(cmd) local p = cmd:match("\'(.-)\' Content") '
              'return { read = function() return PY.read_gpif(p) end, close = function() end } end')
    L.execute((TESTS / "mock_reaper.lua").read_text())
    L.execute('''
FAILS = {}
function check(cond, msg) if not cond then FAILS[#FAILS + 1] = msg end end
function run_frames(script, max)
  for f = 1, max do
    FRAME = script[f] or {}
    local fn = MOCK.deferred
    MOCK.deferred = nil
    assert(fn, "janela fechou no quadro " .. f)
    fn()
  end
end
function tagged(prefix)
  local out = {}
  for _, t in ipairs(MOCK.tracks) do
    local tag = t.str["P_EXT:tabtrack"] or ""
    if tag:sub(1, #prefix) == prefix then out[tonumber(tag:sub(#prefix + 1)) or tag] = t end
  end
  return out
end
function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
function marker_names()
  local out = {}
  for _, m in pairs(MOCK.markers) do out[#out + 1] = m.name end
  table.sort(out)
  return table.concat(out, ",")
end
''')
    return L


def run_main(L):
    L.execute(f'dofile([[{MAIN}]])')


def report(name, L):
    fails = list(L.globals().FAILS.values())
    status = "OK" if not fails else f"FALHOU ({len(fails)})"
    print(f"[{status}] {name}")
    for f in fails:
        print("   -", f)
    return not fails


def test_fixture():
    tmp = pathlib.Path(tempfile.mkdtemp())
    L = new_runtime(tmp)
    fixture = TESTS / "fixture.gp"
    dl = tmp / "home" / "Downloads"
    L.globals().FIXTURE = str(fixture)
    L.globals().DLFILE = str(dl / "Tab Track-Exercicio.gp")
    run_main(L)
    L.execute('''
-- 1) busca: abre o Songsterr e passa a vigiar Downloads
run_frames({ [2] = { search = "tab track exercicio" } }, 2)
check(MOCK.urls[1] == "https://www.songsterr.com/?pattern=tab%20track%20exercicio", "URL de busca: " .. tostring(MOCK.urls[1]))

-- 2) o download aparece e é carregado sozinho
PY.copy(FIXTURE, DLFILE)
run_frames({}, 3)
local loaded = false
for _, s in ipairs(TEXTS) do if s:find("Carregado: Tab Track%-Exercicio.gp") then loaded = true end end
check(loaded, "arquivo baixado não foi detectado")

-- 3) criar faixas
run_frames({ [1] = { click = "Criar faixas" } }, 5)
check(MOCK.refresh == 0, "PreventUIRefresh desbalanceado: " .. MOCK.refresh)
check(MOCK.undo == 0, "Undo desbalanceado: " .. MOCK.undo)

local tabs, midis = tagged("tab:"), tagged("midi:")
check(count(tabs) == 1 and tabs[1], "esperada 1 faixa TAB (guitarra)")
check(count(midis) == 2, "esperadas 2 faixas MIDI, veio " .. count(midis))
check(count(tagged("folder")) == 1, "pasta MIDI")
local tab = tabs[1]
check(tab.str.P_NAME == "TAB · Guitarra | Solo", "nome da TAB: " .. tostring(tab.str.P_NAME))
check(tab.val.C_BEATATTACHMODE == 1, "timebase beats")
check(#tab.items == 4, "4 itens na TAB, veio " .. #tab.items)
check(MOCK.pngs == 4, "4 imagens, veio " .. MOCK.pngs)
check(MOCK.oob == 0, "desenho fora da imagem: " .. MOCK.oob)
for i, it in ipairs(tab.items) do
  check(it.chunk and it.chunk:find('RESOURCEFN ".-m000' .. i .. '%.png"\\nIMGRESOURCEFLAGS 0\\n>\\n$'), "imagem no item " .. i)
end

-- andamento 100 BPM (compassos 1-2) e 120 BPM (3-4)
check(#MOCK.tempo == 2 and MOCK.tempo[1].bpm == 100 and MOCK.tempo[2].bpm == 120 and MOCK.tempo[2].measure == 2,
  "mapa de tempo")
local it3 = tab.items[3]
check(math.abs(it3.val.D_POSITION - 4.8) < 1e-6 and math.abs(it3.val.D_LENGTH - 2) < 1e-6,
  string.format("posição do compasso 3: %.3f / %.3f", it3.val.D_POSITION, it3.val.D_LENGTH))
check(marker_names() == "Descida,Subida", "marcadores: " .. marker_names())

-- MIDI da guitarra: 19 notas (a ligadura estende a última do compasso 2)
local g = midis[1].items[1].take.notes
check(#g == 19, "notas da guitarra: " .. #g)
local tied
for _, n in ipairs(g) do if n.pitch == 67 and n.s == 7.5 * 960 then tied = n end end
check(tied and tied.e == 9 * 960, "ligadura mesclada (sol 67 de 7,5 a 9 QN)")
check(midis[1].fx[1] == "ReaSynth" and #midis[2].fx == 0, "ReaSynth só em instrumento melódico")
local d = midis[2].items[1].take.notes
check(#d == 16 and d[1].chan == 9, "bateria no canal 10")

-- instrumento escolhido fica mudo, o resto toca
check(midis[1].val.B_MUTE == 1 and midis[2].val.B_MUTE == 0, "mute do instrumento escolhido")
run_frames({ [1] = { toggle = "Silenciar o MIDI deste instrumento (tocar junto)" } }, 1)
check(midis[1].val.B_MUTE == 0, "desmarcar tocar junto")

-- 4) recriar não duplica nada
run_frames({ [1] = { click = "Recriar faixas" } }, 3)
check(count(tagged("tab:")) == 1 and count(tagged("midi:")) == 2 and count(tagged("folder")) == 1, "recriar duplicou faixas")
check(#MOCK.tempo == 2, "recriar duplicou tempo")
check(marker_names() == "Descida,Subida", "recriar duplicou marcadores: " .. marker_names())
check(MOCK.pngs == 4, "recriar deveria reaproveitar as imagens")
check(MOCK.ext["TabTrack/gp"]:find("/project/TabTrack/Tab Track%-Exercicio.gp$"), "cópia do .gp no projeto")
''')
    return report("música de exemplo (fixture)", L)


def test_user_file(path):
    tmp = pathlib.Path(tempfile.mkdtemp())
    L = new_runtime(tmp)
    L.globals().PICK_FILE = str(path)
    run_main(L)
    L.execute('''
run_frames({ [2] = { click = "Escolher arquivo…" } }, 2)
run_frames({ [1] = { select = "4." }, [2] = { click = "Criar faixas" } }, 80)
local tabs, midis = tagged("tab:"), tagged("midi:")
check(tabs[4] and tabs[4].val.B_SHOWINTCP == 1, "TAB do instrumento 4 visível")
check(midis[4] and midis[4].val.B_MUTE == 1, "MIDI do instrumento 4 mudo")
check(MOCK.refresh == 0 and MOCK.undo == 0, "refresh/undo balanceados")
local first = MOCK.pngs

-- troca para o instrumento 5 dentro da janela
run_frames({ [1] = { select = "5." } }, 80)
tabs = tagged("tab:")
check(tabs[5] and tabs[5].val.B_SHOWINTCP == 1, "TAB 5 visível")
check(tabs[4].val.B_SHOWINTCP == 0, "TAB 4 escondida")
check(midis[5].val.B_MUTE == 1 and midis[4].val.B_MUTE == 0, "mute segue o instrumento")
check(MOCK.pngs == first * 2, "imagens do instrumento 5")

-- voltar para o 4 é instantâneo (imagens em cache)
run_frames({ [1] = { select = "4." } }, 2)
check(tabs[4].val.B_SHOWINTCP == 1 and tabs[5].val.B_SHOWINTCP == 0, "voltar para o 4")
check(MOCK.pngs == first * 2, "voltar não deveria gerar imagens")
check(MOCK.oob == 0, "desenho fora da imagem: " .. MOCK.oob)
check(MOCK.refresh == 0 and MOCK.undo == 0, "refresh/undo balanceados no fim")
RESULT = string.format("%d compassos, %d faixas MIDI, %d imagens", #tabs[4].items, count(midis), MOCK.pngs)
''')
    ok = report(f"arquivo do usuário ({pathlib.Path(path).name})", L)
    print("   ", L.globals().RESULT)
    return ok


if __name__ == "__main__":
    import make_fixture
    make_fixture.build()
    ok = test_fixture()
    for p in sys.argv[1:]:
        ok = test_user_file(p) and ok
    sys.exit(0 if ok else 1)
