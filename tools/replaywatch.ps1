<#
hwrm-replays companion for Windows: the same tool as replaywatch.py, in PowerShell (built into Windows 10 and 11), so no Python
is needed. Run it through replaywatch.bat (double-click it: it keeps watching for finished games while you play).
See replaywatch.py's header for what it does and why. Both versions share the same state file (.hwrm-replays.json) and output,
and their functions match one for one.

Usage: replaywatch.bat [-Profiles "<the game's Bin\Profiles folder>"] [-Watch <seconds>] [-Dry]
       replaywatch.bat --run <game command...>   (Steam launch options: "<path>\replaywatch.bat" --run %command% -enablerecord)
  -Profiles: found through Steam's library list (or the HWRM_PROFILES variable) when not given.
  -Watch: keep running and check every <seconds> (replaywatch.bat with no arguments uses -Watch 5). Without it: one pass.
  -Dry: only report what would change.
  -WhileGameRuns: (used by replaywatch.bat --run) check every few seconds while HomeworldRM.exe runs, once more after it exits,
    then stop. Gives up if the game hasn't started within 3 minutes.

PowerShell notes for anyone editing this: write null tests as `$null -eq $x` (`$x -eq $null` filters arrays instead of testing
them), return byte arrays as `return ,$bytes` (otherwise they're unrolled into separate values), and write numbers of 0x80000000
and above in decimal (0x80000000 is a negative int32 in PowerShell). Variable names ignore case, so a local like $slot would
overwrite the constant $SLOT: give locals distinct names.
#>
param([string]$Profiles, [int]$Watch = 0, [switch]$Dry, [switch]$WhileGameRuns)

$ErrorActionPreference = 'Stop'


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

$HEADER = 0x720
[byte[]]$FILE_SIGNATURE = 0x09, 0x28, 0x2f, 0x03
$BODY_SIZE = 0x4
$SLOT = 0x8
$END_FRAME = 0xc
$SETTINGS = 0x18

$STRING_FIELDS = 0x658, 0x670   # the settings' text fields: rules tag ('DEATHMATCH'), Race_Paths ('Deathmatch,Extras')
$MODE_OFFSET = 0x68c            # game mode: 0 campaign, 1 local/skirmish, 2 network

# The name trailer: the game's list reads it from the end of the file (as in its own saves) and plays '<name>.rec'.
$TRAILER_SIZE = 0x214                                                                    # 532 bytes
[byte[]]$TRAILER_PREFIX = 0x53, 0x46, 0x4e, 0x4d, 0x00, 0x45, 0x4e, 0x53, 0x2f, 0x01, 0x02, 0x00   # 'SFNM\0ENS' + version-like bytes
$NAME_CHARS = 39                                                                         # the UTF-16 name area

$STATE_FILE = '.hwrm-replays.json'   # per game (settings hash): the output name, its source kind and end frame

$WEB_MARKERS = '(?i)path=|httponly|set-cookie|cookie|domain=|expires=|samesite|max-age|secure;'
$TOKEN_RUN = '^[A-Za-z0-9%+/=_\-]{48,}$'

$L1 = [Text.Encoding]::GetEncoding(28591)   # Latin-1: one character per byte, so text positions are byte offsets


# ---------------------------------------------------------------------------------------------------------------------------------
# Reading and repairing a recording
# ---------------------------------------------------------------------------------------------------------------------------------

# True if $b starts like a recording.
function Test-Recording([byte[]]$b) {
    $b.Length -ge $HEADER -and $b[0] -eq $FILE_SIGNATURE[0] -and $b[1] -eq $FILE_SIGNATURE[1] -and
        $b[2] -eq $FILE_SIGNATURE[2] -and $b[3] -eq $FILE_SIGNATURE[3]
}

# True if $b already ends with a name trailer (ours, or the game's own Save Recorded).
function Test-Trailer([byte[]]$b) {
    $b.Length -ge ($HEADER + $TRAILER_SIZE) -and $L1.GetString($b, $b.Length - $TRAILER_SIZE, 4) -eq 'SFNM'
}

function Get-EndFrame([byte[]]$b) {
    [BitConverter]::ToInt32($b, $END_FRAME)
}

# Writes a 32-bit number into $b at $off.
function Set-Int32([byte[]]$b, [int]$off, [long]$v) {
    [Array]::Copy([BitConverter]::GetBytes([int32]$v), 0, $b, $off, 4)
}

# Blanks leftover web data in the header of $b (changed in place). Returns how many text runs were blanked.
function Clear-WebData([byte[]]$b, $notes) {
    $n = 0
    $text = $L1.GetString($b, $SETTINGS, $HEADER - $SETTINGS)
    foreach ($m in [regex]::Matches($text, '[ -~]{8,}')) {
        if ($m.Value -match $WEB_MARKERS -or $m.Value -cmatch $TOKEN_RUN) {
            [Array]::Clear($b, $SETTINGS + $m.Index, $m.Length)
            $n++
        }
    }
    if ($n -and $null -ne $notes) {
        $notes.Add("blanked $n leftover web-data text run(s)")
    }
    return $n
}

# Returns a repaired copy of the recording (no trailer yet), or $null if it isn't a finished recording.
function Repair-Recording([byte[]]$b, $notes) {
    if (-not (Test-Recording $b)) {
        $notes.Add('not a recording')
        return $null
    }
    if ([BitConverter]::ToInt32($b, $BODY_SIZE) -eq -1 -and -not (Test-Trailer $b)) {
        $notes.Add('still recording (size unknown)')
        return $null
    }

    $c = [byte[]]$b.Clone()

    # Text fields of 16+ characters are pointers into the recording session's memory: write a short value inline instead.
    $tag = $L1.GetString($c, 0x658, 16).Split([char]0)[0]
    $inline = if ($tag -ceq 'SINGLEPLAYER') { 'SinglePlayer' } else { 'Deathmatch' }
    foreach ($off in $STRING_FIELDS) {
        $ptr = [BitConverter]::ToUInt32($c, $off)
        $size = [BitConverter]::ToUInt32($c, $off + 16)
        $cap = [BitConverter]::ToUInt32($c, $off + 20)
        if ($cap -ge 16 -and $cap -lt 0x1000 -and $size -ge 16 -and $size -le $cap -and $ptr -gt 0x10000 -and $ptr -lt 2147483648) {
            [Array]::Clear($c, $off, 16)
            $ib = $L1.GetBytes($inline)
            [Array]::Copy($ib, 0, $c, $off, $ib.Length)
            Set-Int32 $c ($off + 16) $ib.Length
            Set-Int32 $c ($off + 20) 15
            $notes.Add(("string at 0x{0:x} ({1} chars) -> '{2}'" -f $off, $size, $inline))
        }
    }

    # Multiplayer games are recorded in network mode, which playback can't run.
    if ([BitConverter]::ToUInt32($c, $MODE_OFFSET) -eq 2) {
        Set-Int32 $c $MODE_OFFSET 1
        $notes.Add('network mode -> local')
    }

    [void](Clear-WebData $c $notes)

    # Body size 'unknown', so the game accepts the trailer that follows the commands.
    Set-Int32 $c $BODY_SIZE -1
    return ,$c
}

# The name trailer for a recording called $name.
function New-Trailer([string]$name) {
    $t = New-Object byte[] $TRAILER_SIZE
    [Array]::Copy($TRAILER_PREFIX, 0, $t, 0, $TRAILER_PREFIX.Length)
    if ($name.Length -gt $NAME_CHARS) { $name = $name.Substring(0, $NAME_CHARS) }
    $w = [Text.Encoding]::Unicode.GetBytes($name)
    [Array]::Copy($w, 0, $t, 12, $w.Length)
    return ,$t
}

# SHA-1 (hex) of a header's game settings.
function Get-SettingsHash([byte[]]$b) {
    $sha = [Security.Cryptography.SHA1]::Create()
    ([BitConverter]::ToString($sha.ComputeHash($b, $SETTINGS, $HEADER - $SETTINGS)) -replace '-', '').ToLower()
}

# Identifies a game: a hash of its settings (incl. its random seed) as repaired, the same for its snapshots, temp recording and
# our output.
function Get-GameId([byte[]]$b) {
    $fixed = Repair-Recording $b (New-Object Collections.Generic.List[string])
    if ($null -eq $fixed) { $fixed = $b }
    Get-SettingsHash $fixed
}


# ---------------------------------------------------------------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------------------------------------------------------------

# The file's bytes, or $null if it can't be read (e.g. the game is writing it).
function Read-Bytes([string]$path) {
    try { return ,[IO.File]::ReadAllBytes($path) } catch { return $null }
}

# $s as a file name the game's list can show.
function Get-SafeName([string]$s) {
    $s = [regex]::Replace($s, '[^A-Za-z0-9 _\-]', '-')
    if ($s.Length -gt $NAME_CHARS) { $s = $s.Substring(0, $NAME_CHARS) }
    $s = $s.Trim()
    if ($s) { $s } else { 'replay' }
}

# $name, or '$name (2)', '$name (3)', ... if a recording of that name already exists.
function Get-UniqueName([string]$folder, [string]$name) {
    $out = $name
    $n = 2
    while (Test-Path -LiteralPath (Join-Path $folder "$out.rec")) {
        $out = "$name ($n)"
        if ($out.Length -gt $NAME_CHARS) { $out = $out.Substring(0, $NAME_CHARS) }
        $n++
    }
    $out
}

# Writes the repaired recording, with its name trailer, as playback\<name>.rec.
function Write-Recording([string]$playback, [string]$name, [byte[]]$fixed) {
    if ($Dry) { return }
    $t = New-Trailer $name
    $all = New-Object byte[] ($fixed.Length + $t.Length)
    [Array]::Copy($fixed, 0, $all, 0, $fixed.Length)
    [Array]::Copy($t, 0, $all, $fixed.Length, $t.Length)
    [IO.File]::WriteAllBytes((Join-Path $playback "$name.rec"), $all)
}

# Moves a used source file into playback\originals\.
function Move-ToOriginals([string]$path, [string]$originals) {
    if ($Dry) { return }
    [void](New-Item -ItemType Directory -Force -Path $originals)
    Move-Item -LiteralPath $path -Destination (Join-Path $originals (Split-Path -Leaf $path)) -Force
}


# ---------------------------------------------------------------------------------------------------------------------------------
# One profile's playback folder
# ---------------------------------------------------------------------------------------------------------------------------------

# Recordings already in the list (with a trailer), by game id: @{ name; frame }.
function Get-ExistingGames([string]$playback) {
    $existing = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $playback -File -Filter '*.rec')) {
        $eb = Read-Bytes $f.FullName
        if ($null -ne $eb -and (Test-Trailer $eb) -and (Test-Recording $eb)) {
            [void](Clear-WebData $eb $null)                 # hashed as scrubbed, like Repair-Recording output
            $existing[(Get-SettingsHash $eb)] = @{ name = $f.BaseName; frame = (Get-EndFrame $eb) }
        }
    }
    $existing
}

