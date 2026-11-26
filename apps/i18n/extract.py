#!/usr/bin/env python3
"""Finds the phrases JMAP Connect shows, for Localizable.xcstrings.

Collects every string literal in the Swift sources that reads like words people see, turns \\(...) values into the
placeholders SwiftUI and String(localized:) use (%lld for whole numbers, %@ for the rest), and writes
i18n/keys.json. Sample mail, the Private AI prompts and technical strings (SQL, addresses, headers) are left out.
Run from apps/: python3 i18n/extract.py
"""
import json, os, re, sys

SKIP_FILES = {"DemoServer.swift", "Cache.swift", "PushCrypto.swift", "CalDAV.swift", "ICal.swift"}
SKIP_DIRS = {"i18n", "screenshots", "store"}
# Literal text that is never shown: prompts, sample mail, wire formats.
SKIP_TEXT = re.compile(r"^(SELECT|INSERT|DELETE|UPDATE|CREATE|PRAGMA|DROP)\b|https?://|urn:|^Bearer|^Basic|Content-|^[a-z]+:[a-z]|"
                       r"UK English|^You (summarise|give|draft)|^Here are my|^Draft a reply to this|^Summarise this email|"
                       r"^From: |^Date: |^Subject: |^To: |^Re: |^Fwd: |^JCDEBUG|^\$\(|@jmapconnect|^EEE|^yyyy|^HH:|DTSTART|DTEND|SUMMARY:|UID:|default-src|^Write in |^<|^JMAP Connect: ")
SAMPLE = re.compile(r"Maya|Tom Okafor|Kestrel|Hillside|Sam Patel|The Times|Sketches for|Saturday|monthly summary|Lunch on|"
                    r"three directions|climb|statement for November|books left us|order is on its way|November statement")
INT_HINT = re.compile(r"(\.count\b|^count$|^n$|unread|total|number|perMonth|^Int\(|days|hours|minutes|seconds|^limit$|"
                      r"^code$|^c$|blocked|trackers|outbox|picked|selected|emails\.count|left|remaining|^i$|^index$|size)")
STRING_EXPR = re.compile(r"(name|label|title|email|address|who|why|what|display|description|folder|subject|username|"
                         r"formatted|string\(from|lastPathComponent|waiting|long\(|sender|account|\?\?)", re.I)

def literals(code):
    """Yields each top level string literal's body, stepping over strings nested inside \\(...)."""
    i, n = 0, len(code)
    while i < n:
        if code.startswith('"""', i): return   # multi-line literals are code (HTML, CSS), not phrases
        if code[i] != '"': i += 1; continue
        j, depth = i + 1, 0
        while j < n:
            c = code[j]
            if depth == 0 and c == "\\" and j + 1 < n and code[j + 1] != "(": j += 2; continue
            if c == "\\" and j + 1 < n and code[j + 1] == "(": depth += 1; j += 2; continue
            if depth > 0:
                if c == "(": depth += 1
                elif c == ")": depth -= 1
                elif c == '"':   # a string inside the interpolation: skip to its end
                    k = j + 1
                    while k < n and code[k] != '"':
                        k += 2 if code[k] == "\\" else 1
                    j = k
                j += 1; continue
            if c == '"': break
            j += 1
        yield code[i + 1:j]
        i = j + 1

def interp(body):
    """Splits a literal body into text and \\(...) parts (balanced brackets)."""
    out, i = [], 0
    while i < len(body):
        if body.startswith("\\(", i):
            depth, j = 1, i + 2
            while j < len(body) and depth:
                if body[j] == "(": depth += 1
                elif body[j] == ")": depth -= 1
                elif body[j] == '"':   # a nested string inside the interpolation
                    k = body.find('"', j + 1)
                    j = k if k > 0 else j
                j += 1
            out.append(("x", body[i + 2:j - 1])); i = j
        else:
            k = body.find("\\(", i)
            k = len(body) if k < 0 else k
            out.append(("t", body[i:k])); i = k
    return out

def unescape(t):
    return t.replace('\\"', '"').replace("\\n", "\n").replace("\\t", "\t").replace("\\\\", "\\")

def spec(expr, overrides, text):
    e = expr.strip()
    for pat, s in overrides:
        if re.search(pat, text) and (pat_expr := s[0]) and re.fullmatch(pat_expr, e): return s[1]
    if STRING_EXPR.search(e): return "%@"
    if INT_HINT.search(e): return "%lld"
    return "%@"

# Where the guess above is wrong: (phrase pattern, (expression, placeholder)).
OVERRIDES = [
    (r"^Move again to ", (r"\$0", "%@")),
    (r"^(Archived|Deleted|Moved) ", (r"\$0", "%lld")),
    (r"you read", (r"n\.read", "%lld")),
]

def phrase(body):
    parts = interp(body)
    has_x = any(k == "x" for k, _ in parts)
    text = "".join(v if k == "t" else "￼" for k, v in parts)
    if not re.search(r"[A-Za-z]{2,}", text): return None
    out = ""
    for k, v in parts:
        out += unescape(v).replace("%", "%%") if k == "t" and has_x else (unescape(v) if k == "t" else spec(v, OVERRIDES, text))
    return out

keys = {}
for root, dirs, files in os.walk("."):
    dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
    for f in files:
        if not f.endswith(".swift") or f in SKIP_FILES: continue
        p = os.path.join(root, f)
        for n, line in enumerate(open(p, encoding="utf-8"), 1):
            s = line.strip()
            if s.startswith("//") or "NSLog" in s or "print(" in s or "forKey:" in s or "Logger" in s: continue
            code = s.split(" // ")[0]
            for body in literals(code):
                raw = unescape(body)
                if SKIP_TEXT.search(raw) or SAMPLE.search(raw): continue
                # Words people read: a capital start or a space, and not an identifier or a symbol name.
                if not (re.match(r"[A-Z(“\"]", raw) or " " in raw.strip()): continue
                if re.fullmatch(r"[A-Za-z0-9_.\-]+", raw) and not re.match(r"[A-Z][a-z]+$", raw): continue
                if re.fullmatch(r"[a-z]+(\.[a-z.]+)+", raw): continue   # SF Symbol names
                k = phrase(body)
                if k and k.strip():
                    keys.setdefault(k, f"{p[2:]}:{n}")
json.dump(dict(sorted(keys.items())), open("i18n/keys.json", "w"), ensure_ascii=False, indent=1)
print(len(keys), "phrases;", sum(len(k.split()) for k in keys), "words")
