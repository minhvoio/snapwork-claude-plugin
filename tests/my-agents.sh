#!/bin/sh
# Local tests for My agents (SnapWork M7): the connect link in a chat (snapwork-connect.sh through
# snapwork-plugin.sh) and the watcher (snapwork-watch.sh), with a temporary HOME, a fake curl
# (tests/fake-curl.sh) and a fake claude, so nothing reaches the gateway or starts a session.
#
#   sh tests/my-agents.sh           (also run at the end of tests/run.sh)
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPTS=$ROOT/plugins/snapwork/scripts
PLUGIN=$SCRIPTS/snapwork-plugin.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home/proj" "$T/home/proj2" "$T/home/proj3" "$T/fake" "$T/tx"
cp "$ROOT/tests/fake-curl.sh" "$T/bin/curl"
# A claude that records how it was called and answers like Claude Code 2.1.312's --bg.
cat > "$T/bin/claude" << 'EOF'
#!/bin/sh
if [ "${1:-}" = agents ]; then
  printf '[{"sessionId":"e2858c3e-d4ee-49ef-b4a0-57ce8ff97fa8","kind":"background"},{"sessionId": "fee53b8c-6a51-45d3-8d48-980b9689f68a","kind":"background"}]\n'
  exit 0
fi
{ printf 'cwd=%s path=%s' "$(pwd -P)" "$PATH"; for a in "$@"; do printf ' |%s' "$a"; done; printf '\n'; } >> "$FAKE_DIR/claude_calls"
if [ -e "$FAKE_DIR/claude_untrusted" ]; then
  echo "Workspace not trusted. Run \`claude\` in $(pwd) once and accept the trust prompt, then retry." >&2
  exit 1
