#!/bin/sh

usage() {
    printf 'Usage: %s [--launcher [--display index | --builtin] [--debug | --debug-log /path/to/log] --] [--data-dir DIRECTORY] [nblood arguments...]\n' "$0" >&2
}

debug=0
display_index=${EDUKE32_GSG_DISPLAY_INDEX:-}
input_log=${EDUKE32_GSG_INPUT_LOG:-}
if [ -n "${EDUKE32_GSG_INPUT_DEBUG:-}" ] && [ "${EDUKE32_GSG_INPUT_DEBUG}" != 0 ]; then
    debug=1
fi

if [ "${1:-}" = "--launcher" ]; then
    shift
    launcher_delimiter=0

    while [ "$#" -gt 0 ]; do
        case $1 in
            --display)
                if [ "$#" -lt 2 ]; then
                    usage
                    exit 64
                fi
                display_index=$2
                shift 2
                ;;
            --builtin)
                display_index=0
                shift
                ;;
            --debug)
                debug=1
                shift
                ;;
            --debug-log)
                if [ "$#" -lt 2 ]; then
                    usage
                    exit 64
                fi
                debug=1
                input_log=$2
                shift 2
                ;;
            --)
                shift
                launcher_delimiter=1
                break
                ;;
            *)
                usage
                exit 64
                ;;
        esac
    done

    if [ "$launcher_delimiter" -ne 1 ]; then
        usage
        exit 64
    fi
fi

package_dir=$(CDPATH= cd "$(dirname "$0")" && pwd) || {
    printf 'Cannot resolve package directory: %s\n' "$(dirname "$0")" >&2
    exit 70
}
lib_dir=$package_dir/lib
controller_config_file=$package_dir/gamecontrollerdb.txt
executable=$package_dir/nblood

# Debug capture without editing menu entries: if this file exists, write an
# input/debug log next to it on every launch. Delete the file to disable.
debug_flag_file=$package_dir/gsg-debug
if [ -f "$debug_flag_file" ]; then
    debug=1
    input_log=${input_log:-$package_dir/gsg-input.log}
fi

# Video is presented by nblood's own direct-DRM page-flip path, which finds
# the connected external connector itself; the bundled SDK SDL2 provides input
# and audio. With the bundled SDL, HDMI is SDL display 1, so select it when an
# external connector is connected.
for connector in /sys/class/drm/card*-HDMI-* /sys/class/drm/card*-DP-* \
    /sys/class/drm/card*-DisplayPort-* /sys/class/drm/card*-DVI-* \
    /sys/class/drm/card*-VGA-*; do
    if [ -r "$connector/status" ] && [ "$(cat "$connector/status")" = connected ]; then
        printf 'External display detected at %s; selecting SDL display 1\n' "$connector" >&2
        display_index=${display_index:-1}
        if ! {
            printf off >"$connector/status"
            printf on >"$connector/status"
            printf detect >"$connector/status"
        }; then
            printf 'Warning: could not reset external display connector %s\n' "$connector" >&2
        fi
        AUDIODEV=hdmi
        export AUDIODEV
        if command -v alsactl >/dev/null 2>&1 && [ -r /sdcard/asound.state ]; then
            alsactl restore -f /sdcard/asound.state >/dev/null 2>&1 \
                || printf 'Warning: alsactl restore failed\n' >&2
        fi
        ALSA_CARD=0
        ALSA_DEVICE=1
        export ALSA_CARD ALSA_DEVICE
        # Full-resolution software rendering is too heavy at 1920x1080 on this
        # SoC; render at half resolution and upscale on present.
        EDUKE32_GSG_UPSCALE=${EDUKE32_GSG_UPSCALE:-2}
        export EDUKE32_GSG_UPSCALE
        break
    fi
done

if [ -n "$display_index" ]; then
    case $display_index in
        *[!0-9]*|'')
            printf 'Display index must be a non-negative integer: %s\n' "$display_index" >&2
            exit 64
            ;;
    esac

    EDUKE32_GSG_DISPLAY_INDEX=$display_index
    export EDUKE32_GSG_DISPLAY_INDEX
fi

if [ -n "${LD_LIBRARY_PATH:-}" ]; then
    LD_LIBRARY_PATH=$lib_dir:$LD_LIBRARY_PATH
else
    LD_LIBRARY_PATH=$lib_dir
fi
export LD_LIBRARY_PATH

