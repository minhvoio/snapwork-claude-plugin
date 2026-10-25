# snapwork-update.sh: sourced by snapwork-plugin.sh (not run by itself). Keeping snapwork up to date
# in Claude.
#
# Claude (Claude Code and Claude Desktop's Code tab share one plugin system and one ~/.claude) does
# not auto-update a third-party marketplace unless its entry says "autoUpdate": true. So, once per
# computer, the first time a Claude chat joins or comes back to a space (or, for a chat already in
# one, at its next SessionStart), this turns on Claude's own background auto-update for the
# "snapwork" marketplace and tells the person. Codex updates itself when the app starts: never there.
# Never for connections made by the one-line setup.
#
# What is changed: only "autoUpdate": true is added to the snapwork entry, in the user settings file
# (extraKnownMarketplaces.snapwork in $CLAUDE_CONFIG_DIR/settings.json, else ~/.claude/settings.json)
# when it has that entry, else in known_marketplaces.json (under $CLAUDE_CODE_PLUGIN_CACHE_DIR, else
# ~/.claude/plugins). Whether a marketplace auto-updates follows the first of those that says so.
# An entry that already says "autoUpdate" (true or false, in either file) is the person's choice and
# is left alone. Nothing is created; no other key is touched; managed settings are never touched (a
# managed autoUpdate wins anyway). A symlinked file or folder, JSON that does not parse, or a
# file that changed while it was read leaves everything as it was. Before writing, the file is kept
# as <file>.snapwork-bak (mode 600); the new text goes to a temp file in the same folder, is read
# back and must equal the old content plus that one key, keeps the file's mode, then replaces it.
#
# $SNAPWORK_HOME/auto-update records that it was done (or left alone for a choice); after that
# nothing is tried again, so a person who later turns it off is never overridden. Any other outcome
# (no entry, no tool, a refusal) changes nothing and is tried again next time.
#
# Uses from snapwork-plugin.sh: APP, STATE, SNAPWORK_HOME, NL, WORK, work_dir, plog, made_by_setup.

AUTO_MARK=$SNAPWORK_HOME/auto-update
AUTO_NOTE=

# auto_update_say: turn it on if this is the first time, and add one line for the person when it
# changed something. Never fails the hook.
auto_update_say() {
  auto_update
  [ -z "$AUTO_NOTE" ] || printf '%s\n' "$AUTO_NOTE"
  return 0
}

# A python3 that will run. On macOS /usr/bin/python3 is a stub that opens an "install developer
# tools" window when the tools are missing: a hook must never do that.
python_ok() {
  command -v python3 > /dev/null 2>&1 || return 1
  [ "$(uname -s 2> /dev/null)" = Darwin ] || return 0
  [ "$(command -v python3)" != /usr/bin/python3 ] && return 0
  xcode-select -p > /dev/null 2>&1
}

