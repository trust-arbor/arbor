#!/usr/bin/env bash
# Report the hardware cost of local (LM Studio) models: on-disk size, whether
# they're loaded, in-memory footprint, quant, params, and context length.
#
# Pairs with the eval accuracy tables (needs-tools / complexity) so you can judge
# ACCURACY-PER-GB when picking a small model for constrained hardware.
#
# Usage:
#   ./footprint.sh                 # all downloaded models
#   ./footprint.sh granite gemma   # filter to ids matching any of these substrings
#
# Key fact (see MODELS.md): the in-memory footprint = weights (quant) + KV cache
# (context). The cache is pre-allocated at LOAD time from the model's context
# length — so loading at a small context (e.g. 2048) instead of the default
# 131072 is often the biggest VRAM saving for these short-prompt classifiers.
set -uo pipefail

command -v lms >/dev/null 2>&1 || { echo "lms CLI not found (~/.lmstudio/bin/lms)"; exit 1; }

filters="$*"
ls_json="$(lms ls --json 2>/dev/null)"
ps_json="$(lms ps --json 2>/dev/null)"

LS="$ls_json" PS="$ps_json" FILTERS="$filters" python3 - <<'PY'
import json, os

def arr(s):
    try:
        d = json.loads(s) if s.strip() else []
    except Exception:
        return []
    return d if isinstance(d, list) else d.get("data", [])

ls = arr(os.environ["LS"])
ps = arr(os.environ["PS"])
filters = os.environ["FILTERS"].split()

def gb(b):
    try: return f"{int(b)/1e9:.2f} GB"
    except Exception: return "?"

# Match loaded↔downloaded by the gguf PATH (unique per quant) — NOT the model
# name. LM Studio only puts the quant in the loaded `identifier` when 2+ quants
# of a model are loaded, so name-matching is ambiguous; the path always names the
# exact quant file.
loaded = {}  # path -> (footprint bytes, loaded context)
for m in ps:
    loaded[m.get("path")] = (
        m.get("sizeBytes"),
        m.get("contextLength") or m.get("loadedContextLength"),
    )

rows = []
for m in ls:
    key = m.get("modelKey") or m.get("identifier") or m.get("displayName") or "?"
    if filters and not any(f.lower() in key.lower() for f in filters):
        continue
    path = m.get("path")
    foot, lctx = loaded.get(path, (None, None))
    is_loaded = path in loaded
    q = m.get("quantization")
    quant = q.get("name") if isinstance(q, dict) else (q or "")
    rows.append({
        "model": key,
        "params": m.get("paramsString") or "",
        "quant": quant,  # per-path, so correct even for the bare-identifier case
        "disk": gb(m.get("sizeBytes")),
        "loaded": "yes" if is_loaded else "",
        "mem": gb(foot) if foot else "",
        "ctx": str(lctx) if lctx else str(m.get("maxContextLength") or ""),
    })

if not rows:
    print("(no models matched)"); raise SystemExit
cols = [("model",38),("params",8),("quant",10),("disk",10),("loaded",7),("mem(loaded)",12),("ctx",10)]
hdr = "  ".join(h.ljust(w) for h,w in cols)
print(hdr); print("-"*len(hdr))
for r in rows:
    vals = [r["model"], r["params"], r["quant"], r["disk"], r["loaded"], r["mem"], r["ctx"]]
    print("  ".join(str(v).ljust(w) for v,(_,w) in zip(vals, cols)))
print("\nctx = loaded context length if loaded, else the model's max. mem = in-memory")
print("footprint (weights + KV cache @ that context). Lower context → lower mem.")
PY
