-- DecorDyeIndicator/Core.lua
-- Displays a paintbrush icon on the housing decor preview window if the item is dyeable.

local ADDON_NAME = "DecorDyeIndicator"
local TEXTURE_PATH = "Interface\\AddOns\\DecorDyeIndicator\\Media\\paintbrush.png"
local FALLBACK_TEXTURE = "Interface\\Icons\\INV_Misc_PaintBrush_01"

local dyeIcon = nil    -- the 22x22 icon frame
local dyeIconTex = nil -- texture object, kept for /ddi fallback

-- ---------------------------------------------------------------------------
-- Icon creation
-- ---------------------------------------------------------------------------

local function CreateDyeIcon(parent, anchorTo)
    if dyeIcon then return end

    dyeIcon = CreateFrame("Frame", "DecorDyeIndicatorIcon", parent)
    dyeIcon:SetSize(22, 22)
    dyeIcon:SetFrameStrata("FULLSCREEN_DIALOG")
    dyeIcon:SetFrameLevel((parent:GetFrameLevel() or 10) + 20)
    dyeIcon:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -52, -18)

    dyeIconTex = dyeIcon:CreateTexture(nil, "OVERLAY", nil, 7)
    dyeIconTex:SetAllPoints(dyeIcon)
    dyeIconTex:SetTexture(TEXTURE_PATH)

    dyeIcon:EnableMouse(true)
    dyeIcon:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Dyeable Decor", 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    dyeIcon:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    dyeIcon:Hide()
end

-- ---------------------------------------------------------------------------
-- Dyeability check — catalog-definition-first, live-state fallback
-- ---------------------------------------------------------------------------

-- Inspect a single info table for any known dye-capability field.
-- This covers the static catalog definition (canCustomize, dyeSlots, etc.)
-- as well as applied-state fields (hasDyes, dyeIDs, dyeChannels).
local function CheckInfoForDyes(info)
    if not info then return false end
    -- Static / definition fields — true even when 0 dyes are currently applied
    if info.canCustomize  then return true end
    if info.isDyeable     then return true end
    if info.canBeDyed     then return true end
    if info.hasDyeSlots   then return true end
    if info.dyeSlots    and info.dyeSlots > 0    then return true end
    if info.numDyeSlots and info.numDyeSlots > 0 then return true end
    -- Applied-state / runtime fields
    if info.hasDyes       then return true end
    if type(info.dyeIDs)      == "table" and #info.dyeIDs > 0      then return true end
    if type(info.dyeChannels) == "table" and #info.dyeChannels > 0 then return true end
    return false
end

