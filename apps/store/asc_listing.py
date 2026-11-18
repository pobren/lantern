# Fills in the App Store listing for JMAP Connect from listing.json and the screenshots in apps/screenshots/store,
# for both the iPhone and iPad version and the Mac version, and attaches the chosen build to each.
# It never presses Submit: App Privacy answers and the review phone number are done by Paul in App Store Connect.
# Run by .github/workflows/appstore.yml. Env: ASC_KEY (the .p8 text), ASC_KEY_ID, ASC_ISSUER_ID, BUILD (number).

import hashlib, json, os, sys, time
import jwt, requests

API = "https://api.appstoreconnect.apple.com"
HERE = os.path.dirname(os.path.abspath(__file__))
SHOTS = os.path.join(HERE, "..", "screenshots", "store")
L = json.load(open(os.path.join(HERE, "listing.json")))
BUNDLE = "dev.paulobrien.lantern"
BUILD = os.environ.get("BUILD", "").strip()
problems = []


def token():
    now = int(time.time())
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
                      os.environ["ASC_KEY"], algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})


def call(method, path, body=None, ok=(200, 201, 204), quiet=False):
    r = requests.request(method, API + path, json=body, headers={"Authorization": "Bearer " + token()}, timeout=60)
    if r.status_code not in ok:
        detail = r.text[:800]
        if not quiet:
            print(f"!! {method} {path} -> {r.status_code} {detail}")
        raise RuntimeError(f"{method} {path}: {r.status_code} {r.text}")
    return r.json() if r.text else {}


def step(name, fn):
    try:
        fn()
        print(f"OK  {name}")
    except Exception as e:
        problems.append(f"{name}: {str(e)[:600]}")
        print(f"FAIL {name}: {str(e)[:600]}")


app = call("GET", f"/v1/apps?filter[bundleId]={BUNDLE}&fields[apps]=name,primaryLocale")["data"][0]
APP, LOCALE = app["id"], app["attributes"]["primaryLocale"]
print("App", APP, "primary language", LOCALE)


