-- SLOTS CABINET
-- ┌─────────────────────────────────────────────────────────────────┐
-- │ HARDWARE SETUP — edit CFG below to match your build.            │
-- │                                                                 │
-- │  • ADVANCED Monitor (touch only fires on advanced monitors),    │
-- │    3x3 blocks or larger — 4x3+ recommended.                     │
-- │  • Disk drive attached to this computer  -> driveSide           │
-- │  • Wired or wireless modem on the casino network (reaches bank) │
-- │                                                                 │
-- │  The bank server must be running with a matching SECRET in      │
-- │  lib/protocol.lua. This game only debits/credits the account — │
-- │  it never touches items.                                        │
-- │                                                                 │
-- │  Win symbols flash, then you may GAMBLE the win on a 50/50      │
-- │  RED/BLACK double-or-nothing, or COLLECT and spin again.        │
-- └─────────────────────────────────────────────────────────────────┘

local bankc = require("lib.bankclient")
local card  = require("lib.card")
local ui    = require("lib.ui")

local CFG = {
    monitorName  = "monitor_1",   -- exact monitor peripheral name; "" = auto-find any monitor
    driveSide    = "left",        -- side the disk drive is attached to
    monitorScale = 0.5,           -- text scale (0.5 – 5)
    CHIPS        = {1, 5, 25, 100},
    MIN_BET      = 1,
    MAX_BET      = 500,
    GAMBLE_MAX   = 4,             -- max consecutive double-or-nothing rounds per win
}

-- ─── Symbols ──────────────────────────────────────────────────────────────────
-- weight = relative reel frequency (higher = appears more often)
-- mult3  = payout multiplier for three-of-a-kind

local SYMBOLS = {
    { name="DIAMOND", char="D", color=colors.lightBlue, weight=1,  mult3=100 },
    { name="SEVEN",   char="7", color=colors.red,       weight=2,  mult3=50  },
    { name="BELL",    char="*", color=colors.yellow,    weight=4,  mult3=15  },
    { name="CHERRY",  char="C", color=colors.magenta,   weight=7,  mult3=8   },
    { name="COIN",    char="$", color=colors.orange,    weight=9,  mult3=4   },
    { name="BAR",     char="=", color=colors.white,     weight=12, mult3=3   },
}

