-- MeterHover: rest the mouse on a row of Blizzard's damage meter to preview its
-- breakdown (the spell list a click opens). Out of combat only: in combat the meter's
-- data is secret.
--
-- The preview is our own copy of Blizzard's breakdown window. Blizzard's own breakdown is
-- never opened, moved or hidden from here: one our code had written to taints Blizzard's
-- later reads of it, which fail in combat ("attempt to compare ... secret ... tainted").
-- A click on a row stays Blizzard's own (Shift-click keeps it open).

local _, ns = ...
local NAME = "MeterHover"
local SV_NAME = "MeterHoverDB"
local SLASH = "/meterhover"
local TEMPLATE = "DamageMeterSourceWindowTemplate"

local DEFAULT_DELAY = 0.15
local MAX_DELAY = 1
local CLOSE_DELAY = 0.3
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
    if AnySecret(source, 3) or #source.combatSpells == 0 then return end
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
    if not ok or type(session) ~= "table" or type(session.combatSources) ~= "table"
        or AnySecret(session, 2) then
        return
    end
    local parts = {}
    local duration = tonumber(session.durationSeconds)
    if duration and duration > 0 then
        parts[1] = ("%s %s"):format(Gold("Duration"), SecondsToClock(duration))
    end
    local me
    for _, source in ipairs(session.combatSources) do
        if type(source) == "table" and source.isLocalPlayer then me = source end
    end
    if not me then
        parts[#parts + 1] = "no damage from you"
        return table.concat(parts, ", ")
    end
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

local function SetEntryFonts(entry)
    local fonts, bar = preview and preview.fonts, entry.StatusBar
    if not fonts or not bar or not bar.Name or not bar.Value then return end
    bar.Name:SetFont(unpack(fonts.name))
    bar.Value:SetFont(unpack(fonts.value))
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
    -- in the strip under the spell list (Blizzard insets the list 17 px from the bottom)
    local share = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    share:SetPoint("BOTTOMLEFT", 20, 3)
    share:SetPoint("BOTTOMRIGHT", -22, 3)
    share:SetJustifyH("LEFT")
    share:SetWordWrap(false)
    frame.Share = share
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
    p:SetSticky(false)
    -- always take the meter window's height, as Blizzard's does the first time it opens
    p.previousSessionWindowCenterX = nil
    p:AnchorToSessionWindow(window)
    local width = real:GetWidth()
    if width and width > 0 then p:SetWidth(width) end
    p:SetAlpha(window:GetEffectiveAlpha())
    p:Show()
    CopySkin(real, row)
    UpdateShare()
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
        elseif (shown.row and shown.row:IsMouseOver()) or preview:IsMouseOver() then
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
            .. " Shift-click keeps it open. " .. SLASH .. " help lists every command."))
    end
    local hover = Settings.RegisterAddOnSetting(category, "METERHOVER_HOVER", "hover", db,
        Settings.VarType.Boolean, "Preview on hover", true)
    Settings.CreateCheckbox(category, hover, "Rest the mouse on a row of Blizzard's damage"
        .. " meter to see that player's spell breakdown beside the meter, out of combat."
        .. " A click still opens Blizzard's own. " .. SLASH .. " on||off does the same.")
    local delay = Settings.RegisterAddOnSetting(category, "METERHOVER_OPEN_DELAY",
        "openDelay", db, Settings.VarType.Number, "Open delay", DEFAULT_DELAY)
    local options = Settings.CreateSliderOptions(0, MAX_DELAY, 0.05)
    options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right,
        function(v) return ("%.2f s"):format(v) end)
    Settings.CreateSlider(category, delay, options, "How long the mouse rests on a row"
        .. " before the preview opens. " .. SLASH .. " delay <seconds> does the same.")
    local share = Settings.RegisterAddOnSetting(category, "METERHOVER_SHARE", "share", db,
        Settings.VarType.Boolean, "Share line", true)
    share:SetValueChangedCallback(function() UpdateShare() end)
    Settings.CreateCheckbox(category, share, "A line under the preview's spells. Damage"
        .. " Done and DPS: the pet's share, and DoT ticks against direct hits. Healing:"
        .. " Drain Life and Health Funnel against the rest. Damage Taken: who hit"
        .. " hardest. " .. SLASH .. " share on||off does the same.")
    local summary = Settings.RegisterAddOnSetting(category, "METERHOVER_SUMMARY",
        "summary", db, Settings.VarType.Boolean, "Fight summary", true)
    Settings.CreateCheckbox(category, summary, "Hover a fight in the meter's session menu"
        .. " for one line: how long it lasted, your DPS and your pet's share. Out of"
        .. " combat only. " .. SLASH .. " summary on||off does the same.")
    Settings.RegisterAddOnCategory(category)
    settings.hover, settings.openDelay, settings.share = hover, delay, share
    settings.summary = summary
end

local function Help()
    Print("rest the mouse on a damage meter row to preview its breakdown (out of combat)")
    Line(Cmd(SLASH .. " on||off") .. " - the hover preview (now " .. OnOff(db.hover ~= false)
        .. ")")
    Line(Cmd(SLASH .. " delay <seconds>") .. (" - wait before the preview opens (now %.2f)")
        :format(OpenDelay()))
    Line(Cmd(SLASH .. " share on||off") .. " - share line under the preview: pet and DoTs,"
        .. " Drain Life, top attacker (now " .. OnOff(db.share ~= false) .. ")")
    Line(Cmd(SLASH .. " summary on||off") .. " - fight summary in the meter's session menu"
        .. " (now " .. OnOff(db.summary ~= false) .. ")")
    Line(Cmd(SLASH .. " help") .. " - this list")
    Line("|cff999999Click a row for Blizzard's own breakdown; Shift-click keeps it open.|r")
    local problem = MeterProblem()
    if problem then Line("|cffff8080" .. problem .. "|r") end
    Line("Settings: " .. SETTINGS_PATH .. " (" .. Cmd(SLASH .. " settings") .. ")")
end

local function OpenSettings()
    if category then
        Settings.OpenToCategory(category:GetID())
    else
        Help()
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:SetScript("OnEvent", function(_, event, name)
    if event == "ADDON_LOADED" then
        if name == NAME then
            _G[SV_NAME] = _G[SV_NAME] or {}
            db = _G[SV_NAME]
            db.pos = nil -- 1.0 moved Blizzard's breakdown; the preview isn't moved
            if db.hoverOff then db.hover = false end
            db.hoverOff = nil
        elseif name == "Blizzard_DamageMeter" then
            HookMeter()
            HookSessionMenu()
        end
    elseif event == "PLAYER_LOGIN" then
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
    else
        HidePreview()
    end
end)

-- .toc AddonCompartmentFunc
function MeterHover_OnAddonCompartmentClick() OpenSettings() end

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
    elseif word == "summary" and (rest == "on" or rest == "off") then
        Set("summary", rest == "on")
        Print("fight summary " .. OnOff(rest == "on"))
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
