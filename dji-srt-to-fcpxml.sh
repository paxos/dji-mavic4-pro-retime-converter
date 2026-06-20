#!/usr/bin/env bash
#
# dji-srt-to-fcpxml.sh
#
# Reads the DJI .SRT telemetry sidecar next to each .MP4 clip in a folder and
# writes a self-contained output folder containing every clip plus a single
# DJI_metadata.fcpxml. Import that file into Final Cut Pro (File > Import > XML…)
# and every clip arrives with its camera settings — ISO, shutter, aperture,
# color profile, focal length — attached as searchable keywords (each becomes a
# filterable Keyword Collection in the browser).
#
# Slow-motion handling: DJI records 100/120 fps slow motion already "conformed"
# to 25/29.97 fps playback — the file plays slow at a normal frame rate. The SRT
# carries both a playback clock and a real-world capture clock; their ratio is
# the slow-motion factor. Conformed slow-motion clips are re-timestamped to their
# true frame rate (lossless container remux, no re-encode) so you can do your own
# speed-ramping in Final Cut. Normal clips are copied through untouched.
#
# Usage: dji-srt-to-fcpxml.sh <source-folder> [output-folder]
#
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") <source-folder> [output-folder]

  <source-folder>  Directory containing DJI .MP4 files and their matching .SRT sidecars.
  [output-folder]  Where to write results. Defaults to <source-folder>/converted.

Writes <output-folder>/DJI_metadata.fcpxml plus, in that same folder:
  - slow-motion clips re-timestamped to their true frame rate (100/120 fps),
  - normal clips copied through unchanged.
The output folder is self-contained — the FCPXML references the clips inside it,
so the source folder can be deleted afterward. Import via File > Import > XML…
EOF
}

# --- tool checks --------------------------------------------------------------
missing=()
command -v ffprobe >/dev/null 2>&1 || missing+=("ffprobe  — install with: brew install ffmpeg")
command -v ffmpeg  >/dev/null 2>&1 || missing+=("ffmpeg   — install with: brew install ffmpeg")
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
if [ $# -lt 1 ] || [ $# -gt 2 ]; then usage >&2; exit 2; fi
folder="$1"
if [ ! -d "$folder" ]; then echo "Error: not a directory: $folder" >&2; exit 2; fi
folder="$(cd "$folder" && pwd -P)"

outdir="${2:-$folder/converted}"
mkdir -p "$outdir"
outdir="$(cd "$outdir" && pwd -P)"
if [ "$outdir" = "$folder" ]; then
  echo "Error: output folder must differ from the source folder (it would overwrite originals)." >&2
  exit 2
fi

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
#
# Emits the camera-field summary plus the slow-motion factor, derived from the
# two clocks every DJI SRT carries:
#   - playback clock: the "00:00:00,000 --> 00:00:00,033" subtitle timecodes,
#   - capture clock:  the "YYYY-MM-DD HH:MM:SS.mmm" wall-clock line (real time).
# factor = round(playback_span / real_span); ~1 for normal clips, 4 for slow-mo.
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
    # "HH:MM:SS,mmm" or "HH:MM:SS.mmm" (or without millis) -> seconds.
    function tcsec(tc,   t, a) {
      t = tc; gsub(/[,.]/, ":", t); split(t, a, ":")
      return a[1] * 3600 + a[2] * 60 + a[3] + (a[4] != "" ? a[4] / 1000 : 0)
    }
    / --> / { pb_end = $3 }                              # playback end timecode
    /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] / {     # wall-clock line
      if (first_wc == "") first_wc = $2
      last_wc = $2
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

      # Slow-motion factor from the two clocks.
      pb = (pb_end != "" ? tcsec(pb_end) : 0)
      rs = 0
      if (first_wc != "" && last_wc != "") {
        rs = tcsec(last_wc) - tcsec(first_wc)
        if (rs < 0) rs += 86400          # crossed midnight
      }
      factor = 1
      if (rs > 0 && pb > 0) {
        factor = int(pb / rs + 0.5)
        if (factor < 1) factor = 1
      }
      print "srt_factor=" factor
      printf "srt_pb=%.3f\n", pb
      printf "srt_real=%.3f\n", rs
    }
  ' "$1"
}

# --- main ---------------------------------------------------------------------
fcpxml="$outdir/DJI_metadata.fcpxml"
res_tmp="$(mktemp)"; clip_tmp="$(mktemp)"
trap 'rm -f "$res_tmp" "$clip_tmp"' EXIT

rid=1
count=0
skipped=0
slowcount=0

