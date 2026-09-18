# KOReader Dictionary Mode
Tap a word to look it up in the dictionary.

## Usage

This plugin will add a new option **Dictionary Mode** under **Main Menu → Settings → Taps and gestures**.
You can enable it from the menu, or bind the **Dictionary Mode** gesture. When enabled, dictionary lookups will be triggered simply by tapping a word.

In the "Tab zone", there are 4 modes for you to choose to use:

1. **Auto** (The mode will automatically create an invisible region for one tap dictionary, the space that leaves out will be functional previously)
2,3. **Default & Custom** (The region set beforehand, you can set again by simply going in custom tab and set default new value; `x, y` are the top-left (it automatically times 2 for bottom and right) of the zone; `w, h` are width and height. All four are ratios of the screen (`0`–`1`).
)
4. **Only text** (word box): Ignores rectangles. A tap on a word opens the dictionary; a tap on whitespace (including ragged / right-aligned lines) still page-turns. Best for screenplays, poetry, or anything that is not fully justified.

## Install

1. Create a folder named `dictionarymode.koplugin` in your KOReader `plugins` directory.
2. Copy every file from this repository into that folder.
3. Enable it under **Main Menu → Options → More tools → Plugin management**.
4. Restart KOReader after replacing files.

# Credits:
Original plugin: [ckilb/dictionarymode.koplugin](https://github.com/ckilb/dictionarymode.koplugin).
_______________________________________________________




Enable it from that menu, or bind the **Dictionary Mode** gesture (one swipe on, one swipe off).

When it is on, choose a **tap zone**:

| Mode | What it does |
| --- | --- |
| **Auto** | Uses the book's current page margins (left, right, top + header, bottom). Taps *inside* that area look up a word; taps *outside* still turn the page, open the menu, or hit the footer. Recalculates if you change margins or rotate the screen. |
| **Default** | A fixed rectangle. Ships as `x=0.23, y=0.05, w=0.54, h=0.9` (center column, edges free for page turns). You can replace this with your own values — see Custom below. |
| **Custom** | Enter `x, y, w, h` yourself (`0.23` or `23` for percent). **Apply** uses the numbers as Custom. **Default** saves those numbers as the new Default and switches to Default. |
| **Only text** | Ignores rectangles. A tap on a word opens the dictionary; a tap on whitespace (including ragged / right-aligned lines) still page-turns. Best for screenplays, poetry, or anything that is not fully justified. |

`x, y` are the top-left of the zone; `w, h` are width and height. All four are ratios of the screen (`0`–`1`).

Page turns while the mode is on: swipe, hardware buttons, or tap outside the zone (Auto / Default / Custom). With **Only text**, tapping blank space works too.

## Install

1. Create a folder named `dictionarymode.koplugin` in your KOReader `plugins` directory.
2. Copy every file from this repository into that folder.
3. Enable it under **Main Menu → Options → More tools → Plugin management**.
4. Restart KOReader after replacing files.

## Credits

Original plugin: [ckilb/dictionarymode.koplugin](https://github.com/ckilb/dictionarymode.koplugin).
