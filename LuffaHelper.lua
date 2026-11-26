-- Luffa Helper (WoW Forever, interface 16001)
--
-- Shows the Luffa icon with a pulsing highlight, and an arrow to the nearest
-- known water spot, when ALL of these are true:
--   * you are out of combat
--   * Luffa (item 19141) is in your bags or equipped
--   * you have a Disease or Poison with more than 45 seconds left
--     (and longer than Luffa's own remaining cooldown)
--
-- The game has no API for "where is water". Water_0.lua and Water_1.lua hold
-- about 30,900 spots read from the game's own map data: oceans, lakes, ponds,
-- rivers and creeks, plus the Stormwind canals and Orgrimmar's water. Wells,
-- fountains, moonwells, puddles and cave pools are left out. On top of
-- that, every place you swim is remembered (account-wide), "/luffa mark" adds
-- the spot you stand on, and "/luffa bad" hides a spot that turned out wrong.

local LUFFA_ID = 19141
local LUFFA_ICON = 132911        -- inv_fabric_wool_01
local MIN_REMAINING = 45         -- seconds; trinket equip cooldown is 30
local COOLDOWN_MARGIN = 5        -- debuff must outlast Luffa's cooldown by this
local SPOT_SPACING = 40          -- yards between remembered water spots
local UPDATE_EVERY = 0.1         -- seconds between refreshes
local LEARN_EVERY = 1            -- seconds between "am I swimming" checks
local CURABLE = { Disease = true, Poison = true }

local forced = false             -- "/luffa test" preview
local lastError

local function Print(msg)
    print("|cff66ccffLuffa Helper:|r " .. tostring(msg))
end

------------------------------------------------------------------------------
-- Saved data
------------------------------------------------------------------------------

local function DB()
    if type(LuffaHelperDB) ~= "table" then LuffaHelperDB = {} end
    if type(LuffaHelperDB.spots) ~= "table" then LuffaHelperDB.spots = {} end
    if type(LuffaHelperDB.bad) ~= "table" then LuffaHelperDB.bad = {} end
    return LuffaHelperDB
end

------------------------------------------------------------------------------
-- Game state helpers
------------------------------------------------------------------------------

-- World position in yards: "north" grows to the north, "west" grows to the west.
-- Returns nil where the game hides position (dungeons and other instances).
local function PlayerPos()
    if not UnitPosition then return nil end
    local ok, north, west, _, inst = pcall(UnitPosition, "player")
    if ok and type(north) == "number" and type(west) == "number" and inst ~= nil then
        return north, west, inst
    end
    return nil
end

local function InWater()
    return (IsSwimming and IsSwimming()) or (IsSubmerged and IsSubmerged()) or false
end

local function InCombat()
    return (InCombatLockdown and InCombatLockdown())
        or (UnitAffectingCombat and UnitAffectingCombat("player"))
        or false
end

local function LuffaEquipped()
    return (C_Item and C_Item.IsEquippedItem and C_Item.IsEquippedItem(LUFFA_ID))
        or (IsEquippedItem and IsEquippedItem(LUFFA_ID))
        or false
end

local function HasLuffa()
    if LuffaEquipped() then return true end
    local count
    if C_Item and C_Item.GetItemCount then
        count = C_Item.GetItemCount(LUFFA_ID)
    elseif GetItemCount then
        count = GetItemCount(LUFFA_ID)
    end
    return (count or 0) > 0
end

local function LuffaCooldownLeft()
    local start, duration
    if C_Container and C_Container.GetItemCooldown then
        start, duration = C_Container.GetItemCooldown(LUFFA_ID)
    elseif GetItemCooldown then
        start, duration = GetItemCooldown(LUFFA_ID)
    end
    if start and duration and start > 0 and duration > 0 then
        return math.max(0, start + duration - GetTime())
    end
    return 0
end

-- Returns the name and seconds left of a Disease/Poison lasting longer than `need`.
local function FindCurable(need)
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return nil end
    for i = 1, 40 do
        local aura = C_UnitAuras.GetAuraDataByIndex("player", i, "HARMFUL")
        if not aura then break end
        if CURABLE[aura.dispelName] then
            local expires = aura.expirationTime or 0
            local left = (expires > 0) and (expires - GetTime()) or math.huge
            if left > need then
                return aura.name, left
            end
        end
    end
    return nil
end

------------------------------------------------------------------------------
-- Water spots
------------------------------------------------------------------------------

local TILE = 533.33333           -- yards per map tile
local MID = 32 * TILE
local BAD_RADIUS = 30            -- "/luffa bad" hides spots within this many yards

-- Spots the player reported as not working ("/luffa bad"): n1, w1, n2, w2, ...
local function IsBad(north, west, inst)
    local list = DB().bad[inst]
    if not list then return false end
    for i = 1, #list, 2 do
        local dn, dw = list[i] - north, list[i + 1] - west
        if dn * dn + dw * dw < BAD_RADIUS * BAD_RADIUS then return true end
    end
    return false
end

-- Learned/marked spots, stored per continent as a flat list: n1, w1, n2, w2, ...
local function NearestSpot(north, west, inst, skipBad)
    local list = DB().spots[inst]
    if not list then return nil end
    local bestIndex, bestSq
    for i = 1, #list, 2 do
        local dn, dw = list[i] - north, list[i + 1] - west
        local sq = dn * dn + dw * dw
        if (not bestSq or sq < bestSq)
            and not (skipBad and IsBad(list[i], list[i + 1], inst)) then
            bestIndex, bestSq = i, sq
        end
    end
    if not bestIndex then return nil end
    return list[bestIndex], list[bestIndex + 1], math.sqrt(bestSq), bestIndex
end

-- Preloaded spots from the game's map data (Water_0.lua, Water_1.lua).
-- LuffaHelperWater[continent][tileRow * 64 + tileCol] = { offN * 600 + offW, ... }
-- Searches the player's tile first, then widening rings of tiles around it.
local function NearestPreloaded(north, west, inst)
    local data = LuffaHelperWater and LuffaHelperWater[inst]
    if not data then return nil end
    local a, b = MID - north, MID - west
    local tn, tw = math.floor(a / TILE), math.floor(b / TILE)
    local bestA, bestB, bestSq
    for ring = 0, 12 do
        for dn = -ring, ring do
            -- top and bottom rows of the ring: every tile; other rows: the two ends
            local step = (dn == -ring or dn == ring) and 1 or (2 * ring)
            for dw = -ring, ring, step do
                local rn, rw = tn + dn, tw + dw
                local list = rn >= 0 and rn < 64 and rw >= 0 and rw < 64 and data[rn * 64 + rw]
                if list then
                    local baseA, baseB = rn * TILE + 0.5, rw * TILE + 0.5
                    for i = 1, #list do
                        local v = list[i]
                        local sa = baseA + math.floor(v / 600)
                        local sb = baseB + v % 600
                        local da, db = sa - a, sb - b
                        local sq = da * da + db * db
                        if (not bestSq or sq < bestSq) and not IsBad(MID - sa, MID - sb, inst) then
                            bestA, bestB, bestSq = sa, sb, sq
                        end
                    end
                end
            end
        end
        -- Anything in tiles not yet searched is at least `ring` tiles away.
        if bestSq and bestSq <= (ring * TILE) * (ring * TILE) then break end
    end
    if not bestSq then return nil end
    return MID - bestA, MID - bestB, math.sqrt(bestSq)
end

-- Nearest usable water from either source.
local function FindWater(north, west, inst)
    local n1, w1, d1 = NearestPreloaded(north, west, inst)
    local n2, w2, d2 = NearestSpot(north, west, inst, true)
    if d2 and (not d1 or d2 < d1) then return n2, w2 end
    return n1, w1
end

local function AddSpot(north, west, inst)
    local spots = DB().spots
    local _, _, dist = NearestSpot(north, west, inst)
    if dist and dist < SPOT_SPACING then return false end
    local list = spots[inst]
    if not list then
        list = {}
        spots[inst] = list
    end
    list[#list + 1] = math.floor(north + 0.5)
    list[#list + 1] = math.floor(west + 0.5)
    return true
end

local function CountSpots()
    local total = 0
    for _, list in pairs(DB().spots) do
        total = total + #list / 2
    end
    return total
end

------------------------------------------------------------------------------
-- Display
------------------------------------------------------------------------------

local frame = CreateFrame("Frame", "LuffaHelperFrame", UIParent)
frame:SetSize(52, 52)
frame:SetPoint("CENTER", UIParent, "CENTER", 0, 160)
frame:SetFrameStrata("HIGH")
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:Hide()

frame:SetScript("OnDragStart", function(self)
    if IsShiftKeyDown() then self:StartMoving() end
end)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint(1)
    DB().pos = { point, relPoint, x, y }
end)

-- Pulsing gold highlight behind the icon.
local glow = frame:CreateTexture(nil, "BACKGROUND")
glow:SetPoint("TOPLEFT", frame, "TOPLEFT", -5, 5)
glow:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 5, -5)
glow:SetColorTexture(1, 0.82, 0, 1)

local pulse = glow:CreateAnimationGroup()
pulse:SetLooping("BOUNCE")
local fade = pulse:CreateAnimation("Alpha")
fade:SetFromAlpha(1)
fade:SetToAlpha(0.15)
fade:SetDuration(0.6)
frame:SetScript("OnShow", function()
    pulse:Play()
    -- Ask the game for Luffa's real icon; keep the built-in one if it has none.
    local tex = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(LUFFA_ID)
    if tex then frame.icon:SetTexture(tex) end
end)
frame:SetScript("OnHide", function() pulse:Stop() end)

local icon = frame:CreateTexture(nil, "ARTWORK")
icon:SetAllPoints(frame)
icon:SetTexture(LUFFA_ICON)
icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
frame.icon = icon

-- Arrow below the icon, drawn with three lines so no image file is needed.
local arrowBox = CreateFrame("Frame", nil, frame)
arrowBox:SetSize(52, 52)
arrowBox:SetPoint("TOP", frame, "BOTTOM", 0, -8)

local function NewLine()
    local line = arrowBox:CreateLine(nil, "OVERLAY")
    line:SetColorTexture(0.3, 0.85, 1, 1)
    line:SetThickness(5)
    return line
end
local shaft, wingA, wingB = NewLine(), NewLine(), NewLine()

-- rotation: radians, counter-clockwise, 0 = straight ahead (up on screen).
local function PointArrow(rotation)
    local function dir(r, len) return -math.sin(r) * len, math.cos(r) * len end
    local tipX, tipY = dir(rotation, 22)
    local ax, ay = dir(rotation + 0.55, 16)
    local bx, by = dir(rotation - 0.55, 16)
    shaft:SetStartPoint("CENTER", arrowBox, -tipX, -tipY)
    shaft:SetEndPoint("CENTER", arrowBox, tipX, tipY)
    wingA:SetStartPoint("CENTER", arrowBox, tipX, tipY)
    wingA:SetEndPoint("CENTER", arrowBox, tipX - ax, tipY - ay)
    wingB:SetStartPoint("CENTER", arrowBox, tipX, tipY)
    wingB:SetEndPoint("CENTER", arrowBox, tipX - bx, tipY - by)
end

local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
label:SetWidth(260)

local function ShowArrow(shown)
    arrowBox:SetShown(shown)
    label:ClearAllPoints()
    if shown then
        label:SetPoint("TOP", arrowBox, "BOTTOM", 0, -4)
    else
        label:SetPoint("TOP", frame, "BOTTOM", 0, -8)
    end
end

------------------------------------------------------------------------------
-- Main update
------------------------------------------------------------------------------

local RETARGET_EVERY = 0.5       -- seconds between nearest-water searches
local ARRIVE_RADIUS = 6          -- yards; closer than this counts as "at the spot"
local target = {}                -- north, west, inst, time of the current spot

local function ShouldShow()
    if forced then return true end
    if InCombat() or not HasLuffa() then return false end
    -- The 45 second rule only matters while Luffa is still in the bags. Once it
    -- is equipped, the debuff just has to outlast the remaining cooldown, so the
    -- icon stays up while you travel to water.
    local need = LuffaCooldownLeft() + COOLDOWN_MARGIN
    if not LuffaEquipped() then need = math.max(MIN_REMAINING, need) end
    return FindCurable(need) ~= nil
end

local function Refresh()
    if not ShouldShow() then
        frame:Hide()
        return
    end
    frame:Show()

    if InWater() then
        ShowArrow(false)
        local cd = LuffaCooldownLeft()
        if cd > 0 then
            label:SetFormattedText("In water - Luffa ready in %ds", math.ceil(cd))
        elseif LuffaEquipped() then
            label:SetText("In water - use Luffa!")
        else
            label:SetText("In water - equip and use Luffa!")
        end
        return
    end

    local north, west, inst = PlayerPos()
    local facing = GetPlayerFacing and GetPlayerFacing()
    if not north or type(facing) ~= "number" then
        ShowArrow(false)
        label:SetText("Luffa: find water")
        return
    end

    -- Finding the nearest spot is the costly part, so redo it twice a second;
    -- the arrow itself still turns on every refresh.
    local now = GetTime()
    if target.inst ~= inst or now - (target.time or 0) > RETARGET_EVERY then
        target.north, target.west = FindWater(north, west, inst)
        target.inst, target.time = inst, now
    end
    local spotN, spotW = target.north, target.west
    if not spotN then
        ShowArrow(false)
        label:SetText("Luffa: no water known nearby")
        return
    end

    local dn, dw = spotN - north, spotW - west
    local dist = math.sqrt(dn * dn + dw * dw)
    if dist < ARRIVE_RADIUS then
        ShowArrow(false)
        label:SetText("Water is right here - step in\n(/luffa bad if there is none)")
        return
    end

    -- Bearing to the spot, counter-clockwise from north, same as GetPlayerFacing.
    PointArrow(math.atan2(dw, dn) - facing)
    ShowArrow(true)
    label:SetFormattedText("Water: %d yd", dist)
end

local function Learn()
    if not InWater() then return end
    local north, west, inst = PlayerPos()
    if north then AddSpot(north, west, inst) end
end

local function RestorePosition()
    local pos = DB().pos
    if type(pos) == "table" and pos[1] then
        frame:ClearAllPoints()
        frame:SetPoint(pos[1], UIParent, pos[2] or pos[1], pos[3] or 0, pos[4] or 0)
    end
end

-- The driver is a separate, always-running frame; `frame` itself gets hidden.
local driver = CreateFrame("Frame")
local sinceRefresh, sinceLearn, restored = 0, 0, false
driver:SetScript("OnUpdate", function(_, elapsed)
    sinceRefresh = sinceRefresh + elapsed
    sinceLearn = sinceLearn + elapsed
    if sinceRefresh < UPDATE_EVERY then return end
    sinceRefresh = 0

    if not restored then
        restored = true
        pcall(RestorePosition)
    end

    -- pcall: if the client refuses to hand over a value (hidden "secret" data),
    -- hide quietly instead of spamming errors. "/luffa status" shows the reason.
    local ok, err = pcall(Refresh)
    if not ok then
        lastError = err
        frame:Hide()
    end

    if sinceLearn >= LEARN_EVERY then
        sinceLearn = 0
        local okLearn, errLearn = pcall(Learn)
        if not okLearn then lastError = errLearn end
    end
end)

------------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------------

SLASH_LUFFAHELPER1 = "/luffa"
SlashCmdList["LUFFAHELPER"] = function(msg)
    local cmd = (msg or ""):lower():match("^%s*(%S*)")

    if cmd == "test" then
        forced = not forced
        Print(forced and "preview ON (type /luffa test again to turn it off). Shift-drag the icon to move it."
            or "preview off.")

    elseif cmd == "mark" then
        local north, west, inst = PlayerPos()
        if not north then
            Print("can't read your position here.")
        elseif AddSpot(north, west, inst) then
            Print("water spot saved here.")
        else
            Print("there is already a water spot within " .. SPOT_SPACING .. " yards.")
        end

    elseif cmd == "bad" then
        -- Hide the spot the arrow is pointing at (it did not work or can't be reached).
        local north, west, inst = PlayerPos()
        -- Look the spot up fresh unless the arrow updated it a moment ago.
        if north and (target.inst ~= inst or not target.time
            or GetTime() - target.time > RETARGET_EVERY) then
            target.north, target.west = FindWater(north, west, inst)
            target.inst, target.time = inst, GetTime()
        end
        if not north or not target.north then
            Print("no water spot is being pointed at right now.")
        else
            local bad = DB().bad
            bad[inst] = bad[inst] or {}
            table.insert(bad[inst], target.north)
            table.insert(bad[inst], target.west)
            target.time = nil
            Print(("hid that spot and anything within %d yards of it. /luffa reset brings hidden spots back.")
                :format(BAD_RADIUS))
        end

    elseif cmd == "reset" then
        DB().bad = {}
        target.time = nil
        Print("all hidden spots are back.")

    elseif cmd == "status" then
        local preloaded = 0
        for _, tiles in pairs(LuffaHelperWater or {}) do
            for _, list in pairs(tiles) do preloaded = preloaded + #list end
        end
        local hidden = 0
        for _, list in pairs(DB().bad) do hidden = hidden + #list / 2 end
        Print(("Luffa in bags/equipped: %s. In water now: %s."):format(
            HasLuffa() and "yes" or "no", InWater() and "yes" or "no"))
        Print(("Water spots: %d built in, %d learned or marked, %d hidden."):format(
            preloaded, CountSpots(), hidden))
        if lastError then Print("last problem: " .. tostring(lastError)) end

    else
        Print("commands:")
        print("  /luffa test - preview the icon and arrow (shift-drag to move)")
        print("  /luffa bad - hide the spot the arrow points at (no water there)")
        print("  /luffa reset - bring back all hidden spots")
        print("  /luffa mark - save a water spot where you stand")
        print("  /luffa status - show what the addon currently sees")
    end
end
