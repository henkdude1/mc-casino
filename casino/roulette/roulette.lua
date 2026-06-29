-- ROULETTE CABINET (American, double-zero)
-- ┌─────────────────────────────────────────────────────────────────┐
-- │ HARDWARE SETUP — edit CFG below to match your build.            │
-- │                                                                 │
-- │  • ADVANCED Monitor (touch only fires on advanced monitors),    │
-- │    4x3 blocks recommended — bigger than the 3x3 game cabinets.  │
-- │  • Disk drive attached to this computer  -> driveSide           │
-- │  • Wired or wireless modem on the casino network (reaches bank) │
-- │                                                                 │
-- │  The bank server must be running with a matching SECRET in      │
-- │  lib/protocol.lua. This game only debits/credits the account —  │
-- │  it never touches items.                                        │
-- │                                                                 │
-- │  Players stack multiple chips on different spots, then SPIN     │
-- │  once; every bet is resolved against the single winning pocket. │
-- └─────────────────────────────────────────────────────────────────┘

local bankc = require("lib.bankclient")
local card  = require("lib.card")
local ui    = require("lib.ui")

local CFG = {
    monitorName  = "monitor_1",   -- exact monitor peripheral name; "" = auto-find any monitor
    driveSide    = "left",        -- side the disk drive is attached to
    monitorScale = 0.5,           -- 4x3 monitor: 0.5 gives enough cells for the number grid; tune to taste
    CHIPS        = {1, 5, 25, 100},
    MIN_BET      = 1,
    MAX_BET      = 1000,          -- per-spin total stake cap
}

-- ─── Wheel data ─────────────────────────────────────────────────────────────────
-- American double-zero wheel order (used only for animation flavour; the result is
-- a uniform random pocket, so the order does not affect fairness).

local ORDER = {
    "0","28","9","26","30","11","7","20","32","17","5","22","34","15","3","24","36",
    "13","1","00","27","10","25","29","12","8","19","31","18","6","21","33","16","4",
    "23","35","14","2",
}

-- Red numbers on a standard roulette wheel.
local REDS = {}
for _, n in ipairs({1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36}) do REDS[n] = true end

-- Build the pocket list: { label = "00", n = nil|0..36 }.
local POCKETS = {}
for i, label in ipairs(ORDER) do
    local n = (label == "00") and nil or tonumber(label)
    POCKETS[i] = { label = label, n = n }
end

-- bg colour + display name for a pocket. "Black" pockets render as gray so they
-- stay visible against the black monitor background.
local function pocketColor(p)
    if p.n == nil or p.n == 0 then return colors.green, "GREEN" end
    if REDS[p.n] then return colors.red, "RED" end
    return colors.gray, "BLACK"
end

local function dozenOf(n)  return math.ceil(n / 12) end           -- 1-12=1, 13-24=2, 25-36=3
local function columnOf(n) local m = n % 3; return (m == 0) and 3 or m end

-- ─── Peripherals ────────────────────────────────────────────────────────────────

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

-- ─── Game state ─────────────────────────────────────────────────────────────────

local STATE       = "INSERT"   -- INSERT | BET | SPINNING | RESULT
local playerID
local balance     = 0
local bets        = {}         -- list of { kind, sel, amount, key }
local selectedChip
local tab         = "NUMBERS"  -- NUMBERS | OUTSIDE (opens on the number grid)
local message     = ""
local lastResult                -- pocket table, for the RESULT screen
local lastWin     = 0           -- credits won on the last spin
local lastStaked  = 0           -- credits staked on the last spin
local buttons     = {}

local DEBOUNCE_MS = 300
local lastTouch   = 0

local GRID_Y      = 12          -- top row of the number board (BET screen + spin)

-- ─── Bank helpers ─────────────────────────────────────────────────────────────

local function refreshBalance()
    if not playerID then balance = 0; return end
    local ok, res = bankc.balance(playerID)
    if ok then balance = res else balance = 0; message = "Bank: " .. tostring(res) end
end

-- ─── Bet model ──────────────────────────────────────────────────────────────────

