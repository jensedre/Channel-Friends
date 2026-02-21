-- ============================================================
-- ChannelFriends.lua
-- A saveable friend list built from your joined chat channels.
--
-- BEGINNER NOTES:
--   * Everything in WoW addons is driven by "events" (things
--     that happen in the game) and "frames" (UI windows/widgets).
--   * SavedVariables (ChannelFriendsDB) are automatically saved
--     to disk when you log out and reloaded on login.
--   * "this" inside OnEvent/OnClick handlers refers to the frame
--     that registered the event/received the click.
-- ============================================================


-- -------------------------------------------------------
-- 1. SAVED DATA
--    ChannelFriendsDB persists between sessions.
--    It is declared in the .toc as a SavedVariable.
-- -------------------------------------------------------
-- ChannelFriendsDB will look like:
--   { ["PlayerName"] = true, ["OtherPlayer"] = true, ... }


-- -------------------------------------------------------
-- 2. RUNTIME STATE  (lives only while you're logged in)
-- -------------------------------------------------------
local CF_CHANNEL      = "KnightGuard"   -- the one channel this addon manages
local selectedChannel = CF_CHANNEL      -- always selected
local entryFrames     = {}

-- Cache for player info — populated from friends list and guild roster.
-- CF_classCache[name] = "WARRIOR" (uppercase English class name, persists session)
-- CF_zoneCache[name]  = "Elwynn Forest" (refreshed each time we open the window)
local CF_classCache = {}
local CF_zoneCache  = {}

-- Class colours matching the standard WoW class colours (r, g, b)
local CF_CLASS_COLORS = {
    WARRIOR   = { 0.78, 0.61, 0.43 },
    PALADIN   = { 0.96, 0.55, 0.73 },
    HUNTER    = { 0.67, 0.83, 0.45 },
    ROGUE     = { 1.00, 0.96, 0.41 },
    PRIEST    = { 1.00, 1.00, 1.00 },
    SHAMAN    = { 0.00, 0.44, 0.87 },
    MAGE      = { 0.41, 0.80, 0.94 },
    WARLOCK   = { 0.58, 0.51, 0.79 },
    DRUID     = { 1.00, 0.49, 0.04 },
}

-- -------------------------------------------------------
-- 3. CONSTANTS  – tweak these to change the look
-- -------------------------------------------------------
local WINDOW_W     = 280
local WINDOW_H     = 500   -- taller to fit 2-line rows
local ROW_HEIGHT   = 30    -- name line + zone line
local MAX_VISIBLE  = 10


-- -------------------------------------------------------
-- 4. UTILITY HELPERS
-- -------------------------------------------------------

-- CF_CHANNEL is hardcoded to KnightGuard above.
-- GetChannelName(CF_CHANNEL) returns its numeric slot when joined.

-- Scans the friends list and guild roster to populate class and zone caches.
-- Call this on window open so zone data is fresh.
local function CF_ScanPlayerInfo()
    -- Scan friends list: GetFriendInfo returns name, level, class, area, connected
    local numFriends = GetNumFriends()
    for i = 1, numFriends do
        local name, level, class, area, connected = GetFriendInfo(i)
        if name then
            if class and class ~= "" and class ~= "Unknown" then
                -- Friends list returns localised class names, store as-is
                -- and map to our colour table via an English lookup below
                CF_classCache[name] = class
            end
            if area and area ~= "" and area ~= "Unknown" then
                CF_zoneCache[name] = area
            end
        end
    end

    -- Scan guild roster: GetGuildRosterInfo returns name, rank, rankIndex,
    -- level, class, zone, note, officernote, online, status
    local numGuild = GetNumGuildMembers(true)  -- true = include offline
    if numGuild then
        for i = 1, numGuild do
            local name, rank, rankIndex, level, class, zone, note, officernote, online =
                GetGuildRosterInfo(i)
            if name then
                if class and class ~= "" then
                    CF_classCache[name] = class
                end
                if online and zone and zone ~= "" then
                    CF_zoneCache[name] = zone
                end
            end
        end
    end
end

-- Maps a localised or English class name to our colour table key (uppercase English).
local CF_CLASS_NAME_MAP = {
    -- English
    ["Warrior"] = "WARRIOR",   ["Paladin"] = "PALADIN",
    ["Hunter"]  = "HUNTER",    ["Rogue"]   = "ROGUE",
    ["Priest"]  = "PRIEST",    ["Shaman"]  = "SHAMAN",
    ["Mage"]    = "MAGE",      ["Warlock"] = "WARLOCK",
    ["Druid"]   = "DRUID",
    -- Already uppercase (from guild roster classFileName)
    ["WARRIOR"] = "WARRIOR",   ["PALADIN"] = "PALADIN",
    ["HUNTER"]  = "HUNTER",    ["ROGUE"]   = "ROGUE",
    ["PRIEST"]  = "PRIEST",    ["SHAMAN"]  = "SHAMAN",
    ["MAGE"]    = "MAGE",      ["WARLOCK"] = "WARLOCK",
    ["DRUID"]   = "DRUID",
}

local function CF_GetClassColor(name)
    local class = CF_classCache[name]
    if not class then return 1, 1, 1 end
    local key = CF_CLASS_NAME_MAP[class]
    if not key then return 1, 1, 1 end
    local c = CF_CLASS_COLORS[key]
    if not c then return 1, 1, 1 end
    return c[1], c[2], c[3]
end

-- -------------------------------------------------------
-- CHANNEL COLOR FUNCTIONS
-- Defined early so the Join button and init frame can use them.
-- -------------------------------------------------------

local function CF_SetChannelColor()
    local chanIdx = GetChannelName(CF_CHANNEL)
    if chanIdx and chanIdx ~= 0 then
        ChangeChatColor("CHANNEL" .. chanIdx, 0.4, 0.85, 1.0)
        -- Also ensure the channel is visible in the default chat frame.
        -- ChatFrame_AddChannel is safe to call multiple times on the same channel.
        ChatFrame_AddChannel(DEFAULT_CHAT_FRAME, CF_CHANNEL)
        return true
    end
    return false
end

local CF_colorRetries = 0
local CF_colorTimer = CreateFrame("Frame")
CF_colorTimer:Hide()
CF_colorTimer:SetScript("OnUpdate", function()
    if CF_SetChannelColor() then
        CF_colorTimer:Hide()
        CF_colorRetries = 0
    else
        CF_colorRetries = CF_colorRetries + 1
        if CF_colorRetries > 20 then
            CF_colorTimer:Hide()
            CF_colorRetries = 0
        end
    end
end)

local function CF_ScheduleColorSet()
    CF_colorRetries = 0
    CF_colorTimer:Show()
end


-- Returns a table of player names currently in a named channel.
-- In vanilla 1.12 there is no API to directly read channel members.
-- The only way is: call ListChannelByName(name), which asks the server
-- to send the list. The server responds by firing CHAT_MSG_CHANNEL_LIST
-- with arg1 = a string like "Members of General(12): Alice, Bob, Carol, "
-- We register for that event, parse the names, then refresh the UI.

local CF_pendingChannel = nil   -- channel we are waiting on
local CF_members        = {}    -- last parsed member list

local function CF_RequestMembers(channelName)
    CF_pendingChannel = channelName
    CF_members        = {}
    ListChannelByName(channelName)   -- asks server; response comes via event
end

-- Parse the member string the server sends back.
-- Format: "Members of ChannelName(count): Name1, Name2, Name3, "
local function CF_ParseMemberString(text)
    local members = {}
    -- Turtle WoW sends arg1 as a raw name list: "Nightfoxx, *Zradca"
    -- Older format A: "Members of KnightGuard(2): Nightfoxx, *Zradca"  -> after ": "
    -- Older format B: "[6. KnightGuard] Nightfoxx, *Zradca"            -> after "] "
    -- We try each in order and fall back to the raw text itself.
    local _, _, rest = string.find(text, ": (.+)")
    if not rest then
        local _, _, r2 = string.find(text, "%] (.+)")
        rest = r2
    end
    if not rest then rest = text end

    local i = 1
    while i <= string.len(rest) do
        local s, e, name = string.find(rest, "([^,]+)", i)
        if not s then break end
        name = string.gsub(name, "^%s+", "")     -- trim leading space
        name = string.gsub(name, "%s+$", "")     -- trim trailing space
        name = string.gsub(name, "^[%*%+]+", "") -- strip * (owner) + (moderator) prefixes
        if string.len(name) > 0 then
            table.insert(members, name)
        end
        i = e + 1
    end
    table.sort(members)
    return members
end

-- Event listener for the server's channel list response.
local cfEventFrame = CreateFrame("Frame")
cfEventFrame:RegisterEvent("CHAT_MSG_CHANNEL_LIST")
cfEventFrame:SetScript("OnEvent", function()
    if not CF_pendingChannel then return end
    -- In Turtle WoW 1.12: arg1 = member list, arg9 = channel name
    local chanName = tostring(arg9 or "")
    local lowerPending = string.lower(CF_pendingChannel)
    local _, _, shortMatch = string.find(lowerPending, "^(.-)%s*%-")
    local shortPending = shortMatch or lowerPending

    if string.find(string.lower(chanName), shortPending, 1, true) then
        CF_members        = CF_ParseMemberString(tostring(arg1 or ""))
        CF_pendingChannel = nil
        if ChannelFriends_RefreshList then
            ChannelFriends_RefreshList()
        end
    end
end)

-- Checks whether a player is currently online (in your friends list or guild).
-- In vanilla 1.12 there is no cross-realm presence API, so we check:
--   a) Are they in our saved friends list and currently online?
--   b) Are they visible in the channel right now (they must be online for that)?
-- We'll mark them green if they're in the channel, grey otherwise.
local function IsOnlineInChannel(name)
    for _, m in ipairs(CF_members) do
        if m == name then return true end
    end
    return false
