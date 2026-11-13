#!/usr/bin/env python3
"""hwrm-replays companion: makes Homeworld Remastered recordings (-enablerecord) playable and browsable.

For every profile (Bin/Profiles/Profile*/playback):
  - each game is saved as a new, repaired recording named after the time it was recorded: '<YYYY-MM-DD HH-MM-SS> P<slot>.rec'.
    The source is the mod's snapshot (playback/recGame-<slot>-<frame>-snapshot.rec, written by SaveRecordedGame() when the game
    ends; the latest one per game), or, for a game without a snapshot, the game's own playback/temp/recGame-<slot>-temp.rec
    (kept only until the next game). Recordings of one game are matched by their header's game settings. Used snapshots move to
    playback/originals/;
  - each recording saved by name in the game (post-game Save Recorded) is repaired in place (the original is kept in
    playback/originals/).
Repaired recordings show in the game's own Load Recorded Game list (Player vs CPU screen, with -enablerecord) under their file name.

The repairs (why the game can't play its own recordings in a later session):
  - header strings of 16+ characters are stored as pointers into the recording session's memory: rewritten inline (the field seen so
    far is the rules' Race_Paths, e.g. 'Deathmatch,Extras' -> 'Deathmatch');
  - multiplayer games are recorded in network mode (2), which playback can't run: set to local (1);
  - leftover web data is blanked: the header is copied raw from memory, so unused buffer space can hold whatever the game's online
    services (bifrost) last put there, once a session cookie; any header text with web markers (path=, HttpOnly, cookie, ...) or a
    long token-like run is zeroed (the game reads text fields only up to their terminator, so this never changes playback);
  - a save-style name trailer is added (the list only shows files with one, and plays '<name>.rec'), with the header's body size
    set to 'unknown' (-1) so the loader accepts the extra bytes (playback stops at the recorded end frame).

Usage: replaywatch.py [--profiles <Bin/Profiles folder>] [--watch [seconds]] [--dry] [--run <game command...>]
  --profiles: the game's Bin/Profiles folder. By default it's found through Steam's library list (Windows and Linux), or the
              HWRM_PROFILES environment variable.
  --watch: keep running and check every few seconds (default 5) - leave it running while you play.
  --dry: only report what would change.
  --run: start the game with the rest of the command line, check every few seconds while it runs, then once more after it exits.
         For Steam's launch options: `python3 /path/to/replaywatch.py --run %command% -enablerecord` (the game always starts,
         even if this tool fails).
Windows without Python: tools/replaywatch.bat (the same tool in PowerShell).
"""
import hashlib
import json
import os
import re
import struct
import sys
import time


# ---------------------------------------------------------------------------------------------------------------------------------
# Recording file layout
#
# A recording is a 0x720-byte header followed by the recorded commands. The header starts with:
#   +0x0   file signature 09 28 2f 03 (identifies a recording)
#   +0x4   body size (int32; -1 while the game is still recording)
#   +0x8   the recording player's slot
#   +0xc   end frame
#   +0x18  the game settings, copied raw from the game's memory (up to the end of the header)
# ---------------------------------------------------------------------------------------------------------------------------------

HEADER = 0x720
FILE_SIGNATURE = bytes.fromhex('09282f03')
BODY_SIZE = 0x4
SLOT = 0x8
END_FRAME = 0xc
SETTINGS = 0x18

STRING_FIELDS = (0x658, 0x670)  # the settings' text fields: rules tag ('DEATHMATCH'), Race_Paths ('Deathmatch,Extras')
MODE_OFFSET = 0x68c             # game mode: 0 campaign, 1 local/skirmish, 2 network

# The name trailer: the game's list reads it from the end of the file (as in its own saves) and plays '<name>.rec'.
TRAILER_SIZE = 0x214                                         # 532 bytes
TRAILER_PREFIX = bytes.fromhex('53464e4d00454e532f010200')  # 'SFNM\0ENS' + version-like bytes
NAME_CHARS = 39                                              # the UTF-16 name area; names are kept well inside it

STATE_FILE = '.hwrm-replays.json'  # per game (settings hash): the output name, its source kind and end frame

