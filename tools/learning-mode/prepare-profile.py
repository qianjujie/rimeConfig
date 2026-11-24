#!/usr/bin/env python3
"""Build the self-contained, single-schema SharedSupport. Never touch a live user profile."""
from pathlib import Path
import io, json, re, sys, shutil, sqlite3, subprocess, tarfile, tempfile
here = Path(__file__).resolve().parent
stock = Path("/Library/Input Methods/Squirrel.app/Contents")
dest = Path(sys.argv[1]).resolve()
dest.mkdir(parents=True, exist_ok=False)
for f in (here/"profile").iterdir():
    shutil.copy2(f, dest/f.name)
# Keep the official import graph, dictionary weights and source notices. Adapt only
# the spelling tokens, so the existing learning_zh.userdb still matches each syllable.
with tarfile.open(here/"vendor/rime-frost/dictionaries.tar.gz", "r:gz") as archive:
    for member in archive:
        if not member.isfile():
            continue
        name = member.name
        if not re.fullmatch(r"(?:rime_frost|cn_dicts(?:_cell)?/[A-Za-z_0-9-]+)\.dict\.yaml", name):
            raise SystemExit(f"Unexpected dictionary member: {name}")
        target = dest/name
        target.parent.mkdir(exist_ok=True)
        with io.TextIOWrapper(archive.extractfile(member), encoding="utf-8") as src, target.open("x", encoding="utf-8") as out:
            in_body = False
            for line in src:
                if in_body and not line.startswith("#"):
                    fields = line.rstrip("\n").split("\t")
                    # This snapshot's game list has 22 space-separated records;
                    # librime otherwise reads the pinyin and frequency as part of the word.
                    if name == "cn_dicts_cell/game.dict.yaml" and len(fields) < 3:
                        malformed = re.fullmatch(r"([^\s]+)\s+([a-z]+(?: [a-z]+)*)\s+(\d+)", line.strip())
                        if malformed:
                            fields = list(malformed.groups())
                    if len(fields) >= 2 and re.fullmatch(r"[A-Za-z]+(?: [A-Za-z]+)*", fields[1]):
                        fields[1] = " ".join(syllable + ";" for syllable in fields[1].split())
                        line = "\t".join(fields) + "\n"
                if name == "rime_frost.dict.yaml" and not in_body and line.strip() == "...":
                    out.write("  - learning_en\n")
                out.write(line)
                if line.strip() == "...":
                    in_body = True
# One English word is one spelling in the same Rime sentence graph as Chinese.
# Keep the original word and lowercase input distinct: docker stays docker.
words = {}
completion_words = {}
for filename in ("en.dict.yaml", "en_ext.dict.yaml"):
    data = (here/"vendor/rime-frost"/filename).read_text(encoding="utf-8").split("\n...\n", 1)[1]
    for line in data.splitlines():
        fields = line.split("\t")
        if len(fields) >= 2 and fields[0] == fields[1] and re.fullmatch(r"[A-Za-z][A-Za-z'-]+",fields[0]):
            completion_words.setdefault(fields[0].lower(), (filename != "en.dict.yaml",fields[0]))
        if len(fields) >= 2 and fields[0] == fields[1] and re.fullmatch(r"[A-Za-z]{4,}", fields[0]):
            for word in (fields[0], fields[0].lower()):
                words[word] = 1
# Short development terms are opt-in. Never turn everyday two-key Chinese (go, ui, ...)
# into English. Explicit case can disambiguate short names, e.g. Go or UI.
for term in (here/"mixed-terms.txt").read_text().split():
    if not re.fullmatch(r"[A-Za-z]{2,}", term):
        raise ValueError("Invalid mixed term: " + term)
    completion_words.setdefault(term.lower(),(0,term))
    words[term] = 1000
    if len(term) >= 3:
        words[term.lower()] = 1000
with (dest/"learning_en.dict.yaml").open("x", encoding="utf-8") as out:
    out.write("# Derived from rime-frost's en and en_ext (GPL-3.0); see bundled notices.\n"
              "---\nname: learning_en\nversion: '1'\nsort: by_weight\n...\n")
    for word, weight in sorted(words.items()):
        out.write(f"{word}\t_{word}\t{weight}\n")
# Pre-rank proper prefix matches at build time, not on the keyboard thread.
# Reuse the same corpus ranking as the repository's original English prefix table.
# If building the standalone learning-mode directory, still use its bundled lists.
weights = {}
frequency_source = here.parents[1]/"easy_en.dict.yaml"
if frequency_source.is_file():
    with frequency_source.open(encoding="utf-8") as source:
        for line in source:
            fields = line.rstrip("\n").split("\t")
            if len(fields)==3 and fields[0]==fields[1] and fields[0] in completion_words and fields[2].isdigit():
                weights[fields[0]] = max(weights.get(fields[0],0),int(fields[2]))
prefixes = {}
def rank(row):
    key,(extra,form)=row
    inflected = any(key.endswith(suffix) and (key[:-len(suffix)] in completion_words or key[:-len(suffix)]+"e" in completion_words) for suffix in ("s","es","d","ed","ing"))
    return (-weights.get(key,0),extra,inflected,len(key),key)
for word,(_,form) in sorted(completion_words.items(),key=rank):
    for end in range(2,len(word)):
        row=prefixes.setdefault(word[:end],[])
        if len(row)<5: row.append(form)
prefixes["llm"] = ["LLMs", "large language model"] + [w for w in prefixes.get("llm",[]) if w.lower() != "llms"]
with sqlite3.connect(dest/"EnglishCompletions.sqlite3") as db:
    db.execute("CREATE TABLE lookup (word TEXT PRIMARY KEY, choices TEXT NOT NULL) WITHOUT ROWID")
    db.executemany("INSERT INTO lookup VALUES (?,?)",((k,json.dumps([[v,""] for v in vs[:5]])) for k,vs in prefixes.items()))
with tempfile.TemporaryDirectory() as scratch:
    subprocess.run([stock/"MacOS/rime_deployer","--build",scratch,dest,dest/"build"],cwd=scratch,check=True)
shutil.copy2(dest/"squirrel.yaml",dest/"build/squirrel.yaml")
if [p.name for p in (dest/"build").glob("*.schema.yaml")] != ["learning_flypy.schema.yaml"]:
    raise SystemExit("Expected exactly one compiled schema")
for name in ("rime_frost.table.bin","learning_flypy.prism.bin"):
    if not (dest/"build"/name).is_file(): raise SystemExit("Missing "+name)
