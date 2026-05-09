--[[
  TRPLite — Lightweight RP profile addon, wire-compatible with TurtleRP.

  Why this addon exists:
    The original TurtleRP (1.12 → 1.14 port) hit a wall on this server: the
    1.14 Classic Era client silently drops chat sends that don't originate
    from a recent hardware event. Auto-firing pings from an OnUpdate timer
    leave the client and never echo back. Manual `/run TurtleRP.send(...)`
    works because typing in chat is a hardware event.

    TRPLite accepts that constraint. Every outgoing send originates from a
    user action: a slash command, a button click, or a frame OnShow that
    was itself opened by a slash command. There is no background pinger.
    To advertise yourself, you click Refresh or run `/trp ping`.

  Wire compatibility:
    All outgoing/incoming messages use the TurtleRP protocol unchanged so
    1.12 clients running TurtleRP keep working with TRPLite users:
      Channel: "TTRP"
      Ping:    "P<zone>~<x>~<y>~1.1.0"   (or "~false~false~" if no loc)
      Announce: "A<zone>~..."
      Request:  "M:<targetName>~<key|NO_KEY>"   (M, T, or D)
      Response: "MR:p~<senderKey>~<chunkIdx>~<total>~<chunkData>"
                (MR, TR, DR — chunked because messages can exceed ~250 chars)
      Encoding: every "s" -> "°" and "S" -> "§" outbound, reversed inbound.
                This dodges the server-side drunken-speech filter that
                otherwise mangles "s" sounds on drunk characters.
]]

-- =============================================================================
-- Namespace and constants
-- =============================================================================

TRPLite = TRPLite or {}
TRPLite.channelName     = "TTRP"
TRPLite.addonVersion    = "0.2.0"   -- v0.1.0 backed up in _backups/v0.1.0/
TRPLite.protocolVersion = "1.1.0"   -- match TurtleRP wire protocol
TRPLite.chunkSize       = 200       -- chars of payload per chunked response

-- Live (non-persisted) state.
TRPLite.queryablePlayers = {}       -- name -> last-seen unix time
TRPLite.tempBuffers      = {}       -- name -> { M = "...", T = "...", D = "..." }
TRPLite.channelIndex     = 0

-- Field schemas — order is significant: this is the on-the-wire order
-- matching TurtleRP's dataKeys() function. Field 1 in each is the key,
-- which is sent separately and not concatenated into the chunked payload.
TRPLite.fieldSchemas = {
  M = { "keyM", "icon", "full_name", "race", "class", "class_color",
        "ooc_info", "ic_info", "currently_ic", "ooc_pronouns", "ic_pronouns" },
  T = { "keyT", "atAGlance1", "atAGlance1Title", "atAGlance1Icon",
        "atAGlance2", "atAGlance2Title", "atAGlance2Icon",
        "atAGlance3", "atAGlance3Title", "atAGlance3Icon",
        "experience", "walkups", "injury", "romance", "death" },
  D = { "keyD", "description" },
}

-- =============================================================================
-- Utilities
-- =============================================================================

function TRPLite.log(msg)
  if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cff8C48AB[TRPLite]|r " .. tostring(msg))
  end
end

-- Standalone split: returns a table with all fields including empty fields
-- between consecutive separators. Lua 5.1's string library doesn't ship
-- this, and Blizzard's strsplit returns multiple values, not a table.
function TRPLite.split(str, sep)
  local t = {}
  if str == nil or str == "" then return t end
  if sep == nil or sep == "" then t[1] = str return t end
  local i = 1
  local s, e = string.find(str, sep, i, true)
  while s do
    table.insert(t, string.sub(str, i, s - 1))
    i = e + 1
    s, e = string.find(str, sep, i, true)
  end
  table.insert(t, string.sub(str, i))
  return t
end

