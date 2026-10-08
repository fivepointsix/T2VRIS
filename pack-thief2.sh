#!/bin/sh
# Create the VR asset ZIP from your own Thief II installation.
# Uses standard Linux shell tools and zip; no Python is needed.
# Save beside Thief2.exe and run: sh ./pack-thief2.sh
# Or: sh ./pack-thief2.sh "/path/to/Thief II" "/path/to/output.zip"

set -eu

usage() {
    printf '%s\n' 'Usage: sh ./pack-thief2.sh ["Thief II folder"] ["output.zip"]' \
        'Without arguments, packs the folder containing this script.' \
        'Creates Thief2-VR-assets.zip without changing the game files.'
}

die() {
    printf 'Could not create the game package: %s\n' "$*" >&2
    exit 1
}

if [ "$#" -eq 1 ]; then
    case "$1" in -h|--help) usage; exit 0 ;; esac
fi
[ "$#" -le 2 ] || { usage; die 'Expected at most an installation folder and output filename.'; }
command -v zip >/dev/null 2>&1 || die 'The zip command is missing. Install the zip package from your distribution, then run this script again.'
# Keep ZIPOPT from changing compression or adding unrelated files.
unset ZIPOPT

if [ "$#" -ge 1 ]; then
    root=$(realpath -e -- "$1") || die 'The Thief II installation folder does not exist.'
else
    script_path=$(realpath -e -- "$0") || die 'Cannot locate this script.'
    root=$(dirname -- "$script_path")
fi
[ -d "$root" ] || die 'The Thief II installation path must be a folder.'
output=${2:-"$root/Thief2-VR-assets.zip"}
case "$output" in *.[zZ][iI][pP]) ;; *) die 'The output filename must end in .zip.' ;; esac
output_dir=$(CDPATH= cd -P -- "$(dirname -- "$output")" && pwd) || die 'The output folder does not exist.'
output="$output_dir/$(basename -- "$output")"
[ ! -e "$output" ] && [ ! -L "$output" ] || die "ZIP already exists: $output. Move it aside or choose a different output filename."

# Resolve retail paths case-insensitively on Linux, one component at a time.
lookup() (
    current=$root
    remaining=$1
    while [ -n "$remaining" ]; do
        case "$remaining" in
            */*) part=${remaining%%/*}; remaining=${remaining#*/} ;;
            *) part=$remaining; remaining= ;;
        esac
        [ -d "$current" ] || exit 0
        match=$(find "$current" -mindepth 1 -maxdepth 1 -printf '%f\n' |
            awk -v wanted="$part" 'tolower($0) == tolower(wanted) { name=$0; count++ }
                END { if (count > 1) exit 1; if (count) print name }') ||
            die "Conflicting filename capitalization: $1"
        [ -n "$match" ] || exit 0
        current="$current/$match"
    done
    resolved=$(realpath -e -- "$current") || die "Cannot resolve game path: $1"
    case "$resolved" in "$root"|"$root"/*) ;; *) die "Asset path is outside the Thief II folder: $1" ;; esac
    printf '%s\n' "$current"
)

validate_name() {
    case "$1" in
        ''|/*|*/|*//*|.|..|./*|../*|*/./*|*/../*|*/.|*/..) die "Unsupported game file path: $1" ;;
    esac
    printf '%s\n' "$1" | awk '
        /[[:cntrl:]:#?\\]/ { bad=1 }
        END { if (NR != 1 || bad) exit 1 }' || die "Unsupported game file path: $1"
}

work_dir=$(mktemp -d "$output_dir/.thief2-vr-pack.XXXXXX") || die 'Cannot create the temporary package folder.'
cleanup() {
    # Only remove the temporary directory created above, inside the output folder.
    case "$work_dir" in "$output_dir"/.thief2-vr-pack.*) rm -rf -- "$work_dir" ;; esac
}
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
payload_dir="$work_dir/files"
plan="$work_dir/files.tsv"
mkdir -- "$payload_dir"
: > "$plan"

