# DJI SRT → Final Cut Pro metadata

`dji-srt-to-fcpxml.sh` reads the DJI `.SRT` telemetry sidecar that ships next to
each `.MP4` clip and writes a self-contained **output folder** containing every
clip plus a single `DJI_metadata.fcpxml`. You import that file into Final Cut Pro
and every clip arrives with its camera settings attached — some as native
inspector fields, the rest as searchable keywords.

It does two things:

1. **Translates SRT telemetry into FCPXML.** Final Cut cannot read a DJI `.SRT`
   file, but it *can* import an FCPXML (Apple's documented interchange format).
   The script translates the telemetry into that format.
2. **Restores true-frame-rate slow motion.** DJI records 100/120 fps slow motion
   already "conformed" — the file holds every captured frame but is timestamped
   to play *slow* at a normal 25/29.97 fps. The script detects these clips and
   re-timestamps them to their real frame rate so you can do your own
   speed-ramping in Final Cut. This is a lossless container remux (no
   re-encode), so it is fast and quality-preserving.

## Usage

```bash
./dji-srt-to-fcpxml.sh <source-folder> [output-folder]
```

- `<source-folder>` holds the `.MP4` files and their matching `.SRT` sidecars
  (same basename, e.g. `DJI_..._0026_D.MP4` ↔ `DJI_..._0026_D.SRT`).
- `[output-folder]` is where results are written. Defaults to
  `<source-folder>/converted`. It must differ from the source folder.

The script writes into the output folder:

- **slow-motion clips** re-timestamped to their true frame rate (video track
  only — see below),
- **normal clips** copied through unchanged (full copies, not links),
- one **`DJI_metadata.fcpxml`** referencing the clips *inside that folder*.

Then in Final Cut: **File → Import → XML…** and select the `.fcpxml`.

> The output folder is self-contained — the FCPXML references the clips next to
> it, so you can **delete the source folder afterward** without breaking
> anything. Import the **XML**, not the raw MP4s — that is how the metadata (and
> the corrected frame rate) comes along.

## Requirements

- **ffmpeg** and **ffprobe**: `brew install ffmpeg`. `ffprobe` reads
  width/height, exact frame rate, frame count, and audio info; `ffmpeg`
  performs the lossless slow-motion retime.
- **awk** and **bash** (preinstalled on macOS).

The script checks for these on startup and exits with a clear message if a tool
is missing.

## Slow-motion detection (how it knows)

Every DJI SRT carries **two clocks**:

- a **playback clock** — the `00:00:00,000 --> 00:00:00,033` subtitle timecodes
  (how long the file plays), and
- a **real-world capture clock** — the `2026-06-19 14:20:40.236` wall-clock line,
  which advances at real time.

Their ratio is the slow-motion factor, measured directly from the footage:

```
factor = round( playback_span / real_capture_span )
```

A conformed 100 fps clip plays for ~4× as long as it was really captured, so
`factor` = 4 and the true rate is `25 × 4 = 100`. A normal clip has `factor` ≈ 1
and is passed through untouched. This needs no filename conventions or hardcoded
rates, and a genuine high-frame-rate clip (e.g. a real 60 fps shot) is correctly
*not* retimed because its two clocks agree.

The retime itself is `ffmpeg -itsscale 1/factor -i in.mp4 -map 0:v:0 -c:v copy`:
it rescales the timestamps and stream-copies the existing frames, so no frame is
dropped, duplicated, or re-encoded.

### Why retimed clips are video-only

Each DJI MP4 has four tracks; only the first is useful for editing:

| Track | What it is | Kept in retimed clip? |
|-------|------------|-----------------------|
| HEVC video | the 4K footage | **Yes** |
| `djmd` "CAM meta" | per-frame telemetry, binary protobuf | No — same data as the SRT, preserved in the FCPXML |
| `dbgi` "CAM dbgi" | DJI internal debug data (~4.5 Mbps) | No |
| mjpeg 960×540 | embedded preview thumbnail | No — the `.LRF` proxy already exists separately |

Dropping tracks 2–4 makes the remux faster and the file smaller, and loses
nothing useful (the telemetry survives as readable FCPXML metadata). Slow-motion
clips have no audio track, so there is no audio-sync concern. Normal (passed-
through) clips are copied verbatim with all their tracks intact.

## What lands where in Final Cut

| SRT value           | Destination in FCP                | Mechanism |
|---------------------|-----------------------------------|-----------|
| Focal length → lens | **Camera Name** field             | `<md key="com.apple.proapps.mio.cameraName">` on the asset |
| ISO (dominant)      | **ISO** field                     | `<md key="com.apple.proapps.studio.cameraISO">` |
| Color temp (`ct`)   | **Color Temperature** field       | `<md key="com.apple.proapps.studio.cameraColorTemperature">` |
| Aperture (`fnum`)   | **Keyword** (e.g. `f/2.8`)        | `<keyword>` on the asset-clip |
| Shutter             | **Keyword** (e.g. `1/60s`)        | `<keyword>` |
| Color profile       | **Keyword** (e.g. `D-LogM`)       | `<keyword>` |
| ISO range           | **Keyword** (e.g. `ISO 800-2500`) | `<keyword>`, only when ISO varied within the clip |
| Slow motion         | **Keywords** `Slow Motion` + `100fps`/`120fps` | `<keyword>`, only on retimed clips |
| Frame rate          | shown automatically               | derived from the (retimed) media via the `<format>` element |

Where to see them after import:

- **Camera Name / ISO / Color Temperature** → Inspector → **Info** tab (set the
  metadata view to *General* or *Extended* if a field is hidden).
- **Keywords** → the Keywords sidebar (each becomes a filterable Keyword
  Collection), the blue bar on clip thumbnails, or the Keyword Editor (⌘K).
  Filter on `Slow Motion` to find all your slow-mo clips at once.

## How it works

1. **SRT parse (awk).** Each subtitle block carries one frame of telemetry, e.g.
   `[iso: 2000] [shutter: 1/60.0] [fnum: 2.0] [color_md: dlog_m] [focal_len: 28.00] [ct: 6003, tint: 10]`.
   The parser extracts each bracketed field across all frames and summarises the
   clip: **dominant** (most-frequent) value for ISO/shutter/aperture/color/focal/ct,
   plus **min/max ISO** for a range keyword. In the same pass it reads the
   playback and wall-clock timecodes and computes the **slow-motion factor**.
2. **Clip output.** Slow-motion clips (`factor ≥ 2`) are retimed to true fps via
   a lossless `ffmpeg` remux into the output folder; normal clips are copied
   there unchanged.
3. **MP4 probe (ffprobe).** Width, height, `r_frame_rate`, frame count, and audio
   are read from the **output** file, so a retimed clip's frame rate and duration
   are the corrected ones.
4. **FCPXML build (bash).** Emits `<resources>` (one `<format>` + one `<asset>`
   per clip, each asset with a `file://` `media-rep` pointing into the output
   folder, plus native `<metadata>`) and one `<event>` with an `<asset-clip>` per
   clip carrying whole-clip `<keyword>` tags. Durations are frame-accurate
   rationals derived from the ffprobe frame rate and frame count.

Output is one FCPXML for the whole folder (single `<event>`, all clips).

## Design decisions (and why)

- **SRT-derived slow-motion factor.** The factor is measured from the SRT's two
  clocks, not guessed from filenames or fps. This auto-detects slow motion, gives
  the exact factor per clip, and never misfires on genuine high-fps footage.
- **Lossless retime, video-only.** Every captured frame already exists in the
  file, so restoring true fps is a timestamp rescale + stream copy — no
  re-encode. The telemetry/debug/preview tracks are dropped from retimed clips
  (faster, smaller, cleaner for FCP); the telemetry lives on as FCPXML metadata.
- **Full copies, not links.** Normal clips are fully copied into the output
  folder so it is portable and survives deletion of the source.
- **FCPXML, not embedded MP4 metadata.** It is the only reliable way to get this
  data into Final Cut's searchable metadata, and it needs nothing installed
  beyond ffmpeg/ffprobe. Embedding into QuickTime atoms (exiftool) is unreliable
  in FCP and mutates the originals.
- **Native field vs keyword split.** Anything with a *safe, settable* native FCP
  field uses that field (Camera Name, ISO, Color Temperature). Everything else
  stays a keyword. Keywords are still the better tool for filtering, so the split
  is deliberate, not a fallback.
- **Color profile is a keyword, not the "Color Profile" field.** That field
  (`kMDItemProfileName`, e.g. `HD (1-1-1)`) is **media-derived** — Final Cut fills
  it from the file's actual color space and would overwrite our value on import.
  So `dlog_m` goes to a keyword instead.
- **Lens name is derived from focal length.** The SRT has no literal lens name.
  On DJI multi-camera drones each focal length maps to a physical lens, so
  `map_lens()` classifies by range: ≤35mm → Wide, ≤100mm → Medium Tele,
  else Tele. Value format is `Name (focal)`, e.g. `Wide (28mm)`.
- **ISO as dominant + range.** Auto-ISO varies within a shot. The single-value
  ISO field gets the dominant value; the range survives as a keyword only when
  it actually varied.

## Known caveats / open items (handoff)

- **Not verified inside Final Cut yet.** The XML is well-formed and validated, but
  a real **File → Import → XML…** has not been run by an agent. That is the one
  step only the user can confirm. Specifically:
  - **ISO and Color Temperature fields** are written into normally-empty native
    fields, so they *should* persist — but if a given FCP version recomputes them
    from the media on import and blanks them, move those two to keywords (same
    pattern as aperture/shutter).
  - The XML uses a top-level `<event>` (no `<library>` wrapper) so it imports into
    the currently open library/event. If a version rejects that, wrap the event
    in a `<library>` element.
- **Slow-motion factor assumes integer ratios.** Observed DJI factors are exactly
  4× (100→25, 120→29.97); the ratio is rounded to the nearest integer, which
  absorbs the small measurement drift. A clip whose two clocks disagree by less
  than ~1.5× is treated as normal.
- **One `<format>`/`<asset>` per clip, not deduped.** Identical formats are
  repeated rather than shared. Valid, just slightly verbose. Dedup was skipped to
  avoid bash 3.2 associative arrays (macOS default bash). Revisit only if file
  size matters.
- **SRT format assumption.** Built for the modern bracketed DJI SRT
  (`[iso: …] [shutter: …] …`) with the playback/wall-clock lines. Older DJI SRT
  layouts (e.g. `HOME(...) … ISO …`) are not parsed and would need a new branch
  in `parse_srt`. A clip without a matching SRT is skipped (no factor, no
  metadata).
- **`set -euo pipefail` + `&&` guards.** A few keyword-append lines use
  `[ -n "$x" ] && kws+=(...)`. In practice the DJI SRT always populates these
  fields, but an SRT missing one could abort the run under `set -e`. Convert to
  `if` blocks if that ever bites.
- **Other available native fields, not currently used:** `cameraColorTemperature`
  is used; the SRT also has `tint`, `latitude`, `longitude`, `rel_alt`, `abs_alt`,
  `ev`. None are wired up. GPS in particular could become FCP metadata or keywords
  if wanted.

## Files

- `dji-srt-to-fcpxml.sh` — the script.
- `<output-folder>/DJI_metadata.fcpxml` — generated output (regenerated on each run).
