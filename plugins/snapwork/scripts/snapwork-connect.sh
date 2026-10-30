# snapwork-connect.sh: sourced by snapwork-plugin.sh (not run by itself). My agents (SnapWork M7).
#
# A message that is only a connect link (https://space.snapwork.ai/c/<code>, made in the console's
# My agents) makes this chat the agent's home: SnapWork remembers this chat's session id and folder,
# and from then on the person adds the agent to any space they are in from the console. For each
# space, the watcher on this computer (snapwork-watch.sh) copies this chat into a new background
# chat whose first message is that space's one-use invitation; the copy joins like any pasted
# invitation, and this chat stays as it is.
#
# What it writes, all owner-only:
#   $SNAPWORK_HOME/computer.json     this computer's id and key (the first connect on it gets one)
#   $SNAPWORK_HOME/homes/<id>.json   the home chat: its folder, app, agent, the claude or codex
#                                    command to fork it with and the chat's PATH (the watcher finds
#                                    the folder here, never from what the gateway sends)
#   $SNAPWORK_HOME/snapwork-watch.sh a copy of the watcher, started at login by a user service:
#                                    macOS ~/Library/LaunchAgents/ai.snapwork.watch.plist,
#                                    Linux ~/.config/systemd/user/snapwork-watch.service
# Connecting takes two pastes of the same link: the first only looks it up and says whose SnapWork
# account it belongs to (name and an email hint), because connecting lets that account start
# copies of this chat in its spaces; pasting it again in the same chat within 10 minutes connects.
# A link someone else made can never connect a chat by one careless paste.
# A chat that is in a space is never a home: a copy of it would carry that space's talk into the
# next one. The computer key goes to curl through its config on stdin, never on a command line, and
# is never printed or logged.
#
# Uses from snapwork-plugin.sh: GATEWAY, APP, AGENT_FOR, SID, CWD, HOME_REAL, SNAPWORK_HOME, HERE, WORK,
# STATE, work_dir, plog, safe, field, pick, try_adopt, space_of.

CONNECT_URL=$GATEWAY/c/
COMPUTER_FILE=$SNAPWORK_HOME/computer.json
HOMES=$SNAPWORK_HOME/homes
WATCH_SCRIPT=$SNAPWORK_HOME/snapwork-watch.sh
WATCH_VERSION=0.3.0
WATCH_LABEL=ai.snapwork.watch
WATCH_NOTE=
PENDING=$SNAPWORK_HOME/connect-pending
CONFIRM_SECONDS=600

connect_fail() {
  plog "connect-failed why=$2"
  printf 'SnapWork: could not connect this chat: %s. Tell the person this in one line.\n' "$1"
  exit 0
}

# The computer's name as people will see it in the console.
computer_name() {
  n=
  [ "$(uname -s 2> /dev/null)" != Darwin ] || n=$(scutil --get ComputerName 2> /dev/null)
  [ -n "$n" ] || n=$(hostname 2> /dev/null)
  safe "${n:-My computer}"
}

