-- Initialize the Addon table
local Addon = Addon or {}

-- Define the mixin for handling commodity buy frame
MyAddonCommodityBuyFrameMixin = {}

local BUY_EVENTS = {
  "COMMODITY_PRICE_UPDATED",
}

function MyAddonCommodityBuyFrameMixin:OnEvent(event, ...)
  if event == "COMMODITY_PRICE_UPDATED" then
    local _, newAmount = ...
    local oldAmount = AuctionHouseFrame.CommoditiesBuyFrame.BuyDisplay.TotalPrice:GetAmount()
    if newAmount <= oldAmount then
      AuctionHouseFrame.BuyDialog.BuyNowButton:Click()
    else
      AuctionHouseFrame.BuyDialog.CancelButton:Click()
    end
    FrameUtil.UnregisterFrameForEvents(self, BUY_EVENTS)
  end
end

function MyAddonCommodityBuyFrameMixin:ButtonPress()
  AuctionHouseFrame.CommoditiesBuyFrame.BuyDisplay.BuyButton:Click()
  FrameUtil.RegisterFrameForEvents(self, BUY_EVENTS)
end

-- Create the commodity buy frame
local function CreateCommodityBuyFrame()
  if not MyAddonCommodityBuyFrame then
    MyAddonCommodityBuyFrame = CreateFrame("FRAME", "MyAddonCommodityBuyFrame", UIParent, "MyAddonCommodityBuyFrameTemplate")
    MyAddonCommodityBuyFrame:SetScript("OnEvent", MyAddonCommodityBuyFrameMixin.OnEvent)
    MyAddonCommodityBuyFrame:RegisterEvent("COMMODITY_PRICE_UPDATED")
    MyAddonCommodityBuyFrame.ButtonPress = MyAddonCommodityBuyFrameMixin.ButtonPress
  end
end

-- Constants
local ITEM_ID = 224828
local isSearching = false
local lowestPrice = nil
local lowestQuantity = nil
local searchFrame = nil
local refreshTimer = nil
local refreshInterval = 2 -- Interval in seconds to refresh
local PRICE_THRESHOLD = 310000 -- Price threshold in copper (e.g., 5 gold = 50000 copper)
local BUY_EVENTS = { "COMMODITY_PRICE_UPDATED" }

-- Function to scan for commodities (searching for specific item ID 224828)
function Addon:ScanItems()
    if isPaused then return end
    local itemKey = C_AuctionHouse.MakeItemKey(ITEM_ID)
    C_AuctionHouse.SendSearchQuery(itemKey, {}, false)
    self:AddDebugMessage("Searching for item with ID: " .. ITEM_ID)
end

-- Process commodity search results
function Addon:ProcessCommoditySearchResults()
    if not isSearching then return end

    local numResults = C_AuctionHouse.GetNumCommoditySearchResults(ITEM_ID)
    lowestPrice = nil
    lowestQuantity = nil

    -- Iterate over search results
    for i = 1, numResults do
        local resultInfo = C_AuctionHouse.GetCommoditySearchResultInfo(ITEM_ID, i)
        if resultInfo and resultInfo.unitPrice then
            local price = resultInfo.unitPrice
            local quantity = resultInfo.quantity

            -- Track the lowest price
            if not lowestPrice or price < lowestPrice then
                lowestPrice = price
                lowestQuantity = quantity
            end

            -- Flag the purchase if price is below the threshold
            if price <= PRICE_THRESHOLD then
                Addon:FlagPurchase(price, quantity)
                break
            end
        end
    end

    if lowestPrice then
        self:AddDebugMessage(string.format("Lowest Price: %d Copper, Quantity: %d", lowestPrice, lowestQuantity))
    else
        self:AddDebugMessage("No valid purchase found.")
    end
end

-- Flag a purchase for manual buy button handling
function Addon:FlagPurchase(price, quantity)
    local purchaseQuantity = math.max(1, math.floor(quantity * 0.8)) -- Buy 80% or at least 1 unit
    self.flaggedPrice = price
    self.flaggedQuantity = purchaseQuantity
    self:AddDebugMessage(string.format("Flagged %d units at %d copper for purchase.", purchaseQuantity, price))
end

-- Refresh commodity search results automatically
function Addon:RefreshCommoditySearchResults()
    if isSearching then
        self:AddDebugMessage("Refreshing search results for item with ID: " .. ITEM_ID)
        Addon:ScanItems()
    end
end

