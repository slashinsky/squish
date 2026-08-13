# Squish

A small native Mac app wrapping the same logic as `../compress-images.py`.
No Python, no Pillow, no venv — it uses macOS's built-in ImageIO.

## Use

Open the app, drop a folder of photos on it (or click **Choose Folder…**), set the
size cap, click **Compress**. Output goes to a new `<FolderName>_Compressed`
folder next to the one you picked; originals are never touched. Finder opens on
the result when it finishes.

If a `_Compressed` folder already exists, it makes `_Compressed 2` rather than
overwriting.

## Build

```sh
./build.sh
```

Produces `Squish.app` (~510 KB, mostly the icon) in this directory. Requires only
the Xcode Command Line Tools.

```sh
./build.sh --install   # also copies it to /Applications
```

The icon (🤏 on a white rounded tile) is generated at build time by
`Tools/makeicon.swift` — there is no checked-in image asset.

## How it compresses

Same ladder as the Python script — quality 95 stepping down by 5, floor 15,
matching the script's `while quality > 10` loop — but the rung is found by binary
search rather than by encoding every rung on the way down.

JPEG size rises monotonically with quality, so the rungs that fit form a suffix
of the ladder, and the highest fitting rung is reachable in ~5 encodes instead of
~17. This is a pure speed change: verified byte-for-byte identical output against
the linear walk on 20 real photos (the only files that differ are ones that get
resized, where the resampler also changed).

Two differences, both deliberate:

- **Attempts are encoded in memory.** The script wrote every attempt to disk;
  only the winner is written here.
- **Dimensions come down as a last resort.** ~50 MP photos cannot reach 2 MB at
  *any* JPEG quality — the script's output for those was both visually ruined and
  still over the cap. When the full-resolution ladder bottoms out, the image is
  scaled down and retried at quality 85→40, which meets the cap and looks
  considerably better. Files that fit at full resolution never get resized, so
  they behave exactly as before.

EXIF orientation is carried through to the output. The Python version dropped all
EXIF, which could leave photos rotated.

## Tests

`Tests/main.swift` is a headless CLI over the same `Compressor` core, for
checking behavior without clicking through the GUI:

```sh
swiftc -O -o /tmp/cli Sources/Compressor.swift Tests/main.swift
/tmp/cli /path/to/folder 2.0
```

It prints per-file size, quality, and whether a resize was needed.

## Performance

140 photos / 2.2 GB, on a 10-core M-series: **58s wall, 204s CPU**, peak ~1.2 GB RSS.

Three things keep the fans down:

- **Binary search over the quality ladder** — ~5 encodes per photo instead of ~17.
  This was worth 3.6x on its own.
- **Decode once.** The bitmap is decoded up front with `kCGImageSourceShouldCache`
  rather than being re-decoded behind every encode attempt.
- **Concurrency capped at 4**, not the core count. Measured: 4 is slightly *faster*
  than 6 on a 10-core machine and uses less memory — past that, contention and
  memory pressure cost more than the parallelism gains.

Downscaling happens during decode via `CGImageSourceCreateThumbnailAtIndex`, not
by resampling a full-size bitmap afterwards.
