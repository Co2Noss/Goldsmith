local addon = _G.Goldsmith or {}
local UI = addon.UI

-- The tour
--
-- A short walk through the window for new players: a box with an arrow
-- points at one part at a time and says what it's for. When the next stop
-- is on another tab, the box asks you to click that tab (it lights up) and
-- the tour carries on once you do, so you learn where things are by using
-- them. Back, Next and X to end it at any time.
--
-- Offered once, the first time Goldsmith opens (GoldsmithDB.tourOffered);
-- started again from Getting started, Help, or /gsm tour. Closing the
-- window ends it.
--
-- Each step: tab (the tab it's on), title, text, and target = function()
-- returning the frame to point at, or two frames for an area spanning
-- both. Parts come from Window.lua (addon.tourParts, addon:GetTabScreen).

-- Sample data
--
-- A new player's window is mostly empty, which makes for a poor tour, so
-- the tour shows sample data (TourData.lua, made by Tools\Make-TourData.lua
-- from a real account): a few characters with professions, a few weeks of
-- sales and crafts, a queue. It replaces GoldsmithDB while the tour runs
-- and the player's own comes back when it ends (X, Done, closing the
-- window) or at /reload and logout, before the game saves. Its busiest
-- character becomes the player (their name and realm), and its dates move
-- so the newest is now. Settings and window choices stay the player's.
-- Login, gold and bag updates leave it alone (Characters.lua); anything
-- else recorded meanwhile (a craft, a loot) goes to the sample and is
-- lost, except transactions (purchases, sales), which are copied back.

-- Saved fields that are times (seconds), moved with the sample's clock
local TIME_KEYS = {
    time = true, timestamp = true, lastSeen = true, updated = true, seen = true, stockTime = true,
    auctionsTime = true, nextChargeAt = true, readyAt = true, set = true, reached = true, usedAt = true,
    added = true,
}
-- The player's own, kept while the sample shows. Settings aren't: the
-- sample gets a copy of them with its own excluded characters (its bank
-- alt), dropped with the sample.
local SHARED_KEYS = {
    "ui", "ui2", "professionIcons", "tourOffered", "auctionatorTipShown",
    "lastPriceUpdate", "lastFullScan",
}
-- Window choices the tour starts from (ui2 is shared with the window, so
-- the player's are saved and put back when it ends): everything shown,
-- History on All, 30 days. false = not set.
local TOUR_UI = {
    profession = "All", range = "30d", craftsShow = "all", craftsGear = false, craftsOnlyMine = false,
    craftsConcentration = false, historyKind = false, historyCharacter = false,
    itemsInBags = false, itemsCheap = false,
}
local savedUI -- the player's values of those, while the tour runs

local saved -- { db, char, ledger, entries } while the sample shows

function addon:UsingTourData()
    return saved ~= nil
end

local function Noon(t)
    local d = date("*t", t)
    return time({ year = d.year, month = d.month, day = d.day, hour = 12 })
end

-- Preparing it takes about 20-50 ms, so it's spread over frames (never a
-- stutter) by its own runner: addon:RunWork's would be stopped by the
-- window's refresh starting at the same time
local SLICE_MS = 6
local sliceStart = 0
local function Pause()
    if debugprofilestop() - sliceStart >= SLICE_MS then coroutine.yield() end
end

-- A copy of the sample with dates and times moved up to now, and "@me" /
-- "@realm" made the player's name and realm
local function Prepare(data)
    local seconds = time() - data.made
    local days = math.floor((Noon(time()) - Noon(data.made)) / 86400 + 0.5)
    local name, realm = UnitName("player") or "You", GetRealmName() or ""
    local function Text(s)
        local y, m, d = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
        if y then
            return date("%Y-%m-%d", time({ year = tonumber(y), month = tonumber(m), day = tonumber(d) + days, hour = 12 }))
        end
        if s:find("@", 1, true) then return (s:gsub("@me", name):gsub("@realm", realm)) end
        return s
    end
    local function Fix(t)
        local out = {}
        -- The sample is the runner's own table, so pairs() survives pausing
        for k, v in pairs(t) do
            Pause()
            if type(v) == "table" then
                v = Fix(v)
            elseif type(v) == "string" then
                v = Text(v)
            elseif type(v) == "number" and TIME_KEYS[k] and v > 1e9 then
                v = v + seconds
            end
            out[type(k) == "string" and Text(k) or k] = v
        end
        return out
    end
    local db = Fix(data)
    -- priceSeen[itemID] = { time, price }
    for _, seen in pairs(db.priceSeen or {}) do
        if type(seen[1]) == "number" then seen[1] = seen[1] + seconds end
    end
    return db
