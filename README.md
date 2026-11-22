# MeterHover

Rest the mouse on a row of **WoW Forever**'s built-in damage meter and its breakdown (the
spell list a click opens) appears beside the meter. Move away and it closes. No clicking
through the meter row by row after a pull.

![Hovering Aldren's row previews Aldren's spells](docs/preview.png)

With [FlareUI](https://www.curseforge.com/projects/1718307)'s damage meter skin, the preview
takes the same look:

![The preview with FlareUI's meter skin](docs/preview-flareui.png)

## What it does

- **Hover a row** (out of combat): after a short pause the breakdown for that player shows
  beside the meter window, laid out with your meter's own settings (bar height, text size,
  icons, class colours, style). Move to another row and it switches.
- **Move onto the preview** to scroll it or to see a spell's tooltip; it stays while the
  mouse is on it.
- **Click a row** as before: that opens Blizzard's own breakdown, Shift-click keeps it open.
  While Blizzard's breakdown is open, hovering leaves it alone.
- **Share line** under the preview's spells: in Damage Done and DPS, your pet's share and
  DoT ticks against direct hits; in Healing, Drain Life and Health Funnel against the rest;
  in Damage Taken, who hit hardest.
- **Fight summary**: hover a fight in the meter's session menu for one line with how long
  it lasted, your DPS and your pet's share.

![The share line under Brisa's preview: Imp 8%, DoTs 41%, direct 51%](docs/share.png)

In combat the meter's numbers are secret to addons, so the preview only works out of combat
(the damage meter shows them, MeterHover can't read them). It closes when combat starts.

Settings: Esc > Options > AddOns > MeterHover, or the addon compartment on the minimap. They
turn each part on or off and set how long the mouse rests on a row before the preview opens.

## Commands

| Command | |
|---|---|
| `/meterhover` | Opens the settings |
| `/meterhover help` | The list of commands, and whether the damage meter is turned on |
| `/meterhover off`, `/meterhover on` | Turn the hover preview off or on |
| `/meterhover delay <seconds>` | How long to rest on a row before the preview opens (0 to 1) |
| `/meterhover share on`, `off` | The share line under the preview |
| `/meterhover summary on`, `off` | The fight summary in the session menu |

## Install

Use your addon manager, or download the zip from
[Releases](https://github.com/MeioNeiz/MeterHover/releases) and unzip it into
`World of Warcraft\_forever_\Interface\AddOns`, so that you end up with
`AddOns\MeterHover\MeterHover.toc`. Restart WoW fully (a `/reload` doesn't find new
addons).

MeterHover works with the game's own damage meter: turn it on in **Options > Advanced >
Enable Damage Meter**. If it's off, MeterHover says so once at login and in `/meterhover`.

No other addon is needed. [FlareUI](https://www.curseforge.com/projects/1718307) is
optional; with its meter skin the preview copies its background, border and fonts.

## Limits

- Out of combat only (see above).
- Death rows (Deaths meter) open Blizzard's death recap on click; they have no hover preview.
- The preview can't be resized or moved: it sits where Blizzard's breakdown opens, with
  its width.
- Made and tested on an English client, game version 1.60.1.

## Licence

[MIT](LICENSE)