fi
printf 'Starting background service\342\200\246\nbackgrounded \302\267 fee53b8c \302\267 %s\n' "$6"
EOF
chmod 755 "$T/bin/curl" "$T/bin/claude"
HOMEDIR=$(cd "$T/home" && pwd -P)
P1=$HOMEDIR/proj
P2=$HOMEDIR/proj2
SW=$HOMEDIR/.snapwork
CONNECT=https://space.snapwork.ai/c/
INVITE=https://space.snapwork.ai/j/
ROOM_A=aaaaaaaa-0000-4000-8000-000000000001
printf 'kfr-aaaa-0001|%s|Space A\n' "$ROOM_A" > "$T/fake/spaces"
for n in 2 3 4 5 6; do printf 'kfr-aaaa-000%s|aaaaaaaa-0000-4000-8000-00000000000%s|Space %s\n' "$n" "$n" "$n" >> "$T/fake/spaces"; done
: > "$T/fake/calls"
S1=11111111-aaaa-4000-8000-000000000001
S2=22222222-aaaa-4000-8000-000000000002
S3=33333333-aaaa-4000-8000-000000000003
ADD1=adadadad-0000-4000-8000-000000000001
FORK_ID=fee53b8c-6a51-45d3-8d48-980b9689f68a
TAB=$(printf '\t')

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; [ -z "${2:-}" ] || printf '  output: %s\n' "$2"; }
has() { if grep -q -F -e "$2" "$T/out"; then ok; else bad "$1 (wanted: $2)" "$(cat "$T/out")"; fi; }
called() { if grep -q -F -e "$2" "$T/fake/calls"; then ok; else bad "$1 (no call: $2)" "$(cat "$T/fake/calls")"; fi; }
not_called() { if grep -q -F -e "$2" "$T/fake/calls"; then bad "$1 (unwanted call: $2)"; else ok; fi; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
reset() { : > "$T/fake/calls"; rm -f "$T/fake/claim_status" "$T/fake/claim_bodies" "$T/fake/connect_status" "$T/fake/key_refused" "$T/fake/claude_calls" "$T/fake/claude_untrusted" "$T/fake/work_status" "$T/fake/lookup_status" "$T/fake/lookup_runtime"; }

transcript() { f=$T/tx/$1.jsonl; printf '{"type":"user","sessionId":"%s"}\n' "$1" > "$f"; printf '%s' "$f"; }
prompt() { printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","hook_event_name":"UserPromptSubmit","prompt":"%s"}' "$1" "$2" "$3" "$4"; }
run() {
  # An empty and a relative entry on the chat's PATH: neither may reach the saved home.
  printf '%s' "$2" | env HOME="$HOMEDIR" SNAPWORK_HOME="$SW" PATH="$T/bin:.::$PATH" FAKE_DIR="$T/fake" \
    SNAPWORK_WATCH_SERVICE=test SNAPWORK_LISTEN_SECONDS=0 ${TEST_SH:-sh} "$PLUGIN" "$1" > "$T/out" 2> "$T/err"
}
watch() {
  env HOME="$HOMEDIR" SNAPWORK_HOME="$SW" PATH="$T/bin:/usr/bin:/bin" FAKE_DIR="$T/fake" SNAPWORK_WATCH_ONCE=1 \
    SNAPWORK_WATCH_WAIT_S=0 ${TEST_SH:-sh} "$SW/snapwork-watch.sh" > "$T/out" 2> "$T/err"
  echo $? > "$T/rc"
}
# connect <session> <transcript> <folder> <code>: paste the link twice (look up, then confirm).
connect() {
  run prompt "$(prompt "$1" "$2" "$3" "${CONNECT}$4")"
  run prompt "$(prompt "$1" "$2" "$3" "${CONNECT}$4")"
}
work_line() { printf 'start\t%s\tclaude-code\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" > "$T/fake/work_lines"; }

TX1=$(transcript "$S1")
TX2=$(transcript "$S2")
TX3=$(transcript "$S3")

echo "== 0. the first paste only says whose account the link is"
run prompt "$(prompt "$S1" "$TX1" "$P1" "${CONNECT}kfr-cccc-0001")"
has "names the account" "belongs to the SnapWork account \"Minh Vo\" (m"
has "says what connecting allows" "start copies of this chat, working in this project folder, in its rooms"
has "says how to confirm" "paste the same link again to connect this chat"
called "looked it up" "connect-lookup kfr-cccc-0001"
not_called "nothing connected yet" "connect kfr-cccc-0001"
check "nothing saved yet" '[ ! -f "$SW/computer.json" ]'
run prompt "$(prompt "$S2" "$TX2" "$P2" "${CONNECT}kfr-cccc-0001")"
not_called "another chat's paste does not confirm" "connect kfr-cccc-0001"
has "it is asked again" "belongs to the SnapWork account"

echo "== 1. the same link again in the same chat makes it the agent's home"
reset
run prompt "$(prompt "$S1" "$TX1" "$P1" "${CONNECT}kfr-cccc-0001")"
run prompt "$(prompt "$S1" "$TX1" "$P1" "${CONNECT}kfr-cccc-0001")"
has "connected line" "connected. This chat is now the home of \"Claude\""
has "the person is told how to add it" "add \"Claude\" to any room you are in"
called "connect call" "connect kfr-cccc-0001"
check "the plugin names its app and the chat" 'grep -q "\"home_session\":\"$S1\",\"runtime\":\"claude-code\",\"folder\":\"proj\"" "$T/fake/connect_body"'
check "computer key saved, mode 600" '[ "$(ls -l "$SW/computer.json" | cut -c 1-10)" = "-rw-------" ] && grep -q "swc_testcomputerkey123" "$SW/computer.json"'
check "home saved with its folder, command and PATH" 'grep -q "\"project\": \"$P1\"" "$SW/homes/$S1.json" && grep -q "\"runner\": \"$T/bin/claude\"" "$SW/homes/$S1.json" && grep -q "\"path\": \"$T/bin:" "$SW/homes/$S1.json"'
check "home file mode 600" '[ "$(ls -l "$SW/homes/$S1.json" | cut -c 1-10)" = "-rw-------" ]'
check "watcher copied, owner only" '[ "$(ls -l "$SW/snapwork-watch.sh" | cut -c 1-10)" = "-rwx------" ]'
check "home file is valid JSON" 'python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$SW/homes/$S1.json"'
check "computer file is valid JSON" 'python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$SW/computer.json"'

echo "== 2. a second connect on this computer sends its key, in curl's config only"
reset
connect "$S2" "$TX2" "$P2" kfr-cccc-0002
has "connected again" "connected."
check "key went through curl's config" 'grep -q "Bearer swc_testcomputerkey123" "$T/fake/stdin_last"'
not_called "never in argv" "KEY-IN-ARGV"
check "the saved key is kept" 'grep -q "swc_testcomputerkey123" "$SW/computer.json"'

echo "== 2b. a connect link from room.snapwork.ai (the new address) connects the same way"
reset
KEPT_CONNECT=$CONNECT
CONNECT=https://room.snapwork.ai/c/
connect "$S2" "$TX2" "$P2" kfr-cccc-0099
CONNECT=$KEPT_CONNECT
has "connected from the new address" "connected."
called "the connect went to SnapWork" "connect kfr-cccc-0099"

echo "== 3. a disconnected computer's key: connected again as a new computer"
reset
touch "$T/fake/key_refused"
connect "$S2" "$TX2" "$P2" kfr-cccc-0003
has "connected" "connected."
check "two connect calls (with the key, then without)" '[ "$(grep -c "^connect kfr-cccc-0003" "$T/fake/calls")" = 2 ]'

echo "== 4. refusals say what to do"
for pair in "404|was not found" "410|was used or has expired" "403|another SnapWork account" "409|a limit was reached" "400|made for another app" "500|SnapWork answered 500"; do
  reset
  printf '%s' "${pair%%|*}" > "$T/fake/connect_status"
  connect "$S3" "$TX3" "$P2" kfr-cccc-0004
  has "status ${pair%%|*}" "${pair#*|}"
done
check "no home saved after a refusal" '[ ! -f "$SW/homes/$S3.json" ]'
for pair in "404|was not found" "410|was used or has expired"; do
  reset
  printf '%s' "${pair%%|*}" > "$T/fake/lookup_status"
  run prompt "$(prompt "$S3" "$TX3" "$P2" "${CONNECT}kfr-cccc-0008")"
  has "look-up status ${pair%%|*}" "${pair#*|}"
done
reset
printf 'codex' > "$T/fake/lookup_runtime"
run prompt "$(prompt "$S3" "$TX3" "$P2" "${CONNECT}kfr-cccc-0009")"
has "a Codex link in Claude is refused at the look-up" "made for another app"
reset
run prompt "$(prompt "$S3" "$TX3" "$P2" "${CONNECT}kfr-cccc-0010")"
printf 'x %s 1\n' "$S3" > "$SW/connect-pending"
run prompt "$(prompt "$S3" "$TX3" "$P2" "${CONNECT}kfr-cccc-0010")"
not_called "an old or changed confirm does not connect" "connect kfr-cccc-0010"

echo "== 5. a link inside other text, the home folder, a chat in a space"
reset
run prompt "$(prompt "$S3" "$TX3" "$P2" "connect with ${CONNECT}kfr-cccc-0005 please")"
has "paste it alone" "paste the connect link on its own"
not_called "no connect for a link inside text" "connect kfr-cccc-0005"
connect "$S3" "$TX3" "$HOMEDIR" kfr-cccc-0006
has "home folder refused" "open a project folder first"
run prompt "$(prompt "$S3" "$TX3" "$P2" "${INVITE}kfr-aaaa-0001")"
reset
connect "$S3" "$TX3" "$P2" kfr-cccc-0007
has "a chat in a room is never a home" "this chat is in the room \"Space A\""
not_called "no connect from a chat in a room" "connect kfr-cccc-0007"

echo "== 6. the watcher forks the home chat with the invitation as the only prompt"
reset
work_line "$ADD1" "$S1" "${INVITE}kfr-bbbb-0001" "Design review v2"
watch
check "one fork" '[ "$(wc -l < "$T/fake/claude_calls" | tr -d " ")" = 1 ]'
check "in the home's own folder" 'grep -q "^cwd=$P1 " "$T/fake/claude_calls"'
check "with the chat's PATH" 'grep -q " path=$T/bin:" "$T/fake/claude_calls"'
check "only absolute folders on it" '! grep -q " path=[^ ]*::" "$T/fake/claude_calls" && ! grep -q " path=[^ ]*:\.:" "$T/fake/claude_calls"'
check "the fork command, exactly" 'grep -q -F " |--resume |$S1 |--fork-session |--bg |--name |Design review v2 |${INVITE}kfr-bbbb-0001" "$T/fake/claude_calls"'
called "reported started with the full id" "report $ADD1 {\"state\":\"started\",\"session_id\":\"$FORK_ID\"}"
not_called "the key never in argv" "KEY-IN-ARGV"
check "exits cleanly after one poll" '[ "$(cat "$T/rc")" = 0 ]'

echo "== 6b. an invitation on room.snapwork.ai (the new address) is forked the same way"
reset
work_line "$ADD1" "$S1" "https://room.snapwork.ai/j/kfr-bbbb-0001" "Design"
watch
check "forked with the new address's invitation" 'grep -q -F " |--resume |$S1 |--fork-session |--bg |--name |Design |https://room.snapwork.ai/j/kfr-bbbb-0001" "$T/fake/claude_calls"'

echo "== 7. the watcher's refusals"
reset
touch "$T/fake/claude_untrusted"
work_line "$ADD1" "$S1" "${INVITE}kfr-bbbb-0001" "Design"
watch
called "untrusted folder" "report $ADD1 {\"state\":\"failed\",\"failure\":\"not_trusted\"}"
reset
work_line "$ADD1" "99999999-aaaa-4000-8000-000000000009" "${INVITE}kfr-bbbb-0001" "Design"
watch
called "a home this computer never registered" "report $ADD1 {\"state\":\"failed\",\"failure\":\"home_gone\"}"
check "nothing forked for it" '[ ! -f "$T/fake/claude_calls" ]'
reset
work_line "$ADD1" "$S3" "${INVITE}kfr-bbbb-0001" "Design"
mkdir -p "$SW/homes" && printf '{\n  "session": "%s",\n  "project": "%s"\n}\n' "$S3" "$P2" > "$SW/homes/$S3.json"
watch
called "a home that is in a room is never forked" "report $ADD1 {\"state\":\"failed\",\"failure\":\"home_gone\"}"
check "nothing forked for the chat in a room" '[ ! -f "$T/fake/claude_calls" ]'
reset
work_line "$ADD1" "$S1" "https://evil.example.com/j/kfr-bbbb-0001" "Design"
watch
check "an invitation to another host is ignored" '[ ! -f "$T/fake/claude_calls" ]'
not_called "and not reported" "report $ADD1"
reset
work_line "$ADD1" "$S1" "${INVITE}kfr-bbbb-0001" '-rf $(touch pwned)'
watch
check "a name a shell would read is replaced" 'grep -q -F " |--name |SnapWork |" "$T/fake/claude_calls"'
check "nothing ran from the name" '[ ! -e "$P1/pwned" ] && [ ! -e "$HOMEDIR/pwned" ]'
reset
printf 'start\t%s\tcodex\t%s\t%s\tDesign\n' "$ADD1" "$S1" "${INVITE}kfr-bbbb-0001" > "$T/fake/work_lines"
watch
called "Codex is not forked yet (7.4)" "report $ADD1 {\"state\":\"failed\",\"failure\":\"no_runtime\"}"

echo "== 8. a refused key stops the watcher; one watcher per computer"
reset
printf '401' > "$T/fake/work_status"
watch
check "exits 0 on 401" '[ "$(cat "$T/rc")" = 0 ]'
check "logged" 'grep -q "key-refused" "$SW/watch.log"'
reset
sleep 30 &
holder=$!
printf '%s' "$holder" > "$SW/watch.lock"
watch
kill "$holder" 2> /dev/null
called "a lock held by something that is not a watcher is taken over" "work"
reset
cp "$SW/snapwork-watch.sh" "$T/snapwork-watch.sh"
env HOME="$HOMEDIR" SNAPWORK_HOME="$T/other" sh -c 'sleep 30' snapwork-watch.sh &
holder=$!
printf '%s' "$holder" > "$SW/watch.lock"
watch
kill "$holder" 2> /dev/null
not_called "a live watcher keeps its lock" "work"
rm -f "$SW/watch.lock"

echo "== 10. a join by invitation on a connected computer makes the agent the person's (7.6)"
P3=$HOMEDIR/proj3
S4=44444444-aaaa-4000-8000-000000000004
S5=55555555-aaaa-4000-8000-000000000005
S6=66666666-aaaa-4000-8000-000000000006
S7=77777777-aaaa-4000-8000-000000000007
S8=88888888-aaaa-4000-8000-000000000008
home_id() { h=$(printf '%s' "$1" | sha256sum | cut -c 1-32); printf '%s-%s-%s-%s-%s' "$(echo "$h" | cut -c 1-8)" "$(echo "$h" | cut -c 9-12)" "$(echo "$h" | cut -c 13-16)" "$(echo "$h" | cut -c 17-20)" "$(echo "$h" | cut -c 21-32)"; }
HID2=$(home_id "$P2")
HID1=$(home_id "$P1")
reset
run prompt "$(prompt "$S4" "$(transcript "$S4")" "$P2" "${INVITE}kfr-aaaa-0002")"
has "joined as usual" "you just joined the room \"Space 2\""
called "and claimed" "claim"
check "the claim names the folder's home id, the folder and the app" 'grep -q "\"home\":\"$HID2\",\"folder\":\"proj2\",\"runtime\":\"claude-code\"" "$T/fake/claim_bodies"'
check "the claim carries the agent's key, in the body" 'grep -q "\"agent_key\":\"testkey" "$T/fake/claim_bodies"'
not_called "no key on the command line" "KEY-IN-ARGV"
check "the computer key went through curl's config" 'grep -q "Bearer swc_testcomputerkey123" "$T/fake/stdin_last"'
check "the folder home is saved, owner only" '[ "$(ls -l "$SW/homes/$HID2.json" | cut -c 1-10)" = "-rw-------" ]'
check "it is a folder home with its full path" 'grep -q "\"kind\": \"folder\"" "$SW/homes/$HID2.json" && grep -q "\"project\": \"$P2\"" "$SW/homes/$HID2.json" && grep -q "\"home\": \"$HID2\"" "$SW/homes/$HID2.json"'
check "a folder home has no session (an old watcher finds no chat)" '! grep -q "\"session\"" "$SW/homes/$HID2.json"'
check "the folder home is valid JSON" 'python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$SW/homes/$HID2.json"'
check "the room's connection says it was claimed" 'grep -q "\"claimed\": \"$HID2\"" "$SW"/rooms/aaaaaaaa-0000-4000-8000-000000000002.*.json'
check "the log says so, without the key" 'grep -q "claim-ok status=201" "$SW/plugin.log" && ! grep -q "testkey" "$SW/plugin.log"'

echo "== 10a2. a claim refreshes an older watcher copy (computers connected on 0.3.0)"
reset
sed -i.bak 's/^VERSION=.*/VERSION=0.3.0/' "$SW/snapwork-watch.sh" && rm -f "$SW/snapwork-watch.sh.bak"
SA2=a2a2a2a2-aaaa-4000-8000-0000000000a2
printf 'kfr-aaaa-00a2|aaaaaaaa-0000-4000-8000-0000000000a2|Space A2\n' >> "$T/fake/spaces"
run prompt "$(prompt "$SA2" "$(transcript "$SA2")" "$P2" "${INVITE}kfr-aaaa-00a2")"
check "the watcher copy is the plugin's again" 'grep -q "^VERSION=0.3.2$" "$SW/snapwork-watch.sh"'
check "and stays owner only" '[ "$(ls -l "$SW/snapwork-watch.sh" | cut -c 1-10)" = "-rwx------" ]'

echo "== 10b. another chat in the same folder: the same home id"
reset
run prompt "$(prompt "$S5" "$(transcript "$S5")" "$P2" "${INVITE}kfr-aaaa-0003")"
check "same home id for the same folder" 'grep -q "\"home\":\"$HID2\"" "$T/fake/claim_bodies"'

echo "== 10c. a refused claim never spoils the join"
reset
printf '409' > "$T/fake/claim_status"
run prompt "$(prompt "$S6" "$(transcript "$S6")" "$P3" "${INVITE}kfr-aaaa-0004")"
has "joined all the same" "you just joined the room \"Space 4\""
check "logged as refused" 'grep -q "claim-refused status=409" "$SW/plugin.log"'
check "no folder home kept for a refused claim" '[ ! -f "$SW/homes/$(home_id "$P3").json" ]'

echo "== 10d. a copy started by an add (a fork) does not claim"
reset
TXF=$T/tx/$S7.jsonl
printf '{"type":"user","sessionId":"%s"}\n{"type":"user","sessionId":"%s"}\n' "$S1" "$S7" > "$TXF"
run prompt "$(prompt "$S7" "$TXF" "$P1" "${INVITE}kfr-aaaa-0005")"
has "the copy joined" "joined"
not_called "no claim from a copy" "claim"
check "its connection says it is a copy" 'grep -q "\"copy\": \"1\"" "$(grep -l "\"session\": \"$S7\"" "$SW"/rooms/*.json | head -n 1)"'

echo "== 10e. no computer key: nothing is claimed and nothing leaves the computer"
reset
mv "$SW/computer.json" "$T/computer.json.kept"
run prompt "$(prompt "$S8" "$(transcript "$S8")" "$P3" "${INVITE}kfr-aaaa-0006")"
has "joined" "you just joined the room \"Space 6\""
not_called "no claim without a connected computer" "claim"
mv "$T/computer.json.kept" "$SW/computer.json"

echo "== 10f. a connect claims every chat already in a room on this computer, once"
reset
R9=aaaaaaaa-0000-4000-8000-000000000009
A9=00000000-0000-4000-8000-0000000000a9
printf '{\n  "session": "%s",\n  "app": "claude",\n  "project": "%s",\n  "gateway": "https://space.snapwork.ai",\n  "roomId": "%s",\n  "agentId": "%s",\n  "spaceName": "Old room",\n  "agentName": "Claude",\n  "key": "testkeyold9"\n}\n' "$S2" "$P1" "$R9" "$A9" > "$SW/rooms/$R9.$A9.json"
printf '{\n  "session": "%s",\n  "app": "claude",\n  "project": "%s",\n  "gateway": "https://evil.example.com",\n  "roomId": "%s",\n  "agentId": "%s",\n  "key": "testkeyevil"\n}\n' "$S2" "$P1" "$R9" "00000000-0000-4000-8000-0000000000b9" > "$SW/rooms/$R9.00000000-0000-4000-8000-0000000000b9.json"
printf '{\n  "session": "%s",\n  "app": "claude",\n  "project": "relative/folder",\n  "gateway": "https://space.snapwork.ai",\n  "roomId": "%s",\n  "agentId": "%s",\n  "key": "testkeyrel"\n}\n' "$S2" "$R9" "00000000-0000-4000-8000-0000000000c9" > "$SW/rooms/$R9.00000000-0000-4000-8000-0000000000c9.json"
printf '{\n  "session": "%s",\n  "app": "claude",\n  "copy": "1",\n  "project": "%s",\n  "gateway": "https://space.snapwork.ai",\n  "roomId": "%s",\n  "agentId": "%s",\n  "key": "testkeycopy"\n}\n' "$S2" "$P1" "$R9" "00000000-0000-4000-8000-0000000000d9" > "$SW/rooms/$R9.00000000-0000-4000-8000-0000000000d9.json"
chmod 600 "$SW"/rooms/*.json
S9=99999999-aaaa-4000-8000-000000000099
mkdir -p "$HOMEDIR/proj9"
connect "$S9" "$(transcript "$S9")" "$HOMEDIR/proj9" kfr-cccc-0090
has "connected" "connected."
called "the chats already in rooms are claimed" "claim"
check "a chat that joined while the computer was not connected is claimed now" 'grep -q "\"home\":\"$(home_id "$P3")\"" "$T/fake/claim_bodies"'
check "never a relative folder" '! grep -q "testkeyrel" "$T/fake/claim_bodies"'
check "for the old room's chat and folder" 'grep -q "\"agent_key\":\"testkeyold9\",\"home\":\"$HID1\"" "$T/fake/claim_bodies"'
check "never another host's key" '! grep -q "testkeyevil" "$T/fake/claim_bodies"'
check "never a copy started by an add" '! grep -q "testkeycopy" "$T/fake/claim_bodies"'
not_called "no key on the command line" "KEY-IN-ARGV"
reset
connect "$S9" "$(transcript "$S9")" "$HOMEDIR/proj9" kfr-cccc-0091
not_called "a second connect claims nothing again" "claim"

echo "== 10f2. already yours (200): marked claimed, but no folder home is made"
reset
P10=$HOMEDIR/proj10
mkdir -p "$P10"
S10=10101010-aaaa-4000-8000-000000000010
printf 'kfr-aaaa-0010|aaaaaaaa-0000-4000-8000-000000000010|Space 10\n' >> "$T/fake/spaces"
printf '200' > "$T/fake/claim_status"
run prompt "$(prompt "$S10" "$(transcript "$S10")" "$P10" "${INVITE}kfr-aaaa-0010")"
called "claimed" "claim"
check "no folder home for an agent that was already the person's" '[ ! -f "$SW/homes/$(home_id "$P10").json" ]'
check "but its connection is marked, so it is not asked again" 'grep -q "\"claimed\": \"$(home_id "$P10")\"" "$SW"/rooms/aaaaaaaa-0000-4000-8000-000000000010.*.json'

echo "== 10f3. a claim records Claude's own command, even from a Codex chat"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/codex" && chmod 755 "$T/bin/codex"
runner=$(env PATH="$T/bin:/usr/bin:/bin" APP=codex GATEWAY=https://space.snapwork.ai SNAPWORK_HOME="$SW" ${TEST_SH:-sh} -c '. "$1"; claim_runner' sh "$(dirname "$PLUGIN")/snapwork-connect.sh")
check "the runner is claude, not the connecting chat's app" '[ "$runner" = "$T/bin/claude" ]'
rm -f "$T/bin/codex"

echo "== 10g. the watcher starts a fresh chat for a folder home (no copy)"
reset
printf 'start\t%s\tclaude-code\t%s\t%s\tRoom B\tfolder\n' "$ADD1" "$HID2" "${INVITE}kfr-bbbb-0002" > "$T/fake/work_lines"
watch
check "one fresh chat" '[ "$(wc -l < "$T/fake/claude_calls" | tr -d " ")" = 1 ]'
check "in the folder" 'grep -q "^cwd=$P2 " "$T/fake/claude_calls"'
check "the fresh chat command, exactly (no --resume)" 'grep -q -F " |--bg |--name |Room B |${INVITE}kfr-bbbb-0002" "$T/fake/claude_calls" && ! grep -q -F "resume" "$T/fake/claude_calls"'
called "reported started" "report $ADD1 {\"state\":\"started\",\"session_id\":\"$FORK_ID\"}"
reset
printf 'start\t%s\tclaude-code\t%s\t%s\tRoom B\tchat\n' "$ADD1" "$S1" "${INVITE}kfr-bbbb-0002" > "$T/fake/work_lines"
watch
check "a chat home with the 7th field is forked as before" 'grep -q -F " |--resume |$S1 |--fork-session |--bg |--name |Room B |" "$T/fake/claude_calls"'

echo "== 10h. folder home refusals"
reset
printf 'start\t%s\tclaude-code\t%s\t%s\tRoom B\tfolder\n' "$ADD1" "$S1" "${INVITE}kfr-bbbb-0002" > "$T/fake/work_lines"
watch
called "a chat home named as a folder home is refused" "report $ADD1 {\"state\":\"failed\",\"failure\":\"home_gone\"}"
check "nothing started" '[ ! -f "$T/fake/claude_calls" ]'
reset
printf 'start\t%s\tclaude-code\t%s\t%s\tRoom B\tchat\n' "$ADD1" "$HID2" "${INVITE}kfr-bbbb-0002" > "$T/fake/work_lines"
watch
called "a folder home named as a chat is refused (an old watcher's view)" "report $ADD1 {\"state\":\"failed\",\"failure\":\"home_gone\"}"
reset
HIDX=12345678-1234-1234-1234-123456789abc
printf '{\n  "kind": "folder",\n  "home": "%s",\n  "project": "relative/proj"\n}\n' "$HIDX" > "$SW/homes/$HIDX.json"
printf 'start\t%s\tclaude-code\t%s\t%s\tRoom B\tfolder\n' "$ADD1" "$HIDX" "${INVITE}kfr-bbbb-0002" > "$T/fake/work_lines"
watch
called "a relative folder is refused" "report $ADD1 {\"state\":\"failed\",\"failure\":\"home_gone\"}"
reset
printf '{\n  "kind": "folder",\n  "home": "%s",\n  "project": "%s/gone"\n}\n' "$HIDX" "$HOMEDIR" > "$SW/homes/$HIDX.json"
watch
called "a missing folder is refused" "report $ADD1 {\"state\":\"failed\",\"failure\":\"home_gone\"}"
check "nothing started for them" '[ ! -f "$T/fake/claude_calls" ]'
check "the watcher says it is 0.3.2" 'grep -q "^VERSION=0.3.2$" "$SW/snapwork-watch.sh"'
check "the connect script and the watcher name the same version" '[ "$(sed -n "s/^WATCH_VERSION=//p" "$SCRIPTS/snapwork-connect.sh")" = "$(sed -n "s/^VERSION=//p" "$SCRIPTS/snapwork-watch.sh")" ]'

echo "== 9. logs keep no keys, codes or invitations"
check "watch log mode 600" '[ "$(ls -l "$SW/watch.log" | cut -c 1-10)" = "-rw-------" ]'
check "watch log: no key" '! grep -q "swc_" "$SW/watch.log"'
check "watch log: no invitation" '! grep -q "kfr-" "$SW/watch.log"'
check "plugin log: no connect code" '! grep -q "kfr-cccc" "$SW/plugin.log"'
check "plugin log: no key" '! grep -q "swc_" "$SW/plugin.log"'
check "plugin log: no agent key" '! grep -q "testkey" "$SW/plugin.log"'
check "watch log: no agent key" '! grep -q "testkey" "$SW/watch.log"'

printf '\nmy agents: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