end

local function Swapped()
    addon:RecipesSwapped()
    addon:GatheredSwapped()
    addon:DataChanged()
    if addon.Refresh then addon.Refresh() end
end

local preparing -- { onReady } while the sample is being prepared

-- Swaps the sample in, then calls onReady (at once if it's already in, or
-- without it when there's no sample)
local function UseSampleData(onReady)
    if saved or not addon.TourDataTable then
        onReady()
        return
    end
    if preparing then
        preparing.onReady = onReady
        return
    end
    local job = { onReady = onReady }
    preparing = job
    local co = coroutine.create(function() return Prepare(addon:TourDataTable()) end)
    local function Step()
        if preparing ~= job then return end -- the tour ended meanwhile
        sliceStart = debugprofilestop()
        local ok, db = coroutine.resume(co)
        if not ok then
            preparing = nil
            geterrorhandler()(db)
            job.onReady()
            return
        end
        if coroutine.status(co) ~= "dead" then
            C_Timer.After(0, Step)
            return
        end
        preparing = nil
        for _, key in ipairs(SHARED_KEYS) do db[key] = GoldsmithDB[key] end
        local settings = {}
        for k, v in pairs(GoldsmithDB.settings or {}) do settings[k] = v end
        settings.excluded = db.excluded or {}
        db.settings = settings
        local ui = GoldsmithDB.ui2 or {}
        savedUI = {}
        for key, value in pairs(TOUR_UI) do
            savedUI[key] = ui[key] == nil and false or ui[key]
            if value == false then ui[key] = nil else ui[key] = value end
        end
        saved = { db = GoldsmithDB, char = addon.char, ledger = addon.ledger, entries = #db.entries }
        GoldsmithDB = db
        addon.char = db.characters[addon.charKey] or saved.char
        addon.ledger = addon:CreateLedger(db)
        Swapped()
        job.onReady()
    end
    Step()
end

local function UseOwnData()
    preparing = nil
    if not saved then return end
    local sample, own = GoldsmithDB, saved.db
    -- Transactions recorded during the tour are the player's: keep them
    own.entries = own.entries or {}
    own.nextId = own.nextId or (#own.entries + 1)
    for i = saved.entries + 1, #(sample.entries or {}) do
        local e = sample.entries[i]
        e.id = own.nextId
        own.nextId = own.nextId + 1
        table.insert(own.entries, e)
    end
    for _, key in ipairs(SHARED_KEYS) do own[key] = sample[key] end
    if savedUI and own.ui2 then
        for key, value in pairs(savedUI) do
            if value == false then own.ui2[key] = nil else own.ui2[key] = value end
        end
    end
    savedUI = nil
    GoldsmithDB, addon.char, addon.ledger = own, saved.char, saved.ledger
    saved = nil
    Swapped()
end

-- The game saves GoldsmithDB at logout and /reload: the player's own,
-- never the sample. This frame is made as the file loads, before the
-- frames that save at logout (made at ADDON_LOADED), so it goes first.
local logoutFrame = CreateFrame("Frame")
logoutFrame:RegisterEvent("PLAYER_LOGOUT")
logoutFrame:SetScript("OnEvent", function() UseOwnData() end)

local function Screen(key)
    local screen = addon:GetTabScreen(key)
    return screen and screen.view, screen and screen.frame
end

local function Part(name)
    return addon.tourParts and addon.tourParts[name]
end


-- Back to a tab's main screen; true if something was closed
local function CloseScreens(tab)
    if tab == "crafts" then
        local view = Screen("crafts")
        if view and view.plan.plan then
            view:ClosePlan()
            return true
        end
    elseif tab == "items" then
        local view = Screen("items")
        if view and view.page.item then
            view.page.item = nil
            addon.RefreshWindow()
            return true
        end
    end
    return false
end

-- What a step asks to click, by name (user: hand-picked so the plan and
-- the page look their best): the row showing it, or nil
local CRAFT_PICK = "Gloaming Alloy"   -- vendor, AH and crafted materials
local ITEM_PICK = "Sterling Alloy"    -- sold well, on target
local function IsCraftPick(item)
    return item and not item.salvage and item.recipe and item.recipe.outputName == CRAFT_PICK
end
local function CraftRows()
    local view = Screen("crafts")
    return view and view.list.rows or {}
end
local function BoardRows()
    local view, rows = Screen("items"), {}
    for _, board in ipairs(view and view.boards or {}) do
        for _, row in ipairs(board.rows or {}) do rows[#rows + 1] = row end
    end
    return rows
end
local PICKS = {
    plan = { name = CRAFT_PICK, rows = CraftRows,
        match = function(row) return IsCraftPick(row.data) end,
        scroll = function()
            local view = Screen("crafts")
            if view then view.list:ScrollToItem({ IsCraftPick }) end
        end },
    page = { name = ITEM_PICK, rows = BoardRows,
        match = function(row) return row.item and row.item.name == ITEM_PICK end },
}
-- The row to click; for the craft, its best quality (gold: the one with
-- a mix of material qualities to show)
local pickTier -- that row's tier, once found
local function PickedRow(which)
    local pick = PICKS[which]
    if not pick then return nil end
    local best
    for _, row in ipairs(pick.rows()) do
        if row:IsShown() and pick.match(row) then
            if which ~= "plan" then return row end
            if not best or (row.data.tier or 0) > (best.data.tier or 0) then best = row end
        end
    end
    if best then pickTier = best.data.tier end
    return best
end
local scrolled = {} -- steps that have scrolled to their pick once
local noPick = {}   -- screens whose pick wasn't found: any will do

-- What's open inside a tab: nil (nothing), "pick" (the one asked for, or
-- any when it wasn't found) or the name of something else
local function OpenScreen(which)
    if which == "plan" then
        local view = Screen("crafts")
        local plan = view and view.plan:IsShown() and view.plan.plan
        if not plan then return nil end
        local name = plan.recipe and plan.recipe.outputName
        if noPick.plan or (name == CRAFT_PICK and (not pickTier or plan.tier == pickTier)) then return "pick" end
        if name == CRAFT_PICK then return "a different quality of " .. name end
        return name or "another craft"
    elseif which == "page" then
        local view = Screen("items")
        local item = view and view.page:IsShown() and view.page.item
        if not item then return nil end
        if noPick.page or item.name == ITEM_PICK then return "pick" end
        return item.name or "another item"
    end
    return "pick"
end
local function ScreenOpen(which) return OpenScreen(which) == "pick" end
local wrongPick -- what they opened instead, to say so

local watcher -- ticker while a step waits for a screen to open
local function StopWatching()
    if watcher then watcher:Cancel() end
    watcher = nil
end

-- Each step: tab, title, text (shown on the step), target. On another tab,
-- lead (a short lead-in) shows until the tab is clicked. screen: a screen
-- inside the tab to open first ("plan", "page"); until then lead, ask
-- (what to click) and clickTarget (where).
local STEPS = {
    { tab = "overview", title = "Filters",
      text = "Pick one profession or all of them, the dates for profits and charts, and which expansions' items to show. They apply on every tab.",
      target = function() return Part("filters")[1], Part("filters")[2] end },
    { tab = "overview", title = "What clicks do",
      text = "This line always says what clicking does on the screen you're on: click, right-click, Shift-click. Hovers end with the same colored hints.",
      target = function() return Part("legend") end },
    { tab = "overview", title = "Prices",
      text = "Where prices come from right now: Goldsmith Data's daily prices for your region, an Auctionator scan, or TSM. It turns orange when prices are old.",
      target = function() return Part("price") end },
    { tab = "overview", title = "How you're doing",
      text = "Profit on what you've sold, your sales, the gold tied up in stock, and concentration across every character. Hover any number to see how it's worked out.",
      target = function()
          local view = Screen("overview")
          return view and view.tiles[1], view and view.tiles[#view.tiles]
      end },
    { tab = "overview", title = "Do this next",
      text = "The best things to do right now (Getting started while you set up): what to craft, with concentration and without. Only solid bets show here, things that sell. Click one to open its plan. Hover \"followed\" by the title to see how the suggestions you crafted did: on target or fell short.",
      target = function()
          local view = Screen("overview")
          return view and view.actionsTitle:GetParent()
      end },
    { tab = "overview", title = "Charts",
      text = "Profit by day, total gold, and gold per hour of goldmaking. The arrows switch between them. On Total gold, \"Set a goal\" gives you a gold goal to work toward.",
      target = function()
          local view = Screen("overview")
          return view and view.chartTitle:GetParent()
      end },
    { tab = "overview", title = "By profession",
      text = "Each profession's profit and concentration. Click one to filter everything to it.",
      target = function()
          local view = Screen("overview")
          return view and view.professionsNote:GetParent()
      end },
    { tab = "crafts", title = "Crafts",
      lead = "Next: everything your characters can craft.",
      text = "Every craft with its cost from your own crafting stats, AH price, profit, and how well it sells. The same cost and profit show in the game's profession window, under the reagents.",
      target = function()
          local view = Screen("crafts")
          return view and view.list
      end },
    { tab = "crafts", title = "Show",
      text = "Recommended (solid bets), All crafts, or Not learned yet: recipes worth going to learn. It can hide gear too.",
      target = function()
          local view = Screen("crafts")
          return view and view.show
      end },
    { tab = "crafts", title = "Concentration",
      text = "Turn it on to see the better quality concentration reaches, and how much gold each point earns (g/conc).",
      target = function()
          local view = Screen("crafts")
          return view and view.concSwitch
      end },
    { tab = "crafts", screen = "plan", title = "A craft's plan",
      lead = "Every craft has a plan behind it.",
      ask = "Click the highlighted " .. CRAFT_PICK .. " to open its plan.",
      askAny = "Click any craft in the list to open its plan.",
      clickTarget = function()
          local view = Screen("crafts")
          return view and view.list
      end,
      text = "How many to make, what it costs and what it makes, worked out from your own stats. Add it to the queue, or craft it right here. Back returns to the list.",
      target = function()
          local view = Screen("crafts")
          return view and view.plan
      end },
    { tab = "crafts", screen = "plan", title = "Materials",
      lead = "Every craft has a plan behind it.",
      ask = "Click the highlighted " .. CRAFT_PICK .. " to open its plan.",
      askAny = "Click any craft in the list to open its plan.",
      clickTarget = function()
          local view = Screen("crafts")
          return view and view.list
      end,
      text = "Each material and where it comes from: your bags, a vendor, the AH, or crafting it first. Right-click one to change that, for example to buy it instead of crafting it.",
      target = function()
          local view = Screen("crafts")
          return view and view.plan.list
      end },
    { tab = "crafts", screen = "plan", title = "Material qualities",
      lead = "Every craft has a plan behind it.",
      ask = "Click the highlighted " .. CRAFT_PICK .. " to open its plan.",
      askAny = "Click any craft in the list to open its plan.",
      clickTarget = function()
          local view = Screen("crafts")
          return view and view.list
      end,
      text = "The mix of material qualities: Goldsmith picks the cheapest one that reaches this quality. Click the bar to compare the top three and pick another; click it again to hide them.",
      target = function()
          local view = Screen("crafts")
          local mixes = view and view.plan.mixes
          return mixes and mixes:IsShown() and mixes or (view and view.plan)
      end },
    { tab = "crafts", screen = "plan", title = "Shopping list",
      lead = "Every craft has a plan behind it.",
      ask = "Click the highlighted " .. CRAFT_PICK .. " to open its plan.",
      askAny = "Click any craft in the list to open its plan.",
      clickTarget = function()
          local view = Screen("crafts")
          return view and view.list
      end,
      text = "With Auctionator, this sends everything you need to buy to a shopping list on the AH's Shopping tab. Items come off it as you buy them.",
      target = function()
          local view = Screen("crafts")
          return view and view.plan.shop
      end },
    { tab = "queue", title = "Queue",
      lead = "Next: crafts lined up to make.",
      text = "Crafts added from any plan or by right-clicking a craft. Each character has their own queue; the menu at the top right switches between them. One shopping list for all of it, and Craft next does the next step: one click per craft.",
      target = function() return select(2, Screen("queue")) end },
    { tab = "items", title = "Items",
      lead = "Next: every item you craft, buy and sell.",
      text = "Leaderboards: most profit, best margin, fastest sellers, and things held too long. Search any item, or tick In my bags or Cheap materials.",
      target = function() return select(2, Screen("items")) end },
    { tab = "items", screen = "page", title = "An item's page",
      lead = "Every item has a page of its own.",
      ask = "Click the highlighted " .. ITEM_PICK .. " to open its page.",
      askAny = "Click any item on a leaderboard to open its page.",
      clickTarget = function() return select(2, Screen("items")) end,
      text = "Its break-even price, what yours cost you, what it sells for, a price chart, and everything you've done with it. Back returns to the leaderboards.",
      target = function()
          local view = Screen("items")
          return view and view.page
      end },
    { tab = "history", title = "History",
      lead = "Next: everything Goldsmith has recorded.",
      text = "Every purchase, sale, craft, crafting order, AH deposit and gathered material, recorded by itself. The choices at the top show one kind. Right-click an entry to fix it, for example to mark a craft as a crafting order.",
      target = function() return select(2, Screen("history")) end },
    { tab = "characters", title = "Characters",
      lead = "Next: all your characters at a glance.",
      text = "A card per character: professions, concentration, craft cooldowns and a to-do list. Click a to-do to open its plan. Exclude a character you don't play, so its gold, stock and recipes stay out.",
      target = function() return select(2, Screen("characters")) end },
    { title = "Settings",
      text = "Prices, when a craft is worth suggesting, item tooltips, chat messages and characters. Help and Support and feedback are in there too: questions, bug reports and ideas. Hold Ctrl over any hover to see what its numbers mean.\n\nThat's the tour. /gsm tour starts it again.",
      target = function() return Part("settings") end },
}

local TAB_NAMES = {
    overview = "Overview", crafts = "Crafts", queue = "Queue",
    items = "Items", history = "History", characters = "Characters",
}

local BOX_WIDTH = 340
local box, highlight
local current -- step number, or nil when no tour is running
local waiting -- the tab the current step waits for, if any

local function CreateFrames()
    highlight = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    highlight:SetFrameStrata("FULLSCREEN_DIALOG")
    highlight:SetBackdrop({ edgeFile = addon.theme.texture, edgeSize = 2 })
    highlight:SetBackdropBorderColor(addon:Color("gold"))
    highlight:EnableMouse(false)
    local pulse = highlight:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local fade = pulse:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0.35)
    fade:SetDuration(0.7)
    highlight.pulse = pulse

    box = CreateFrame("Frame", "GoldsmithTour", UIParent, "BackdropTemplate")
    box:SetFrameStrata("FULLSCREEN_DIALOG")
    box:SetFrameLevel(highlight:GetFrameLevel() + 5)
    box:SetWidth(BOX_WIDTH)
    box:SetClampedToScreen(true)
    box:EnableMouse(true)
    UI.Style(box, "dialog", "gold")

    box.title = UI.Text(box, "heading")
    box.title:SetPoint("TOPLEFT", 14, -12)
    box.count = UI.Text(box, "label", "dim", "RIGHT")
    box.count:SetPoint("TOPRIGHT", -36, -14)
    box.close = UI.IconButton(box, 22, "X", "End the tour (/gsm tour starts it again)", function() addon:EndTour() end,
        { font = "body", hoverColor = "loss" })
    box.close:SetPoint("TOPRIGHT", -8, -8)

    box.text = UI.Text(box, "body", "text")
    box.text:SetPoint("TOPLEFT", box.title, "BOTTOMLEFT", 0, -10)
    -- A fixed width, so the wrapped height is known at once (FitBox)
    box.text:SetWidth(BOX_WIDTH - 28)
    box.text:SetWordWrap(true)

    box.ask = UI.Text(box, "body", "gold")
    box.ask:SetPoint("TOPLEFT", box.text, "BOTTOMLEFT", 0, -10)
    box.ask:SetWidth(BOX_WIDTH - 28)
    box.ask:SetWordWrap(true)

    -- Above the buttons, on every step
    box.note = UI.Text(box, "label", "dim")
    box.note:SetPoint("BOTTOMLEFT", 14, 12 + 24 + 8)
    box.note:SetWidth(BOX_WIDTH - 28)
    box.note:SetWordWrap(true)

    box.back = UI.Button(box, "Back", 80, 24, function() addon:TourStep(current - 1) end)
    box.back:SetPoint("BOTTOMLEFT", 14, 12)
    box.next = UI.Button(box, "Next", 80, 24, function()
        if current == #STEPS then addon:EndTour() else addon:TourStep(current + 1) end
    end)
    box.next:SetPoint("BOTTOMRIGHT", -14, 12)
end

-- Height to fit the wrapped text and the buttons
local function FitBox()
    local height = 12 + box.title:GetStringHeight() + 10 + box.text:GetStringHeight()
    if box.ask:IsShown() then height = height + 10 + box.ask:GetStringHeight() end
    if box.note:IsShown() then height = height + 10 + box.note:GetStringHeight() end
    box:SetHeight(height + 12 + 24 + 12)
end

-- Below the target when it's in the top half of the screen, else above
local function PlaceBox(first)
    box:ClearAllPoints()
    local _, top = first:GetCenter()
    if top and top > UIParent:GetHeight() / 2 then
        box:SetPoint("TOPLEFT", first, "BOTTOMLEFT", 0, -12)
    else
        box:SetPoint("BOTTOMLEFT", first, "TOPLEFT", 0, 12)
    end
end

local function Show(first, last)
    highlight:ClearAllPoints()
    highlight:SetPoint("TOPLEFT", first, "TOPLEFT", -4, 4)
    highlight:SetPoint("BOTTOMRIGHT", last or first, "BOTTOMRIGHT", 4, -4)
    highlight:Show()
    highlight.pulse:Play()
    FitBox()
    PlaceBox(first)
    box:Show()
    -- Again once drawn, in case the font measured differently before
    C_Timer.After(0, function() if box:IsShown() then FitBox() end end)
end

-- Shows step n. On another tab: point at that tab and wait for the click
-- (addon.OnTourTab), unless going back, which switches tabs itself.
function addon:TourStep(n)
    if not addon.window then return end
    if not box then CreateFrames() end
    n = math.max(1, math.min(n, #STEPS))
    local goingBackward = current and n < current
    current = n
    local step = STEPS[n]
    if not addon.window:IsShown() then addon.window:Show() end

    box.count:SetText(string.format("%d / %d", n, #STEPS))
    box.note:SetText("Showing sample characters and sales. Yours come back when the tour ends.")
    box.note:SetShown(saved ~= nil)
    box.back:SetShown(n > 1)
    box.next:SetLabel(n == #STEPS and "Done" or "Next")

    StopWatching()
    local onTab = not step.tab or addon:CurrentTab() == step.tab
    waiting = not onTab and step.tab or nil
    if waiting and goingBackward then
        addon:ShowTab(step.tab) -- calls OnTourTab, which shows the step
        return
    end
    -- Waiting for a click: a short lead-in, not the explanation, which
    -- shows once they've clicked (user: not the same text twice)
    if waiting then
        box.title:SetText(step.title)
        box.text:SetText(step.lead)
        box.ask:SetText("Click the " .. TAB_NAMES[step.tab] .. " tab to carry on.")
        box.ask:Show()
        box.next:Hide()
        local tabButton = Part("tabs")[step.tab]
        Show(tabButton)
        return
    end
    if step.screen and not ScreenOpen(step.screen) then
        -- Something else open (they clicked another craft or item): back
        -- to the list, and ask again
        local open = OpenScreen(step.screen)
        if open then
            wrongPick = open
            CloseScreens(step.tab)
            C_Timer.After(0.3, function() if current == n then addon:TourStep(n) end end)
            return
        end
        local row = PickedRow(step.screen)
        if not row and (scrolled[n] or not (PICKS[step.screen] and PICKS[step.screen].scroll)) then
            noPick[step.screen] = true
        end
        -- Not in view: scroll to it once, then look again
        if not row and PICKS[step.screen] and PICKS[step.screen].scroll and not scrolled[n] then
            scrolled[n] = true
            PICKS[step.screen].scroll()
            addon.RefreshWindow()
            C_Timer.After(0.3, function() if current == n then addon:TourStep(n) end end)
            return
        end
        box.title:SetText(step.title)
        box.text:SetText(wrongPick and string.format("That's %s. The tour shows a good example, so this one first; you can look at any of them after.", wrongPick)
            or step.lead)
        wrongPick = nil
        box.ask:SetText(row and step.ask or step.askAny or step.ask)
        box.ask:Show()
        box.next:Hide()
        Show(row or step.clickTarget())
        -- Carries on once that screen is open and laid out
        watcher = C_Timer.NewTicker(0.2, function()
            if current == n and OpenScreen(step.screen) then
                StopWatching()
                C_Timer.After(0.2, function() if current == n then addon:TourStep(n) end end)
            end
        end)
        return
    end
    -- Steps on a tab's main screen (after going back from a plan or an
    -- item's page): back to it first
    if not step.screen and CloseScreens(step.tab) then
        C_Timer.After(0.2, function() if current == n then addon:TourStep(n) end end)
        return
    end

    box.title:SetText(step.title)
    box.text:SetText(step.text)
    box.ask:Hide()
    box.next:Show()
    -- The tab's screen may only just have been made; point once it's laid out
    local first, last = step.target()
    if first then
        Show(first, last)
    else
        Show(addon.window)
    end
end

-- The window's tab changed (Window.lua Refresh): a step waiting for that
-- tab carries on
function addon.OnTourTab(key)
    if not current then return end
    if waiting and waiting == key then
        waiting = nil
        local step = current
        C_Timer.After(0, function()
            if current == step then addon:TourStep(current) end
        end)
    end
end

function addon:StartTour()
    GoldsmithDB.tourOffered = true
    current = nil
    scrolled, noPick, pickTier, wrongPick = {}, {}, nil, nil
    if addon.window and not addon.window:IsShown() then addon.window:Show() end
    UseSampleData(function()
        addon:ShowTab("overview")
        C_Timer.After(0, function() addon:TourStep(1) end)
    end)
end

function addon:EndTour()
    current, waiting = nil, nil
    StopWatching()
    UseOwnData()
    if box then box:Hide() end
    if highlight then
        highlight.pulse:Stop()
        highlight:Hide()
    end
end

function addon:TourRunning()
    return current ~= nil
end

StaticPopupDialogs["GOLDSMITH_TOUR"] = {
    text = "Welcome to Goldsmith!\n\nTake a 2-minute tour of the window?",
    button1 = "Take the tour",
    button2 = "Not now",
    OnAccept = function() addon:StartTour() end,
    OnCancel = function()
        print("|cFF00FF00[Goldsmith]|r No problem. Start the tour any time with /gsm tour, or from Getting started on the Overview.")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- The first time the window opens: ask once
function addon:OfferTour()
    if GoldsmithDB.tourOffered or current then return end
    GoldsmithDB.tourOffered = true
    StaticPopup_Show("GOLDSMITH_TOUR")
end

_G.Goldsmith = addon
