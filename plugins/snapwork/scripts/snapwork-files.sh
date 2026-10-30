#!/bin/sh
# snapwork-files.sh: send and fetch SnapWork files with POSIX sh + curl only (M6.2).
# snapwork-files-version: 4
#
# snapwork-hook.sh hands its file commands to this script (it lives next to it, in ~/.snapwork),
# after it has found the connection and checked the gateway, the key and, when the setup pinned it,
# this script's own SHA-256:
#
#   snapwork-hook.sh --say --room ID [--agent ID] --file <path> -- <note>   (share a file)
#   snapwork-hook.sh --fetch --room ID [--agent ID] <file id>               (fetch one)
#
# and calls it as
#
#   snapwork-files.sh send  --gateway URL --room ID [--agent ID] --project DIR --file PATH [--note-json FILE] [-- note...]
#   snapwork-files.sh fetch --gateway URL --room ID [--agent ID] --project DIR --space NAME <file id>
#   snapwork-files.sh news --room ID [--agent ID] --as once|rewake|stop|prompt
#                                     (a background upload that failed, told once; exit 3: nothing)
#   snapwork-files.sh run <upload folder>                (the background upload itself)
#
# send, fetch and run read the agent key from the first line of stdin; it goes to curl as a config
# on stdin, never on a command line, in the environment or in a file this script writes.
#
# Sending: only a regular file with one link, inside a project folder that is not the home folder
# or the whole disk (real paths, after links in folder names are resolved), never a link, never a
# path with a line break, and never a path whose parts look like secrets (any case; the same list
# as files.ts in the snapwork-room skill): .git, .env*, .ssh, .snapwork, .aws, .gnupg, .config/gh,
# .netrc, .npmrc, .pypirc, .docker, .kube, .git-credentials, id_*, *.pem, *.key, *.p12, *.pfx.
# The upload uses the gateway's tus routes in pieces of exactly the part size the gateway gives
# (at most 50 MiB), then a say with "file_id" shares it (the rest of the command is its note). Up
# to 8 MiB is sent before the command returns ("sent"). A bigger file uploads in the background,
# so an agent's command time limit cannot cut it: the command returns at once, the space sees the
# progress, and a failure for good is told to the agent by its listener (the next wake), from
# $SNAPWORK_HOME/uploads/<file id>/status. Before every piece the file is checked again (not a
# link, still in the project, same device, inode and size, one link): a change stops the upload.
# A piece that fails is sent again from where the gateway is (it keeps every whole piece), up to 8
# tries with growing pauses. The background job runs in its own session: setsid, else perl's
# POSIX::setsid, else a subshell that ignores HUP (that last one can still be stopped with the
# terminal's whole process group, a gap on systems with neither setsid nor perl).
#
# Fetching: into <project>/snapwork-files/<space name>/<cleaned name> (private to you), " (2)" on a
# clash, never over an existing file; the name never becomes a path (letters, digits and a few
# marks only). It needs the file's size plus 1 GB free. Bytes go straight into a hidden .part, so a
# cut or killed download keeps what arrived and the next run asks for the rest (Range, If-Range);
# only the whole file is checked against the gateway's sha256 ETag, and removed when it does not
# match. Error replies never land in the file, and nothing but the file is left once it is saved.
#
# File names and room text are untrusted: they are only cleaned, quoted and printed, never run.

set -u

SELF=$0
HOME_DIR=${SNAPWORK_HOME:-${HOME:-.}/.snapwork}
UPLOADS_DIR=$HOME_DIR/uploads
FOREGROUND_MAX=${SNAPWORK_FILES_FOREGROUND_MAX:-8388608}
case $FOREGROUND_MAX in '' | *[!0-9]*) FOREGROUND_MAX=8388608 ;; esac
PART_MAX=52428800
FREE_MARGIN_KB=1048576
PIECE_TRIES=${SNAPWORK_FILES_TRIES:-8}
case $PIECE_TRIES in '' | *[!0-9]* | 0) PIECE_TRIES=8 ;; esac
PAUSE_BASE=${SNAPWORK_FILES_PAUSE_S:-2}
case $PAUSE_BASE in '' | *[!0-9]*) PAUSE_BASE=2 ;; esac
TUS='Tus-Resumable: 1.0.0'
NL='
'

