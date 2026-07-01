-- Hold'em maths self-test. Run on the table computer (or CraftOS-PC): test_holdem
-- Verifies the 7-card evaluator, hand comparison, and side-pot construction.

local h = require("lib.holdem")

local pass, fail = 0, 0
local function ok(name, cond)
    if cond then pass = pass + 1; print("ok   " .. name)
    else fail = fail + 1; print("FAIL " .. name) end
end

-- Build a card from "As", "Td", "9c" etc.  ("T" = ten).
local VAL = { ["2"]=2,["3"]=3,["4"]=4,["5"]=5,["6"]=6,["7"]=7,["8"]=8,["9"]=9,
              ["T"]=10,["J"]=11,["Q"]=12,["K"]=13,["A"]=14 }
local function c(s)
    local r, su = s:sub(1, 1), s:sub(2, 2):upper()
    return { rank = (r == "T" and "10" or r), suit = su, value = VAL[r] }
end
local function hand(...)
    local t = {}
    for _, s in ipairs({ ... }) do t[#t + 1] = c(s) end
    return t
end

-- ── Category detection ────────────────────────────────────────────────────────
local royal = h.evaluate7(hand("As", "Ks", "Qs", "Js", "Ts", "2h", "3d"))
ok("royal flush = straight flush (cat 9, high A)", royal[1] == 9 and royal[2] == 14)

local quads = h.evaluate7(hand("9s", "9h", "9d", "9c", "Kd", "2c", "3h"))
ok("four of a kind (cat 8, K kicker)", quads[1] == 8 and quads[2] == 9 and quads[3] == 13)

local boat = h.evaluate7(hand("Ks", "Kh", "Kd", "3s", "3h", "9c", "5s"))
ok("full house (cat 7, K over 3)", boat[1] == 7 and boat[2] == 13 and boat[3] == 3)

local flush = h.evaluate7(hand("Ah", "Jh", "8h", "5h", "2h", "Kd", "Qc"))
ok("flush (cat 6, A high)", flush[1] == 6 and flush[2] == 14)

local wheel = h.evaluate7(hand("As", "2d", "3c", "4h", "5s", "Kd", "Qc"))
ok("wheel straight (cat 5, high 5)", wheel[1] == 5 and wheel[2] == 5)

local bigStraight = h.evaluate7(hand("9s", "Td", "Jc", "Qh", "Ks", "2d", "3c"))
ok("straight (cat 5, high K)", bigStraight[1] == 5 and bigStraight[2] == 13)

local twoPair = h.evaluate7(hand("Ah", "Ad", "Kh", "Kd", "5s", "5c", "2d"))
ok("two pair picks top two (AAKK, kicker 5)",
    twoPair[1] == 3 and twoPair[2] == 14 and twoPair[3] == 13 and twoPair[4] == 5)

-- ── Comparison ────────────────────────────────────────────────────────────────
ok("full house beats flush", h.compare(boat, flush) == 1)
ok("higher straight beats wheel", h.compare(bigStraight, wheel) == 1)
ok("flush beats straight", h.compare(flush, bigStraight) == 1)
ok("equal hands tie",
    h.compare(h.evaluate7(hand("As","Ks","Qs","Js","Ts","2h","3d")),
              h.evaluate7(hand("As","Ks","Qs","Js","Ts","4c","7d"))) == 0)

-- kicker decides
local pairAk = h.evaluate7(hand("Ah", "Ad", "Kh", "9d", "5s", "3c", "2d"))
local pairAq = h.evaluate7(hand("As", "Ac", "Qh", "9c", "5h", "3s", "2c"))
ok("pair of aces: K kicker beats Q kicker", h.compare(pairAk, pairAq) == 1)

-- ── Side pots ─────────────────────────────────────────────────────────────────
-- Seat 3 is all-in for 50; seats 1 & 2 put in 100 each.
local pots = h.buildPots({ [1] = 100, [2] = 100, [3] = 50 }, {})
ok("two pots built", #pots == 2)
ok("main pot 150 / eligible 1,2,3",
    pots[1].amount == 150 and #pots[1].eligible == 3)
ok("side pot 100 / eligible 1,2",
    pots[2].amount == 100 and #pots[2].eligible == 2)

-- Folded player's chips are dead money (counted, not winnable).
local pots2 = h.buildPots({ [1] = 100, [2] = 50, [3] = 50 }, { [1] = true })
local total2 = 0
for _, p in ipairs(pots2) do total2 = total2 + p.amount end
ok("folded dead money still in pots (total 200)", total2 == 200)

-- Award + chip conservation
local handBySeat = {
    [1] = h.evaluate7(hand("As", "Ad", "Kh", "Qd", "Jc", "2s", "3h")),  -- pair aces
    [2] = h.evaluate7(hand("Ks", "Kd", "Qh", "Jd", "9c", "2s", "3h")),  -- pair kings
    [3] = h.evaluate7(hand("2c", "2h", "7d", "8s", "9h", "4s", "5h")),  -- pair twos
}
local win = h.awardPots(h.buildPots({ [1] = 100, [2] = 100, [3] = 50 }, {}), handBySeat)
local awarded = 0
for _, v in pairs(win) do awarded = awarded + v end
ok("all 250 chips awarded", awarded == 250)
ok("aces win main pot (>=150)", (win[1] or 0) >= 150)

-- Split pot: identical hands share evenly.
local tieHands = {
    [1] = h.evaluate7(hand("As", "Ks", "Qs", "Js", "Ts", "2h", "3d")),
    [2] = h.evaluate7(hand("Ah", "Kh", "Qh", "Jh", "Th", "4c", "7d")),
}
local splitWin = h.awardPots(h.buildPots({ [1] = 100, [2] = 100 }, {}), tieHands)
ok("split pot 100/100", splitWin[1] == 100 and splitWin[2] == 100)

-- ── Rake ──────────────────────────────────────────────────────────────────────
ok("no flop no drop", h.computeRake(1000, 0.05, 30, false) == 0)
ok("5% of 400 = 20", h.computeRake(400, 0.05, 30, true) == 20)
ok("cap binds at 30 on 1000 pot", h.computeRake(1000, 0.05, 30, true) == 30)
ok("rounds down (5% of 90 = 4)", h.computeRake(90, 0.05, 30, true) == 4)

-- takeRake walks layers: main pot smaller than the rake
local rp = { { amount = 3, eligible = { 1, 2, 3 } }, { amount = 198, eligible = { 2, 3 } } }
local taken = h.takeRake(rp, 10)
ok("takeRake drains main then side (3+7)", taken == 10 and rp[1].amount == 0 and rp[2].amount == 191)
ok("takeRake conserves chips", rp[1].amount + rp[2].amount + taken == 201)

-- rake larger than everything (degenerate) takes only what exists
local rp2 = { { amount = 5, eligible = { 1 } } }
ok("takeRake capped by pot total", h.takeRake(rp2, 99) == 5 and rp2[1].amount == 0)

-- end-to-end conservation: pot raked then awarded == original total minus rake
local potsR = h.buildPots({ [1] = 100, [2] = 100, [3] = 50 }, {})
local rakeR = h.computeRake(250, 0.05, 30, true)   -- 12
local takenR = h.takeRake(potsR, rakeR)
local winR = h.awardPots(potsR, {
    [1] = h.evaluate7(hand("As", "Ad", "Kh", "Qd", "Jc", "2s", "3h")),
    [2] = h.evaluate7(hand("Ks", "Kd", "Qh", "Jd", "9c", "2s", "3h")),
    [3] = h.evaluate7(hand("2c", "2h", "7d", "8s", "9h", "4s", "5h")),
})
local awardedR = 0
for _, v in pairs(winR) do awardedR = awardedR + v end
ok("awarded + rake == original 250", awardedR + takenR == 250)

print(string.format("\n%d passed, %d failed", pass, fail))
