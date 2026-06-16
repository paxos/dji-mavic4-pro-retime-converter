# DJI SRT → Final Cut Pro metadata

`dji-srt-to-fcpxml.sh` reads the DJI `.SRT` telemetry sidecar that ships next to
each `.MP4` clip and writes a single `DJI_metadata.fcpxml`. You import that file
into Final Cut Pro and every clip arrives with its camera settings attached —
some as native inspector fields, the rest as searchable keywords.

This solves the core problem: **Final Cut cannot read a DJI `.SRT` file**, but it
*can* import an FCPXML, which is Apple's own documented interchange format. The
script translates the SRT telemetry into that format.

## Usage

```bash
./dji-srt-to-fcpxml.sh <folder>
```

`<folder>` is the directory holding the `.MP4` files and their matching `.SRT`
sidecars (same basename, e.g. `DJI_..._0026_D.MP4` ↔ `DJI_..._0026_D.SRT`). The
script writes `<folder>/DJI_metadata.fcpxml`.

Then in Final Cut: **File → Import → XML…** and select the `.fcpxml`.

> Import the **XML**, not the raw MP4s — that is how the metadata comes along.
> The XML references the original MP4s in place (no copy is made). If you have
> *already* imported the MP4s directly, importing the XML creates a second,
> metadata-tagged copy of the clips; use those.

## Requirements

- **ffprobe** (from ffmpeg): `brew install ffmpeg` — used to read width/height,
  exact frame rate, frame count, and audio info from each MP4.
- **awk** and **bash** (preinstalled on macOS).

The script checks for these on startup and exits with a clear message if a tool
is missing.

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
| Frame rate          | shown automatically               | derived from the media via the `<format>` element |

Where to see them after import:

- **Camera Name / ISO / Color Temperature** → Inspector → **Info** tab (set the
  metadata view to *General* or *Extended* if a field is hidden).
- **Keywords** → the Keywords sidebar (each becomes a filterable Keyword
  Collection), the blue bar on clip thumbnails, or the Keyword Editor (⌘K).

## How it works

1. **SRT parse (awk).** Each subtitle block carries one frame of telemetry, e.g.
   `[iso: 2000] [shutter: 1/60.0] [fnum: 2.0] [color_md: dlog_m] [focal_len: 28.00] [ct: 6003, tint: 10]`.
   The parser extracts each bracketed field across all frames and summarises the
   clip: **dominant** (most-frequent) value for ISO/shutter/aperture/color/focal/ct,
   plus **min/max ISO** so a range keyword can be emitted when ISO drifts.
2. **MP4 probe (ffprobe).** Width, height, `r_frame_rate` (an exact rational like
   `60000/1001`), frame count, and audio channels/rate.
3. **FCPXML build (bash).** Emits `<resources>` (one `<format>` + one `<asset>`
   per clip, each asset with a `file://` `media-rep` and the native `<metadata>`)
   and one `<event>` with an `<asset-clip>` per clip carrying whole-clip
   `<keyword>` tags. Durations are frame-accurate rationals derived from the
   ffprobe frame rate and frame count.

Output is one FCPXML for the whole folder (single `<event>`, all clips).

## Design decisions (and why)

- **FCPXML, not embedded MP4 metadata.** It is the only reliable way to get this
  data into Final Cut's searchable metadata, and it needs nothing installed
  beyond ffprobe. Embedding into QuickTime atoms (exiftool) is unreliable in FCP
  and mutates the originals.
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
- **One `<format>`/`<asset>` per clip, not deduped.** Identical formats are
  repeated rather than shared. Valid, just slightly verbose. Dedup was skipped to
  avoid bash 3.2 associative arrays (macOS default bash). Revisit only if file
  size matters.
- **SRT format assumption.** Built for the modern bracketed DJI SRT
  (`[iso: …] [shutter: …] …`). Older DJI SRT layouts (e.g. `HOME(...) … ISO …`)
  are not parsed and would need a new branch in `parse_srt`.
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
- `DJI_metadata.fcpxml` — generated output (regenerated on each run).