-- Start a timer to periodically refresh search results
function Addon:StartRefreshTimer()
    if not refreshTimer then
        refreshTimer = C_Timer.NewTicker(refreshInterval, function()
            Addon:RefreshCommoditySearchResults()
        end)
    end
end

-- Stop the refresh timer
function Addon:StopRefreshTimer()
    if refreshTimer then
        refreshTimer:Cancel()
        refreshTimer = nil
    end
end

-- Function to handle popup text detection and auto-click
-- Handle the popup dialogs
function Addon:HandlePopup()
    for i = 1, STATICPOPUP_NUMDIALOGS do
        local popup = _G["StaticPopup" .. i]

        if popup and popup:IsVisible() then
            local popupText = popup.text and popup.text:GetText()

            if popupText == "This item is no longer available." then
                self:AddDebugMessage("Detected 'Item not available' popup.")
                local okayButton = _G[popup:GetName() .. "Button1"]
                if okayButton and okayButton:IsVisible() and okayButton:IsEnabled() then
                    okayButton:Click()
                    self:AddDebugMessage("Clicked 'Okay' on item not available popup.")
                    return true
                end
            elseif popupText == "Are you sure you want to buy this item?" then
                self:AddDebugMessage("Detected buy confirmation popup.")
                local confirmButton = _G[popup:GetName() .. "Button1"]
                if confirmButton and confirmButton:IsVisible() and confirmButton:IsEnabled() then
                    confirmButton:Click()
                    self:AddDebugMessage("Clicked 'Confirm' on buy popup.")
                    return true
                end
            end
        end
    end

    return false
end

-- Clicks the Buy Button and handles event registration
function Addon:ClickBuyButton()
    local buyButton = AuctionHouseFrame.CommoditiesBuyFrame.BuyDisplay.BuyButton
    if buyButton and buyButton:IsVisible() and buyButton:IsEnabled() then
        buyButton:Click()
        self:AddDebugMessage("BuyButton clicked.")
        
        -- Register for events to handle price updates or other actions
        FrameUtil.RegisterFrameForEvents(self, BUY_EVENTS)
    else
        self:AddDebugMessage("BuyButton is not ready for interaction.")
    end
end

-- Function to control the refresh timing to avoid overlapping refreshes
function Addon:ControlRefreshTiming()
    -- Prevent overlapping search refreshes
    if self.isRefreshing then
        self:AddDebugMessage("Already refreshing, skipping new search.")
        return
    end
    
    self.isRefreshing = true

    -- Perform search logic
    self:AddDebugMessage("Refreshing search results for item with ID: " .. ITEM_ID)
    -- (Your search logic here)
    
    -- Add a delay to prevent refreshes from happening too quickly
    C_Timer.After(0.5, function()
        self.isRefreshing = false
    end)
end

-- Handle the price update event
function Addon:OnEvent(event, ...)
    if event == "COMMODITY_PRICE_UPDATED" then
        local _, newAmount = ...
        local oldAmount = AuctionHouseFrame.CommoditiesBuyFrame.BuyDisplay.TotalPrice:GetAmount()

        if newAmount <= oldAmount then
            -- Proceed with buying if the price hasn't increased
            self:ClickBuyButton()
        else
            -- Cancel the purchase if the price has increased
            self:AddDebugMessage("Price increased. Cancelling purchase.")
            AuctionHouseFrame.BuyDialog.CancelButton:Click()
        end

        -- Unregister for events after handling
        FrameUtil.UnregisterFrameForEvents(self, BUY_EVENTS)
    end
end

-- Update the AttemptPurchase function to use the frame
function Addon:AttemptPurchase()
    if not self.flaggedPrice or not self.flaggedQuantity then
        self:AddDebugMessage("No items flagged for purchase.")
        return
    end

    -- Ensure the commodity buy frame is created and reset
    CreateCommodityBuyFrame()
    MyAddonCommodityBuyFrame:ButtonPress()

    -- Delay to give time for the button press to be processed
    C_Timer.After(1, function()
        -- Check if the button press has triggered the appropriate actions
        if AuctionHouseFrame.CommoditiesBuyFrame.BuyDisplay.BuyButton:IsVisible() and
           AuctionHouseFrame.CommoditiesBuyFrame.BuyDisplay.BuyButton:IsEnabled() then
            self:AddDebugMessage("BuyButton should be visible and enabled.")
        else
            self:AddDebugMessage("BuyButton is not visible or enabled. Possible issue with the frame.")
        end
    end)
