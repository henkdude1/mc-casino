-- BLACKJACK CABINET
-- ┌─────────────────────────────────────────────────────────────────┐
-- │ HARDWARE SETUP — edit CFG below to match your build.            │
-- │                                                                 │
-- │  • ADVANCED Monitor (touch only fires on advanced monitors),    │
-- │    3x3 blocks or larger — 4x3+ recommended.                     │
-- │  • Disk drive attached to this computer  -> driveSide           │
-- │  • Wired or wireless modem on the casino network (reaches bank) │
-- │                                                                 │
-- │  The bank server must be running with a matching SECRET in      │
-- │  lib/protocol.lua. This game NEVER touches items — it only      │
-- │  debits the bet and credits winnings on the player's account.   │
-- └─────────────────────────────────────────────────────────────────┘

local bankc = require("lib.bankclient")
local card  = require("lib.card")
local ui    = require("lib.ui")

local CFG = {
    monitorName  = "monitor_1",   -- exact monitor peripheral name; "" or nil = auto-find any monitor
    driveSide    = "left",        -- side the disk drive is attached to
    monitorScale = 1,             -- 1.0 suits a 3×3 monitor; lower it on larger monitors for more room
    CHIPS        = {1, 5, 25, 100},
    MIN_BET      = 1,
    MAX_BET      = 500,
}

-- ─── Peripherals ──────────────────────────────────────────────────────────────

local mon

local function initPeripherals()
    bankc.open()
    if CFG.monitorName and CFG.monitorName ~= "" then
        mon = peripheral.wrap(CFG.monitorName)
        assert(mon, "Monitor not found: " .. CFG.monitorName)
    else
        mon = peripheral.find("monitor")
        assert(mon, "No monitor found — attach an Advanced Monitor")
    end
    assert(mon.isColor and mon.isColor(), "Monitor must be an Advanced (color) Monitor for touch")
    mon.setTextScale(CFG.monitorScale)
end

-- ─── Game state ───────────────────────────────────────────────────────────────

local STATE   = "INSERT"   -- INSERT | BET | PLAYER | DEALER | RESULT
local playerID                -- locked at DEAL; payouts go to this id
local balance     = 0         -- cached account balance
local bet         = 0         -- current wager being built
local staked      = 0         -- total debited this hand (doubles on double-down)
local message     = ""        -- status banner text
local deck, playerHand, dealerHand
local revealHole  = false     -- show dealer's hole card?
local canDouble   = false     -- double allowed right now?
local buttons     = {}        -- current hit-test descriptors

local DEBOUNCE_MS = 300       -- ignore repeat touches within this window (fixes double-hit)
local lastTouch   = 0

-- ─── Deck & hand maths ────────────────────────────────────────────────────────

local RANKS = {
    {r="A", v=11}, {r="2", v=2}, {r="3", v=3}, {r="4", v=4}, {r="5", v=5},
    {r="6", v=6},  {r="7", v=7}, {r="8", v=8}, {r="9", v=9}, {r="10", v=10},
    {r="J", v=10}, {r="Q", v=10}, {r="K", v=10},
}
local SUITS = { "S", "H", "D", "C" }

