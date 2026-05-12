--[[
  TRPLite_UI — Lua-only UI: directory, profile editor, tooltip integration.

  No XML. Every frame is built imperatively here so there's no parser
  surface to debug across client versions. The directory and profile
  editor are simple movable frames; the tooltip integration is a
  HookScript on GameTooltip.

  Sending: every UI control that triggers a network send (Refresh,
  profile Save, clicking a name in the directory) does so directly from
  the click handler. Click handlers run in a hardware-event context, so
  the sends are not silent-dropped on the 1.14 client.
]]

TRPLite      = TRPLite or {}
TRPLite.UI   = TRPLite.UI or {}

-- =============================================================================
-- Helpers
-- =============================================================================

local function makeBackdrop(frame)
  if frame.SetBackdrop then
    frame:SetBackdrop({
      bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true, tileSize = 32, edgeSize = 32,
      insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
  end
end

local function makeTitle(frame, text)
  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOP", frame, "TOP", 0, -16)
  title:SetText(text)
  return title
end

local function makeCloseButton(frame)
  local btn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  btn:SetPoint("TOPRIGHT", -4, -4)
  return btn
end

-- A standard Blizz button with a click handler.
local function makeButton(parent, label, w, h, onClick)
  local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  btn:SetSize(w or 100, h or 22)
  btn:SetText(label)
  btn:SetScript("OnClick", onClick)
  return btn
end

-- A labeled single-line edit box.
local function makeLabeledEditBox(parent, labelText, width)
  local container = CreateFrame("Frame", nil, parent)
  container:SetSize(width or 220, 38)

  local label = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  label:SetPoint("TOPLEFT", 0, 0)
  label:SetText(labelText)

  local edit = CreateFrame("EditBox", nil, container, "InputBoxTemplate")
  edit:SetSize((width or 220) - 10, 20)
  edit:SetAutoFocus(false)
  edit:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 6, -2)
  edit:SetMaxLetters(0)

  container.edit = edit
  return container
end

-- A multi-line edit box for description fields.
local function makeMultilineEditBox(parent, labelText, width, height)
  local container = CreateFrame("Frame", nil, parent)
  container:SetSize(width or 320, (height or 80) + 20)

  local label = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  label:SetPoint("TOPLEFT", 0, 0)
  label:SetText(labelText)

  local scroll = CreateFrame("ScrollFrame", nil, container, "UIPanelScrollFrameTemplate")
  scroll:SetSize(width or 320, height or 80)
  scroll:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -2)

  local edit = CreateFrame("EditBox", nil, scroll)
  edit:SetMultiLine(true)
  edit:SetSize(width or 320, height or 80)
  edit:SetFontObject("ChatFontNormal")
  edit:SetAutoFocus(false)
  edit:SetMaxLetters(0)
  scroll:SetScrollChild(edit)

  container.edit = edit
  return container
end

-- =============================================================================
-- Directory frame
-- =============================================================================

local Directory = nil

local function buildDirectory()
  if Directory then return Directory end

  local f = CreateFrame("Frame", "TRPLite_Directory", UIParent, "BackdropTemplate")
  f:SetSize(420, 460)
  f:SetPoint("CENTER")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop",  f.StopMovingOrSizing)
  f:SetClampedToScreen(true)
  f:Hide()
  makeBackdrop(f)
  makeTitle(f, "TRPLite — Directory")
  makeCloseButton(f)

  -- Filter / search bar. Case-insensitive substring match against the
  -- character name. Empty filter shows everything (default).
  local searchLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  searchLabel:SetPoint("TOPLEFT", 24, -42)
  searchLabel:SetText("Filter:")

  local search = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
  search:SetSize(280, 18)
  search:SetAutoFocus(false)
  search:SetPoint("LEFT", searchLabel, "RIGHT", 8, 0)
  search:SetMaxLetters(32)
  search:SetScript("OnTextChanged", function(self)
    f.filterText = (self:GetText() or ""):lower()
    TRPLite.UI.refreshDirectory()
  end)
  search:SetScript("OnEscapePressed", function(self)
    self:SetText("")
    self:ClearFocus()
  end)
  f.search     = search
  f.filterText = ""

  -- Column headers (shifted down to make room for the filter bar)
  local nameH = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  nameH:SetPoint("TOPLEFT", 24, -70)
  nameH:SetText("Name")

  local zoneH = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  zoneH:SetPoint("TOPLEFT", 150, -70)
  zoneH:SetText("Zone")

  local statusH = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  statusH:SetPoint("TOPLEFT", 350, -70)
  statusH:SetText("Online")

  -- Scroll list
  local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 16, -90)
  scroll:SetPoint("BOTTOMRIGHT", -36, 50)

  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(360, 1)
  scroll:SetScrollChild(content)
  f.content = content
  f.rows = {}

  -- Footer status text
  f.summary = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.summary:SetPoint("BOTTOM", 0, 32)
  f.summary:SetText("0 found (0 online)")

  -- Refresh button — hardware event, broadcasts P + MR + TR + DR.
  local refresh = makeButton(f, "Refresh", 100, 22, function()
    TRPLite.broadcastSelf()
    TRPLite.log("Broadcast sent.")
    TRPLite.UI.refreshDirectory()
  end)
  refresh:SetPoint("BOTTOMLEFT", 16, 12)

  -- Open profile shortcut
  local prof = makeButton(f, "My Profile", 100, 22, function()
    TRPLite.UI.openProfileEditor()
  end)
  prof:SetPoint("BOTTOMLEFT", refresh, "BOTTOMRIGHT", 4, 0)

  -- Clean: remove offline characters (no ping in last 5 minutes) from
  -- the cache. Confirmation popup before doing it so a misclick can't
  -- nuke the directory.
  local clean = makeButton(f, "Clean", 80, 22, function()
    StaticPopup_Show("TRPLITE_CONFIRM_CLEAN")
  end)
  clean:SetPoint("BOTTOMLEFT", prof, "BOTTOMRIGHT", 4, 0)

  Directory = f
  return f
