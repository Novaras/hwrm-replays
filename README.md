# hwrm-replays

Watch recorded games in **Homeworld Remastered**: every game you play is saved automatically and can be watched from the game's
own *Load Recorded Game* screen.

## Installation

1. **The mod:** subscribe to it on the [Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3838739464) and
   enable it in the game.
2. **Recording:** in Steam, Homeworld Remastered → Properties → Launch Options, add `-enablerecord`. The game then records every
   game you play.
3. **The companion tool:** download `hwrm-replays-tools` (a zip) from the latest
   [release](https://github.com/Novaras/hwrm-replays/releases/latest) (it isn't part of the Workshop download), unzip it anywhere
   and run it (see [Companion tool](#companion-tool)). On Windows keep `replaywatch.bat` and `replaywatch.ps1` together; with
   Python, `replaywatch.py` is all you need.

### Without the Workshop

Put this folder (it must contain `keeper.txt`) in the game's `Homeworld` or `HomeworldRM` folder, e.g.
`...\steamapps\common\Homeworld\hwrm-replays`, and use these launch options instead:

```
-moddatapath hwrm-replays -enablerecord
```

The game disables its online multiplayer menu whenever `-moddatapath` is used; skirmish and LAN games still work.

## In game

- **Saving:** when a game ends (victory/defeat banner, retiring, or leaving through the in-game menu: exit, end game, restart),
  the mod saves a snapshot of the recording to `Bin\Profiles\<profile>\playback\recGame-<slot>-<frame>-snapshot.rec`. Snapshots
  are kept even if the companion tool isn't running, so no game is lost.
- **Watching:** *Player vs CPU → Load Recorded Game* (the game's own screen, shown with `-enablerecord`) lists every recording
  the companion tool has prepared, by name.
- The post-game *Save Recorded* button is hidden: it fails for non-host players, and every game is saved anyway.

## Companion tool

No extra packages needed. Leave it running while you play, or run it after playing.

| Platform | How to run |
| --- | --- |
| Windows | Double-click `tools\replaywatch.bat` (PowerShell, built into Windows 10/11). It keeps watching until you close it. |
| Linux, or anywhere with Python 3 | `python3 tools/replaywatch.py --watch` |

It finds the game through Steam. If it can't, pass the game's `Bin\Profiles` folder: `-Profiles "<folder>"` (Windows) or
`--profiles <folder>` (Python). Both versions also take `-Dry` / `--dry` to only report what they would change.

### Starting it with the game

Instead of running the tool yourself, Steam can start it with the game: it then converts replays while you play and closes
after the game exits. Put the tool's full path in the launch options (Steam → Homeworld Remastered → Properties) like this:

| Platform | Launch options |
| --- | --- |
| Windows | `"C:\path\to\tools\replaywatch.bat" --run %command% -enablerecord` |
| Linux (Proton) | `python3 /path/to/tools/replaywatch.py --run %command% -enablerecord` |

`%command%` is Steam's placeholder for the game itself; the game always starts, even if the tool can't find its folders.

What it does:

- turns each game's snapshot into a named, playable recording: `<date> <time> P<slot>.rec`;
- uses the game's own last recording (`playback\temp`) only for a game with no snapshot;
- repairs recordings saved by name in the game, in place (the original is kept in `playback\originals`);
- blanks any leftover web data (once a login cookie) from the recordings' headers.

See the header of `tools/replaywatch.py` for the details of each repair.

## Known limitation

When a player **leaves** a game part-way through, every other player who is recording it (`-enablerecord`) crashes. This is an
engine bug. Have just one player record, ideally an observer, so only that copy is affected. Surrendering is fine.

## Files

| File | What |
| --- | --- |
| `ui/newui/ingamemenu.lua`, `ui/newui/gameoverscreen.lua`, `ui/newui/stats.lua` | Stock copies; changes marked `hwrm-replays` |
| `tools/replaywatch.py` | Companion tool (Python 3) |
| `tools/replaywatch.ps1`, `tools/replaywatch.bat` | The same tool for Windows (PowerShell) |
| `keeper.txt` | Marks the folder as a mod |

## Publishing your own version

If you upload a modified copy to the Workshop, first clear the `WorkshopID:` line in `config.txt` (leave it blank) and change
the title, so the upload creates a new Workshop item instead of trying to update this one. The upload writes your new item's ID
into the uploaded folder's `config.txt`; keep it there (and in your own copy) so later uploads update that item.
