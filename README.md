# Squish

A small native Mac app that squishes images down to smaller sizes. Unitasker built to automate a pesky workflow I find myself doing frequently for web content management.

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

Same ladder as my compress-images Python script — quality 95 stepping down by 5, floor 15,
matching the script's `while quality > 10` loop — but the rung is found by binary
search rather than by encoding every rung on the way down.