end

-- Confirmation popup for the directory's Clean button. Defined once at
-- file load — StaticPopupDialogs is global and persists for the session.
StaticPopupDialogs["TRPLITE_CONFIRM_CLEAN"] = {
  text         = "Remove all offline characters (no ping in 5+ minutes) from the TRPLite directory?",
  button1      = YES,
  button2      = NO,
  OnAccept     = function()
    local n = TRPLite.cleanOffline()
    TRPLite.log("Removed " .. n .. " offline character" ..
                (n == 1 and "" or "s") .. ".")
    TRPLite.UI.refreshDirectory()
  end,
  timeout      = 0,
  whileDead    = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

-- Build/update one row in the directory list.
local function setRow(row, name, zone, online, char)
  row.nameText:SetText(name)
  row.zoneText:SetText(zone or "")
  if online then
    row.dot:SetVertexColor(0.1, 0.9, 0.1)
  else
    row.dot:SetVertexColor(0.5, 0.5, 0.5)
  end
  row.charName = name
  row:Show()
end

local function makeRow(parent, idx)
  local row = CreateFrame("Button", nil, parent)
  row:SetSize(360, 18)
  row:SetPoint("TOPLEFT", 0, -(idx - 1) * 18)
  row:RegisterForClicks("LeftButtonUp")

  local hl = row:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.1)

  row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  row.nameText:SetPoint("LEFT", 8, 0)
  row.nameText:SetWidth(110)
  row.nameText:SetJustifyH("LEFT")

  row.zoneText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  row.zoneText:SetPoint("LEFT", 130, 0)
  row.zoneText:SetWidth(190)
  row.zoneText:SetJustifyH("LEFT")

  row.dot = row:CreateTexture(nil, "OVERLAY")
  row.dot:SetSize(10, 10)
  row.dot:SetPoint("LEFT", 330, 0)
  row.dot:SetColorTexture(0.5, 0.5, 0.5)

  -- Click: re-request M/T/D for this player AND open the info viewer for
  -- them. Click is a hardware event, so the sends go through; the viewer
  -- subscribes to data updates and refreshes itself when chunks land.
  --
  -- We use the forced variant (NO_KEY) so the request can't be short-
  -- circuited by a key match on the responder side — TurtleRP never
  -- bumps its keys on edits, so without forcing NO_KEY a refresh click
  -- after the sender added new fields would silently return nothing.
  row:SetScript("OnClick", function(self)
    if not self.charName or self.charName == "" then return end
    TRPLite.requestDataForced("M", self.charName)
    TRPLite.requestDataForced("T", self.charName)
    TRPLite.requestDataForced("D", self.charName)
    TRPLite.log("Requested data from " .. self.charName .. "...")
    if TRPLite.UI.openInfoView then
      TRPLite.UI.openInfoView(self.charName)
    end
  end)

  return row
end