-- Normalize a sender name from CHAT_MSG_CHANNEL into the plain character
-- name without any realm suffix. Modern Classic Era can hand us
-- "Name-Realm" or even "Name-" (empty realm field) on what should be a
-- single-realm server, which collides with the plain "Name" we get on
-- other paths and produces duplicate directory entries. Always cut at
-- the first hyphen.
function TRPLite.normalizeSenderName(name)
  if type(name) ~= "string" or name == "" then return name end
  local i = string.find(name, "-", 1, true)
  if i then
    return string.sub(name, 1, i - 1)
  end
  return name
end

function TRPLite.randomKey(len)
  len = len or 5
  local chars = "abcdefghijklmnopqrstuvwxyz"
  local out = ""
  for _ = 1, len do
    local idx = math.random(1, #chars)
    out = out .. string.sub(chars, idx, idx)
  end
  return out
end

-- Player map position helper that works on the 1.14 client.
function TRPLite.playerMapPos()
  if C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition then
    local mapID = C_Map.GetBestMapForUnit("player")
    if mapID then
      local pos = C_Map.GetPlayerMapPosition(mapID, "player")
      if pos and pos.GetXY then return pos:GetXY() end
    end
  end
  return nil, nil
end

-- =============================================================================
-- Drunk encode / decode (matches TurtleRP exactly)
-- =============================================================================

function TRPLite.encode(text)
  text = string.gsub(text, "s", "°")
  text = string.gsub(text, "S", "§")
  return text
end

function TRPLite.decode(text)
  text = string.gsub(text, "°", "s")
  text = string.gsub(text, "§", "S")
  -- Strip the localized "...hic!" suffix the server appends to drunk speech.
  -- SLURRED_SPEECH is a Blizzard global like "...hic!%s" — we want
  -- everything after %s to be optional; this is a best-effort cleanup that
  -- mirrors TurtleRP's behavior. If SLURRED_SPEECH isn't defined for some
  -- reason, just skip this step.
  if type(SLURRED_SPEECH) == "string" and SLURRED_SPEECH ~= "" then
    local suffix = string.gsub(SLURRED_SPEECH, "%%s(.+)", "%1$")
    if suffix and suffix ~= "" then
      text = string.gsub(text, suffix, "")
    end
  end
  return text
end

-- =============================================================================
-- Profile defaults
-- =============================================================================

-- Field names that are part of the wire format but TRPLite never surfaces
-- in its UI. They go on the wire as empty strings so the field count and
-- separator positions stay aligned with TurtleRP's expectation.
--
-- The At-a-Glance fields are forced empty because Vanessa's TurtleRP has
-- a render-side bug (nil-value error) when AAG data is present. Sending
-- them empty keeps the wire format intact while sidestepping that bug.
TRPLite.alwaysEmptyFields = {
  ic_pronouns      = true,
  ooc_pronouns     = true,
  -- icon: a numeric texture index. The 1.12 client errors when this is
  -- set to anything TRPLite sends, so we just never send it.
  icon             = true,
  atAGlance1       = true,
  atAGlance1Title  = true,
  atAGlance1Icon   = true,
  atAGlance2       = true,
  atAGlance2Title  = true,
  atAGlance2Icon   = true,
  atAGlance3       = true,
  atAGlance3Title  = true,
  atAGlance3Icon   = true,
}

-- Compute a sensible default class_color hex string from the player's
-- class. TurtleRP renders the class line as "<race> |cff<class_color><class>|r",
-- so an empty or malformed class_color causes the |cff<...> escape to break
-- and the recipient sees something like "Human|cff Mage" instead of
-- "Human Mage" with the class name colored. We default to the actual class
-- color from RAID_CLASS_COLORS, falling back to white if the table or
-- class file isn't available for some reason.
function TRPLite.computeDefaultClassColor()
  local _, classFile = UnitClass("player")
  if classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile] then
    local c = RAID_CLASS_COLORS[classFile]
    return string.format("%02x%02x%02x",
                         math.floor((c.r or 1) * 255),
                         math.floor((c.g or 1) * 255),
                         math.floor((c.b or 1) * 255))
  end
  return "ffffff"
end

