#!/usr/bin/env python3
"""Convert the user's ChineseEnglish3 MDict to Apple Dictionary XML and a read-only IME index.
Run in a new output directory; no dictionary data is shipped with the source."""
import argparse, html as H, json, plistlib, re, sqlite3
from collections import defaultdict
from pathlib import Path, PurePosixPath
from urllib.parse import unquote
from lxml import html, etree
from mdict_utils.reader import MDX, MDD

TITLE = '汉英大词典（第三版）'
BUNDLE = 'local.rime.dictionary.HanYing3'
HAN = re.compile(r'[\u3400-\u9fff]+')
OUT = re.compile(r"[A-Za-z][A-Za-z’'\-]*(?: [A-Za-z][A-Za-z’'\-]*){0,5}")
# Display order and short disambiguators, only for English present in the entry.
PREFER = {
    '地方': [('place','地点'),('part','部分'),('locality','行政区')],
    '花': [('flower','花朵'),('spend','花费'),('pattern','花纹')],
    '接口': [('interface','接口'),('nozzle','喷嘴'),('mouthpiece','口部')],
    '部署': [('deploy','部署'),('arrange','安排'),('map out','规划')],
    '意思': [('meaning','含义'),('idea','想法'),('fun','趣味')],
    '方便': [('convenient','便利'),('handy','顺手')],
    '需求': [('requirement','要求'),('demand','需求'),('need','需要')],
    '运行': [('run','运行'),('operation','运转'),('move','移动')],
}
def plain(el):
    return ' '.join(el.text_content().split())
def paragraph_meanings(art):
    groups = []
    phrases = []
    pending = None
    related = False
    for el in art.iter('p'):
        classes = el.get('class','').split()
        s = plain(el)
        if s.startswith('◇'): related = True
        if 'example-en' in classes:
            if pending:
                en=s.rstrip(';:. ').strip()
                if OUT.fullmatch(en): phrases.append((pending,en))
            pending=None
            continue
        pending=None
        if 'example-zh' in classes:
            # Source has a visible ～ AND a hidden expansion. Keep the expansion once.
            zh=re.sub(r'[◆～\s]', '',s)
            if not related and HAN.fullmatch(zh) and len(zh)>1: pending=zh
            continue
        if 'section-heading' in classes: related=False
        if s[:1] in '①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳' and s: related=False
        if related or 'line' not in classes or not s:continue
        s=re.sub(r'^[Ⅰ-Ⅻ]+\s*[名动形副介连数代量助叹]\s*', '',s)
        s=re.sub(r'^[①-⑳]\s*','',s)
        label=''
        s=re.sub(r'^(?:\[[^\]]+\]|\{[^}]+\})\s*','',s)
        m=re.match(r'^[(（]([^()）]{1,60})[)）]\s*',s)
        if m:
            label=m[1] if len(m[1])<=8 else ''
            s=s[m.end():]
        values=[]
        for part in s.rstrip(':;. ').split(';'):
            part=re.sub(r'^\s*(?:\[[^\]]+\]|\{[^}]+\})\s*','',part.strip()).strip()
            # A verb followed by an explicit object slot is usable without its complement.
            frame=re.fullmatch(r"([A-Za-z]+) \([^()]+\) (?:to|for|with|from|in|on)",part)
            if frame:part=frame[1]
            if OUT.fullmatch(part) and not re.search(r'\b(?:sb|sth|etc)\b',part,re.I):
                values.append((part,label))
        if values:groups.append(values)
    return groups,phrases
def rank(head, groups):
    if not groups:return []
    allwords={v for row in groups for v,_ in row}
    ordered=[(v,l) for v,l in PREFER.get(head,[]) if v in allwords]
    if head in PREFER and ordered:return ordered[:3]
    # Show distinct meanings before synonyms of a single meaning.
    seen=set(); result=[]
    for v,l in [row[0] for row in groups]+[p for row in groups for p in row[1:]]:
        if v.lower() not in seen: seen.add(v.lower());result.append((v,l))
        if len(result)==3:break
    return result
