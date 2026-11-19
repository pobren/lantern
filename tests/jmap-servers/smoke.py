#!/usr/bin/env python3
"""Runs the JMAP calls JMAP Connect makes against a real server, signing in the way the app does.

    python3 smoke.py https://mail.example.org/.well-known/jmap you@example.org app-password

Core steps (sign in, folders, lists, reading, drafts, sending, changes, attachments, live updates) must pass, or it
exits with 1. Extras (out of office, contacts, instant alerts, send later) are reported so we know what to hide.
Only uses Python's standard library, so it runs on any GitHub runner.
"""
import base64, json, os, sys, time, urllib.error, urllib.parse, urllib.request

SESSION, USER, PASSWORD = sys.argv[1:4]
AUTH = "Basic " + base64.b64encode(f"{USER}:{PASSWORD}".encode()).decode()
CORE, MAIL, SUB = "urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail", "urn:ietf:params:jmap:submission"
LIST = ["id", "threadId", "mailboxIds", "keywords", "from", "to", "cc", "replyTo", "subject", "preview", "receivedAt",
        "hasAttachment", "messageId", "references", "blobId", "bcc", "inReplyTo"]
failed, notes = [], []


class KeepAuth(urllib.request.HTTPRedirectHandler):
    """Like the app: the sign in follows a redirect only to the same domain."""
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None:
            old_host, new_host = urllib.parse.urlparse(req.full_url).hostname, urllib.parse.urlparse(newurl).hostname
            base = ".".join(old_host.split(".")[-2:])
            if new_host == old_host or new_host.endswith("." + base):
                new.add_header("Authorization", AUTH)
        return new


opener = urllib.request.build_opener(KeepAuth, urllib.request.ProxyHandler({}))


def http(url, data=None, ctype="application/json", accept="application/json", timeout=30):
    req = urllib.request.Request(url, data=data, method="POST" if data is not None else "GET")
    req.add_header("Authorization", AUTH)
    req.add_header("Accept", accept)
    if data is not None:
        req.add_header("Content-Type", ctype)
    return opener.open(req, timeout=timeout)


def resolve(address, base):
    """Same as JMAPAuth.resolve: Stalwart gives addresses relative to the session."""
    if address.lower().startswith(("http://", "https://")):
        return address
    p = urllib.parse.urlparse(base)
    origin = f"{p.scheme}://{p.netloc}"
    return origin + address if address.startswith("/") else origin + p.path.rsplit("/", 1)[0] + "/" + address


def step(name, core=True):
    def wrap(fn):
        try:
            out = fn()
            print(f"PASS  {name}" + (f": {out}" if out else ""))
        except Exception as e:  # noqa: BLE001
            print(f"{'FAIL' if core else 'NOTE'}  {name}: {e}")
            (failed if core else notes).append(name)
        return fn
    return wrap


S = {}
try:
    res = http(SESSION)
except urllib.error.HTTPError as e:
    # Say why without showing the secret: what the server asked for and what it said.
    print(f"FAIL  sign in: HTTP {e.code}; server asks for {e.headers.get('WWW-Authenticate')!r}; "
          f"user looks like an email address: {'@' in USER}; password length {len(PASSWORD)}")
    print("      server said:", e.read(300).decode("utf-8", "replace").replace(USER, "<user>"))
    sys.exit(1)
session = json.load(res)
final = res.geturl()
ORIGIN = os.environ.get("JMAP_ORIGIN")  # a test server in Docker names itself mail.example.org; reach it here instead
for k in ("apiUrl", "downloadUrl", "uploadUrl", "eventSourceUrl"):
    if session.get(k):
        S[k] = resolve(session[k], final)
        if ORIGIN:
            p = urllib.parse.urlparse(S[k])
            S[k] = ORIGIN + S[k][len(f"{p.scheme}://{p.netloc}"):]
caps = session["capabilities"]
acc = session["primaryAccounts"][MAIL]
print(f"PASS  sign in as {session['username']} (session at {final}, account {acc})")
print(f"INFO  capabilities: {', '.join(sorted(caps))}")


def call(calls, using=(CORE, MAIL, SUB)):
    body = json.dumps({"using": list(using), "methodCalls": calls}).encode()
    out = json.load(http(S["apiUrl"], body))
    res = {}
    for name, args, cid in out["methodResponses"]:
        if name == "error":
            raise RuntimeError(f"{cid}: {args.get('type')} {args.get('description', '')}")
        res[cid] = args
    return res