# Sorts the recordings into games (snapshots and finished temp recordings, by game id) and recordings saved by name.
# Recordings that already have a trailer are only scrubbed of leftover web data.
function Get-Recordings([string]$playback, [string]$temp) {
    $files = @(Get-ChildItem -LiteralPath $playback -File -Filter '*.rec' | ForEach-Object { $_.FullName })
    if (Test-Path -LiteralPath $temp) {
        $files += @(Get-ChildItem -LiteralPath $temp -File -Filter '*.rec' | ForEach-Object { $_.FullName })
    }

    $candidates = @{}                                       # game id -> list of @{ Kind; Frame; Path; Bytes }
    $named = New-Object Collections.ArrayList               # list of @{ Path; Name; Bytes }
    foreach ($src in ($files | Sort-Object)) {
        $b = Read-Bytes $src
        if ($null -eq $b -or -not (Test-Recording $b)) { continue }

        if (Test-Trailer $b) {                              # already done (ours, or a game save)
            $notes = New-Object Collections.Generic.List[string]
            if ((Clear-WebData $b $notes) -and -not $Dry) { [IO.File]::WriteAllBytes($src, $b) }
            if ($notes.Count) { Write-Host "${src}: $($notes -join '; ')" }
            continue
        }

        $base = [IO.Path]::GetFileNameWithoutExtension($src)
        if ((Split-Path -Parent $src) -eq $temp) {
            $body = [BitConverter]::ToInt32($b, $BODY_SIZE)
            if ($body -eq -1 -or $body -eq 0) { continue }   # still recording, or empty (the mod's snapshot has that game)
            $kind = 'temp'
        } elseif ($base -match '^recGame-\d+-\d+-snapshot$') {
            $kind = 'snapshot'
        } else {
            [void]$named.Add([pscustomobject]@{ Path = $src; Name = $base; Bytes = $b })
            continue
        }

        $gid = Get-GameId $b
        if (-not $candidates.ContainsKey($gid)) { $candidates[$gid] = New-Object Collections.ArrayList }
        [void]$candidates[$gid].Add([pscustomobject]@{ Kind = $kind; Frame = (Get-EndFrame $b); Path = $src; Bytes = $b })
    }
    @{ Candidates = $candidates; Named = $named }
}