end

-- Create Debug Frame with Buy Flagged button
local function CreateDebugFrame()
    local frame = CreateFrame("Frame", "AuctionDebugFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(600, 400)
    frame:SetPoint("CENTER", UIParent, "CENTER")
    frame:Hide()

    -- Title
    local title = frame:CreateFontString(nil, "OVERLAY")
    title:SetFontObject("GameFontHighlight")
    title:SetPoint("CENTER", frame.TitleBg, "CENTER", 0, 0)
    title:SetText("Auction Debug Window")

    -- Scrollable output frame
    local scrollFrame = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetSize(550, 300)
    scrollFrame:SetPoint("TOP", 0, -40)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(550, 300)

    scrollFrame:SetScrollChild(content)

    -- Text output
    local outputText = CreateFrame("EditBox", nil, content)
    outputText:SetMultiLine(true)
    outputText:SetFontObject("GameFontHighlight")
    outputText:SetJustifyH("LEFT")
    outputText:SetPoint("TOPLEFT", 0, 0)
    outputText:SetSize(530, 300)
    outputText:SetAutoFocus(false)
    outputText:SetTextInsets(10, 10, 10, 10)
    outputText:SetEnabled(true)
    outputText:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    content.outputText = outputText

    -- Maintain a history of messages
    frame.messageHistory = {}

    -- Update Debug Output
    function frame:UpdateDebugOutput()
        local text = table.concat(self.messageHistory, "\n")
        outputText:SetText(text)
        scrollFrame:SetVerticalScroll(scrollFrame:GetVerticalScrollRange())
    end

    -- Start/Stop button
    local button = CreateFrame("Button", nil, frame, "GameMenuButtonTemplate")
    button:SetPoint("BOTTOM", 0, 20)
    button:SetSize(140, 40)
    button:SetText("Start Search")
    button:SetNormalFontObject("GameFontNormalLarge")
    button:SetHighlightFontObject("GameFontHighlightLarge")

    -- Button handler
    button:SetScript("OnClick", function(self)
        if isSearching then
            isSearching = false
            button:SetText("Start Search")
            frame.outputText:SetText("Search stopped.")
            Addon:StopRefreshTimer()
        else
            isSearching = true
            button:SetText("Stop Search")
            Addon:ScanItems()
            Addon:StartRefreshTimer()
        end
    end)

    -- Buy Flagged button
    local purchaseButton = CreateFrame("Button", "BuyFlaggedButton", frame, "GameMenuButtonTemplate")
    purchaseButton:SetPoint("BOTTOMRIGHT", -10, 20)
    purchaseButton:SetSize(140, 40)
    purchaseButton:SetText("Buy Flagged")
    purchaseButton:SetNormalFontObject("GameFontNormalLarge")
    purchaseButton:SetHighlightFontObject("GameFontHighlightLarge")

    -- Button click handler for buying flagged items
    purchaseButton:SetScript("OnClick", function(self)
        Addon:AttemptPurchase()
    end)

    return frame
end

-- Auction house opened event
local function OnAuctionHouseShow()
    if not searchFrame then
        searchFrame = CreateDebugFrame()
    end
    searchFrame:Show()

    -- Set up a keybinding for rapid-fire purchase (e.g., ALT + M)
    SetBindingClick("ALT-M", searchFrame:GetName() .. "BuyFlaggedButton")
end

-- Auction house closed event
local function OnAuctionHouseHide()
    if searchFrame then
        searchFrame:Hide()
        Addon:StopRefreshTimer()
    end
end

-- Event handler for auction house events
local f = CreateFrame("Frame")
f:RegisterEvent("AUCTION_HOUSE_SHOW")
f:RegisterEvent("AUCTION_HOUSE_CLOSED")
f:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
f:SetScript("OnEvent", function(self, event, ...)
    if event == "AUCTION_HOUSE_SHOW" then
        OnAuctionHouseShow()
    elseif event == "AUCTION_HOUSE_CLOSED" then
        OnAuctionHouseHide()
    elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
        Addon:ProcessCommoditySearchResults()
    end
end)

-- Add debug messages to the frame
function Addon:AddDebugMessage(message)
    if searchFrame and searchFrame.messageHistory then
        table.insert(searchFrame.messageHistory, message)
        if #searchFrame.messageHistory > 50 then
            table.remove(searchFrame.messageHistory, 1)
        end
        searchFrame:UpdateDebugOutput()
    end
end