auto_update() {
  AUTO_NOTE=
  [ "$APP" = claude ] || return 0
  { [ -n "$STATE" ] && ! made_by_setup "$STATE"; } || return 0
  [ -d "$SNAPWORK_HOME" ] || return 0
  if [ -e "$AUTO_MARK" ] || [ -L "$AUTO_MARK" ]; then
    plog "auto-update-skip why=done-before"
    return 0
  fi
  # Claude's whole background update pass is off: turning it on here would change nothing.
  if [ -z "${FORCE_AUTOUPDATE_PLUGINS:-}" ] \
    && [ -n "${DISABLE_UPDATES:-}${DISABLE_AUTOUPDATER:-}${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-}" ]; then
    plog "auto-update-skip why=updates-off"
    return 0
  fi
  conf=${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}
  plugins=${CLAUDE_CODE_PLUGIN_CACHE_DIR:-$conf/plugins}
  case $conf in /?*) ;; *) plog "auto-update-skip why=no-entry"; return 0 ;; esac
  case $plugins in /?*) ;; *) plog "auto-update-skip why=no-entry"; return 0 ;; esac
  case $conf$plugins in *"$NL"*) plog "auto-update-skip why=no-entry"; return 0 ;; esac
  settings=$conf/settings.json
  known=$plugins/known_marketplaces.json
  # Neither (regular) file names snapwork: nothing to do, without starting a tool.
  found=0
  for f in "$settings" "$known"; do
    if [ -f "$f" ] && grep -q -F '"snapwork"' "$f" 2> /dev/null; then found=1; fi
  done
  [ "$found" -eq 1 ] || { plog "auto-update-skip why=no-entry"; return 0; }
  tool=
  if python_ok; then tool=python3
  elif command -v node > /dev/null 2>&1; then tool=node
  elif command -v bun > /dev/null 2>&1; then tool=bun
  fi
  [ -n "$tool" ] || { plog "auto-update-skip why=no-tool"; return 0; }
  work_dir || { plog "auto-update-skip why=write-failed"; return 0; }
  # The programs are fixed text; the two paths reach them as arguments only.
  if [ "$tool" = python3 ]; then
    auto_update_py > "$WORK/auto-update.py" || { plog "auto-update-skip why=write-failed"; return 0; }
    res=$(cd "$WORK" && python3 -I "$WORK/auto-update.py" "$settings" "$known" 2> /dev/null)
  else
    auto_update_js > "$WORK/auto-update.js" || { plog "auto-update-skip why=write-failed"; return 0; }
    res=$(cd "$WORK" && "$tool" "$WORK/auto-update.js" "$settings" "$known" 2> /dev/null)
  fi
  case $res in
    'on settings' | 'on known')
      auto_mark "$res"
      plog "auto-update-on file=${res#on } tool=$tool"
      if [ "$res" = 'on settings' ]; then where=$settings; else where=$known; fi
      case $where in "${HOME:-/nonexistent}"/*) where="~${where#"$HOME"}" ;; esac
      where=$(printf '%s' "$where" | tr -d '[:cntrl:]')
      AUTO_NOTE="SnapWork also turned on automatic updates for the snapwork plugin in Claude (once), so new versions of snapwork arrive by themselves and load the next time Claude starts. To turn this off: /plugin, then Marketplaces, then snapwork in Claude Code, or set \"autoUpdate\": false on the snapwork entry in $where. Tell the person this too, in one more line." ;;
    explicit)
      auto_mark explicit
      plog "auto-update-skip why=explicit" ;;
    no-entry | symlink | bad-json | write-failed)
      plog "auto-update-skip why=$res tool=$tool" ;;
    *)
      plog "auto-update-skip why=write-failed tool=$tool" ;;
  esac
  return 0
}

# auto_mark <what>: done once on this computer (mode 600, never through a symlink).
auto_mark() {
  (
    umask 077
    [ ! -L "$AUTO_MARK" ] || exit 0
    printf '%s %s\n' "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$AUTO_MARK.$$" && chmod 600 "$AUTO_MARK.$$" \
      && mv "$AUTO_MARK.$$" "$AUTO_MARK"
  ) 2> /dev/null || rm -f "$AUTO_MARK.$$"
}

# Prints one word line: "on settings", "on known", explicit, no-entry, symlink, bad-json, write-failed.
auto_update_py() {
  cat << 'PYEOF'
import copy, json, os, stat, sys, tempfile
NAME = "snapwork"
settings_path, known_path = sys.argv[1:3]
def say(word):
    print(word)
    sys.exit(0)
def load(path):
    # (state, data, raw, mode, linked); a file is read through a link, never written through one.
    try:
        linked = os.path.islink(path) or os.path.islink(os.path.dirname(path))
        st = os.stat(path)
    except FileNotFoundError:
        return "missing", None, None, None, False
    except OSError:
        return "bad", None, None, None, False
    if not stat.S_ISREG(st.st_mode):
        return "bad", None, None, None, False
    try:
        with open(path, "rb") as f:
            raw = f.read()
        data = json.loads(raw.decode("utf-8"))
    except (OSError, ValueError):
        return "bad", None, None, None, False
    if not isinstance(data, dict):
        return "bad", None, None, None, False
    return "ok", data, raw, stat.S_IMODE(st.st_mode), linked
def entry(data, where):
    if data is None:
        return None
    m = data.get("extraKnownMarketplaces") if where == "settings" else data
    e = m.get(NAME) if isinstance(m, dict) else None
    return e if isinstance(e, dict) else None
s = load(settings_path)
k = load(known_path)
if s[0] == "bad" or k[0] == "bad":
    say("bad-json")
se, ke = entry(s[1], "settings"), entry(k[1], "known")
if (se is not None and "autoUpdate" in se) or (ke is not None and "autoUpdate" in ke):
    say("explicit")
if se is not None:
    where, path, (state, data, raw, mode, linked) = "settings", settings_path, s
elif ke is not None:
    where, path, (state, data, raw, mode, linked) = "known", known_path, k
else:
    say("no-entry")
if linked:
    say("symlink")
folder = os.path.dirname(path)
expected = copy.deepcopy(data)
entry(expected, where)["autoUpdate"] = True
tmps = []
try:
    fd, tmp = tempfile.mkstemp(dir=folder, prefix=".snapwork-bak.")
    tmps.append(tmp)
    with os.fdopen(fd, "wb") as f:
        f.write(raw)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path + ".snapwork-bak")
    tmps.remove(tmp)
    fd, tmp = tempfile.mkstemp(dir=folder, prefix=".snapwork.")
    tmps.append(tmp)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(json.dumps(expected, indent=2, ensure_ascii=False) + "\n")
    os.chmod(tmp, mode)
    with open(tmp, "rb") as f:
        back = json.loads(f.read().decode("utf-8"))
    without = copy.deepcopy(back)
    if back != expected or entry(without, where).pop("autoUpdate", None) is not True or without != data:
        raise ValueError("check failed")
    if os.path.islink(path) or os.path.islink(folder):
        raise ValueError("became a link")
    with open(path, "rb") as f:
        if f.read() != raw:
            raise ValueError("changed meanwhile")
    os.replace(tmp, path)
    tmps.remove(tmp)
except (OSError, ValueError):
    for t in tmps:
        try:
            os.unlink(t)
        except OSError:
            pass
    say("write-failed")
say("on " + where)
PYEOF
}

auto_update_js() {
  cat << 'JSEOF'
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { isDeepStrictEqual } = require("util");
const NAME = "snapwork";
const [settingsPath, knownPath] = process.argv.slice(2);
const say = (word) => {
  process.stdout.write(`${word}\n`);
  process.exit(0);
};
const isLink = (p) => {
  try {
    return fs.lstatSync(p).isSymbolicLink();
  } catch {
    return false;
  }
};
const load = (p) => {
  const linked = isLink(p) || isLink(path.dirname(p));
  let st;
  try {
    st = fs.statSync(p);
  } catch (e) {
    return { state: e && e.code === "ENOENT" ? "missing" : "bad" };
  }
  if (!st.isFile()) return { state: "bad" };
  let raw;
  let data;
  try {
    raw = fs.readFileSync(p);
    const text = raw.toString("utf8");
    // A number this long would lose digits in JavaScript: leave such a file alone.
    if (/[0-9]{16,}/.test(text)) return { state: "bad" };
    data = JSON.parse(text);
  } catch {
    return { state: "bad" };
  }
  if (!data || typeof data !== "object" || Array.isArray(data)) return { state: "bad" };
  return { state: "ok", data, raw, mode: st.mode & 0o7777, linked };
};
const entry = (data, where) => {
  if (!data) return null;
  const m = where === "settings" ? data.extraKnownMarketplaces : data;
  const e = m && typeof m === "object" && !Array.isArray(m) ? m[NAME] : null;
  return e && typeof e === "object" && !Array.isArray(e) ? e : null;
};
const s = load(settingsPath);
const k = load(knownPath);
if (s.state === "bad" || k.state === "bad") say("bad-json");
const se = entry(s.data, "settings");
const ke = entry(k.data, "known");
if ((se && "autoUpdate" in se) || (ke && "autoUpdate" in ke)) say("explicit");
let where;
let file;
let f;
if (se) [where, file, f] = ["settings", settingsPath, s];
else if (ke) [where, file, f] = ["known", knownPath, k];
else say("no-entry");
if (f.linked) say("symlink");
const folder = path.dirname(file);
const expected = JSON.parse(JSON.stringify(f.data));
entry(expected, where).autoUpdate = true;
const tmps = [];
const tmpName = (prefix) => path.join(folder, `${prefix}${crypto.randomBytes(8).toString("hex")}`);
try {
  let tmp = tmpName(".snapwork-bak.");
  tmps.push(tmp);
  fs.writeFileSync(tmp, f.raw, { mode: 0o600, flag: "wx" });
  fs.chmodSync(tmp, 0o600);
  fs.renameSync(tmp, `${file}.snapwork-bak`);
  tmps.pop();
  tmp = tmpName(".snapwork.");
  tmps.push(tmp);
  fs.writeFileSync(tmp, `${JSON.stringify(expected, null, 2)}\n`, { mode: 0o600, flag: "wx" });
  fs.chmodSync(tmp, f.mode);
  const back = JSON.parse(fs.readFileSync(tmp, "utf8"));
  const without = JSON.parse(JSON.stringify(back));
  const e = entry(without, where);
  const added = e ? e.autoUpdate : undefined;
  if (e) delete e.autoUpdate;
  if (!isDeepStrictEqual(back, expected) || added !== true || !isDeepStrictEqual(without, f.data)) throw new Error("check failed");
  if (isLink(file) || isLink(folder)) throw new Error("became a link");
  if (!fs.readFileSync(file).equals(f.raw)) throw new Error("changed meanwhile");
  fs.renameSync(tmp, file);
  tmps.pop();
} catch {
  for (const t of tmps) {
    try {
      fs.unlinkSync(t);
    } catch {}
  }
  say("write-failed");
}
say(`on ${where}`);
JSEOF
}
