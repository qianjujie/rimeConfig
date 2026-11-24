#!/usr/bin/env python3
"""Build a private look-up index from the user's installed LDOCE5 Apple dictionary."""
import argparse, json, re, sqlite3, struct, tempfile, zlib
from pathlib import Path
from lxml import html

def entries(data):
    end = 64 + struct.unpack_from('<I', data, 64)[0]
    pos = 96
    while pos < end:
        size, packed, raw = struct.unpack_from('<III', data, pos)
        if size < 8 or pos + 4 + size > end or packed != size - 4:
            raise ValueError("Unsupported LDOCE5 block")
        block = zlib.decompress(data[pos+12:pos+4+size])
        if len(block) != raw: raise ValueError("Incomplete dictionary block")
        at = 0
        while at < len(block):
            length, = struct.unpack_from('<I', block, at)
            item = block[at+4:at+4+length]
            if not item.startswith(b'<d:entry') or len(item) != length: raise ValueError("Incomplete entry")
            yield item
            at += 4 + length
        pos += 4 + size

def senses(record):
    root = html.fromstring(record.decode('utf-8'))
    key = root.get('d:title','').strip()
    if not re.fullmatch(r"[A-Za-z][A-Za-z'’ -]*", key): return key,[]
    values = []
    for sense in root.find_class('Sense'):
        # Compound expressions and example sentences are not glosses of the headword.
        if any('REFHWD' in child.get('class','').split() for child in sense): continue
        for definition in sense.find_class('DEF'):
            chinese = definition.find_class('cn_txt')
            if not chinese: continue
            text = ''.join(chinese[0].itertext()).strip()
            text = re.sub(r'〔[^〕]*〕|【[^】]*】', '', text)
            for part in re.split('[，；;/]',text):
                part = re.sub(r'\s+', '',part).strip('，。；、')
                if 0 < len(part) <= 12 and re.search('[\u3400-\u9fff]',part):
                    if part not in values: values.append(part)
                    break
            break
        if len(values)==3: break
    return key,values

def build(book,out):
    rows = {}
    for item in entries((book/'Contents/Resources/Body.data').read_bytes()):
        word,glosses=senses(item)
        if glosses: rows.setdefault(word,[]).extend(s for s in glosses if s not in rows.get(word,[]))
    if not rows: raise ValueError("No bilingual LDOCE5 entries")
    out.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(dir=out.parent) as tmp:
        staged=Path(tmp)/'lookup.sqlite3'
        with sqlite3.connect(staged) as db:
            db.execute('CREATE TABLE lookup (word TEXT PRIMARY KEY, choices TEXT NOT NULL) WITHOUT ROWID')
            db.executemany('INSERT INTO lookup VALUES (?,?)', ((k,json.dumps([[t,''] for t in v[:3]],ensure_ascii=False)) for k,v in rows.items()))
        staged.replace(out)
    print(f'{len(rows)} English headwords in {out}')
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('dictionary',type=Path);p.add_argument('output',type=Path)
    args=p.parse_args();build(args.dictionary,args.output)
