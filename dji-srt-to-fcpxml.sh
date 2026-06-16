#!/usr/bin/env bash
#
# dji-srt-to-fcpxml.sh
#
# Reads the DJI .SRT telemetry sidecar next to each .MP4 clip in a folder and
# writes a single DJI_metadata.fcpxml. Import that file into Final Cut Pro
# (File > Import > XML…) and every clip arrives with its camera settings —
# ISO, shutter, aperture, color profile, focal length — attached as searchable
# keywords (each becomes a filterable Keyword Collection in the browser).
#
# Usage: dji-srt-to-fcpxml.sh <folder>
#
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") <folder>

  <folder>  Directory containing DJI .MP4 files and their matching .SRT sidecars.

Writes <folder>/DJI_metadata.fcpxml. Import it into Final Cut via
File > Import > XML…  — it references the original MP4s in place (no copy).
EOF
}

# --- tool checks --------------------------------------------------------------
missing=()
command -v ffprobe >/dev/null 2>&1 || missing+=("ffprobe  — install with: brew install ffmpeg")
command -v awk     >/dev/null 2>&1 || missing+=("awk")
if [ ${#missing[@]} -gt 0 ]; then
  echo "Error: required tool(s) not found:" >&2
  for m in "${missing[@]}"; do echo "  - $m" >&2; done
  exit 1
fi

# --- args ---------------------------------------------------------------------
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
if [ $# -ne 1 ]; then usage >&2; exit 2; fi
folder="$1"
if [ ! -d "$folder" ]; then echo "Error: not a directory: $folder" >&2; exit 2; fi
folder="$(cd "$folder" && pwd -P)"

# --- helpers ------------------------------------------------------------------

# Map DJI color_md token to a human-readable label; unknown values pass through.
map_color() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    dlog_m|d-log-m|d_log_m)      echo "D-LogM" ;;
    dlog|d-log|d_log)            echo "D-Log" ;;
    d_cinelike|d-cinelike|dcinelike) echo "D-Cinelike" ;;
    hlg)                         echo "HLG" ;;
    normal|none|"")              echo "Normal" ;;
    *)                           echo "$1" ;;
  esac
}

# Map a focal length (mm) to a lens/camera-module name. DJI multi-camera drones
# expose a fixed set of focal lengths, one per physical lens. Empty if unknown.
map_lens() {
  local f="${1%%.*}"   # integer part
  case "$f" in (''|*[!0-9]*) echo ""; return ;; esac
  if   [ "$f" -le 35 ];  then echo "Wide"
  elif [ "$f" -le 100 ]; then echo "Medium Tele"
  else                        echo "Tele"
  fi
}

# Escape the five XML-significant characters.
xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
                         -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

# Percent-encode the bits of a path that break a file:// URL.
url_path() {
  printf '%s' "$1" | sed -e 's/%/%25/g' -e 's/ /%20/g' -e "s/'/%27/g" \
                         -e 's/#/%23/g' -e 's/?/%3F/g'
}