WEB_MARKERS = re.compile(rb'(?i)path=|httponly|set-cookie|cookie|domain=|expires=|samesite|max-age|secure;')
TOKEN_RUN = re.compile(rb'^[A-Za-z0-9%+/=_\-]{48,}$')


# ---------------------------------------------------------------------------------------------------------------------------------
# Reading and repairing a recording
# ---------------------------------------------------------------------------------------------------------------------------------

def int32(b, offset):
    """The signed 32-bit number at offset."""
    return struct.unpack('<i', b[offset:offset + 4])[0]


def uint32(b, offset):
    """The unsigned 32-bit number at offset."""
    return struct.unpack('<I', b[offset:offset + 4])[0]


def is_recording(b):
    """True if b starts like a recording."""
    return len(b) >= HEADER and b[:4] == FILE_SIGNATURE


def has_trailer(b):
    """True if b already ends with a name trailer (ours, or the game's own Save Recorded)."""
    return len(b) >= HEADER + TRAILER_SIZE and b[-TRAILER_SIZE:-TRAILER_SIZE + 4] == b'SFNM'


def end_frame(b):
    return int32(b, END_FRAME)


def scrub(b, notes):
    """Blanks leftover web data in the header of b (a bytearray, changed in place). Returns how many text runs were blanked."""
    n = 0
    for m in re.finditer(rb'[ -~]{8,}', bytes(b[SETTINGS:HEADER])):
        run = m.group()
        if WEB_MARKERS.search(run) or TOKEN_RUN.match(run):
            start, end = SETTINGS + m.start(), SETTINGS + m.end()
            b[start:end] = bytes(end - start)
            n += 1
    if n:
        notes.append(f'blanked {n} leftover web-data text run(s)')
    return n


def repair(b, notes):
    """Returns a repaired copy of the recording (no trailer yet), or None if it isn't a finished recording."""
    if not is_recording(b):
        notes.append('not a recording')
        return None
    if int32(b, BODY_SIZE) == -1 and not has_trailer(b):
        notes.append('still recording (size unknown)')
        return None

    b = bytearray(b)

    # Text fields of 16+ characters are pointers into the recording session's memory: write a short value inline instead.
    tag = bytes(b[0x658:0x668]).split(b'\0')[0].decode('latin-1', 'replace')
    inline = {'DEATHMATCH': b'Deathmatch', 'SINGLEPLAYER': b'SinglePlayer'}.get(tag, b'Deathmatch')
    for off in STRING_FIELDS:
        ptr = uint32(b, off)
        size, cap = uint32(b, off + 16), uint32(b, off + 20)
        if 16 <= cap < 0x1000 and 16 <= size <= cap and 0x10000 < ptr < 0x80000000:
            b[off:off + 16] = inline + bytes(16 - len(inline))
            b[off + 16:off + 24] = struct.pack('<II', len(inline), 15)
            notes.append(f'string at 0x{off:x} ({size} chars) -> {inline.decode()!r}')

    # Multiplayer games are recorded in network mode, which playback can't run.
    if uint32(b, MODE_OFFSET) == 2:
        b[MODE_OFFSET:MODE_OFFSET + 4] = struct.pack('<I', 1)
        notes.append('network mode -> local')

    scrub(b, notes)

    # Body size 'unknown', so the game accepts the trailer that follows the commands.
    b[BODY_SIZE:BODY_SIZE + 4] = struct.pack('<i', -1)
    return bytes(b)


def trailer(name):
    """The name trailer for a recording called name."""
    t = bytearray(TRAILER_SIZE)
    t[:12] = TRAILER_PREFIX
    w = name[:NAME_CHARS].encode('utf-16-le') + b'\0\0'
    t[12:12 + len(w)] = w
    return bytes(t)


def game_id(b):
    """Identifies a game: a hash of its settings (incl. its random seed) as repaired, the same for its snapshots, temp recording and
    our output."""
    fixed = repair(b, [])
    return hashlib.sha1(bytes((fixed or b)[SETTINGS:HEADER])).hexdigest()