-- defaultProfile only initializes fields TRPLite actually uses. Wire-format
-- positions for icon, pronouns, and at-a-glance entries are still preserved
-- by sendDataResponse (those slots go on the wire as empty strings via
-- TRPLite.alwaysEmptyFields), but we don't bother storing the values since
-- nothing in TRPLite reads them. TRPLiteCharacters (cache of others) still
-- captures the full wire schema so the info viewer can show received AAG.
function TRPLite.defaultProfile()
  local p = {}
  p.keyM = TRPLite.randomKey()
  p.keyT = TRPLite.randomKey()
  p.keyD = TRPLite.randomKey()
  p.full_name    = UnitName("player") or ""
  p.race         = UnitRace("player") or ""
  p.class        = UnitClass("player") or ""
  p.class_color  = TRPLite.computeDefaultClassColor()
  p.ic_info      = ""
  p.ooc_info     = ""
  p.currently_ic = "1"
  p.experience, p.walkups, p.injury, p.romance, p.death = "0", "0", "0", "0", "0"
  p.description  = ""

  -- Per-field broadcast opt-out. Default: share everything. The profile
  -- editor toggles entries here when the user unchecks a "share" box.
  -- Mirrors the editable field set above — fields whose wire slots are
  -- always empty don't need a share entry.
  p.share = {
    full_name = true, race = true, class = true, class_color = true,
    ic_info = true, ooc_info = true, currently_ic = true,
    experience = true, walkups = true, injury = true,
    romance = true, death = true,
    description = true,
  }
  return p
end

function TRPLite.defaultSettings()
  return {
    share_location   = "1",
    -- Minimap button. Hidden defaults to false so the icon is visible
    -- on first install. Locked defaults to true so the button doesn't
    -- accidentally drift on click; right-click toggles. Position is the
    -- angle in degrees around the minimap's center (0 = 3 o'clock,
    -- 90 = 12 o'clock, etc.); 200 puts it lower-left where most other
    -- addons aren't crowded.
    minimap_hide     = false,
    minimap_locked   = true,
    minimap_position = 200,
  }
end

-- Bumps the per-type key. Call this whenever the user edits profile fields
-- in that bucket so other clients know their cached copy is stale.
function TRPLite.bumpKey(typ)
  if not TRPLiteMyProfile then return end
  TRPLiteMyProfile["key" .. typ] = TRPLite.randomKey()
end

-- =============================================================================
-- Channel: join / send
-- =============================================================================

-- Best-effort join. We try a clean leave-then-rejoin to recover from the
-- "marked-left / greyed-out" state that saved-channels auto-rejoin can
-- leave the client in on /reload. ChatFrame_AddChannel goes through the
-- same path the chat UI's "Join" button uses, which can recover from
-- states that bare JoinChannelByName silently no-ops on.
function TRPLite.joinChannel()
  local id = GetChannelName(TRPLite.channelName)
  if id and id > 0 then
    TRPLite.channelIndex = id
    return true
  end

  if LeaveChannelByName then
    pcall(LeaveChannelByName, TRPLite.channelName)
  end
  if ChatFrame_RemoveChannel then
    pcall(ChatFrame_RemoveChannel, DEFAULT_CHAT_FRAME, TRPLite.channelName)
  end

  -- Defer the rejoin one frame so the leave fully settles. The deferred
  -- frame is created here at addon-load time; its OnUpdate runs from the
  -- frame loop, which is a clean (non-event-chain) context.
  local rejoiner = CreateFrame("Frame")
  rejoiner:SetScript("OnUpdate", function(self)
    self:SetScript("OnUpdate", nil)
    if ChatFrame_AddChannel then
      ChatFrame_AddChannel(DEFAULT_CHAT_FRAME, TRPLite.channelName)
    elseif JoinPermanentChannel then
      JoinPermanentChannel(TRPLite.channelName)
    else
      JoinChannelByName(TRPLite.channelName)
    end
    -- Verify on the next frame and update channelIndex.
    local verifier = CreateFrame("Frame")
    verifier:SetScript("OnUpdate", function(v)
      v:SetScript("OnUpdate", nil)
      local newId = GetChannelName(TRPLite.channelName)
      TRPLite.channelIndex = newId or 0
      if not newId or newId == 0 then
        TRPLite.log("Couldn't auto-join '" .. TRPLite.channelName ..
                    "'. Try |cff8C48AB/join " .. TRPLite.channelName ..
                    "|r manually.")
      end
    end)
  end)
  return false
