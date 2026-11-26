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
--
-- On screen, top to bottom: the Disease/Poison icons Luffa would remove, the
-- Luffa icon (click it to equip Luffa and start its 30 second equip cooldown
-- while you travel), a gold arrow to the water, and what to do next.

local ADDON_NAME = ...
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

-- Fills `curables` with every Disease/Poison on the player and returns the
-- longest time left among them (0 if there are none).
-- Each entry: { name, icon, kind ("Disease"/"Poison"), left (seconds) }.
local curables, curableCount = {}, 0
local function ScanCurables()
    curableCount = 0
    local longest = 0
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return 0 end
    for i = 1, 40 do
        local aura = C_UnitAuras.GetAuraDataByIndex("player", i, "HARMFUL")
        if not aura then break end
        if CURABLE[aura.dispelName] then
            local expires = aura.expirationTime or 0
            local left = (expires > 0) and (expires - GetTime()) or math.huge
            curableCount = curableCount + 1
            local entry = curables[curableCount] or {}
            curables[curableCount] = entry
            entry.name, entry.icon, entry.kind, entry.left = aura.name, aura.icon, aura.dispelName, left
            if left > longest then
                longest = left
                -- Keep the longest one first: it is the reason the icon is up.
                curables[curableCount], curables[1] = curables[1], entry
            end
        end
    end
    return longest
end

-- Trinket slot Luffa is equipped into (13 = top, 14 = bottom). "/luffa slot"
-- sets it. Otherwise it avoids the slot SurfNTurf manages, and defaults to top.
local function LuffaSlot()
    local chosen = DB().slot
    if chosen == 13 or chosen == 14 then return chosen end
    if type(SurfNTurfDB) == "table" and SurfNTurfDB.trinketSlot == 13 then return 14 end
    return 13
end

local function EquipLuffa()
    if InCombat() then
        Print("trinkets can't be swapped in combat.")
    elseif LuffaEquipped() then
        Print("Luffa is already equipped.")
    elseif not HasLuffa() then
        Print("Luffa is not in your bags.")
    else
        local equip = EquipItemByName or (C_Item and C_Item.EquipItemByName)
        if equip then equip(LUFFA_ID, LuffaSlot()) end
    end
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

-- The Luffa icon is a button: click it to equip Luffa, shift-drag to move it.
local frame = CreateFrame("Button", "LuffaHelperFrame", UIParent)
frame:SetSize(52, 52)
frame:SetPoint("CENTER", UIParent, "CENTER", 0, 160)
frame:SetFrameStrata("HIGH")
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:RegisterForClicks("LeftButtonUp")
frame:Hide()

frame:SetScript("OnClick", function()
    if not IsShiftKeyDown() then EquipLuffa() end
end)
frame:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Luffa Helper")
    GameTooltip:AddLine("Click to equip Luffa.", 1, 1, 1)
    GameTooltip:AddLine("Shift-drag to move.", 1, 1, 1)
    GameTooltip:Show()
end)
frame:SetScript("OnLeave", function() GameTooltip:Hide() end)

