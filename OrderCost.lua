local addon = _G.Goldsmith or {}
local UI = addon.UI

-- What a crafting order costs you, in the game's order window
--
-- Under the order's materials (the empty space below the last one), two
-- lines in the window's own font: what you'd actually pay (only the
-- materials you supply, not the customer's, at the qualities the window
-- has chosen) and the profit (commission and sellable rewards less that).
-- The hover lists each material, what the customer provides, the
-- commission and the rewards. CraftSim shows the full
-- recipe cost there, which on a patron order counts the customer's
-- materials as yours (idea board, 2026-10-10). The numbers come from
-- addon:GetOrderPreview (Pricing.lua), valued like History values the
-- craft afterwards. Updates when the order or the allocations change.
-- If the game's order window changes, this quietly shows nothing.

local LOGO = "Interface\\AddOns\\Goldsmith\\Media\\Logo"
local LOGO_SIZE = 18
local WIDTH = 330

local holder, line1, line2
local hooked = false
local pending = false
local preview -- the latest GetOrderPreview result, for the hover
local callbackOwner = {} -- for the form's AllocationsModified callback

local Money = function(c) return addon:FormatMoney(c) end

local function OrderView()
    local page = ProfessionsFrame and ProfessionsFrame.OrdersPage
    return page and page.OrderView
end

local function Form()
    local view = OrderView()
    return view and view.OrderDetails and view.OrderDetails.SchematicForm
end

local function ItemName(itemID)
    return C_Item.GetItemNameByID(itemID) or ("item " .. itemID)
end


-- A reward's link, unless the game hasn't loaded its name yet (the link
-- then reads "[]"): the name, or "item N" while it loads
local function RewardName(r)
    if r.link and not r.link:find("[]", 1, true) then return r.link end
    C_Item.RequestLoadItemDataByID(r.itemID)
    return ItemName(r.itemID)
end

local function FillTooltip(tooltip)
    local p = preview
    if not p then return end
    -- Under the line, not over the window's Crafting Details (user, 2026-10-11)
    tooltip:ClearAllPoints()
    tooltip:SetPoint("TOPLEFT", holder, "BOTTOMLEFT", 0, -4)
    tooltip:AddLine("Goldsmith: this order", addon:Color("gold"))
    if #p.mats > 0 then
        tooltip:AddLine("Your materials", addon:Color("muted"))
        for _, m in ipairs(p.mats) do
            local value = m.unit and Money(m.unit * m.qty) or "no price"
            tooltip:AddDoubleLine(m.qty .. "x " .. ItemName(m.itemID), value, 1, 1, 1, 1, 1, 1)
        end
    end
    if next(p.provided) then
        tooltip:AddLine("Customer provides", addon:Color("muted"))
        for id, qty in pairs(p.provided) do
            tooltip:AddLine(qty .. "x " .. ItemName(id), 0.8, 0.8, 0.8)
        end
    end
    tooltip:AddLine(" ")
    tooltip:AddDoubleLine("Commission (after the consortium's cut)", Money(p.commission), 1, 1, 1, 1, 1, 1)
    for _, r in ipairs(p.rewards) do
        local value = r.value > 0 and Money(r.value) or "can't be sold"
        tooltip:AddDoubleLine("Reward: " .. RewardName(r) .. (r.count > 1 and (" x" .. r.count) or ""),
            value, 1, 1, 1, 0.8, 0.8, 0.8)
    end
    addon:Explain(tooltip, "Your materials are valued at what yours cost you, or today's price "
        .. "if you have none: the same way History counts the order once it's crafted. "
        .. "A material you don't have yet counts at its lowest quality. "
        .. "Resourcefulness may give some back (History shows it as kept).")
    if not p.complete then
        tooltip:AddLine("Some materials have no price, so the cost is at least this.", addon:Color("warning"))
    end
end

-- The font of the window's own material names ("35/5 Sunglass Vial"), so
-- the lines read as part of the window (user, 2026-10-11); the game's
-- standard highlight font if the slots can't be read
local function NativeFont(form)
    local ok, font = pcall(function()
        for _, slots in pairs(form.reagentSlots or {}) do
            for _, slot in ipairs(slots) do
                local name = slot.Name or (slot.Button and slot.Button.Name)
                if name and name.GetFontObject and name:GetFontObject() then return name:GetFontObject() end
            end
        end
    end)
    return ok and font or GameFontHighlight