-- Build weighted pool once at load time.
local POOL = {}
for _, sym in ipairs(SYMBOLS) do
    for _ = 1, sym.weight do POOL[#POOL+1] = sym end
end

local function randSym() return POOL[math.random(#POOL)] end

-- Look up a symbol by name (so default reels don't depend on table order).
local function symByName(name)
    for _, s in ipairs(SYMBOLS) do if s.name == name then return s end end
end
local BAR = symByName("BAR")

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

local STATE        = "INSERT"   -- INSERT | BET | SPINNING | RESULT | GAMBLE
local playerID
local balance      = 0
local bet          = 0
local staked       = 0
local message      = ""
local messageColor = colors.gray
local reels        = { BAR, BAR, BAR }   -- current display (default BAR BAR BAR)
local lastMult     = 0          -- payout multiplier of the last spin (0 = loss)
local currentWin   = 0          -- credits riding (spin payout, grows on a gamble win)
local gambleCount  = 0          -- consecutive gambles taken on the current win
local buttons      = {}

local DEBOUNCE_MS = 300
local lastTouch   = 0

-- ─── Bank helpers ─────────────────────────────────────────────────────────────

local function refreshBalance()
    if not playerID then balance = 0; return end
    local ok, res = bankc.balance(playerID)
    if ok then balance = res else balance = 0; message = "Bank: " .. tostring(res) end
end

-- ─── Paytable ─────────────────────────────────────────────────────────────────

-- Returns payout multiplier for three reels (0 = no win).
--  • three-of-a-kind         -> sym.mult3  (covers 3 cherries = 8x, 3 sevens = 50x, ...)
--  • two sevens anywhere     -> 5x
--  • two cherries anywhere   -> 3x
--  • one cherry anywhere     -> 1x  (returns the stake)
local function getPayout(r1, r2, r3)
    if r1.name == r2.name and r2.name == r3.name then
        return r1.mult3
    end
    local sevens, cherries = 0, 0
    for _, r in ipairs({r1, r2, r3}) do
        if r.name == "SEVEN"  then sevens   = sevens   + 1 end
        if r.name == "CHERRY" then cherries = cherries + 1 end
    end
    if sevens == 2   then return 5 end
    if cherries == 2 then return 3 end
    if cherries == 1 then return 1 end
    return 0
end

-- ─── Drawing ──────────────────────────────────────────────────────────────────

local REEL_W, REEL_H = 9, 5   -- outer reel box size in chars
local SYM_W,  SYM_H  = 5, 3   -- colored symbol box inside each reel

-- Where the three reels sit for the current monitor size.
-- Returns { x1, x2, x3 }, reelY.
local function reelLayout(w, h)
    local gap    = 2
    local totalW = REEL_W * 3 + gap * 2
    local startX = math.max(1, math.floor((w - totalW) / 2) + 1)
    -- Center reels vertically between the header and the bottom 5 reserved rows.
    local reelY = math.max(4, math.min(math.floor((h - REEL_H) / 2), h - REEL_H - 5))
    return { startX, startX + REEL_W + gap, startX + REEL_W * 2 + gap * 2 }, reelY
end

-- Draw one reel box with its symbol centered. `bg` overrides the box color (for the win flash).
local function drawReel(x, y, sym, bg)
    local boxColor = bg or colors.gray
    local symColor = bg or sym.color
    ui.fillRect(mon, x, y, REEL_W, REEL_H, boxColor)
    local sx = x + math.floor((REEL_W - SYM_W) / 2)
    local sy = y + math.floor((REEL_H - SYM_H) / 2)
    ui.fillRect(mon, sx, sy, SYM_W, SYM_H, symColor)
    mon.setBackgroundColor(symColor)
    mon.setTextColor(colors.black)
    mon.setCursorPos(sx + math.floor(SYM_W / 2), sy + math.floor(SYM_H / 2))
    mon.write(sym.char)
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)
end

-- The active payline runs through the middle row; mark it with > <.
local function drawPayline(xs, reelY, win)
    local midY  = reelY + math.floor(REEL_H / 2)
    local color = win and colors.yellow or colors.gray
    ui.text(mon, math.max(1, xs[1] - 2), midY, ">", color)
    ui.text(mon, xs[3] + REEL_W + 1,     midY, "<", color)
end

local function drawAllReels(w, h, r1, r2, r3, win)
    local xs, reelY = reelLayout(w, h)
    drawReel(xs[1], reelY, r1)
    drawReel(xs[2], reelY, r2)
    drawReel(xs[3], reelY, r3)
    drawPayline(xs, reelY, win)
end

-- Flash the winning reels yellow a few times (more, plus a banner, for a jackpot).
local function flashWin(rs, mult)
    local w, h      = mon.getSize()
    local xs, reelY = reelLayout(w, h)
    local cycles    = (mult >= 50) and 10 or 6
    for f = 1, cycles do
        local hot = (f % 2 == 1)
        for i = 1, 3 do
            drawReel(xs[i], reelY, rs[i], hot and colors.yellow or nil)
        end
        drawPayline(xs, reelY, true)
        if mult >= 50 then
            ui.centerText(mon, h - 4, "*  *  *   J A C K P O T   *  *  *", colors.yellow)
        else
            ui.centerText(mon, h - 4, "W I N N E R !", colors.yellow)
        end
        sleep(0.15)
    end
end

-- Lay out a single row of evenly-spaced buttons across the full width.
local function rowButtons(defs, y, h)
    local w = mon.getSize()
    local n = #defs
    local gap = 1
    local bw = math.floor((w - (n + 1) * gap) / n)
    local out = {}
    local x = gap + 1
    for _, d in ipairs(defs) do
        out[#out+1] = ui.button(mon, x, y, bw, h, d.label, d.bg, d.fg, d.id)
        x = x + bw + gap
    end
    return out
end

local function drawPaytableHint(h)
    ui.centerText(mon, h - 5, "3x: D100 7:50 *:15 C:8 $:4 =:3   77:5  CC:3  C:1", colors.gray)
end

local function appendRow(defs, y, h)
    for _, b in ipairs(rowButtons(defs, y, h)) do buttons[#buttons+1] = b end
end

local function draw()
    local w, h = mon.getSize()
    ui.clear(mon)
    buttons = {}

    if STATE == "INSERT" then
        ui.centerText(mon, 1, "S  L  O  T  S", colors.yellow)
        ui.centerText(mon, math.floor(h / 2) - 1, "INSERT CARD", colors.red)
        ui.centerText(mon, math.floor(h / 2) + 1, "TO PLAY", colors.red)
        ui.centerText(mon, h, message, colors.gray)

    elseif STATE == "BET" then
        ui.centerText(mon, 1, "S  L  O  T  S", colors.yellow)
        ui.centerText(mon, 3, "BALANCE: " .. balance .. "  BET: " .. bet, colors.lime)
        drawAllReels(w, h, reels[1], reels[2], reels[3])
        drawPaytableHint(h)
        ui.centerText(mon, h - 4, message, messageColor)

        local defs = {}
        for _, chip in ipairs(CFG.CHIPS) do
            defs[#defs+1] = { label="+"..chip, id="chip:"..chip, bg=colors.blue }
        end
        defs[#defs+1] = { label="CLEAR", id="clear", bg=colors.red }
        defs[#defs+1] = { label="EJECT", id="eject", bg=colors.orange, fg=colors.black }
        local spinOK = bet >= CFG.MIN_BET and bet <= balance
        defs[#defs+1] = { label="SPIN", id="spin", bg=spinOK and colors.green or colors.gray }
        buttons = rowButtons(defs, h - 2, 3)

    elseif STATE == "RESULT" then
        ui.centerText(mon, 1, "S  L  O  T  S", colors.yellow)
        ui.centerText(mon, 3, "BALANCE: " .. balance, colors.lime)
        drawAllReels(w, h, reels[1], reels[2], reels[3], lastMult > 0)
        local net = currentWin - staked
        if lastMult > 0 then
            ui.centerText(mon, h - 6, message, messageColor)
            ui.centerText(mon, h - 5,
                "Staked " .. staked .. "   Net " .. (net >= 0 and "+" or "") .. net, colors.lime)
            buttons = rowButtons({
                { label="GAMBLE",  id="gamble",  bg=colors.purple },
                { label="COLLECT", id="collect", bg=colors.green  },
                { label="EJECT",   id="eject",   bg=colors.orange, fg=colors.black },
            }, h - 2, 3)
        else
            ui.centerText(mon, h - 6, "No win this spin", colors.red)
            ui.centerText(mon, h - 5, "Staked " .. staked .. "   Net " .. net, colors.red)
            buttons = rowButtons({
                { label="SPIN AGAIN", id="again", bg=colors.green },
                { label="EJECT",      id="eject", bg=colors.orange, fg=colors.black },
            }, h - 2, 3)
        end

    elseif STATE == "GAMBLE" then
        ui.centerText(mon, 1, "DOUBLE  OR  NOTHING", colors.yellow)
        ui.centerText(mon, 3, "BALANCE: " .. balance, colors.lime)
        ui.centerText(mon, math.floor(h / 2) - 3, "WIN SO FAR: " .. currentWin, colors.lime)
        ui.centerText(mon, math.floor(h / 2) - 1, "Pick a colour to risk it all", colors.white)
        ui.centerText(mon, math.floor(h / 2) + 1, currentWin .. "  ->  " .. (currentWin * 2), colors.yellow)
        ui.centerText(mon, h - 5, message, messageColor)
        ui.centerText(mon, h - 4, "Gamble " .. gambleCount .. "/" .. CFG.GAMBLE_MAX, colors.gray)
        appendRow({
            { label="RED",   id="g:red",   bg=colors.red  },
            { label="BLACK", id="g:black", bg=colors.gray },
        }, math.floor(h / 2) + 3, 3)
        appendRow({
            { label="COLLECT", id="collect", bg=colors.green  },
            { label="EJECT",   id="eject",   bg=colors.orange, fg=colors.black },
        }, h - 2, 3)
    end
end

-- ─── Game flow ────────────────────────────────────────────────────────────────

local function startBetting()
    playerID = card.id(CFG.driveSide)
    if not playerID then STATE = "INSERT"; return end
    bet, staked, currentWin, lastMult, gambleCount, message = 0, 0, 0, 0, 0, ""
    messageColor = colors.gray
    refreshBalance()
    STATE = "BET"
end

-- Return to the betting screen after a win is settled. Keeps `message` so the
-- player still sees the outcome ("Collected ...", "Gambled and lost!").
local function toBet()
    bet, staked, currentWin, lastMult, gambleCount = 0, 0, 0, 0, 0
    STATE = "BET"
end

local function doSpin()
    local spinOK = bet >= CFG.MIN_BET and bet <= balance
    if not spinOK then message, messageColor = "Set a valid bet first", colors.red; return end

    local ok, res = bankc.debit(playerID, bet)
    if not ok then message, messageColor = "Bet declined: " .. tostring(res), colors.red; return end
    balance = res
    staked  = bet
    STATE   = "SPINNING"

    -- Determine results now (fair — not influenced by animation length).
    local finalReels = { randSym(), randSym(), randSym() }

    -- Animate: reels stop sequentially at frames 12, 19, 26 out of 28.
    local w, h = mon.getSize()
    local stopAt = { 12, 19, 26 }
    local display = { randSym(), randSym(), randSym() }

    for frame = 1, 28 do
        for r = 1, 3 do
            if frame >= stopAt[r] then
                display[r] = finalReels[r]
            else
                display[r] = randSym()
            end
        end
        ui.clear(mon)
        ui.centerText(mon, 1, "S  L  O  T  S", colors.yellow)
        ui.centerText(mon, 3, "BALANCE: " .. balance .. "  BET: " .. staked, colors.lime)
        drawAllReels(w, h, display[1], display[2], display[3])
        ui.centerText(mon, h - 4, "* SPINNING *", colors.gray)
        sleep(0.07)
    end

    reels = finalReels

    -- Resolve
    local mult   = getPayout(reels[1], reels[2], reels[3])
    local payout = staked * mult
    lastMult = mult

    if payout > 0 then
        local pok, pres = bankc.credit(playerID, payout)
        if pok then balance = pres end
        currentWin  = payout
        gambleCount = 0
        flashWin(reels, mult)
        if mult >= 50 then
            message, messageColor = "JACKPOT!  x" .. mult .. "  +" .. payout, colors.yellow
        else
            message, messageColor = "WIN  x" .. mult .. "  +" .. payout, colors.lime
        end
    else
        currentWin = 0
        message, messageColor = "No win — try again!", colors.red
    end

    STATE = "RESULT"
end

-- Double-or-nothing on the current win. The win is already in the bank, so a
-- correct guess credits the same amount again (doubling it); a wrong guess
-- debits it back out (to zero).
local function doGamble(choice)
    if currentWin <= 0 then return end
    local w, h   = mon.getSize()
    local result = (math.random(2) == 1) and "red" or "black"

    -- Reveal animation: a band flickers, then locks to the drawn colour.
    local bw = math.min(w - 4, 20)
    local bx = math.floor((w - bw) / 2) + 1
    local by = math.floor(h / 2) - 1
    for f = 1, 6 do
        ui.fillRect(mon, bx, by, bw, 3, (f % 2 == 1) and colors.red or colors.gray)
        sleep(0.12)
    end
    local rc = (result == "red") and colors.red or colors.gray
    ui.fillRect(mon, bx, by, bw, 3, rc)
    ui.centerText(mon, by + 1, result:upper(), colors.white, rc)
    sleep(0.7)

    if choice == result then
        local pok, pres = bankc.credit(playerID, currentWin)
        if pok then balance = pres end
        currentWin  = currentWin * 2
        gambleCount = gambleCount + 1
        if gambleCount >= CFG.GAMBLE_MAX then
            message, messageColor = "Max gambles — " .. currentWin .. " collected!", colors.lime
            toBet()
        else
            message, messageColor = result:upper() .. "!  Doubled to " .. currentWin, colors.lime
            -- stay in GAMBLE for another round
        end
    else
        local dok, dres = bankc.debit(playerID, currentWin)
        if dok then balance = dres end
        message, messageColor = "It was " .. result:upper() .. " — lost " .. currentWin .. "!", colors.red
        currentWin = 0
        toBet()
    end
end

local function handleTouch(id)
    if not id then return end
    messageColor = colors.gray   -- reset to neutral; specific actions may set it red

    -- EJECT works from any betting/result/gamble screen. Any pending win is
    -- already in the bank, so there is nothing to refund.
    if id == "eject" then
        card.eject(CFG.driveSide)
        playerID = nil
        bet, staked, currentWin, lastMult, gambleCount = 0, 0, 0, 0, 0
        message, STATE = "", "INSERT"
        return
    end

    if STATE == "BET" then
        if id:match("^chip:") then
            local chip   = tonumber(id:match("^chip:(%d+)"))
            local newbet = math.min(bet + chip, balance, CFG.MAX_BET)
            if newbet == bet and bet > 0 then
                message, messageColor = "Max bet reached", colors.red
            else
                message = ""
            end
            bet = newbet
        elseif id == "clear" then
            bet, message = 0, ""
        elseif id == "spin" then
            doSpin()
        end

    elseif STATE == "RESULT" then
        if id == "again" then
            if card.id(CFG.driveSide) then toBet() else STATE = "INSERT" end
        elseif id == "collect" then
            if card.id(CFG.driveSide) then
                message, messageColor = (currentWin > 0 and ("Collected " .. currentWin) or ""), colors.lime
                toBet()
            else
                STATE = "INSERT"
            end
        elseif id == "gamble" then
            if currentWin > 0 then
                gambleCount, message, messageColor = 0, "", colors.gray
                STATE = "GAMBLE"
            end
        end

    elseif STATE == "GAMBLE" then
        if id == "g:red" then
            doGamble("red")
        elseif id == "g:black" then
            doGamble("black")
        elseif id == "collect" then
            message, messageColor = (currentWin > 0 and ("Collected " .. currentWin) or ""), colors.lime
            toBet()
        end
    end
end

-- ─── Main loop ────────────────────────────────────────────────────────────────

local function main()
    initPeripherals()
    math.randomseed(os.epoch("utc"))

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
            -- During SPINNING the bet is already committed; the spin finishes
            -- and pays out to the locked playerID. All other states return to INSERT.
            if STATE ~= "SPINNING" then
                STATE   = "INSERT"
                message = ""
            end
        end
    end
end

main()