add_file() (
    source=$1
    validate_name "$2"
    name=$(printf '%s' "$2" | LC_ALL=C tr '[:upper:]' '[:lower:]')
    [ -f "$source" ] && [ ! -L "$source" ] || die "Not a regular game file: $name"
    resolved=$(realpath -e -- "$source") || die "Cannot resolve game file: $name"
    case "$resolved" in "$root"/*) ;; *) die "Asset path is outside the Thief II folder: $name" ;; esac
    destination="$payload_dir/$name"
    [ ! -e "$destination" ] || exit 0
    mkdir -p -- "$(dirname -- "$destination")"
    stamp=$(stat -c '%s:%Y:%y' -- "$source")
    size=${stamp%%:*}
    # Hard links avoid copying the large CRFs. Copy when filesystems differ.
    ln -- "$source" "$destination" 2>/dev/null || cp -p -- "$source" "$destination"
    [ "$stamp" = "$(stat -c '%s:%Y:%y' -- "$source")" ] || die "Game file changed while packing: $name"
    [ "$stamp" = "$(stat -c '%s:%Y:%y' -- "$destination")" ] || die "Incomplete game file: $name"
    printf '%s\t%s\t%s\n' "$name" "$size" "$stamp" >> "$plan"
    printf 'Packing %s\n' "$name"
)

missing=
for name in MISS1.MIS DARK.GAM motiondb.bin \
    RES/fam.crf RES/obj.crf RES/mesh.crf RES/motions.crf \
    RES/pal.crf RES/snd.crf RES/song.crf; do
    source=$(lookup "$name")
    case "$name" in RES/*) [ -n "$source" ] || source=$(lookup "${name#RES/}") ;; esac
    if [ -z "$source" ] || [ ! -f "$source" ]; then
        missing="${missing}${missing:+, }$name"
    else
        add_file "$source" "$name"
    fi
done
[ -z "$missing" ] || die "Missing required game files: $missing. Run this script in your Thief II installation folder."

# Include the same optional mission DML and configured sky assets as Windows.
mods="$work_dir/mods.txt"
printf '\n' > "$mods"
cam_mod=$(lookup cam_mod.ini)
if [ -n "$cam_mod" ] && [ -f "$cam_mod" ]; then
    add_file "$cam_mod" cam_mod.ini
    awk '
        {
            line=$0
            sub(/^\357\273\277/, "", line)
            sub(/;.*/, "", line)
            sub(/^[[:space:]]+/, "", line)
            if (tolower(line) !~ /^(uber_mod_path|mod_path)[[:space:]]+/) next
            sub(/^[^[:space:]]+[[:space:]]+/, "", line)
            gsub(/\\/, "/", line)
            count=split(line, paths, /\+/)
            for (i=1; i<=count; i++) {
                path=paths[i]
                sub(/^[[:space:]]+/, "", path)
                sub(/[[:space:]]+$/, "", path)
                sub(/^\.\//, "", path)
                sub(/\/+$/, "", path)
                if (path != "") print path
            }
        }' "$cam_mod" >> "$mods"
fi
sort -fu "$mods" > "$work_dir/unique-mods.txt"
while IFS= read -r directory; do
    case "$directory" in
        /*|*:*|..|../*|*/../*|*/..)
            printf 'Warning: skipping sky mod outside the game folder: %s\n' "$directory" >&2
            continue ;;
    esac
    if [ -n "$directory" ]; then
        validate_name "$directory"
        mod_root=$(lookup "$directory")
        prefix="$directory/"
    else
        mod_root=$root
        prefix=
    fi
    [ -n "$mod_root" ] && [ -d "$mod_root" ] || continue
    for dml in miss_all.dml miss1.mis.dml; do
        source=$(lookup "$prefix$dml")
        if [ -n "$source" ] && [ -f "$source" ]; then
            add_file "$source" "$prefix$dml"
        fi
    done
    sky=$(lookup "${prefix}fam/skyhw")
    if [ -n "$sky" ] && [ -d "$sky" ]; then
        find "$sky" -type f \( -iname '*.dds' -o -iname '*.tga' -o -iname '*.pcx' \) -print |
            sort | while IFS= read -r image; do
                add_file "$image" "${image#"$root"/}"
            done
    fi
done < "$work_dir/unique-mods.txt"

created=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
awk -F '\t' -v created="$created" '
    function quote(value, result, i, character) {
        result="\""
        for (i=1; i<=length(value); i++) {
            character=substr(value, i, 1)
            if (character == "\"" || character == "\\") result=result "\\"
            result=result character
        }
        return result "\""
    }
    BEGIN {
        printf "{\"format\":\"thief2-vr-assets\",\"version\":1,\"mission\":\"MISS1.MIS\",\"createdUtc\":%s,\"files\":[", quote(created)
    }
    {
        total+=$2
        printf "%s{\"path\":%s,\"size\":%.0f}", (NR > 1 ? "," : ""), quote($1), $2
    }
    END {
        if (NR >= 4096 || total + 4194304 > 2147483648) {
            print "This first-mission package exceeds the 2 GiB limit." > "/dev/stderr"
            exit 1
        }
        print "]}"
    }' "$plan" > "$payload_dir/manifest.json" || die 'The game package is too large.'
[ "$(stat -c '%s' -- "$payload_dir/manifest.json")" -le 1048576 ] || die 'The package file list is too large.'

archive="$work_dir/package.zip"
printf '%s\n' 'Creating the game ZIP...'
(
    cd -- "$payload_dir"
    # Only these files are included; every entry uses ZIP method 0 (STORE).
    { cut -f 1 "$plan"; printf 'manifest.json\n'; } |
        zip -q -0 -X -MM -nw -UN=UTF8 "$archive" -@
) || die 'The zip command could not create the game package.'
[ "$(stat -c '%s' -- "$archive")" -le 2147483648 ] || die 'This first-mission package exceeds the 2 GiB limit.'
while IFS="$(printf '\t')" read -r name size stamp; do
    [ "$stamp" = "$(stat -c '%s:%Y:%y' -- "$payload_dir/$name")" ] || die "Game file changed while packing: $name"
done < "$plan"

# The archive and output are on the same filesystem; do not replace any file.
mv -nT -- "$archive" "$output" || die "Cannot save the ZIP: $output"
[ ! -e "$archive" ] || die "ZIP already exists: $output. Move it aside or choose a different output filename."
printf '\nReady: %s\n' "$output"
printf '%s\n' 'Choose this ZIP on the Thief II VR page. For standalone Quest, copy it to the headset first.'
