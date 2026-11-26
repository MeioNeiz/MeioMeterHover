# MeioMeterHover

## 1.2.4

- Fixed: in taller meter styles the preview scrolled its last spell out of sight. It now
  reaches down far enough to show every spell (up to 10)
- Fixed: on a very narrow meter the preview's values ran over the spell icons; it now keeps
  at least Blizzard's own minimum width

## 1.2.3

- Fixed: the share line under the preview ("Imp 8%, DoTs 41%") sat on the window's bottom
  border. It now has its own strip inside the border, with the chat bubble beside it, and
  the preview still shows as many spells as Blizzard's own breakdown

## 1.2.2

- Report to chat: the chat bubble on the preview posts that player's top spells to party or
  raid (shown only to you when solo); right-click it for say, guild or a whisper to your
  target. `/meterhover report [n]` does the same for the last player you looked at
- `/meterhover help` lists each command on its own line

## 1.2.1

- Fixed: the fight summary in the meter's session menu could stay hidden out of combat

## 1.2.0

- First public release
- Rest the mouse on a row of the damage meter: that player's breakdown shows beside the
  meter, laid out with the meter's own settings (and FlareUI's skin when it's on)
- Share line under the preview: pet share and DoT ticks against direct hits (Damage Done,
  DPS), Drain Life and Health Funnel (Healing), who hit hardest (Damage Taken)
- Fight summary when hovering a fight in the meter's session menu: duration, your DPS,
  your pet's share
- Settings panel: Esc > Options > AddOns > MeterHover, also from the addon compartment;
  open delay slider and a switch for each part