MODE=${1:-}
[ $# -gt 0 ] && shift
GATEWAY=
ROOM=
AGENT=
PROJECT=
SPACE=
FILE_ARG=
NOTE_JSON=
NOTE=
ID_ARG=
AS=
KEY=

say_line() { printf '%s\n' "$1"; }
failed() { printf 'failed: %s\n' "$1"; exit 1; }

while [ $# -gt 0 ]; do
  case $1 in
    --gateway) shift; GATEWAY=${1:-} ;;
    --room) shift; ROOM=${1:-} ;;
    --agent) shift; AGENT=${1:-} ;;
    --project) shift; PROJECT=${1:-} ;;
    --space) shift; SPACE=${1:-} ;;
    --file) shift; FILE_ARG=${1:-} ;;
    --note-json) shift; NOTE_JSON=${1:-} ;;
    --as) shift; AS=${1:-} ;;
    --) shift; NOTE="$*"; break ;;
    *)
      if [ -z "$ID_ARG" ]; then ID_ARG=$1; else failed "unknown argument"; fi
      ;;
  esac
  shift
done

valid_room() { case $1 in '' | *[!A-Za-z0-9_-]*) return 1 ;; esac; }
valid_agent() {
  case $1 in ????????-????-????-????-????????????) ;; *) return 1 ;; esac
  case $1 in *[!0-9a-fA-F-]*) return 1 ;; esac
}
# The gateway's file ids: up to five groups of letters and digits joined by dashes.
valid_file_id() {
  case $1 in '' | -* | *- | *--* | *[!a-z0-9-]*) return 1 ;; esac
  [ "${#1}" -le 84 ]
}
# https anywhere; plain http only for exactly localhost, 127.0.0.1 or [::1] (then a port or path).
valid_gateway() {
  case $1 in *@* | *[!A-Za-z0-9._~:/\[\]-]*) return 1 ;; esac
  case $1 in
    https://?*) return 0 ;;
    http://127.0.0.1 | http://127.0.0.1:* | http://127.0.0.1/*) return 0 ;;
    http://localhost | http://localhost:* | http://localhost/*) return 0 ;;
    'http://[::1]' | 'http://[::1]:'* | 'http://[::1]/'*) return 0 ;;
  esac
  return 1
}
read_key() {
  IFS= read -r KEY || true
  case $KEY in '' | *[!A-Za-z0-9._~+/=-]*) failed "missing or odd agent key" ;; esac
}

# One "name=value" line of a status file.
status_field() { sed -n "s/^$1=//p" "$2" 2> /dev/null | head -n 1; }

# Writes a whole status file at once, so a reader never sees half of it.
write_status() {
  dir=$1
  shift
  (umask 077 && printf '%s\n' "$@" > "$dir/status.$$.tmp") && mv "$dir/status.$$.tmp" "$dir/status"
}

# Replaces one field of a status file.
set_status() {
  dir=$1
  (umask 077 && { sed "/^$2=/d" "$dir/status"; printf '%s=%s\n' "$2" "$3"; } > "$dir/status.$$.tmp") \
    && mv "$dir/status.$$.tmp" "$dir/status"
}

# What people read: decimal units, like the gateway's own sizes ("3.2 GB").
human_size() {
  awk -v b="$1" 'BEGIN {
    if (b < 1000) { printf "%d bytes", b; exit }
    split("KB MB GB TB", u, " "); v = b / 1000; i = 1
    while (v >= 1000 && i < 4) { v /= 1000; i++ }
    if (v < 10) printf "%.1f %s", v, u[i]; else printf "%d %s", v + 0.5, u[i]
  }'
}

sha_of() {
  if command -v sha256sum > /dev/null 2>&1; then sha256sum < "$1" | cut -d ' ' -f 1
  elif command -v shasum > /dev/null 2>&1; then shasum -a 256 < "$1" | cut -d ' ' -f 1
  else return 1
  fi
}

# Printable ASCII only (slashes kept for paths), no quotes or backslashes, at most $2 characters: safe to show in a line.
shown() { printf '%s' "$1" | LC_ALL=C tr -cd 'A-Za-z0-9 ._()+,=@/-' | cut -c 1-"${2:-120}"; }
# The same for a sentence (a reason): colons, semicolons and percent signs kept too.
shown_text() { printf '%s' "$1" | LC_ALL=C tr -cd 'A-Za-z0-9 ._()+,=@/:;%-' | cut -c 1-"${2:-300}"; }

