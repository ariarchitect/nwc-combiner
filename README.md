# Navisworks NWD Publisher

A small Windows utility that republishes a Navisworks NWD only when an NWC or
NWD file in the source folder is newer than the current output. It is intended
for a simple flat folder layout with no installation or third-party
dependencies.

## Files

- `publishNWD.bat` displays the Navisworks reminder and launches PowerShell.
- `publishNWD.ps1` contains the publishing logic and interactive configurator.
- `config.example.psd1` documents the configuration format without containing
  machine- or project-specific paths.
- `config.psd1` stores local paths used by the publisher and is excluded from
  Git.

## Requirements

- Windows PowerShell 5.1 or later
- Autodesk Navisworks Manage
- An existing `.nwf` project
- A folder containing the source `.nwc`/`.nwd` files

Before using command-line publishing, open Navisworks Manage once, configure
the required publish/export options, and save them. Navisworks uses the most
recent GUI publish settings when it runs from the command line.

## Configure

Run the configurator through the same batch launcher:

```bat
publishNWD.bat -Configure
```

The configurator creates `config.psd1` when it does not exist. This local file
and all `.nwd` files are excluded from Git because they may contain sensitive
project information.

Alternatively, invoke the PowerShell script directly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\publishNWD.ps1 -Configure
```

The configurator asks for:

1. The Navisworks `Roamer.exe` path.
2. The folder containing source files.
3. The source `.nwf` project.
4. The destination `.nwd` path.

Press Enter at any prompt to keep the value currently stored in `config.psd1`.
Existing input paths are validated. The output NWD does not need to exist, but
its parent folder must exist.

## Run

Double-click `publishNWD.bat`, or run it from Command Prompt:

```bat
publishNWD.bat
```

The PowerShell script finds the newest `.nwc` or `.nwd` file directly inside
the configured source folder and compares its modification time with the
output NWD. If the output is missing or older, it runs Navisworks without the
GUI, waits for it to finish, and verifies that the output NWD was updated.
Otherwise, it exits without republishing. If the output NWD is located inside
the source folder, it is excluded from the source-file comparison.

The source-folder check is not recursive; files in nested folders are ignored.

## Automation

After configuration, `publishNWD.bat` can be launched from Windows Task
Scheduler. Set the task's **Start in** directory to this project folder and run
it under a Windows account that can access every configured path and has a
valid Navisworks license. During publishing, the script exclusively opens
`publishNWD.lock` next to the script. A second publisher instance exits instead
of starting another Navisworks process. The lock file may remain on disk; the
lock itself is released automatically when its file handle is closed.

## Exit behavior

- Exit code `0`: configuration succeeded, publishing succeeded, or the output
  was already up to date.
- Exit code `2`: invalid configuration, missing source files, or a Navisworks
  publishing failure. The same code is returned when another publisher
  instance is already running.