end


-- -------------------------------------------------------
-- 5. MAIN WINDOW
-- -------------------------------------------------------

-- Create the outer window frame.
local f = CreateFrame("Frame", "ChannelFriendsFrame", UIParent)
f:SetWidth(WINDOW_W)
f:SetHeight(WINDOW_H)
f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
f:SetBackdrop({
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left=11, right=12, top=12, bottom=11 }
})
f:SetBackdropColor(0, 0, 0, 0.9)
f:SetMovable(true)
f:EnableMouse(true)
f:RegisterForDrag("LeftButton")
f:SetScript("OnDragStart", function() this:StartMoving() end)
f:SetScript("OnDragStop",  function() this:StopMovingOrSizing() end)
f:Hide()   -- hidden by default; shown via /cf or the button below
f:SetScript("OnShow", function()
    CF_ScanPlayerInfo()   -- refresh zone and class cache from friends/guild
    CF_members = {}
    CF_RequestMembers(CF_CHANNEL)
end)

-- Title bar text
local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", f, "TOP", 0, -16)
title:SetText("Channel Friends")

-- Close button (the X in the corner)
local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -5, -5)
closeBtn:SetScript("OnClick", function() f:Hide() end)


-- -------------------------------------------------------
-- 6. CHANNEL HEADER
--    Fixed to KnightGuard — shows channel name, join button, and refresh.
-- -------------------------------------------------------

