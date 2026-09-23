# KOReader Dictionary Mode

Tap a word to look it up in the dictionary.

## Usage

This plugin will add a new option **Dictionary Mode** under **Main Menu → Settings → Taps and gestures**.
You can enable it from the menu, or bind the **Dictionary Mode** gesture. When enabled, dictionary lookups will be triggered simply by tapping a word.

Under _Tab zone_, there are 4 modes for you to choose to use:

| Mode | What it does |
| --- | --- |
| **Auto** | Uses the book's current page margins to create a _region_ for dictionary tapping. Taps *inside* that area look up a word. |
| **Default** | A fixed _region_. Ships as `x=0.23, y=0.05, w=0.54, h=0.9`. You can replace this with your own values — see Custom below. |
| **Custom** | Enter `x, y, w, h` yourself (`0.23` or `23` for percent). **Apply** uses the numbers as Custom. **Default** saves those numbers as the new Default and switches to Default. |
| **Pixel** | A tap on a word opens the dictionary. |

- _Custom:_ (`0`–`1`)

|  |  |
|---|---|
| `x`, `y` | Top-left position of the zone |
| `w`, `h` | Width and height of the zone |
| `right` | `1 − x − w` |
| `bottom` | `1 − y − h` |

e.g. `x=0.3`, `w=0.5` → **left 30% · zone 50% · right 20%**.

- Outside the zone, page-turn and other taps work as usual (`Auto` / `Default` / `Custom`). In `Pixel`, blank space also keeps the normal tap behavior.
- In two-column view or with uneven left/right margins, only `Auto` and `Pixel` are available.

## Install

1. Create a folder named `dictionarymode.koplugin` in your KOReader `plugins` directory.
2. Copy files (`main.lua`, `_meta.lua`) from this repository into that folder.
3. Restart KOReader.
4. Enable it under **Main Menu → Options → More tools → Plugin management**.

## Credits

Original plugin: [ckilb/dictionarymode.koplugin](https://github.com/ckilb/dictionarymode.koplugin).
