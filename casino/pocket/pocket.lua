-- TEXAS HOLD'EM POCKET CLIENT
-- Runs on an Advanced Pocket Computer with a wireless modem. This is the ONLY
-- device that ever sees your hole cards: they arrive sealed and are decrypted
-- here with a per-session key derived from this pocket's device key. Hold it in
-- your hand like real cards — nothing private is ever drawn on the shared board.
--
-- Pocket terminals are keyboard-driven (no touch), so actions use letter keys.

local crypto = require("lib.crypto")
local pp     = require("lib.pokerproto")
local ui     = require("lib.ui")

local DEVKEY_FILE = "devicekey"

-- ─── Identity / session ───────────────────────────────────────────────────────

local pocketId = os.getComputerID()
local deviceKey
local sessionKey
local mySeat

local hole       = nil    -- our two hole cards (private)
local pub        = { community = {}, pot = 0, seats = {}, banner = "" }
local lastResult = nil

local function loadDeviceKey()
    assert(fs.exists(DEVKEY_FILE), "No device key. Re-run the pocket installer.")
    local f = fs.open(DEVKEY_FILE, "r"); deviceKey = f.readAll():gsub("%s+$", ""); f.close()
    assert(#deviceKey > 0, "Empty device key file")
end

local function findTable()
    return rednet.lookup(pp.PROTOCOL, pp.HOSTNAME)
end

-- ─── Rendering (compact, for a 26-wide pocket terminal) ───────────────────────

local function draw()
    ui.clear(term)
    local w, h = term.getSize()
    ui.centerText(term, 1, "HOLD'EM  seat " .. (mySeat or "-"), colors.yellow)

    -- our hole cards
    if hole then
        ui.card(term, 2, 3, hole[1].rank, hole[1].suit, true)
        ui.card(term, 9, 3, hole[2].rank, hole[2].suit, true)
    else
        ui.text(term, 2, 4, "(no cards yet)", colors.gray)
    end

    -- community + pot
    local board = ""
    for _, c in ipairs(pub.community or {}) do board = board .. c.rank .. c.suit .. " " end
    ui.text(term, 2, 8, "Board: " .. (board == "" and "-" or board), colors.lime)
    ui.text(term, 2, 9, "Pot:   " .. (pub.pot or 0), colors.lime)

    -- our stack
    local me
    for _, s in ipairs(pub.seats or {}) do if s.seat == mySeat then me = s end end
    if me then
        ui.text(term, 2, 10, "Stack: " .. me.stack .. "  bet " .. (me.bet or 0),
            me.isTurn and colors.yellow or colors.white)
    end

    if lastResult then ui.text(term, 2, 12, lastResult, colors.orange) end
    ui.centerText(term, h, pub.banner or "", colors.gray)
end

-- ─── Join handshake ───────────────────────────────────────────────────────────

local function joinFlow()
    while not sessionKey do
        term.clear(); term.setCursorPos(1, 1)
        print("=== HOLD'EM POCKET ===")
        print("Pocket id: " .. pocketId)
        print("Insert your bank card at the table,")
        print("then enter the PIN it shows.")
        io.write("PIN: ")
        local pin = read()
        local tableId = findTable()
        if not tableId then print("Table offline. Retrying..."); sleep(1)
        else
            local nonce = crypto.sha256(tostring(os.epoch("utc")) .. tostring(math.random()))
            local mac = crypto.hmac(deviceKey, pin .. ":" .. nonce .. ":" .. tostring(pocketId))
            rednet.send(tableId, { kind = "join", pocketId = pocketId, pin = pin, nonce = nonce, mac = mac }, pp.PROTOCOL)
            local _, reply = rednet.receive(pp.PROTOCOL, 5)
            if type(reply) == "table" and reply.kind == "joined" and reply.ok then
                sessionKey = crypto.deriveKey(deviceKey, reply.sessionNonce)
                mySeat = reply.seat
                print("Seated at seat " .. mySeat .. ". Good luck!")
                sleep(1)
            elseif type(reply) == "table" and reply.kind == "joined" then
                print("Join failed: " .. tostring(reply.reason)); sleep(2)
            else
                print("No response from table."); sleep(2)
            end
        end
    end
end

-- ─── Action prompt ────────────────────────────────────────────────────────────
-- Blocking interaction for our turn. Keeps absorbing public state in the
-- background so the board stays live while we decide.

local function takeTurn(turn)
    local toCall   = turn.toCall or 0
    local minRaise = turn.minRaise or 0
    local stack    = turn.stack or 0
    local currentBet = turn.currentBet or 0
    local raiseTo  = currentBet + minRaise
    local function drawPrompt()
        draw()
        local _, h = term.getSize()
        local y = 13
        ui.text(term, 2, y,   "YOUR TURN", colors.yellow)
        ui.text(term, 2, y+1, "[F]old", colors.red)
        if toCall == 0 then ui.text(term, 9, y+1, "[C]heck", colors.green)
        else ui.text(term, 9, y+1, "[C]all " .. toCall, colors.green) end
        ui.text(term, 2, y+2, "[R]aise to " .. raiseTo .. "  (+/-)", colors.cyan)
        ui.text(term, 2, y+3, "[A]ll-in " .. stack, colors.orange)
        ui.text(term, 2, y+4, "Enter = confirm raise", colors.gray)
    end
    drawPrompt()

    while true do
        local ev = { os.pullEvent() }
        if ev[1] == "char" then
            local ch = ev[2]:lower()
            if ch == "f" then return { move = "fold" }
            elseif ch == "c" then return { move = (toCall == 0) and "check" or "call" }
            elseif ch == "a" then return { move = "allin" }
            elseif ch == "r" then return { move = "raise", amount = raiseTo }
            elseif ch == "+" or ch == "=" then
                raiseTo = math.min(raiseTo + math.max(minRaise, 1), currentBet + stack)
                drawPrompt()
            elseif ch == "-" then
                raiseTo = math.max(currentBet + minRaise, raiseTo - math.max(minRaise, 1))
                drawPrompt()
            end
        elseif ev[1] == "key" and ev[2] == keys.enter then
            return { move = "raise", amount = raiseTo }
        elseif ev[1] == "rednet_message" and ev[4] == pp.PROTOCOL and type(ev[3]) == "table" then
            -- keep the board fresh while deciding, but the turn is still ours
            local msg = ev[3]
            if msg.kind == "state" then pub = msg; drawPrompt() end
        end
    end
end

-- ─── Main loop ────────────────────────────────────────────────────────────────

local function run()
    loadDeviceKey()
    pp.open()
    math.randomseed(os.epoch("utc") + pocketId)
    joinFlow()
    draw()

    while true do
        local ev = { os.pullEvent() }
        if ev[1] == "char" and ev[2]:lower() == "q" and not hole then
            -- Cash out between hands (ignored while we hold live cards).
            local tid = findTable()
            if tid then rednet.send(tid, { kind = "cashout", pocketId = pocketId }, pp.PROTOCOL) end
            pub.banner = "Cash-out requested..."; draw()
        elseif ev[1] == "rednet_message" then
            local sender, msg, proto = ev[2], ev[3], ev[4]
            if proto == pp.PROTOCOL and type(msg) == "table" then
                if msg.kind == "state" then
                    pub = msg; draw()
                elseif msg.kind == "deal" then
                    local opened = pp.openTable(sessionKey, msg.sealed)
                    if opened and opened.hole then
                        hole = opened.hole
                        mySeat = opened.seat or mySeat
                        lastResult = nil
                        draw()
                    end
                elseif msg.kind == "turn" and msg.seat == mySeat then
                    local action = takeTurn(msg)
                    action.kind = "action"; action.pocketId = pocketId
                    rednet.send(sender, action, pp.PROTOCOL)
                elseif msg.kind == "result" then
                    -- keep showing our hole cards until the next deal
                    local mine = ""
                    for _, r in ipairs(msg.results or {}) do
                        if r.seat == mySeat then mine = "You won " .. r.won .. " (" .. r.hand .. ")" end
                    end
                    lastResult = (mine ~= "") and mine or "Hand over"
                    pub.community = msg.community or pub.community
                    draw()
                elseif msg.kind == "busted" then
                    lastResult = "Busted out. Re-buy at the table."
                    hole, sessionKey, mySeat = nil, nil, nil
                    draw(); joinFlow(); draw()
                elseif msg.kind == "cashedout" then
                    term.clear(); term.setCursorPos(1, 1)
                    print("Cashed out " .. (msg.amount or 0) .. " credits.")
                    print("Thanks for playing!")
                    return
                end
            end
        end
    end
end

run()
