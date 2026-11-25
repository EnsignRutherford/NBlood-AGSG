# Atari GameStation Go

This target builds Linux ARMHF Rednukem packages for the Atari GameStation Go.
It uses the validated Dice/Debian Stretch SDK sysroot, SDL2, and ALSA runtime
staging used by the working GameStation Go ports. The normal package is
software-rendered; the dedicated Duke Nukem 64 package uses Rednukem's
OpenGL renderer through the same SDL KMSDRM video path.

## Build

From WSL Ubuntu, build and validate the package with:

```sh
cd /mnt/d/Development/rednukem
SYSROOT=/mnt/d/Development/SDKs/gamestation-go-dice-stretch-armhf \
  bash platform/gamestation-go-build.sh
```

To build the distinct SDL/OpenGL package required by Duke Nukem 64:

```sh
cd /mnt/d/Development/rednukem
GSG_RENDERER=dn64-gl \
SYSROOT=/mnt/d/Development/SDKs/gamestation-go-dice-stretch-armhf \
  bash platform/gamestation-go-build.sh
```

`GSG_RENDERER=software` is the default and outputs
`package/gamestation-go/`. `GSG_RENDERER=dn64-gl` enables OpenGL, disables
Polymer, and outputs `package/gamestation-go-dn64/` with a separate object
directory. This leaves the tested software package unchanged.

The script requires `arm-linux-gnueabihf-gcc` and
`arm-linux-gnueabihf-g++`. It prefers `arm-linux-gnueabihf-readelf` for
validation and falls back to GNU `readelf`, which parses ARM ELF files
independently of the host architecture. Override `CROSS`, `READELF`,
`OUTPUT_DIR`, `BUILD_DIR`, `TARGET_CFLAGS`, or `TARGET_LDFLAGS` when needed.

The build uses `--sysroot`, `-march=armv7-a`, `-mfloat-abi=hard`, `-mfpu=neon`,
and `-fPIE`; it links a PIE against `/lib/ld-linux-armhf.so.3`. The primary
SDK supplies the SDL2/ALSA development files and the staged runtime. Its
runtime-only root does not contain the glibc development linker scripts, so
the script also uses the cached GCC 6.3/Debian Stretch-compatible headers and
linker scripts at `/home/lebla/armhf-stretch-sysroot`. Override
`LEGACY_SYSROOT` if that cache is installed elsewhere. The cached Stretch image
also provides GCC 8 compatibility C++ headers and `libstdc++.so.6` at
`opt/mame-gcc8/usr`; override `LEGACY_CXX_ROOT` if needed. That shared library
is staged with the firmware-matched SDL2/ALSA/FLAC/Ogg/libgcc/libatomic
closure, avoiding newer host runtime symbols. The final link also uses
Stretch's `libc_nonshared.a` for the glibc `atexit` compatibility shim. The
script also uses Stretch's PIE start/end files with GCC's `crtbeginS.o` and
`crtendS.o`. This preserves C++ global-constructor execution under the
firmware-compatible glibc; using GCC 13's newer `Scrt1.o` leaves global
`std::string` state uninitialized and crashes before Rednukem reads arguments.
The executable uses 64 KiB ELF load alignment, matching the verified EDuke32
GameStation Go package. Set `RUNTIME_LIBDIR` to a colon-separated replacement
search path for another firmware-matched staging environment.

After every build, the script recursively walks `DT_NEEDED` entries with
readelf. It bundles every non-baseline dependency in `lib/` and fails if any
non-baseline library is missing, is not ARMHF, or is not included in the
closure. The firmware-provided ARMHF baseline is limited to the dynamic loader
and glibc libraries (`libc`, `libdl`, `libm`, `libpthread`, and `librt`).

## Deploy

The deployable output is `package/gamestation-go/`. Copy that directory to
`/sdcard/bin/rednukem` on the device, keep its `lib/` directory intact, and
run:

```sh
/sdcard/bin/rednukem/run-rednukem.sh -g /path/to/DUKE3D.GRP
```

### Duke Nukem 64

Deploy `package/gamestation-go-dn64/` to
`/sdcard/bin/rednukem-dn64/` to keep it alongside the software-rendered
package. Preserve its `lib/` directory and launcher:

```sh
/sdcard/bin/rednukem-dn64/run-rednukem.sh \
  -g '/sdcard/Games/Duke Nukem 64/Duke Nukem 64.z64'
```

The file must be a legal 8 MiB Duke Nukem 64 cartridge ROM dump. Rednukem
accepts supported byte orders and normalizes them internally; optional MIDI
tracks extracted from a lawful `DUKE3D.GRP` may be placed beside the ROM.
The `dn64-gl` binary still uses SDL/KMSDRM and all GameStation input support.
SDL dynamically loads the firmware's `libGL.so.1`/EGL/GLES backend, so this
package intentionally does not bundle the desktop Stretch Mesa libraries,
which are not compatible with the GameStation graphics stack.
The GameStation build requests an attribute-free desktop OpenGL context:
the firmware EGL driver rejects the desktop robust-access/debug context
attributes, while Rednukem's renderer requires desktop fixed-function OpenGL
rather than GLES.
Its optional desktop ImGui renderer is disabled: the firmware exposes GL
through SDL's context resolver, not the separate desktop `libGL` loader ImGui
uses. This does not affect the game renderer or controls.

The launcher resolves its own directory, prepends
`/sdcard/bin/rednukem/lib` (or its actual installed location) to
`LD_LIBRARY_PATH` without discarding an existing value, starts Rednukem from
the package directory, and rejects an empty invocation with usage and status
64 in its first executable block, before it performs a path lookup,
environment change, or binary launch. Use Rednukem's standard `-g`, `-grp`,
or `-game_dir` game-data options as appropriate.

