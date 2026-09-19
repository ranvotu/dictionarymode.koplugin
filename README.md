# KOReader Dictionary Mode
Tap a word to look it up in the dictionary.

## Usage

This plugin will add a new option **Dictionary Mode** under **Main Menu → Settings → Taps and gestures**.
You can enable it from the menu, or bind the **Dictionary Mode** gesture. When enabled, dictionary lookups will be triggered simply by tapping a word.

Under _Tab zone_, there are 4 modes for you to choose to use:

| Mode | What it does |
| --- | --- |
| **Auto** | Uses the book's current page margins to create a _region_ for dictionary tapping. Taps *inside* that area look up a word; taps *outside* unchanged. |
| **Default** | A fixed _region_. Ships as `x=0.23, y=0.05, w=0.54, h=0.9`. You can replace this with your own values — see Custom below. |
| **Custom** | Enter `x, y, w, h` yourself (`0.23` or `23` for percent). **Apply** uses the numbers as Custom. **Default** saves those numbers as the new Default and switches to Default. |
| **Pixel** | A tap on a word opens the dictionary; a tap on any whitespace still same as before. |

`x, y` are the top-left of the zone (including right-bottom; ex: ratio x: 0.1 will automatically create 0.1 on left and 0.1 on right); `w, h` are width and height. All four are ratios of the screen (`0`–`1`).

Page turns while the mode is on: swipe, hardware buttons, or tap outside the zone (Auto / Default / Custom). With **Only text**, tapping blank space works too.

## Install

1. Create a folder named `dictionarymode.koplugin` in your KOReader `plugins` directory.
2. Copy files (`main.lua`, `_meta.lua`) from this repository into that folder.
3. Restart KOReader.
4. Enable it under **Main Menu → Options → More tools → Plugin management**.

## Credits
Original plugin: [ckilb/dictionarymode.koplugin](https://github.com/ckilb/dictionarymode.koplugin).
