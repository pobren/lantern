# App Review help for JMAP Connect 1.0, kept apart from asc_listing.py so it never touches screenshots or text:
#   notes   puts apps/store/review-notes.txt in the App Review notes of the iPhone/iPad and Mac versions
#   attach  adds a file (the screen recording, path in ATTACH) as an App Review attachment on the iPhone/iPad version
#   status  just prints where each version stands
# It never submits for review. Run by .github/workflows/review.yml. Env: ASC_KEY, ASC_KEY_ID, ASC_ISSUER_ID, MODE, ATTACH.

import hashlib, os, sys, time
import jwt, requests

API = "https://api.appstoreconnect.apple.com"
HERE = os.path.dirname(os.path.abspath(__file__))
BUNDLE = "dev.paulobrien.lantern"
VERSION = "1.0"
MODE = os.environ.get("MODE", "status")


def token():
    now = int(time.time())
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
                      os.environ["ASC_KEY"], algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})


def call(method, path, body=None, ok=(200, 201, 204)):
    r = requests.request(method, API + path, json=body, headers={"Authorization": "Bearer " + token()}, timeout=60)
    if r.status_code not in ok:
        raise RuntimeError(f"{method} {path}: {r.status_code} {r.text[:800]}")
    return r.json() if r.text else {}


app = call("GET", f"/v1/apps?filter[bundleId]={BUNDLE}")["data"][0]["id"]
notes = open(os.path.join(HERE, "review-notes.txt")).read().strip()
assert len(notes) <= 4000, f"notes are {len(notes)} characters, Apple allows 4000"
failed = False

for platform in ("IOS", "MAC_OS"):
    versions = call("GET", f"/v1/apps/{app}/appStoreVersions?filter[platform]={platform}&filter[versionString]={VERSION}")["data"]
    if not versions:
        print(f"{platform}: no version {VERSION}"); continue
    v = versions[0]
    print(f"{platform} {VERSION}: {v['attributes']['appStoreState']}")
    detail = call("GET", f"/v1/appStoreVersions/{v['id']}/appStoreReviewDetail").get("data")
    if not detail:
        print("   no App Review details yet"); continue
    if MODE == "notes":
        try:
            call("PATCH", f"/v1/appStoreReviewDetails/{detail['id']}", {"data": {"type": "appStoreReviewDetails", "id": detail["id"],
                 "attributes": {"notes": notes, "demoAccountRequired": False}}})
            print(f"   notes updated ({len(notes)} characters)")
        except RuntimeError as e:
            failed = True
            print(f"   couldn't update notes: {e}")
    if MODE == "attach" and platform == "IOS":
        path = os.environ["ATTACH"]
        data = open(path, "rb").read()
        a = call("POST", "/v1/appStoreReviewAttachments", {"data": {"type": "appStoreReviewAttachments",
                 "attributes": {"fileName": os.path.basename(path), "fileSize": len(data)},
                 "relationships": {"appStoreReviewDetail": {"data": {"type": "appStoreReviewDetails", "id": detail["id"]}}}}})["data"]
        for op in a["attributes"]["uploadOperations"]:
            part = data[op["offset"]:op["offset"] + op["length"]]
            headers = {h["name"]: h["value"] for h in op.get("requestHeaders", [])}
            r = requests.request(op["method"], op["url"], data=part, headers=headers, timeout=300)
            if r.status_code >= 300:
                raise RuntimeError(f"upload part {r.status_code}")
        call("PATCH", f"/v1/appStoreReviewAttachments/{a['id']}", {"data": {"type": "appStoreReviewAttachments", "id": a["id"],
             "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
        print(f"   attached {os.path.basename(path)} ({len(data) // 1_000_000} MB)")
    for att in call("GET", f"/v1/appStoreReviewDetails/{detail['id']}/appStoreReviewAttachments").get("data", []):
        st = att["attributes"].get("assetDeliveryState") or {}
        print(f"   attachment: {att['attributes'].get('fileName')} {st.get('state', '')}")

sys.exit(1 if failed else 0)