# Saves each game from its best source (the latest snapshot, else the temp recording), replacing an earlier save of the same game
# if this source is better. Returns $true if the state changed.
function Save-Games([string]$playback, [string]$originals, $candidates, $existing, $state) {
    $changed = $false
    foreach ($gid in @($candidates.Keys)) {
        $cands = $candidates[$gid]
        $snaps = @($cands | Where-Object { $_.Kind -eq 'snapshot' })
        $pool = if ($snaps.Count) { $snaps } else { @($cands) }
        $best = $pool | Sort-Object -Property Frame -Descending | Select-Object -First 1

        $prev = $state[$gid]
        if ($null -eq $prev -and $existing.ContainsKey($gid)) {   # saved before this state file existed: never let a temp override it
            $prev = @{ name = $existing[$gid].name; kind = 'snapshot'; frame = $existing[$gid].frame }
            $state[$gid] = $prev
            $changed = $true
        }

        if ($null -ne $prev) {
            $better = ($best.Kind -eq 'snapshot' -and $prev.kind -eq 'temp') -or ($best.Kind -eq $prev.kind -and $best.Frame -gt $prev.frame)
            if (-not $better) {
                foreach ($s in $snaps) { Move-ToOriginals $s.Path $originals }   # tidy up snapshots already covered
                continue
            }
            $name = $prev.name                              # replace the earlier output, keep its name
        } else {
            $playerSlot = [BitConverter]::ToUInt32($best.Bytes, $SLOT)
            $stamp = (Get-Item -LiteralPath $best.Path).LastWriteTime.ToString('yyyy-MM-dd HH-mm-ss')
            $name = Get-UniqueName $playback (Get-SafeName "$stamp P$playerSlot")
        }

        $notes = New-Object Collections.Generic.List[string]
        $fixed = Repair-Recording $best.Bytes $notes
        if ($null -eq $fixed) { continue }
        Write-Host "$($best.Path) -> $(Join-Path $playback "$name.rec") ($($best.Kind), frame $($best.Frame)): $($notes -join '; ')"
        Write-Recording $playback $name $fixed
        foreach ($s in $snaps) { Move-ToOriginals $s.Path $originals }
        $state[$gid] = @{ name = $name; kind = $best.Kind; frame = $best.Frame }
        $changed = $true
    }
    $changed
}