local function newDeck()
    local d = {}
    for _, s in ipairs(SUITS) do
        for _, rk in ipairs(RANKS) do
            d[#d + 1] = { rank = rk.r, suit = s, value = rk.v }
        end
    end
    -- Fisher–Yates shuffle
    for i = #d, 2, -1 do
        local j = math.random(i)
        d[i], d[j] = d[j], d[i]
    end
    return d
end

local function draw1()
    return table.remove(deck)
end

-- Best total for a hand, treating aces as 11 then dropping to 1 as needed.
local function handValue(hand)
    local total, aces = 0, 0
    for _, c in ipairs(hand) do
        total = total + c.value
        if c.rank == "A" then aces = aces + 1 end
    end
    while total > 21 and aces > 0 do
        total = total - 10
        aces = aces - 1
    end
    return total
end

local function isBlackjack(hand)
    return #hand == 2 and handValue(hand) == 21
end

-- ─── Bank helpers ─────────────────────────────────────────────────────────────

local function refreshBalance()
    if not playerID then balance = 0; return end
    local ok, res = bankc.balance(playerID)
    if ok then balance = res else balance = 0; message = "Bank: " .. tostring(res) end
end

-- ─── Rendering ────────────────────────────────────────────────────────────────

-- Lay out a single row of evenly-spaced buttons across the screen width.
local function rowButtons(defs, y, h)
    local w = mon.getSize()
    local n = #defs
    local gap = 1
    local bw = math.floor((w - (n + 1) * gap) / n)
    local out = {}
    local x = gap + 1
    for _, d in ipairs(defs) do
        out[#out + 1] = ui.button(mon, x, y, bw, h, d.label, d.bg, d.fg, d.id)
        x = x + bw + gap
    end
    return out
end

local function drawHand(hand, x, y, hideHole)
    local w = mon.getSize()
    local n = #hand
    local spacing = 6
    if n > 1 then spacing = math.floor((w - x - 5) / (n - 1)) end
    spacing = math.max(3, math.min(6, spacing))
    for i, c in ipairs(hand) do
        local faceUp = not (hideHole and i == 2)
        ui.card(mon, x + (i - 1) * spacing, y, c.rank, c.suit, faceUp)
    end
end

local function drawTable(w, h, hideHole)
    ui.clear(mon)
    ui.centerText(mon, 1, "B L A C K J A C K", colors.yellow)

    -- Dealer
    local dealerLabel = "DEALER"
    if hideHole then
        dealerLabel = dealerLabel .. "  (" .. tostring(dealerHand[1].value) .. " + ?)"
    else
        dealerLabel = dealerLabel .. "  (" .. tostring(handValue(dealerHand)) .. ")"
    end
    ui.text(mon, 2, 3, dealerLabel, colors.white)
    drawHand(dealerHand, 2, 4, hideHole)

    -- Player
    ui.text(mon, 2, 9, "YOU  (" .. tostring(handValue(playerHand)) .. ")", colors.cyan)
    drawHand(playerHand, 2, 10, false)
end

local function draw()
    local w, h = mon.getSize()

    if STATE == "INSERT" then
        ui.clear(mon)
        ui.centerText(mon, 1, "B L A C K J A C K", colors.yellow)
        ui.centerText(mon, math.floor(h / 2) - 1, "INSERT CARD", colors.red)
        ui.centerText(mon, math.floor(h / 2) + 1, "TO PLAY", colors.red)
        ui.centerText(mon, h, message, colors.gray)
        buttons = {}

    elseif STATE == "BET" then
        ui.clear(mon)
        ui.centerText(mon, 1, "B L A C K J A C K", colors.yellow)
        ui.centerText(mon, 4, "BALANCE: " .. balance .. " credits", colors.lime)
        ui.centerText(mon, 6, "YOUR BET", colors.white)
        ui.centerText(mon, 7, tostring(bet), colors.yellow)
        ui.centerText(mon, h - 7, message, colors.gray)

        local chipDefs = {}
        for _, chip in ipairs(CFG.CHIPS) do
            chipDefs[#chipDefs + 1] = { label = "+" .. chip, id = "chip:" .. chip, bg = colors.blue }
        end
        local dealOK = bet >= CFG.MIN_BET and bet <= balance
        local controlDefs = {
            { label = "CLEAR",  id = "clear",  bg = colors.red },
            { label = "DEAL",   id = "deal",   bg = dealOK and colors.green or colors.gray },
            { label = "EJECT",  id = "eject",  bg = colors.orange },
        }
        buttons = {}
        for _, b in ipairs(rowButtons(chipDefs,    h - 6, 3)) do buttons[#buttons + 1] = b end
        for _, b in ipairs(rowButtons(controlDefs, h - 2, 3)) do buttons[#buttons + 1] = b end

    elseif STATE == "PLAYER" then
        drawTable(w, h, true)
        ui.centerText(mon, h - 4, message, colors.gray)
        local defs = {
            { label = "HIT",   id = "hit",   bg = colors.green },
            { label = "STAND", id = "stand", bg = colors.orange },
        }
        if canDouble and balance >= bet then
            defs[#defs + 1] = { label = "DOUBLE", id = "double", bg = colors.cyan, fg = colors.black }
        end
        buttons = rowButtons(defs, h - 2, 3)

    elseif STATE == "DEALER" then
        drawTable(w, h, false)
        ui.centerText(mon, h - 4, "Dealer drawing...", colors.gray)
        buttons = {}

    elseif STATE == "RESULT" then
        drawTable(w, h, false)
        ui.centerText(mon, h - 4, message, colors.yellow)
        ui.centerText(mon, h - 3, "Balance: " .. balance .. " credits", colors.lime)
        buttons = rowButtons({
            { label = "PLAY AGAIN", id = "again", bg = colors.green },
            { label = "QUIT",       id = "quit",  bg = colors.red   },
        }, h - 2, 3)
    end
end

-- ─── Game flow ────────────────────────────────────────────────────────────────

local function startBetting()
    playerID = card.id(CFG.driveSide)
    if not playerID then STATE = "INSERT"; return end
    bet, staked, message = 0, 0, ""
    refreshBalance()
    STATE = "BET"
end

local function resolve()
    revealHole = true
    local pv, dv = handValue(playerHand), handValue(dealerHand)
    local pBJ, dBJ = isBlackjack(playerHand), isBlackjack(dealerHand)
    local payout, outcome

    if pv > 21 then
        payout, outcome = 0, "BUST — you lose"
    elseif pBJ and dBJ then
        payout, outcome = staked, "Push — both blackjack"
    elseif pBJ then
        -- 3:2 natural. Odd bets round the half-credit down (house edge).
        payout, outcome = staked + math.floor(staked * 3 / 2), "BLACKJACK! 3:2"
    elseif dBJ then
        payout, outcome = 0, "Dealer blackjack — you lose"
    elseif dv > 21 then
        payout, outcome = staked * 2, "Dealer busts — you win!"
    elseif pv > dv then
        payout, outcome = staked * 2, "You win!"
    elseif pv < dv then
        payout, outcome = 0, "Dealer wins"
    else
        payout, outcome = staked, "Push"
    end

    if payout > 0 then
        local ok, res = bankc.credit(playerID, payout)
        if ok then balance = res else message = "Payout error: " .. tostring(res) end
    end
    message = outcome
    STATE = "RESULT"
end

local function dealerTurn()
    STATE = "DEALER"
    revealHole = true
    draw()
    sleep(0.6)
    -- Dealer only draws if the player is still live (not busted).
    if handValue(playerHand) <= 21 then
        while handValue(dealerHand) < 17 do
            dealerHand[#dealerHand + 1] = draw1()
            draw()
            sleep(0.6)
        end
    end
    resolve()
end

local function doDeal()
    local dealOK = bet >= CFG.MIN_BET and bet <= balance
    if not dealOK then message = "Set a valid bet first"; return end

    local ok, res = bankc.debit(playerID, bet)
    if not ok then message = "Bet declined: " .. tostring(res); return end
    balance = res
    staked = bet

    deck = newDeck()
    playerHand = { draw1(), draw1() }
    dealerHand = { draw1(), draw1() }
    revealHole = false
    canDouble = balance >= bet
    STATE = "PLAYER"
    message = ""

    -- Natural blackjack resolves immediately.
    if isBlackjack(playerHand) then
        dealerTurn()
    end
end

local function doHit()
    playerHand[#playerHand + 1] = draw1()
    canDouble = false
    local pv = handValue(playerHand)
    if pv > 21 then
        resolve()          -- bust
    elseif pv == 21 then
        dealerTurn()       -- auto-stand on 21
    end
end

local function doDouble()
    if not (canDouble and balance >= bet) then return end
    local ok, res = bankc.debit(playerID, bet)
    if not ok then message = "Double declined: " .. tostring(res); return end
    balance = res
    staked = staked + bet
    canDouble = false
    playerHand[#playerHand + 1] = draw1()
    if handValue(playerHand) > 21 then
        resolve()
    else
        dealerTurn()
    end
end

local function handleTouch(id)
    if not id then return end

    if STATE == "BET" then
        if id:match("^chip:") then
            local chip = tonumber(id:match("^chip:(%d+)"))
            bet = math.min(bet + chip, balance, CFG.MAX_BET)
            message = ""
        elseif id == "clear" then
            bet, message = 0, ""
        elseif id == "deal" then
            doDeal()
        elseif id == "eject" then
            disk.eject(CFG.driveSide)
            playerID = nil
            bet, staked, message = 0, 0, ""
            STATE = "INSERT"
        end

    elseif STATE == "PLAYER" then
        if id == "hit" then doHit()
        elseif id == "stand" then dealerTurn()
        elseif id == "double" then doDouble() end

    elseif STATE == "RESULT" then
        if id == "again" then
            if card.id(CFG.driveSide) then startBetting() else STATE = "INSERT" end
        elseif id == "quit" then
            disk.eject(CFG.driveSide)
            playerID = nil
            bet, staked, message = 0, 0, ""
            STATE = "INSERT"
        end
    end
end

-- ─── Main loop ────────────────────────────────────────────────────────────────

local function main()
    initPeripherals()
    math.randomseed(os.epoch("utc"))

    -- If a card is already present at boot, go straight to betting.
    if card.id(CFG.driveSide) then startBetting() else STATE = "INSERT" end

    while true do
        draw()
        local ev = { os.pullEvent() }
        local name = ev[1]

        if name == "monitor_touch" then
            local now = os.epoch("utc")
            if now - lastTouch >= DEBOUNCE_MS then
                lastTouch = now
                local _, _, x, y = table.unpack(ev)
                handleTouch(ui.hit(buttons, x, y))
            end

        elseif name == "disk" then
            if STATE == "INSERT" then startBetting() end

        elseif name == "disk_eject" then
            -- Card pulled: payouts still reach the locked account by id.
            if STATE == "PLAYER" then
                dealerTurn()        -- auto-stand and resolve
            else
                STATE, message = "INSERT", ""
            end
        end
    end
end

main()
