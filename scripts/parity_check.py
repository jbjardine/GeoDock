#!/usr/bin/env python3
import os
import sys
import json
from urllib.parse import urlencode
import urllib.request
import ssl
import urllib.error

BASE = os.getenv("BASE", "http://localhost")
REMOTE = os.getenv("REMOTE_BASE", "https://api-adresse.data.gouv.fr")
INSECURE_SSL = os.getenv("INSECURE_SSL", "0") == "1"
TIMEOUT = float(os.getenv("TIMEOUT", "8"))

QUERIES = [
    ("/search/", {"q": "8 bd du port, nanterre", "limit": 1}),
    ("/autocomplete", {"q": "rue de la paix", "limit": 1}),
    ("/reverse/", {"lat": 48.8566, "lon": 2.3522}),
]

def _opener_for(base: str):
    if INSECURE_SSL:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx))
    return urllib.request.build_opener()

def get_json(base: str, path: str, params: dict) -> dict:
    url = f"{base}{path}"
    if params:
        url += "?" + urlencode(params)
    req = urllib.request.Request(url, headers={"User-Agent": "geodock-parity"})
    opener = _opener_for(base)
    with opener.open(req, timeout=TIMEOUT) as resp:
        return json.loads(resp.read())

def same_shape(a, b):
    if type(a) != type(b):
        return False, f"type {type(a).__name__} vs {type(b).__name__}"
    if isinstance(a, dict):
        ka, kb = set(a.keys()), set(b.keys())
        if ka != kb:
            return False, f"keys -{sorted(ka-kb)} +{sorted(kb-ka)}"
        for k in ka:
            ok, why = same_shape(a[k], b[k])
            if not ok:
                return False, f"field {k}: {why}"
        return True, "ok"
    if isinstance(a, list):
        if not a or not b:
            return True, "ok (empty tolerated)"
        return same_shape(a[0], b[0])
    return True, "ok"

def main():
    failures = 0
    for path, params in QUERIES:
        try:
            lj = get_json(BASE, path, params)
        except Exception as e:
            print(f"[X] local {path}: {e}")
            failures += 1
            continue
        try:
            rj = get_json(REMOTE, path, params)
        except Exception as e:
            print(f"[X] remote {path}: {e}")
            failures += 1
            continue
        ok, why = same_shape(lj, rj)
        print(f"[{ 'OK' if ok else '!!' }] {path} -> {why}")
        if not ok:
            failures += 1
    sys.exit(1 if failures else 0)

if __name__ == "__main__":
    main()
