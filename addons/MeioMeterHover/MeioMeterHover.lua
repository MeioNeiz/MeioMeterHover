-- MeioMeterHover: rest the mouse on a row of Blizzard's damage meter to preview its
-- breakdown (the spell list a click opens). Out of combat only: in combat the meter's
-- data is secret.
--
-- The preview is our own copy of Blizzard's breakdown window. Blizzard's own breakdown is
-- never opened, moved or hidden from here: one our code had written to taints Blizzard's
-- later reads of it, which fail in combat ("attempt to compare ... secret ... tainted").
-- A click on a row stays Blizzard's own (Shift-click keeps it open).

local _, ns = ...
local NAME = "MeioMeterHover"
local SV_NAME = "MeioMeterHoverDB"
local SLASH = "/meterhover"
local TEMPLATE = "DamageMeterSourceWindowTemplate"

local DEFAULT_DELAY = 0.15
local MAX_DELAY = 1
local CLOSE_DELAY = 0.3
-- preview layout: share line and report button between the backdrop's bottom border and
-- the list
local STRIP_BOTTOM = 18
local LIST_BOTTOM = 33
local BLIZZARD_LIST_BOTTOM = 17
local BLIZZARD_LIST_TOP = 15
local BLIZZARD_MIN_WIDTH = 200
local MAX_ROWS = 10
local SETTINGS_PATH = "Esc > Options > AddOns > " .. NAME

local db = {}
local preview
local hookedWindows, hookedRows = {}, {}
local rowWindow = setmetatable({}, { __mode = "k" })
local rowData = setmetatable({}, { __mode = "k" })
local pending = { row = nil, at = 0 }
local shown = { row = nil, window = nil, awaySince = nil }
local poller = CreateFrame("Frame")
poller:Hide()

local category, settings = nil, {}

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffb090ff" .. NAME .. ":|r " .. msg)
end

local function Line(msg) DEFAULT_CHAT_FRAME:AddMessage("  " .. msg) end
local function Cmd(text) return "|cffffd100" .. text .. "|r" end
local function OnOff(on) return on and "|cff80ff80on|r" or "|cffff8080off|r" end

local function OpenDelay()
    local d = tonumber(db.openDelay) or DEFAULT_DELAY
    return math.min(math.max(d, 0), MAX_DELAY)
end

-- through the Setting when the panel exists, so an open panel shows the change
-- "Your casts" ships hidden until checked in game: off unless turned on by slash, and kept
-- out of help and Settings. To release: true, and README Coming soon to features.
ns.CASTS_LISTED = false
local function CastsOn()
    if db.casts == nil then return ns.CASTS_LISTED end
    return db.casts
end
ns.CastsOn = CastsOn

local function Set(key, value)
    if settings[key] then settings[key]:SetValue(value) else db[key] = value end
end

local IsSecret = issecretvalue or function() return false end

local function AnySecret(t, depth)
    for k, v in pairs(t) do
        if IsSecret(k) or IsSecret(v) then return true end
        if type(v) == "table" and depth > 0 and AnySecret(v, depth - 1) then
            return true
        end
    end
    return false
end

-- nil when the meter can be used, else why not
local function MeterProblem()
    if not C_DamageMeter or not C_DamageMeter.IsDamageMeterAvailable then
        return "this game client has no damage meter."
    end
    if not C_CVar.GetCVarBool("damageMeterEnabled") then
        return ("Blizzard's damage meter is off: turn on Options > Advanced > %s.")
            :format(ENABLE_DAMAGE_METER or "Enable Damage Meter")
    end
    local ok, available, reason = pcall(C_DamageMeter.IsDamageMeterAvailable)
    if ok and not available then
        return "the damage meter isn't available here" .. (reason and reason ~= ""
            and ": " .. reason or ".")
    end
end

local function HidePreview()
    pending.row = nil
    shown.row, shown.window, shown.awaySince = nil, nil, nil
    if preview then preview:Hide() end
end

-- one source's breakdown, or nil when it can't be read (combat, secret, no spells)
local function FetchBreakdown(sessionType, sessionID, meterType, data)
    local api = C_DamageMeter
    local ok, source
    if sessionType then
        ok, source = pcall(api.GetCombatSessionSourceFromType, sessionType, meterType,
            data.sourceGUID, data.sourceCreatureID)
    elseif sessionID then
        ok, source = pcall(api.GetCombatSessionSourceFromID, sessionID, meterType,
            data.sourceGUID, data.sourceCreatureID)
    end
    if not ok or type(source) ~= "table" or type(source.combatSpells) ~= "table" then
        return
    end
    -- the spec icon can be secret, and Blizzard's entries compare it: fails from our code
    for _, spell in ipairs(source.combatSpells) do
        local details = type(spell) == "table" and spell.combatSpellDetails
        if type(details) == "table" and IsSecret(details.specIconID) then
            details.specIconID = nil
        end
    end
    if AnySecret(source, 3) then return nil, true end
    if #source.combatSpells == 0 then return end
    return source
end

local function FetchSource(window, data)
    return FetchBreakdown(window:GetSessionType(), window:GetSessionID(),
        window:GetDamageMeterType(), data)
end

-- the row's source with only the fields the breakdown reads, or nil if any is secret
local function RowSource(row)
    local data = rowData[row] or (row.GetElementData and row:GetElementData())
    if type(data) ~= "table" then return end
    local source = {
        sourceGUID = data.sourceGUID, sourceCreatureID = data.sourceCreatureID,
        totalAmount = data.totalAmount, name = data.name,
        classFilename = data.classFilename,
        isLocalPlayer = data.isLocalPlayer,
        showsValuePerSecondAsPrimary = data.showsValuePerSecondAsPrimary,
    }
    if AnySecret(source, 0) or IsSecret(data.deathRecapID) then return end
    -- a death row opens the death recap instead of a breakdown
    if data.deathRecapID and data.deathRecapID ~= 0 then return end
    if not source.sourceGUID and not source.sourceCreatureID then return end
    return source
end

local METER_TYPE = Enum.DamageMeterType or {}
local function TypeSet(...)
    local set = {}
    for i = 1, select("#", ...) do
        local value = METER_TYPE[select(i, ...)]
        if value then set[value] = true end
    end
    return set