# Parse one .SRT: print shell-assignable key=value lines summarising the clip.
# Exits 3 if the file holds no telemetry lines.
parse_srt() {
  awk '
    function field(line, key,   re, s) {
      re = "\\[" key ": [^]]*\\]"
      if (match(line, re)) {
        s = substr(line, RSTART, RLENGTH)
        sub("\\[" key ": ", "", s)
        sub("\\]$", "", s)
        return s
      }
      return ""
    }
    function mode(arr,   k, bestk, bestv) {
      bestv = -1
      for (k in arr) if (arr[k] > bestv) { bestv = arr[k]; bestk = k }
      return bestk
    }
    /\[iso:/ {
      iso = field($0, "iso"); sh = field($0, "shutter"); fn = field($0, "fnum")
      cm  = field($0, "color_md"); fl = field($0, "focal_len")
      ct  = field($0, "ct"); sub(/,.*/, "", ct)   # "[ct: 6003, tint: 10]" -> 6003
      if (iso != "") {
        isocount[iso]++; n++
        v = iso + 0
        if (isomin == "" || v < isomin) isomin = v
        if (v > isomax) isomax = v
      }
      if (sh != "") shc[sh]++
      if (fn != "") fnc[fn]++
      if (cm != "") cmc[cm]++
      if (fl != "") flc[fl]++
      if (ct != "") ctc[ct]++
    }
    END {
      if (n == 0) exit 3
      sh = mode(shc); fl = mode(flc)
      sub(/\.0+$/, "", sh)   # 1/60.0 -> 1/60
      sub(/\.0+$/, "", fl)   # 28.00  -> 28
      print "iso_dom=" mode(isocount)
      print "iso_min=" isomin
      print "iso_max=" isomax
      print "shutter=" sh
      print "fnum="    mode(fnc)
      print "color="   mode(cmc)
      print "focal="   fl
      print "ct="      mode(ctc)
    }
  ' "$1"
}

# --- main ---------------------------------------------------------------------
fcpxml="$folder/DJI_metadata.fcpxml"
res_tmp="$(mktemp)"; clip_tmp="$(mktemp)"
trap 'rm -f "$res_tmp" "$clip_tmp"' EXIT

rid=1
count=0
skipped=0

shopt -s nullglob nocaseglob
for mp4 in "$folder"/*.mp4; do
  name="$(basename "$mp4")"
  stem="${name%.*}"

  # Locate the sibling SRT (DJI ships them uppercased).
  srt="$folder/$stem.SRT"
  [ -f "$srt" ] || srt="$folder/$stem.srt"
  if [ ! -f "$srt" ]; then
    echo "skip (no SRT):        $name" >&2
    skipped=$((skipped + 1)); continue
  fi

  # Camera settings from the SRT.
  if ! srt_out="$(parse_srt "$srt")"; then
    echo "skip (empty SRT):     $name" >&2
    skipped=$((skipped + 1)); continue
  fi
  eval "$srt_out"

  # Technical facts from the MP4.
  vinfo="$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=width,height,r_frame_rate,nb_frames \
            -of csv=p=0 "$mp4" 2>/dev/null)" || vinfo=""
  if [ -z "$vinfo" ]; then
    echo "skip (ffprobe fail):  $name" >&2
    skipped=$((skipped + 1)); continue
  fi
  IFS=, read -r w h rfr nbf <<<"$vinfo"
  dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$mp4" 2>/dev/null)" || dur=""
  ach="$(ffprobe -v error -select_streams a:0 -show_entries stream=channels,sample_rate \
          -of csv=p=0 "$mp4" 2>/dev/null)" || ach=""

  # Frame rate as a rational (r_frame_rate is "num/den", e.g. 60000/1001).
  num="${rfr%%/*}"; den="${rfr##*/}"
  { [ -n "$num" ] && [ "$num" != "0" ]; } || { num=30; den=1; }
  { [ -n "$den" ] && [ "$den" != "0" ]; } || den=1

  # Frame count: trust nb_frames if numeric, else derive from duration * fps.
  if printf '%s' "$nbf" | grep -Eq '^[0-9]+$'; then
    N="$nbf"
  else
    N="$(awk -v d="${dur:-0}" -v n="$num" -v e="$den" \
         'BEGIN { if (d + 0 <= 0) print 0; else printf "%d", d * n / e + 0.5 }')"
  fi
  if ! [ "$N" -gt 0 ] 2>/dev/null; then N=1; fi

  # FCPXML rational times: frameDuration = den/num s; total = N*den/num s.
  fdur="${den}/${num}s"
  tdur="$((N * den))/${num}s"

  # Build the keyword list (the five facts you asked for).
  cprof="$(map_color "$color")"
  lens="$(map_lens "$focal")"
  if   [ -n "$lens" ] && [ -n "$focal" ]; then camname="$lens (${focal}mm)"
  elif [ -n "$focal" ];                   then camname="${focal}mm"
  else                                         camname=""
  fi
  # Keywords: only the facts with no safe native FCP field (plus ISO range,
  # which the single-value ISO field can't represent).
  kws=()
  if [ "$iso_min" != "$iso_max" ]; then kws+=("ISO ${iso_min}-${iso_max}"); fi
  [ -n "$shutter" ] && kws+=("${shutter}s")
  [ -n "$fnum" ]    && kws+=("f/${fnum}")
  [ -n "$cprof" ]   && kws+=("$cprof")

  # Emit resources (a self-contained format + asset per clip) and the clip.
  fmt_id="r$rid"; rid=$((rid + 1))
  asset_id="r$rid"; rid=$((rid + 1))
  url="file://$(url_path "$mp4")"
  xname="$(xml_escape "$stem")"

  printf '    <format id="%s" name="DJIFormat_%sx%s_%s" frameDuration="%s" width="%s" height="%s"/>\n' \
    "$fmt_id" "$w" "$h" "$rid" "$fdur" "$w" "$h" >> "$res_tmp"

  audio_attrs=""
  if [ -n "$ach" ]; then
    achan="${ach%%,*}"; arate="${ach##*,}"
    [ -n "$achan" ] || achan=2
    [ -n "$arate" ] || arate=48000
    audio_attrs=" hasAudio=\"1\" audioSources=\"1\" audioChannels=\"$achan\" audioRate=\"$arate\""
  fi
  printf '    <asset id="%s" name="%s" start="0s" duration="%s" hasVideo="1" videoSources="1" format="%s"%s>\n' \
    "$asset_id" "$xname" "$tdur" "$fmt_id" "$audio_attrs" >> "$res_tmp"
  printf '      <media-rep kind="original-media" src="%s"/>\n' "$url" >> "$res_tmp"
  # Native FCP metadata fields (these start empty on import, so ours stick).
  printf '      <metadata>\n' >> "$res_tmp"
  if [ -n "$camname" ]; then
    printf '        <md key="com.apple.proapps.mio.cameraName" value="%s"/>\n' \
      "$(xml_escape "$camname")" >> "$res_tmp"
  fi
  printf '        <md key="com.apple.proapps.studio.cameraISO" value="%s"/>\n' \
    "$(xml_escape "$iso_dom")" >> "$res_tmp"
  if [ -n "$ct" ]; then
    printf '        <md key="com.apple.proapps.studio.cameraColorTemperature" value="%s"/>\n' \
      "$(xml_escape "$ct")" >> "$res_tmp"
  fi
  printf '      </metadata>\n' >> "$res_tmp"
  printf '    </asset>\n' >> "$res_tmp"

  printf '      <asset-clip ref="%s" name="%s" start="0s" duration="%s" format="%s" tcFormat="NDF">\n' \
    "$asset_id" "$xname" "$tdur" "$fmt_id" >> "$clip_tmp"
  for kw in "${kws[@]}"; do
    printf '        <keyword start="0s" duration="%s" value="%s"/>\n' \
      "$tdur" "$(xml_escape "$kw")" >> "$clip_tmp"
  done
  printf '      </asset-clip>\n' >> "$clip_tmp"

  if [ "$iso_min" != "$iso_max" ]; then isokw=" ISO${iso_min}-${iso_max}"; else isokw=""; fi
  printf 'ok: %-30s fields[lens=%s ISO=%s ct=%s] keywords[%ss f/%s %s%s]\n' \
    "$name" "$camname" "$iso_dom" "${ct:-n/a}" "$shutter" "$fnum" "$cprof" "$isokw"
  count=$((count + 1))
done

if [ "$count" -eq 0 ]; then
  echo "No clips with SRT telemetry found in: $folder" >&2
  exit 1
fi

{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<!DOCTYPE fcpxml>'
  echo '<fcpxml version="1.10">'
  echo '  <resources>'
  cat "$res_tmp"
  echo '  </resources>'
  echo '  <event name="DJI Metadata">'
  cat "$clip_tmp"
  echo '  </event>'
  echo '</fcpxml>'
} > "$fcpxml"

echo
echo "Wrote: $fcpxml"
echo "Clips: $count   Skipped: $skipped"
echo "Import into Final Cut:  File > Import > XML…  (select the .fcpxml)"
