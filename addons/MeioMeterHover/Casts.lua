-- Your own casts per meter session: the meter keeps one total per spell and no casts, so
-- they are counted here from your cast events and filed under the meter's session for
-- that fight. In memory only: after a /reload older fights show no casts.

local _, ns = ...

local PRE_PULL = 6 -- seconds before combat whose casts count towards the fight
local SAME_CAST = 0.3 -- a channel reports both SUCCEEDED and CHANNEL_START
local FILE_TRIES, FILE_RETRY = 4, 0.5
local MELEE = { [1] = true, [6603] = true }

local IsSecret = issecretvalue or function() return false end
local GetSpellName = C_Spell and C_Spell.GetSpellName or GetSpellInfo

local function Readable(v)
    if v == nil or IsSecret(v) then return false end
    if canaccessvalue then
        local ok, allowed = pcall(canaccessvalue, v)
        return not ok or allowed ~= false
    end
    return true
end

local pending = {} -- spellID -> GetTime() of each cast not yet filed under a fight
local lastCast = {}
local bySession = {} -- meter sessionID -> spellID -> casts
local overall = {} -- since the meter was last reset
local lastFight -- { sid = sessionID or nil, counts = {} }
local inFight, fightSession = false, nil

local function Wipe()
    wipe(bySession)
    wipe(overall)
    lastFight = nil
end

local function CountCast(id)
    if not Readable(id) or type(id) ~= "number" or MELEE[id] then return end
    local now = GetTime()
    if lastCast[id] and now - lastCast[id] < SAME_CAST then return end
    lastCast[id] = now
    local list = pending[id] or {}
    list[#list + 1] = now
    pending[id] = list
end

-- combat started: only the casts just before it (the pull) belong to this fight
local function TrimToPull()
    local cutoff = GetTime() - PRE_PULL
    for id, list in pairs(pending) do
        local keep = {}
        for _, t in ipairs(list) do if t >= cutoff then keep[#keep + 1] = t end end
        pending[id] = #keep > 0 and keep or nil
    end
end

local function TakeCasts()
    local counts, any = {}, false
    for id, list in pairs(pending) do counts[id], any = #list, true end
    wipe(pending)
    return any and counts
end

-- the meter's session IDs as a set, and the newest; nil when the list can't be read
local function Sessions()
    local api = C_DamageMeter
    if not api or not api.GetAvailableCombatSessions then return end
    local ok, list = pcall(api.GetAvailableCombatSessions)
    if not ok or type(list) ~= "table" then return end
    local set, newest = {}, nil
    for _, s in ipairs(list) do
        local sid = type(s) == "table" and s.sessionID
        if Readable(sid) and type(sid) == "number" then
            set[sid] = true
            if not newest or sid > newest then newest = sid end
        end
    end
    return set, newest
end

-- sessions the meter dropped lose their casts; all gone means the meter was reset. One
-- newer than the list's newest is kept: the list can lag behind the fight's end.
local function Prune(set, newest)
    if not newest then return end
    local had, kept = false, false
    for sid in pairs(bySession) do
        had = true
        if set[sid] or sid > newest then kept = true else bySession[sid] = nil end
    end
    if had and not kept then Wipe() end
end

local function Add(into, counts)
    for id, n in pairs(counts) do into[id] = (into[id] or 0) + n end
end

local function File(counts, tries)
    -- a new pull came first: its session is not this fight's
    if inFight then return Add(overall, counts) end
    local sid = fightSession
    if not sid then
        local set, newest = Sessions()
        -- the meter may list the fight a moment after combat ends
        if (not newest or bySession[newest]) and tries > 0 then
            C_Timer.After(FILE_RETRY, function() File(counts, tries - 1) end)
            return
        end
        if newest and not bySession[newest] then sid = newest end
        Prune(set, newest)
    end
    if sid then
        bySession[sid] = bySession[sid] or {}
        Add(bySession[sid], counts)
    end
    Add(overall, counts)
    lastFight = { sid = sid, counts = counts }
end

-- spellID -> casts for the session the meter window shows, or nil
function ns.SessionCasts(sessionType, sessionID)
    local kinds = Enum.DamageMeterSessionType or {}
    local set, newest = Sessions()
    if not inFight then Prune(set, newest) end
    if sessionID then return bySession[sessionID] end
    if sessionType == kinds.Overall then return next(overall) and overall or nil end
    if sessionType == kinds.Current then
        if lastFight and (not newest or not lastFight.sid or lastFight.sid == newest) then
            return lastFight.counts
        end
        return newest and bySession[newest]
    end
end

-- casts behind a meter row: its own spell, the spell that triggered it, or (area hits under
-- another ID) your casts of that name that have no row of their own
function ns.CastsFor(counts, spellID, ownRows)
    if not counts or not Readable(spellID) or MELEE[spellID] then return end
    local n = counts[spellID] or counts[ns.TRIGGERED[spellID] or 0]
    if n then return n end
    local name = GetSpellName(spellID)
    if not name or not Readable(name) then return end
    local sum = 0
    for id, k in pairs(counts) do
        if not ownRows[id] and GetSpellName(id) == name then sum = sum + k end
    end
    return sum > 0 and sum or nil
end

local events = CreateFrame("Frame")
events:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
events:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("DAMAGE_METER_COMBAT_SESSION_UPDATED")
events:RegisterEvent("DAMAGE_METER_RESET")
events:SetScript("OnEvent", function(_, event, a1, a2, a3)
    if event == "DAMAGE_METER_RESET" then return Wipe() end
    if not ns.CastsOn() then return end
    if event == "UNIT_SPELLCAST_SUCCEEDED" or event == "UNIT_SPELLCAST_CHANNEL_START" then
        if a1 == "player" then CountCast(a3) end
    elseif event == "DAMAGE_METER_COMBAT_SESSION_UPDATED" then
        -- one event names the ongoing fight's session (the other is Overall, 0)
        if inFight and Readable(a2) and type(a2) == "number" and a2 ~= 0 then
            fightSession = a2
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        inFight, fightSession = true, nil
        TrimToPull()
    elseif event == "PLAYER_REGEN_ENABLED" then
        inFight = false
        local counts = TakeCasts()
        if counts then File(counts, FILE_TRIES) end
    elseif event == "DAMAGE_METER_RESET" then
        Wipe()
    end
end)