# Repairs recordings saved by name in the game, in place (the original goes to playback\originals\).
function Repair-Named([string]$playback, [string]$originals, $named) {
    foreach ($item in $named) {
        $notes = New-Object Collections.Generic.List[string]
        $fixed = Repair-Recording $item.Bytes $notes
        if ($null -eq $fixed) {
            Write-Host "skip $($item.Path): $($notes[0])"
            continue
        }
        $base = $item.Name
        $name = if ((Get-SafeName $base) -ceq $base -and $base.Length -le $NAME_CHARS) { $base } else { Get-UniqueName $playback (Get-SafeName $base) }
        Write-Host "$($item.Path) -> $(Join-Path $playback "$name.rec") (named): $($notes -join '; ')"
        Move-ToOriginals $item.Path $originals
        Write-Recording $playback $name $fixed
    }
}

# Backups in playback\originals\ are kept as recorded, apart from leftover web data.
function Clear-Originals([string]$originals) {
    if (-not (Test-Path -LiteralPath $originals)) { return }
    foreach ($f in (Get-ChildItem -LiteralPath $originals -File | Sort-Object Name)) {
        $ob = Read-Bytes $f.FullName
        if ($null -eq $ob -or -not (Test-Recording $ob)) { continue }
        $notes = New-Object Collections.Generic.List[string]
        if (Clear-WebData $ob $notes) {
            Write-Host "$($f.FullName): $($notes -join '; ')"
            if (-not $Dry) { [IO.File]::WriteAllBytes($f.FullName, $ob) }
        }
    }
}