-- "Channel:" label
local channelLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
channelLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -42)
channelLabel:SetText("Channel:")

-- Channel name display (static, gold coloured)
local channelName = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
channelName:SetPoint("LEFT", channelLabel, "RIGHT", 8, 0)
channelName:SetText("|cffffd700" .. CF_CHANNEL .. "|r")

-- Join button — joins KnightGuard if not already in it
local joinBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
joinBtn:SetWidth(50)
joinBtn:SetHeight(22)
joinBtn:SetPoint("RIGHT", f, "RIGHT", -70, 0)
joinBtn:SetPoint("TOP",   f, "TOP",   0,  -36)
joinBtn:SetText("Join")
-- Adds KnightGuard to DEFAULT_CHAT_FRAME display if not already shown.
local function CF_AddChannelToChat()
    local idx = GetChannelName(CF_CHANNEL)
    if idx and idx ~= 0 then
        ChatFrame_AddChannel(DEFAULT_CHAT_FRAME, CF_CHANNEL)
        return true
    end
    return false
end

-- Second-stage timer: waits ~2s after joining before requesting member list.
local CF_memberRequestDelay = 0
local CF_memberRequestTimer = CreateFrame("Frame")
CF_memberRequestTimer:Hide()
CF_memberRequestTimer:SetScript("OnUpdate", function()
    CF_memberRequestDelay = CF_memberRequestDelay + 1
    if CF_memberRequestDelay >= 60 then
        CF_memberRequestTimer:Hide()
        CF_memberRequestDelay = 0
        CF_members = {}
        CF_RequestMembers(CF_CHANNEL)
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffChannelFriends:|r Requesting member list...")
    end
end)

local function CF_ScheduleMemberRequest()
    CF_memberRequestDelay = 0
    CF_memberRequestTimer:Show()
end

-- Polls until channel is registered then sets color, adds to chat, and schedules member refresh.
local CF_setupRetries = 0
local CF_setupTimer = CreateFrame("Frame")
CF_setupTimer:Hide()
CF_setupTimer:SetScript("OnUpdate", function()
    local idx = GetChannelName(CF_CHANNEL)
    if idx and idx ~= 0 then
        ChangeChatColor("CHANNEL" .. idx, 0.4, 0.85, 1.0)
        ChatFrame_AddChannel(DEFAULT_CHAT_FRAME, CF_CHANNEL)
        if not f:IsShown() then f:Show() end
        CF_ScheduleMemberRequest()  -- waits ~2s then requests member list
        CF_setupTimer:Hide()
        CF_setupRetries = 0
    else
        CF_setupRetries = CF_setupRetries + 1
        if CF_setupRetries > 60 then
            CF_setupTimer:Hide()
            CF_setupRetries = 0
            DEFAULT_CHAT_FRAME:AddMessage("|cffff4444ChannelFriends:|r Could not join " .. CF_CHANNEL .. ".")
        end
    end
end)