if [ -z "${SDL_GAMECONTROLLERCONFIG:-}" ]; then
    if [ ! -r "$controller_config_file" ]; then
        printf 'Cannot read controller mapping: %s\n' "$controller_config_file" >&2
        exit 70
    fi

    # SDL splits this variable on newlines only; a semicolon join corrupts
    # every mapping after the first.
    SDL_GAMECONTROLLERCONFIG=$(sed -e 's/\r$//' -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' \
        "$controller_config_file")
    if [ -z "$SDL_GAMECONTROLLERCONFIG" ]; then
        printf 'Controller mapping is empty: %s\n' "$controller_config_file" >&2
        exit 70
    fi
fi
export SDL_GAMECONTROLLERCONFIG

# Optional data directory via environment or --data-dir, normalized to the
# parser-safe inline -j=value form (NBlood's legacy parser treats '/' as an
# option prefix, so "-j /absolute/path" loses its argument).
data_dir=${NBLOOD_DATA_DIR:-}
if [ "${1:-}" = "--data-dir" ] || [ "${1:-}" = "--data_dir" ]; then
    if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        printf '%s: %s requires a directory.\n' "$0" "$1" >&2
        usage
        exit 64
    fi
    data_dir=$2
    shift 2
fi
if [ -n "$data_dir" ]; then
    set -- "-j=$data_dir" "$@"
fi

if [ "${1:-}" = "-j" ] || [ "${1:-}" = "-game_dir" ]; then
    if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        printf '%s: %s requires a non-empty directory; check GAME_DIR/NBLOOD_DATA_DIR.\n' "$0" "${1:-data directory option}" >&2
        usage
        exit 64
    fi
    game_dir=$2
    shift 2
    set -- "-j=$game_dir" "$@"
fi

# NBlood replaced settings.cfg with nblood_cvars.cfg. Preserve an old local
# configuration once, rather than silently discarding a user's settings.
if [ -f "$package_dir/settings.cfg" ] && [ ! -e "$package_dir/nblood_cvars.cfg" ]; then
    mv "$package_dir/settings.cfg" "$package_dir/nblood_cvars.cfg"
fi

# Enter the game data directory (from --data-dir, NBLOOD_DATA_DIR or -j in any
# of its forms) so saves, settings and logs land with the game rather than in
# the package folder.
scenario_dir=
prev=
for arg in "$@"; do
    if [ "$prev" = "-j" ] || [ "$prev" = "-game_dir" ]; then
        scenario_dir=$arg
        break
    fi
    case $arg in
        -j=*)  scenario_dir=${arg#-j=} ;;
        -j?*)  scenario_dir=${arg#-j} ;;
    esac
    prev=$arg
done

if [ -n "$scenario_dir" ] && [ -d "$scenario_dir" ]; then
    cd "$scenario_dir" || {
        printf 'Cannot enter game data directory: %s\n' "$scenario_dir" >&2
        exit 70
    }
else
    cd "$package_dir" || {
        printf 'Cannot enter package directory: %s\n' "$package_dir" >&2
        exit 70
    }
fi

if [ "$debug" -eq 1 ]; then
    EDUKE32_GSG_INPUT_DEBUG=1
    NBLOOD_GSG_INPUT_DEBUG=1
    EDUKE32_GSG_FPS_LOG=${EDUKE32_GSG_FPS_LOG:-1}
    export EDUKE32_GSG_INPUT_DEBUG NBLOOD_GSG_INPUT_DEBUG EDUKE32_GSG_FPS_LOG

    if [ -z "$input_log" ]; then
        input_log=/tmp/runtime-$(id -u)/nblood-gsg-input.log
    fi
    input_dir=$(dirname "$input_log")
    if ! mkdir_error=$(mkdir -p "$input_dir" 2>&1); then
        printf 'Cannot create input debug log directory %s: %s\n' "$input_dir" "$mkdir_error" >&2
        exit 73
    fi
    if ! log_error=$( (umask 077; : > "$input_log") 2>&1); then
        printf 'Cannot open input debug log %s: %s\n' "$input_log" "$log_error" >&2
        exit 73
    fi
    {
        printf 'GSGDBG launcher: package=%s\n' "$package_dir"
        printf 'GSGDBG launcher: executable=%s\n' "$executable"
        printf 'GSGDBG launcher: log=%s\n' "$input_log"
        if command -v cksum >/dev/null 2>&1; then
            cksum "$executable" | sed 's/^/GSGDBG launcher: executable-cksum=/'
        else
            printf 'GSGDBG launcher: executable-cksum=unavailable\n'
        fi
    } >>"$input_log"
    printf 'GSGDBG launcher: executable=%s log=%s\n' "$executable" "$input_log" >&2
    exec "$executable" "$@" >>"$input_log" 2>&1
fi

exec "$executable" "$@"
