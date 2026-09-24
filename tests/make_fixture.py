"""Gera tests/fixture.gp: um Guitar Pro 7 mínimo com um exercício original
(pentatônica de Mi menor), duas faixas (guitarra 6 cordas e bateria),
ligadura, quiáltera, ponto de aumento, pausa e duas seções."""
import zipfile, pathlib

HERE = pathlib.Path(__file__).parent

RHYTHMS = [
    ("Quarter", None, None),   # 0
    ("Eighth", None, None),    # 1
    ("Half", None, None),      # 2
    ("Eighth", 1, None),       # 3 colcheia pontuada
    ("16th", None, None),      # 4
    ("Eighth", None, (3, 2)),  # 5 tercina
    ("Whole", None, None),     # 6
]

# (corda 0=mais grave, casa, ritmo, tie_destination)
E_STD = [40, 45, 50, 55, 59, 64]
MEASURES = [
    [[(1, 0)], [(1, 2)], [(2, 0)], [(2, 2)]],                                   # 4 semínimas
    [[(2, 0)], [(2, 2)], [(3, 0)], [(3, 2)], [(4, 0)], [(4, 3)], [(5, 0)], [(5, 3)]],  # 8 colcheias
    [[(5, 3, "tie")], [(5, 0)], [(4, 3)], [(4, 0)], None, [(3, 2)]],            # ligadura + pausa
    [[(1, 0), (2, 2), (3, 2)]],                                                 # acorde (semibreve)
]
RHY = [
    [0, 0, 0, 0],
    [1] * 8,
    [0, 5, 5, 5, 0, 0],  # semínima, tercina x3, pausa, semínima
    [6],
]


def build():
    notes, beats, voices, bars = [], [], [], []

    def add_note(string, fret, tie=False, drum=None):
        nid = len(notes)
        midi = drum if drum is not None else E_STD[string] + fret
        tie_xml = '<Tie origin="false" destination="true" />' if tie else ""
        notes.append(f'''<Note id="{nid}">{tie_xml}<Properties>
<Property name="Fret"><Fret>{fret}</Fret></Property>
<Property name="String"><String>{string}</String></Property>
<Property name="Midi"><Number>{midi}</Number></Property>
</Properties></Note>''')
        return nid

    def add_beat(rhythm, note_ids):
        bid = len(beats)
        n = f"<Notes>{' '.join(map(str, note_ids))}</Notes>" if note_ids else ""
        beats.append(f'<Beat id="{bid}"><Rhythm ref="{rhythm}" />{n}<Dynamic>F</Dynamic></Beat>')
        return bid

    def add_voice(beat_ids):
        vid = len(voices)
        voices.append(f'<Voice id="{vid}"><Beats>{" ".join(map(str, beat_ids))}</Beats></Voice>')
        return vid

    def add_bar(vid):
        bid = len(bars)
        bars.append(f'<Bar id="{bid}"><Voices>{vid} -1 -1 -1</Voices></Bar>')
        return bid

    master = []
    for mi, (m, r) in enumerate(zip(MEASURES, RHY)):
        # guitarra: a ligadura do compasso 3 continua a última nota do compasso 2
        gb = []
        for beat, rh in zip(m, r):
            if beat is None:
                gb.append(add_beat(rh, []))
            else:
                ids = [add_note(n[0], n[1], tie=len(n) > 2) for n in beat]
                gb.append(add_beat(rh, ids))
        g_bar = add_bar(add_voice(gb))
        # bateria: bumbo e caixa em semínimas
        db = [add_beat(0, [add_note(0, 0, drum=36 if k % 2 == 0 else 38)]) for k in range(4)]
        d_bar = add_bar(add_voice(db))
        section = ""
        if mi == 0:
            section = "<Section><Letter><![CDATA[A]]></Letter><Text><![CDATA[Subida]]></Text></Section>"
        if mi == 2:
            section = "<Section><Letter><![CDATA[B]]></Letter><Text><![CDATA[Descida]]></Text></Section>"
        master.append(f"<MasterBar><Time>4/4</Time><Bars>{g_bar} {d_bar}</Bars>{section}</MasterBar>")

    rhythms = []
    for i, (v, dot, tup) in enumerate(RHYTHMS):
        d = f'<AugmentationDot count="{dot}" />' if dot else ""
        t = f'<PrimaryTuplet num="{tup[0]}" den="{tup[1]}" />' if tup else ""
        rhythms.append(f'<Rhythm id="{i}"><NoteValue>{v}</NoteValue>{d}{t}</Rhythm>')

    tuning = " ".join(map(str, E_STD))
    xml = f'''<?xml version="1.0" encoding="utf-8"?>
<GPIF>
<Score><Title><![CDATA[Exercicio Pentatonica]]></Title><Artist><![CDATA[Tab Track]]></Artist></Score>
<MasterTrack><Automations>
<Automation><Type>Tempo</Type><Bar>0</Bar><Position>0</Position><Value>100 2</Value></Automation>
<Automation><Type>Tempo</Type><Bar>2</Bar><Position>0</Position><Value>120 2</Value></Automation>
</Automations></MasterTrack>
<Tracks>
<Track id="0"><Name><![CDATA[Guitarra | Solo]]></Name><InstrumentSet><Type>electricGuitar</Type></InstrumentSet>
<Sounds><Sound><Name>Distortion Guitar</Name><MIDI><LSB>0</LSB><MSB>0</MSB><Program>30</Program></MIDI></Sound></Sounds>
<Staves><Staff><Properties><Property name="Tuning"><Pitches>{tuning}</Pitches></Property></Properties></Staff></Staves></Track>
<Track id="1"><Name><![CDATA[Bateria]]></Name><InstrumentSet><Type>drumKit</Type></InstrumentSet>
<Sounds><Sound><Name>Drumkit</Name><MIDI><LSB>0</LSB><MSB>0</MSB><Program>0</Program></MIDI></Sound></Sounds>
<Staves><Staff><Properties><Property name="Tuning"><Pitches>0 0 0 0 0 0</Pitches></Property></Properties></Staff></Staves></Track>
</Tracks>
<MasterBars>{"".join(master)}</MasterBars>
<Bars>{"".join(bars)}</Bars>
<Voices>{"".join(voices)}</Voices>
<Beats>{"".join(beats)}</Beats>
<Notes>{"".join(notes)}</Notes>
<Rhythms>{"".join(rhythms)}</Rhythms>
</GPIF>'''
    out = HERE / "fixture.gp"
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("Content/score.gpif", xml)
        z.writestr("VERSION", "7.0")
    return out


if __name__ == "__main__":
    print(build())