# ---------------------------------------------------------------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------------------------------------------------------------

def read(path):
    """The file's bytes, or None if it can't be read (e.g. the game is writing it)."""
    try:
        with open(path, 'rb') as f:
            return f.read()
    except OSError:
        return None


def safe_name(s):
    """s as a file name the game's list can show."""
    return re.sub(r'[^A-Za-z0-9 _\-]', '-', s)[:NAME_CHARS].strip() or 'replay'


def unique(folder, name):
    """name, or 'name (2)', 'name (3)', ... if a recording of that name already exists."""
    out, n = name, 2
    while os.path.exists(os.path.join(folder, out + '.rec')):
        out = f'{name} ({n})'[:NAME_CHARS]
        n += 1
    return out


def write_output(playback, name, fixed, dry):
    """Writes the repaired recording, with its name trailer, as playback/<name>.rec."""
    if not dry:
        with open(os.path.join(playback, name + '.rec'), 'wb') as f:
            f.write(fixed + trailer(name))


def to_originals(path, originals, dry):
    """Moves a used source file into playback/originals/."""
    if not dry:
        os.makedirs(originals, exist_ok=True)
        os.replace(path, os.path.join(originals, os.path.basename(path)))


# ---------------------------------------------------------------------------------------------------------------------------------
# One profile's playback folder
# ---------------------------------------------------------------------------------------------------------------------------------

def existing_games(playback):
    """Recordings already in the list (with a trailer), by game id: (name, end frame)."""
    existing = {}
    for f in os.listdir(playback):
        if not f.lower().endswith('.rec'):
            continue
        eb = read(os.path.join(playback, f))
        if eb and has_trailer(eb) and is_recording(eb):
            eb = bytearray(eb)
            scrub(eb, [])                                   # hashed as scrubbed, like repair() output
            existing[hashlib.sha1(bytes(eb[SETTINGS:HEADER])).hexdigest()] = (os.path.splitext(f)[0], end_frame(eb))
    return existing


def scan(playback, temp, dry):
    """Sorts the recordings into games (snapshots and finished temp recordings, by game id) and recordings saved by name.
    Recordings that already have a trailer are only scrubbed of leftover web data."""
    files = [os.path.join(playback, f) for f in os.listdir(playback) if f.lower().endswith('.rec')]
    if os.path.isdir(temp):
        files += [os.path.join(temp, f) for f in os.listdir(temp) if f.lower().endswith('.rec')]

    candidates = {}                                         # game id -> [(kind, end frame, path, bytes)]
    named = []                                              # [(path, name, bytes)]
    for src in sorted(files):
        b = read(src)
        if not b or not is_recording(b):
            continue

        if has_trailer(b):                                  # already done (ours, or a game save)
            bb, notes = bytearray(b), []
            if scrub(bb, notes):
                print(f'{src}: ' + '; '.join(notes))
                if not dry:
                    with open(src, 'wb') as f:
                        f.write(bytes(bb))
            continue

        base = os.path.splitext(os.path.basename(src))[0]
        if os.path.dirname(src) == temp:
            if int32(b, BODY_SIZE) in (-1, 0):
                continue                                    # still recording, or empty (leaving through the menu empties it;
                                                            # the mod's snapshot has that game)
            candidates.setdefault(game_id(b), []).append(('temp', end_frame(b), src, b))
        elif re.match(r'recGame-\d+-\d+-snapshot$', base, re.I):
            candidates.setdefault(game_id(b), []).append(('snapshot', end_frame(b), src, b))
        else:
            named.append((src, base, b))
    return candidates, named