end

-- Send a single message to the TTRP channel. The caller is responsible
-- for ensuring this is invoked from a hardware-event context (slash
-- command, button click, etc.). Sends from OnUpdate or OnEvent are
-- silently dropped on this server.
function TRPLite.send(message)
  local id = GetChannelName(TRPLite.channelName)
  if not id or id == 0 then
    -- Channel not joined — try to join, but the send itself can't be
    -- retried automatically without re-entering a tainted context.
    TRPLite.joinChannel()
    return false
  end
  TRPLite.channelIndex = id
  SendChatMessage(TRPLite.encode(message), "CHANNEL", nil, id)
  return true
end

-- =============================================================================
-- Outgoing: pings, requests, responses
-- =============================================================================

-- Send a ping (P or A) advertising my zone (and optionally coordinates).
function TRPLite.broadcastPing(prefix)
  prefix = prefix or "P"
  local zone = GetZoneText() or ""
  local msg = prefix .. zone
  local share = TRPLiteSettings and TRPLiteSettings.share_location == "1"
  if share then
    local x, y = TRPLite.playerMapPos()
    if x and y then
      msg = msg .. "~" .. math.floor(x * 10000) / 10000 ..
                  "~" .. math.floor(y * 10000) / 10000 ..
                  "~" .. TRPLite.protocolVersion
    else
      msg = msg .. "~false~false~" .. TRPLite.protocolVersion
    end
  else
    msg = msg .. "~false~false~" .. TRPLite.protocolVersion
  end
  TRPLite.send(msg)
end

-- Send a directed data request. typ is "M", "T", or "D".
function TRPLite.requestData(typ, targetName)
  if not targetName or targetName == "" then return end
  local cached = TRPLiteCharacters and TRPLiteCharacters[targetName]
  local key = (cached and cached["key" .. typ]) or "NO_KEY"
  TRPLite.send(typ .. ":" .. targetName .. "~" .. key)
end

-- Send my own data of one type, chunked. typ is "M", "T", or "D".
-- Wire format: "MR:p~<myKey>~<chunkIdx>~<total>~<chunkData>"
-- The literal "p" placeholder is taken straight from TurtleRP — receivers
-- check whether the second segment is their own name, and "p" never is,
-- so all listeners take the "store data" branch.
function TRPLite.sendDataResponse(typ)
  if not TRPLiteMyProfile then return end
  local fields = TRPLite.fieldSchemas[typ]
  if not fields then return end

  -- Build the payload. Skip field 1 (the key) — it's transmitted in its
  -- own column. Description gets newlines escaped to "@N" so the message
  -- stays single-line, matching TurtleRP.
  --
  -- Per-field opt-out: if the user unchecked a field's "share" box, OR
  -- the field is in alwaysEmptyFields (e.g. pronouns, which TRPLite has
  -- no UI for), we send "" in that wire slot. The field count and
  -- separator positions stay identical so TurtleRP receivers parse the
  -- payload correctly — they just see an empty value for that field.
  local share = (TRPLiteMyProfile and TRPLiteMyProfile.share) or {}
  local payload = ""
  for i = 2, #fields do
    local name = fields[i]
    local val
    if TRPLite.alwaysEmptyFields[name] or share[name] == false then
      val = ""
    else
      val = TRPLiteMyProfile[name] or ""
    end
    -- class_color: an empty value would produce a malformed "|cff" color
    -- escape on receivers (TurtleRP renders class as "|cff<color><class>|r"
    -- and concatenates raw). Substitute white so the escape stays valid.
    if name == "class_color" and (val == "" or val == nil) then
      val = "ffffff"
    end
    if name == "description" then
      val = string.gsub(val, "\n", "@N")
      if val == "" then val = " " end   -- avoid empty payload edge case
    end
    if i > 2 then payload = payload .. "~" end
    payload = payload .. tostring(val)
  end

  -- Chunk the payload.
  local chunks = {}
  local chunkSize = TRPLite.chunkSize
  local len = string.len(payload)
  if len == 0 then chunks[1] = "" else
    local idx = 1
    while idx <= len do
      table.insert(chunks, string.sub(payload, idx, idx + chunkSize - 1))
      idx = idx + chunkSize
    end
  end

  local total = #chunks
  local key = TRPLiteMyProfile["key" .. typ] or ""
  for i, chunk in ipairs(chunks) do
    TRPLite.send(typ .. "R:p~" .. key .. "~" .. i .. "~" .. total .. "~" .. chunk)
  end