# One pass over a profile's playback folder.
function Invoke-Profile([string]$playback) {
    $statePath = Join-Path $playback $STATE_FILE
    $state = @{}
    if (Test-Path -LiteralPath $statePath) {
        $obj = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
        foreach ($p in $obj.PSObject.Properties) {
            $state[$p.Name] = @{ name = $p.Value.name; kind = $p.Value.kind; frame = [int]$p.Value.frame }
        }
    }
    $temp = Join-Path $playback 'temp'
    $originals = Join-Path $playback 'originals'

    $existing = Get-ExistingGames $playback
    $found = Get-Recordings $playback $temp
    $changed = Save-Games $playback $originals $found.Candidates $existing $state
    Repair-Named $playback $originals $found.Named
    Clear-Originals $originals

    if ($changed -and -not $Dry) {                          # UTF-8 without a BOM, so the Python version can read it too
        [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 3), (New-Object Text.UTF8Encoding $false))
    }
}


# ---------------------------------------------------------------------------------------------------------------------------------
# Finding the game
# ---------------------------------------------------------------------------------------------------------------------------------

# Steam library folders: the one this tool is in (if it is), then every library listed by the Steam installs found.
function Get-SteamLibraries {
    $libs = New-Object Collections.Generic.List[string]
    $parts = $PSScriptRoot -split '[\\/]'
    for ($i = $parts.Length - 1; $i -gt 0; $i--) {
        if ($parts[$i] -eq 'steamapps') {
            $libs.Add(($parts[0..($i - 1)] -join '\'))
            break
        }
    }

    $roots = @()
    try { $roots += (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction Stop).SteamPath } catch { }
    if (${env:ProgramFiles(x86)}) { $roots += Join-Path ${env:ProgramFiles(x86)} 'Steam' }
    if ($env:ProgramFiles) { $roots += Join-Path $env:ProgramFiles 'Steam' }

    foreach ($r in $roots) {
        $libs.Add($r)
        $vdf = Join-Path $r 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            foreach ($m in [regex]::Matches([IO.File]::ReadAllText($vdf), '"path"\s+"([^"]+)"')) {
                $libs.Add($m.Groups[1].Value.Replace('\\', '\'))
            }
        }
    }
    $libs
}

# The game's Bin\Profiles folder: HWRM_PROFILES, else the first Steam library that has the game. $null if not found.
function Find-Profiles {
    if ($env:HWRM_PROFILES) { return $env:HWRM_PROFILES }
    foreach ($lib in Get-SteamLibraries) {
        $p = Join-Path $lib 'steamapps\common\Homeworld\HomeworldRM\Bin\Profiles'
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $null
}


# ---------------------------------------------------------------------------------------------------------------------------------

# One pass over every profile.
function Invoke-AllProfiles {
    foreach ($p in (Get-ChildItem -LiteralPath $Profiles -Directory | Where-Object { $_.Name -like 'profile*' } | Sort-Object Name)) {
        $pb = Join-Path $p.FullName 'playback'
        if (Test-Path -LiteralPath $pb) { Invoke-Profile $pb }
    }
}

# Invoke-AllProfiles, reporting errors instead of stopping (the watch loops keep going: a file may be mid-write).
function Invoke-SafePass {
    try { Invoke-AllProfiles } catch { Write-Host "error: $_ (will retry)" }
}

function Test-GameRunning {
    [bool](Get-Process -Name 'HomeworldRM' -ErrorAction SilentlyContinue)
}


# ---------------------------------------------------------------------------------------------------------------------------------

if (-not $Profiles) { $Profiles = Find-Profiles }
if (-not $Profiles -or -not (Test-Path -LiteralPath $Profiles)) {
    Write-Host "Homeworld Remastered's Bin\Profiles folder not found: pass it with -Profiles `"<folder>`""
    exit 1
}

if ($WhileGameRuns) {
    $interval = if ($Watch -gt 0) { $Watch } else { 5 }
    Write-Host "profiles: $Profiles (checking every $interval s while the game runs)"
    $deadline = (Get-Date).AddMinutes(3)
    while (-not (Test-GameRunning)) {                       # wait for the game to start
        if ((Get-Date) -gt $deadline) { Write-Host 'the game did not start'; exit 1 }
        Start-Sleep -Seconds 2
    }
    while (Test-GameRunning) {
        Invoke-SafePass
        Start-Sleep -Seconds $interval
    }
    Invoke-SafePass
    exit 0
}

Write-Host ("profiles: $Profiles" + $(if ($Watch -gt 0) { " (checking every $Watch s; close this window to stop)" } else { '' }))
if ($Watch -le 0) {
    Invoke-AllProfiles
    exit 0
}
while ($true) {
    Invoke-SafePass
    Start-Sleep -Seconds $Watch
}
