#!/bin/sh
# A stand-in for curl in tests/run.sh: answers like the SnapWork gateway, never touches the network.
# Spaces come from $FAKE_DIR/spaces (lines "code|room id|space name"); every call is logged to
# $FAKE_DIR/calls as "join <code>", "lookup <code>", "hook <room>", "away <room>",
# "stop <room>", "start <room>" or "status <room>". A key on the command line is logged as
# "KEY-IN-ARGV". Per room, files in $FAKE_DIR change the answers:
#   gone_<room>     every call with its key answers 401 (the member was removed)
#   refused_<room>  the listening gate answers 403, state "refused"
#   pending_<room>  the member has not passed its hello: stop/start answer 403, state "pending"
#   off_<room>      the member is turned off at the gateway (stop creates it, start removes it)
#   proxy404        something in front of the gateway answers stop/start with an HTML 404
#   old             the gateway has no stop/start routes yet (404 "Route not found")
#   waiting         how many messages waited, for start (default 2)
set -u
out=
wfmt=
hdr=
url=
method=GET
fail_on_http=0
for arg in "$@"; do
  case $arg in *testkey* | *legacykey* | *setupkey*) echo "KEY-IN-ARGV" >> "$FAKE_DIR/calls" ;; esac
  case $arg in --*) ;; -*f*) fail_on_http=1 ;; esac
done
while [ $# -gt 0 ]; do
  case $1 in
    -o) shift; out=$1 ;;
    -w) shift; wfmt=$1 ;;
    -D) shift; hdr=$1 ;;
    -X) shift; method=$1 ;;
    -K | -H | --proto | --max-time | --data-binary | --data-urlencode) shift ;;
    -*) ;;
    *) url=$1 ;;
  esac
  shift
done
cat > /dev/null
space() { grep "^$1|" "$FAKE_DIR/spaces" | head -n 1; }
code_status() { [ -z "$wfmt" ] || printf '%s' "$1"; }
answer() {
  if [ -n "$out" ]; then printf '%s' "$2" > "$out"; else printf '%s' "$2"; fi
  code_status "$1"
  case $1 in 2??) exit 0 ;; esac
  # Like curl: an HTTP error is a failed run only with -f.
  [ "$fail_on_http" -eq 0 ] || exit 22
  exit 0
}
room_of() { r=${url#*/rooms/}; printf '%s' "${r%%/*}"; }
gate() {
  r=$(room_of)
  [ ! -e "$FAKE_DIR/gone_$r" ] || answer 401 '{"error":{"code":"UNAUTHORIZED","message":"Agent key required (Authorization: Bearer <agent_key>)"}}'
  [ ! -e "$FAKE_DIR/refused_$r" ] || answer 403 '{"refusal":"refused","listening":{"state":"refused","tried":[],"left":0},"error":{"code":"LISTENING_REQUIRED","message":"This agent is not listening yet; the call is refused"}}'
}
case $url in
  */j/*/join)
    code=${url%/join}
    code=${code##*/}
    line=$(space "$code")
    if [ -z "$line" ]; then code_status 404; exit 0; fi
    room=$(printf '%s' "$line" | cut -d '|' -f 2)
    name=$(printf '%s' "$line" | cut -d '|' -f 3)
    n=$(($(cat "$FAKE_DIR/count" 2> /dev/null || echo 0) + 1))
    echo "$n" > "$FAKE_DIR/count"
    agent=00000000-0000-4000-8000-$(printf '%012d' "$n")
    printf '{"agent":{"id":"%s","name":"Claude","key":"testkey%s"},"room":{"id":"%s","name":"%s","paused":false},"cursor":"c%s"}' \
      "$agent" "$n" "$room" "$name" "$n" > "$out"
    echo "join $code" >> "$FAKE_DIR/calls"
    code_status 201 ;;
  */j/*)
    code=${url##*/}
    line=$(space "$code")
    echo "lookup $code" >> "$FAKE_DIR/calls"
    [ -n "$line" ] || exit 22
    printf 'GET https://space.snapwork.ai/rooms/%s/docs with your agent key.\n' "$(printf '%s' "$line" | cut -d '|' -f 2)" ;;
  */rooms/*/hook)
    r=$(room_of)
    echo "hook $r" >> "$FAKE_DIR/calls"
    gate
    [ -z "$hdr" ] || printf 'HTTP/1.1 204 No Content\r\n\r\n' > "$hdr"
    answer 204 '' ;;
  */rooms/*/away)
    echo "away $(room_of)" >> "$FAKE_DIR/calls" ;;
  */rooms/*/listening/stop | */rooms/*/listening/start)
    r=$(room_of)
    act=${url##*/}
    echo "$act $r" >> "$FAKE_DIR/calls"
    [ ! -e "$FAKE_DIR/proxy404" ] || answer 404 '<html><body>404 Not Found</body></html>'
    [ ! -e "$FAKE_DIR/old" ] || answer 404 '{"error":{"code":"NOT_FOUND","message":"Route not found"}}'
    gate
    [ ! -e "$FAKE_DIR/pending_$r" ] || answer 403 '{"refusal":"wait","listening":{"state":"pending","tried":["hook"],"left":1},"error":{"code":"LISTENING_REQUIRED","message":"This agent is not listening yet; the call is refused"}}'
    if [ "$act" = stop ]; then
      if [ -e "$FAKE_DIR/off_$r" ]; then changed=false; else changed=true; touch "$FAKE_DIR/off_$r"; fi
      answer 200 "{\"off\":true,\"off_at\":1792000000000,\"changed\":$changed,\"next\":\"You are turned off.\"}"
    fi
    if [ -e "$FAKE_DIR/off_$r" ]; then
      rm -f "$FAKE_DIR/off_$r"
      answer 200 "{\"off\":false,\"changed\":true,\"waiting\":$(cat "$FAKE_DIR/waiting" 2> /dev/null || echo 2),\"next\":\"You are listening again.\"}"
    fi
    answer 200 '{"off":false,"changed":false,"waiting":null,"next":"You are listening again."}' ;;
  */rooms/*/listening)
    r=$(room_of)
    echo "status $r" >> "$FAKE_DIR/calls"
    gate
    state=listening
    [ ! -e "$FAKE_DIR/pending_$r" ] || state=pending
    off=null
    [ ! -e "$FAKE_DIR/off_$r" ] || off=1792000000000
    answer 200 "{\"listening\":{\"state\":\"$state\",\"tried\":[\"hook\"],\"left\":0,\"attempt\":null,\"notice\":null,\"off_at\":$off}}" ;;
  *) exit 7 ;;
esac
exit 0
