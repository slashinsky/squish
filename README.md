# Squish

A small native Mac app that squishes images down to smaller sizes. Unitasker built to automate a pesky workflow I find myself doing frequently for web content management.

## Download

**[⬇ Download Squish for Mac](https://github.com/slashinsky/squish/releases/latest/download/Squish.zip)**
Requires an Apple Silicon Mac (M1 or newer) running macOS 13 Ventura or later.

1. Click the link above, then double-click `Squish.zip` in your Downloads folder to unzip it.
2. Drag **Squish** into your **Applications** folder.
3. Double-click it. macOS will refuse to open it the first time — see below.

### Getting past the first-launch warning

Squish isn't signed with a paid Apple Developer certificate, so macOS blocks it on
first open with *"Apple could not verify Squish is free of malware."* To allow it:

1. Open **System Settings → Privacy & Security**.
2. Scroll to the **Security** section — there'll be a note that Squish was blocked.
3. Click **Open Anyway** and authenticate.

Once only. It opens normally after that.

## Use

Open the app, drop a folder of photos on it (or click **Choose Folder…**), set the
size cap, click **Compress**. Output goes to a new `<FolderName>_Compressed`
folder next to the one you picked; originals are never touched. Finder opens on
the result when it finishes.

If a `_Compressed` folder already exists, it makes `_Compressed 2` rather than
overwriting.

## How it compresses

Same ladder as my compress-images Python script — quality 95 stepping down by 5, floor 15,
matching the script's `while quality > 10` loop — but the rung is found by binary
search rather than by encoding every rung on the way down.