end

-- Convenience: broadcast everything other clients might want from us.
-- Called from hardware events (Refresh button, /trp ping).
function TRPLite.broadcastSelf()
  TRPLite.broadcastPing("P")
  TRPLite.sendDataResponse("M")
  TRPLite.sendDataResponse("T")
  TRPLite.sendDataResponse("D")
end

-- Opportunistic broadcast piggybacked on user chat activity.
--
-- The 1.14 client silent-drops channel sends without a recent hardware
-- event, so we can't run a background timer. Pressing Enter to submit a
-- chat message IS a hardware event, so by hooking ChatEdit_SendText we
-- get a "free" hardware-event-blessed call site every time the user
-- sends any chat (any /say, /yell, /4, /tell, /trp, etc.).
--
-- The cooldown keeps us from flooding the channel even if the user is
-- chatting non-stop. Default is 180s; bump TRPLite.broadcastCooldown
-- in the saved settings to change it.
TRPLite.broadcastCooldown = 180   -- seconds between opportunistic broadcasts
TRPLite.lastBroadcast     = 0

function TRPLite.maybeOpportunisticBroadcast()
  local now = time()
  local cooldown = (TRPLiteSettings and TRPLiteSettings.broadcast_cooldown)
                   or TRPLite.broadcastCooldown
  -- broadcastNeeded gets set when an incoming request asked for data
  -- under a key we couldn't reply to from OnEvent context. Honor it
  -- once by bypassing the cooldown — that way someone asking gets a
  -- fresh broadcast at the next user-driven chat send instead of
  -- waiting for the next cooldown window.
  if not TRPLite.broadcastNeeded
     and now - (TRPLite.lastBroadcast or 0) < cooldown then
    return
  end
  -- Only attempt if we're actually joined to the channel.
  local id = GetChannelName(TRPLite.channelName)
  if not id or id == 0 then return end
  TRPLite.lastBroadcast   = now
  TRPLite.broadcastNeeded = false
  TRPLite.broadcastSelf()
end

-- =============================================================================
-- Incoming: dispatch
-- =============================================================================

-- Top-level dispatch for a decoded TTRP channel message.
function TRPLite.onChannelMessage(text, sender)
  if not text or text == "" or not sender then return end

  -- Pings have no colon; data messages always do (e.g. "MR:p~...").
  if not string.find(text, ":", 1, true) then
    local first = string.sub(text, 1, 1)
    if first == "P" or first == "A" then
      TRPLite.recvPing(sender, text)
    end
    return
  end

  -- Data path. Expected: "<TYPE>:<subjectName>~<rest>"
  local colonStart, colonEnd = string.find(text, ":", 1, true)
  local prefix = string.sub(text, 1, colonEnd - 1)
  local tildeStart = string.find(text, "~", colonEnd + 1, true)
  if not tildeStart then return end
  local subjectName = string.sub(text, colonEnd + 1, tildeStart - 1)
  local rest        = string.sub(text, tildeStart + 1)

  local me = UnitName("player")
  if subjectName == me and (prefix == "M" or prefix == "T" or prefix == "D") then
    -- A request directed at me. We *cannot* reply directly from here:
    -- CHAT_MSG_CHANNEL is an OnEvent context, which is not a hardware
    -- event. Sending from here trips NobleSpeak's wrapper into
    -- ADDON_ACTION_BLOCKED on this server. Instead, just note that
    -- somebody is asking for data we haven't pushed lately, and let the
    -- next opportunistic broadcast (or any user-driven broadcast) cover
    -- it. We use a "needed" flag that maybeOpportunisticBroadcast reads
    -- to bypass its cooldown once.
    local parts = TRPLite.split(rest, "~")
    local theirKey = parts[1] or "NO_KEY"
    local myKey = (TRPLiteMyProfile and TRPLiteMyProfile["key" .. prefix]) or ""
    if theirKey ~= myKey then
      TRPLite.broadcastNeeded = true
    end
    return
  end

  -- Otherwise this is somebody else's data flowing through the channel.
  -- Responses look like "MR:p~<senderKey>~<idx>~<total>~<chunkData>".
  if prefix == "MR" or prefix == "TR" or prefix == "DR" then
    TRPLite.recvData(prefix, sender, rest)
  end
