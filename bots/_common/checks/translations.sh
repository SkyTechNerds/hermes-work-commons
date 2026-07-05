#!/bin/bash
t() { if [ "${CODEMOLE_LANG:-de}" = "en" ]; then printf %s "$2"; else printf %s "$1"; fi; }
# Check-Modul: translations — en.json-Pflicht + Key-SET-Konsistenz (nicht nur Anzahl). cwd=REPO_DIR.
emit() { python3 -c "import json,sys;print(json.dumps({'name':'translations','status':sys.argv[1],'message':sys.argv[2]}))" "$1" "$2"; }
TDIR=$(find custom_components -maxdepth 2 -type d -name translations 2>/dev/null | head -1)
[ -z "$TDIR" ] && { emit skip "$(t "Kein translations/-Verzeichnis" "No translations/ directory")"; exit 0; }
EN="$TDIR/en.json"
[ -f "$EN" ] || { emit warn "$(t "en.json fehlt - keine Pflicht-Sprache" "en.json missing - it is the required language")"; exit 0; }
RESULT="$(TDIR="$TDIR" python3 <<'PY'
import json, os, glob
tdir = os.environ["TDIR"]
def keypaths(f):
    try:
        with open(f, encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        return None
    out = set()
    def walk(d, prefix):
        if isinstance(d, dict):
            for k, v in d.items():
                walk(v, prefix + (k,))
        else:
            out.add(".".join(prefix))
    walk(data, ())
    return out
en = keypaths(os.path.join(tdir, "en.json"))
if en is None:
    print("BROKEN en.json nicht parsebar"); raise SystemExit
langs = sorted(glob.glob(os.path.join(tdir, "*.json")))
problems = []
for lf in langs:
    name = os.path.basename(lf)[:-5]
    if name == "en":
        continue
    ks = keypaths(lf)
    if ks is None:
        problems.append(f"{name}(JSON kaputt)")
        continue
    missing = len(en - ks); extra = len(ks - en)
    if missing or extra:
        problems.append(f"{name}({missing} fehlen/{extra} extra)")
if problems:
    print("MISMATCH " + ", ".join(problems))
else:
    print(f"OK {len(langs)} Sprachen, Key-Sets identisch ({len(en)} Keys)")
PY
)"
case "$RESULT" in
  OK*)       emit pass "${RESULT#OK }" ;;
  MISMATCH*) emit warn "Translations-Key-Mismatch: ${RESULT#MISMATCH }" ;;
  BROKEN*)   emit fail "${RESULT#BROKEN }" ;;
  *)         emit warn "$(t "translations-Check nicht auswertbar" "translations check could not be evaluated")" ;;
esac