frame:SetScript("OnDragStart", function(self)
    if IsShiftKeyDown() then
        self:StartMoving()
    else
        -- A click where the mouse slipped a little counts as a drag, and the
        -- game then skips OnClick, so treat it as the click it was meant to be.
        EquipLuffa()
    end
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

-- Arrow below the icon: a gold quest-style arrow image (Arrow.tga, drawn
-- pointing up) that is rotated to point at the water.
local arrowBox = CreateFrame("Frame", nil, frame)
arrowBox:SetSize(56, 56)
arrowBox:SetPoint("TOP", frame, "BOTTOM", 0, -6)

local arrow = arrowBox:CreateTexture(nil, "OVERLAY")
arrow:SetAllPoints(arrowBox)
arrow:SetTexture("Interface\\AddOns\\" .. ADDON_NAME .. "\\Arrow.tga")

-- rotation: radians, counter-clockwise, 0 = straight ahead (up on screen).
local function PointArrow(rotation)
    arrow:SetRotation(rotation)
end

local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
label:SetWidth(320)

-- Above the icon: the Diseases and Poisons Luffa would remove, each with a
-- border in its debuff colour and its time left, under a caption naming it.
local DEBUFF_SIZE, DEBUFF_GAP, MAX_DEBUFFS = 34, 8, 4
local KIND_COLOR = { Disease = { 0.72, 0.48, 0.05 }, Poison = { 0.1, 0.75, 0.1 } }
local debuffRow = CreateFrame("Frame", nil, frame)
debuffRow:SetSize(DEBUFF_SIZE, DEBUFF_SIZE)
debuffRow:SetPoint("BOTTOM", frame, "TOP", 0, 16)

local caption = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
caption:SetPoint("BOTTOM", debuffRow, "TOP", 0, 6)
caption:SetWidth(320)

local debuffSlots = {}
local function DebuffSlot(i)
    local slot = debuffSlots[i]
    if slot then return slot end
    slot = CreateFrame("Frame", nil, debuffRow)
    slot:SetSize(DEBUFF_SIZE, DEBUFF_SIZE)
    slot:SetPoint("LEFT", debuffRow, "LEFT", (i - 1) * (DEBUFF_SIZE + DEBUFF_GAP), 0)
    slot.border = slot:CreateTexture(nil, "BACKGROUND")
    slot.border:SetPoint("TOPLEFT", slot, "TOPLEFT", -3, 3)
    slot.border:SetPoint("BOTTOMRIGHT", slot, "BOTTOMRIGHT", 3, -3)
    slot.icon = slot:CreateTexture(nil, "ARTWORK")
    slot.icon:SetAllPoints(slot)
    slot.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    slot.time = slot:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    slot.time:SetPoint("BOTTOMRIGHT", slot, "BOTTOMRIGHT", -1, 2)
    debuffSlots[i] = slot
    return slot
end

local function ShowDebuffs()
    local shown = math.min(curableCount, MAX_DEBUFFS)
    for i = 1, shown do
        local entry, slot = curables[i], DebuffSlot(i)
        local color = KIND_COLOR[entry.kind] or KIND_COLOR.Disease
        slot.border:SetColorTexture(color[1], color[2], color[3], 1)
        slot.icon:SetTexture(entry.icon or 134400)
        if entry.left == math.huge then
            slot.time:SetText("")
        elseif entry.left >= 60 then
            slot.time:SetFormattedText("%dm", math.ceil(entry.left / 60))
        else
            slot.time:SetFormattedText("%d", math.max(0, math.ceil(entry.left)))
        end
        slot:Show()
    end
    for i = shown + 1, #debuffSlots do debuffSlots[i]:Hide() end
    debuffRow:SetShown(shown > 0)
    caption:SetShown(shown > 0)
    if shown > 0 then
        debuffRow:SetWidth(shown * DEBUFF_SIZE + (shown - 1) * DEBUFF_GAP)
        local first = curables[1]
        local text = ("%s: %s"):format(first.kind or "Disease", first.name or "?")
        if curableCount > 1 then text = text .. (" (+%d more)"):format(curableCount - 1) end
        caption:SetText(text)
    end
end

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
    if forced then
        -- Preview: scan real debuffs if out of combat, else show an example one.
        if not InCombat() then ScanCurables() else curableCount = 0 end
        if curableCount == 0 then
            curableCount = 1
            local entry = curables[1] or {}
            curables[1] = entry
            entry.name, entry.icon, entry.kind, entry.left = "Example Disease", 134400, "Disease", 120
        end
        return true
    end
    if InCombat() or not HasLuffa() then return false end
    -- The 45 second rule only matters while Luffa is still in the bags. Once it
    -- is equipped, the debuff just has to outlast the remaining cooldown, so the
    -- icon stays up while you travel to water.
    local need = LuffaCooldownLeft() + COOLDOWN_MARGIN
    if not LuffaEquipped() then need = math.max(MIN_REMAINING, need) end
    return ScanCurables() > need
end

-- First line of the label: what to do about Luffa itself right now.
local function LuffaLine(inWater)
    if not LuffaEquipped() then
        return "|cff40ff40Click the icon to equip Luffa|r"
    end
    local cd = LuffaCooldownLeft()
    if cd > 0 then
        return ("Luffa ready in %ds"):format(math.ceil(cd))
    end
    return inWater and "|cff40ff40Use Luffa now!|r" or "Luffa is ready"
end

local function Refresh()
    if not ShouldShow() then
        frame:Hide()
        return
    end
    frame:Show()
    ShowDebuffs()

    if InWater() then
        ShowArrow(false)
        label:SetText(LuffaLine(true) .. "\nYou are in water")
        return
    end

    local luffaLine = LuffaLine(false)
    local north, west, inst = PlayerPos()
    local facing = GetPlayerFacing and GetPlayerFacing()
    if not north or type(facing) ~= "number" then
        ShowArrow(false)
        label:SetText(luffaLine .. "\nFind water")
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
        label:SetText(luffaLine .. "\nNo water known nearby")
        return
    end

    local dn, dw = spotN - north, spotW - west
    local dist = math.sqrt(dn * dn + dw * dw)
    if dist < ARRIVE_RADIUS then
        ShowArrow(false)
        label:SetText(luffaLine .. "\nWater is right here - step in\n(/luffa bad if there is none)")
        return
    end

    -- Bearing to the spot, counter-clockwise from north, same as GetPlayerFacing.
    PointArrow(math.atan2(dw, dn) - facing)
    ShowArrow(true)
    label:SetText(("%s\nWater: %d yd"):format(luffaLine, dist))
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

    elseif cmd == "slot" then
        -- Cycle: automatic -> top -> bottom -> automatic
        local db = DB()
        if db.slot == 13 then db.slot = 14 elseif db.slot == 14 then db.slot = nil else db.slot = 13 end
        Print(("clicking the icon equips Luffa in the %s trinket slot%s."):format(
            LuffaSlot() == 13 and "top" or "bottom", db.slot and "" or " (automatic)"))

    elseif cmd == "status" then
        Print(("Luffa equips into the %s trinket slot."):format(LuffaSlot() == 13 and "top" or "bottom"))
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
        print("  /luffa slot - choose which trinket slot Luffa is equipped into")
        print("  /luffa bad - hide the spot the arrow points at (no water there)")
        print("  /luffa reset - bring back all hidden spots")
        print("  /luffa mark - save a water spot where you stand")
        print("  /luffa status - show what the addon currently sees")
    end
end