end

local function Create(form)
    holder = CreateFrame("Frame", nil, form)
    holder:SetSize(WIDTH, 40 + LOGO_SIZE + 4)
    -- The logo on its own line, so both text lines start at the same place
    -- (it sat in front of the first one, user, 2026-10-11)
    local logo = holder:CreateTexture(nil, "ARTWORK")
    logo:SetTexture(LOGO)
    logo:SetSize(LOGO_SIZE, LOGO_SIZE)
    logo:SetPoint("TOPLEFT", 0, 0)
    line1 = UI.Text(holder, "small", "text")
    line1:SetPoint("TOPLEFT", logo, "BOTTOMLEFT", 0, -4)
    line1:SetWidth(WIDTH)
    line2 = UI.Text(holder, "small", "text")
    line2:SetPoint("TOPLEFT", line1, "BOTTOMLEFT", 0, -4)
    line2:SetWidth(WIDTH)
    holder:EnableMouse(true)
    UI.SetTooltip(holder, FillTooltip, "ANCHOR_NONE")
end

-- Below the lowest of the form's material lists that's showing
local function Place(form)
    local below = form.Reagents
    if form.OptionalReagents and form.OptionalReagents:IsShown() then below = form.OptionalReagents end
    if not below then return false end
    holder:ClearAllPoints()
    holder:SetPoint("TOPLEFT", below, "BOTTOMLEFT", 0, -10)
    return true
end

local function Update()
    pending = false
    local view, form = OrderView(), Form()
    if not (view and form and view:IsShown() and form:IsShown()) then
        if holder then holder:Hide() end
        return
    end
    if not holder then Create(form) end
    local ok, p = pcall(addon.GetOrderPreview, addon, view.order, form.GetTransaction and form:GetTransaction())
    preview = ok and p or nil
    if not (preview and Place(form)) then
        holder:Hide()
        return
    end

    -- In the window's font, set each time: the slots exist only once a
    -- recipe has been shown
    local font = NativeFont(form)
    line1:SetFontObject(font)
    line2:SetFontObject(font)
    line1:SetTextColor(1, 1, 1)
    line2:SetTextColor(1, 1, 1)

    -- Just your cost and the profit: the window already marks what the
    -- customer supplies and shows the commission (user, 2026-10-11); the
    -- hover has the rest
    local cost
    if #preview.mats == 0 then
        cost = "none"
    else
        cost = (preview.complete and "" or "at least ") .. Money(preview.cost)
    end
    line1:SetText("Your materials: " .. cost)

    local profit = preview.commission + preview.rewardsValue - preview.cost
    line2:SetText("Profit: " .. (preview.complete and "" or "at most ")
        .. addon:Colorize(addon:FormatSignedMoney(profit), addon:MoneyColor(profit)))
    holder:Show()
    if GameTooltip:IsOwned(holder) and UI.RedrawTooltip then UI.RedrawTooltip(holder) end
end

local function UpdateSoon()
    if pending then return end
    pending = true
    C_Timer.After(0.05, Update)
end

-- The order window is part of Blizzard_Professions, loaded the first time
-- a profession or the crafting orders open
local function Hook()
    local view, form = OrderView(), Form()
    if hooked or not (view and form) then return end
    hooked = true
    if view.SetOrder then hooksecurefunc(view, "SetOrder", UpdateSoon) end
    view:HookScript("OnShow", UpdateSoon)
    view:HookScript("OnHide", UpdateSoon)
    form:HookScript("OnShow", UpdateSoon)
    if form.RegisterCallback and ProfessionsRecipeSchematicFormMixin and ProfessionsRecipeSchematicFormMixin.Event then
        pcall(form.RegisterCallback, form, ProfessionsRecipeSchematicFormMixin.Event.AllocationsModified, UpdateSoon, callbackOwner)
    end
end

local events = CreateFrame("Frame")
for _, event in ipairs({ "ADDON_LOADED", "TRADE_SKILL_SHOW", "BAG_UPDATE_DELAYED" }) do
    events:RegisterEvent(event)
end
events:SetScript("OnEvent", function(_, event)
    Hook()
    if event == "BAG_UPDATE_DELAYED" and holder and holder:IsShown() then UpdateSoon() end
end)

_G.Goldsmith = addon
