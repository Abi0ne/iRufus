#!/usr/bin/env python3
"""Regenerate THIRD_PARTY_LICENSES.md from the engine's resolved (non-dev) dependency graph."""
import json, os, pathlib, subprocess
ROOT = pathlib.Path(__file__).resolve().parent.parent
env = dict(os.environ, PATH=os.path.expanduser("~/.cargo/bin") + ":" + os.environ["PATH"])
m = json.loads(subprocess.check_output(["cargo", "metadata", "--format-version", "1", "--locked",
                                        "--filter-platform", "aarch64-apple-darwin"], cwd=ROOT / "engine", env=env))
nodes = {n["id"]: n for n in m["resolve"]["nodes"]}
pk = {p["id"]: p for p in m["packages"]}
root = m["resolve"]["root"]
seen, st = set(), [root]
while st:
    i = st.pop()
    if i in seen:
        continue
    seen.add(i)
    for d in nodes[i]["deps"]:
        if any(k["kind"] is None for k in d["dep_kinds"]):
            st.append(d["pkg"])
rows = sorted((pk[i]["name"], pk[i]["version"], pk[i]["license"] or "see crate", pk[i].get("repository") or "")
              for i in seen if i != root)
out = ["# Componenti di terze parti / Third-party components", "",
       "iRufus è distribuito con licenza GPL-3.0-or-later (vedi `LICENSE`). Il motore Rust include staticamente",
       "i crate seguenti (grafo risolto per macOS, solo dipendenze di runtime); tutte le licenze sono compatibili",
       "con la GPL-3.0. Generato da `scripts/third-party.py`.", "",
       "| Crate | Versione | Licenza | Repository |", "|---|---|---|---|"]
out += ["| %s | %s | %s | %s |" % r for r in rows]
out += ["", "## Note", "",
        "- **fatfs 0.3.6** (MIT) è incluso in `engine/vendor/fatfs` con una patch documentata in `engine/vendor/README.md`.",
        "- **liblzma** (0BSD / pubblico dominio), **zstd** (BSD-3-Clause) e **libbzip2** (licenza bzip2, tipo BSD) sono compilati staticamente dai crate `*-sys`.",
        "- La logica e i contenuti del file di risposta Windows sono portati da **Rufus** (GPL-3.0-or-later, © Pete Batard / Akeo Consulting).",
        "- Strumenti usati solo nei test e non distribuiti: `wimlib-imagex` (GPL-3.0-or-later), `hdiutil` e `fsck_msdos` di macOS.",
        "- Nessun binario Microsoft, firmware, boot loader (GRUB, Syslinux, FreeDOS, UEFI:NTFS) o script remoto è incluso o scaricato."]
(ROOT / "THIRD_PARTY_LICENSES.md").write_text("\n".join(out) + "\n")
print(len(rows), "crates")
