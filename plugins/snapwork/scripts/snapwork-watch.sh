#!/bin/sh
# snapwork-watch.sh: the SnapWork watcher (My agents, SnapWork M7). POSIX sh + curl only.
#
# One per computer, started at login by a user service (snapwork-connect.sh installs it). It asks
# SnapWork, 30 seconds at a time, whether its person added one of the agents homed on this computer
# to a space. For each add it gets: the add's id, the app, the home chat's session id, a one-use
# invitation and the space's name as a safe label. It then copies the home chat into a new
# background chat whose first message is the invitation, so the copy joins the space like any
# pasted invitation (the plugin does the join), and tells SnapWork the copy's session id, or why it
# could not start it in a fixed word (no_runtime, not_trusted, home_gone, fork_failed).
#
# What it never does: run anything but the one fork command, from a home chat this computer
# registered (homes/<id>.json, written by the plugin when the person connected the chat), in that
# chat's own folder as recorded here (never a folder the gateway names), with the invitation as
# the only prompt. It never forks a chat that is in a space. The computer key goes to curl through
# its config on stdin, never on a command line, and is never logged; neither are invitations.
#
# Exits 0 (and the service stays down) when SnapWork refuses the key: the computer was
# disconnected in the console. Connecting a chat again installs and starts it again.
#
#   SNAPWORK_HOME           default ~/.snapwork
#   SNAPWORK_WATCH_ONCE=1   one poll, then exit (tests)
#   SNAPWORK_WATCH_WAIT_S   seconds per poll (default 30)

set -u

GATEWAY=https://space.snapwork.ai
# The same gateway's new main address: its invitations are accepted too (room_word_and_address).
ALT_GATEWAY=https://room.snapwork.ai
VERSION=0.3.0
SNAPWORK_HOME=${SNAPWORK_HOME:-${HOME:-}/.snapwork}
COMPUTER_FILE=$SNAPWORK_HOME/computer.json
HOMES=$SNAPWORK_HOME/homes
ROOMS=$SNAPWORK_HOME/rooms
LOG=$SNAPWORK_HOME/watch.log
LOCK=$SNAPWORK_HOME/watch.lock
WAIT=${SNAPWORK_WATCH_WAIT_S:-30}
ONCE=${SNAPWORK_WATCH_ONCE:-}
LOG_MAX_BYTES=65536
LOG_KEEP_LINES=200
BACKOFF_MAX_S=300
TAB=$(printf '\t')

case $WAIT in '' | *[!0-9]*) WAIT=30 ;; esac

wlog() {
  [ -d "$SNAPWORK_HOME" ] || return 0
  (
    umask 077
    [ ! -L "$LOG" ] || exit 0
    if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" | tr -d ' ')" -gt "$LOG_MAX_BYTES" ]; then
      tail -n "$LOG_KEEP_LINES" "$LOG" > "$LOG.$$" && mv "$LOG.$$" "$LOG"
    fi
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"
    chmod 600 "$LOG"
  ) 2> /dev/null
  return 0
}

# One string field of a saved file, e.g. "project": "...".
field() {
  sed -n "s/^[[:space:]]*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$2" 2> /dev/null | head -n 1
}
valid_uuid() {
  case $1 in ????????-????-????-????-????????????) ;; *) return 1 ;; esac
  case $1 in *[!0-9a-fA-F-]*) return 1 ;; esac
}
short() { printf '%s' "$1" | cut -c 1-8; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/snapwork-watch.XXXXXX") || exit 1
trap 'rm -rf "$WORK"; [ "$(cat "$LOCK" 2> /dev/null)" != "$$" ] || rm -f "$LOCK"' EXIT
trap 'exit 0' TERM INT HUP

# One watcher per computer: a second one (a reconnect while it runs) leaves the first alone.
take_lock() {
  (umask 077 && mkdir -p "$SNAPWORK_HOME") 2> /dev/null || exit 1
  if [ -f "$LOCK" ] && [ ! -L "$LOCK" ]; then
    old=$(cat "$LOCK" 2> /dev/null)
    # Only a live watcher holds it: after a restart its number may belong to something else.
    case $old in
      '' | *[!0-9]*) ;;
      *) case $(ps -p "$old" -o args= 2> /dev/null) in *snapwork-watch.sh*) exit 0 ;; esac ;;
    esac
  fi
  [ ! -L "$LOCK" ] || exit 1
  (umask 077 && printf '%s' "$$" > "$LOCK")
}

# report <add id> <json body>: tells SnapWork how the fork went (best effort, logged).
report() {
  key=$(field key "$COMPUTER_FILE")
  status=$(printf 'header = "Authorization: Bearer %s"\n' "$key" \
    | curl -q -K - -sS --proto =https --max-time 15 -o /dev/null -w '%{http_code}' -X POST \
      -H 'content-type: application/json' --data-binary "$2" "$GATEWAY/computer/work/$1" 2> /dev/null) \
    || status=000
  key=
  wlog "report add=$(short "$1") status=$status"
}
failed() { report "$1" "{\"state\":\"failed\",\"failure\":\"$2\"}"; wlog "failed add=$(short "$1") why=$2"; }