# JSON string body of the text: escape backslash, quote, tab, CR and newline; drop other control chars.
json_text() {
  tab=$(printf '\t')
  cr=$(printf '\r')
  printf '%s\n' "$1" | LC_ALL=C tr -d '\001-\010\013\014\016-\037\177' \
    | LC_ALL=C sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/$tab/\\\\t/g" -e "s/$cr/\\\\r/g" \
    | LC_ALL=C awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }'
}

# The gateway's own words from an error reply, cleaned and short.
reason_of() {
  LC_ALL=C tr -d '\r\n' < "$1" 2> /dev/null | LC_ALL=C sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | LC_ALL=C tr -cd 'A-Za-z0-9 _.,:;()%/+=-' | cut -c 1-200
}

# curl with the key from stdin. Prints the HTTP status ("000" when nothing answered) and returns
# curl's own exit code, so a cut transfer is told apart from a whole one.
api() {
  printf 'header = "Authorization: Bearer %s"\n' "$KEY" | curl -q -K - --proto =https,http -sS "$@" -w '%{http_code}' 2> /dev/null
}

# Device, inode, link count and size of a file ("dev:ino:links:size"), GNU or BSD stat.
file_ident() { stat -c '%d:%i:%h:%s' "$1" 2> /dev/null || stat -f '%d:%i:%l:%z' "$1" 2> /dev/null; }

# A path part that looks like a secret (lowercase, trailing dots and spaces gone). Keep identical
# with SECRET_PARTS in .claude/skills/snapwork-room/scripts/files.ts.
secret_part() {
  case $1 in
    .git | .env | .env* | .envrc | .ssh | .snapwork | .aws | .gnupg | .netrc | .npmrc | .pypirc | .docker | .kube | .git-credentials | .bash_history | .zsh_history | .pgpass | .terraform.d | id_* | *.pem | *.key | *.p12 | *.pfx | *.jks | *.keystore | *.p8) return 0 ;;
  esac
  return 1
}
# Two-part folders that hold keys. Keep identical with SECRET_FOLDERS in files.ts.
SECRET_FOLDERS='.config/gh .config/gcloud'

# The reason a real path may not be sent, or nothing. Each part is compared lowercased and without
# trailing dots and spaces, so "k.pem." or ".ssh " is no way around the list.
secret_reason() {
  rest=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  rest=${rest#/}
  norm=
  while [ -n "$rest" ]; do
    part=$(printf '%s' "${rest%%/*}" | sed 's/[. ]*$//')
    case $rest in */*) rest=${rest#*/} ;; *) rest= ;; esac
    [ -n "$part" ] || continue
    norm=$norm/$part
    if secret_part "$part"; then
      printf '%s looks like a secret (keys, tokens, .env, .git), so it is never sent' "$(shown "$part" 60)"
      return 0
    fi
  done
  for folder in $SECRET_FOLDERS; do
    case $norm/ in */"$folder"/*) printf 'files under %s are never sent: they hold keys' "$folder"; return 0 ;; esac
  done
  return 1
}

# ---- news: a background upload that failed, told once ----
if [ "$MODE" = news ]; then
  valid_room "$ROOM" || exit 3
  [ -d "$UPLOADS_DIR" ] || exit 3
  out=
  for st in "$UPLOADS_DIR"/*/status; do
    [ -f "$st" ] && [ ! -L "$st" ] || continue
    [ "$(status_field room "$st")" = "$ROOM" ] || continue
    [ "$(status_field agent "$st")" = "$AGENT" ] || continue
    [ "$(status_field reported "$st")" = 0 ] || continue
    dir=$(dirname "$st")
    state=$(status_field state "$st")
    reason=$(status_field reason "$st")
    if [ "$state" = uploading ]; then
      # The job is gone (the computer slept, restarted or killed it) without saying why.
      pid=$(status_field pid "$st" | tr -cd '0-9')
      if [ -n "$pid" ] && kill -0 "$pid" 2> /dev/null; then continue; fi
      # Just started: the job has not written its pid yet.
      if [ -z "$pid" ] && [ -z "$(find "$st" -mmin +2 2> /dev/null)" ]; then continue; fi
      state=failed
      reason="the upload stopped before it was done (the computer may have slept or restarted)"
      set_status "$dir" state failed
    fi
    [ "$state" = failed ] || continue
    set_status "$dir" reported 1
    name=$(shown "$(status_field name "$st")")
    path=$(status_field path "$st")
    again=" Send it again from your project folder."
    if [ -n "$path" ] && [ "$(shown "$path" 400)" = "$path" ]; then
      again=" Send it again with: sh ~/.snapwork/snapwork-hook.sh --say --room $ROOM${AGENT:+ --agent $AGENT} --file '$path' -- '<note>'"
    fi
    out="${out:+$out$NL}SnapWork: your file \"$name\" was not sent to the room: $(shown_text "${reason:-it failed}"). The room did not get it.$again"
  done
  [ -n "$out" ] || exit 3
  json() { printf '%s' "$(json_text "$out")"; }
  case $AS in
    once) printf '%s\n' "$out" ;;
    rewake) printf '%s\n' "$out" >&2; exit 2 ;;
    stop) printf '{"decision":"block","reason":"%s"}\n' "$(json)" ;;
    *) printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"}}\n' "$(json)" ;;
  esac
  exit 0
