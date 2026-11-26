#!/usr/bin/env python3
"""Builds Shared/Localizable.xcstrings from i18n/keys.json (the English phrases) and i18n/tr/<language>.json.

Each translation file maps an English phrase to its translation. A phrase with one %lld may instead map to plural
forms, {"one": "...", "other": "..."} (plus "zero", "two", "few", "many" where the language has them).
Checks every translation keeps the same placeholders; a bad or missing one is left out, so English shows there.
Run from apps/: python3 i18n/build_catalog.py   (add --check to only report)
"""
import json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
PH = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|lf|f|s)")

def placeholders(s):
    return sorted(re.sub(r"\d+\$", "", p) for p in PH.findall(s.replace("%%", "")))

def ok(key, value):
    if isinstance(value, dict):
        return all(isinstance(v, str) and v.strip() for v in value.values()) and "other" in value and \
            all(placeholders(v) == placeholders(key) or placeholders(v) == [] and c in ("zero", "one", "two") for c, v in value.items())
    return isinstance(value, str) and value.strip() != "" and placeholders(value) == placeholders(key)

def main():
    keys = json.load(open(os.path.join(HERE, "keys.json")))
    langs = json.load(open(os.path.join(HERE, "languages.json")))
    strings, report = {}, []
    for key in keys:
        strings[key] = {"extractionState": "manual", "localizations": {}}
    for code in langs:
        path = os.path.join(HERE, "tr", code + ".json")
        if not os.path.exists(path):
            report.append(f"{code}: no file yet"); continue
        tr = json.load(open(path, encoding="utf-8"))
        good = bad = 0
        for key in keys:
            v = tr.get(key)
            if v is None: continue
            if not ok(key, v):
                bad += 1; report.append(f"{code}: bad placeholders for {key!r} -> {v!r}"); continue
            good += 1
            if isinstance(v, dict):
                unit = {"variations": {"plural": {c: {"stringUnit": {"state": "translated", "value": t}} for c, t in v.items()}}}
            else:
                unit = {"stringUnit": {"state": "translated", "value": v}}
            strings[key]["localizations"][code] = unit
        missing = len(keys) - good - bad
        report.append(f"{code}: {good} translated, {bad} bad, {missing} missing")
    if "--check" not in sys.argv:
        out = {"sourceLanguage": "en", "strings": strings, "version": "1.0"}
        dest = os.path.join(HERE, "..", "Shared", "Localizable.xcstrings")
        with open(dest, "w", encoding="utf-8") as f:
            json.dump(out, f, ensure_ascii=False, indent=2, sort_keys=True)
            f.write("\n")
    print("\n".join(r for r in report if "bad placeholders" in r or "translated" in r or "no file" in r))

main()