# App level: name, subtitle, privacy policy, categories.
def app_info():
    infos = call("GET", f"/v1/apps/{APP}/appInfos")["data"]
    info = next((i for i in infos if i["attributes"].get("appStoreState") in ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", None)), infos[0])
    call("PATCH", f"/v1/appInfos/{info['id']}", {"data": {"type": "appInfos", "id": info["id"], "relationships": {
        "primaryCategory": {"data": {"type": "appCategories", "id": L["primaryCategory"]}},
        "secondaryCategory": {"data": {"type": "appCategories", "id": L["secondaryCategory"]}}}}})
    for loc in call("GET", f"/v1/appInfos/{info['id']}/appInfoLocalizations")["data"]:
        call("PATCH", f"/v1/appInfoLocalizations/{loc['id']}", {"data": {"type": "appInfoLocalizations", "id": loc["id"], "attributes": {
            "name": L["name"], "subtitle": L["subtitle"], "privacyPolicyUrl": L["privacyPolicyUrl"]}}})
    # Age rating: an email app with no content of its own (4+).
    try:
        age = call("GET", f"/v1/appInfos/{info['id']}/ageRatingDeclaration")["data"]
        # Email is messaging between people; nothing else in the questionnaire applies.
        attrs = {}
        for k, v in age["attributes"].items():
            if k == "kidsAgeBand" or any(w in k.lower() for w in ("override", "url", "grac", "korea")):
                continue
            attrs[k] = False if isinstance(v, bool) else "NONE"
        if "messagingAndChat" in attrs:
            attrs["messagingAndChat"] = True
        for _ in range(6):  # Apple says which fields want true/false and which want a level; adjust and retry.
            try:
                call("PATCH", f"/v1/ageRatingDeclarations/{age['id']}", {"data": {"type": "ageRatingDeclarations", "id": age["id"], "attributes": attrs}}, quiet=True)
                break
            except RuntimeError as e:
                text, changed = str(e), False
                try:
                    errors = json.loads(text[text.index("{"):]).get("errors", [])
                except ValueError:
                    errors = []
                for err in errors:
                    key = err.get("source", {}).get("pointer", "").split("/")[-1]
                    if key in attrs:
                        if "BOOLEAN" in err.get("detail", "") and not isinstance(attrs[key], bool):
                            attrs[key], changed = (key == "messagingAndChat"), True
                        elif "STRING" in err.get("detail", "") and isinstance(attrs[key], bool):
                            attrs[key], changed = "NONE", True
                        elif "not a valid" in err.get("detail", "") or "not allowed" in err.get("detail", "").lower():
                            attrs.pop(key); changed = True
                if not changed:
                    raise
    except Exception as e:
        problems.append(f"age rating: {str(e)[:600]}")


step("Name, subtitle, privacy policy, categories and age rating", app_info)


# Free, in every country.
def price():
    points = call("GET", f"/v1/apps/{APP}/appPricePoints?filter[territory]=GBR&limit=200")["data"]
    free = next(p for p in points if float(p["attributes"]["customerPrice"]) == 0)
    call("POST", "/v1/appPriceSchedules", {"data": {"type": "appPriceSchedules", "relationships": {
        "app": {"data": {"type": "apps", "id": APP}},
        "baseTerritory": {"data": {"type": "territories", "id": "GBR"}},
        "manualPrices": {"data": [{"type": "appPrices", "id": "${price}"}]}}},
        "included": [{"type": "appPrices", "id": "${price}", "attributes": {"startDate": None},
                      "relationships": {"appPricePoint": {"data": {"type": "appPricePoints", "id": free["id"]}}}}]})


step("Price: free", price)


def availability():
    try:
        call("GET", f"/v1/apps/{APP}/appAvailabilityV2", quiet=True)
        return  # already set
    except Exception:
        pass
    territories = []
    url = "/v1/territories?limit=200"
    while url:
        page = call("GET", url)
        territories += [t["id"] for t in page["data"]]
        nxt = page.get("links", {}).get("next")
        url = nxt.replace(API, "") if nxt else None
    included = [{"type": "territoryAvailabilities", "id": f"${{t{i}}}", "attributes": {"available": True},
                 "relationships": {"territory": {"data": {"type": "territories", "id": t}}}} for i, t in enumerate(territories)]
    call("POST", "/v2/appAvailabilities", {"data": {"type": "appAvailabilities", "attributes": {"availableInNewTerritories": True},
        "relationships": {"app": {"data": {"type": "apps", "id": APP}},
                          "territoryAvailabilities": {"data": [{"type": "territoryAvailabilities", "id": x["id"]} for x in included]}}},
        "included": included})


step("Available in every country", availability)


def version_for(platform):
    versions = call("GET", f"/v1/apps/{APP}/appStoreVersions?filter[platform]={platform}&limit=20")["data"]
    editable = [v for v in versions if v["attributes"]["appStoreState"] in ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED")]
    if editable:
        v = editable[0]
        call("PATCH", f"/v1/appStoreVersions/{v['id']}", {"data": {"type": "appStoreVersions", "id": v["id"], "attributes": {
            "versionString": L["version"], "copyright": L["copyright"], "releaseType": "MANUAL"}}})
        return v["id"]
    v = call("POST", "/v1/appStoreVersions", {"data": {"type": "appStoreVersions", "attributes": {
        "platform": platform, "versionString": L["version"], "copyright": L["copyright"], "releaseType": "MANUAL"},
        "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})["data"]
    return v["id"]


def upload_shot(set_id, path):
    data = open(path, "rb").read()
    shot = call("POST", "/v1/appScreenshots", {"data": {"type": "appScreenshots", "attributes": {
        "fileName": os.path.basename(path), "fileSize": len(data)},
        "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}}}})["data"]
    for op in shot["attributes"]["uploadOperations"]:
        part = data[op["offset"]:op["offset"] + op["length"]]
        headers = {h["name"]: h["value"] for h in op.get("requestHeaders", [])}
        r = requests.request(op["method"], op["url"], data=part, headers=headers, timeout=120)
        if r.status_code >= 300:
            raise RuntimeError(f"upload part {r.status_code}")
    call("PATCH", f"/v1/appScreenshots/{shot['id']}", {"data": {"type": "appScreenshots", "id": shot["id"], "attributes": {
        "uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})


def fill(platform):
    vid = version_for(platform)
    print(f"   {platform} version {L['version']}: {vid}")
    locs = call("GET", f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations")["data"]
    loc = next((l for l in locs if l["attributes"]["locale"] == LOCALE), locs[0] if locs else None)
    attrs = {"description": L["description"], "keywords": L["keywords"], "promotionalText": L["promotionalText"],
             "marketingUrl": L["marketingUrl"], "supportUrl": L["supportUrl"]}
    if loc:
        call("PATCH", f"/v1/appStoreVersionLocalizations/{loc['id']}", {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"], "attributes": attrs}})
    else:
        loc = call("POST", "/v1/appStoreVersionLocalizations", {"data": {"type": "appStoreVersionLocalizations",
            "attributes": dict(attrs, locale=LOCALE), "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}})["data"]

    # Screenshots: replace each set with the current files.
    sets = {s["attributes"]["screenshotDisplayType"]: s["id"] for s in call("GET", f"/v1/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets")["data"]}
    for display, prefix in L["screenshots"][platform].items():
        files = sorted(f for f in os.listdir(SHOTS) if f.startswith(prefix) and f.endswith(".png"))
        if display in sets:
            for old in call("GET", f"/v1/appScreenshotSets/{sets[display]}/appScreenshots")["data"]:
                call("DELETE", f"/v1/appScreenshots/{old['id']}")
            set_id = sets[display]
        else:
            set_id = call("POST", "/v1/appScreenshotSets", {"data": {"type": "appScreenshotSets", "attributes": {"screenshotDisplayType": display},
                "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"]}}}}})["data"]["id"]
        for f in files:
            upload_shot(set_id, os.path.join(SHOTS, f))
        print(f"   {display}: {len(files)} screenshots")

    # Review notes: no sign in needed (sample mail). Paul adds his phone number in App Store Connect.
    r = L["review"]
    review_attrs = {k: r[k] for k in ("contactFirstName", "contactLastName", "contactEmail", "demoAccountRequired", "notes")}
    try:
        detail = call("GET", f"/v1/appStoreVersions/{vid}/appStoreReviewDetail", quiet=True).get("data")
    except RuntimeError:
        detail = None
    if not detail:
        # Apple won't create review details without a phone number, which only Paul adds. Once he has,
        # running this again fills in the notes.
        print("   Review notes skipped until a contact phone number is added in App Store Connect")
    else:
        call("PATCH", f"/v1/appStoreReviewDetails/{detail['id']}", {"data": {"type": "appStoreReviewDetails", "id": detail["id"], "attributes": review_attrs}})

    # The build.
    if BUILD:
        builds = call("GET", f"/v1/builds?filter[app]={APP}&filter[version]={BUILD}&filter[preReleaseVersion.platform]={platform}&fields[builds]=version,processingState")["data"]
        if not builds:
            raise RuntimeError(f"build {BUILD} for {platform} isn't in App Store Connect yet")
        b = builds[0]
        if b["attributes"]["processingState"] != "VALID":
            raise RuntimeError(f"build {BUILD} for {platform} is still {b['attributes']['processingState']}")
        call("PATCH", f"/v1/appStoreVersions/{vid}/relationships/build", {"data": {"type": "builds", "id": b["id"]}})
        print(f"   build {BUILD} attached")


step("iPhone and iPad version", lambda: fill("IOS"))
step("Mac version", lambda: fill("MAC_OS"))

print()
if problems:
    print("Still to sort out:")
    for p in problems:
        print(" -", p)
    sys.exit(1)
print("Listing is in App Store Connect. Left for Paul: App Privacy (Data Not Collected), review phone number, then Add for Review and Submit.")
