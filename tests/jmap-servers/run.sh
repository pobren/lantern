#!/usr/bin/env bash
# Starts a real Stalwart and a real Cyrus in Docker and runs smoke.py against each, signing in with an email
# address and app password the way JMAP Connect does. Used by .github/workflows/jmap-servers.yml; runs on any
# Linux machine with Docker too:  bash tests/jmap-servers/run.sh
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
STALWART_IMAGE="${STALWART_IMAGE:-stalwartlabs/stalwart:v1.1.1}"
CYRUS_IMAGE="${CYRUS_IMAGE:-ghcr.io/cyrusimap/cyrus-docker-test-server:latest}"
ok=0

jmap() {  # jmap user:password json
  curl -s --noproxy '*' -u "$1" -X POST http://localhost:18080/jmap/ -H 'Content-Type: application/json' -d "$2"
}

echo "== Stalwart ($STALWART_IMAGE)"
docker rm -f jc-stalwart >/dev/null 2>&1
docker run -d --name jc-stalwart -p 18080:8080 "$STALWART_IMAGE" >/dev/null
for _ in $(seq 60); do docker logs jc-stalwart 2>&1 | grep -q "password:" && break; sleep 1; done
boot=$(docker logs jc-stalwart 2>&1 | grep -o "password: [A-Za-z0-9]*" | head -1 | cut -d' ' -f2)
for _ in $(seq 30); do curl -s --noproxy '*' -o /dev/null http://localhost:18080/.well-known/jmap && break; sleep 1; done
# First run setup (what Stalwart's web setup does), then an app password for the admin's own mailbox.
out=$(jmap "admin:$boot" '{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:Bootstrap/set",{"update":{"singleton":{"defaultHostname":"mail.example.org","defaultDomain":"example.org","requestTlsCertificate":false,"generateDkimKeys":false}}},"a"]]}')
secret=$(echo "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["methodResponses"][0][1]["updated"]["singleton"]["secret"])')
user=$(echo "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["methodResponses"][0][1]["updated"]["singleton"]["username"])')
docker restart jc-stalwart >/dev/null
for _ in $(seq 60); do curl -s --noproxy '*' -f -o /dev/null -u "$user:$secret" http://localhost:18080/jmap/session && break; sleep 1; done
app=$(jmap "$user:$secret" '{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:AppPassword/set",{"create":{"n":{"description":"JMAP Connect"}}},"a"]]}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["methodResponses"][0][1]["created"]["n"]["secret"])')
JMAP_ORIGIN=http://localhost:18080 python3 -I "$here/smoke.py" http://localhost:18080/.well-known/jmap "$user" "$app" || ok=1
docker rm -f jc-stalwart >/dev/null

echo
echo "== Cyrus ($CYRUS_IMAGE)"
docker rm -f jc-cyrus >/dev/null 2>&1
docker run -d --name jc-cyrus -p 18081:8080 "$CYRUS_IMAGE" >/dev/null
for _ in $(seq 90); do curl -s --noproxy '*' -f -o /dev/null -u user1:x http://localhost:18081/jmap && break; sleep 1; done
# The test server takes any password for its sample users.
JMAP_ORIGIN=http://localhost:18081 python3 -I "$here/smoke.py" http://localhost:18081/.well-known/jmap user1 x || ok=1
docker rm -f jc-cyrus >/dev/null

exit $ok