# The home chat this computer registered, or nothing.
HOME_FILE=
home_file() {
  HOME_FILE=$HOMES/$1.json
  { [ -f "$HOME_FILE" ] && [ ! -L "$HOME_FILE" ]; } || return 1
  [ "$(field session "$HOME_FILE")" = "$1" ]
}

# A chat in a space is never forked: its copy would carry that space's talk.
in_a_space() {
  for f in "$ROOMS"/*.json; do
    { [ -f "$f" ] && [ ! -L "$f" ]; } || continue
    [ "$(field session "$f")" != "$1" ] || return 0
  done
  return 1
}

# fork_claude <add> <home> <project> <invitation> <name>
fork_claude() {
  runner=$(field runner "$HOME_FILE")
  { [ -n "$runner" ] && [ -x "$runner" ]; } || runner=$(command -v claude 2> /dev/null)
  case $runner in /*) [ -x "$runner" ] || runner= ;; *) runner= ;; esac
  [ -n "$runner" ] || { failed "$1" no_runtime; return 0; }
  # Only absolute folders: an empty or relative entry would look tools up in the project folder.
  chat_path=$(field path "$HOME_FILE" | tr ':' '\n' | grep '^/' | paste -s -d ':' -)
  out=$(cd "$3" && PATH=${chat_path:-$PATH} "$runner" --resume "$2" --fork-session --bg --name "$5" "$4" 2>&1)
  case $out in *"not trusted"*) failed "$1" not_trusted; return 0 ;; esac
  id8=$(printf '%s' "$out" | sed -n 's/.*backgrounded[^0-9a-f]*\([0-9a-f]\{8\}\).*/\1/p' | head -n 1)
  [ -n "$id8" ] || { failed "$1" fork_failed; return 0; }
  # --bg prints the short id; the full one is in the list of sessions.
  full=$(PATH=${chat_path:-$PATH} "$runner" agents --json 2> /dev/null \
    | grep -o "\"sessionId\"[[:space:]]*:[[:space:]]*\"$id8[0-9a-f-]*\"" | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')
  if valid_uuid "$full"; then
    report "$1" "{\"state\":\"started\",\"session_id\":\"$full\"}"
    wlog "started add=$(short "$1") session=$id8"
  else
    # It runs and will join; SnapWork sees the join. Not reported, so not offered again either way.
    wlog "started add=$(short "$1") session=$id8 full-id-unknown"
  fi
}

# start_one <add> <runtime> <home> <invitation> <name>: one line of work.
start_one() {
  valid_uuid "$1" || { wlog "bad-item"; return 0; }
  valid_uuid "$3" || { failed "$1" home_gone; return 0; }
  case $4 in
    "$GATEWAY/j/"*) code=${4#"$GATEWAY/j/"} ;;
    "$ALT_GATEWAY/j/"*) code=${4#"$ALT_GATEWAY/j/"} ;;
    *) code= ;;
  esac
  case $code in '' | *[!A-Za-z0-9_-]*) wlog "bad-item add=$(short "$1")"; return 0 ;; esac
  name=$5
  case $name in '' | -* | *[\"\'\`\$\\\;\&\|\<\>\(\)\{\}\*\?\[\]\~\#!]*) name=SnapWork ;; esac
  home_file "$3" || { failed "$1" home_gone; return 0; }
  project=$(field project "$HOME_FILE")
  case $project in /*) ;; *) failed "$1" home_gone; return 0 ;; esac
  [ -d "$project" ] || { failed "$1" home_gone; return 0; }
  if in_a_space "$3"; then
    wlog "home-in-space add=$(short "$1")"
    failed "$1" home_gone
    return 0
  fi
  case $2 in
    claude-code) fork_claude "$1" "$3" "$project" "$4" "$name" ;;
    *) failed "$1" no_runtime ;;
  esac
}

poll() {
  key=$(field key "$COMPUTER_FILE")
  [ -n "$key" ] || { wlog "no-key"; exit 0; }
  status=$(printf 'header = "Authorization: Bearer %s"\n' "$key" \
    | curl -q -K - -sS --proto =https --max-time $((WAIT + 15)) -o "$WORK/work" -w '%{http_code}' \
      "$GATEWAY/computer/work?wait=$WAIT&format=lines&v=$VERSION" 2> /dev/null) || status=000
  key=
  case $status in
    200) ;;
    401)
      wlog "key-refused"
      exit 0 ;;
    *) return 1 ;;
  esac
  # `|| [ -n "$kind" ]`: a last line without its line break still counts.
  while IFS=$TAB read -r kind add runtime home invitation name || [ -n "${kind:-}" ]; do
    [ "$kind" = start ] || continue
    start_one "$add" "$runtime" "$home" "$invitation" "$name"
  done < "$WORK/work"
  return 0
}

take_lock
wlog "watcher start version=$VERSION"
backoff=5
while :; do
  if poll; then
    backoff=5
  else
    wlog "poll-failed status=$status wait=$backoff"
    [ -n "$ONCE" ] || sleep "$backoff"
    backoff=$((backoff * 2))
    [ "$backoff" -le "$BACKOFF_MAX_S" ] || backoff=$BACKOFF_MAX_S
  fi
  [ -z "$ONCE" ] || exit 0
done