fi

# ---- the pieces, shared by the foreground and the background ----

# Where the gateway is with this upload: sets OFFSET, or returns 1.
upload_offset() {
  code=$(api -o "$WORK/head" -H "$TUS" "$GATEWAY/rooms/$ROOM/uploads/$FILE_ID")
  [ "$code" = 200 ] || { REASON=$(reason_of "$WORK/head"); REASON=${REASON:-HTTP $code}; return 1; }
  OFFSET=$(LC_ALL=C tr -d '\r\n ' < "$WORK/head" | sed -n 's/.*"offset":\([0-9][0-9]*\).*/\1/p')
  [ -n "$OFFSET" ]
}

# The file is still the one that was checked: not a link, in the project, same device, inode and
# size, one link. Its real folder must not have moved either.
still_same() {
  [ ! -L "$SRC" ] && [ -f "$SRC" ] || return 1
  [ "$(cd "${SRC%/*}" 2> /dev/null && pwd -P)" = "${SRC%/*}" ] || return 1
  case $SRC in "$PROJ"/*) ;; *) return 1 ;; esac
  [ "$(file_ident "$SRC")" = "$IDENT" ]
}

# Sends every piece from where the gateway is. Returns 1 with REASON set when it gives up.
send_pieces() {
  tries=0
  upload_offset || return 1
  while [ "$OFFSET" -lt "$SIZE" ]; do
    [ $((OFFSET % PART)) -eq 0 ] || { REASON="the gateway is at an odd place in the file"; return 1; }
    still_same || { REASON="the file changed while sending"; return 1; }
    dd if="$SRC" of="$WORK/piece" bs="$PART" skip=$((OFFSET / PART)) count=1 2> /dev/null \
      || { REASON="could not read the file"; return 1; }
    code=$(api -o "$WORK/resp" -X PATCH -T "$WORK/piece" -H "$TUS" -H 'Expect:' \
      -H 'Content-Type: application/offset+octet-stream' -H "Upload-Offset: $OFFSET" \
      "$GATEWAY/rooms/$ROOM/uploads/$FILE_ID")
    case $code in
      204)
        OFFSET=$((OFFSET + $(wc -c < "$WORK/piece" | tr -d ' ')))
        tries=0
        [ -z "${STATUS_DIR:-}" ] || set_status "$STATUS_DIR" offset "$OFFSET"
        continue
        ;;
      000 | 408 | 409 | 423 | 429 | 5??) ;;
      *)
        REASON=$(reason_of "$WORK/resp")
        REASON=${REASON:-the gateway answered HTTP $code}
        return 1
        ;;
    esac
    tries=$((tries + 1))
    if [ "$tries" -ge "$PIECE_TRIES" ]; then
      REASON="the gateway could not be reached for a while (HTTP $code)"
      return 1
    fi
    pause=$PAUSE_BASE
    i=1
    while [ "$i" -lt "$tries" ] && [ "$pause" -lt 60 ]; do pause=$((pause * 2)); i=$((i + 1)); done
    [ "$pause" -gt 0 ] && sleep "$pause"
    # A cut or refused piece: ask where the gateway is, and go on from there.
    upload_offset || return 1
  done
  rm -f "$WORK/piece"
  return 0
}

# Shares the finished upload with its note. Returns 1 with REASON set.
share() {
  code=$(api -o "$WORK/said" -X POST -H 'content-type: application/json' \
    --data-binary "@$1" "$GATEWAY/rooms/$ROOM/say")
  case $code in 2??) return 0 ;; esac
  if [ "$code" = 000 ]; then
    sleep "$PAUSE_BASE"
    code=$(api -o "$WORK/said" -X POST -H 'content-type: application/json' \
      --data-binary "@$1" "$GATEWAY/rooms/$ROOM/say")
    case $code in 2??) return 0 ;; esac
  fi
  REASON=$(reason_of "$WORK/said")
  REASON="the file is uploaded as $FILE_ID but the room did not take the message (${REASON:-HTTP $code}); it is kept 24 hours unshared"
  return 1
}

# ---- run: the background upload ----
if [ "$MODE" = run ]; then
  trap '' HUP
  STATUS_DIR=$ID_ARG
  [ -n "$STATUS_DIR" ] && [ -f "$STATUS_DIR/status" ] && [ ! -L "$STATUS_DIR/status" ] || exit 1
  read_key
  # One run per upload: the lock folder holds the pid of the run that has it.
  lock=$STATUS_DIR/lock
  if ! mkdir "$lock" 2> /dev/null; then
    holder=$(cat "$lock/pid" 2> /dev/null | tr -cd '0-9')
    if [ -n "$holder" ] && kill -0 "$holder" 2> /dev/null; then exit 0; fi
    rm -rf "$lock"
    mkdir "$lock" 2> /dev/null || exit 0
  fi
  printf '%s\n' "$$" > "$lock/pid"
  trap 'rm -rf "$lock"' EXIT
  st=$STATUS_DIR/status
  GATEWAY=$(status_field gateway "$st")
  ROOM=$(status_field room "$st")
  FILE_ID=$(status_field file "$st")
  SRC=$(status_field path "$st")
  PROJ=$(status_field project "$st")
  SIZE=$(status_field size "$st")
  PART=$(status_field part "$st")
  IDENT=$(status_field ident "$st")
  set_status "$STATUS_DIR" pid "$$"
  WORK=$STATUS_DIR
  if send_pieces && share "$STATUS_DIR/say.json"; then
    set_status "$STATUS_DIR" state sent
    rm -f "$STATUS_DIR/piece" "$STATUS_DIR/say.json"
    exit 0
  fi
  set_status "$STATUS_DIR" reason "$(printf '%s' "$REASON" | tr -d '\r\n' | cut -c 1-300)"
  set_status "$STATUS_DIR" state failed
  rm -f "$STATUS_DIR/piece"
  exit 1
fi

# ---- send and fetch: the checks they share ----
case $MODE in send | fetch) ;; *) failed "usage: snapwork-files.sh send|fetch|news|run" ;; esac
valid_gateway "$GATEWAY" || failed "the gateway must be https"
GATEWAY=${GATEWAY%/}
valid_room "$ROOM" || failed "no valid room id"
[ -z "$AGENT" ] || valid_agent "$AGENT" || failed "the agent id must be a UUID"
[ -n "$PROJECT" ] && [ -d "$PROJECT" ] || failed "no project folder"
PROJ=$(cd "$PROJECT" 2> /dev/null && pwd -P) || failed "cannot open the project folder"
case $PROJ in *"$NL"*) failed "the project folder's path has a line break: move the project first" ;; esac
REAL_HOME=
[ -z "${HOME:-}" ] || REAL_HOME=$(cd "$HOME" 2> /dev/null && pwd -P) || REAL_HOME=
# Not the home folder, not a folder that holds it, not the whole disk.
if [ "$MODE" = send ]; then
  case $REAL_HOME/ in "$PROJ"/* | /) failed "Sending works from a project folder, not your home folder. Copy the file into the project." ;; esac
  [ "$PROJ" != / ] || failed "Sending works from a project folder, not your home folder. Copy the file into the project."
fi
[ "$PROJ" != / ] || failed "the project folder cannot be the whole disk: run this from your project folder"
read_key
WORK=$(mktemp -d 2> /dev/null) || failed "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

# ---- send ----
if [ "$MODE" = send ]; then
  [ -n "$FILE_ARG" ] || failed "name the file with --file <path>"
  case $FILE_ARG in *"$NL"*) failed "the file name has a line break: rename it first" ;; esac
  case $FILE_ARG in /*) path=$FILE_ARG ;; *) path=$(pwd -P)/$FILE_ARG ;; esac
  [ -L "$path" ] && failed "$(shown "$FILE_ARG") is a link: send the file itself (copy it into the project folder first)"
  [ -e "$path" ] || failed "there is no file $(shown "$FILE_ARG")"
  [ -f "$path" ] || failed "$(shown "$FILE_ARG") is not a regular file (folders cannot be sent: zip it first)"
  [ -r "$path" ] || failed "cannot read $(shown "$FILE_ARG")"
  dir=$(cd "$(dirname "$path")" 2> /dev/null && pwd -P) || failed "cannot open the folder of $(shown "$FILE_ARG")"
  base=$(basename "$path")
  SRC=$dir/$base
  case $SRC in *"$NL"*) failed "the file's path has a line break: rename it first" ;; esac
  case $SRC in
    "$PROJ"/*) ;;
    *) failed "only files inside your project folder ($(shown "$PROJ" 200)) can be sent: copy it into the project folder first" ;;
  esac
  why=$(secret_reason "$SRC") && failed "$why"
  IDENT=$(file_ident "$SRC")
  [ -n "$IDENT" ] || failed "cannot read the size of the file"
  links=$(printf '%s' "$IDENT" | cut -d : -f 3)
  [ "$links" = 1 ] || failed "$(shown "$base") has more than one name on disk (a hard link): copy it into the project folder first"
  SIZE=$(printf '%s' "$IDENT" | cut -d : -f 4)
  case $SIZE in '' | *[!0-9]*) failed "cannot read the size of the file" ;; esac
  case $(printf '%s' "$base" | tr 'A-Z' 'a-z') in
    *.pdf) type=application/pdf ;;
    *.png) type=image/png ;;
    *.jpg | *.jpeg) type=image/jpeg ;;
    *.gif) type=image/gif ;;
    *.webp) type=image/webp ;;
    *.mp4) type=video/mp4 ;;
    *.mov) type=video/quicktime ;;
    *.webm) type=video/webm ;;
    *.txt | *.log) type=text/plain ;;
    *.md) type=text/markdown ;;
    *.csv) type=text/csv ;;
    *.json) type=application/json ;;
    *.zip) type=application/zip ;;
    *) type=application/octet-stream ;;
  esac
  b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
  code=$(api -o "$WORK/start" -X POST -H "$TUS" -H "Upload-Length: $SIZE" \
    -H "Upload-Metadata: filename $(b64 "$base"),filetype $(b64 "$type")" "$GATEWAY/rooms/$ROOM/uploads")
  if [ "$code" != 201 ]; then
    why=$(reason_of "$WORK/start")
    case $code in 000) failed "could not reach the gateway" ;; esac
    failed "${why:-the gateway answered HTTP $code}"
  fi
  start=$(LC_ALL=C tr -d '\r\n ' < "$WORK/start")
  FILE_ID=$(printf '%s' "$start" | sed -n 's/.*"file_id":"\([a-z0-9-]*\)".*/\1/p')
  PART=$(printf '%s' "$start" | sed -n 's/.*"part_size":\([0-9][0-9]*\).*/\1/p')
  valid_file_id "$FILE_ID" || failed "the gateway gave no file id"
  case $PART in '' | 0 | *[!0-9]*) failed "the gateway gave no part size" ;; esac
  [ "${#PART}" -le 9 ] && [ "$PART" -le "$PART_MAX" ] || failed "the gateway asked for pieces over 50 MiB"
  {
    printf '{"file_id":"%s","client_id":"f-%s","text":"' "$FILE_ID" "$FILE_ID"
    if [ -n "$NOTE_JSON" ]; then cat "$NOTE_JSON"; else json_text "$NOTE"; fi
    printf '"}'
  } > "$WORK/say.json"
  name=$(shown "$base")
  if [ "$SIZE" -le "$FOREGROUND_MAX" ]; then
    send_pieces || failed "$REASON"
    share "$WORK/say.json" || failed "$REASON"
    say_line sent
    exit 0
  fi
  # Bigger: in the background, in its own session, so the agent's command limit and its terminal
  # closing cannot stop it. Only the job writes its pid and progress.
  STATUS_DIR=$UPLOADS_DIR/$FILE_ID
  (umask 077 && mkdir -p "$STATUS_DIR") || failed "cannot write $UPLOADS_DIR"
  find "$UPLOADS_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} + 2> /dev/null
  cp "$WORK/say.json" "$STATUS_DIR/say.json" && chmod 600 "$STATUS_DIR/say.json"
  # The job runs from its own copy of this (already checked) script: the caller may remove its copy.
  cp "$SELF" "$STATUS_DIR/files.sh" && chmod 500 "$STATUS_DIR/files.sh" || failed "cannot write $UPLOADS_DIR"
  write_status "$STATUS_DIR" "gateway=$GATEWAY" "room=$ROOM" "agent=$AGENT" "file=$FILE_ID" \
    "name=$name" "path=$SRC" "project=$PROJ" "ident=$IDENT" "size=$SIZE" "part=$PART" "offset=0" \
    "state=uploading" "reported=0" "pid=" || failed "cannot write $UPLOADS_DIR"
  if command -v setsid > /dev/null 2>&1; then
    printf '%s\n' "$KEY" | setsid sh "$STATUS_DIR/files.sh" run "$STATUS_DIR" > "$STATUS_DIR/log" 2>&1 &
  elif command -v perl > /dev/null 2>&1; then
    printf '%s\n' "$KEY" | perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' sh "$STATUS_DIR/files.sh" run "$STATUS_DIR" > "$STATUS_DIR/log" 2>&1 &
  else
    printf '%s\n' "$KEY" | (trap '' HUP && exec sh "$STATUS_DIR/files.sh" run "$STATUS_DIR") > "$STATUS_DIR/log" 2>&1 &
  fi
  say_line "uploading $name, $(human_size "$SIZE"), in the background; the room sees it when it is done"
  exit 0
fi

# ---- fetch ----
umask 077
valid_file_id "$ID_ARG" || failed "a file id looks like kq3-mzqt-wpxh"
FILE_ID=$ID_ARG
space=$(printf '%s' "$SPACE" | LC_ALL=C tr -cd 'A-Za-z0-9 _-' | tr ' ' '-' | cut -c 1-40)
[ -n "$space" ] || space=$(printf '%s' "$ROOM" | cut -c 1-8)
top=$PROJ/snapwork-files
[ -L "$top" ] && failed "snapwork-files in your project folder is a link: remove it first"
dest=$top/$space
[ -L "$dest" ] && failed "snapwork-files/$space is a link: remove it first"
mkdir -p "$dest" 2> /dev/null || failed "cannot make snapwork-files/$space in your project folder"
url=$GATEWAY/rooms/$ROOM/files/$FILE_ID/content
code=$(api -o /dev/null -D "$WORK/h" -I "$url")
case $code in
  200) ;;
  000) failed "could not reach the gateway" ;;
  404) failed "there is no file $FILE_ID in this room (wrong id, or it was removed)" ;;
  *) failed "the gateway answered HTTP $code" ;;
