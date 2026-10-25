#!/bin/sh
# A stand-in for curl in tests/run.sh: answers like the SnapWork gateway, never touches the network.
# Spaces come from $FAKE_DIR/spaces (lines "code|room id|space name"); every call is logged to
# $FAKE_DIR/calls as "join <code>", "lookup <code>", "hook <room>" or "away <room>".
set -u
out=
wfmt=
hdr=
url=
while [ $# -gt 0 ]; do
  case $1 in
    -o) shift; out=$1 ;;
    -w) shift; wfmt=$1 ;;
    -D) shift; hdr=$1 ;;
    -K | -H | -X | --proto | --max-time | --data-binary | --data-urlencode) shift ;;
    -*) ;;
    *) url=$1 ;;
  esac
  shift
done
cat > /dev/null
space() { grep "^$1|" "$FAKE_DIR/spaces" | head -n 1; }
code_status() { [ -z "$wfmt" ] || printf '%s' "$1"; }
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
    room=${url%/hook}
    room=${room##*/}
    echo "hook $room" >> "$FAKE_DIR/calls"
    [ -z "$out" ] || : > "$out"
    [ -z "$hdr" ] || printf 'HTTP/1.1 204 No Content\r\n\r\n' > "$hdr"
    code_status 204 ;;
  */rooms/*/away)
    room=${url%/away}
    room=${room##*/}
    echo "away $room" >> "$FAKE_DIR/calls" ;;
  *) exit 7 ;;
esac
exit 0
