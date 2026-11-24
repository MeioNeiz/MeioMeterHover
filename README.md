# Meio MeterHover

Rest the mouse on a damage meter row to see that player's spells. No clicking.

Renamed from MeterHover. Your settings carry over if you log in once with the old MeterHover
folder still enabled (until you disable it, MeioMeterHover stays idle and says so in chat);
if your addon manager removed it, copy `WTF\Account\<account>\SavedVariables\MeterHover.lua`
to `MeioMeterHover.lua` before logging in.

![The damage meter with the mouse on Brisa's row: before, nothing happens; with MeterHover,
Brisa's spell breakdown shows beside the meter](docs/before-after.png)

## What it does

- Works with Blizzard's damage meter, and with FlareUI's skin
- A share line under the spells: your pet's share, DoTs against direct hits
- Hover a fight in the session menu for its length and your DPS
- Clicking a row still opens Blizzard's breakdown

Out of combat only: in combat the game hides the meter's numbers from addons.

Settings: Esc > Options > AddOns > MeioMeterHover, or `/meterhover`.

## Install

Use your addon manager (CurseForge, Wago), or unzip a GitHub release into
`World of Warcraft\_forever_\Interface\AddOns` and restart WoW fully.

## Feedback

Bugs and ideas: [GitHub issues](https://github.com/MeioNeiz/MeioMeterHover/issues)

## More Meio addons

[Meio TrainerCompare](https://www.curseforge.com/wow/addons/trainercompare) | [Meio Next Stop](https://www.curseforge.com/wow/addons/leavebutton) | [Meio AutoRank](https://www.curseforge.com/wow/addons/meio-autorank) | [Meio Map](https://addons.wago.io/addons/meiomap) | [Meio Alts](https://addons.wago.io/addons/meioalts) | [Meio DPS](https://addons.wago.io/addons/meiodps) | [Meio Plates](https://addons.wago.io/addons/meioplates) | [Meio Hub](https://addons.wago.io/addons/meiohub) | [Meio Pets](https://addons.wago.io/addons/meiopets) | [Meio Stats](https://addons.wago.io/addons/meiostats) | [Meio Bags](https://addons.wago.io/addons/meiobags) | [Meio Fixes](https://addons.wago.io/addons/meiofixes) | [Meio Flight Times](https://addons.wago.io/addons/meioflighttimes)

## Licence

[MIT](LICENSE)
