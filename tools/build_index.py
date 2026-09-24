"""Gera o index.xml do ReaPack.

    python tools/build_index.py USUARIO/REPOSITORIO

Rode de novo sempre que mudar a versão em "Tablature/Tab Track.lua" (@version).
"""
import re, sys, pathlib, datetime, urllib.parse

ROOT = pathlib.Path(__file__).resolve().parent.parent
CAT = "Tablature"
MAIN = ROOT / CAT / "Tab Track.lua"


def main(repo, branch="main"):
    header = MAIN.read_text(encoding="utf-8")
    version = re.search(r"@version\s+(\S+)", header).group(1)
    about = re.search(r"@about\n((?:--.*\n)+?)-- @provides", header).group(1)
    about = "\n".join(l[2:].strip() for l in about.splitlines())
    base = f"https://raw.githubusercontent.com/{repo}/{branch}/{CAT}/"
    url = lambda rel: base + urllib.parse.quote(rel)
    files = sorted(p.relative_to(ROOT / CAT).as_posix() for p in (ROOT / CAT / "tabtrack").glob("*.lua"))
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    sources = [f'        <source main="main">{url("Tab Track.lua")}</source>']
    sources += [f'        <source file="{f}">{url(f)}</source>' for f in files]
    xml = f'''<?xml version="1.0" encoding="utf-8"?>
<index version="1" name="Tab Track">
  <category name="{CAT}">
    <reapack name="Tab Track.lua" type="script" desc="Tab Track">
      <metadata>
        <description><![CDATA[{about}]]></description>
        <link rel="website">https://github.com/{repo}</link>
      </metadata>
      <version name="{version}" author="{repo.split('/')[0]}" time="{now}">
{chr(10).join(sources)}
      </version>
    </reapack>
  </category>
</index>
'''
    (ROOT / "index.xml").write_text(xml, encoding="utf-8")
    print(f"index.xml gerado: versão {version}, {len(sources)} arquivos")
    print(f"Endereço para o ReaPack: https://raw.githubusercontent.com/{repo}/{branch}/index.xml")


if __name__ == "__main__":
    if len(sys.argv) < 2 or "/" not in sys.argv[1]:
        sys.exit("uso: python tools/build_index.py USUARIO/REPOSITORIO")
    main(sys.argv[1])