local function totalBet()
    local t = 0
    for _, b in ipairs(bets) do t = t + b.amount end
    return t
end

local function betOn(key)
    for _, b in ipairs(bets) do if b.key == key then return b.amount end end
    return 0
end

local function placeBet(kind, sel)
    local amt = selectedChip
    local cap = math.min(balance, CFG.MAX_BET)
    if totalBet() + amt > cap then message = "Over limit (" .. cap .. ")"; return end
    local key = kind .. ":" .. tostring(sel)
    for _, b in ipairs(bets) do
        if b.key == key then b.amount = b.amount + amt; message = ""; return end
    end
    bets[#bets + 1] = { kind = kind, sel = sel, amount = amt, key = key }
    message = ""
end

-- Win payout multiplier for one bet against the winning pocket.
-- Stake is already debited, so a win credits (odds + 1) x the bet; a loss credits 0.
local function creditMult(bet, p)
    local k = bet.kind
    if k == "number" then
        return (bet.sel == p.label) and 36 or 0   -- 35:1
    end
    -- Every even-money / dozen / column bet loses on 0 and 00.
    if p.n == nil or p.n == 0 then return 0 end
    local n = p.n
    if     k == "red"    then return REDS[n] and 2 or 0
    elseif k == "black"  then return (not REDS[n]) and 2 or 0
    elseif k == "even"   then return (n % 2 == 0) and 2 or 0
    elseif k == "odd"    then return (n % 2 == 1) and 2 or 0
    elseif k == "low"    then return (n >= 1 and n <= 18) and 2 or 0
    elseif k == "high"   then return (n >= 19 and n <= 36) and 2 or 0
    elseif k == "dozen"  then return (dozenOf(n) == bet.sel) and 3 or 0
    elseif k == "column" then return (columnOf(n) == bet.sel) and 3 or 0
    end
    return 0
end

local function resolve(p)
    local win = 0
    for _, b in ipairs(bets) do
        win = win + b.amount * creditMult(b, p)
    end
    return win
end

-- ─── Layout helpers ─────────────────────────────────────────────────────────────

-- Lay out a single row of evenly-spaced buttons across the full width.
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

-- Append the staked amount to an outside-bet label, e.g. "RED" -> "RED(25)".
local function lbl(text, key)
    local a = betOn(key)
    if a > 0 then return text .. "(" .. a .. ")" end
    return text
end

-- ─── Drawing: number grid (NUMBERS tab) ─────────────────────────────────────────

local function pocketByLabel(label)
    for _, p in ipairs(POCKETS) do if p.label == label then return p end end
end

-- Compute the rect for every pocket cell on the number board (0, 00, 1..36).
-- Returns an ordered list of { label, x, y, cw, ch, p }. Shared by the BET-screen
-- grid and the spin animation, so the ball lands on the exact board players bet on.
local function gridCells(y0)
    local w = mon.getSize()
    local cols = 12
    local cw = math.max(2, math.floor((w - 2) / cols))
    local ch = 2
    local gw = cw * cols
    local x0 = math.max(1, math.floor((w - gw) / 2) + 1)
    local cells = {}

    -- 0 / 00 row spanning the full grid width.
    local halfW = math.floor(gw / 2)
    cells[#cells + 1] = { label = "0",  x = x0,         y = y0, cw = halfW,      ch = ch, p = pocketByLabel("0")  }
    cells[#cells + 1] = { label = "00", x = x0 + halfW, y = y0, cw = gw - halfW, ch = ch, p = pocketByLabel("00") }

    -- 36 numbers: 12 columns x 3 rows. Top row = 3c, bottom row = 3c-2.
    local gy = y0 + ch + 1
    for c = 1, cols do
        for r = 1, 3 do
            local num = 3 * c - (r - 1)
            cells[#cells + 1] = {
                label = tostring(num), x = x0 + (c - 1) * cw, y = gy + (r - 1) * ch,
                cw = cw, ch = ch, p = pocketByLabel(tostring(num)),
            }
        end
    end
    return cells
end

-- Paint a single grid cell. `mode` = "normal" | "ball" | "win".
-- "normal" also overlays the player's stake on that number (yellow, 2nd row).
local function paintSpinCell(cell, mode)
    local bg, fg
    if mode == "ball" then
        bg, fg = colors.white, colors.black
    elseif mode == "win" then
        bg, fg = colors.yellow, colors.black
    else
        bg, fg = select(1, pocketColor(cell.p)), colors.white
    end
    ui.fillRect(mon, cell.x, cell.y, cell.cw, cell.ch, bg)
    mon.setBackgroundColor(bg)
    mon.setTextColor(fg)
    mon.setCursorPos(cell.x + math.max(0, math.floor((cell.cw - #cell.label) / 2)), cell.y)
    mon.write(cell.label)
    if mode == "normal" and cell.ch >= 2 then
        local staked = betOn("number:" .. cell.label)
        if staked > 0 then
            local amt = tostring(staked)
            mon.setTextColor(colors.yellow)
            mon.setCursorPos(cell.x + math.max(0, math.floor((cell.cw - #amt) / 2)), cell.y + cell.ch - 1)
            mon.write(amt)
        end
    end
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)
end

-- Draw the full number board and register each cell's touch button (BET screen).
local function drawNumberGrid(y0, out)
    for _, cell in ipairs(gridCells(y0)) do
        paintSpinCell(cell, "normal")
        out[#out + 1] = { x = cell.x, y = cell.y, w = cell.cw, h = cell.ch, id = "spot:number:" .. cell.label }
    end
end

-- ─── Drawing: outside bets (OUTSIDE tab) ────────────────────────────────────────

local function drawOutside(y0, out)
    local rowH = 3
    local function row(defs, y) for _, b in ipairs(rowButtons(defs, y, rowH)) do out[#out + 1] = b end end

    row({ { label = lbl("RED", "red:nil"),     id = "spot:red",   bg = colors.red },
          { label = lbl("BLACK", "black:nil"), id = "spot:black", bg = colors.gray } }, y0)
    row({ { label = lbl("EVEN", "even:nil"),   id = "spot:even",  bg = colors.blue },
          { label = lbl("ODD", "odd:nil"),     id = "spot:odd",   bg = colors.blue } }, y0 + rowH + 1)
    row({ { label = lbl("1-18", "low:nil"),    id = "spot:low",   bg = colors.cyan, fg = colors.black },
          { label = lbl("19-36", "high:nil"),  id = "spot:high",  bg = colors.cyan, fg = colors.black } }, y0 + (rowH + 1) * 2)
    row({ { label = lbl("DOZ1", "dozen:1"),    id = "spot:dozen:1", bg = colors.purple },
          { label = lbl("DOZ2", "dozen:2"),    id = "spot:dozen:2", bg = colors.purple },
          { label = lbl("DOZ3", "dozen:3"),    id = "spot:dozen:3", bg = colors.purple } }, y0 + (rowH + 1) * 3)
    row({ { label = lbl("COL1", "column:1"),   id = "spot:column:1", bg = colors.brown },
          { label = lbl("COL2", "column:2"),   id = "spot:column:2", bg = colors.brown },
          { label = lbl("COL3", "column:3"),   id = "spot:column:3", bg = colors.brown } }, y0 + (rowH + 1) * 4)
end

-- ─── Drawing: screens ───────────────────────────────────────────────────────────

local function draw()
    local w, h = mon.getSize()
    ui.clear(mon)
    buttons = {}

    if STATE == "INSERT" then
        ui.centerText(mon, 1, "R O U L E T T E", colors.yellow)
        ui.centerText(mon, math.floor(h / 2) - 1, "INSERT CARD", colors.red)
        ui.centerText(mon, math.floor(h / 2) + 1, "TO PLAY", colors.red)
        ui.centerText(mon, h, message, colors.gray)
        return
    end

    if STATE == "RESULT" then
        local p = lastResult
        local bg, name = pocketColor(p)
        ui.centerText(mon, 1, "R O U L E T T E", colors.yellow)
        local bw = math.min(w - 4, 14)
        local bx = math.floor((w - bw) / 2) + 1
        ui.fillRect(mon, bx, 3, bw, 3, bg)
        ui.centerText(mon, 4, p.label .. "  " .. name, colors.white, bg)
        ui.centerText(mon, 7, "Staked: " .. lastStaked, colors.gray)
        if lastWin > 0 then
            ui.centerText(mon, 9,  "YOU WON " .. lastWin .. "!", colors.lime)
            ui.centerText(mon, 10, "Net " .. (lastWin - lastStaked >= 0 and "+" or "") .. (lastWin - lastStaked), colors.lime)
        else
            ui.centerText(mon, 9, "No win this spin", colors.red)
        end
        ui.centerText(mon, 12, "BALANCE: " .. balance, colors.lime)
        ui.centerText(mon, h - 4, message, colors.yellow)
        buttons = rowButtons({
            { label = "BET AGAIN", id = "again", bg = colors.green },
            { label = "EJECT",     id = "eject", bg = colors.orange, fg = colors.black },
        }, h - 2, 3)
        return
    end

    -- BET (and the steady frame behind SPINNING is drawn by the animation itself)
    ui.centerText(mon, 1, "R O U L E T T E", colors.yellow)
    ui.text(mon, 2, 2, "BAL " .. balance, colors.lime)
    local tb = totalBet()
    local tbText = "BET " .. tb
    ui.text(mon, w - #tbText - 1, 2, tbText, (tb > 0) and colors.orange or colors.gray)
    ui.centerText(mon, 3, message, colors.gray)

    -- Chip selector
    local chipDefs = {}
    for _, c in ipairs(CFG.CHIPS) do
        chipDefs[#chipDefs + 1] = { label = tostring(c), id = "chip:" .. c,
                                    bg = (c == selectedChip) and colors.green or colors.blue }
    end
    for _, b in ipairs(rowButtons(chipDefs, 5, 3)) do buttons[#buttons + 1] = b end

    -- Tab toggle
    for _, b in ipairs(rowButtons({
        { label = "NUMBERS", id = "tab:NUMBERS", bg = (tab == "NUMBERS") and colors.lightBlue or colors.gray, fg = colors.black },
        { label = "OUTSIDE", id = "tab:OUTSIDE", bg = (tab == "OUTSIDE") and colors.lightBlue or colors.gray, fg = colors.black },
    }, 9, 2)) do buttons[#buttons + 1] = b end

    -- Board
    if tab == "OUTSIDE" then drawOutside(GRID_Y, buttons) else drawNumberGrid(GRID_Y, buttons) end

    -- Footer: CLEAR + SPIN
    local spinOK = tb >= CFG.MIN_BET and tb <= math.min(balance, CFG.MAX_BET)
    for _, b in ipairs(rowButtons({
        { label = "CLEAR", id = "clear", bg = colors.red },
        { label = "EJECT", id = "eject", bg = colors.orange, fg = colors.black },
        { label = "SPIN",  id = "spin",  bg = spinOK and colors.green or colors.gray },
    }, h - 2, 3)) do buttons[#buttons + 1] = b end
end

-- ─── Spin ───────────────────────────────────────────────────────────────────────

local function indexOfPocket(p)
    for i, q in ipairs(POCKETS) do if q == p then return i end end
    return 1
end

-- Repaint the banner row (above the grid) with the current/winning pocket.
local function spinBanner(text, color)
    local w = mon.getSize()
    ui.fillRect(mon, 1, 3, w, 1, colors.black)
    ui.centerText(mon, 3, text, color)
end

local function doSpin()
    local tb = totalBet()
    if not (tb >= CFG.MIN_BET and tb <= math.min(balance, CFG.MAX_BET)) then
        message = "Place a valid bet first"; return
    end

    local ok, res = bankc.debit(playerID, tb)
    if not ok then message = "Bet declined: " .. tostring(res); return end
    balance    = res
    lastStaked = tb
    STATE      = "SPINNING"

    -- Decide the result up front (fair — not influenced by the animation).
    local result = POCKETS[math.random(#POCKETS)]
    local n      = #POCKETS
    local target = indexOfPocket(result)
    local start  = math.random(n)
    local steps  = n * 2 + ((target - start) % n)   -- ~2 trips, lands exactly on `target`

    -- Draw the board once; the ball animates by repainting only changed cells.
    local cells = gridCells(GRID_Y)
    local cellByLabel = {}
    for _, c in ipairs(cells) do cellByLabel[c.label] = c end

    ui.clear(mon)
    ui.centerText(mon, 1, "R O U L E T T E", colors.yellow)
    for _, c in ipairs(cells) do paintSpinCell(c, "normal") end

    -- Ball hops in wheel order, easing out over the final stretch.
    local pos, prevCell = start, nil
    for i = 1, steps do
        pos = (pos % n) + 1
        local p = POCKETS[pos]
        if prevCell then paintSpinCell(prevCell, "normal") end
        local cell = cellByLabel[p.label]
        paintSpinCell(cell, "ball")
        prevCell = cell
        spinBanner("BALL  " .. p.label, (select(1, pocketColor(p))))

        local remaining = steps - i
        local delay = 0.04
        if remaining < 14 then delay = 0.04 + (14 - remaining) * 0.02 end
        sleep(delay)
    end

    -- Flash the winning cell.
    local winCell = cellByLabel[result.label]
    local _, name = pocketColor(result)
    for f = 1, 6 do
        paintSpinCell(winCell, (f % 2 == 1) and "win" or "ball")
        spinBanner("WINNER  " .. result.label .. "  " .. name, colors.yellow)
        sleep(0.18)
    end
    paintSpinCell(winCell, "win")
    sleep(0.8)

    -- Resolve every bet against the winning pocket.
    lastResult = result
    lastWin    = resolve(result)
    if lastWin > 0 then
        local pok, pres = bankc.credit(playerID, lastWin)
        if pok then balance = pres end
        message = "Winner: " .. result.label
    else
        message = ""
    end

    bets  = {}
    STATE = "RESULT"
end

-- ─── Game flow ──────────────────────────────────────────────────────────────────

local function startBetting()
    playerID = card.id(CFG.driveSide)
    if not playerID then STATE = "INSERT"; return end
    bets, message = {}, ""
    selectedChip = CFG.CHIPS[1]
    tab = "NUMBERS"
    refreshBalance()
    STATE = "BET"
end

local function handleTouch(id)
    if not id then return end

    -- EJECT works from any betting/result screen (bets are only debited at SPIN,
    -- so an un-spun board is simply discarded — no refund needed).
    if id == "eject" then
        card.eject(CFG.driveSide)
        STATE, message, bets = "INSERT", "", {}
        return
    end

    if STATE == "BET" then
        if id:match("^chip:") then
            selectedChip = tonumber(id:match("^chip:(%d+)"))
            message = ""
        elseif id == "tab:OUTSIDE" then tab = "OUTSIDE"
        elseif id == "tab:NUMBERS" then tab = "NUMBERS"
        elseif id == "clear" then bets, message = {}, ""
        elseif id == "spin" then doSpin()
        elseif id:match("^spot:") then
            local rest = id:sub(6)               -- strip "spot:"
            local kind, sel = rest:match("^([^:]+):?(.*)$")
            if sel == "" then sel = nil
            elseif kind ~= "number" then sel = tonumber(sel) end
            placeBet(kind, sel)
        end

    elseif STATE == "RESULT" then
        if id == "again" then
            if card.id(CFG.driveSide) then startBetting() else STATE = "INSERT" end
        end
    end
end

-- ─── Main loop ──────────────────────────────────────────────────────────────────

local function main()
    initPeripherals()
    math.randomseed(os.epoch("utc"))
    selectedChip = CFG.CHIPS[1]

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
            -- During SPINNING the stake is already committed; the spin finishes and
            -- pays the locked playerID. All other states return to INSERT.
            if STATE ~= "SPINNING" then
                STATE   = "INSERT"
                message = ""
            end
        end
    end
end

main()
