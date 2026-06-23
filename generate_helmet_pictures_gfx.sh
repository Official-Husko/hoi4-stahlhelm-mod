#!/usr/bin/env bash
# Builds the helmet equipment pictures end to end:
#   1. Resizes every PNG under gfx/interface/STH_equipment_pictures/helmets/
#      to a fixed TARGET_WIDTH x TARGET_HEIGHT canvas, in place. Aspect
#      ratio is preserved (no stretching) - the image is scaled to fit
#      within the canvas, then centered on a fully transparent background
#      to fill out the rest.
#   2. Converts each (now fixed-size) PNG to DDS in place via todds
#      (foo.png -> foo.dds, same name/folder). BC3 (block compression)
#      hard-requires both dimensions to be multiples of 4, and 54 isn't -
#      so the DDS file's own header will report 56, not 54 (--fix-size
#      rounds up rather than crashing on encode). The extra 2px is fully
#      transparent padding centered by step 1, so it's not visible in
#      game - there is no way to get an exact 164x54 *and* use a
#      block-compressed DDS format; the rounding is mandatory for BC3.
#      Mipmaps are left enabled (no --no-mipmaps) because todds 0.4.1 has
#      a known crash when --no-mipmaps is combined with --fix-size on a
#      non-multiple-of-4 source - mipmaps are unused/harmless extra data
#      for a static UI icon anyway.
#   3. Regenerates interface/replace/STH_Helmet_Equipment_Pictures.gfx by
#      scanning that same folder for *.dds files. Each numbered file (e.g.
#      m16_01.dds) gets its own sprite, used by the engine's automatic
#      cosmetic-variety rotation in equipment/unit lists. The
#      alphabetically-first file in each folder (_01) additionally gets a
#      "_medium"-suffixed sprite with no number - that's the canonical
#      single-icon name the engine looks up by default (equipment
#      "picture = " field, production queue, and - if a tech doesn't
#      define its own icon - the research tree, which falls back to
#      whatever icon its unlocked equipment uses). So _01 is the de facto
#      main/default image for a given helmet everywhere only one icon is
#      shown; 02-10 only ever appear in list-rotation contexts.
#   4. Regenerates the Equipment Designer icon-picker registry at
#      gfx/interface/equipmentdesigner/graphic_db/STH_helmet_icons.txt,
#      registering all 10 numbered sprites per variant as separate,
#      equally-weighted pools the player can browse/choose between in the
#      designer's icon picker (see interface/equipmentdesigner/
#      STH_helmet_equipment.gui for the designer layout itself).
#   5. Seeds localisation/english/STH_l_english.yml with a placeholder
#      STH_helmet_equipment_<suffix> line for any helmet folder that doesn't
#      have one yet, derived from the folder name (e.g. m45_prototype ->
#      "Stahlhelm M45 Prototype #N") so no helmet is left without a display
#      name. The trailing " #N" flags it as a placeholder still needing a
#      real name (and _short/_desc, which this step doesn't generate) - N
#      keeps counting up from whatever placeholder numbers already exist in
#      the file. Existing lines, placeholder or hand-written, are never
#      touched.
#   6. Seeds localisation/english/STH_helmet_icon_names_l_english.yml with
#      one entry per icon, keyed by its exact GFX_ sprite name - the
#      designer's icon-picker tooltip has no field of its own to set a
#      name, it falls back to displaying the raw, untranslated loc key
#      (i.e. the literal "GFX_STH_helmet_equipment_m35_01" sprite name) when
#      no translation exists, which is the "internal name" you see in the
#      picker. This step only ever appends missing keys with a generic
#      default ("<Helmet Name> #N") - it never touches a key that's already
#      in the file, so you can freely hand-edit any entry (e.g. to "M35
#      Normandy Camo") and reruns won't overwrite your choice.
#
# Run this any time you add, replace, remove, or rename files under that
# folder - the resize, the DDS conversion, the equipment-pictures .gfx
# file, and the icon-picker registry are all fully derived from what's on
# disk, so none of them need to be hand-edited. The loc placeholders (steps
# 5 and 6) are the one exception - they're seeded automatically but meant
# to be hand-edited afterward.
set -euo pipefail

TARGET_WIDTH=164
TARGET_HEIGHT=54

MOD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELMETS_DIR="$MOD_ROOT/gfx/interface/STH_equipment_pictures/helmets"
OUT_FILE="$MOD_ROOT/interface/replace/STH_Helmet_Equipment_Pictures.gfx"

if [ ! -d "$HELMETS_DIR" ]; then
    echo "No helmet picture folder found at: $HELMETS_DIR" >&2
    exit 1
fi

# --- Step 1: resize/pad PNGs to a fixed canvas, then convert to DDS ---
# The originals under $HELMETS_DIR are never touched - resizing happens on
# copies in a temp scratch dir, and only the resulting .dds files are copied
# back next to the (untouched) source PNGs.

