# Tab Track

Script para o REAPER que mostra tablatura rítmica (casas + ritmo) numa faixa
da timeline, sincronizada com o projeto, a partir de arquivos Guitar Pro 7/8
(`.gp`) — por exemplo, os baixados com o plano Plus do Songsterr.

## O que faz

- Abre a busca do Songsterr no navegador e detecta o `.gp` baixado em Downloads
- Cria a faixa **TAB** do instrumento escolhido: um item por compasso, com a tab desenhada
- Aplica andamento e fórmulas de compasso do arquivo e cria marcadores de seção
- Gera faixas **MIDI** de todos os instrumentos (com ReaSynth opcional)
- Troca o instrumento exibido e silencia o MIDI dele para você tocar junto

## Instalação (ReaPack)

1. Instale o [ReaPack](https://reapack.com)
2. *Extensions → ReaPack → Import repositories…* e cole o endereço do `index.xml` deste repositório
3. *Extensions → ReaPack → Browse packages*, procure **Tab Track** e instale
4. Instale também **ReaImGui** e **js_ReaScriptAPI** (repositório ReaTeam Extensions, já vem no ReaPack).
   Se faltar alguma, o script avisa e abre o ReaPack no pacote certo.

## Uso

1. Salve o projeto (as imagens da tab ficam na pasta dele, em `TabTrack/`)
2. *Actions → Tab Track*
3. Busque a música, baixe o arquivo **Guitar Pro** no Songsterr
4. Escolha o instrumento e clique em **Criar faixas**

## Desenvolvimento

```
pip install lupa
python tests/run_tests.py [arquivo.gp ...]
python tools/build_index.py USUARIO/REPOSITORIO   # atualiza o index.xml
```

Os testes rodam o script com uma API do REAPER simulada e uma música de exemplo
original (`tests/fixture.gp`, gerada por `tests/make_fixture.py`).