end

-- Handle an incoming ping. Marks the player as online and stores their zone.
function TRPLite.recvPing(sender, msg)
  if not TRPLiteCharacters then TRPLiteCharacters = {} end

  local zoneText = string.sub(msg, 2)   -- strip leading "P" or "A"
  TRPLite.queryablePlayers[sender] = time()

  if not TRPLiteCharacters[sender] then
    TRPLiteCharacters[sender] = {}
  end
  local char = TRPLiteCharacters[sender]
  char.zone = zoneText

  -- Ping format may include "~x~y~version" trailing fields.
  if string.find(zoneText, "~", 1, true) then
    local parts = TRPLite.split(zoneText, "~")
    char.zone = parts[1]
    if parts[2] and parts[3] and parts[2] ~= "false" and parts[3] ~= "false" then
      char.zoneX = parts[2]
      char.zoneY = parts[3]
    end
  end

  if TRPLite.UI and TRPLite.UI.refreshDirectory then
    TRPLite.UI.refreshDirectory()
  end
  if TRPLite.UI and TRPLite.UI.refreshInfoView then
    TRPLite.UI.refreshInfoView()
  end
end

-- Handle an incoming chunked data response. typ is "MR", "TR", or "DR";
-- rest is everything after the ":" up to and including the chunk payload
-- (i.e. "<senderKey>~<idx>~<total>~<chunkData>"). Special case: rest may
-- have started with the literal "p~" subject placeholder — the dispatch
-- layer already stripped past the first "~", so this function sees just
-- the trailing tilde-separated fields.
function TRPLite.recvData(typ, sender, rest)
  -- typ is "MR" / "TR" / "DR"; we want the base ("M" / "T" / "D") for
  -- field schema lookup and temp buffer naming.
  local base = string.sub(typ, 1, 1)
  local schema = TRPLite.fieldSchemas[base]
  if not schema then return end

  local parts = TRPLite.split(rest, "~")
  -- parts: senderKey, chunkIdx, totalChunks, chunkData1, chunkData2, ...
  local senderKey  = parts[1]
  local chunkIdx   = tonumber(parts[2])
  local totalChnks = tonumber(parts[3])
  if not chunkIdx or not totalChnks then return end

  if not TRPLiteCharacters then TRPLiteCharacters = {} end
  if not TRPLiteCharacters[sender] then TRPLiteCharacters[sender] = {} end
  local char = TRPLiteCharacters[sender]

  if not TRPLite.tempBuffers[sender] then TRPLite.tempBuffers[sender] = {} end
  local buf = TRPLite.tempBuffers[sender]

  if chunkIdx == 1 then
    -- First chunk: seed the buffer with the senderKey followed by the
    -- chunk payload, exactly as TurtleRP does so the reassembled string
    -- starts with the key and field-splits cleanly.
    buf[base] = senderKey .. "~"
  end
  buf[base] = buf[base] or ""

  -- Append the chunk-payload fields back together with "~" separators.
  for i = 4, #parts do
    buf[base] = buf[base] .. parts[i]
    if i < #parts then buf[base] = buf[base] .. "~" end
  end

  -- All chunks received? Parse and store.
  if chunkIdx == totalChnks then
    local assembled = TRPLite.split(buf[base] or "", "~")
    for i, fieldName in ipairs(schema) do
      char[fieldName] = assembled[i] or ""
    end
    if char.description then
      char.description = string.gsub(char.description, "@N", "\n")
    end
    buf[base] = nil
    if TRPLite.UI and TRPLite.UI.refreshDirectory then
      TRPLite.UI.refreshDirectory()
    end
    if TRPLite.UI and TRPLite.UI.refreshInfoView then
      TRPLite.UI.refreshInfoView()
    end
  end