def save_games(playback, originals, candidates, existing, state, dry):
    """Saves each game from its best source (the latest snapshot, else the temp recording), replacing an earlier save of the same
    game if this source is better. Returns True if the state changed."""
    changed = False
    for gid, cands in candidates.items():
        snaps = [c for c in cands if c[0] == 'snapshot']
        kind, frame, src, b = max(snaps or cands, key=lambda c: c[1])

        prev = state.get(gid)
        if prev is None and gid in existing:                # saved before this state file existed: never let a temp override it
            prev = {'name': existing[gid][0], 'kind': 'snapshot', 'frame': existing[gid][1]}
            state[gid] = prev
            changed = True

        if prev:
            better = (kind == 'snapshot' and prev['kind'] == 'temp') or (kind == prev['kind'] and frame > prev['frame'])
            if not better:
                for _, _, s, _ in snaps:                    # tidy up snapshots already covered
                    to_originals(s, originals, dry)
                continue
            name = prev['name']                             # replace the earlier output, keep its name
        else:
            slot = uint32(b, SLOT)
            stamp = time.strftime('%Y-%m-%d %H-%M-%S', time.localtime(os.path.getmtime(src)))
            name = unique(playback, safe_name(f'{stamp} P{slot}'))

        notes = []
        fixed = repair(b, notes)
        if fixed is None:
            continue
        print(f'{src} -> {os.path.join(playback, name + ".rec")} ({kind}, frame {frame}): ' + '; '.join(notes))
        write_output(playback, name, fixed, dry)
        for _, _, s, _ in snaps:
            to_originals(s, originals, dry)
        state[gid] = {'name': name, 'kind': kind, 'frame': frame}
        changed = True
    return changed


def repair_named(playback, originals, named, dry):
    """Repairs recordings saved by name in the game, in place (the original goes to playback/originals/)."""
    for src, base, b in named:
        notes = []
        fixed = repair(b, notes)
        if fixed is None:
            print(f'skip {src}: {notes[0]}')
            continue
        name = base if safe_name(base) == base and len(base) <= NAME_CHARS else unique(playback, safe_name(base))
        print(f'{src} -> {os.path.join(playback, name + ".rec")} (named): ' + '; '.join(notes))
        to_originals(src, originals, dry)
        write_output(playback, name, fixed, dry)


def scrub_originals(originals, dry):
    """Backups in playback/originals/ are kept as recorded, apart from leftover web data."""
    if not os.path.isdir(originals):
        return
    for f in sorted(os.listdir(originals)):
        path = os.path.join(originals, f)
        ob = read(path)
        if not ob or not is_recording(ob):
            continue
        ob, notes = bytearray(ob), []
        if scrub(ob, notes):
            print(f'{path}: ' + '; '.join(notes))
            if not dry:
                with open(path, 'wb') as fh:
                    fh.write(bytes(ob))


def process_profile(playback, dry):
    """One pass over a profile's playback folder."""
    state_path = os.path.join(playback, STATE_FILE)
    state = {}
    if os.path.exists(state_path):
        with open(state_path) as f:
            state = json.load(f)
    temp = os.path.join(playback, 'temp')
    originals = os.path.join(playback, 'originals')

    existing = existing_games(playback)
    candidates, named = scan(playback, temp, dry)
    changed = save_games(playback, originals, candidates, existing, state, dry)
    repair_named(playback, originals, named, dry)
    scrub_originals(originals, dry)

    if changed and not dry:
        with open(state_path, 'w') as f:
            json.dump(state, f, indent=1)


# ---------------------------------------------------------------------------------------------------------------------------------
# Finding the game
# ---------------------------------------------------------------------------------------------------------------------------------

GAME_PROFILES = os.path.join('steamapps', 'common', 'Homeworld', 'HomeworldRM', 'Bin', 'Profiles')


def steam_libraries():
    """Steam library folders: the one this tool is in (if it is), then every library listed by the Steam installs found."""
    libs = []
    here = os.path.abspath(__file__).split(os.sep)
    for i in range(len(here) - 1, 0, -1):
        if here[i].lower() == 'steamapps':
            libs.append(os.sep.join(here[:i]) or os.sep)
            break

    roots = []
    if os.name == 'nt':
        try:
            import winreg
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r'Software\Valve\Steam') as k:
                roots.append(winreg.QueryValueEx(k, 'SteamPath')[0])
        except OSError:
            pass
        roots += [os.path.expandvars(r'%ProgramFiles(x86)%\Steam'), os.path.expandvars(r'%ProgramFiles%\Steam')]
    else:
        roots += [os.path.expanduser(p) for p in ('~/.local/share/Steam', '~/.steam/steam',
                                                  '~/.var/app/com.valvesoftware.Steam/.local/share/Steam')]

    for r in roots:
        libs.append(r)
        try:
            with open(os.path.join(r, 'steamapps', 'libraryfolders.vdf'), encoding='utf-8', errors='replace') as f:
                vdf = f.read()
        except OSError:
            continue
        libs += [p.replace('\\\\', '\\') for p in re.findall(r'"path"\s+"([^"]+)"', vdf)]
    return libs