box = {}


@step("folders (Mailbox/get)")
def _():
    for m in call([["Mailbox/get", {"accountId": acc}, "m"]])["m"]["list"]:
        if m.get("role"):
            box[m["role"]] = m["id"]
    for role in ("inbox", "drafts", "sent"):
        assert role in box, f"no {role} folder"
    return ", ".join(sorted(box))


ident = {}


@step("sending addresses (Identity/get)")
def _():
    ids = call([["Identity/get", {"accountId": acc}, "i"]])["i"]["list"]
    assert ids, "no identities"
    ident.update(ids[0])
    return ", ".join(i["email"] for i in ids)


state = {}


@step("list emails (Email/query + get, collapse threads)")
def _():
    q = {"accountId": acc, "filter": {"inMailbox": box["inbox"]}, "sort": [{"property": "receivedAt", "isAscending": False}],
         "limit": 100, "position": 0, "collapseThreads": True}
    r = call([["Email/query", q, "q"],
              ["Email/get", {"accountId": acc, "#ids": {"resultOf": "q", "name": "Email/query", "path": "/ids"}, "properties": LIST}, "g"]])
    state["email"] = r["g"]["state"]
    return f"{len(r['g']['list'])} in inbox"


blob = {}


@step("upload an attachment")
def _():
    url = S["uploadUrl"].replace("{accountId}", urllib.parse.quote(acc, safe=""))
    r = json.load(http(url, b"hello from JMAP Connect\n", ctype="text/plain"))
    blob["id"] = r["blobId"]
    return r["blobId"]


sent = {}


@step("send an email to myself, with attachment (Email/set + EmailSubmission/set)")
def _():
    me = ident.get("email") or (USER if "@" in USER else USER + "@example.com")  # the Cyrus test server leaves it empty
    draft = {"mailboxIds": {box["drafts"]: True}, "keywords": {"$draft": True, "$seen": True},
             "from": [{"name": ident.get("name", ""), "email": me}], "to": [{"name": "", "email": me}],
             "subject": f"JMAP Connect test {int(time.time())}", "bodyValues": {"body": {"value": "Hello\n\n"}},
             "textBody": [{"partId": "body", "type": "text/plain"}]}
    if blob:
        draft["attachments"] = [{"blobId": blob["id"], "type": "text/plain", "name": "hello.txt", "disposition": "attachment"}]
    r = call([["Email/set", {"accountId": acc, "create": {"draft": draft}}, "c"],
              ["EmailSubmission/set", {"accountId": acc, "create": {"send": {"identityId": ident["id"], "emailId": "#draft"}},
                                       "onSuccessUpdateEmail": {"#send": {f"mailboxIds/{box['drafts']}": None,
                                                                         f"mailboxIds/{box['sent']}": True, "keywords/$draft": None}}}, "s"]])
    assert not r["c"].get("notCreated"), r["c"].get("notCreated")
    assert not r["s"].get("notCreated"), r["s"].get("notCreated")
    sent["subject"] = draft["subject"]
    return "accepted"


@step("it arrives in the inbox", core=False)
def _():
    for _ in range(20):
        q = {"accountId": acc, "filter": {"inMailbox": box["inbox"], "subject": sent.get("subject", "-")}}
        ids = call([["Email/query", q, "q"]])["q"]["ids"]
        if ids:
            sent["id"] = ids[0]
            return ids[0]
        time.sleep(1)
    raise RuntimeError("not delivered within 20 seconds (some test servers hand mail to a catcher instead)")


@step("the copy in Sent")
def _():
    q = {"accountId": acc, "filter": {"inMailbox": box["sent"], "subject": sent.get("subject", "-")}}
    ids = call([["Email/query", q, "q"]])["q"]["ids"]
    assert ids, "no copy filed in Sent"
    sent.setdefault("id", ids[0])
    return ids[0]