end

-- =============================================================================
-- Events: ADDON_LOADED, PLAYER_ENTERING_WORLD, CHAT_MSG_CHANNEL
-- =============================================================================

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("CHAT_MSG_CHANNEL")
eventFrame:SetScript("OnEvent", function(self, event, ...)
  if event == "ADDON_LOADED" then
    local arg1 = ...
    if arg1 ~= "TRPLite" then return end

    -- SavedVariables fan-in.
    if not TRPLiteCharacters then TRPLiteCharacters = {} end
    if not TRPLiteSettings   then TRPLiteSettings   = TRPLite.defaultSettings() end
    if not TRPLiteMyProfile  then TRPLiteMyProfile  = TRPLite.defaultProfile() end

    -- Backfill any missing fields on existing profiles after upgrades.
    local defaults = TRPLite.defaultProfile()
    for k, v in pairs(defaults) do
      if TRPLiteMyProfile[k] == nil then TRPLiteMyProfile[k] = v end
    end
    local defSettings = TRPLite.defaultSettings()
    for k, v in pairs(defSettings) do
      if TRPLiteSettings[k] == nil then TRPLiteSettings[k] = v end
    end

    -- Migration: collapse any cache keys that have a "-Realm" or trailing
    -- "-" suffix into the plain name, so the directory stops showing
    -- duplicates left over from before normalization existed. Prefer a
    -- pre-existing plain entry if one is already there; otherwise rename.
    if TRPLiteCharacters then
      for name, char in pairs(TRPLiteCharacters) do
        local clean = TRPLite.normalizeSenderName(name)
        if clean ~= name and clean ~= "" then
          if TRPLiteCharacters[clean] == nil then
            TRPLiteCharacters[clean] = char
          end
          TRPLiteCharacters[name] = nil
        end
      end
    end

    -- Migration: strip fields from MyProfile that TRPLite never reads.
    -- Anything in alwaysEmptyFields goes on the wire as "" regardless of
    -- the local value, so storing it locally just bloats the SVs file.
    -- Only touches the user's own profile; received-cache schema is
    -- preserved so the info viewer can still render others' AAG.
    for fieldName in pairs(TRPLite.alwaysEmptyFields) do
      TRPLiteMyProfile[fieldName] = nil
      if TRPLiteMyProfile.share then
        TRPLiteMyProfile.share[fieldName] = nil
      end
    end

    -- Build the minimap button (if not hidden in saved settings) and
    -- apply its saved position. The UI module isn't loaded until after
    -- TRPLite.lua, so we guard against missing functions.
    if TRPLite.UI and TRPLite.UI.setupMinimapIcon then
      TRPLite.UI.setupMinimapIcon()
    end

    TRPLite.log("v" .. TRPLite.addonVersion .. " loaded. Type |cff8C48AB/trp|r for commands.")

  elseif event == "PLAYER_ENTERING_WORLD" then
    -- Just attempt the join; we don't need to ping here (and can't safely,
    -- since this event runs in a tainted context — see addon header).
    TRPLite.joinChannel()

  elseif event == "CHAT_MSG_CHANNEL" then
    -- Args: text, playerName, languageName, channelName, target,
    --       flags, zoneChannelID, channelIndex, channelBaseName, ...
    local text, sender = select(1, ...), select(2, ...)
    local channelBaseName = select(9, ...)
    if not channelBaseName then return end
    if string.lower(channelBaseName) ~= string.lower(TRPLite.channelName) then
      return
    end
    -- Normalize so "Vanessa", "Vanessa-", "Vanessa-Realm" all become
    -- the same cache key. Avoids duplicate directory entries.
    sender = TRPLite.normalizeSenderName(sender)
    TRPLite.onChannelMessage(TRPLite.decode(text), sender)
  end