local function CF_ScheduleSetup()
    CF_setupRetries = 0
    CF_setupTimer:Show()
end

joinBtn:SetScript("OnClick", function()
    local idx = GetChannelName(CF_CHANNEL)
    if idx and idx ~= 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffChannelFriends:|r Already in " .. CF_CHANNEL .. ".")
        CF_SetChannelColor()
        CF_AddChannelToChat()
    else
        JoinChannelByName(CF_CHANNEL)
        CF_ScheduleSetup()   -- polls until joined then sets color + adds to chat
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffChannelFriends:|r Joining " .. CF_CHANNEL .. "...")
    end
end)
joinBtn:SetScript("OnEnter", function()
    GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
    GameTooltip:SetText("Join " .. CF_CHANNEL .. "\nif not already in it")
    GameTooltip:Show()
end)
joinBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- Refresh button
local refreshBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
refreshBtn:SetWidth(60)
refreshBtn:SetHeight(22)
refreshBtn:SetPoint("RIGHT", f, "RIGHT", -8, 0)
refreshBtn:SetPoint("TOP",   f, "TOP",   0, -36)
refreshBtn:SetText("Refresh")
refreshBtn:SetScript("OnClick", function()
    CF_RequestMembers(CF_CHANNEL)
end)



-- -------------------------------------------------------
-- 7. SCROLL FRAME  (the list of names)
-- -------------------------------------------------------

-- Simple list container - no scroll template, just a plain clipping frame
local listFrame = CreateFrame("Frame", nil, f)
listFrame:SetWidth(WINDOW_W - 32)
listFrame:SetHeight(MAX_VISIBLE * ROW_HEIGHT)
listFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -65)

-- Scroll offset (how many rows down we've scrolled)
local CF_scrollOffset = 0
local CF_totalRows    = 0

local function CF_ScrollUp()
    if CF_scrollOffset > 0 then
        CF_scrollOffset = CF_scrollOffset - 1
        ChannelFriends_RefreshList()
    end
end

local function CF_ScrollDown()
    if CF_scrollOffset < CF_totalRows - MAX_VISIBLE then
        CF_scrollOffset = CF_scrollOffset + 1
        ChannelFriends_RefreshList()
    end
end

-- Mouse wheel scrolling on the list
listFrame:EnableMouseWheel(true)
listFrame:SetScript("OnMouseWheel", function()
    if arg1 > 0 then CF_ScrollUp() else CF_ScrollDown() end
end)

-- Up/down arrow buttons on the right side
local scrollUpBtn = CreateFrame("Button", nil, f, "UIPanelScrollUpButtonTemplate")
scrollUpBtn:SetWidth(16)
scrollUpBtn:SetHeight(16)
scrollUpBtn:SetPoint("TOPRIGHT", listFrame, "TOPRIGHT", 18, 0)
scrollUpBtn:SetScript("OnClick", CF_ScrollUp)

local scrollDownBtn = CreateFrame("Button", nil, f, "UIPanelScrollDownButtonTemplate")
scrollDownBtn:SetWidth(16)
scrollDownBtn:SetHeight(16)
scrollDownBtn:SetPoint("BOTTOMRIGHT", listFrame, "BOTTOMRIGHT", 18, 0)
scrollDownBtn:SetScript("OnClick", CF_ScrollDown)

-- Row frames are children of listFrame directly
local scrollChild = listFrame   -- alias so row creation code below still works

-- Pre-create MAX_VISIBLE row frames (we reuse them).
for i = 1, MAX_VISIBLE do
    local row = CreateFrame("Button", nil, scrollChild)
    row:SetWidth(WINDOW_W - 50)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 4, -(i-1) * ROW_HEIGHT)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    -- Coloured dot: green = online, grey = offline
    local dot = row:CreateTexture(nil, "OVERLAY")
    dot:SetWidth(8)
    dot:SetHeight(8)
    dot:SetPoint("LEFT", row, "LEFT", 4, 0)
    dot:SetTexture("Interface\\CHARACTERFRAME\\UI-StateIcon")
    dot:SetTexCoord(0.125, 0.25, 0, 1)  -- use a simple square portion of the texture
    row.dot = dot

    -- Player name (top line)
    local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameText:SetPoint("TOPLEFT", row, "TOPLEFT", 18, -2)
    nameText:SetPoint("RIGHT", row, "RIGHT", -60, 0)
    nameText:SetJustifyH("LEFT")
    row.nameText = nameText

    -- Zone text (bottom line, smaller and grey)
    local zoneText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    zoneText:SetPoint("TOPLEFT", nameText, "BOTTOMLEFT", 0, -1)
    zoneText:SetPoint("RIGHT", row, "RIGHT", -60, 0)
    zoneText:SetJustifyH("LEFT")
    zoneText:SetTextColor(0.6, 0.6, 0.6)
    row.zoneText = zoneText

    -- Save/remove label on the right (not a button, just text — click the row)
    local actionText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    actionText:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    actionText:SetJustifyH("RIGHT")
    row.actionText = actionText

    -- Tooltip on hover
    row:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        local tip = row.playerName or "?"
        if row.isSaved then
            tip = tip .. "\nLeft-click: Target\nRight-click: Whisper\nShift-click: Remove from saved\nCtrl-click: Invite to group"
        else
            tip = tip .. "\nLeft-click: Target\nRight-click: Whisper\nShift-click: Save\nCtrl-click: Invite to group"
        end
        GameTooltip:SetText(tip)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- Left-click = target, Right-click = whisper, Shift-click = save/remove, Ctrl-click = invite
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function()
        if not row.playerName then return end
        if arg1 == "RightButton" then
            ChatFrame_OpenChat("/w " .. row.playerName .. " ")
        elseif IsControlKeyDown() then
            InviteByName(row.playerName)
        elseif IsShiftKeyDown() then
            if row.isSaved then
                ChannelFriendsDB[row.playerName] = nil
            else
                ChannelFriendsDB[row.playerName] = true
            end
            ChannelFriends_RefreshList()
        else
            TargetByName(row.playerName)
        end
    end)

    row:Hide()
    row.dot:Hide()
    row.zoneText:Hide()
    entryFrames[i] = row