end
-- creatureName and the per-target details mean the attacker in the "taken" meters
local DAMAGE_DONE_TYPES = TypeSet("DamageDone", "Dps")
local HEALING_TYPES = TypeSet("HealingDone", "Hps")
local TAKEN_TYPES = TypeSet("DamageTaken")
local DRAIN_LIFE, HEALTH_FUNNEL = 689, 755

local GetSpellName = C_Spell and C_Spell.GetSpellName or GetSpellInfo
local function Gold(text) return NORMAL_FONT_COLOR:WrapTextInColorCode(text) end
local function Pct(part, total) return math.floor(part / total * 100 + 0.5) end

local function Amount(spell)
    return type(spell) == "table" and tonumber(spell.totalAmount) or 0
end

-- damage done split: total, pet part, pet name ("Pets" for several), owner's DoT ticks
local function DamageSplit(spells)
    local total, petTotal, dot, pets, petNames = 0, 0, 0, {}, {}
    local periodic = ns.PERIODIC or {}
    for _, spell in ipairs(spells) do
        local amount = Amount(spell)
        if amount > 0 then
            total = total + amount
            local pet = spell.creatureName
            if type(pet) == "string" and pet ~= "" then
                petTotal = petTotal + amount
                if not pets[pet] then petNames[#petNames + 1] = pet end
                pets[pet] = (pets[pet] or 0) + amount
            else
                dot = dot + amount * (periodic[spell.spellID] or 0)
            end
        end
    end
    return total, petTotal, #petNames == 1 and petNames[1] or "Pets", dot
end

-- Drain Life and Health Funnel by name, so every rank counts
local function HealText(breakdown)
    local drainName, funnelName = GetSpellName(DRAIN_LIFE), GetSpellName(HEALTH_FUNNEL)
    if not drainName or not funnelName then return end
    local total, drain, funnel = 0, 0, 0
    for _, spell in ipairs(breakdown.combatSpells) do
        local amount = Amount(spell)
        if amount > 0 then
            total = total + amount
            local name = GetSpellName(spell.spellID)
            if name == drainName then
                drain = drain + amount
            elseif name == funnelName then
                funnel = funnel + amount
            end
        end
    end
    if total <= 0 or drain + funnel <= 0 then return end
    local drainPct, funnelPct = Pct(drain, total), Pct(funnel, total)
    local long, short = {}, {}
    if drainPct >= 1 then
        long[#long + 1] = ("%s %d%%"):format(Gold(drainName), drainPct)
        short[#short + 1] = long[#long]
    end
    if funnelPct >= 1 then
        long[#long + 1] = ("%s %d%%"):format(Gold(funnelName), funnelPct)
        short[#short + 1] = long[#long]
    end
    local other = math.max(100 - drainPct - funnelPct, 0)
    if other >= 1 then long[#long + 1] = ("%s %d%%"):format(Gold("other"), other) end
    if #short == 0 then return end
    return table.concat(long, ", "), table.concat(short, ", ")
end

-- the attacker who did the most: unitName, or creatureName for a pet
local function TakenText(breakdown)
    local total, by = 0, {}
    for _, spell in ipairs(breakdown.combatSpells) do
        local amount = Amount(spell)
        if amount > 0 then
            total = total + amount
            local details = spell.combatSpellDetails
            local who = type(details) == "table" and details.unitName
            if type(who) ~= "string" or who == "" then who = spell.creatureName end
            if type(who) == "string" and who ~= "" then
                by[who] = (by[who] or 0) + amount
            end
        end
    end
    local top, most
    for who, amount in pairs(by) do
        if not most or amount > most or (amount == most and who < top) then
            top, most = who, amount
        end
    end
    if not top or total <= 0 then return end
    local pct = Pct(most, total)
    if pct >= 100 then return ("%s %s"):format(Gold("All from:"), top), top end
    return ("%s %s %d%%"):format(Gold("Most from:"), top, pct),
        ("%s %d%%"):format(top, pct)
end

-- footer lines (long, short) for a checked breakdown, or nil. Damage: pet share and DoT
-- share. Every spell counts once, so the parts add up to 100%: pet, then the owner's own
-- damage split into DoT ticks (ns.PERIODIC share of each spell) and the rest.
local function ShareText(breakdown, meterType, source)
    if HEALING_TYPES[meterType] then return HealText(breakdown) end
    if TAKEN_TYPES[meterType] then return TakenText(breakdown) end
    if not DAMAGE_DONE_TYPES[meterType] then return end
    local total, petTotal, petName, dot = DamageSplit(breakdown.combatSpells)
    if total <= 0 then return end
    local petPct, dotPct = Pct(petTotal, total), Pct(dot, total)
    if petPct < 1 and dotPct < 1 then return end
    if dotPct < 1 then
        local whose = source.isLocalPlayer and "your"
            or (source.name and source.name .. "'s" or "their")
        return ("%s: %d%% of %s damage"):format(Gold(petName), petPct, whose),
            ("%s %d%%"):format(Gold(petName), petPct)
    end
    local dots = ("%s %d%%, %s %d%%"):format(Gold("DoTs"), dotPct, Gold("direct"),
        math.max(100 - petPct - dotPct, 0))
    if petPct < 1 then return dots, ("%s %d%%"):format(Gold("DoTs"), dotPct) end
    return ("%s %d%%, %s"):format(Gold(petName), petPct, dots),
        ("%s %d%%, %s %d%%"):format(Gold(petName), petPct, Gold("DoTs"), dotPct)
end

-- one line for a fight in the session menu: duration, your DPS, your pet's share
local function SummaryText(sessionType, sessionID)
    local api, damage = C_DamageMeter, METER_TYPE.DamageDone
    if not damage then return end
    local ok, session
    if sessionType then
        ok, session = pcall(api.GetCombatSessionFromType, sessionType, damage)
    elseif sessionID then
        ok, session = pcall(api.GetCombatSessionFromID, sessionID, damage)
    end
    -- only the fields read below: the spec icon can be secret out of combat
    if not ok or type(session) ~= "table" or type(session.combatSources) ~= "table"
        or IsSecret(session.durationSeconds) then
        return
    end
    local parts = {}
    local duration = tonumber(session.durationSeconds)
    if duration and duration > 0 then
        parts[1] = ("%s %s"):format(Gold("Duration"), SecondsToClock(duration))
    end
    local me
    for _, source in ipairs(session.combatSources) do
        if type(source) == "table" then
            if IsSecret(source.isLocalPlayer) then return end
            if source.isLocalPlayer then me = source end
        end
    end
    if not me then
        parts[#parts + 1] = "no damage from you"
        return table.concat(parts, ", ")
    end
    if IsSecret(me.amountPerSecond) or IsSecret(me.totalAmount) then return end
    local dps = tonumber(me.amountPerSecond)
    if not dps and duration and duration > 0 then
        dps = (tonumber(me.totalAmount) or 0) / duration
    end
    if dps then
        parts[#parts + 1] = ("%s %s"):format(Gold("DPS"),
            BreakUpLargeNumbers(math.floor(dps + 0.5)))
    end
    local breakdown = FetchBreakdown(sessionType, sessionID, damage, me)
    if breakdown then
        local total, petTotal, petName = DamageSplit(breakdown.combatSpells)
        local petPct = total > 0 and Pct(petTotal, total) or 0
        if petPct >= 1 then
            parts[#parts + 1] = ("%s %d%%"):format(Gold(petName), petPct)
        end
    end
    return table.concat(parts, ", ")
end

-- Report to chat: the last previewed player's top spells, read fresh when sent

local REPORT_SPELLS, REPORT_MAX_SPELLS = 5, 10
local REPORT_GAP = 5
local CHAT_MAX = 255
local reportTarget, reportMenu
local lastSent = -math.huge

local METER_WORD = {
    DamageDone = "damage", Dps = "damage", HealingDone = "healing", Hps = "healing",
    Absorbs = "absorbs", Interrupts = "interrupts", Dispels = "dispels",
    DamageTaken = "damage taken", AvoidableDamageTaken = "avoidable damage taken",
    EnemyDamageTaken = "damage taken",
}
local function MeterWord(meterType)
    for key, word in pairs(METER_WORD) do
        if METER_TYPE[key] == meterType then return word end
    end
    return "total"
end

local function Short(n)
    local text
    if n >= 1e6 then
        text = ("%.1fm"):format(n / 1e6)
    elseif n >= 1e5 then
        return ("%dk"):format(math.floor(n / 1e3 + 0.5))
    elseif n >= 1e3 then
        text = ("%.1fk"):format(n / 1e3)
    else
        return tostring(math.floor(n + 0.5))
    end
    return (text:gsub("%.0([km])$", "%1"))
end

-- group = instance, raid or party chat as the player is grouped; nil when solo
local function GroupChannel()
    local instance = LE_PARTY_CATEGORY_INSTANCE
    if instance and IsInGroup(instance) then return "INSTANCE_CHAT" end
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
end

local CHANNEL_WORD = {
    INSTANCE_CHAT = "instance chat", RAID = "raid chat", PARTY = "party chat",
    SAY = "say", GUILD = "guild chat", WHISPER = "a whisper",
}

local function WhisperTarget()
    if not UnitIsPlayer("target") then return end
    local isMe = UnitIsUnit("target", "player")
    if IsSecret(isMe) or isMe then return end
    local name = GetUnitName("target", true)
    if not IsSecret(name) and type(name) == "string" and name ~= "" then return name end
end

-- the target's source in its session, nil if gone, or "secret"
local function ReportSource(t)
    local api, ok, session = C_DamageMeter, nil, nil
    if t.sessionType then
        ok, session = pcall(api.GetCombatSessionFromType, t.sessionType, t.meterType)
    elseif t.sessionID then
        ok, session = pcall(api.GetCombatSessionFromID, t.sessionID, t.meterType)
    end
    if not ok or type(session) ~= "table" or type(session.combatSources) ~= "table" then
        return
    end
    if IsSecret(session.durationSeconds) then return "secret" end
    local guid, creature = t.source.sourceGUID, t.source.sourceCreatureID
    for _, s in ipairs(session.combatSources) do
        if type(s) == "table" then
            if IsSecret(s.sourceGUID) or IsSecret(s.sourceCreatureID) then
                return "secret"
            end
            if (guid and s.sourceGUID == guid)
                or (not guid and creature and s.sourceCreatureID == creature) then
                if IsSecret(s.totalAmount) or IsSecret(s.amountPerSecond)
                    or IsSecret(s.name) then
                    return "secret"
                end
                return s, tonumber(session.durationSeconds)
            end
        end
    end
end

-- chat lines for the target's top n spells, or nil and "secret" / "gone"
local function ReportLines(t, n)
    local me, duration = ReportSource(t)
    if me == "secret" then return nil, "secret" end
    if not me then return nil, "gone" end
    local breakdown, secret = FetchBreakdown(t.sessionType, t.sessionID, t.meterType, me)
    if secret then return nil, "secret" end
    if not breakdown then return nil, "gone" end

    local byName, list, sum = {}, {}, 0
    for _, spell in ipairs(breakdown.combatSpells) do
        local amount = Amount(spell)
        if amount > 0 then
            sum = sum + amount
            local id, who = spell.spellID, spell.creatureName
            local name = "?"
            if not IsSecret(id) then
                local spellName = GetSpellName(id)
                name = "spell " .. tostring(id)
                if not IsSecret(spellName) and type(spellName) == "string" then
                    name = spellName
                end
            end
            if not IsSecret(who) and type(who) == "string" and who ~= "" then
                name = ("%s (%s)"):format(name, who)
            end
            if not byName[name] then
                byName[name] = { name = name, amount = 0 }
                list[#list + 1] = byName[name]
            end
            byName[name].amount = byName[name].amount + amount
        end
    end
    if sum <= 0 then return nil, "gone" end
    table.sort(list, function(a, b)
        if a.amount ~= b.amount then return a.amount > b.amount end
        return a.name < b.name
    end)

    local total = tonumber(me.totalAmount) or sum
    local header = ("%s: %s %s"):format(me.name or t.source.name or "?", Short(total),
        MeterWord(t.meterType))
    local perSecond = DAMAGE_DONE_TYPES[t.meterType] and "DPS"
        or HEALING_TYPES[t.meterType] and "HPS"
    local rate = tonumber(me.amountPerSecond)
    if perSecond and not rate and duration and duration > 0 then rate = total / duration end
    if perSecond and rate then
        header = ("%s (%s %s)"):format(header, BreakUpLargeNumbers(math.floor(rate + 0.5)),
            perSecond)
    end
    local lines, line = {}, header
    for i = 1, math.min(n, #list) do
        local part = ("%s %s %d%%"):format(list[i].name, Short(list[i].amount),
            Pct(list[i].amount, sum))
        if #line + 2 + #part > CHAT_MAX then
            lines[#lines + 1] = line
            line = part
        else
            line = line .. ", " .. part
        end
    end
    lines[#lines + 1] = line
    return lines
end

local function SendLine(text, channel, whisperTo)
    local send = C_ChatInfo and C_ChatInfo.SendChatMessage or SendChatMessage
    return pcall(send, text, channel, nil, whisperTo)
end

-- channel "auto": group chat, or only your own chat frame when solo; "self": yours only
local function Report(channel, n, whisperTo)
    local t = reportTarget
    if not t then
        Print("hover a player in the damage meter first, then " .. Cmd(SLASH .. " report"))
        return
    end
    n = math.min(math.max(math.floor(tonumber(n) or REPORT_SPELLS), 1), REPORT_MAX_SPELLS)
    local lines, why = ReportLines(t, n)
    if not lines then
        if why == "secret" or InCombatLockdown() then
            Print("report after combat: the meter hides its numbers until then")
        else
            Print("that fight's numbers are gone: hover the player again")
        end
        return
    end
    local solo = channel == "auto" and not GroupChannel()
    if channel == "auto" then channel = GroupChannel() or "self" end
    if channel == "self" then
        Print(lines[1])
        for i = 2, #lines do Line(lines[i]) end
        if solo then
            Line("|cff999999only you see this (not in a group); right-click the chat button"
                .. " for say or a whisper|r")
        end
        return
    end
    local now = GetTime()
    if now - lastSent < REPORT_GAP then
        Print(("one report every %d s: try again in a moment"):format(REPORT_GAP))
        return
    end
    lastSent = now
    for _, l in ipairs(lines) do
        local ok, err = SendLine(l, channel, whisperTo)
        if not ok then
            Print("couldn't send to " .. (CHANNEL_WORD[channel] or channel) .. ": "
                .. tostring(err))
            return
        end
    end
end

local function ReportMenu()
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
    local group = GroupChannel()
    local whisper = WhisperTarget()
    -- owned by UIParent: the menu would close with the preview, which a click outside hides
    reportMenu = MenuUtil.CreateContextMenu(nil, function(_, root)
        local name = reportTarget and reportTarget.source.name or "Spells"
        root:CreateTitle(("%s's top %d spells to"):format(name, REPORT_SPELLS))
        local g = root:CreateButton(group and CHANNEL_WORD[group]:gsub("^%l", string.upper)
            or "Party chat", function() Report(group) end)
        if not group then g:SetEnabled(false) end
        root:CreateButton("Say", function() Report("SAY") end)
        if IsInGuild() then
            root:CreateButton("Guild chat", function() Report("GUILD") end)
        end
        if whisper then
            root:CreateButton("Whisper " .. whisper, function()
                Report("WHISPER", nil, whisper)
            end)
        end
        root:CreateButton("Only me", function() Report("self") end)
    end)
end

local function ReportButtonTooltip(button)
    local name = reportTarget and reportTarget.source.name or "this player"
    local group = GroupChannel()
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    GameTooltip:SetText("Report to chat")
    GameTooltip:AddLine(("Click: %s's top %d spells to %s"):format(name, REPORT_SPELLS,
        group and CHANNEL_WORD[group] or "your chat only (not in a group)"), 1, 1, 1, true)
    GameTooltip:AddLine("Right-click: say, guild or a whisper to your target",
        1, 1, 1, true)
    GameTooltip:Show()
end

-- Your casts beside each of your spells: only on your own row, damage and healing meters

local CASTS_TYPES = {}
for t in pairs(DAMAGE_DONE_TYPES) do CASTS_TYPES[t] = true end
for t in pairs(HEALING_TYPES) do CASTS_TYPES[t] = true end
local CAST_GAP, NAME_GAP = 16, 8
-- the short form may cut a long name down to this, never further
local MIN_NAME = 70
-- Blizzard's own gap between an entry's name and value (DamageMeterEntryMixin)
local BLIZZARD_NAME_GAP = 25
local castText = setmetatable({}, { __mode = "k" })

local function CastContext(window, source, breakdown)
    local meterType = window:GetDamageMeterType()
    if not source.isLocalPlayer or not CASTS_TYPES[meterType] then return end
    local counts = ns.SessionCasts(window:GetSessionType(), window:GetSessionID())
    if not counts then return end
    local ownRows = {}
    for _, spell in ipairs(breakdown.combatSpells) do
        if type(spell) == "table" and spell.spellID then ownRows[spell.spellID] = true end
    end
    return { counts = counts, ownRows = ownRows }
end

local function PerCast(n)
    local ok, text = pcall(AbbreviateLargeNumbers, math.floor(n + 0.5))
    if ok and type(text) == "string" and text ~= "" then return text end
    return Short(n)
end

-- casts and amount per cast for an entry of the preview, or nil
local function EntryCasts(entry)
    local context = preview and preview.casts
    if not CastsOn() or not context then return end
    local pet, amount = entry.creatureName, entry.value
    if IsSecret(pet) or IsSecret(amount) or type(amount) ~= "number" or amount <= 0 then
        return
    end
    if type(pet) == "string" and pet ~= "" then return end
    local n = ns.CastsFor(context.counts, entry.spellID, context.ownRows)
    if n then return n, amount / n end
end

local function Width(fs)
    if fs.GetUnboundedStringWidth then return fs:GetUnboundedStringWidth() end
    return fs:GetStringWidth()
end

-- our own fontstring left of the value; the name ends where it starts
local function UpdateEntryCasts(entry)
    local bar = entry.StatusBar
    if not bar or not bar.Name or not bar.Value then return end
    local fs = castText[entry]
    local n, each = EntryCasts(entry)
    local function Hide()
        if fs and fs:IsShown() then
            fs:Hide()
            bar.Name:SetPoint("RIGHT", bar.Value, "LEFT", -BLIZZARD_NAME_GAP, 0)
        end
    end
    if not n then return Hide() end
    if not fs then
        fs = bar:CreateFontString(nil, "OVERLAY")
        fs:SetJustifyH("RIGHT")
        fs:SetWordWrap(false)
        castText[entry] = fs
    end
    -- an outline keeps the grey readable where it crosses the gold bar fill
    local face, size, flags = bar.Value:GetFont()
    flags = flags or ""
    if not flags:find("OUTLINE") then
        flags = flags == "" and "OUTLINE" or flags .. ",OUTLINE"
    end
    if face and size then
        fs:SetFont(face, size, flags)
    else
        fs:SetFontObject(NumberFontNormal)
    end
    fs:SetTextScale(bar.Value:GetTextScale())
    fs:SetTextColor(0.9, 0.9, 0.9)
    fs:SetShadowColor(bar.Value:GetShadowColor())
    fs:SetShadowOffset(bar.Value:GetShadowOffset())
    fs:ClearAllPoints()
    fs:SetPoint("RIGHT", bar.Value, "LEFT", -CAST_GAP, 0)
    local per = PerCast(each)
    fs:SetText(("%d %s, %s each"):format(n, n == 1 and "cast" or "casts", per))
    local name = Width(bar.Name)
    local room = bar:GetWidth() - 5 - NAME_GAP - CAST_GAP - Width(bar.Value)
    local form = "long"
    if preview.castsShort or Width(fs) > room - name then
        form = "short"
        fs:SetText(("%d x %s"):format(n, per))
        if Width(fs) > room - math.min(name, MIN_NAME) then return Hide() end
    end
    fs:Show()
    bar.Name:SetPoint("RIGHT", fs, "LEFT", -NAME_GAP, 0)
    return form
end

-- one form for the whole list: short everywhere once one entry needs it, also when a row
-- is laid out again after the others (scrolled in, resized)
local refreshing = false
local function RefreshCasts()
    if not preview or refreshing then return end
    refreshing = true
    local box, short = preview:GetScrollBox(), false
    preview.castsShort = false
    box:ForEachFrame(function(entry) short = UpdateEntryCasts(entry) == "short" or short end)
    if short then
        preview.castsShort = true
        -- ForEachFrame stops at the first callback that returns a value
        box:ForEachFrame(function(entry) UpdateEntryCasts(entry) end)
    end
    refreshing = false
end

local function UpdateCasts(entry)
    local form = UpdateEntryCasts(entry)
    if form == "short" and not refreshing and not preview.castsShort then RefreshCasts() end
    return form
end

local hookedEntries = setmetatable({}, { __mode = "k" })
local function HookEntry(entry)
    if hookedEntries[entry] or not entry.UpdateStyle then return end
    hookedEntries[entry] = true
    -- a style change re-anchors the name to the value
    hooksecurefunc(entry, "UpdateStyle", UpdateCasts)
end

local function SetEntryFonts(entry)
    local fonts, bar = preview and preview.fonts, entry.StatusBar
    if not fonts or not bar or not bar.Name or not bar.Value then return end
    bar.Name:SetFont(unpack(fonts.name))
    bar.Value:SetFont(unpack(fonts.value))
    UpdateCasts(entry)
end

local function CreatePreview()
    if preview ~= nil then return preview end
    preview = false
    local xml = C_XMLUtil
    if xml and xml.GetTemplateInfo and not xml.GetTemplateInfo(TEMPLATE) then
        return preview
    end
    local ok, frame = pcall(CreateFrame, "Frame", NAME .. "Preview", UIParent, TEMPLATE)
    if not ok or not frame then return preview end
    frame:Hide()
    frame:SetClampedToScreen(true)
    -- resizing a preview that closes when the mouse leaves would be lost at once
    frame:GetResizeButton():Hide()
    -- Refresh reads the breakdown through this: hand it the one checked for secrets
    frame.GetCombatSessionSource = function(self) return self.checkedSource end
    ScrollUtil.AddAcquiredFrameCallback(frame:GetScrollBox(), function(_, entry)
        SetEntryFonts(entry)
    end)
    ScrollUtil.AddInitializedFrameCallback(frame:GetScrollBox(), function(_, entry)
        HookEntry(entry)
        UpdateCasts(entry)
    end, castText)
    -- Blizzard's backdrop draws its bottom border ~14 px up (shadow below it) and ends the
    -- list at 17 px: no room inside the border, so lift the list for a strip of our own.
    -- Blizzard re-anchors the list when its scroll bar shows or hides: lift it again.
    local box = frame:GetScrollBox()
    local function PlaceList()
        for i = 1, box:GetNumPoints() do
            local point, rel, relPoint, x, y = box:GetPoint(i)
            if point == "BOTTOMRIGHT" then
                if y ~= LIST_BOTTOM then box:SetPoint(point, rel, relPoint, x, LIST_BOTTOM) end
                return
            end
        end
    end
    hooksecurefunc(box, "SetPoint", function(_, point)
        if point == "BOTTOMRIGHT" then PlaceList() end
    end)
    PlaceList()
    local share = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    share:SetPoint("BOTTOMLEFT", 20, STRIP_BOTTOM)
    share:SetPoint("BOTTOMRIGHT", -42, STRIP_BOTTOM)
    share:SetJustifyH("LEFT")
    share:SetWordWrap(false)
    frame.Share = share
    local report = CreateFrame("Button", nil, frame)
    report:SetSize(18, 18)
    report:SetPoint("BOTTOMRIGHT", -20, STRIP_BOTTOM - 4)
    report:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIcon-Chat-Up")
    report:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIcon-Chat-Down")
    report:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    report:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    report:SetScript("OnClick", function(_, button)
        GameTooltip:Hide()
        if button == "RightButton" then ReportMenu() else Report("auto") end
    end)
    report:SetScript("OnEnter", ReportButtonTooltip)
    report:SetScript("OnLeave", function() GameTooltip:Hide() end)
    frame.Report = report
    preview = frame
    return preview
end

-- FlareUI skins Blizzard's breakdown: give the preview the same backdrop and bar fonts
local function CopySkin(real, row)
    local skin = real.FlareUI_DMSkin
    if not skin or not skin.GetBackdrop or not skin:GetBackdrop() then
        if preview.skin then preview.skin:Hide() end
        preview:GetBackground():SetAlpha(1)
        preview.fonts = nil
        return
    end
    local mine = preview.skin or CreateFrame("Frame", nil, preview, "BackdropTemplate")
    preview.skin = mine
    for i = 1, skin:GetNumPoints() do
        local point, _, relPoint, x, y = skin:GetPoint(i)
        if i == 1 then mine:ClearAllPoints() end
        mine:SetPoint(point, preview, relPoint, x, y)
    end
    mine:SetFrameLevel(math.max(preview:GetFrameLevel() - 1, 0))
    mine:SetBackdrop(skin:GetBackdrop())
    mine:SetBackdropColor(skin:GetBackdropColor())
    mine:SetBackdropBorderColor(skin:GetBackdropBorderColor())
    mine:Show()
    preview:GetBackground():SetAlpha(0)

    local bar = row.StatusBar
    if not bar or not bar.Name or not bar.Value or not bar.Name:GetFont() then return end
    preview.fonts = { name = { bar.Name:GetFont() }, value = { bar.Value:GetFont() } }
    preview:GetScrollBox():ForEachFrame(SetEntryFonts)
end

local function UpdateShare()
    local p, fs = preview, preview and preview.Share
    if not fs then return end
    local long, short
    if db.share ~= false and p.checkedSource then
        long, short = ShareText(p.checkedSource, p:GetDamageMeterType(), p.shareSource)
    end
    if p.fonts then
        local face, size, flags = unpack(p.fonts.value)
        fs:SetFont(face, math.min(size, 11), flags)
    else
        fs:SetFontObject("GameFontHighlightSmall")
    end
    fs:SetText(long or "")
    local width = fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth()
        or fs:GetStringWidth()
    if short and width > fs:GetWidth() then fs:SetText(short) end
    fs:SetShown(long ~= nil)
end

local function ShowPreview(row)
    local window = rowWindow[row]
    if not window or not window:IsVisible() then return end
    if window.IsEditing and window:IsEditing() then return end
    local real = window:GetSourceWindow()
    if real:IsShown() then return end
    local source = RowSource(row)
    local breakdown = source and FetchSource(window, source)
    if not breakdown or not CreatePreview() then return end

    local p = preview
    p.checkedSource = breakdown
    -- before the session is set: setting it fills the entries
    p.casts = CastContext(window, source, breakdown)
    p:SetDamageMeterType(window:GetDamageMeterType())
    p:SetSession(window:GetSessionType(), window:GetSessionID())
    p:SetUseClassColor(window:ShouldUseClassColor())
    p:SetBarHeight(window:GetBarHeight())
    p:SetBarSpacing(window:GetBarSpacing())
    p:SetTextScale(window:GetTextScale())
    p:SetShowBarIcons(window:ShouldShowBarIcons())
    p:SetStyle(window:GetStyle())
    p:SetBackgroundAlpha(window:GetBackgroundAlpha())
    p:SetSource(source)
    p.shareSource = source
    reportTarget = { sessionType = window:GetSessionType(),
        sessionID = window:GetSessionID(), meterType = window:GetDamageMeterType(),
        source = source }
    p:SetSticky(false)
    -- always take the meter window's height, as Blizzard's does the first time it opens
    p.previousSessionWindowCenterX = nil
    p:AnchorToSessionWindow(window)
    -- reach down past the meter by our strip, so the list shows as many rows as Blizzard's
    local right = p.isRightSide
    -- and further when taller rows (the meter's style) would scroll spells out of sight
    local box = p:GetScrollBox()
    local provider = box:GetDataProvider()
    local rows = math.min(provider and provider:GetSize() or 0, MAX_ROWS)
    local need = BLIZZARD_LIST_TOP + LIST_BOTTOM + rows * p:GetBarHeight()
        + math.max(rows - 1, 0) * p:GetBarSpacing()
    local reach = window:GetHeight() + LIST_BOTTOM - BLIZZARD_LIST_BOTTOM
    local extra = math.max(math.ceil(need - reach), 0)
    p:SetPoint(right and "BOTTOMLEFT" or "BOTTOMRIGHT", window,
        right and "BOTTOMRIGHT" or "BOTTOMLEFT", 0, BLIZZARD_LIST_BOTTOM - LIST_BOTTOM - extra)
    -- the meter can be narrower than Blizzard lets its breakdown be: values would cover icons
    local width = real:GetWidth()
    if width and width > 0 then p:SetWidth(math.max(width, BLIZZARD_MIN_WIDTH)) end
    p:SetAlpha(window:GetEffectiveAlpha())
    p:Show()
    CopySkin(real, row)
    UpdateShare()
    RefreshCasts()
    shown.row, shown.window, shown.awaySince = row, window, nil
end

poller:SetScript("OnUpdate", function(self)
    if InCombatLockdown() then
        HidePreview()
        self:Hide()
        return
    end
    local now = GetTime()
    if pending.row then
        if not pending.row:IsMouseOver() then
            pending.row = nil
        elseif now >= pending.at then
            local row = pending.row
            pending.row = nil
            local ok, err = pcall(ShowPreview, row)
            if not ok then
                HidePreview()
                Print("couldn't show the breakdown: " .. tostring(err))
            end
        end
    end
    if preview and preview:IsShown() then
        local window = shown.window
        if not window or not window:IsVisible() or window:GetSourceWindow():IsShown() then
            HidePreview()
        elseif (shown.row and shown.row:IsMouseOver()) or preview:IsMouseOver()
            or preview.Report:IsMouseOver() or (reportMenu and reportMenu:IsShown()) then
            shown.awaySince = nil
        elseif not shown.awaySince then
            shown.awaySince = now
        elseif now - shown.awaySince >= CLOSE_DELAY then
            HidePreview()
        end
    end
    if not pending.row and not (preview and preview:IsShown()) then self:Hide() end
end)

local function OnRowEnter(row)
    if db.hover == false or InCombatLockdown() then return end
    pending.row, pending.at = row, GetTime() + OpenDelay()
    poller:Show()
end

local function HookRow(window, row)
    if not row then return end
    rowWindow[row] = window
    if hookedRows[row] or not row.HookScript then return end
    hookedRows[row] = true
    row:HookScript("OnEnter", OnRowEnter)
end

local function HookWindow(window)
    if not window or hookedWindows[window] or not window.InitEntry then return end
    hookedWindows[window] = true
    -- every row (and the pinned local player row) gets its data through InitEntry
    hooksecurefunc(window, "InitEntry", function(self, row, data)
        rowData[row] = data
        HookRow(self, row)
    end)
    window:GetScrollBox():ForEachFrame(function(row) HookRow(window, row) end)
    HookRow(window, window:GetLocalPlayerEntry())
end

local function HookMeter()
    local meter = _G.DamageMeter
    if not meter or hookedWindows[meter] then return end
    hookedWindows[meter] = true
    for i = 1, _G.MAX_DAMAGE_METER_SESSION_WINDOWS or 3 do
        HookWindow(_G["DamageMeterSessionWindow" .. i])
    end
    if meter.SetupSessionWindow then
        hooksecurefunc(meter, "SetupSessionWindow", function(_, _, windowData)
            HookWindow(windowData and windowData.sessionWindow)
        end)
    end
end

local function ShowSummary(button, description, data)
    if db.summary == false or InCombatLockdown() then return end
    local ok, text = pcall(SummaryText, data.type, data.sessionID)
    if not ok or not text or text == "" then return end
    -- the menu's own OnLeave hides this tooltip again
    local tooltip = description.GetTooltipFrame and description:GetTooltipFrame()
        or GameTooltip
    local function Fill(tip) tip:SetText(text, 1, 1, 1) end
    if MenuUtil and MenuUtil.ShowTooltipEx then
        MenuUtil.ShowTooltipEx(button, tooltip, Fill)
    else
        tooltip:SetOwner(button, "ANCHOR_RIGHT")
        Fill(tooltip)
        tooltip:Show()
    end
end

-- Menu.ModifyMenu is the menu system's way in for addons: Blizzard's session list is
-- regenerated on every open and only its proxies see our hook
local sessionMenuHooked = false
local function HookSessionMenu()
    if sessionMenuHooked or not (Menu and Menu.ModifyMenu) then return end
    sessionMenuHooked = true
    Menu.ModifyMenu("MENU_DAMAGE_METER_SESSIONS", function(_, root)
        if db.summary == false or InCombatLockdown() then return end
        for _, description in root:EnumerateElementDescriptions() do
            local data = description.GetData and description:GetData()
            if type(data) == "table" and (data.sessionID or data.type) then
                description:HookOnEnter(function(button)
                    ShowSummary(button, description, data)
                end)
            end
        end
    end)
end

local function RegisterSettings()
    if category or not Settings or not Settings.RegisterVerticalLayoutCategory then
        return
    end
    local layout
    category, layout = Settings.RegisterVerticalLayoutCategory(NAME)
    if layout and CreateSettingsListSectionHeaderInitializer then
        layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Hover preview",
            "Out of combat only. A click on a row opens Blizzard's own breakdown;"
            .. " Shift-click keeps it open. The chat bubble in the preview's corner reports"
            .. " the spells to chat. " .. SLASH .. " help lists every command."))
    end
    local hover = Settings.RegisterAddOnSetting(category, "MEIOMETERHOVER_HOVER", "hover", db,
        Settings.VarType.Boolean, "Preview on hover", true)
    Settings.CreateCheckbox(category, hover, "Rest the mouse on a row of Blizzard's damage"
        .. " meter to see that player's spell breakdown beside the meter, out of combat."
        .. " A click still opens Blizzard's own. " .. SLASH .. " on||off does the same.")
    local delay = Settings.RegisterAddOnSetting(category, "MEIOMETERHOVER_OPEN_DELAY",
        "openDelay", db, Settings.VarType.Number, "Open delay", DEFAULT_DELAY)
    local options = Settings.CreateSliderOptions(0, MAX_DELAY, 0.05)
    options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right,
        function(v) return ("%.2f s"):format(v) end)
    Settings.CreateSlider(category, delay, options, "How long the mouse rests on a row"
        .. " before the preview opens. " .. SLASH .. " delay <seconds> does the same.")
    local share = Settings.RegisterAddOnSetting(category, "MEIOMETERHOVER_SHARE", "share", db,
        Settings.VarType.Boolean, "Share line", true)
    share:SetValueChangedCallback(function() UpdateShare() end)
    Settings.CreateCheckbox(category, share, "A line under the preview's spells. Damage"
        .. " Done and DPS: the pet's share, and DoT ticks against direct hits. Healing:"
        .. " Drain Life and Health Funnel against the rest. Damage Taken: who hit"
        .. " hardest. " .. SLASH .. " share on||off does the same.")
    local casts
    if ns.CASTS_LISTED then
        casts = Settings.RegisterAddOnSetting(category, "MEIOMETERHOVER_CASTS", "casts",
            db, Settings.VarType.Boolean, "Your casts", true)
        casts:SetValueChangedCallback(function() RefreshCasts() end)
        Settings.CreateCheckbox(category, casts, "On your own row, each spell shows how"
            .. " often you cast it that fight and how much it did per cast. Damage Done, DPS"
            .. " and healing only. Counted while you play, so fights from before a /reload"
            .. " show none. " .. SLASH .. " casts on||off does the same.")
    end
    local summary = Settings.RegisterAddOnSetting(category, "MEIOMETERHOVER_SUMMARY",
        "summary", db, Settings.VarType.Boolean, "Fight summary", true)
    Settings.CreateCheckbox(category, summary, "Hover a fight in the meter's session menu"
        .. " for one line: how long it lasted, your DPS and your pet's share. Out of"
        .. " combat only. " .. SLASH .. " summary on||off does the same.")
    Settings.RegisterAddOnCategory(category)
    settings.hover, settings.openDelay, settings.share = hover, delay, share
    settings.summary = summary
    settings.casts = casts
end

local function Help()
    local problem = MeterProblem()
    Print("rest the mouse on a damage meter row to preview its breakdown (out of combat);"
        .. " Shift-click keeps it open" .. (problem and (". |cffff8080" .. problem .. "|r") or ""))
    Line(Cmd(SLASH .. " on||off") .. " - the hover preview (now " .. OnOff(db.hover ~= false)
        .. ")")
    Line(Cmd(SLASH .. " report [n]") .. (" - post the last previewed player's top n"
        .. " spells (%d if left out) to group chat, or only to you when solo")
        :format(REPORT_SPELLS))
    Line(Cmd(SLASH .. " delay <seconds>") .. (" - wait before the preview opens (now %.2f)")
        :format(OpenDelay()))
    Line(Cmd(SLASH .. " share on||off") .. " - share line under the preview: pet and DoTs,"
        .. " Drain Life, top attacker (now " .. OnOff(db.share ~= false) .. ")")
    if ns.CASTS_LISTED then
        Line(Cmd(SLASH .. " casts on||off") .. " - on your own row: casts and amount per"
            .. " cast for each spell (now " .. OnOff(CastsOn()) .. ")")
    end
    Line(Cmd(SLASH .. " summary on||off") .. " - fight summary in the meter's session menu"
        .. " (now " .. OnOff(db.summary ~= false) .. ")")
    Line(Cmd(SLASH .. " help") .. " - this list")
    Line("Settings: " .. SETTINGS_PATH .. " (" .. Cmd(SLASH .. " settings") .. ")")
end

local function OpenSettings()
    if category then
        Settings.OpenToCategory(category:GetID())
    else
        Help()
    end
end

-- MeterHover is this addon before the Meio rename. With its folder still loaded both
-- would preview a row, so this one stays idle and leaves the old table to it. That folder
-- loads after this one, so hooks wait for login to know.
local function OldLoaded() return C_AddOns.IsAddOnLoaded("MeterHover") end

local function LoadDB()
    -- saved under the old name: a renamed file, or copied at logout while idle
    if not OldLoaded() then
        if not _G[SV_NAME] and type(MeterHoverDB) == "table" then
            _G[SV_NAME] = MeterHoverDB
        end
        MeterHoverDB = nil
    end
    _G[SV_NAME] = _G[SV_NAME] or {}
    db = _G[SV_NAME]
    db.pos = nil -- 1.0 moved Blizzard's breakdown; the preview isn't moved
    if db.hoverOff then db.hover = false end
    db.hoverOff = nil
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_LOGOUT")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
local loggedIn = false
events:SetScript("OnEvent", function(_, event, name)
    if event == "ADDON_LOADED" then
        if name == NAME then
            LoadDB()
        elseif name == "Blizzard_DamageMeter" and loggedIn and not OldLoaded() then
            HookMeter()
            HookSessionMenu()
        end
    elseif event == "PLAYER_LOGIN" then
        loggedIn = true
        if OldLoaded() then return end
        HookMeter()
        HookSessionMenu()
        local ok, err = pcall(RegisterSettings)
        if not ok then geterrorhandler()(err) end
        local problem = MeterProblem()
        if problem and not db.toldProblem then
            db.toldProblem = true
            Print(problem)
        elseif not problem then
            db.toldProblem = nil
        end
    elseif event == "PLAYER_LOGOUT" then
        -- next time, without the old folder, we start from its settings
        if OldLoaded() and type(MeterHoverDB) == "table" then
            _G[SV_NAME] = MeterHoverDB
        end
    else
        HidePreview()
    end
end)

-- .toc AddonCompartmentFunc
function MeioMeterHover_OnAddonCompartmentClick() OpenSettings() end

_G["SLASH_" .. NAME:upper() .. "1"] = SLASH
SlashCmdList[NAME:upper()] = function(msg)
    local word, rest = strtrim(msg or ""):lower():match("^(%S*)%s*(.-)$")
    if word == "" or word == "settings" or word == "options" then
        OpenSettings()
    elseif word == "help" or word == "?" then
        Help()
    elseif word == "on" or word == "off" then
        Set("hover", word == "on")
        if word == "off" then HidePreview() end
        Print("hover preview " .. OnOff(word == "on"))
    elseif word == "share" and (rest == "on" or rest == "off") then
        Set("share", rest == "on")
        UpdateShare()
        Print("share line " .. OnOff(rest == "on"))
    elseif word == "casts" and (rest == "on" or rest == "off") then
        Set("casts", rest == "on")
        RefreshCasts()
        Print("your casts " .. OnOff(rest == "on"))
    elseif word == "summary" and (rest == "on" or rest == "off") then
        Set("summary", rest == "on")
        Print("fight summary " .. OnOff(rest == "on"))
    elseif word == "report" and (rest == "" or tonumber(rest)) then
        Report("auto", tonumber(rest))
    elseif word == "delay" and tonumber(rest) then
        local d = math.min(math.max(tonumber(rest), 0), MAX_DELAY)
        d = math.floor(d * 20 + 0.5) / 20
        Set("openDelay", d)
        Print(("preview opens after %.2f s"):format(d))
    else
        Print(('unknown command "%s"'):format(strtrim(msg or "")))
        Help()
    end
end

-- While idle /meterhover is the old folder's: both claim the word
local oldFolder = CreateFrame("Frame")
oldFolder:RegisterEvent("PLAYER_LOGIN")
oldFolder:SetScript("OnEvent", function()
    if not OldLoaded() then return end
    if SlashCmdList.METERHOVER then
        SlashCmdList.MEIOMETERHOVER = SlashCmdList.METERHOVER
        if hash_SlashCmdList then
            hash_SlashCmdList["/METERHOVER"] = nil
        end
    end
    Print("the old MeterHover addon is still enabled, so MeioMeterHover is idle: disable"
        .. " MeterHover in the AddOns list and /reload (MeioMeterHover replaces it)")
end)
