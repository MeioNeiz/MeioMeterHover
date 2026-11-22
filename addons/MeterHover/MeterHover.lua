-- MeterHover: rest the mouse on a row of Blizzard's damage meter to preview its
-- breakdown (the spell list a click opens). Out of combat only: in combat the meter's
-- data is secret.
--
-- The preview is our own copy of Blizzard's breakdown window. Blizzard's own breakdown is
-- never opened, moved or hidden from here: one our code had written to taints Blizzard's
-- later reads of it, which fail in combat ("attempt to compare ... secret ... tainted").
-- A click on a row stays Blizzard's own (Shift-click keeps it open).

local NAME = "MeterHover"
local SV_NAME = "MeterHoverDB"
local SLASH = "/meterhover"
local TEMPLATE = "DamageMeterSourceWindowTemplate"

local OPEN_DELAY = 0.15
local CLOSE_DELAY = 0.3

local db = {}
local preview
local hookedWindows, hookedRows = {}, {}
local rowWindow = setmetatable({}, { __mode = "k" })
local rowData = setmetatable({}, { __mode = "k" })
local pending = { row = nil, at = 0 }
local shown = { row = nil, window = nil, awaySince = nil }
local poller = CreateFrame("Frame")
poller:Hide()

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff8788ee" .. NAME .. "|r: " .. msg)
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

-- one meter row's breakdown, or nil when it can't be read (combat, secret, no spells)
local function FetchSource(window, data)
    local meterType = window:GetDamageMeterType()
    local sessionType, sessionID = window:GetSessionType(), window:GetSessionID()
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

-- the row's source with only the fields the breakdown reads, or nil if any is secret
local function RowSource(row)
    local data = rowData[row] or (row.GetElementData and row:GetElementData())
    if type(data) ~= "table" then return end
    local source = {
        sourceGUID = data.sourceGUID, sourceCreatureID = data.sourceCreatureID,
        totalAmount = data.totalAmount, name = data.name,
        classFilename = data.classFilename,
        showsValuePerSecondAsPrimary = data.showsValuePerSecondAsPrimary,
    }
    if AnySecret(source, 0) or IsSecret(data.deathRecapID) then return end
    -- a death row opens the death recap instead of a breakdown
    if data.deathRecapID and data.deathRecapID ~= 0 then return end
    if not source.sourceGUID and not source.sourceCreatureID then return end
    return source
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
    p:SetSticky(false)
    -- always take the meter window's height, as Blizzard's does the first time it opens
    p.previousSessionWindowCenterX = nil
    p:AnchorToSessionWindow(window)
    local width = real:GetWidth()
    if width and width > 0 then p:SetWidth(width) end
    p:SetAlpha(window:GetEffectiveAlpha())
    p:Show()
    CopySkin(real, row)
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
    if db.hoverOff or InCombatLockdown() then return end
    pending.row, pending.at = row, GetTime() + OPEN_DELAY
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
    for i = 1, MAX_DAMAGE_METER_SESSION_WINDOWS or 3 do
        HookWindow(_G["DamageMeterSessionWindow" .. i])
    end
    if meter.SetupSessionWindow then
        hooksecurefunc(meter, "SetupSessionWindow", function(_, _, windowData)
            HookWindow(windowData and windowData.sessionWindow)
        end)
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
        elseif name == "Blizzard_DamageMeter" then
            HookMeter()
        end
    elseif event == "PLAYER_LOGIN" then
        HookMeter()
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

_G["SLASH_" .. NAME:upper() .. "1"] = SLASH
SlashCmdList[NAME:upper()] = function(msg)
    msg = strtrim(msg or ""):lower()
    if msg == "off" then
        db.hoverOff = true
        HidePreview()
        Print("hover preview off. " .. SLASH .. " on turns it back on.")
        return
    elseif msg == "on" then
        db.hoverOff = nil
        Print("hover preview on.")
        return
    elseif msg ~= "" then
        Print("unknown command: " .. msg)
    end
    Print("rest the mouse on a damage meter row to preview its breakdown"
        .. " (out of combat).")
    Print("Click a row for Blizzard's own breakdown; Shift-click keeps it open.")
    Print(SLASH .. " off, " .. SLASH .. " on: turn the hover preview off or on (now "
        .. (db.hoverOff and "off" or "on") .. ")")
    local problem = MeterProblem()
    if problem then Print(problem) end
end