end


-- -------------------------------------------------------
-- 8. STATUS / DIVIDER LINE  (drawn below the scroll list)
-- -------------------------------------------------------

local divider = f:CreateTexture(nil, "ARTWORK")
divider:SetHeight(2)
divider:SetWidth(WINDOW_W - 30)
divider:SetPoint("TOPLEFT", f, "TOPLEFT", 15, -(70 + MAX_VISIBLE * ROW_HEIGHT + 8))
divider:SetTexture("Interface\\Tooltips\\UI-Tooltip-Border")

local statusText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
-- Anchor from the BOTTOM so it always sits just above the buttons regardless of window size
statusText:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 15, 44)
statusText:SetTextColor(0.7, 0.7, 0.7)


-- -------------------------------------------------------
-- 9. BOTTOM BUTTONS
-- -------------------------------------------------------

-- "Add all from channel" – saves every current channel member to the list.
local addAllBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
addAllBtn:SetWidth(130)
addAllBtn:SetHeight(24)
addAllBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 15, 14)
addAllBtn:SetText("Add All From Channel")
addAllBtn:SetScript("OnClick", function()
    if not selectedChannel then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff9900ChannelFriends:|r Please select a channel first.")
        return
    end
    if table.getn(CF_members) == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff9900ChannelFriends:|r No members loaded yet — hit Refresh first.")
        return
    end
    local added = 0
    for _, name in ipairs(CF_members) do
        if not ChannelFriendsDB[name] then
            ChannelFriendsDB[name] = true
            added = added + 1
        end
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00ChannelFriends:|r Added " .. added .. " players.")
    ChannelFriends_RefreshList()
end)

-- "Clear All" – removes everyone from the saved list.
local clearBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
clearBtn:SetWidth(90)
clearBtn:SetHeight(24)
clearBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -15, 14)
clearBtn:SetText("Clear All")
clearBtn:SetScript("OnClick", function()
    StaticPopupDialogs["CF_CONFIRM_CLEAR"] = {
        text    = "Remove ALL players from your Channel Friends list?",
        button1 = "Yes",
        button2 = "No",
        OnAccept = function()
            ChannelFriendsDB = {}
            ChannelFriends_RefreshList()
            DEFAULT_CHAT_FRAME:AddMessage("|cffff4444ChannelFriends:|r List cleared.")
        end,
        timeout   = 0,
        whileDead = false,
        hideOnEscape = true,
    }
    StaticPopup_Show("CF_CONFIRM_CLEAR")
end)


-- -------------------------------------------------------
-- 10. REFRESH FUNCTION
--     Populates the scroll list based on:
--       a) If a channel is selected: shows that channel's members.
--       b) Always shows your saved friends with online status.
-- -------------------------------------------------------

