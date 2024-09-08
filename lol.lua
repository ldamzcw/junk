local addonName, addon = ...

addon.Buy = {}

local buyFrame = CreateFrame("Button", "AHBuyButton", nil, "SecureActionButtonTemplate")
buyFrame:SetAttribute("type", "click")

local function SetupBuyFrame()
    if AuctionHouseFrame and AuctionHouseFrame.CommoditiesBuyFrame and AuctionHouseFrame.CommoditiesBuyFrame.BuyDisplay and AuctionHouseFrame.CommoditiesBuyFrame.BuyDisplay.BuyButton then
        buyFrame:SetAttribute("clickbutton", AuctionHouseFrame.CommoditiesBuyFrame.BuyDisplay.BuyButton)
    else
        C_Timer.After(0.1, SetupBuyFrame)
    end
end

local function OnAuctionHouseShow()
    SetupBuyFrame()
end

addon.Events.RegisterEvent("AUCTION_HOUSE_SHOW", OnAuctionHouseShow)

local purchaseItem = {}

local BUY_EVENTS = {
    "COMMODITY_PRICE_UPDATED",
    "AUCTION_HOUSE_THROTTLED_SYSTEM_READY",
}

local function OnBuyEvent(self, event, ...)
    if event == "COMMODITY_PRICE_UPDATED" then
        local itemID, newAmount = ...
        if itemID == purchaseItem.itemID then
            local oldAmount = AuctionHouseFrame.CommoditiesBuyFrame.BuyDisplay.TotalPrice:GetAmount()
            if newAmount <= oldAmount and newAmount <= purchaseItem.maxPrice then
                AuctionHouseFrame.BuyDialog.BuyNowButton:Click()
            else
                addon.UI.AddDebugMessage("Commodity price increased or exceeded max price. Cancelling purchase.")
                AuctionHouseFrame.BuyDialog.CancelButton:Click()
            end
            FrameUtil.UnregisterFrameForEvents(self, BUY_EVENTS)
        end
    elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
        if next(purchaseItem) then
            C_AuctionHouse.ConfirmCommoditiesPurchase(purchaseItem.itemID, purchaseItem.quantity)
            addon.UI.AddDebugMessage(string.format("Confirming purchase of %d units of item %d", purchaseItem.quantity, purchaseItem.itemID))
            wipe(purchaseItem)
        end
    end
end

local buyEventFrame = CreateFrame("Frame")
buyEventFrame:SetScript("OnEvent", OnBuyEvent)

function addon.Buy.AttemptPurchase()
    local flaggedPrice, flaggedQuantity = addon.Scanner.GetFlaggedPurchase()
    
    if flaggedPrice and flaggedQuantity then
        purchaseItem.itemID = addon.Scanner.ITEM_ID
        purchaseItem.quantity = flaggedQuantity
        purchaseItem.maxPrice = flaggedPrice * flaggedQuantity  -- Store the max total price we're willing to pay

        buyFrame:Click()
        C_AuctionHouse.StartCommoditiesPurchase(purchaseItem.itemID, purchaseItem.quantity)
        addon.UI.AddDebugMessage(string.format("Attempting to purchase %d units at %.2fg each (max total: %.2fg)", flaggedQuantity, flaggedPrice / 10000, purchaseItem.maxPrice / 10000))
        
        FrameUtil.RegisterFrameForEvents(buyEventFrame, BUY_EVENTS)
    else
        addon.UI.AddDebugMessage("No flagged auctions to purchase")
    end
end

function addon.Buy.OnBuyButtonClick()
    addon.Buy.AttemptPurchase()
end

return addon.Buy