shopt -s nullglob nocaseglob
for mp4 in "$folder"/*.mp4; do
  name="$(basename "$mp4")"
  stem="${name%.*}"

  # Locate the sibling SRT in the SOURCE folder (DJI ships them uppercased).
  srt="$folder/$stem.SRT"
  [ -f "$srt" ] || srt="$folder/$stem.srt"
  if [ ! -f "$srt" ]; then
    echo "skip (no SRT):        $name" >&2
    skipped=$((skipped + 1)); continue
  fi

  # Camera settings + slow-motion factor from the SRT.
  if ! srt_out="$(parse_srt "$srt")"; then
    echo "skip (empty SRT):     $name" >&2
    skipped=$((skipped + 1)); continue
  fi
  eval "$srt_out"

  # Produce the clip in the output folder: retime slow motion to true fps
  # (lossless, video-only remux), or copy a normal clip through unchanged.
  out_mp4="$outdir/$name"
  slowmo=0
  if [ "${srt_factor:-1}" -ge 2 ]; then
    inv="$(awk -v f="$srt_factor" 'BEGIN { printf "%.10f", 1.0 / f }')"
    if ! ffmpeg -y -loglevel error -itsscale "$inv" -i "$mp4" \
           -map 0:v:0 -c:v copy "$out_mp4" 2>/dev/null; then
      echo "skip (retime failed): $name" >&2
      rm -f "$out_mp4"; skipped=$((skipped + 1)); continue
    fi
    slowmo=1
  else
    if ! cp -f "$mp4" "$out_mp4"; then
      echo "skip (copy failed):   $name" >&2
      skipped=$((skipped + 1)); continue
    fi
  fi

  # Technical facts from the OUTPUT file (so retimed fps/duration are correct).
  vinfo="$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=width,height,r_frame_rate,nb_frames \
            -of csv=p=0 "$out_mp4" 2>/dev/null)" || vinfo=""
  if [ -z "$vinfo" ]; then
    echo "skip (ffprobe fail):  $name" >&2
    rm -f "$out_mp4"; skipped=$((skipped + 1)); continue
  fi
  IFS=, read -r w h rfr nbf <<<"$vinfo"
  dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$out_mp4" 2>/dev/null)" || dur=""
  ach="$(ffprobe -v error -select_streams a:0 -show_entries stream=channels,sample_rate \
          -of csv=p=0 "$out_mp4" 2>/dev/null)" || ach=""

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

  # True (display) fps as a rounded integer, for the slow-motion keyword.
  truefps="$(awk -v n="$num" -v e="$den" 'BEGIN { if (e + 0 > 0) printf "%d", n / e + 0.5; else print 0 }')"

  # Build the keyword list.
  cprof="$(map_color "$color")"
  lens="$(map_lens "$focal")"
  if   [ -n "$lens" ] && [ -n "$focal" ]; then camname="$lens (${focal}mm)"
  elif [ -n "$focal" ];                   then camname="${focal}mm"
  else                                         camname=""
  fi
  # Keywords: only the facts with no safe native FCP field (plus ISO range,
  # which the single-value ISO field can't represent).
  kws=()
  if [ "$slowmo" -eq 1 ]; then
    kws+=("Slow Motion")
    if [ "${truefps:-0}" -gt 0 ] 2>/dev/null; then kws+=("${truefps}fps"); fi
  fi
  if [ "$iso_min" != "$iso_max" ]; then kws+=("ISO ${iso_min}-${iso_max}"); fi
  [ -n "$shutter" ] && kws+=("${shutter}s")
  [ -n "$fnum" ]    && kws+=("f/${fnum}")
  [ -n "$cprof" ]   && kws+=("$cprof")

  # Emit resources (a self-contained format + asset per clip) and the clip.
  fmt_id="r$rid"; rid=$((rid + 1))
  asset_id="r$rid"; rid=$((rid + 1))
  url="file://$(url_path "$out_mp4")"
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
  if [ "$slowmo" -eq 1 ]; then
    printf 'ok slowmo %sx -> %sfps: %-26s keywords[%ss f/%s %s%s]\n' \
      "$srt_factor" "$truefps" "$name" "$shutter" "$fnum" "$cprof" "$isokw"
    slowcount=$((slowcount + 1))
  else
    printf 'ok: %-30s fields[lens=%s ISO=%s ct=%s] keywords[%ss f/%s %s%s]\n' \
      "$name" "$camname" "$iso_dom" "${ct:-n/a}" "$shutter" "$fnum" "$cprof" "$isokw"
  fi
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
echo "Output folder: $outdir"
echo "Clips: $count   Slow-motion retimed: $slowcount   Skipped: $skipped"
echo "Import into Final Cut:  File > Import > XML…  (select the .fcpxml)"