function ChannelFriends_RefreshList()
    -- Ensure DB exists (first login before any saves).
    if not ChannelFriendsDB then ChannelFriendsDB = {} end

    local displayList = {}

    if selectedChannel then
        -- Show the last fetched member list (populated by CF_RequestMembers).
        for _, name in ipairs(CF_members) do
            table.insert(displayList, {
                name   = name,
                saved  = ChannelFriendsDB[name] == true,
                online = true,   -- they're in the channel response, so online
            })
        end
    else
        -- No channel selected: show only saved friends with online check.
        for name, _ in pairs(ChannelFriendsDB) do
            table.insert(displayList, {
                name   = name,
                saved  = true,
                online = false,   -- can't check without a channel reference
            })
        end
        table.sort(displayList, function(a, b) return a.name < b.name end)
    end

    local total = table.getn(displayList)
    CF_totalRows = total
    local offset = CF_scrollOffset
    -- Clamp offset in case list shrank
    if offset > total - MAX_VISIBLE then
        CF_scrollOffset = math.max(0, total - MAX_VISIBLE)
        offset = CF_scrollOffset
    end

    for i = 1, MAX_VISIBLE do
        local idx  = i + offset
        local data = displayList[idx]
        local row  = entryFrames[i]

        if data then
            row.playerName = data.name
            row.isSaved    = data.saved

            -- Name coloured purely by class, no tinting for saved status
            local cr, cg, cb = CF_GetClassColor(data.name)
            row.nameText:SetTextColor(cr, cg, cb)
            row.nameText:SetText(data.name)

            -- Zone line
            local zone = CF_zoneCache[data.name]
            if zone then
                row.zoneText:SetText(zone)
            else
                row.zoneText:SetText("|cff555555Unknown zone|r")
            end

            -- Online dot
            if data.online then
                row.dot:SetVertexColor(0, 1, 0)
            else
                row.dot:SetVertexColor(0.5, 0.5, 0.5)
            end

            -- Right side save status
            if data.saved then
                row.actionText:SetText("|cffaaaaaa[saved]|r")
            else
                row.actionText:SetText("|cff44ff44[+save]|r")
            end

            row:Show()
            row.dot:Show()
            row.zoneText:Show()
        else
            row:Hide()
            row.dot:Hide()
            row.nameText:SetText("")
            row.actionText:SetText("")
            row.zoneText:SetText("")
        end
    end

    -- Update the count text at the bottom.
    local savedCount = 0
    for _ in pairs(ChannelFriendsDB) do savedCount = savedCount + 1 end
    if CF_pendingChannel then
        statusText:SetText("Requesting " .. CF_pendingChannel .. " list...")
    else
        statusText:SetText(
            total .. " shown  |  " .. savedCount .. " saved"
            .. (selectedChannel and ("  |  " .. selectedChannel) or "")
        )
    end
end




-- -------------------------------------------------------
-- 11. MINIMAP BUTTON
--     A draggable button on the minimap to open/close the window.
-- -------------------------------------------------------

-- -------------------------------------------------------
-- 11. MINIMAP BUTTON
--     Styled as a proper circular minimap button with a
--     friends-list icon, matching the look of other addons.
-- -------------------------------------------------------

local minimapBtn = CreateFrame("Button", "ChannelFriendsMinimapBtn", Minimap)
minimapBtn:SetWidth(33)
minimapBtn:SetHeight(33)
minimapBtn:SetFrameStrata("MEDIUM")
minimapBtn:SetFrameLevel(8)
minimapBtn:SetPoint("TOPLEFT", Minimap, "TOPLEFT", 18, -18)

-- Icon background: 21x21 at TOPLEFT 7,-6 (exact ItemRack values)
local minimapBg = minimapBtn:CreateTexture(nil, "BACKGROUND")
minimapBg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
minimapBg:SetWidth(21)
minimapBg:SetHeight(21)
minimapBg:SetPoint("TOPLEFT", minimapBtn, "TOPLEFT", 7, -6)
minimapBg:SetVertexColor(0.5, 0.08, 0.08)

-- KG text over the icon area
local minimapText = minimapBtn:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
minimapText:SetWidth(21)
minimapText:SetHeight(21)
minimapText:SetPoint("TOPLEFT", minimapBtn, "TOPLEFT", 7, -6)
minimapText:SetJustifyH("CENTER")
minimapText:SetJustifyV("MIDDLE")
minimapText:SetText("|cffd4a017KG|r")

-- Border: 56x56 at TOPLEFT 0,0 (exact ItemRack values)
local minimapBorder = minimapBtn:CreateTexture(nil, "OVERLAY")
minimapBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
minimapBorder:SetWidth(56)
minimapBorder:SetHeight(56)
minimapBorder:SetPoint("TOPLEFT", minimapBtn, "TOPLEFT", 0, 0)