# The command that forks this app's chats, as an absolute path (services start with a short PATH);
# nothing if its path could break the saved file.
runner_path() {
  if [ "$APP" = codex ]; then r=$(command -v codex 2> /dev/null); else r=$(command -v claude 2> /dev/null); fi
  case $r in /*) ;; *) return 0 ;; esac
  case $r in *'"'* | *\\* | *[[:cntrl:]]*) return 0 ;; esac
  printf '%s' "$r"
}

# The chat's PATH with only absolute folders: an empty or relative entry would look tools up in
# the project folder, where a cloned repository could plant one.
absolute_path() {
  printf '%s' "${PATH:-}" | tr -d '"\\' | tr -d '[:cntrl:]' | tr ':' '\n' | grep '^/' | paste -s -d ':' -
}

# write_owner_only <file> <content>: through a temp file in the same folder, mode 600.
write_owner_only() {
  [ ! -L "$1" ] || return 1
  (umask 077 && printf '%s' "$2" > "$1.$$" && chmod 600 "$1.$$" && mv "$1.$$" "$1")
}

# connect_post <code> <key or empty>: POST the connect; the reply in $WORK/connect.json, the
# HTTP status on stdout.
connect_post() {
  folder=$(basename -- "$CWD" | tr -d '"\\' | tr -d '[:cntrl:]')
  os=$(uname -s 2> /dev/null | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9._-')
  body=$(printf '{"home_session":"%s","runtime":"%s","folder":"%s","computer":{"name":"%s","os":"%s"},"watcher_version":"%s"}' \
    "$SID" "$AGENT_FOR" "$folder" "$(computer_name)" "$os" "$WATCH_VERSION")
  { [ -z "$2" ] || printf 'header = "Authorization: Bearer %s"\n' "$2"; } \
    | curl -q -K - -sS --proto =https --max-time 30 -o "$WORK/connect.json" -w '%{http_code}' -X POST \
      -H 'content-type: application/json' --data-binary "$body" "$CONNECT_URL$1/connect" 2> /dev/null \
    || printf '000'
}

on_connect() {
  code=$1
  command -v curl > /dev/null 2>&1 || connect_fail "curl is missing on this computer" no-curl
  case $SID in
    ????????-????-????-????-????????????) ;;
    *) connect_fail "this app did not say which chat this is, so it cannot be the agent's home" no-session ;;
  esac
  case $CWD in / | *'"'* | *\\* | *[[:cntrl:]]*) connect_fail "open a project folder first (not your home folder), then paste the link again" bad-folder ;; esac
  [ "$CWD" != "$HOME_REAL" ] || connect_fail "open a project folder first (not your home folder), then paste the link again" home-folder
  if pick bound || try_adopt; then
    connect_fail "this chat is in the room \"$(space_of "$STATE")\", and a copy of it would carry that room's talk into the next one; paste the link in a chat that is in no room" in-space
  fi
  (umask 077 && mkdir -p "$SNAPWORK_HOME" "$HOMES") || connect_fail "cannot create $HOMES" no-dir
  chmod 700 "$SNAPWORK_HOME" "$HOMES" 2> /dev/null
  work_dir || connect_fail "mktemp failed" no-tmp
  confirmed "$code" || ask_to_confirm "$code"
  key=
  [ ! -f "$COMPUTER_FILE" ] || key=$(field key "$COMPUTER_FILE")
  status=$(connect_post "$code" "$key")
  if [ "$status" = 401 ] && [ -n "$key" ]; then
    # This computer was disconnected in the console: connect it as a new one.
    plog "connect-key-refused"
    key=
    status=$(connect_post "$code" "")
  fi
  case $status in
    201) ;;
    404) connect_fail "this connect link was not found; make a new one in My agents" not-found ;;
    410) connect_fail "this connect link was used or has expired; make a new one in My agents" gone ;;
    400) connect_fail "this link was made for another app; make one for this app in My agents" other-app ;;
    403) connect_fail "this computer is connected to another SnapWork account" other-account ;;
    409) connect_fail "a limit was reached (agents or computers); remove one in My agents, then make a new link" limit ;;
    429) connect_fail "too many tries; wait a few minutes and paste a new link" rate ;;
    *) connect_fail "SnapWork answered $status" "status-$status" ;;
  esac
  reply=$WORK/connect.json
  agent_id=$(grep -o '"agent":{"id":"[^"]*"' "$reply" | head -n 1 | sed 's/.*"id":"//;s/"$//')
  agent_name=$(safe "$(grep -o '"agent":{"id":"[^"]*","name":"[^"]*"' "$reply" | head -n 1 | sed 's/.*"name":"//;s/"$//')")
  computer_id=$(grep -o '"computer":{"id":"[^"]*"' "$reply" | head -n 1 | sed 's/.*"id":"//;s/"$//')
  new_key=$(grep -o '"key":"swc_[A-Za-z0-9_-]*"' "$reply" | head -n 1 | sed 's/^"key":"//;s/"$//')
  valid_agent "$agent_id" || connect_fail "the reply was not understood" bad-reply
  valid_agent "$computer_id" || connect_fail "the reply was not understood" bad-reply
  if [ -n "$new_key" ]; then
    write_owner_only "$COMPUTER_FILE" "$(printf '{\n  "computerId": "%s",\n  "gateway": "%s",\n  "key": "%s"\n}\n' \
      "$computer_id" "$GATEWAY" "$new_key")" || connect_fail "cannot save this computer's key" no-save
  fi
  new_key=
  key=
  # The chat's own PATH, so a copy started by the watcher (whose service has a short one) finds the
  # same tools this chat does.
  chat_path=$(absolute_path)
  write_owner_only "$HOMES/$SID.json" "$(printf '{\n  "session": "%s",\n  "app": "%s",\n  "project": "%s",\n  "agentId": "%s",\n  "agentName": "%s",\n  "runner": "%s",\n  "path": "%s"\n}\n' \
    "$SID" "$APP" "$CWD" "$agent_id" "$agent_name" "$(runner_path)" "$chat_path")" || connect_fail "cannot save this chat as the home" no-save
  install_watcher
  plog "connected agent=$(printf '%s' "$agent_id" | cut -c 1-8) watcher=$WATCH_NOTE"
  printf 'SnapWork: connected. This chat is now the home of "%s" on this computer. From My agents in the SnapWork console, add "%s" to any room you are in: each room gets its own copy of this chat, started in the background, and this chat stays as it is.%s Tell the person this in one line.\n' \
    "$agent_name" "$agent_name" "$(watch_note_text)"
  exit 0
}

watch_note_text() {
  case $WATCH_NOTE in
    service | test) ;;
    background) printf ' (The watcher runs until this computer restarts; paste a new link after a restart.)' ;;
    unsupported) printf ' (This computer cannot run the watcher yet: macOS and Linux only. Each room can still be added by hand from the console.)' ;;
    *) printf ' (The watcher could not be started; each room can still be added by hand from the console.)' ;;
  esac
}

# confirmed <code>: this chat pasted this link moments ago and was told whose it is.
confirmed() {
  { [ -f "$PENDING" ] && [ ! -L "$PENDING" ]; } || return 1
  want=$(printf '%s' "$1" | sha_of) || return 1
  # `|| [ -n ... ]`: the saved line has no line break at its end.
  read -r hash sid at < "$PENDING" 2> /dev/null || [ -n "${at:-}" ] || return 1
  rm -f "$PENDING"
  now=$(date +%s)
  case $at in '' | *[!0-9]*) return 1 ;; esac
  [ "$hash" = "$want" ] && [ "$sid" = "$SID" ] && [ $((now - at)) -le "$CONFIRM_SECONDS" ]
}

# ask_to_confirm <code>: look the link up (nothing is used), say whose account it is, remember it.
ask_to_confirm() {
  status=$(curl -q -sS --proto =https --max-time 15 -o "$WORK/lookup.json" -w '%{http_code}'     "$CONNECT_URL$1" 2> /dev/null) || status=000
  case $status in
    200) ;;
    404) connect_fail "this connect link was not found; make a new one in My agents" not-found ;;
    410) connect_fail "this connect link was used or has expired; make a new one in My agents" gone ;;
    429) connect_fail "too many tries; wait a few minutes and paste a new link" rate ;;
    *) connect_fail "SnapWork answered $status" "lookup-$status" ;;
  esac
  name=$(safe "$(grep -o '"name":"[^"]*"' "$WORK/lookup.json" | head -n 1 | sed 's/^"name":"//;s/"$//')")
  email=$(safe "$(grep -o '"email":"[^"]*"' "$WORK/lookup.json" | head -n 1 | sed 's/^"email":"//;s/"$//')")
  runtime=$(grep -o '"runtime":"[a-z-]*"' "$WORK/lookup.json" | head -n 1 | sed 's/^"runtime":"//;s/"$//')
  if [ -n "$runtime" ] && [ "$runtime" != "$AGENT_FOR" ]; then
    connect_fail "this link was made for another app; make one for this app in My agents" other-app
  fi
  hash=$(printf '%s' "$1" | sha_of) || connect_fail "this computer has no sha256sum or shasum" no-sha
  write_owner_only "$PENDING" "$hash $SID $(date +%s)" || connect_fail "cannot remember the link" no-save
  plog "connect-asked"
  printf 'SnapWork: this connect link belongs to the SnapWork account "%s"%s. Connecting lets that account start copies of this chat, working in this project folder, in its rooms. If that is your own account, paste the same link again to connect this chat; if not, do nothing. Tell the person exactly this; do not paste it yourself.\n' \
    "${name:-Unknown}" "${email:+ ($email)}"
  exit 0
}

# ---- the watcher ----

xml_escape() { printf '%s' "$1" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g'; }

install_launchd() {
  agents=$HOME/Library/LaunchAgents
  plist=$agents/$WATCH_LABEL.plist
  mkdir -p "$agents" 2> /dev/null || return 1
  [ ! -L "$plist" ] || return 1
  w=$(xml_escape "$WATCH_SCRIPT")
  h=$(xml_escape "$SNAPWORK_HOME")
  p=$(xml_escape "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin")
  (umask 077 && cat > "$plist.$$" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$WATCH_LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/sh</string><string>$w</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>SNAPWORK_HOME</key><string>$h</string>
    <key>PATH</key><string>$p</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>30</integer>
</dict>
</plist>
EOF
  ) && mv "$plist.$$" "$plist" || return 1
  uid=$(id -u)
  launchctl bootout "gui/$uid/$WATCH_LABEL" > /dev/null 2>&1
  launchctl bootstrap "gui/$uid" "$plist" > /dev/null 2>&1
}

install_systemd() {
  command -v systemctl > /dev/null 2>&1 || return 1
  # A unit file reads %, $, quotes and backslashes itself: such a path runs in the background instead.
  case $WATCH_SCRIPT$SNAPWORK_HOME in *%* | *'$'* | *'"'* | *\\*) return 1 ;; esac
  units=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
  unit=$units/snapwork-watch.service
  mkdir -p "$units" 2> /dev/null || return 1
  [ ! -L "$unit" ] || return 1
  (umask 077 && cat > "$unit.$$" << EOF
[Unit]
Description=SnapWork watcher: starts a copy of your agent's home chat when you add it to a room

[Service]
ExecStart=/bin/sh "$WATCH_SCRIPT"
Environment="SNAPWORK_HOME=$SNAPWORK_HOME"
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
Restart=on-failure
RestartSec=30

[Install]
WantedBy=default.target
EOF
  ) && mv "$unit.$$" "$unit" || return 1
  systemctl --user daemon-reload > /dev/null 2>&1 || return 1
  systemctl --user enable snapwork-watch.service > /dev/null 2>&1 || return 1
  # restart, not start: a watcher already running picks up a newer copy of the script.
  systemctl --user restart snapwork-watch.service > /dev/null 2>&1
}

# The watcher copied out of the plugin (the plugin's folder changes with every update) and started
# by a user service, else in the background until the computer restarts.
install_watcher() {
  src=$HERE/snapwork-watch.sh
  if [ ! -f "$src" ] || [ -L "$WATCH_SCRIPT" ]; then WATCH_NOTE=failed; return 0; fi
  (umask 077 && cp "$src" "$WATCH_SCRIPT.$$" && chmod 700 "$WATCH_SCRIPT.$$" && mv "$WATCH_SCRIPT.$$" "$WATCH_SCRIPT") \
    || { WATCH_NOTE=failed; return 0; }
  case ${SNAPWORK_WATCH_SERVICE:-$(uname -s 2> /dev/null)} in
    test) WATCH_NOTE=test; return 0 ;;
    Darwin) if install_launchd; then WATCH_NOTE=service; return 0; fi ;;
    Linux) if install_systemd; then WATCH_NOTE=service; return 0; fi ;;
    *) WATCH_NOTE=unsupported; return 0 ;;
  esac
  # No user service here (an SSH login without a user bus): run it until the computer restarts.
  if (SNAPWORK_HOME=$SNAPWORK_HOME nohup /bin/sh "$WATCH_SCRIPT" > /dev/null 2>&1 &); then
    WATCH_NOTE=background
  else
    WATCH_NOTE=failed
  fi
}
