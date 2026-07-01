-- holdem.lua — pure poker maths. No I/O, no peripherals, no rednet: every
-- function here is deterministic and unit-testable under standalone Lua (see
-- tests/test_holdem.lua). This is the algorithmic heart of the game.
--
-- Card model matches the rest of the casino: { rank=string, suit="S/H/D/C",
-- value=number }. Poker values run 2..14 (Ace high = 14; the wheel A-2-3-4-5 is
-- handled specially in straight detection).

local M = {}

M.RANKS = {
    { r = "2", v = 2 }, { r = "3", v = 3 }, { r = "4", v = 4 }, { r = "5", v = 5 },
    { r = "6", v = 6 }, { r = "7", v = 7 }, { r = "8", v = 8 }, { r = "9", v = 9 },
    { r = "10", v = 10 }, { r = "J", v = 11 }, { r = "Q", v = 12 }, { r = "K", v = 13 }, { r = "A", v = 14 },
}
M.SUITS = { "S", "H", "D", "C" }

-- Fresh shuffled 52-card deck (Fisher–Yates), mirroring blackjack/blackjack.lua.
function M.newDeck()
    local d = {}
    for _, s in ipairs(M.SUITS) do
        for _, rk in ipairs(M.RANKS) do
            d[#d + 1] = { rank = rk.r, suit = s, value = rk.v }
        end
    end
    for i = #d, 2, -1 do
        local j = math.random(i)
        d[i], d[j] = d[j], d[i]
    end
    return d
end

function M.draw(deck) return table.remove(deck) end

-- ─── Hand evaluation ─────────────────────────────────────────────────────────
-- evaluate7 returns a "rank tuple": { category, tiebreak1, tiebreak2, ... }.
-- Higher is better, compared lexicographically by M.compare. Categories:
--   9 straight flush  8 four of a kind  7 full house  6 flush
--   5 straight        4 three of a kind 3 two pair     2 one pair  1 high card

-- Highest card of the best 5-in-a-row in `valueSet` (a set of present values),
-- or nil. Aces double as 1 for the wheel.
local function straightHigh(valueSet)
    local present = {}
    for v in pairs(valueSet) do present[v] = true end
    if present[14] then present[1] = true end
    for high = 14, 5, -1 do
        local ok = true
        for k = 0, 4 do
            if not present[high - k] then ok = false break end
        end
        if ok then return high end
    end
    return nil
end

function M.evaluate7(cards)
    -- suit buckets (for flush / straight flush)
    local bySuit = {}
    for _, c in ipairs(cards) do
        bySuit[c.suit] = bySuit[c.suit] or {}
        local b = bySuit[c.suit]
        b[#b + 1] = c.value
    end
    local flushVals
    for _, vals in pairs(bySuit) do
        if #vals >= 5 then flushVals = vals end
    end

    -- straight flush
    if flushVals then
        local set = {}
        for _, v in ipairs(flushVals) do set[v] = true end
        local sf = straightHigh(set)
        if sf then return { 9, sf } end
    end

    -- rank-count groups, sorted by (count desc, value desc)
    local cnt = {}
    for _, c in ipairs(cards) do cnt[c.value] = (cnt[c.value] or 0) + 1 end
    local groups = {}
    for v, c in pairs(cnt) do groups[#groups + 1] = { v = v, c = c } end
    table.sort(groups, function(a, b)
        if a.c ~= b.c then return a.c > b.c end
        return a.v > b.v
    end)

    local function kickers(exclude, n)
        local k = {}
        for _, g in ipairs(groups) do
            if not exclude[g.v] then
                for _ = 1, g.c do k[#k + 1] = g.v end
            end
        end
        table.sort(k, function(a, b) return a > b end)
        local out = {}
        for i = 1, n do out[i] = k[i] end
        return out
    end

    -- four of a kind
    if groups[1].c == 4 then
        local kk = kickers({ [groups[1].v] = true }, 1)
        return { 8, groups[1].v, kk[1] }
    end
    -- full house (trip + pair, or two trips)
    if groups[1].c == 3 then
        for i = 2, #groups do
            if groups[i].c >= 2 then return { 7, groups[1].v, groups[i].v } end
        end
    end
    -- flush
    if flushVals then
        table.sort(flushVals, function(a, b) return a > b end)
        return { 6, flushVals[1], flushVals[2], flushVals[3], flushVals[4], flushVals[5] }
    end
    -- straight
    do
        local set = {}
        for _, c in ipairs(cards) do set[c.value] = true end
        local s = straightHigh(set)
        if s then return { 5, s } end
    end
    -- three of a kind
    if groups[1].c == 3 then
        local kk = kickers({ [groups[1].v] = true }, 2)
        return { 4, groups[1].v, kk[1], kk[2] }
    end
    -- two pair
    if groups[1].c == 2 and groups[2] and groups[2].c == 2 then
        local kk = kickers({ [groups[1].v] = true, [groups[2].v] = true }, 1)
        return { 3, groups[1].v, groups[2].v, kk[1] }
    end
    -- one pair
    if groups[1].c == 2 then
        local kk = kickers({ [groups[1].v] = true }, 3)
        return { 2, groups[1].v, kk[1], kk[2], kk[3] }
    end
    -- high card
    local kk = kickers({}, 5)
    return { 1, kk[1], kk[2], kk[3], kk[4], kk[5] }
end

-- Compare two rank tuples: -1 if a<b, 0 if equal, 1 if a>b.
function M.compare(a, b)
    local n = math.max(#a, #b)
    for i = 1, n do
        local x, y = a[i] or 0, b[i] or 0
        if x ~= y then return x < y and -1 or 1 end
    end
    return 0
end

-- ─── Pots ────────────────────────────────────────────────────────────────────
-- buildPots turns per-seat total contributions into layered main/side pots.
-- `contrib` is { seat = totalChipsCommittedThisHand }; `folded` is { seat=true }.
-- Folded players' chips stay in the pots (dead money) but they win nothing.
function M.buildPots(contrib, folded)
    folded = folded or {}
    local seats, rem = {}, {}
    for s, amt in pairs(contrib) do
        if amt > 0 then seats[#seats + 1] = s; rem[s] = amt end
    end
    table.sort(seats)

    local pots = {}
    while true do
        local minAmt
        for _, s in ipairs(seats) do
            if rem[s] > 0 and (not minAmt or rem[s] < minAmt) then minAmt = rem[s] end
        end
        if not minAmt then break end

        local amount, eligible = 0, {}
        for _, s in ipairs(seats) do
            if rem[s] > 0 then
                amount = amount + minAmt
                rem[s] = rem[s] - minAmt
                if not folded[s] then eligible[#eligible + 1] = s end
            end
        end
        pots[#pots + 1] = { amount = amount, eligible = eligible }
    end
    return pots
end

-- ─── Rake ────────────────────────────────────────────────────────────────────
-- Standard card-room pot rake: a percentage of the total pot, capped, with
-- "no flop no drop" — hands that end pre-flop are rake-free.

function M.computeRake(totalPot, pct, cap, flopSeen)
    if not flopSeen then return 0 end
    return math.min(cap, math.floor(totalPot * pct))
end

-- Deduct `rake` from the pot layers, walking them in order until consumed.
-- Sequential (not main-pot-only) because in all-in hands the main pot layer can
-- be smaller than the rake itself (contribs 1/100/100 -> main pot 3, side 198).
-- Mutates `pots`; returns the amount actually taken.
function M.takeRake(pots, rake)
    local left = rake
    for _, pot in ipairs(pots) do
        if left <= 0 then break end
        local take = math.min(pot.amount, left)
        pot.amount = pot.amount - take
        left = left - take
    end
    return rake - left
end

-- awardPots assigns each pot to the best hand(s) among its eligible seats.
-- `handBySeat` maps seat -> rank tuple (only for seats still in at showdown).
-- Returns { seat = chipsWon }. Split pots share evenly; odd chips go to the
-- lowest seat index first (deterministic, conserves every chip).
function M.awardPots(pots, handBySeat)
    local win = {}
    for _, pot in ipairs(pots) do
        local best, winners = nil, {}
        for _, s in ipairs(pot.eligible) do
            local h = handBySeat[s]
            if h then
                if not best then
                    best, winners = h, { s }
                else
                    local c = M.compare(h, best)
                    if c > 0 then best, winners = h, { s }
                    elseif c == 0 then winners[#winners + 1] = s end
                end
            end
        end
        if #winners > 0 then
            table.sort(winners)
            local share = math.floor(pot.amount / #winners)
            local odd = pot.amount - share * #winners
            for i, s in ipairs(winners) do
                win[s] = (win[s] or 0) + share + (i <= odd and 1 or 0)
            end
        end
    end
    return win
end

return M