-- Highlight (no explicit size, matches ItemRack)
local minimapHighlight = minimapBtn:CreateTexture(nil, "HIGHLIGHT")
minimapHighlight:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
minimapHighlight:SetBlendMode("ADD")
minimapHighlight:SetAllPoints(minimapBtn)

minimapBtn:SetScript("OnMouseDown", function()
    minimapBg:SetPoint("TOPLEFT", minimapBtn, "TOPLEFT", 8, -7)
    minimapText:SetPoint("TOPLEFT", minimapBtn, "TOPLEFT", 8, -7)
end)
minimapBtn:SetScript("OnMouseUp", function()
    minimapBg:SetPoint("TOPLEFT", minimapBtn, "TOPLEFT", 7, -6)
    minimapText:SetPoint("TOPLEFT", minimapBtn, "TOPLEFT", 7, -6)
end)

minimapBtn:SetScript("OnClick", function()
    if f:IsShown() then
        f:Hide()
    else
        f:Show()   -- OnShow fires automatically and triggers refresh
    end
end)

minimapBtn:SetScript("OnEnter", function()
    GameTooltip:SetOwner(this, "ANCHOR_LEFT")
    GameTooltip:SetText("Channel Friends\nClick to open/close")
    GameTooltip:Show()
end)
minimapBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)


-- -------------------------------------------------------
-- 12. FLOATING "KG" BUTTON
--     A draggable action-bar-sized badge that opens/closes
--     the main window. Position is saved between sessions.
-- -------------------------------------------------------

local kgBtn = CreateFrame("Button", "ChannelFriendsKGButton", UIParent)
kgBtn:SetWidth(36)
kgBtn:SetHeight(36)
kgBtn:SetFrameStrata("MEDIUM")
kgBtn:SetMovable(true)
kgBtn:EnableMouse(true)
kgBtn:RegisterForDrag("LeftButton")
kgBtn:RegisterForClicks("RightButtonUp")

-- Restore saved position or default to bottom-right area
kgBtn:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -250, 120)

-- Background texture — dark action-button style
local kgBg = kgBtn:CreateTexture(nil, "BACKGROUND")
kgBg:SetAllPoints(kgBtn)
kgBg:SetTexture("Interface\\Buttons\\UI-Quickslot2")
kgBg:SetVertexColor(0.6, 0.1, 0.1)   -- dark red tint to match KnightGuard theme

-- Border/highlight frame texture
local kgBorder = kgBtn:CreateTexture(nil, "OVERLAY")
kgBorder:SetAllPoints(kgBtn)
kgBorder:SetTexture("Interface\\Buttons\\UI-Quickslot-Depress")
kgBorder:SetAlpha(0.8)

-- "KG" text label
local kgText = kgBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
kgText:SetAllPoints(kgBtn)
kgText:SetJustifyH("CENTER")
kgText:SetJustifyV("MIDDLE")
kgText:SetText("|cffd4a017KG|r")   -- warm gold colour

-- Pushed effect — darken slightly on click
kgBtn:SetScript("OnMouseDown", function()
    kgBg:SetVertexColor(0.4, 0.05, 0.05)
    kgText:SetPoint("CENTER", kgBtn, "CENTER", 1, -1)
end)
kgBtn:SetScript("OnMouseUp", function()
    kgBg:SetVertexColor(0.6, 0.1, 0.1)
    kgText:SetPoint("CENTER", kgBtn, "CENTER", 0, 0)
end)

-- Drag to reposition — only start dragging after mouse has moved a little
local kgDragging = false
kgBtn:SetScript("OnDragStart", function()
    kgDragging = true
    kgBtn:StartMoving()
end)
kgBtn:SetScript("OnDragStop", function()
    kgDragging = false
    kgBtn:StopMovingOrSizing()
    -- Save position so it persists between sessions
    local point, _, relPoint, x, y = kgBtn:GetPoint()
    if ChannelFriendsDB then
        ChannelFriendsDB["__kgBtnPoint"]    = point
        ChannelFriendsDB["__kgBtnRelPoint"] = relPoint
        ChannelFriendsDB["__kgBtnX"]        = x
        ChannelFriendsDB["__kgBtnY"]        = y
    end
end)

-- Left-click toggles the main window (right-click reserved, does nothing)
kgBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
kgBtn:SetScript("OnClick", function()
    if kgDragging then return end
    if arg1 == "RightButton" then return end
    if f:IsShown() then
        f:Hide()
    else
        f:Show()
    end
end)

-- Tooltip
kgBtn:SetScript("OnEnter", function()
    GameTooltip:SetOwner(this, "ANCHOR_TOP")
    GameTooltip:SetText("|cffd4a017KnightGuard|r\nClick to open friends list\nDrag to move")
    GameTooltip:Show()
end)
kgBtn:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