esac
# The last value of one response header, its name in any case.
header() {
  tr -d '\r' < "$2" | awk -v k="$1" '{
    i = index($0, ":")
    if (i > 0 && tolower(substr($0, 1, i - 1)) == k) { v = substr($0, i + 1); sub(/^[ \t]+/, "", v); last = v }
  } END { print last }'
}
size=$(header content-length "$WORK/h" | tr -cd '0-9')
etag=$(header etag "$WORK/h" | tr -d '"' | LC_ALL=C tr -cd 'a-f0-9')
[ -n "$size" ] || failed "the gateway gave no size"
[ "${#etag}" -eq 64 ] || failed "the gateway gave no sha256 for this file"
raw=$(header content-disposition "$WORK/h" | sed -n 's/.*filename="\([^"]*\)".*/\1/p')
name=$(printf '%s' "$raw" | LC_ALL=C tr -c 'A-Za-z0-9._()+,=@ -' '_' | sed 's/^[. ]*//' | cut -c 1-150)
case $name in '' | *[!_]*) ;; *) name= ;; esac
[ -n "$name" ] || name=$FILE_ID
part=$dest/.$FILE_ID.part
# Version 2 downloaded into this side file first, so a killed run left its bytes there: from 0 when
# there was no .part, else the bytes right after it. They are folded into the .part, once.
dl=$dest/.$FILE_ID.dl
[ ! -L "$part" ] || rm -f "$part"
[ ! -L "$dl" ] || rm -f "$dl"
if [ -f "$dl" ]; then
  if [ -f "$part" ]; then cat "$dl" >> "$part" || failed "cannot write the download"
  else mv -f "$dl" "$part" || failed "cannot write the download"
  fi
  rm -f "$dl"