Normal single-player launches retain Rednukem's main menu. To start a
specific episode, level, or skill directly, pass Rednukem's standard
one-based `-v`, `-l`, and `-s` options explicitly.

When the explicit main archive is named `WW2GI.GRP`, the launcher also adds
the GameStation-only `-ww2gi` selection switch. This is required for valid
World War II GI archive revisions that differ from the scanner's fixed
CRC/size record: it selects the World War II GI game type and related
resources. Rednukem then uses the archive's normal CON fallback (`WW2GI.CON`
when present, otherwise `GAME.CON`); a user-supplied `-x` CON file remains
authoritative.

The launcher also translates a supplied `/sdcard/...` game-data directory to
`/mnt/sdcard/...` when that mounted path exists. Rednukem itself runs from
`/mnt/sdcard` on the firmware, so this makes GameStation launcher paths
readable without changing a caller's command line.

For an explicit `-game_dir` plus `-gamegrp`, the launcher verifies that the
selected archive is a readable regular file before starting Rednukem. On
failure it exits with status 66 and prints the resolved path plus the
game-data directory listing, avoiding an empty-archive startup stall.

An empty invocation that still prints `Segmentation fault` is not running
this staged launcher; redeploy `run-rednukem.sh` and invoke it explicitly
through `/bin/sh`.

Rednukem's SDL layer already loads a local `gamecontrollerdb.txt` before
controller discovery. The package supplies the verified GameStation Go
`agpio-keys` mapping and the launcher exports the same mapping through
`SDL_GAMECONTROLLERCONFIG` only when the user has not provided an override.
If SDL cannot expose the device as a game controller, Rednukem instead
selects the verified `agpio-keys` GUID as its raw joystick.

On GameStation Go, the D-pad is bound to forward, backward, turn-left, and
turn-right during gameplay. Menu navigation continues to use SDL's D-pad
repeat state.

The Home button (`b25`, exposed by SDL as `misc1` when the runtime emits a
controller event) exits Rednukem cleanly only while its main menu is active.
Both the verified controller's raw `b25` and mapped `misc1` events are
consumed during gameplay, so Home cannot trigger an unintended exit mid-level.
Redneck Rampage and Redneck Rampage Rides Again also exit from their title
attract demo, which presents the frontend with its menu closed.

The integrated trackball is read directly from the Linux input device that
provides `REL_Z` and `REL_RX` axes, which are translated into horizontal and
vertical mouse movement while the game has mouse capture. The known
`/dev/input/event5` is preferred; otherwise Rednukem selects a single
capability-matched event device and refuses an ambiguous match.

## Volume buttons are ignored

`evtest` shows the integrated volume buttons on the `zadc-keys` evdev device
(`/dev/input/event0`) as `KEY_VOLUMEUP` (115) and `KEY_VOLUMEDOWN` (114). The
game ignores those two key codes: the direct `agpio-keys` readers in
`source/build/src/sdlayer.cpp` skip them, and the SDL keyboard handler drops
`SDL_SCANCODE_VOLUMEUP`/`VOLUMEDOWN` (and the matching keycodes).

In game mode the firmware also remaps the buttons to ordinary game inputs
(volume down -> controller A, volume up -> D-pad down/Down arrow, and on some
configs other controls such as strafe left). The real 114/115 events are still
read passively from `zadc-keys`; while one is held, and for 250 ms after, new
presses (SDL controller/raw buttons, SDL key-downs, large axis pushes, and the
direct `agpio-keys` reader presses) are dropped. Releases always pass,
so nothing can stick. Number keys (keypad digits, SDL scancodes 1-0 and
KP 1-0) are never dropped by this window: the direct keypad reader does not
apply it, and the SDL key-down check exempts them. Home (`b25`), D-pad and the
trackball behave normally otherwise. The wireless gamepad's keypad (HID
keyboard interface of the "LiteStar PC-GamePad" evdev nodes, e.g.
`KEY_KP1`=79) is read passively by the same keypad reader and injected as
number keys 1-0; the pad's `*` (`KEY_9`) and `#` (`KEY_0`) become the left/right
stick clicks (raw buttons 18/20), like the built-in keypad. No other pad events are used from those nodes. The keypad reader also keeps its
`zadc-keys` flag in step with its fd list when a node is removed, so an
`agpio-keys` fd can no longer be mistaken for `zadc-keys`. Set `EDUKE32_GSG_INPUT_DEBUG=1` to log `GSGDBG dropped phantom ...`
lines. On-device behavior must be verified on the hardware.

## Device diagnostic

To capture the dynamic-loader trace, launcher environment, checksums, exact
forwarded arguments, and Rednukem output without changing normal launches,
use the launcher-only diagnostic prefix:

```sh
/sdcard/bin/rednukem/run-rednukem.sh --launcher --debug-log /tmp/rednukem-gsg.log -- \
  -game_dir '/sdcard/Games/Duke Nukem/gamedata/rednukem-WWII' -gamegrp WW2GI.GRP
```

The command writes the log with mode 0600, records every forwarded argument as
an exact hexadecimal byte sequence, returns Rednukem's exit status, and does
not alter the normal launch environment. `--debug` uses
`/tmp/runtime-<uid>/rednukem-gsg.log` when no explicit log path is supplied.

Game data is not distributed. Place compatible Duke Nukem 3D, Redneck
Rampage, NAM, or World War II GI data where Rednukem can find it, or pass the
appropriate Rednukem command-line arguments. On hardware, verify SDL video,
audio, controller mapping, trackball behavior, and a clean game exit against
the installed firmware; those device-specific checks cannot be performed by
the cross-build.