shopt -s nullglob globstar
pngs=("$HELMETS_DIR"/**/*.png)
shopt -u nullglob globstar

if [ ${#pngs[@]} -eq 0 ]; then
    echo "No PNG files found under $HELMETS_DIR - skipping conversion."
else
    if ! command -v magick >/dev/null 2>&1; then
        echo "ImageMagick (magick) not found on PATH - install it to enable resizing." >&2
        exit 1
    fi
    if ! command -v todds >/dev/null 2>&1; then
        echo "todds not found on PATH - install it from https://github.com/joaodicastro/todds" >&2
        exit 1
    fi

    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMP_DIR"' EXIT

    for f in "${pngs[@]}"; do
        rel="${f#"$HELMETS_DIR"/}"
        tmp_f="$TMP_DIR/$rel"
        mkdir -p "$(dirname "$tmp_f")"
        magick "$f" \
            -resize "${TARGET_WIDTH}x${TARGET_HEIGHT}" \
            -background none \
            -gravity center \
            -extent "${TARGET_WIDTH}x${TARGET_HEIGHT}" \
            "$tmp_f"
    done
    echo "Resized ${#pngs[@]} PNG file(s) to ${TARGET_WIDTH}x${TARGET_HEIGHT} (originals untouched)."

    todds \
        --format BC3 \
        --fix-size \
        --overwrite \
        --progress \
        "$TMP_DIR"

    shopt -s nullglob globstar
    tmp_dds=("$TMP_DIR"/**/*.dds)
    shopt -u nullglob globstar

    for f in "${tmp_dds[@]}"; do
        rel="${f#"$TMP_DIR"/}"
        dest="$HELMETS_DIR/$rel"
        mkdir -p "$(dirname "$dest")"
        cp "$f" "$dest"
    done

    rm -rf "$TMP_DIR"
    trap - EXIT

    echo "Converted ${#pngs[@]} PNG file(s) under $HELMETS_DIR to DDS."
fi

# --- Step 2: regenerate the .gfx file from whatever .dds files exist now ---

{
    echo "# Auto-generated by generate_helmet_pictures_gfx.sh - do not hand-edit."
    echo "# Re-run that script after adding/removing/renaming files under"
    echo "# gfx/interface/STH_equipment_pictures/helmets/ to regenerate this file."
    echo "spriteTypes = {"

    for dir in "$HELMETS_DIR"/*/; do
        [ -d "$dir" ] || continue
        suffix="$(basename "$dir")"

        shopt -s nullglob
        files=("$dir"*.dds)
        shopt -u nullglob
        [ ${#files[@]} -eq 0 ] && continue

        sorted=()
        while IFS= read -r line; do
            sorted+=("$line")
        done < <(printf '%s\n' "${files[@]}" | sort)

        echo ""
        echo -e "\t# --- helmet_equipment_${suffix} ---"

        first_fname="$(basename "${sorted[0]}")"
        first_rel_path="gfx/interface/STH_equipment_pictures/helmets/${suffix}/${first_fname}"
        echo -e "\t# Canonical default/main image (production, equipment list, and"
        echo -e "\t# research tree icon borrowing all look this up by default)."
        echo -e "\tSpriteType = {"
        echo -e "\t\tname = \"GFX_STH_helmet_equipment_${suffix}_medium\""
        echo -e "\t\ttexturefile = \"${first_rel_path}\""
        echo -e "\t}"

        for f in "${sorted[@]}"; do
            fname="$(basename "$f")"
            name_no_ext="${fname%.dds}"
            rel_path="gfx/interface/STH_equipment_pictures/helmets/${suffix}/${fname}"
            echo -e "\tSpriteType = {"
            echo -e "\t\tname = \"GFX_STH_helmet_equipment_${name_no_ext}\""
            echo -e "\t\ttexturefile = \"${rel_path}\""
            echo -e "\t}"
        done
    done

    echo ""
    echo "}"
} > "$OUT_FILE"

count=$(grep -c "SpriteType = {" "$OUT_FILE")
echo "Wrote $count SpriteType entries to $OUT_FILE"

# --- Step 3: regenerate the Equipment Designer icon-picker registry ---

GRAPHIC_DB_FILE="$MOD_ROOT/gfx/interface/equipmentdesigner/graphic_db/STH_helmet_icons.txt"
mkdir -p "$(dirname "$GRAPHIC_DB_FILE")"

{
    echo "# Auto-generated by generate_helmet_pictures_gfx.sh - do not hand-edit."
    echo "# Registers each helmet variant's 10 numbered pictures as separate,"
    echo "# equally-weighted pools so the player can browse/choose between them"
    echo "# in the Equipment Designer's icon picker."
    echo "default = {"

    for dir in "$HELMETS_DIR"/*/; do
        [ -d "$dir" ] || continue
        suffix="$(basename "$dir")"

        shopt -s nullglob
        files=("$dir"*.dds)
        shopt -u nullglob
        [ ${#files[@]} -eq 0 ] && continue

        sorted=()
        while IFS= read -r line; do
            sorted+=("$line")
        done < <(printf '%s\n' "${files[@]}" | sort)

        echo ""
        echo -e "\tSTH_helmet_equipment_${suffix} = {"
        for f in "${sorted[@]}"; do
            fname="$(basename "$f")"
            name_no_ext="${fname%.dds}"
            echo -e "\t\tpool = {"
            echo -e "\t\t\tweight = 1"
            echo -e "\t\t\ticons = { GFX_STH_helmet_equipment_${name_no_ext} }"
            echo -e "\t\t}"
        done
        echo -e "\t}"
    done

    echo ""
    echo "}"
} > "$GRAPHIC_DB_FILE"

pool_count=$(grep -c "pool = {" "$GRAPHIC_DB_FILE")
echo "Wrote $pool_count icon pool entries to $GRAPHIC_DB_FILE"

# --- Step 4: seed missing base helmet-name loc lines (hand-edit afterward, never overwritten) ---
# If a helmet folder has no STH_helmet_equipment_<suffix> line yet in the main loc
# file, append a placeholder derived from the folder name (e.g. m45_prototype ->
# "Stahlhelm M45 Prototype") so nothing is left nameless. The trailing " #N" marks
# it as a placeholder still needing a real name/description - N keeps counting up
# from whatever's already in the file, so re-runs never reuse or collide with a
# number you've already seen. Existing lines (placeholder or hand-written) are
# never modified or removed.

BASE_LOC_FILE="$MOD_ROOT/localisation/english/STH_l_english.yml"

last_num="$(grep -oP '(?<= #)[0-9]+(?=")' "$BASE_LOC_FILE" 2>/dev/null | sort -n | tail -1)" || true
[ -z "$last_num" ] && last_num=0

new_base_count=0
for dir in "$HELMETS_DIR"/*/; do
    [ -d "$dir" ] || continue
    suffix="$(basename "$dir")"

    if grep -q "^ STH_helmet_equipment_${suffix}:0 \"" "$BASE_LOC_FILE"; then
        continue
    fi

    title="$(echo "$suffix" | tr '_' ' ' | sed -E 's/(^| )([a-z])/\1\u\2/g')"
    last_num=$((last_num + 1))
    printf ' STH_helmet_equipment_%s:0 "Stahlhelm %s #%d"\n' "$suffix" "$title" "$last_num" >> "$BASE_LOC_FILE"
    new_base_count=$((new_base_count + 1))
done

echo "Added $new_base_count placeholder helmet name(s) to $BASE_LOC_FILE (existing lines left untouched - edit freely)."

# --- Step 5: seed per-icon display names (hand-edit afterward, never overwritten) ---

ICON_NAMES_FILE="$MOD_ROOT/localisation/english/STH_helmet_icon_names_l_english.yml"
mkdir -p "$(dirname "$ICON_NAMES_FILE")"

if [ ! -f "$ICON_NAMES_FILE" ]; then
    # HOI4 loc files must be UTF-8 with a BOM, or the game logs an error (and may
    # crash with 0xC0000005 if the file's l_english: header was never seen with one).
    printf '\xEF\xBB\xBFl_english:\n' > "$ICON_NAMES_FILE"
fi

new_count=0
for dir in "$HELMETS_DIR"/*/; do
    [ -d "$dir" ] || continue
    suffix="$(basename "$dir")"

    shopt -s nullglob
    files=("$dir"*.dds)
    shopt -u nullglob
    [ ${#files[@]} -eq 0 ] && continue

    base_name="$(grep -oP "(?<=^ STH_helmet_equipment_${suffix}:0 \")[^\"]+" "$BASE_LOC_FILE" 2>/dev/null || true)"
    [ -z "$base_name" ] && base_name="$suffix"

    sorted=()
    while IFS= read -r line; do
        sorted+=("$line")
    done < <(printf '%s\n' "${files[@]}" | sort)

    for f in "${sorted[@]}"; do
        fname="$(basename "$f")"
        name_no_ext="${fname%.dds}"
        key="GFX_STH_helmet_equipment_${name_no_ext}"
        num="${name_no_ext##*_}"

        if ! grep -q "^ ${key}:" "$ICON_NAMES_FILE"; then
            printf ' %s:0 "%s #%s"\n' "$key" "$base_name" "$num" >> "$ICON_NAMES_FILE"
            new_count=$((new_count + 1))
        fi
    done
done

echo "Seeded $new_count new icon display-name localisation entries in $ICON_NAMES_FILE (existing entries left untouched - edit freely)."