end)

-- =============================================================================
-- Suppress raw protocol traffic from the user's chat tabs
-- =============================================================================

local function suppressTTRP(_, _, ...)
  local channelBaseName = select(9, ...)
  if channelBaseName and string.lower(channelBaseName) == string.lower(TRPLite.channelName) then
    return true
  end
  return false
end
ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL",             suppressTTRP)
ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL_NOTICE_USER", suppressTTRP)
ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL_JOIN",        suppressTTRP)
ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL_LEAVE",       suppressTTRP)

-- =============================================================================
-- Opportunistic broadcast hook
-- =============================================================================

-- Piggyback on the user's own chat activity. ChatEdit_SendText is the
-- FrameXML function that runs when the user presses Enter in any chat
-- editbox. The keypress is a hardware event, so any sends we make from
-- this hook are not silent-dropped by the 1.14 client. We call
-- maybeOpportunisticBroadcast which short-circuits if the cooldown
-- hasn't elapsed, keeping channel traffic well below any anti-spam
-- threshold even when the user is chatting heavily.
--
-- NobleSpeak compatibility: NobleSpeak's SendChatMessage wrapper only
-- translates SAY and YELL chat types; CHANNEL (what we use) is passed
-- through unchanged, so the broadcast text is unaffected by the noble
-- translator.
if hooksecurefunc and ChatEdit_SendText then
  hooksecurefunc("ChatEdit_SendText", function()
    TRPLite.maybeOpportunisticBroadcast()
  end)
end

-- =============================================================================
-- Slash commands
-- =============================================================================

SLASH_TRPLITE1 = "/trp"
SlashCmdList["TRPLITE"] = function(input)
  local cmd, rest = string.match(input or "", "^(%S*)%s*(.-)$")
  cmd = string.lower(cmd or "")

  if cmd == "" or cmd == "help" then
    TRPLite.log("|cff8C48AB/trp|r — show this help")
    TRPLite.log("|cff8C48AB/trp dir|r — open the directory of seen players")
    TRPLite.log("|cff8C48AB/trp profile|r — open the profile editor")
    TRPLite.log("|cff8C48AB/trp ping|r — broadcast your profile to others")
    TRPLite.log("|cff8C48AB/trp rejoin|r — re-join the TTRP chat channel")
    TRPLite.log("|cff8C48AB/trp minimap|r — show or hide the minimap button")

  elseif cmd == "dir" or cmd == "directory" then
    if TRPLite.UI and TRPLite.UI.openDirectory then
      TRPLite.UI.openDirectory()
      -- Slash commands run in a hardware-event context, so this send
      -- will go through. Announces our presence whenever the user opens
      -- the directory.
      TRPLite.broadcastPing("P")
    else
      TRPLite.log("UI not loaded yet. Try /reload.")
    end

  elseif cmd == "profile" or cmd == "edit" then
    if TRPLite.UI and TRPLite.UI.openProfileEditor then
      TRPLite.UI.openProfileEditor()
    else
      TRPLite.log("UI not loaded yet. Try /reload.")
    end

  elseif cmd == "ping" or cmd == "refresh" then
    -- Broadcast everything (P + MR + TR + DR). All sends originate from
    -- this slash command callback, which is a hardware-event context.
    TRPLite.broadcastSelf()
    TRPLite.log("Broadcast sent.")

  elseif cmd == "rejoin" then
    TRPLite.joinChannel()
    TRPLite.log("Re-joining " .. TRPLite.channelName .. "...")

  elseif cmd == "minimap" then
    if TRPLite.UI and TRPLite.UI.toggleMinimapIcon then
      TRPLite.UI.toggleMinimapIcon()
    else
      TRPLite.log("UI not loaded yet. Try /reload.")
    end

  else
    TRPLite.log("Unknown command. Try |cff8C48AB/trp help|r.")
  end
end