-- Restore saved position on login
local kgPosFrame = CreateFrame("Frame")
kgPosFrame:RegisterEvent("PLAYER_LOGIN")
kgPosFrame:SetScript("OnEvent", function()
    if ChannelFriendsDB and ChannelFriendsDB["__kgBtnX"] then
        kgBtn:ClearAllPoints()
        kgBtn:SetPoint(
            ChannelFriendsDB["__kgBtnPoint"] or "BOTTOMRIGHT",
            UIParent,
            ChannelFriendsDB["__kgBtnRelPoint"] or "BOTTOMRIGHT",
            ChannelFriendsDB["__kgBtnX"],
            ChannelFriendsDB["__kgBtnY"]
        )
    end
end)

-- -------------------------------------------------------
-- 13. SLASH COMMANDS
--     /cf          – toggle the window
--     /cf add Name – save a player by name
--     /cf rem Name – remove a player by name
--     /cf list     – print saved list to chat
-- -------------------------------------------------------

SLASH_CHANNELFRIENDS1 = "/cf"
SLASH_CHANNELFRIENDS2 = "/channelfriends"

SlashCmdList["CHANNELFRIENDS"] = function(msg)
    msg = msg or ""
    local _, _, cmd, arg = string.find(msg, "^(%S*)%s*(.*)$")
    cmd = string.lower(cmd or "")

    if cmd == "" then
        -- Toggle the window.
        if f:IsShown() then
            f:Hide()
        else
            f:Show()   -- OnShow fires automatically and triggers refresh
        end

    elseif cmd == "add" and arg ~= "" then
        if not ChannelFriendsDB then ChannelFriendsDB = {} end
        ChannelFriendsDB[arg] = true
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00ChannelFriends:|r Added " .. arg)
        ChannelFriends_RefreshList()

    elseif cmd == "rem" and arg ~= "" then
        if ChannelFriendsDB then ChannelFriendsDB[arg] = nil end
        DEFAULT_CHAT_FRAME:AddMessage("|cffff4444ChannelFriends:|r Removed " .. arg)
        ChannelFriends_RefreshList()

    elseif cmd == "debug" then
        -- Dump everything the channel APIs return so we can diagnose issues.
        DEFAULT_CHAT_FRAME:AddMessage("|cffffff00CF Debug – GetChannelList():|r")
        local list = { GetChannelList() }
        if table.getn(list) == 0 then
            DEFAULT_CHAT_FRAME:AddMessage("  (empty)")
        else
            for i = 1, table.getn(list) do
                DEFAULT_CHAT_FRAME:AddMessage("  [" .. i .. "] = " .. tostring(list[i]))
            end
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cffffff00CF Debug – GetChannelName(1..10):|r")
        for i = 1, 10 do
            local idx, name = GetChannelName(i)
            if idx and idx ~= 0 then
                DEFAULT_CHAT_FRAME:AddMessage("  slot " .. i .. " -> idx=" .. tostring(idx) .. " name=" .. tostring(name))
            end
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cffffff00ChannelFriends – Saved Players:|r")
        if not ChannelFriendsDB then
            DEFAULT_CHAT_FRAME:AddMessage("  (none)")
            return
        end
        for name, _ in pairs(ChannelFriendsDB) do
            DEFAULT_CHAT_FRAME:AddMessage("  " .. name)
        end
    else
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cffffff00ChannelFriends commands:|r\n"
            .. "  /cf          – open/close window\n"
            .. "  /cf add Name – save a player\n"
            .. "  /cf rem Name – remove a player\n"
            .. "  /cf list     – print saved list"
        )
    end
end


-- -------------------------------------------------------
-- 13. INITIALISE ON LOGIN
-- -------------------------------------------------------

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
initFrame:RegisterEvent("CHAT_MSG_CHANNEL_JOIN")
initFrame:SetScript("OnEvent", function()
    if not ChannelFriendsDB then ChannelFriendsDB = {} end

    if event == "CHAT_MSG_CHANNEL_JOIN" then
        -- Fires for everyone joining; arg9 = channel name
        local joiningChannel = tostring(arg9 or "")
        if string.find(string.lower(joiningChannel), string.lower(CF_CHANNEL), 1, true) then
            CF_ScheduleColorSet()
        end
        return
    end

    -- PLAYER_LOGIN and PLAYER_ENTERING_WORLD
    CF_ScheduleColorSet()
    CF_AddChannelToChat()   -- ensure channel shows in chat frame

    if event == "PLAYER_LOGIN" then
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff00ccffChannelFriends|r loaded! Type |cffffff00/cf|r to open."
        )
    end
end)
