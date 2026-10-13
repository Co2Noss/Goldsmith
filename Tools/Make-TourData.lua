-- Makes the tour's sample data (TourData.lua) from real saved data.
--
--   lua Make-TourData.lua <real Goldsmith.lua> <output TourData.lua>
--
-- A new player's window is mostly empty, so the tour shows sample data
-- instead (Tour.lua swaps it in while the tour runs). It's hand-picked
-- from a real account (user, 2026-10-13): one clear example of each part
-- of the window, all looking good, so a new player isn't swamped.
--   - FOLLOWED: the "followed" hover's three examples (on target, fell
--     short, expected a loss but made a little), with the tweaks to make
--     each one show that
--   - characters: the ones who crafted those, renamed; the one with the
--     most becomes "@me" (the player taking the tour), the realm "@realm"
--     (theirs), filled in when the tour starts
--   - recipes: those three, the recipes making their materials, and each
--     character's EXTRA_PER_CHARACTER best sellers (current expansion)
--   - history: profitable sales of those items and their materials, the
--     purchases and deposits for them, crafts, one crafting order, a
--     couple of days of gathering and one box opened: every kind History
--     shows at least once
--   - a queue on both characters, one recipe not learned yet, a gold goal
--     part way there
--   - no customer names, posts, AH searches, debug tables or errors
-- Times stay as they were; Tour.lua moves them so the newest is now.
-- Run with Lua 5.1 (WoW's version). The input file is only read.

local input, output = arg[1], arg[2]

-- The choices
local DAYS = 30
local FOLLOWED = {
    -- On target: sold for about what was expected
    ["Sterling Alloy"] = {},
    -- Fell short: the price dropped after its first batch (expected price
    -- raised 25% so its sales made under 80% of it; profitable sales only)
    ["Refulgent Razorstone"] = { priceScale = 1.25, maxLots = 1 },
    -- Expected a small loss, made a little; its second batch not sold yet
    ["Thalassian Missive of the Harmonious"] = { maxLots = 2 },
}
-- Recipes Goldsmith suggests (Do this next, to-dos) on the real data;
-- whoever knows one comes too if no character above does
local SHOWCASE = { "Null and Void Plate", "Argentleaf Tea", "Vicious Thalassian Flask of Honor",
    -- The plan the tour opens (vendor, AH and crafted materials) and the
    -- item page it opens
    "Gloaming Alloy", "Sterling Alloy" }
local EXTRA_PER_CHARACTER = 4  -- best-selling recipes per character
-- Sales' margins (profit on cost) made believable (user, 2026-10-13: the
-- real ones ran 100-250%, e.g. gathered materials sold at no cost): each
-- sale above MARGIN[2] gets a cost making it somewhere in this range.
-- Followed items keep their real numbers (their hover adds them up).
local MARGIN = { 0.2, 0.45 }
local PURCHASES_PER_MATERIAL = 2 -- the latest ones
local LOTS_PER_ITEM = 2        -- latest crafts kept of items not followed
local GATHERED_DAYS = 2        -- days of gathering kept
local OPENED_BOX = 245650      -- the box opened (one that came out ahead)
-- Total gold (all characters and the warband bank, copper): GOLD.total
-- now, GOLD.rise less DAYS ago, a little up and down day to day
local GOLD = { total = 120000 * 10000, rise = 22000 * 10000, warband = 0.15 }
local GOAL = { make = 10000 * 10000, daysAgo = 9 } -- set then, about 60% there now
-- Queued: each on the first character who knows it (profitable crafts)
local QUEUED = {
    { "Sterling Alloy" }, { "Gloaming Alloy" },
    { "Thalassian Missive of the Fireflash", concentrate = true },
}
-- The plan the tour opens (Tour.lua's CRAFT_PICK): nobody holds its
-- materials but IN_STOCK, so the plan shows each way to get one (real
-- stock made Luminant Flux "From stock" instead of vendor; user, 2026-10-13)
local PLAN = "Gloaming Alloy"
-- In "@me"'s bags (itemID -> count): a few silver Umbral Tin Ore, so the
-- plan has a material from stock and the rest of it bought
local IN_STOCK = { [237362] = 2 }
-- A character the player doesn't play, excluded in the sample's settings
-- (Characters tab: "Exclude a character you don't play"): made from one the real account excludes
local EXCLUDED_ALT = { name = "Dustyboots", gold = 1800 * 10000 }
local NAMES = { "Unholysaint", "Alexithymia", "Silkveil" }
local EXPANSION = "Midnight"   -- skill lines start with it ("Midnight Inscription")

if not input or not output then
    print("Usage: lua Make-TourData.lua <real Goldsmith.lua> <output TourData.lua>")
    os.exit(1)
end
dofile(input)
local real = GoldsmithDB
assert(type(real) == "table", "No GoldsmithDB in " .. input)
assert(not real.stressTest, "That file is fake data")

local function Copy(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = Copy(v) end
    return c
end
local function Count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

-- Newest thing recorded: the sample's "now"
local made = 0
for _, e in ipairs(real.entries or {}) do made = math.max(made, e.timestamp or 0) end
for _, e in ipairs(real.craftLog or {}) do made = math.max(made, e.time or 0) end
local from = made - DAYS * 86400
local fromDay = os.date("%Y-%m-%d", from)

-- Recipes of this expansion, by what they make
local recipes, byOutput = {}, {}
for id, r in pairs(real.recipes or {}) do
    if (r.skillLine or ""):find("^" .. EXPANSION) then
        recipes[id] = r
        if r.outputName then byOutput[r.outputName] = byOutput[r.outputName] or id end
    end
end

-- Characters: whoever crafted the followed items, most of them first
local crafted = {}
for _, lots in pairs(real.craftLots or {}) do
    for _, lot in ipairs(lots) do
        if FOLLOWED[lot.name] and lot.suggested and lot.char then
            crafted[lot.char] = crafted[lot.char] or {}
            crafted[lot.char][lot.name] = true
        end
    end
end
local chars = {}
for key, names in pairs(crafted) do
    local c = assert(real.characters[key], "No character " .. key)
    table.insert(chars, { key = key, c = c, n = Count(names) })
end
table.sort(chars, function(a, b) return a.n > b.n end)
assert(#chars > 0, "No followed crafts of the FOLLOWED items")
for _, name in ipairs(SHOWCASE) do
    local id = assert(byOutput[name], "No " .. EXPANSION .. " recipe makes " .. name)
    local known = false
    for _, ch in ipairs(chars) do
        if ch.c.knownRecipes and ch.c.knownRecipes[id] then known = true end
    end
    if not known then
        local keys = {}
        for key, c in pairs(real.characters) do
            if c.knownRecipes and c.knownRecipes[id] then keys[#keys + 1] = key end
        end
        table.sort(keys)
        assert(keys[1], "Nobody knows " .. name)
        table.insert(chars, { key = keys[1], c = real.characters[keys[1]], n = 0 })
    end
end
local rename = {} -- old name or key -> new
for i, ch in ipairs(chars) do
    local name = i == 1 and "@me" or assert(NAMES[i - 1], "More characters than NAMES")
    rename[ch.c.name] = name
    rename[ch.key] = name .. "-@realm"
end
local function Knows(id)
    for _, ch in ipairs(chars) do
        if ch.c.knownRecipes and ch.c.knownRecipes[id] then return true end
    end
    return false
end

-- Profit of a sale (nil when its cost wasn't saved)
local function SaleProfit(e)
    return e.costBasis and (e.totalCopper or 0) - e.costBasis or nil
end
-- A sale worth showing: one that made money
local function GoodSale(e)
    return (SaleProfit(e) or -1) >= 0
end

-- Its cost raised so its margin is in MARGIN (spread by its ID, so the
-- same each run)
local function BelievableCost(e)
    if FOLLOWED[e.item] then return end
    local total = e.totalCopper or 0
    if total <= 0 or (e.costBasis or 0) * (1 + MARGIN[2]) >= total then return end
    local margin = MARGIN[1] + (MARGIN[2] - MARGIN[1]) * ((e.id * 37) % 100) / 100
    e.costBasis = math.floor(total / (1 + margin) + 0.5)
    e.costSource = e.costSource == "free" and "paid" or e.costSource
end

-- Recipes: the followed ones, each character's best sellers, then the
-- recipes making their materials
local wanted = {}
for name in pairs(FOLLOWED) do
    local id = assert(byOutput[name], "No " .. EXPANSION .. " recipe makes " .. name)
    wanted[id] = true
end
for _, name in ipairs(SHOWCASE) do wanted[assert(byOutput[name], "No recipe makes " .. name)] = true end
for id, r in pairs(recipes) do
    if r.outputItemID == OPENED_BOX then wanted[id] = true end
end
for _, ch in ipairs(chars) do
    local profit = {}
    for _, e in ipairs(real.entries or {}) do
        local id = e.type == "REVENUE" and (e.timestamp or 0) >= from and byOutput[e.item or ""]
        if id and ch.c.knownRecipes and ch.c.knownRecipes[id] and (SaleProfit(e) or 0) > 0 then
            profit[id] = (profit[id] or 0) + SaleProfit(e)
        end
    end
    local list = {}
    for id, p in pairs(profit) do if not wanted[id] then list[#list + 1] = { id = id, p = p } end end
    table.sort(list, function(a, b) return a.p > b.p end)
    for i = 1, math.min(EXTRA_PER_CHARACTER, #list) do wanted[list[i].id] = true end
end
local changed = true
while changed do
    changed = false
    for id in pairs(wanted) do
        for _, slot in ipairs(recipes[id] and recipes[id].reagents or {}) do
            for _, n in ipairs(slot.names or {}) do
                local sub = byOutput[n]
                if sub and not wanted[sub] and Knows(sub) then wanted[sub], changed = true, true end
            end
        end
    end
end

-- Items used (ID and name), filled as things are kept
local itemIDs, itemNames = {}, {}
local function UseItem(id, name)
    if id then itemIDs[id] = true end
    if name then itemNames[name] = true end
end

local db = {
    made = made, sample = true, setupDone = true, setupShown = true,
    estimatedSalesRepaired = true, harmoniousLotsRepaired = true, logoutGoldRepaired = true,
    characters = {}, recipes = {}, unlearned = {}, entries = {}, craftLog = {}, craftLots = {},
    orderCrafts = {}, gathered = {}, gatheredLog = {}, suggested = {}, ignored = {}, queues = {},
    craftStats = {}, scrollOutputs = {}, milling = {}, products = {}, reagents = {},
    itemFacts = {}, priceHistory = {}, priceSeen = {}, vendorPrices = {},
    warbandGold = Copy(real.warbandGold), warbandStock = Copy(real.warbandStock),
    concentrationCurrency = Copy(real.concentrationCurrency),
    nonCrafting = Copy(real.nonCrafting), freeItems = Copy(real.freeItems),
}

-- What the kept recipes make and use
local outputs, materials, materialIDs = {}, {}, {}
for id in pairs(wanted) do
    local r = recipes[id]
    db.recipes[id] = Copy(r)
    outputs[r.outputName] = true
    UseItem(r.outputItemID, r.outputName)
    for _, slot in ipairs(r.reagents or {}) do
        for _, rid in ipairs(slot.itemIDs or {}) do UseItem(rid); materialIDs[rid] = true end
        for _, n in ipairs(slot.names or {}) do UseItem(nil, n); materials[n] = true end
    end
    if real.craftStats and real.craftStats[id] then db.craftStats[id] = Copy(real.craftStats[id]) end
    if real.scrollOutputs and real.scrollOutputs[id] then db.scrollOutputs[id] = Copy(real.scrollOutputs[id]) end
end
local function Kept(name) return name and (outputs[name] or materials[name]) end

-- One recipe not learned yet that a kept character could learn
for id, r in pairs(real.unlearned or {}) do
    if not next(db.unlearned) and (r.skillLine or ""):find("^" .. EXPANSION) then
        local learners = {}
        for key in pairs(r.learners or {}) do if rename[key] then learners[rename[key]] = true end end
        if next(learners) then
            local u = Copy(r)
            u.learners = learners
            db.unlearned[id] = u
            UseItem(r.outputItemID, r.outputName)
            for _, slot in ipairs(r.reagents or {}) do
                for _, rid in ipairs(slot.itemIDs or {}) do UseItem(rid) end
            end
        end
    end
end

-- Characters, cut to the kept recipes
for _, ch in ipairs(chars) do
    local c = Copy(ch.c)
    c.name, c.realm = rename[ch.c.name], "@realm"
    for _, field in ipairs({ "knownRecipes", "recipeStats", "tierData" }) do
        local kept = {}
        for id, v in pairs(c[field] or {}) do if db.recipes[id] then kept[id] = v end end
        c[field] = kept
    end
    for _, field in ipairs({ "stock", "stockBank", "auctions" }) do
        for id in pairs(c[field] or {}) do UseItem(id) end
    end
    db.characters[rename[ch.key]] = c
end
do
    local materials, seen = {}, {}
    local function Walk(recipeID)
        local r = db.recipes[recipeID]
        if not r or seen[recipeID] then return end
        seen[recipeID] = true
        for _, slot in ipairs(r.reagents or {}) do
            for i, id in ipairs(slot.itemIDs or {}) do
                materials[id] = true
                if byOutput[slot.names[i]] then Walk(byOutput[slot.names[i]]) end
            end
        end
    end
    Walk(assert(byOutput[PLAN], "No recipe makes " .. PLAN))
    for _, c in pairs(db.characters) do
        for _, field in ipairs({ "stock", "stockBank" }) do
            for id in pairs(materials) do if c[field] then c[field][id] = nil end end
        end
    end
    for id in pairs(materials) do if db.warbandStock then db.warbandStock[id] = nil end end
end
for id, count in pairs(IN_STOCK) do
    local me = db.characters["@me-@realm"]
    me.stock = me.stock or {}
    me.stock[id] = count
    UseItem(id)
end
do
    local keys = {}
    for key in pairs(real.settings and real.settings.excluded or {}) do
        if real.characters[key] then keys[#keys + 1] = key end
    end
    table.sort(keys)
    assert(keys[1], "No excluded character to make the bank alt from")
    local c = Copy(real.characters[keys[1]])
    c.name, c.realm = EXCLUDED_ALT.name, "@realm"
    c.professions, c.knownRecipes, c.recipeStats, c.tierData = {}, {}, {}, {}
    c.concentration, c.cooldowns, c.calibration, c.craftBuffs = {}, {}, {}, {}
    c.stock, c.stockBank, c.auctions = {}, {}, {}
    local key = EXCLUDED_ALT.name .. "-@realm"
    db.characters[key] = c
    db.excluded = { [key] = true }
end

-- Transactions: profitable sales of the kept items (margins made
-- believable), the latest purchases
-- of their materials, one deposit for each item sold
local sold, bought, posted = {}, {}, {}
local function AddEntry(e)
    local c = Copy(e)
    c.character, c.realm = rename[e.character], c.realm and "@realm" or nil
    c.id = #db.entries + 1
    table.insert(db.entries, c)
    UseItem(c.itemID, c.item)
end
for _, e in ipairs(real.entries or {}) do
    if (e.timestamp or 0) >= from and rename[e.character] and Kept(e.item) and e.type == "REVENUE"
        and GoodSale(e) then
        AddEntry(e)
        BelievableCost(db.entries[#db.entries])
        sold[e.item] = true
    end
end
for i = #(real.entries or {}), 1, -1 do
    local e = real.entries[i]
    if (e.timestamp or 0) >= from and rename[e.character] and e.type ~= "REVENUE" then
        if e.kind == "DEPOSIT" then
            if sold[e.item] and not posted[e.item] then
                posted[e.item] = true
                AddEntry(e)
            end
        elseif materials[e.item] and (bought[e.item] or 0) < PURCHASES_PER_MATERIAL then
            bought[e.item] = (bought[e.item] or 0) + 1
            AddEntry(e)
        end
    end
end
table.sort(db.entries, function(a, b) return a.timestamp < b.timestamp end)
for i, e in ipairs(db.entries) do e.id = i end
db.nextId = #db.entries + 1

-- Crafts of the kept recipes; the followed ones as FOLLOWED says
for _, e in ipairs(real.craftLog or {}) do
    if (e.time or 0) >= from and db.recipes[e.recipeID] then table.insert(db.craftLog, Copy(e)) end
end
-- Followed lots kept per item (all tiers), oldest first
local followedLots, firstLots = {}, {}
for _, lots in pairs(real.craftLots or {}) do
    for _, lot in ipairs(lots) do
        if lot.suggested and FOLLOWED[lot.name] and (lot.time or 0) >= from then
            table.insert(firstLots, lot)
        end
    end
end
table.sort(firstLots, function(a, b) return a.time < b.time end)
local followedLot = {}
for _, lot in ipairs(firstLots) do
    local n = followedLots[lot.name] or 0
    if n < (FOLLOWED[lot.name].maxLots or math.huge) then
        followedLots[lot.name] = n + 1
        followedLot[lot] = true
    end
end
for id, lots in pairs(real.craftLots or {}) do
    local kept = {}
    for _, lot in ipairs(lots) do
        if (lot.time or 0) >= from and outputs[lot.name] and (not lot.char or rename[lot.char]) then
            local l = Copy(lot)
            if l.char then l.char = rename[l.char] end
            local f = FOLLOWED[l.name]
            if followedLot[lot] then
                -- Lots before 2026-10-11 didn't keep the price expected:
                -- that day's price, or the latest before it
                if not l.expectedPrice then
                    local day, best = os.date("%Y-%m-%d", l.time), nil
                    for d in pairs(real.priceHistory and real.priceHistory[id] or {}) do
                        if d <= day and (not best or d > best) then best = d end
                    end
                    l.expectedPrice = best and real.priceHistory[id][best] or nil
                end
                if l.expectedPrice and f.priceScale then
                    l.expectedPrice = math.floor(l.expectedPrice * f.priceScale + 0.5)
                end
            else
                l.suggested, l.expectedPrice = nil, nil
            end
            table.insert(kept, l)
        end
    end
    -- Not followed: only the latest few
    local trimmed, others = {}, 0
    for i = #kept, 1, -1 do
        if kept[i].suggested or others < LOTS_PER_ITEM then
            if not kept[i].suggested then others = others + 1 end
            table.insert(trimmed, 1, kept[i])
        end
    end
    kept = trimmed
    if #kept > 0 then
        db.craftLots[id] = kept
        UseItem(id, kept[1].name)
    end
end
for name in pairs(FOLLOWED) do
    if real.suggested and real.suggested[name] then db.suggested[name] = Copy(real.suggested[name]) end
end

-- One crafting order: the latest by a kept character
for i = #(real.orderCrafts or {}), 1, -1 do
    local o = real.orderCrafts[i]
    if not db.orderCrafts[1] and rename[o.char] then
        local c = Copy(o)
        c.char = rename[o.char]
        c.customer, c.customerName, c.crafter = nil, nil, nil
        db.orderCrafts[1] = c
        UseItem(c.itemID, c.name)
    end
end

-- Gathering: the last GATHERED_DAYS days of it and one box opened, all
-- "@me"'s (whoever really did it)
local days = {}
for _, g in ipairs(real.gathered or {}) do
    if not g.box and g.day then days[g.day] = true end
end
local recent = {}
for day in pairs(days) do recent[#recent + 1] = day end
table.sort(recent, function(a, b) return a > b end)
local keepDays = {}
for i = 1, math.min(GATHERED_DAYS, #recent) do keepDays[recent[i]] = true end
for _, g in ipairs(real.gathered or {}) do
    if (g.box == nil and keepDays[g.day]) or g.box == OPENED_BOX then
        local c = Copy(g)
        c.character, c.realm = "@me", "@realm"
        table.insert(db.gathered, c)
        UseItem(c.itemID, c.name)
    end
end
if real.boxContents and real.boxContents[OPENED_BOX] then
    db.boxContents = { [OPENED_BOX] = Copy(real.boxContents[OPENED_BOX]) }
    UseItem(OPENED_BOX)
end

-- Milling, for the herbs the kept recipes' pigments come from
for id, m in pairs(real.milling or {}) do
    local feeds = false
    for out in pairs(m.outputs or {}) do
        if materialIDs[out] then feeds = true end
    end
    if feeds then
        db.milling[id] = Copy(m)
        UseItem(id, m.name)
        for out in pairs(m.outputs or {}) do UseItem(out) end
    end
end

-- Queues: QUEUED, each on the first character who knows it
for _, q in ipairs(QUEUED) do
    local id = assert(byOutput[q[1]], "No recipe makes " .. q[1])
    assert(db.recipes[id], q[1] .. " isn't in the sample's recipes")
    local key
    for _, ch in ipairs(chars) do
        if not key and ch.c.knownRecipes and ch.c.knownRecipes[id] then key = rename[ch.key] end
    end
    assert(key, "Nobody in the sample knows " .. q[1])
    db.queues[key] = db.queues[key] or {}
    table.insert(db.queues[key], { recipeID = id, quantity = 5, made = 0, concentrate = q.concentrate == true, added = made })
end

-- Gold: a total climbing to GOLD.total, split between the warband bank
-- and the crafters (in proportion to their real gold); the excluded alt holds
-- the same all month. The goal started GOAL.daysAgo days ago.
do
    local crafters, sum = {}, 0
    for _, ch in ipairs(chars) do
        local key = rename[ch.key]
        crafters[#crafters + 1] = { c = db.characters[key], share = math.max(ch.c.money or 0, 1) }
        sum = sum + math.max(ch.c.money or 0, 1)
        db.characters[key].gold = {}
    end
    local function TotalOn(i) -- i days before made
        local wiggle = math.sin(i * 1.7) * 0.012 * GOLD.total
        return math.floor(GOLD.total - GOLD.rise * i / (DAYS - 1) + (i > 0 and wiggle or 0))
    end
    db.warbandGold = {}
    for i = DAYS - 1, 0, -1 do
        local day = os.date("%Y-%m-%d", made - i * 86400)
        local total = TotalOn(i)
        local warband = math.floor(total * GOLD.warband)
        db.warbandGold[day] = warband
        for _, cr in ipairs(crafters) do
            cr.c.gold[day] = math.floor((total - warband) * cr.share / sum)
            cr.c.money = cr.c.gold[day]
        end
    end
    local alt = db.characters[EXCLUDED_ALT.name .. "-@realm"]
    alt.gold, alt.money = { [os.date("%Y-%m-%d", made - (DAYS - 1) * 86400)] = EXCLUDED_ALT.gold }, EXCLUDED_ALT.gold
    db.goldGoal = { make = GOAL.make, set = made - GOAL.daysAgo * 86400, start = TotalOn(GOAL.daysAgo) }
    print(string.format("Gold: %dg now, goal %dg at %d%%", GOLD.total / 10000, GOAL.make / 10000,
        (GOLD.total - TotalOn(GOAL.daysAgo)) * 100 / GOAL.make))
end

-- Item lookups, only for the items used
for name, prof in pairs(real.products or {}) do if itemNames[name] then db.products[name] = prof end end
for name, prof in pairs(real.reagents or {}) do if itemNames[name] then db.reagents[name] = prof end end
for id in pairs(itemIDs) do
    if real.itemFacts and real.itemFacts[id] then db.itemFacts[id] = Copy(real.itemFacts[id]) end
    if real.priceSeen and real.priceSeen[id] then db.priceSeen[id] = Copy(real.priceSeen[id]) end
    if real.vendorPrices and real.vendorPrices[id] then db.vendorPrices[id] = real.vendorPrices[id] end
    if real.priceHistory and real.priceHistory[id] then
        local d = {}
        for day, price in pairs(real.priceHistory[id]) do
            if day >= fromDay then d[day] = price end
        end
        if next(d) then db.priceHistory[id] = d end
    end
end

-- Every kind of History entry at least once
local kinds = { Sale = 0, Purchase = 0, Deposit = 0, Craft = Count(db.craftLots), Order = #db.orderCrafts,
    Gathered = 0, Opened = 0 }
for _, e in ipairs(db.entries) do
    local kind = e.type == "REVENUE" and "Sale" or (e.kind == "DEPOSIT" and "Deposit" or "Purchase")
    kinds[kind] = kinds[kind] + 1
end
for _, g in ipairs(db.gathered) do
    local kind = g.box and "Opened" or "Gathered"
    kinds[kind] = kinds[kind] + 1
end
local summary = {}
for kind, n in pairs(kinds) do
    assert(n > 0, "No " .. kind .. " entries for History")
    summary[#summary + 1] = kind .. " " .. n
end
table.sort(summary)

-- Write it as a function, so the table is only built when the tour asks
-- (a new one each time: the tour changes it as it goes)
local file = assert(io.open(output, "w"))
local function Key(k)
    if type(k) == "string" then
        if k:match("^[%a_][%w_]*$") then return k end
        return string.format("[%q]", k)
    end
    return "[" .. tostring(k) .. "]"
end
local function Value(v)
    if type(v) == "string" then return (string.format("%q", v):gsub("\\\n", "\\n")) end
    if type(v) == "number" then
        if v == math.floor(v) and math.abs(v) < 2^53 then return string.format("%.0f", v) end
        return string.format("%.6g", v)
    end
    return tostring(v)
end
local function Write(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        if type(a) == type(b) then return a < b end
        return type(a) == "number"
    end)
    file:write("{")
    for _, k in ipairs(keys) do
        local v = t[k]
        if type(v) == "table" then
            file:write(Key(k), "=")
            Write(v)
            file:write(",")
        elseif type(v) ~= "function" then
            file:write(Key(k), "=", Value(v), ",")
        end
    end
    file:write("}\n")
end
file:write("-- Generated by Tools\\Make-TourData.lua: sample data for the tour. Do not edit.\n")
file:write("local addon = _G.Goldsmith or {}\n\n")
file:write("function addon:TourDataTable()\nreturn ")
Write(db)
file:write("end\n\n_G.Goldsmith = addon\n")
file:close()

print(string.format("Wrote %s: %d characters, %d recipes (+%d not learned), %d items, made %s.",
    output, Count(db.characters), Count(db.recipes), Count(db.unlearned), Count(db.itemFacts),
    os.date("%Y-%m-%d %H:%M", made)))
print("History: " .. table.concat(summary, ", "))