fi
have=0
[ -f "$part" ] && have=$(wc -c < "$part" | tr -d ' ')
if [ "$have" -gt "$size" ]; then rm -f "$part"; have=0; fi
free_kb=$(df -Pk "$dest" 2> /dev/null | awk 'NR == 2 { print $4 }')
case $free_kb in
  '' | *[!0-9]*) ;;
  *)
    need_kb=$(((size - have) / 1024 + 1 + FREE_MARGIN_KB))
    [ "$free_kb" -ge "$need_kb" ] || failed "not enough free space: the file needs $(human_size $((size - have))) and 1 GB is kept free, but the disk has $(human_size $((free_kb * 1024))) free"
    ;;
esac
# Straight into the .part, so whatever arrives stays even when the run is killed. A resume asks
# for the rest (Range from the .part's size, If-Range on the sha256) and appends; --fail keeps an
# error reply's body out of the file. Prints the HTTP status.
get_into_part() {
  if [ "$have" -gt 0 ]; then
    api --fail -C "$have" -o "$part" -D "$WORK/g" -H "If-Range: \"$etag\"" "$url"
  else
    api --fail -o "$part" -D "$WORK/g" "$url"
  fi
}
if [ "$have" -lt "$size" ]; then
  code=$(get_into_part)
  if [ "$code" = 200 ] && [ "$have" -gt 0 ]; then
    # The whole file instead of the rest (no ranges, or the file changed): start again from 0.
    rm -f "$part"
    have=0
    code=$(get_into_part)
  fi
  case $code in
    206)
      start=$(header content-range "$WORK/g" | sed -n 's/^bytes \([0-9][0-9]*\)-.*/\1/p')
      if [ "$start" != "$have" ]; then rm -f "$part"; failed "the gateway answered from another place in the file: run the same command again"; fi
      ;;
    200 | 000) ;;
    404) failed "there is no file $FILE_ID in this room (wrong id, or it was removed)" ;;
    *) failed "the gateway answered HTTP $code" ;;
  esac
fi
[ -f "$part" ] || : > "$part"
have=$(wc -c < "$part" | tr -d ' ')
[ "$have" -ge "$size" ] || failed "the download was cut: run the same command again to go on from where it stopped"
got=$(sha_of "$part") || failed "need sha256sum or shasum to check the file"
if [ "$got" != "$etag" ]; then
  rm -f "$part"
  failed "the sha256 did not match, so the download was removed: run the same command again"
fi
stem=$name
ext=
case $name in ?*.*) stem=${name%.*}; ext=.${name##*.} ;; esac
final=$dest/$name
n=2
# A hard link never replaces a file that is already there: a clash tries the next name.
until ln "$part" "$final" 2> /dev/null; do
  [ -e "$final" ] || [ -L "$final" ] || failed "cannot save the file in snapwork-files/$space"
  [ "$n" -le 99 ] || failed "too many files named $name in snapwork-files/$space"
  final="$dest/$stem ($n)$ext"
  n=$((n + 1))
done
rm -f "$part"
printf 'saved to snapwork-files/%s/%s (%s), sha256 ok\n' "$space" "${final##*/}" "$(human_size "$size")"