-- Attempt to fetch the master catalog definition via C_HousingCatalog and check it.
-- Accepts any info table that might carry an entry/decor/item ID.
local function CheckCatalogDefinition(info)
    if not info then return false end
    if not C_HousingCatalog then return false end

    -- Collect every candidate ID field Blizzard might store on the info table.
    local ids = {}
    for _, field in ipairs({ "housingCatalogEntryID", "catalogEntryID",
                              "decorID", "itemID", "spellID" }) do
        local v = info[field]
        if type(v) == "number" and v > 0 then
            ids[#ids + 1] = v
        end
    end

    for _, id in ipairs(ids) do
        -- Try GetCatalogEntryInfo with the ID directly.
        if type(C_HousingCatalog.GetCatalogEntryInfo) == "function" then
            local ok, def = pcall(C_HousingCatalog.GetCatalogEntryInfo, id)
            if ok and def and CheckInfoForDyes(def) then return true end
        end
        -- Some builds expose GetDecorInfo by decorID.
        if type(C_HousingCatalog.GetDecorInfo) == "function" then
            local ok, def = pcall(C_HousingCatalog.GetDecorInfo, id)
            if ok and def and CheckInfoForDyes(def) then return true end
        end
    end

    return false
end

-- Returns true if the ModelPreview's current item supports dye customization.
-- Priority: catalog master definition → live info tables → applied-state helpers.
local function IsDyeable(modelPreview)
    if not modelPreview then return false end

    -- 1. Check the raw catalogEntryInfo against C_HousingCatalog master data.
    --    This catches items that are dyeable but have 0 dyes currently applied.
    if CheckCatalogDefinition(modelPreview.catalogEntryInfo) then return true end

    -- 2. Direct field scan on catalogEntryInfo and variantInfo.
    --    Blizzard may already populate canCustomize / dyeSlots on these tables.
    if CheckInfoForDyes(modelPreview.catalogEntryInfo) then return true end
    if CheckInfoForDyes(modelPreview.variantInfo)      then return true end

    -- 3. GetCurrentDyeNames() — has content when dyes are already applied.
    if type(modelPreview.GetCurrentDyeNames) == "function" then
        local ok, result = pcall(modelPreview.GetCurrentDyeNames, modelPreview)
        if ok then
            if type(result) == "table" and #result > 0 then return true end
            if type(result) == "string" and result ~= "" then return true end
        end
    end

    -- 4. allVariantInfos > 1 — multiple unlocked variants imply dye support.
    if type(modelPreview.allVariantInfos) == "table" and
       #modelPreview.allVariantInfos > 1 then
        return true
    end

    return false
end

-- Refresh icon visibility from ModelPreview's live state.
local function UpdateIcon()
    if not dyeIcon then return end
    local modelPreview = HousingModelPreviewFrame and HousingModelPreviewFrame.ModelPreview
    if IsDyeable(modelPreview) then
        dyeIcon:Show()
    else
        dyeIcon:Hide()
    end
end

-- ---------------------------------------------------------------------------
-- Hooks into HousingModelPreviewFrame and ModelPreview
-- ---------------------------------------------------------------------------

local function SetupHooks(previewFrame)
    local modelPreview = previewFrame.ModelPreview or previewFrame

    -- Build the icon anchored to NameContainer if available, else modelPreview.
    local anchorTo = modelPreview.NameContainer or modelPreview
    CreateDyeIcon(modelPreview, anchorTo)

    -- PreviewCatalogEntryInfo — fires when a new decor entry is previewed.
    hooksecurefunc(modelPreview, "PreviewCatalogEntryInfo", function()
        UpdateIcon()
    end)

    -- ApplyCurrentVariant — fires when the player switches dye variant.
    hooksecurefunc(modelPreview, "ApplyCurrentVariant", function()
        UpdateIcon()
    end)

    -- ClearPreviewData — fires when the preview is cleared; hide the icon.
    hooksecurefunc(modelPreview, "ClearPreviewData", function()
        if dyeIcon then dyeIcon:Hide() end
    end)

    -- ShowCatalogEntryInfo on the outer frame — belt-and-suspenders refresh.
    hooksecurefunc(previewFrame, "ShowCatalogEntryInfo", function()
        UpdateIcon()
    end)

    -- Hide the icon whenever the outer preview frame closes.
    hooksecurefunc(previewFrame, "Hide", function()
        if dyeIcon then dyeIcon:Hide() end
    end)
end

-- ---------------------------------------------------------------------------
-- Initialisation — wait for HousingModelPreviewFrame
-- ---------------------------------------------------------------------------

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("ADDON_LOADED")
initFrame:SetScript("OnEvent", function(self, event, addonName)
    if event == "ADDON_LOADED" then
        if addonName == "Blizzard_HousingModelPreview" or
           addonName == ADDON_NAME then
            if HousingModelPreviewFrame then
                SetupHooks(HousingModelPreviewFrame)
                self:UnregisterEvent("ADDON_LOADED")
            end
        end
    end
end)

-- In case Blizzard_HousingModelPreview is already loaded when we run.
if HousingModelPreviewFrame then
    SetupHooks(HousingModelPreviewFrame)
    initFrame:UnregisterEvent("ADDON_LOADED")
end

-- ---------------------------------------------------------------------------
-- Slash commands:  /ddi debug   /ddi test   /ddi fallback
-- ---------------------------------------------------------------------------

local function PrintTable(label, tbl)
    if type(tbl) ~= "table" then
        print(string.format("  |cffffd700%s|r = %s", label, tostring(tbl)))
        return
    end
    print(string.format("  |cffffd700%s|r (table):", label))
    for k, v in pairs(tbl) do
        print(string.format("    |cffffd700%s|r = %s", tostring(k), tostring(v)))
    end
end

SLASH_DDI1 = "/ddi"
SlashCmdList["DDI"] = function(msg)
    local cmd = strtrim(msg or ""):lower()

    -- /ddi debug — live inspection of ModelPreview state
    if cmd == "debug" or cmd == "" then
        local mp = HousingModelPreviewFrame and HousingModelPreviewFrame.ModelPreview
        if not mp then
            print("|cffff9900[DecorDyeIndicator]|r HousingModelPreviewFrame.ModelPreview not found.")
            return
        end
        print("|cffff9900[DecorDyeIndicator]|r ModelPreview live state:")

        -- catalogEntryInfo
        PrintTable("catalogEntryInfo", mp.catalogEntryInfo)

        -- variantInfo
        PrintTable("variantInfo", mp.variantInfo)

        -- allVariantInfos count
        local variantCount = type(mp.allVariantInfos) == "table" and #mp.allVariantInfos or 0
        print(string.format("  |cffffd700allVariantInfos|r count = %d", variantCount))

        -- GetCurrentDyeNames return value
        if type(mp.GetCurrentDyeNames) == "function" then
            local ok, result = pcall(mp.GetCurrentDyeNames, mp)
            if ok then
                PrintTable("GetCurrentDyeNames()", result)
            else
                print(string.format("  |cffffd700GetCurrentDyeNames()|r ERROR: %s", tostring(result)))
            end
        else
            print("  |cffffd700GetCurrentDyeNames()|r not available on ModelPreview")
        end

        print(string.format("  |cffffd700IsDyeable result|r = %s",
            tostring(IsDyeable(mp))))

    -- /ddi fallback — swap texture to the built-in Blizzard paintbrush icon
    elseif cmd == "fallback" then
        if not dyeIconTex then
            print("|cffff9900[DecorDyeIndicator]|r Icon not created yet — open the housing preview first.")
            return
        end
        dyeIconTex:SetTexture(FALLBACK_TEXTURE)
        print("|cffff9900[DecorDyeIndicator]|r Texture switched to fallback: " .. FALLBACK_TEXTURE)

    -- /ddi test — force-toggle the paintbrush icon
    elseif cmd == "test" then
        if not dyeIcon then
            print("|cffff9900[DecorDyeIndicator]|r Icon not created yet — open the housing preview first.")
            return
        end
        if dyeIcon:IsShown() then
            dyeIcon:Hide()
            print("|cffff9900[DecorDyeIndicator]|r Icon hidden.")
        else
            dyeIcon:Show()
            print("|cffff9900[DecorDyeIndicator]|r Icon shown.")
        end

    else
        print("|cffff9900[DecorDyeIndicator]|r Usage:")
        print("  /ddi debug    — inspect ModelPreview data tables live")
        print("  /ddi test     — toggle the paintbrush icon on/off")
        print("  /ddi fallback — switch texture to built-in Blizzard paintbrush icon")
    end
end
