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
    AUTO_DELAY   = 3.0,           -- pause (s) between autospins; STOP stays tappable in this gap
}

-- ─── Symbols ──────────────────────────────────────────────────────────────────
-- weight = relative reel frequency (higher = appears more often)
-- mult3  = payout multiplier for three-of-a-kind

local SYMBOLS = {
    { name="DIAMOND", char="D", color=colors.lightBlue, weight=1,  mult3=100,
      icon    = { "..X..", ".XXX.", "..X.." },
      iconBig = { "...X...", "..XXX..", ".XXXXX.", "..XXX..", "...X..." } },
    { name="SEVEN",   char="7", color=colors.red,       weight=2,  mult3=50,
      icon    = { "XXXXX", "...X.", "..X.." },
      iconBig = { "XXXXXXX", ".....X.", "....X..", "...X...", "..X...." } },
    { name="BELL",    char="*", color=colors.yellow,    weight=4,  mult3=15,
      icon    = { ".XXX.", "XXXXX", "..X.." },
      iconBig = { "...X...", "..XXX..", ".XXXXX.", "XXXXXXX", "...X..." } },
    { name="CHERRY",  char="C", color=colors.magenta,   weight=6,  mult3=8,
      icon    = { "..g..", ".X.X.", "XXXXX" },
      iconBig = { "...gg..", "..g.g..", ".X...X.", "XXX.XXX", ".XX.XX." },
      iconAccents = { g=colors.green } },
    { name="COIN",    char="$", color=colors.orange,    weight=9,  mult3=4,
      icon    = { ".XXX.", "X...X", ".XXX." },
      iconBig = { ".XXXXX.", "XXXXXXX", "XXXXXXX", "XXXXXXX", ".XXXXX." } },
    { name="BAR",     char="=", color=colors.white,     weight=12, mult3=3,
      icon    = { "XXXXX", ".....", "XXXXX" },
      iconBig = { "XXXXXXX", ".......", "XXXXXXX", ".......", "XXXXXXX" } },
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
local reels        = { BAR, BAR, BAR }   -- center-row symbols (the payline — scored by getPayout)
-- Each reel shows 3 stacked symbols {top, mid, bot}; `mid` is the payline = reels[r].
local reelWindows  = { { BAR, BAR, BAR }, { BAR, BAR, BAR }, { BAR, BAR, BAR } }
local lastMult     = 0          -- payout multiplier of the last spin (0 = loss)
local currentWin   = 0          -- credits riding (spin payout, grows on a gamble win)
local gambleCount  = 0          -- consecutive gambles taken on the current win
local autoSpin     = false      -- autospin toggle (re-bets `staked` until stopped)
local autoTimer    = nil        -- os.startTimer id for the next autospin
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
    if cherries == 2 then return 2 end
    if cherries == 1 then return 1 end
    return 0
end

-- ─── Drawing: 3x3 reel grid ─────────────────────────────────────────────────
-- Three reels across, three symbol rows down. The middle row is the payline.

local GRID_TOP    = 4   -- first row available below the title/balance header
local GRID_BOTTOM = 7   -- rows reserved at the bottom for paytable + message + buttons

-- Compute cell rects for the 3x3 grid for the current monitor size. Adaptive so
-- it fits a small monitor (cells clamp to 1 tall). Returns:
--   cells  = cells[col][row] = { x, y, cw, ch }   (col,row = 1..3)
--   midY   = top row of the centre (payline) cells
--   xLeft, xRight = x just outside the grid (for the > < markers)
local function gridLayout(w, h)
    local gap    = 1
    local cw     = math.min(11, math.floor((w - 4 - gap * 2) / 3))
    cw           = math.max(3, cw)
    local gridW  = cw * 3 + gap * 2
    local x0     = math.max(1, math.floor((w - gridW) / 2) + 1)

    local availH = h - GRID_TOP - GRID_BOTTOM + 1
    local ch     = math.max(1, math.floor(availH / 3))
    local gridH  = ch * 3
    local y0     = GRID_TOP + math.max(0, math.floor((availH - gridH) / 2))

    local cells = {}
    for c = 1, 3 do
        cells[c] = {}
        local cx = x0 + (c - 1) * (cw + gap)
        for r = 1, 3 do
            cells[c][r] = { x = cx, y = y0 + (r - 1) * ch, cw = cw, ch = ch }
        end
    end
    local midY = y0 + ch + math.floor(ch / 2)   -- char row of the centre cell
    return cells, midY, x0 - 1, x0 + gridW
end

-- Paint a pw×ph block-art pattern centred in `rect`. Each non-"." pixel becomes
-- a 1-char fillRect. On a win flash (`hot`) every pixel is drawn black (over the
-- yellow cell backdrop); otherwise X = symbol colour and lowercase letters map
-- through sym.iconAccents (e.g. cherry stem g = green).
local function drawPattern(rect, pattern, pw, ph, sym, hot)
    local ix = rect.x + math.floor((rect.cw - pw) / 2)
    local iy = rect.y + math.floor((rect.ch - ph) / 2)
    for row = 1, ph do
        local rowStr = pattern[row]
        for col = 1, pw do
            local px = rowStr:sub(col, col)
            if px ~= "." then
                local pixColor
                if hot then
                    pixColor = colors.black
                elseif px ~= "X" and sym.iconAccents and sym.iconAccents[px] then
                    pixColor = sym.iconAccents[px]
                else
                    pixColor = sym.color
                end
                ui.fillRect(mon, ix + col - 1, iy + row - 1, 1, 1, pixColor)
            end
        end
    end
end

-- Draw one symbol cell. `hot` (the winning payline flash) paints it yellow.
-- Picks the largest icon that fits: 7x5 big icon, then 5x3, then a centred char.
local function drawCell(rect, sym, hot)
    ui.fillRect(mon, rect.x, rect.y, rect.cw, rect.ch, hot and colors.yellow or colors.black)
    if rect.cw >= 7 and rect.ch >= 5 and sym.iconBig then
        drawPattern(rect, sym.iconBig, 7, 5, sym, hot)
    elseif rect.cw >= 5 and rect.ch >= 3 and sym.icon then
        drawPattern(rect, sym.icon, 5, 3, sym, hot)
    else
        mon.setBackgroundColor(hot and colors.yellow or sym.color)
        mon.setTextColor(colors.black)
        mon.setCursorPos(rect.x + math.floor((rect.cw - 1) / 2), rect.y + math.floor(rect.ch / 2))
        mon.write(sym.char)
        mon.setBackgroundColor(colors.black)
        mon.setTextColor(colors.white)
    end
end

-- Draw the whole 3x3 grid from `windows` (windows[col] = {top, mid, bot}).
-- When `win`, the centre (payline) row and its > < markers turn yellow.
local function drawGrid(w, h, windows, win)
    local cells, midY, xLeft, xRight = gridLayout(w, h)
    for c = 1, 3 do
        for r = 1, 3 do
            drawCell(cells[c][r], windows[c][r], win and r == 2)
        end
    end
    local mc = win and colors.yellow or colors.gray
    ui.text(mon, math.max(1, xLeft), midY, ">", mc)
    ui.text(mon, xRight,             midY, "<", mc)
end

-- Flash the winning payline (centre row) yellow a few times (more, plus a banner,
-- for a jackpot). Top/bottom rows stay static.
local function flashWin(windows, mult)
    local w, h   = mon.getSize()
    local cycles = (mult >= 50) and 10 or 6
    for f = 1, cycles do
        drawGrid(w, h, windows, f % 2 == 1)
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
    ui.centerText(mon, h - 5, "3x: D100 7:50 *:15 C:8 $:4 =:3   77:5  CC:2  C:1", colors.gray)
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
        drawGrid(w, h, reelWindows)
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
        drawGrid(w, h, reelWindows, lastMult > 0)
        local net      = currentWin - staked
        local canRepeat = staked >= CFG.MIN_BET and staked <= balance
        local repeatBg  = canRepeat and colors.green or colors.gray
        local autoBg    = canRepeat and colors.cyan  or colors.gray

        if autoSpin then
            ui.centerText(mon, h - 6, message ~= "" and message or "Autospin running...", messageColor)
            ui.centerText(mon, h - 5, "Staked " .. staked .. "   Bal " .. balance, colors.gray)
            buttons = rowButtons({
                { label="STOP AUTOSPIN", id="stop", bg=colors.red },
            }, h - 2, 3)
        elseif lastMult > 0 then
            ui.centerText(mon, h - 6, message, messageColor)
            ui.centerText(mon, h - 5,
                "Staked " .. staked .. "   Net " .. (net >= 0 and "+" or "") .. net, colors.lime)
            buttons = rowButtons({
                { label="GAMBLE",  id="gamble",  bg=colors.purple },
                { label="RESPIN",  id="respin",  bg=repeatBg },
                { label="AUTO",    id="auto",    bg=autoBg, fg=colors.black },
                { label="COLLECT", id="collect", bg=colors.green  },
                { label="EJECT",   id="eject",   bg=colors.orange, fg=colors.black },
            }, h - 2, 3)
        else
            ui.centerText(mon, h - 6, "No win this spin", colors.red)
            ui.centerText(mon, h - 5, "Staked " .. staked .. "   Net " .. net, colors.red)
            buttons = rowButtons({
                { label="RESPIN",  id="respin", bg=repeatBg },
                { label="AUTO",    id="auto",   bg=autoBg, fg=colors.black },
                { label="NEW BET", id="newbet", bg=colors.blue },
                { label="EJECT",   id="eject",  bg=colors.orange, fg=colors.black },
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

    -- Build a scroll strip per reel. Each reel rolls one symbol per frame; the
    -- visible window is strip[pos..pos+2] with strip[pos+1] as the centre cell.
    -- Forcing strip[stopFrame+1] = finalReels[r] lands the payline on the result
    -- exactly when that reel stops.
    local w, h   = mon.getSize()
    local stopAt = { 12, 19, 26 }   -- reels stop left-to-right
    local FRAMES = stopAt[3]
    local strips = {}
    for r = 1, 3 do
        local s = {}
        for i = 1, stopAt[r] + 2 do s[i] = randSym() end
        s[stopAt[r] + 1] = finalReels[r]
        strips[r] = s
    end

    local function windowAt(frame)
        local win = {}
        for r = 1, 3 do
            local pos = math.min(frame, stopAt[r])
            win[r] = { strips[r][pos], strips[r][pos + 1], strips[r][pos + 2] }
        end
        return win
    end

    for frame = 1, FRAMES do
        ui.clear(mon)
        ui.centerText(mon, 1, "S  L  O  T  S", colors.yellow)
        ui.centerText(mon, 3, "BALANCE: " .. balance .. "  BET: " .. staked, colors.lime)
        drawGrid(w, h, windowAt(frame))
        ui.centerText(mon, h - 4, "* SPINNING *", colors.gray)
        -- Ease out: slow down over the final stretch so the reels visibly settle.
        local remaining = FRAMES - frame
        local delay = 0.05
        if remaining < 10 then delay = 0.05 + (10 - remaining) * 0.015 end
        sleep(delay)
    end

    reelWindows = windowAt(FRAMES)
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
        flashWin(reelWindows, mult)
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

    -- STOP autospin (works from any screen). Nil-ing autoTimer makes any queued
    -- timer event a no-op via the `ev[2] == autoTimer` guard in the main loop.
    if id == "stop" then
        autoSpin, autoTimer = false, nil
        message, messageColor = "Autospin stopped", colors.gray
        return
    end

    -- EJECT works from any betting/result/gamble screen. Any pending win is
    -- already in the bank, so there is nothing to refund.
    if id == "eject" then
        autoSpin, autoTimer = false, nil
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
        if id == "respin" then
            if not card.id(CFG.driveSide) then STATE = "INSERT"
            elseif staked >= CFG.MIN_BET and staked <= balance then
                bet = staked
                doSpin()
            else
                message, messageColor = "Need " .. staked .. " to repeat", colors.red
            end
        elseif id == "auto" then
            if not card.id(CFG.driveSide) then STATE = "INSERT"
            elseif staked >= CFG.MIN_BET and staked <= balance then
                autoSpin = true
                bet = staked
                doSpin()
                autoTimer = os.startTimer(CFG.AUTO_DELAY)
            else
                message, messageColor = "Need " .. staked .. " to autospin", colors.red
            end
        elseif id == "newbet" then
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

        elseif name == "timer" then
            -- Autospin heartbeat: fire the next spin if still affordable.
            if autoSpin and ev[2] == autoTimer then
                if not card.id(CFG.driveSide) then
                    autoSpin, autoTimer, STATE, message = false, nil, "INSERT", ""
                elseif staked < CFG.MIN_BET or staked > balance then
                    autoSpin, autoTimer = false, nil
                    message, messageColor = "Autospin stopped — not enough credits", colors.red
                else
                    bet = staked
                    doSpin()
                    autoTimer = os.startTimer(CFG.AUTO_DELAY)
                end
            end

        elseif name == "disk" then
            if STATE == "INSERT" then startBetting() end

        elseif name == "disk_eject" then
            -- During SPINNING the bet is already committed; the spin finishes
            -- and pays out to the locked playerID. All other states return to INSERT.
            if STATE ~= "SPINNING" then
                autoSpin, autoTimer = false, nil
                STATE   = "INSERT"
                message = ""
            end
        end
    end
end

main()