def convert(mdx,out):
    out.mkdir(parents=True,exist_ok=False)
    res=out/'OtherResources';res.mkdir()
    bodies={}; aliases=defaultdict(list); groups=defaultdict(list)
    for kb,v in MDX(str(mdx)).items():
        k=kb.decode()
        if v.startswith(b'@@@LINK='):
            aliases[v[8:].decode().strip()].append(k);continue
        if k in bodies:raise ValueError('duplicate record '+k)
        bodies[k]=v
        groups[re.sub(r' \[w\d+\]$','',k)].append(k)
    missing=aliases.keys()-bodies.keys()
    if missing:raise ValueError(f'{len(missing)} unresolved redirects')
    ids={key:'e'+str(i) for i,keys in enumerate(groups.values()) for key in keys}
    for head,keys in groups.items():ids.setdefault(head,ids[keys[0]])
    for key,als in aliases.items():
        for a in als:ids.setdefault(a,ids[key])
    fields={}; examples=defaultdict(list)
    ns='http://www.apple.com/DTDs/DictionaryService-1.0.rng'
    ix=0
    with (out/'Book.xml').open('w') as fp:
        fp.write(f'<?xml version="1.0" encoding="UTF-8"?>\n<d:dictionary xmlns="http://www.w3.org/1999/xhtml" xmlns:d="{ns}">\n')
        for head,keys in groups.items():
            surfaces=list(dict.fromkeys([head]+[a for key in keys for a in aliases[key]]))
            # Both readings remain in the book; plain everyday meaning comes first here.
            if head=='地方':keys.sort(key=lambda k:b'place; space; room' not in bodies[k])
            esc=H.escape
            fp.write(f'<d:entry id="{ids[keys[0]]}" d:title="{esc(head)}">\n')
            for val in surfaces:fp.write(f'<d:index d:value="{esc(val)}" d:title="{esc(head)}"/>\n')
            ix+=len(surfaces)
            meanings=[]
            for key in keys:
                wrapper=html.fragment_fromstring(bodies[key].decode(),create_parent='div')
                art=wrapper.find('article')
                if art is None:raise ValueError(key)
                parts,phr=paragraph_meanings(art)
                meanings.extend(parts)
                for zh,en in phr:
                    if en not in examples[zh]:examples[zh].append(en)
                    if zh not in ids and zh not in surfaces:
                        fp.write(f'<d:index d:value="{esc(zh)}" d:title="{esc(zh)}"/>\n'); surfaces.append(zh); ix+=1
                # The source's hidden HTML expansion is otherwise duplicated in macOS Look Up.
                for el in art.xpath('.//span[@class="placeholder"]'):el.drop_tree()
                for el in art.xpath('.//span[@class="expanded"]'):el.set('class','headword-part')
                for a in art.iter('a'):
                    href=a.get('href','')
                    dest=unquote(href.removeprefix('entry://'))
                    if href.startswith('entry://') and dest in ids:a.set('href','x-dictionary:r:'+ids[dest]+':'+BUNDLE)
                    else:a.attrib.pop('href',None)
                for img in art.iter('img'):
                    img.set('src',img.get('src','').replace('\\','/').lstrip('/'))
                fp.write(etree.tostring(art,encoding='unicode',method='xml')+'\n')
            fp.write('</d:entry>\n')
            if HAN.fullmatch(head) and (opts:=rank(head,meanings)):fields[head]=opts
        fp.write('</d:dictionary>\n')
    for key,vals in examples.items():
        fields.setdefault(key,[(v,'') for v in vals[:3]])
    db=sqlite3.connect(res/'LearningSenses.sqlite3')
    db.execute('CREATE TABLE lookup (word TEXT PRIMARY KEY, choices TEXT NOT NULL) WITHOUT ROWID')
    db.executemany('INSERT INTO lookup VALUES (?,?)',((k,json.dumps(v,ensure_ascii=False)) for k,v in fields.items()))
    db.execute('PRAGMA user_version=1');db.commit();db.close()
    for k,v in MDD(str(mdx.with_suffix('.mdd'))).items():
        rel=PurePosixPath(k.decode().replace('\\','/').lstrip('/'))
        if '..' in rel.parts:raise ValueError(rel)
        f=res/rel;f.parent.mkdir(exist_ok=True,parents=True);f.write_bytes(v)
    css=mdx.with_suffix('.css').read_text()
    (out/'Book.css').write_text(css+'\n@media (prefers-color-scheme:dark){.ce3{color:#e7e7e7}.ce3 h1,.ce3 h2,.ce3 .roman,.ce3 a,.ce3 .example-zh{color:#89cfc9}.ce3 .reading,.ce3 .bopomofo{color:#bdbdbd}}\n')
    meta=dict(CFBundleIdentifier=BUNDLE, CFBundleName=TITLE, CFBundleDisplayName=TITLE, CFBundleShortVersionString='3.0',DCSDictionaryManufacturerName='吴光华 主编', DCSDictionaryUseSystemAppearance=True, DCSDictionaryLanguages=[dict(DCSDictionaryIndexLanguage='zh-Hans',DCSDictionaryDescriptionLanguage='en')])
    (out/'Book.plist').write_bytes(plistlib.dumps(meta))
    print(f'{len(bodies)} source articles, {len(groups)} headwords, {ix} indexes, {len(fields)} selectable words/phrases.')
    for w in ['地方','看看','收拾桌子','帮我看看这段代码','苹果','部署','花']:print(w,fields.get(w))
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('mdx',type=Path);p.add_argument('fresh_output',type=Path)
    args=p.parse_args(); convert(args.mdx,args.fresh_output)