def find_profiles():
    """The game's Bin/Profiles folder: HWRM_PROFILES, else the first Steam library that has the game. None if not found."""
    if os.environ.get('HWRM_PROFILES'):
        return os.environ['HWRM_PROFILES']
    for lib in steam_libraries():
        p = os.path.join(lib, GAME_PROFILES)
        if os.path.isdir(p):
            return p
    return None


# ---------------------------------------------------------------------------------------------------------------------------------

def process_all(root, dry):
    """One pass over every profile."""
    for p in sorted(os.listdir(root)):
        pb = os.path.join(root, p, 'playback')
        if p.lower().startswith('profile') and os.path.isdir(pb):
            process_profile(pb, dry)


def safe_pass(root, dry):
    """process_all(), reporting errors instead of stopping (the watch and run loops keep going: a file may be mid-write)."""
    try:
        process_all(root, dry)
    except Exception as e:                                  # noqa: BLE001 - keep watching whatever happens
        print(f'error: {e!r} (will retry)')


def game_running():
    """True while the game's process exists (Windows only: under Proton, Steam's command already waits for the game)."""
    if os.name != 'nt':
        return False
    import subprocess
    out = subprocess.run(['tasklist', '/FI', 'IMAGENAME eq HomeworldRM.exe', '/NH'], capture_output=True, text=True).stdout
    return 'homeworldrm.exe' in out.lower()


def run_game(command, root, dry, interval):
    """Starts the game, checks for replays every interval seconds while it runs, then once more. Returns the game's exit code.
    The game is started first, so a problem here (e.g. no profiles folder) never stops it."""
    import subprocess
    game = subprocess.Popen(command)
    if not root or not os.path.isdir(root):
        print('Homeworld Remastered\'s Bin/Profiles folder not found: replays won\'t be converted (use --profiles)')
        return game.wait()
    print(f'profiles: {root} (game running; checking every {interval} s)')
    while game.poll() is None or game_running():           # (a launcher can exit before the game does)
        safe_pass(root, dry)
        time.sleep(interval)
    safe_pass(root, dry)
    return game.returncode


def main():
    args = sys.argv[1:]

    command = None
    if '--run' in args:                                     # everything after --run is the game's command
        i = args.index('--run')
        command = args[i + 1:]
        del args[i:]
        if not command:
            sys.exit('--run needs the game command after it (in Steam: --run %command%)')

    root = None
    if '--profiles' in args:
        i = args.index('--profiles')
        root = args[i + 1]
        del args[i:i + 2]
    root = root or find_profiles()
    dry = '--dry' in args
    if command:
        interval = 5
        if '--watch' in args:
            i = args.index('--watch')
            if i + 1 < len(args) and args[i + 1].isdigit():
                interval = int(args[i + 1])
        sys.exit(run_game(command, root, dry, interval))
    if not root:
        sys.exit('Homeworld Remastered\'s Bin/Profiles folder not found: pass it with --profiles')

    interval = None
    if '--watch' in args:
        i = args.index('--watch')
        interval = 5
        if i + 1 < len(args) and args[i + 1].isdigit():
            interval = int(args[i + 1])

    if not os.path.isdir(root):
        sys.exit(f'no profiles folder at {root} (use --profiles)')
    print(f'profiles: {root}' + (f' (checking every {interval} s; Ctrl+C to stop)' if interval else ''))

    if interval is None:
        process_all(root, dry)
        return
    while True:
        safe_pass(root, dry)
        time.sleep(interval)


if __name__ == '__main__':
    main()
