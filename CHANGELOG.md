# MeioMeterHover

## 1.2.2

- Report to chat: the chat bubble on the preview posts that player's top spells to party or
  raid (shown only to you when solo); right-click it for say, guild or a whisper to your
  target. `/meterhover report [n]` does the same for the last player you looked at
- `/meterhover help` lists each command on its own line

## 1.2.1

- Renamed from MeterHover. Your settings carry over if you log in once with the old
  MeterHover folder still enabled (until you disable it, MeioMeterHover stays idle and
  says so in chat); if your addon manager removed it, copy
  `WTF\Account\<account>\SavedVariables\MeterHover.lua` to `MeioMeterHover.lua` before
  logging in.
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