@step("read it (bodies) and download the attachment")
def _():
    r = call([["Email/get", {"accountId": acc, "ids": [sent["id"]], "properties": ["id", "htmlBody", "textBody", "bodyValues", "attachments", "blobId"],
                             "fetchTextBodyValues": True, "fetchHTMLBodyValues": True}, "b"]])
    e = r["b"]["list"][0]
    att = e.get("attachments") or []
    assert att, "attachment missing"
    url = (S["downloadUrl"].replace("{accountId}", urllib.parse.quote(acc, safe="")).replace("{blobId}", att[0]["blobId"])
           .replace("{name}", "hello.txt").replace("{type}", urllib.parse.quote("text/plain", safe="")))
    data = http(url, accept="*/*").read()
    assert b"hello" in data, data[:60]
    return "ok"


@step("mark read, star, move to archive or bin (Email/set update)")
def _():
    target = box.get("archive") or box.get("trash")
    upd = {"keywords/$seen": True, "keywords/$flagged": True}
    r = call([["Email/set", {"accountId": acc, "update": {sent["id"]: upd}}, "u"]])
    assert not r["u"].get("notUpdated"), r["u"].get("notUpdated")
    r = call([["Email/set", {"accountId": acc, "update": {sent["id"]: {"mailboxIds": {target: True}}}}, "u"]])
    assert not r["u"].get("notUpdated"), r["u"].get("notUpdated")
    return "ok"


@step("changes since the list (Email/changes)")
def _():
    r = call([["Email/changes", {"accountId": acc, "sinceState": state["email"]}, "c"]])["c"]
    return f"{len(r['created'])} new, {len(r['updated'])} changed"


@step("search (text filter)")
def _():
    r = call([["Email/query", {"accountId": acc, "filter": {"text": "JMAP Connect"}, "limit": 10}, "q"]])
    return f"{len(r['q']['ids'])} found"


@step("live updates (EventSource)")
def _():
    if "eventSourceUrl" not in S:
        raise RuntimeError("no eventSourceUrl")
    url = S["eventSourceUrl"].replace("{types}", "Email,Mailbox").replace("{closeafter}", "state").replace("{ping}", "5")
    res = http(url, accept="text/event-stream", timeout=15)
    assert res.status == 200, res.status
    return res.headers.get("Content-Type")


@step("out of office (VacationResponse)", core=False)
def _():
    assert "urn:ietf:params:jmap:vacationresponse" in caps, "not offered"
    call([["VacationResponse/get", {"accountId": acc}, "v"]], using=(CORE, "urn:ietf:params:jmap:vacationresponse"))
    return "offered"


@step("contacts (ContactCard/get)", core=False)
def _():
    assert "urn:ietf:params:jmap:contacts" in caps, "not offered"
    call([["ContactCard/get", {"accountId": acc, "properties": ["name", "emails"]}, "c"]], using=(CORE, "urn:ietf:params:jmap:contacts"))
    return "offered"


@step("send later (FUTURERELEASE)", core=False)
def _():
    ext = session["accounts"][acc]["accountCapabilities"].get(SUB, {}).get("submissionExtensions", {})
    assert "FUTURERELEASE" in ext, "not offered"
    return "offered"


@step("instant alerts (PushSubscription/set, encrypted)", core=False)
def _():
    # A real P-256 public key and auth secret are needed for encrypted push; an obviously fake URL is fine here
    # because the server only has to accept the subscription (it'll fail to verify, which is what we expect).
    keys = {"p256dh": "BNcRdreALRFXTkOOUHK1EtK2wtaz5Ry4YfYCA_0QTpQtUbVlUls0VJXg7A8u-Ts1XbjhazAkj7I99e8QcYP7DkM",
            "auth": "tBHItJI5svbpez7KI4CCXg"}
    r = call([["PushSubscription/set", {"create": {"p": {"deviceClientId": "smoke", "url": "https://example.com/jmap-connect-smoke",
                                                          "types": ["Email"], "keys": keys}}}, "p"]], using=(CORE,))
    created = r["p"].get("created", {}).get("p")
    assert created, r["p"].get("notCreated")
    call([["PushSubscription/set", {"destroy": [created["id"]]}, "d"]], using=(CORE,))
    return "accepted"


@step("Masked Email (Fastmail only)", core=False)
def _():
    assert "https://www.fastmail.com/dev/maskedemail" in caps, "not offered, so the app hides it"


print()
print(f"{'FAILED' if failed else 'OK'}: {len(failed)} core failures {failed}; extras missing {notes}")
sys.exit(1 if failed else 0)