function TRPLite.UI.refreshDirectory()
  local f = Directory
  if not f or not f:IsShown() then return end
  if not TRPLiteCharacters then return end

  -- Snapshot known characters, applying the filter as we go. Filter is
  -- a case-insensitive substring match on the character name; empty
  -- filter accepts everything. We compute total counts (how many
  -- characters exist in the cache and how many of them are online)
  -- alongside the filtered list so the summary can show both.
  local filter = (f.filterText or ""):lower()
  local list = {}
  local totalCount = 0
  local totalOnline = 0
  local now = time()
  for name, char in pairs(TRPLiteCharacters) do
    totalCount = totalCount + 1
    local ts   = TRPLite.queryablePlayers[name]
    local isOn = ts and (ts > now - 65) or false
    if isOn then totalOnline = totalOnline + 1 end
    if filter == "" or string.find(name:lower(), filter, 1, true) then
      table.insert(list, { name = name, char = char, online = isOn })
    end
  end
  table.sort(list, function(a, b) return a.name < b.name end)

  local visibleOnline = 0
  for i, entry in ipairs(list) do
    local row = f.rows[i] or makeRow(f.content, i)
    f.rows[i] = row
    if entry.online then visibleOnline = visibleOnline + 1 end
    setRow(row, entry.name, entry.char.zone, entry.online, entry.char)
  end
  -- Hide unused rows.
  for i = #list + 1, #f.rows do
    f.rows[i]:Hide()
  end
  f.content:SetHeight(math.max(1, #list * 18))

  -- Summary: when filter is active show "shown / total" so the user
  -- knows how much they're hiding. Without a filter, just totals.
  if filter ~= "" then
    f.summary:SetFormattedText("%d of %d shown (%d online)",
                               #list, totalCount, visibleOnline)
  else
    f.summary:SetFormattedText("%d found (%d online)", totalCount, totalOnline)
  end
end

function TRPLite.UI.openDirectory()
  local f = buildDirectory()
  f:Show()
  TRPLite.UI.refreshDirectory()
end

-- =============================================================================
-- Profile editor frame
-- =============================================================================
--
-- Tabbed layout: Identity / RP-info / Description. Each field row is
-- a label, a value widget (edit box, dropdown, multiline, or checkbox),
-- and a small "share" checkbox to its right. The share checkbox toggles
-- the corresponding entry in TRPLiteMyProfile.share — when the user saves,
-- unshared fields are still preserved locally but are sent on the wire as
-- empty strings (the position is preserved so TurtleRP receivers parse
-- the rest correctly).
--
-- Single Save & Broadcast button at the bottom commits all fields from
-- all tabs and fires broadcastSelf. Click = hardware event = sends go
-- through the silent-drop on the 1.14 client.

local Editor = nil
local EditorWidgets   = {}   -- field name -> { value = <widget>, share = <checkbox> }
local EditorTabPanels = {}   -- tab key -> Frame

-- Field schema for the editor. `bucket` is the wire bucket (M/T/D);
-- `tab` controls placement; `type` selects the widget; `options` for
-- dropdowns is { {value, label}, ... } in display order.
local FIELDS = {
  -- Identity (M bucket) -----------------------------------------------------
  { name = "full_name",    label = "Full Name",     type = "edit",     tab = "identity", bucket = "M" },
  { name = "race",         label = "Race",          type = "edit",     tab = "identity", bucket = "M" },
  { name = "class",        label = "Class",         type = "edit",     tab = "identity", bucket = "M" },
  { name = "class_color",  label = "Class Color (hex, e.g. ff7c0a)",
                                                    type = "edit",     tab = "identity", bucket = "M" },
  { name = "currently_ic", label = "Currently IC",
                                                    type = "checkbox", tab = "identity", bucket = "M" },
  { name = "ic_info",      label = "IC short info", type = "edit",     tab = "identity", bucket = "M" },
  { name = "ooc_info",     label = "OOC short info",type = "edit",     tab = "identity", bucket = "M" },

  -- RP-info (T bucket) ------------------------------------------------------
  -- The 9 At-a-Glance slots (atAGlance1/2/3 and their Title/Icon variants)
  -- are deliberately not editable here. They're listed in
  -- TRPLite.alwaysEmptyFields so the wire format still carries empty
  -- strings in their positions — sidestepping a nil-value render bug in
  -- Vanessa's TurtleRP that fires whenever AAG data is non-empty.
  { name = "experience",   label = "RP Experience", type = "dropdown", tab = "rpinfo", bucket = "T",
    options = { {"0","(not set)"}, {"a","New"}, {"b","Comfortable"},
                {"c","Advanced"}, {"d","Do Not Show"} } },
  { name = "walkups",      label = "Walk-Ups",      type = "dropdown", tab = "rpinfo", bucket = "T",
    options = { {"0","(not set)"}, {"a","Welcomes Walk-Ups"}, {"b","No Walk-Ups"},
                {"c","Guild Only"}, {"d","Do Not Show"} } },
  { name = "injury",       label = "Character Injury", type = "dropdown", tab = "rpinfo", bucket = "T",
    options = { {"0","(not set)"}, {"a","Acceptable"}, {"b","Ask First"},
                {"c","No"}, {"d","Do Not Show"} } },
  { name = "romance",      label = "Romance",       type = "dropdown", tab = "rpinfo", bucket = "T",
    options = { {"0","(not set)"}, {"a","Looking"}, {"b","In A Relationship"},
                {"c","Open Relationship"}, {"d","Committed"}, {"e","Ask First"},
                {"f","No"}, {"g","Do Not Show"} } },
  { name = "death",        label = "Character Death", type = "dropdown", tab = "rpinfo", bucket = "T",
    options = { {"0","(not set)"}, {"a","Acceptable"}, {"b","Ask First"},
                {"c","No"}, {"d","Do Not Show"} } },

  -- Description (D bucket) -------------------------------------------------
  { name = "description",  label = "Description",   type = "multiline", tab = "description", bucket = "D" },
}

-- ---- Widget factories ------------------------------------------------------

-- Standard "share" checkbox to the right of any value widget. Checked = the
-- field will be broadcast; unchecked = the slot is sent empty.
local function makeShareCheckbox(parent)
  local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  cb:SetSize(20, 20)
  return cb
end

-- Edit box (single line). Returns a frame with .value (the editbox) and .share.
local function makeEditRow(parent, labelText)
  local row = CreateFrame("Frame", nil, parent)
  row:SetSize(440, 38)

  local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  label:SetPoint("TOPLEFT", 0, 0)
  label:SetText(labelText)

  local edit = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
  edit:SetSize(360, 20)
  edit:SetAutoFocus(false)
  edit:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 6, -2)
  edit:SetMaxLetters(0)
  edit:SetFontObject("ChatFontNormal")

  local share = makeShareCheckbox(row)
  share:SetPoint("LEFT", edit, "RIGHT", 8, 0)

  row.value = edit
  row.share = share
  return row
end

-- Multiline edit box (description). Backdrop so the description area is
-- visually delineated. The internal scrollbar from UIPanelScrollFrameTemplate
-- is hidden (its up/down arrow buttons were rendering as stray controls
-- next to the share checkbox); the EditBox auto-scrolls with the cursor
-- when typing, which is enough for the field. Share checkbox sits at
-- TOPRIGHT of the row, aligned with the label.
local function makeMultilineRow(parent, labelText, height)
  height = height or 90
  local row = CreateFrame("Frame", nil, parent)
  row:SetSize(440, height + 20)

  local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  label:SetPoint("TOPLEFT", 0, 0)
  label:SetText(labelText)

  local share = makeShareCheckbox(row)
  share:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4, 0)

  -- Visible bordered container so the user knows where the description
  -- field is and where it ends.
  local box = CreateFrame("Frame", nil, row, "BackdropTemplate")
  box:SetSize(430, height)
  box:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -2)
  if box.SetBackdrop then
    box:SetBackdrop({
      bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 12,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    box:SetBackdropColor(0, 0, 0, 0.6)
  end

  local scroll = CreateFrame("ScrollFrame", nil, box)
  scroll:SetPoint("TOPLEFT", 6, -6)
  scroll:SetPoint("BOTTOMRIGHT", -6, 6)

  local edit = CreateFrame("EditBox", nil, scroll)
  edit:SetMultiLine(true)
  edit:SetSize(418, height - 12)
  edit:SetFontObject("ChatFontNormal")
  edit:SetAutoFocus(false)
  edit:SetMaxLetters(0)
  edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  scroll:SetScrollChild(edit)

  row.value = edit
  row.share = share
  return row
end

-- Boolean checkbox row (like currently_ic). The "value" is the checkbox
-- itself; we serialize it as "1" / "0" on save.
local function makeCheckboxRow(parent, labelText)
  local row = CreateFrame("Frame", nil, parent)
  row:SetSize(440, 22)

  local cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
  cb:SetSize(20, 20)
  cb:SetPoint("TOPLEFT", 4, 0)

  local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  label:SetPoint("LEFT", cb, "RIGHT", 4, 0)
  label:SetText(labelText)

  local share = makeShareCheckbox(row)
  share:SetPoint("LEFT", row, "LEFT", 380, 0)

  row.value = cb       -- boolean read via GetChecked()
  row.share = share
  row.kind  = "checkbox"
  return row
end

-- Dropdown row using UIDropDownMenuTemplate. options is { {value,label}, ... }.
local function makeDropdownRow(parent, labelText, options)
  local row = CreateFrame("Frame", nil, parent)
  row:SetSize(440, 44)

  local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  label:SetPoint("TOPLEFT", 0, 0)
  label:SetText(labelText)

  local dd = CreateFrame("Frame", nil, row, "UIDropDownMenuTemplate")
  dd:SetPoint("TOPLEFT", label, "BOTTOMLEFT", -16, -2)
  UIDropDownMenu_SetWidth(dd, 200)

  -- Internal state: dd.selectedValue holds the wire value (e.g. "a").
  dd.selectedValue = "0"

  UIDropDownMenu_Initialize(dd, function(self, level, menuList)
    for _, pair in ipairs(options) do
      -- Capture each pair's value/label as upvalues. info.func is invoked
      -- by Blizzard with the BUTTON as its first arg, not the info table —
      -- the button doesn't carry .text reliably (it lives on a fontstring),
      -- so don't try to read item.text. Use the closure instead.
      local val, lbl = pair[1], pair[2]
      local info = UIDropDownMenu_CreateInfo()
      info.text    = lbl
      info.value   = val
      info.checked = (dd.selectedValue == val)
      info.func    = function()
        dd.selectedValue = val
        UIDropDownMenu_SetText(dd, lbl)
        CloseDropDownMenus()
      end
      UIDropDownMenu_AddButton(info)
    end
  end)
  UIDropDownMenu_SetText(dd, "(not set)")

  local share = makeShareCheckbox(row)
  share:SetPoint("LEFT", dd, "RIGHT", 0, 4)

  row.value   = dd
  row.share   = share
  row.kind    = "dropdown"
  row.options = options
  return row
end

-- Map dropdown wire-value -> display label.
local function dropdownLabelFor(options, value)
  for _, pair in ipairs(options) do
    if pair[1] == value then return pair[2] end
  end
  return "(not set)"
end

-- ---- Builders --------------------------------------------------------------

local function buildEditor()
  if Editor then return Editor end

  local f = CreateFrame("Frame", "TRPLite_Editor", UIParent, "BackdropTemplate")
  f:SetSize(500, 620)
  f:SetPoint("CENTER")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop",  f.StopMovingOrSizing)
  f:SetClampedToScreen(true)
  f:Hide()
  f:SetFrameStrata("DIALOG")
  makeBackdrop(f)
  makeTitle(f, "TRPLite — Profile")
  makeCloseButton(f)

  -- Hint about the share checkbox column.
  local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("TOP", 0, -34)
  hint:SetText("Right column: check = broadcast this field, uncheck = keep private")

  -- Tab buttons across the top.
  local tabDefs = {
    { key = "identity",    label = "Identity"     },
    { key = "rpinfo",      label = "RP-info"      },
    { key = "description", label = "Description"  },
  }
  local tabButtons = {}
  for i, def in ipairs(tabDefs) do
    local btn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btn:SetSize(140, 24)
    btn:SetPoint("TOPLEFT", 16 + (i - 1) * 145, -56)
    btn:SetText(def.label)
    btn.tabKey = def.key
    btn:SetScript("OnClick", function(self)
      for k, panel in pairs(EditorTabPanels) do
        if k == self.tabKey then panel:Show() else panel:Hide() end
      end
    end)
    tabButtons[i] = btn
  end

  -- Tab content panels. Plain Frames — content fits comfortably after the
  -- AAG and icon removals, no scrolling needed.
  EditorTabPanels = {}
  for _, def in ipairs(tabDefs) do
    local panel = CreateFrame("Frame", nil, f)
    panel:SetPoint("TOPLEFT", 16, -90)
    panel:SetPoint("BOTTOMRIGHT", -16, 50)
    panel:Hide()
    EditorTabPanels[def.key] = panel
  end

  -- Generate fields into the appropriate tab panel and stack vertically.
  local tabYOffset = { identity = 0, rpinfo = 0, description = 0 }
  for _, def in ipairs(FIELDS) do
    local panel = EditorTabPanels[def.tab]
    local row
    if     def.type == "edit"      then row = makeEditRow(panel, def.label)
    elseif def.type == "multiline" then row = makeMultilineRow(panel, def.label, 200)
    elseif def.type == "checkbox"  then row = makeCheckboxRow(panel, def.label)
    elseif def.type == "dropdown"  then row = makeDropdownRow(panel, def.label, def.options)
    end
    if row then
      row:SetPoint("TOPLEFT", 0, -tabYOffset[def.tab])
      tabYOffset[def.tab] = tabYOffset[def.tab] + row:GetHeight() + 4
      EditorWidgets[def.name] = row
    end
  end

  -- Save: traverse all fields, write to profile, bump keys per bucket,
  -- broadcast. Click is a hardware event → sends go through.
  local save = makeButton(f, "Save & Broadcast", 160, 24, function()
    if not TRPLiteMyProfile then TRPLiteMyProfile = TRPLite.defaultProfile() end
    if not TRPLiteMyProfile.share then TRPLiteMyProfile.share = TRPLite.defaultProfile().share end

    local changed = { M = false, T = false, D = false }

    for _, def in ipairs(FIELDS) do
      local row = EditorWidgets[def.name]
      if row then
        local newVal
        if def.type == "checkbox" then
          newVal = row.value:GetChecked() and "1" or "0"
        elseif def.type == "dropdown" then
          newVal = row.value.selectedValue or "0"
        else
          newVal = row.value:GetText() or ""
        end
        if TRPLiteMyProfile[def.name] ~= newVal then
          TRPLiteMyProfile[def.name] = newVal
          changed[def.bucket] = true
        end

        -- Share toggle.
        local newShare = row.share:GetChecked() and true or false
        if TRPLiteMyProfile.share[def.name] ~= newShare then
          TRPLiteMyProfile.share[def.name] = newShare
          changed[def.bucket] = true
        end
      end
    end

    if changed.M then TRPLite.bumpKey("M") end
    if changed.T then TRPLite.bumpKey("T") end
    if changed.D then TRPLite.bumpKey("D") end

    TRPLite.broadcastSelf()
    TRPLite.log("Profile saved and broadcast.")
    f:Hide()
  end)
  save:SetPoint("BOTTOMLEFT", 24, 16)

  local cancel = makeButton(f, "Cancel", 90, 24, function() f:Hide() end)
  cancel:SetPoint("BOTTOMRIGHT", -24, 16)

  -- Default to Identity tab.
  EditorTabPanels.identity:Show()

  Editor = f
  return f
end

-- Populate widgets from TRPLiteMyProfile when the editor opens.
local function loadEditorFromProfile()
  if not TRPLiteMyProfile then return end
  local share = TRPLiteMyProfile.share or {}
  for _, def in ipairs(FIELDS) do
    local row = EditorWidgets[def.name]
    if row then
      local cur = TRPLiteMyProfile[def.name] or ""
      if def.type == "checkbox" then
        row.value:SetChecked(cur == "1" or cur == true)
      elseif def.type == "dropdown" then
        row.value.selectedValue = (cur ~= nil and cur ~= "" and tostring(cur)) or "0"
        UIDropDownMenu_SetText(row.value, dropdownLabelFor(def.options, row.value.selectedValue))
      else
        row.value:SetText(tostring(cur))
        if row.value.SetCursorPosition then row.value:SetCursorPosition(0) end
      end
      -- Share checkbox: default to true if not previously stored.
      local s = share[def.name]
      if s == nil then s = true end
      row.share:SetChecked(s and true or false)
    end
  end
end

function TRPLite.UI.openProfileEditor()
  local f = buildEditor()
  loadEditorFromProfile()
  f:Show()
end

-- =============================================================================
-- Info viewer — read-only display of another player's RP data
-- =============================================================================
--
-- Opens for any character we have cached data on. Useful primarily for
-- viewing At-a-Glance entries received from a 1.12 TurtleRP user (TRPLite
-- doesn't send AAG, but it parses and stores them when received). The
-- viewer also surfaces the RP-info dropdown values translated to their
-- human-readable labels and the description.
--
-- Singleton: opening for a different character just retargets the viewer.
-- recvData refreshes the panel if the currently-viewed name matches.

local InfoView = nil
local InfoViewTarget = nil   -- name currently being shown

-- Pull the human-readable label for a given dropdown value from the FIELDS
-- metadata. Used to translate "a"/"b"/"c"/... into "New"/"Comfortable"/etc.
local function rpInfoLabel(fieldName, value)
  for _, def in ipairs(FIELDS) do
    if def.name == fieldName and def.options then
      for _, pair in ipairs(def.options) do
        if pair[1] == value then return pair[2] end
      end
    end
  end
  return "(not set)"
end

local function buildInfoView()
  if InfoView then return InfoView end

  local f = CreateFrame("Frame", "TRPLite_InfoView", UIParent, "BackdropTemplate")
  f:SetSize(440, 520)
  f:SetPoint("CENTER", 250, 0)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop",  f.StopMovingOrSizing)
  f:SetClampedToScreen(true)
  f:SetFrameStrata("DIALOG")
  f:Hide()
  makeBackdrop(f)
  makeCloseButton(f)

  -- Title shows the current target.
  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.title:SetPoint("TOP", 0, -16)
  f.title:SetText("TRPLite — Info")

  -- Scrollable body. Content height is recomputed on each refresh.
  local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 16, -42)
  scroll:SetPoint("BOTTOMRIGHT", -36, 16)

  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(380, 1)
  scroll:SetScrollChild(content)

  -- Pre-create the FontStrings we'll fill on every refresh.
  local function newSection(parent, prevAnchor, color)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetWidth(380)
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("TOP")
    if color then fs:SetTextColor(color[1], color[2], color[3]) end
    if prevAnchor then
      fs:SetPoint("TOPLEFT", prevAnchor, "BOTTOMLEFT", 0, -10)
    else
      fs:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    end
    return fs
  end

  f.identityFS = newSection(content, nil)
  f.aagHeader  = newSection(content, f.identityFS, { 0.95, 0.8, 0.2 })
  f.aag1FS     = newSection(content, f.aagHeader)
  f.aag2FS     = newSection(content, f.aag1FS)
  f.aag3FS     = newSection(content, f.aag2FS)
  f.rpHeader   = newSection(content, f.aag3FS,    { 0.95, 0.8, 0.2 })
  f.rpFS       = newSection(content, f.rpHeader)
  f.descHeader = newSection(content, f.rpFS,      { 0.95, 0.8, 0.2 })
  f.descFS     = newSection(content, f.descHeader)
  f.descFS:SetSpacing(2)

  f.content = content
  InfoView = f
  return f
end

-- Refresh the InfoView from cached data. Safe to call any time; if the
-- viewer isn't open or no target is set, this is a no-op.
function TRPLite.UI.refreshInfoView()
  local f = InfoView
  if not f or not f:IsShown() or not InfoViewTarget then return end
  local name = InfoViewTarget
  local char = TRPLiteCharacters and TRPLiteCharacters[name]

  f.title:SetText("TRPLite — " .. name)

  -- Identity block.
  if char then
    local lines = {}
    if char.full_name and char.full_name ~= "" then
      table.insert(lines, "|cffabd473" .. char.full_name .. "|r")
    else
      table.insert(lines, "|cffabd473" .. name .. "|r")
    end
    local race = char.race and char.race ~= "" and char.race or "(unknown race)"
    local class = char.class and char.class ~= "" and char.class or "(unknown class)"
    table.insert(lines, race .. " — " .. class)
    if char.currently_ic == "1" then
      table.insert(lines, "|cff00ff00Currently IC|r")
    elseif char.currently_ic == "0" then
      table.insert(lines, "|cffaaaaaaCurrently OOC|r")
    end
    if char.ic_info and char.ic_info ~= "" then
      table.insert(lines, "IC: " .. char.ic_info)
    end
    if char.ooc_info and char.ooc_info ~= "" then
      table.insert(lines, "|cffaaaaff" .. "OOC: " .. char.ooc_info .. "|r")
    end
    f.identityFS:SetText(table.concat(lines, "\n"))
  else
    f.identityFS:SetText("|cffabd473" .. name .. "|r\n(no data received yet — click again to re-request)")
  end

  -- At-a-Glance entries. Empty slots are skipped. We have no icon table
  -- bundled, so we render title + text only; if a slot has no title and
  -- no text we hide it entirely.
  local hasAAG = false
  local function aagText(idx)
    if not char then return "" end
    local title = char["atAGlance" .. idx .. "Title"] or ""
    local body  = char["atAGlance" .. idx] or ""
    if title == "" and body == "" then return nil end
    hasAAG = true
    local s = ""
    if title ~= "" then s = "|cffffd75e" .. title .. "|r\n" end
    if body  ~= "" then s = s .. body end
    return s
  end
  local aag1, aag2, aag3 = aagText(1), aagText(2), aagText(3)
  f.aagHeader:SetText(hasAAG and "At-a-Glance" or "")
  f.aag1FS:SetText(aag1 or "")
  f.aag2FS:SetText(aag2 or "")
  f.aag3FS:SetText(aag3 or "")

  -- RP info: the 5 dropdown fields with human-readable labels.
  if char then
    local rpLines = {}
    local rpFields = { "experience", "walkups", "injury", "romance", "death" }
    local rpLabels = {
      experience = "RP Experience",
      walkups    = "Walk-Ups",
      injury     = "Character Injury",
      romance    = "Romance",
      death      = "Character Death",
    }
    for _, fname in ipairs(rpFields) do
      local v = char[fname] or "0"
      if v ~= "" and v ~= "0" then
        table.insert(rpLines, rpLabels[fname] .. ": " .. rpInfoLabel(fname, v))
      end
    end
    if #rpLines > 0 then
      f.rpHeader:SetText("RP Info")
      f.rpFS:SetText(table.concat(rpLines, "\n"))
    else
      f.rpHeader:SetText("")
      f.rpFS:SetText("")
    end
  else
    f.rpHeader:SetText("")
    f.rpFS:SetText("")
  end

  -- Description (D bucket) — full text, may be multi-line. TurtleRP sends
  -- a single space " " as a placeholder when the description is empty
  -- (to avoid an empty-payload edge case in its sender), so treat any
  -- whitespace-only value as "no description" and skip the header too.
  local desc = char and char.description
  if desc and not string.match(desc, "^%s*$") then
    f.descHeader:SetText("Description")
    f.descFS:SetText(desc)
  else
    f.descHeader:SetText("")
    f.descFS:SetText("")
  end

  -- Compute total content height so the scrollbar's range matches.
  -- StringHeight isn't always cheap; we use GetStringHeight on each
  -- visible FontString and add fixed gap allowances.
  local total = 0
  local function add(fs, isHeader)
    local txt = fs:GetText()
    if txt and txt ~= "" then
      total = total + (fs:GetStringHeight() or 0) + (isHeader and 14 or 10)
    end
  end
  add(f.identityFS)
  add(f.aagHeader, true) ; add(f.aag1FS) ; add(f.aag2FS) ; add(f.aag3FS)
  add(f.rpHeader,  true) ; add(f.rpFS)
  add(f.descHeader,true) ; add(f.descFS)
  f.content:SetHeight(math.max(1, total + 20))
end

function TRPLite.UI.openInfoView(name)
  if not name or name == "" then return end
  InfoViewTarget = name
  local f = buildInfoView()
  f:Show()
  TRPLite.UI.refreshInfoView()
end

-- =============================================================================
-- Tooltip integration
-- =============================================================================

-- Hook GameTooltip's unit-tooltip render. When the unit is a player we
-- have cached data for, append RP info lines. Pure read-out — no sends
-- happen here, since OnTooltipSetUnit fires from a non-hardware-event
-- context and any send would be silently dropped anyway.
local function onUnitTooltip(self)
  if not TRPLiteCharacters then return end
  local _, unit = self:GetUnit()
  if not unit or not UnitIsPlayer(unit) then return end
  local name = UnitName(unit)
  if not name then return end
  local char = TRPLiteCharacters[name]
  if not char then return end

  -- Add a separator and the RP details we have on file.
  self:AddLine(" ")
  if char.full_name and char.full_name ~= "" then
    self:AddLine("|cffabd473" .. char.full_name .. "|r")
  end
  if char.ic_info and char.ic_info ~= "" then
    self:AddLine("IC: " .. char.ic_info, 1, 1, 1, true)
  end
  if char.ooc_info and char.ooc_info ~= "" then
    self:AddLine("OOC: " .. char.ooc_info, 0.7, 0.7, 0.9, true)
  end
  -- Pronouns intentionally not surfaced in TRPLite — no editor field for
  -- them, no tooltip line either.
  self:Show()
end

if GameTooltip and GameTooltip.HookScript then
  GameTooltip:HookScript("OnTooltipSetUnit", onUnitTooltip)
end

-- =============================================================================
-- Minimap button
-- =============================================================================
--
-- A small draggable button. Left-click opens the directory; right-click
-- toggles the lock. When unlocked, the button uses Blizzard's standard
-- StartMoving/StopMovingOrSizing so it can be dragged anywhere on the
-- screen — not just around the minimap perimeter — letting the user
-- park it alongside other addons' minimap buttons in a vertical row to
-- the side, or wherever else fits their HUD.
--
-- Position is saved as a full anchor record (point, relativePoint, x, y).
-- On first install (or after a settings reset) we fall back to a default
-- position on the minimap perimeter at angle 200 so the button is
-- discoverable.

local MinimapButton = nil
local MINIMAP_RADIUS = 80   -- default radius for first-install placement

-- Place the button at the saved anchor, or default to the minimap
-- perimeter if no anchor exists yet.
local function placeMinimapButton(button)
  local saved = TRPLiteSettings and TRPLiteSettings.minimap_anchor
  button:ClearAllPoints()
  if saved and saved.point and saved.relativePoint then
    button:SetPoint(saved.point, UIParent, saved.relativePoint,
                    saved.x or 0, saved.y or 0)
  else
    -- Fallback: place on the minimap perimeter at the default angle.
    local angle = (TRPLiteSettings and TRPLiteSettings.minimap_position) or 200
    local rad = math.rad(angle)
    local x = math.cos(rad) * MINIMAP_RADIUS
    local y = math.sin(rad) * MINIMAP_RADIUS
    button:SetPoint("CENTER", Minimap, "CENTER", x, y)
  end
end

local function buildMinimapButton()
  if MinimapButton then return MinimapButton end

  -- Parent to UIParent (not Minimap) so the button can be dragged
  -- outside the minimap's clip region. Strata + level kept high so it
  -- stays visible above other UI when placed in busy areas.
  local btn = CreateFrame("Button", "TRPLite_MinimapButton", UIParent)
  btn:SetSize(32, 32)
  btn:SetFrameStrata("MEDIUM")
  btn:SetFrameLevel(8)
  btn:SetMovable(true)
  btn:SetClampedToScreen(true)
  btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  btn:RegisterForDrag("LeftButton")

  -- Icon (the actual TRPLite glyph)
  local icon = btn:CreateTexture(nil, "BACKGROUND")
  icon:SetTexture("Interface\\Icons\\INV_Misc_Note_01")
  icon:SetSize(20, 20)
  icon:SetPoint("CENTER")
  icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)   -- trim default icon edges
  btn.icon = icon

  -- Standard minimap-button border ring
  local border = btn:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetSize(54, 54)
  border:SetPoint("TOPLEFT", -2, 2)

  -- Hover highlight matching other minimap buttons
  btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  btn:SetScript("OnClick", function(self, mouseButton)
    if mouseButton == "LeftButton" then
      if TRPLite.UI.openDirectory then TRPLite.UI.openDirectory() end
    elseif mouseButton == "RightButton" then
      TRPLiteSettings.minimap_locked = not TRPLiteSettings.minimap_locked
      TRPLite.log("Minimap button " ..
                  (TRPLiteSettings.minimap_locked and "locked" or "unlocked — drag to move"))
      if GameTooltip:GetOwner() == self then
        self:GetScript("OnEnter")(self)
      end
    end
  end)

  btn:SetScript("OnDragStart", function(self)
    if TRPLiteSettings and TRPLiteSettings.minimap_locked then return end
    self:StartMoving()
  end)

  btn:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    -- Persist the new anchor so it survives /reload. We capture the
    -- first anchor point relative to UIParent (StartMoving leaves the
    -- frame anchored that way) and store its components individually
    -- so they round-trip through the SavedVariables serializer.
    local point, _, relativePoint, x, y = self:GetPoint(1)
    if TRPLiteSettings then
      TRPLiteSettings.minimap_anchor = {
        point          = point,
        relativePoint  = relativePoint,
        x              = x,
        y              = y,
      }
    end
  end)

  btn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("|cff8C48ABTRPLite|r")
    GameTooltip:AddLine("|cffeda55fLeft-click|r open directory", 1, 1, 1)
    local rightHint = (TRPLiteSettings and TRPLiteSettings.minimap_locked)
                      and "unlock to drag" or "lock in place"
    GameTooltip:AddLine("|cffeda55fRight-click|r " .. rightHint, 1, 1, 1)
    GameTooltip:Show()
  end)
  btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  MinimapButton = btn
  return btn
end

-- Called from ADDON_LOADED. Builds the button (lazily) if not hidden and
-- applies the saved anchor / falls back to the default perimeter spot.
function TRPLite.UI.setupMinimapIcon()
  if not TRPLiteSettings then return end
  if TRPLiteSettings.minimap_hide then
    if MinimapButton then MinimapButton:Hide() end
    return
  end
  local btn = buildMinimapButton()
  placeMinimapButton(btn)
  btn:Show()
end

-- /trp minimap entry point — flips visibility and persists the choice.
function TRPLite.UI.toggleMinimapIcon()
  if not TRPLiteSettings then return end
  TRPLiteSettings.minimap_hide = not TRPLiteSettings.minimap_hide
  if TRPLiteSettings.minimap_hide then
    if MinimapButton then MinimapButton:Hide() end
    TRPLite.log("Minimap button hidden. Use |cff8C48AB/trp minimap|r to show again.")
  else
    TRPLite.UI.setupMinimapIcon()
    TRPLite.log("Minimap button shown.")
  end
end
