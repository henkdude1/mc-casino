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
}

-- ─── Symbols ──────────────────────────────────────────────────────────────────
-- weight = relative reel frequency (higher = appears more often)
-- mult3  = payout multiplier for three-of-a-kind

local SYMBOLS = {
    { name="SEVEN",  char="7", color=colors.red,     weight=2,  mult3=50 },
    { name="BELL",   char="*", color=colors.yellow,  weight=4,  mult3=15 },
    { name="CHERRY", char="C", color=colors.magenta, weight=7,  mult3=6  },
    { name="COIN",   char="$", color=colors.orange,  weight=9,  mult3=4  },
    { name="BAR",    char="=", color=colors.white,   weight=12, mult3=3  },
}

-- Build weighted pool once at load time.
local POOL = {}
for _, sym in ipairs(SYMBOLS) do
    for _ = 1, sym.weight do POOL[#POOL+1] = sym end
end

local function randSym() return POOL[math.random(#POOL)] end

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

local STATE   = "INSERT"
local playerID
local balance = 0
local bet     = 0
local staked  = 0
local message = ""
local reels   = { SYMBOLS[5], SYMBOLS[5], SYMBOLS[5] }  -- default display (BAR BAR BAR)
local buttons = {}

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
-- Three-of-a-kind pays sym.mult3; two sevens anywhere pays 5x.
local function getPayout(r1, r2, r3)
    if r1.name == r2.name and r2.name == r3.name then
        return r1.mult3
    end
    local sevens = 0
    for _, r in ipairs({r1, r2, r3}) do
        if r.name == "SEVEN" then sevens = sevens + 1 end
    end
    if sevens == 2 then return 5 end
    return 0
end

-- ─── Drawing ──────────────────────────────────────────────────────────────────

local REEL_W, REEL_H = 9, 5   -- outer reel box size in chars
local SYM_W,  SYM_H  = 5, 3   -- colored symbol box inside each reel

local function drawReel(x, y, sym)
    ui.fillRect(mon, x, y, REEL_W, REEL_H, colors.gray)
    local sx = x + math.floor((REEL_W - SYM_W) / 2)
    local sy = y + math.floor((REEL_H - SYM_H) / 2)
    ui.fillRect(mon, sx, sy, SYM_W, SYM_H, sym.color)
    mon.setBackgroundColor(sym.color)
    mon.setTextColor(colors.black)
    -- single char centered in the colored box
    mon.setCursorPos(sx + math.floor(SYM_W / 2), sy + math.floor(SYM_H / 2))
    mon.write(sym.char)
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)
end

local function drawAllReels(w, h, r1, r2, r3)
    local gap    = 2
    local totalW = REEL_W * 3 + gap * 2
    local startX = math.max(1, math.floor((w - totalW) / 2) + 1)
    -- Center reels vertically in the space between the header (row 4) and
    -- the info/button rows at the bottom (bottom 5 rows reserved).
    local reelY = math.max(4, math.min(math.floor((h - REEL_H) / 2), h - REEL_H - 5))
    drawReel(startX,                    reelY, r1)
    drawReel(startX + REEL_W + gap,     reelY, r2)
    drawReel(startX + REEL_W*2 + gap*2, reelY, r3)
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
    ui.centerText(mon, h - 5, "7x3=50x  *x3=15x  Cx3=6x  $x3=4x  =x3=3x  77=5x", colors.gray)
end

local function draw()
    local w, h = mon.getSize()
    ui.clear(mon)

    if STATE == "INSERT" then
        ui.centerText(mon, 1, "S  L  O  T  S", colors.yellow)
        ui.centerText(mon, math.floor(h / 2) - 1, "INSERT CARD", colors.red)
        ui.centerText(mon, math.floor(h / 2) + 1, "TO PLAY", colors.red)
        ui.centerText(mon, h, message, colors.gray)
        buttons = {}

    elseif STATE == "BET" then
        ui.centerText(mon, 1, "S  L  O  T  S", colors.yellow)
        ui.centerText(mon, 3, "BALANCE: " .. balance .. "  BET: " .. bet, colors.lime)
        drawAllReels(w, h, reels[1], reels[2], reels[3])
        drawPaytableHint(h)
        ui.centerText(mon, h - 4, message, colors.gray)

        local defs = {}
        for _, chip in ipairs(CFG.CHIPS) do
            defs[#defs+1] = { label="+"..chip, id="chip:"..chip, bg=colors.blue }
        end
        defs[#defs+1] = { label="CLEAR", id="clear", bg=colors.red }
        local spinOK = bet >= CFG.MIN_BET and bet <= balance
        defs[#defs+1] = { label="SPIN", id="spin", bg=spinOK and colors.green or colors.gray }
        buttons = rowButtons(defs, h - 2, 3)

    elseif STATE == "RESULT" then
        ui.centerText(mon, 1, "S  L  O  T  S", colors.yellow)
        ui.centerText(mon, 3, "BALANCE: " .. balance .. "  BET: " .. bet, colors.lime)
        drawAllReels(w, h, reels[1], reels[2], reels[3])
        drawPaytableHint(h)
        ui.centerText(mon, h - 4, message, colors.yellow)
        buttons = rowButtons({ { label="SPIN AGAIN", id="again", bg=colors.green } }, h - 2, 3)
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

local function doSpin()
    local spinOK = bet >= CFG.MIN_BET and bet <= balance
    if not spinOK then message = "Set a valid bet first"; return end

    local ok, res = bankc.debit(playerID, bet)
    if not ok then message = "Bet declined: " .. tostring(res); return end
    balance = res
    staked  = bet

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

    if payout > 0 then
        local pok, pres = bankc.credit(playerID, payout)
        if pok then balance = pres end
        if mult >= 50 then
            message = "JACKPOT!  7 7 7  +" .. payout .. " credits!"
        else
            message = "WIN!  x" .. mult .. "  =  +" .. payout .. " credits"
        end
    else
        message = "No win — try again!"
    end

    STATE = "RESULT"
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
        elseif id == "spin" then
            doSpin()
        end

    elseif STATE == "RESULT" then
        if id == "again" then
            if card.id(CFG.driveSide) then
                startBetting()
            else
                STATE = "INSERT"
            end
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
