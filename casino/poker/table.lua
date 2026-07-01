-- TEXAS HOLD'EM TABLE SERVER (the dealer)
-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ HARDWARE — edit CFG below to match your build.                            │
-- │   • Advanced Monitor (public board) ............... monitorName           │
-- │   • Disk drive (floppy buy-in)  ................... driveSide             │
-- │   • Wireless modem, ENDER recommended (reaches pockets anywhere)          │
-- │   • Bank server running with a matching SECRET in lib/protocol.lua        │
-- │                                                                           │
-- │ The monitor shows ONLY public state. Hole cards never touch this screen — │
-- │ they are sealed and sent to each player's pocket computer. The server is  │
-- │ the sole authority: it shuffles, validates every action, and computes the │
-- │ pots. Pockets only send intents.                                          │
-- └─────────────────────────────────────────────────────────────────────────┘

local bankc  = require("lib.bankclient")
local card   = require("lib.card")
local ui     = require("lib.ui")
local crypto = require("lib.crypto")
local holdem = require("lib.holdem")
local pp     = require("lib.pokerproto")

local CFG = {
    monitorName  = "",        -- exact monitor name; "" = auto-find
    driveSide    = "left",    -- disk drive side for buy-in
    monitorScale = 0.5,       -- 0.5 suits a larger board monitor
    SEATS        = 6,
    SMALL_BLIND  = 5,
    BIG_BLIND    = 10,
    MIN_BUYIN    = 100,
    MAX_BUYIN    = 2000,
    DEFAULT_BUYIN= 500,
    BUYIN_STEP   = 100,
    ACTION_TIMEOUT = 30,      -- seconds before auto check/fold
    START_DELAY  = 6,         -- seconds from "enough players" to dealing
}

local DEVICES_DB = "devices.db"   -- { [pocketId]=deviceKey } authorized pockets
local SEATS_DB   = "seats.db"     -- crash-recovery snapshot of live chip stacks

-- ─── State ────────────────────────────────────────────────────────────────────

local mon, monName
local seats   = {}     -- index -> seat table | nil
local button  = 0      -- seat index of the dealer button
local community = {}   -- shared cards on the board
local devices = {}     -- pocketId(string) -> deviceKey
local pendingPair = {} -- pin(string) -> { seat=index }
local cashoutQueue = {}-- pocketId -> true, processed between hands
local banner  = "Waiting for players..."
local inHand  = false  -- true during a hand: defer buy-ins so they can't block play

-- ─── Peripherals & persistence ────────────────────────────────────────────────

local function initPeripherals()
    pp.open()
    bankc.open()
    if CFG.monitorName and CFG.monitorName ~= "" then
        mon = peripheral.wrap(CFG.monitorName)
        assert(mon, "Monitor not found: " .. CFG.monitorName)
        monName = CFG.monitorName
    else
        mon = peripheral.find("monitor")
        assert(mon, "No monitor found — attach an Advanced Monitor")
        monName = peripheral.getName(mon)
    end
    assert(mon.isColor and mon.isColor(), "Monitor must be an Advanced (color) Monitor")
    mon.setTextScale(CFG.monitorScale)
end

local function loadDevices()
    if fs.exists(DEVICES_DB) then
        local f = fs.open(DEVICES_DB, "r"); local raw = f.readAll(); f.close()
        devices = textutils.unserialize(raw) or {}
    end
end

local function persistSeats()
    local snap = {}
    for i, s in pairs(seats) do
        snap[i] = { accountId = s.accountId, pocketId = s.pocketId, stack = s.stack }
    end
    local f = fs.open(SEATS_DB, "w"); f.write(textutils.serialize(snap)); f.close()
end

-- On boot, refund any stranded chip stacks back to their bank accounts. We can't
-- resume a hand that was in progress when the server died, so the safe move is to
-- return every snapshotted stack and start clean. (Buy-ins debit the bank up front,
-- so without this a crash would vaporise players' chips.)
local function recoverStrandedChips()
    if not fs.exists(SEATS_DB) then return end
    local f = fs.open(SEATS_DB, "r"); local raw = f.readAll(); f.close()
    local snap = textutils.unserialize(raw) or {}
    for _, s in pairs(snap) do
        if s.accountId and (s.stack or 0) > 0 then
            local ok = bankc.credit(s.accountId, s.stack)
            print(("[recover] refunded %d to account %s -> %s")
                :format(s.stack, tostring(s.accountId), ok and "ok" or "FAILED"))
        end
    end
    fs.delete(SEATS_DB)
end

-- ─── Messaging ────────────────────────────────────────────────────────────────

local function sendPocket(pocketId, msg)
    if pocketId then rednet.send(pocketId, msg, pp.PROTOCOL) end
end

-- Build the PUBLIC table state. By construction this never includes hole cards.
local function publicState(activeSeat)
    local list = {}
    for i = 1, CFG.SEATS do
        local s = seats[i]
        if s then
            list[#list + 1] = {
                seat = i, stack = s.stack, bet = s.committedRound or 0,
                status = s.status, isButton = (i == button),
                isTurn = (i == activeSeat), hasCards = (s.hole ~= nil),
            }
        end
    end
    local pot = 0
    for _, s in pairs(seats) do pot = pot + (s.committedHand or 0) end
    return { kind = "state", community = community, pot = pot, seats = list, banner = banner }
end

local function broadcastState(activeSeat)
    rednet.broadcast(publicState(activeSeat), pp.PROTOCOL)
end

-- ─── Rendering (public board only) ────────────────────────────────────────────

local CARD_W = 5

local function drawCommunity(w)
    local n = #community
    local totalW = 5 * CARD_W + 4
    local x0 = math.max(2, math.floor((w - totalW) / 2) + 1)
    for i = 1, 5 do
        local c = community[i]
        if c then
            ui.card(mon, x0 + (i - 1) * (CARD_W + 1), 4, c.rank, c.suit, true)
        else
            ui.fillRect(mon, x0 + (i - 1) * (CARD_W + 1), 4, CARD_W, 4, colors.green)
        end
    end
end

local function statusColor(st)
    if st == "folded" then return colors.gray
    elseif st == "allin" then return colors.orange
    elseif st == "sitout" then return colors.lightGray
    else return colors.white end
end

local function render(activeSeat)
    ui.clear(mon)
    local w, h = mon.getSize()
    ui.centerText(mon, 1, "TEXAS HOLD'EM  -  $" .. CFG.SMALL_BLIND .. "/$" .. CFG.BIG_BLIND, colors.yellow)

    drawCommunity(w)

    local pot = 0
    for _, s in pairs(seats) do pot = pot + (s.committedHand or 0) end
    ui.centerText(mon, 9, "POT: " .. pot, colors.lime)

    -- seat rows
    local row = 11
    for i = 1, CFG.SEATS do
        local s = seats[i]
        local label
        if s then
            local tag = (i == button) and "(D) " or "    "
            local turn = (i == activeSeat) and " <-- " or ""
            label = string.format("%sSeat %d  stack %-5d  bet %-4d  %s%s",
                tag, i, s.stack, s.committedRound or 0, s.status, turn)
            ui.text(mon, 2, row, label, (i == activeSeat) and colors.yellow or statusColor(s.status))
        else
            ui.text(mon, 2, row, string.format("    Seat %d  (empty)", i), colors.gray)
        end
        row = row + 1
    end

    ui.centerText(mon, h, banner, colors.white)
end

-- ─── Pairing / buy-in ─────────────────────────────────────────────────────────

local function emptySeat()
    for i = 1, CFG.SEATS do if not seats[i] then return i end end
    return nil
end

-- Blocking buy-in amount selector on the (public) monitor. Returns amount | nil.
local function selectBuyin(maxAffordable)
    local amount = math.min(CFG.DEFAULT_BUYIN, maxAffordable)
    while true do
        ui.clear(mon)
        local w, h = mon.getSize()
        ui.centerText(mon, 2, "BUY IN", colors.yellow)
        ui.centerText(mon, 4, "Bank balance: " .. maxAffordable, colors.lime)
        ui.centerText(mon, 6, "Amount: " .. amount, colors.white)
        local btns = {}
        btns[#btns+1] = ui.button(mon, 2,        9, 8, 3, "-" .. CFG.BUYIN_STEP, colors.red,    nil, "minus")
        btns[#btns+1] = ui.button(mon, w-9,      9, 8, 3, "+" .. CFG.BUYIN_STEP, colors.blue,   nil, "plus")
        btns[#btns+1] = ui.button(mon, 2,        h-3, 10, 3, "CANCEL",  colors.gray,   nil, "cancel")
        local okColor = (amount >= CFG.MIN_BUYIN and amount <= maxAffordable) and colors.green or colors.gray
        btns[#btns+1] = ui.button(mon, w-11,     h-3, 10, 3, "CONFIRM", okColor,       nil, "confirm")
        local ev
        repeat ev = { os.pullEvent("monitor_touch") } until ev[2] == monName
        local id = ui.hit(btns, ev[3], ev[4])
        if id == "minus" then amount = math.max(CFG.MIN_BUYIN, amount - CFG.BUYIN_STEP)
        elseif id == "plus" then amount = math.min(maxAffordable, amount + CFG.BUYIN_STEP)
        elseif id == "cancel" then return nil
        elseif id == "confirm" and amount >= CFG.MIN_BUYIN and amount <= maxAffordable then
            return amount
        end
    end
end

-- A floppy was inserted: read the account, take a buy-in, seat the player, and
-- show a pairing PIN. The player then enters that PIN on their pocket to bind.
local function handleBuyIn()
    local accountId = card.id(CFG.driveSide)
    if not accountId then return end
    local seatIdx = emptySeat()
    if not seatIdx then banner = "Table full"; return end

    local ok, bal = bankc.balance(accountId)
    if not ok then banner = "Bank error: " .. tostring(bal); card.eject(CFG.driveSide); return end
    if bal < CFG.MIN_BUYIN then banner = "Need at least " .. CFG.MIN_BUYIN .. " to sit"; card.eject(CFG.driveSide); return end

    local amount = selectBuyin(math.min(bal, CFG.MAX_BUYIN))
    if not amount then card.eject(CFG.driveSide); return end

    local dok, res = bankc.debit(accountId, amount)
    if not dok then banner = "Buy-in declined: " .. tostring(res); card.eject(CFG.driveSide); return end

    seats[seatIdx] = {
        accountId = accountId, pocketId = nil, sessionKey = nil,
        stack = amount, committedRound = 0, committedHand = 0,
        status = "sitout", hole = nil,
    }
    persistSeats()
    card.eject(CFG.driveSide)

    local pin = string.format("%04d", math.random(0, 9999))
    pendingPair[pin] = { seat = seatIdx }
    banner = ("Seat %d: enter PIN %s on your pocket"):format(seatIdx, pin)
end

-- A pocket sent a join with a PIN. Authenticate it against the device registry.
local function handleJoin(sender, msg)
    local pend = msg.pin and pendingPair[msg.pin]
    if not pend then sendPocket(sender, { kind = "joined", ok = false, reason = "bad PIN" }); return end

    local deviceKey = devices[tostring(msg.pocketId)]
    if not deviceKey then
        sendPocket(sender, { kind = "joined", ok = false, reason = "device not registered" }); return
    end
    -- Proof the pocket holds the device key (which never travels the wire).
    local expect = crypto.hmac(deviceKey, (msg.pin or "") .. ":" .. (msg.nonce or "") .. ":" .. tostring(msg.pocketId))
    if expect ~= msg.mac then
        sendPocket(sender, { kind = "joined", ok = false, reason = "auth failed" }); return
    end

    local s = seats[pend.seat]
    if not s then pendingPair[msg.pin] = nil; return end
    local sessionNonce = crypto.sha256(tostring(os.epoch("utc")) .. ":" .. tostring(math.random()))
    s.pocketId   = msg.pocketId
    s.sessionKey = crypto.deriveKey(deviceKey, sessionNonce)
    s.status     = "sitout"   -- joins the next hand
    pendingPair[msg.pin] = nil
    banner = ("Seat %d paired — dealing soon"):format(pend.seat)
    sendPocket(sender, { kind = "joined", ok = true, seat = pend.seat, sessionNonce = sessionNonce, stack = s.stack })
end

-- ─── Cash out ─────────────────────────────────────────────────────────────────

local function processCashouts()
    for pocketId in pairs(cashoutQueue) do
        for i, s in pairs(seats) do
            if s.pocketId == pocketId then
                if s.stack > 0 then bankc.credit(s.accountId, s.stack) end
                sendPocket(pocketId, { kind = "cashedout", amount = s.stack })
                seats[i] = nil
            end
        end
    end
    cashoutQueue = {}
    persistSeats()
end

-- ─── Background event handling ────────────────────────────────────────────────
-- Used while idle and while awaiting a player's action. Returns an "action"
-- message table only when it matches the seat we're currently waiting on.

local function dispatch(ev, awaitPocketId)
    local name = ev[1]
    if name == "rednet_message" then
        local sender, msg, proto = ev[2], ev[3], ev[4]
        if proto == pp.PROTOCOL and type(msg) == "table" then
            if msg.kind == "join" then
                handleJoin(sender, msg)
            elseif msg.kind == "cashout" then
                cashoutQueue[msg.pocketId] = true
            elseif msg.kind == "action" then
                if awaitPocketId and msg.pocketId == awaitPocketId then return msg end
            end
        end
    elseif name == "disk" then
        -- Only seat new players between hands; mid-hand the buy-in dialog would
        -- block the action. The disk just waits in the drive until the lobby.
        if not inHand then handleBuyIn() end
    end
    return nil
end

-- ─── Hand flow helpers ────────────────────────────────────────────────────────

local function seatedOrder()  -- indices that will play this hand
    local out = {}
    for i = 1, CFG.SEATS do
        local s = seats[i]
        if s and s.sessionKey and s.stack > 0 then out[#out + 1] = i end
    end
    return out
end

-- circular sequence of seat indices starting just AFTER `from`
local function seqAfter(order, from)
    local seq = {}
    -- find position of `from` in order, then walk forward
    local pos
    for idx, v in ipairs(order) do if v == from then pos = idx break end end
    if not pos then pos = #order end
    for k = 1, #order do
        seq[#seq + 1] = order[((pos - 1 + k) % #order) + 1]
    end
    return seq
end

local function commit(s, amt)
    amt = math.min(amt, s.stack)
    s.stack = s.stack - amt
    s.committedRound = s.committedRound + amt
    s.committedHand  = s.committedHand + amt
    if s.stack == 0 and (s.status == "active" or s.status == "sitout") then s.status = "allin" end
    return amt
end

local function inHandCount()
    local n = 0
    for _, s in pairs(seats) do if s.status == "active" or s.status == "allin" then n = n + 1 end end
    return n
end

local function activeCanActCount()
    local n = 0
    for _, s in pairs(seats) do if s.status == "active" and s.stack > 0 then n = n + 1 end end
    return n
end

-- Ask one seat for its action. Returns move,amount with the move validated.
local function awaitAction(seatIdx, currentBet, minRaise)
    local s = seats[seatIdx]
    local toCall = currentBet - s.committedRound
    sendPocket(s.pocketId, {
        kind = "turn", seat = seatIdx, toCall = toCall, minRaise = minRaise,
        stack = s.stack, currentBet = currentBet, timeout = CFG.ACTION_TIMEOUT,
    })
    broadcastState(seatIdx)
    render(seatIdx)

    local timer = os.startTimer(CFG.ACTION_TIMEOUT)
    while true do
        local ev = { os.pullEvent() }
        if ev[1] == "timer" and ev[2] == timer then
            return (toCall == 0) and "check" or "fold", 0   -- auto act on timeout
        end
        local act = dispatch(ev, s.pocketId)
        if act then
            local move = act.move
            local amount = tonumber(act.amount) or 0
            if move == "fold" then return "fold", 0
            elseif move == "check" and toCall == 0 then return "check", 0
            elseif move == "call" then return "call", math.min(toCall, s.stack)
            elseif move == "allin" then return "allin", s.stack
            elseif move == "raise" then
                -- amount is the TOTAL this player wants committed this round (the raise-to).
                local raiseTo = amount
                local minTo = currentBet + minRaise
                if raiseTo >= minTo and (raiseTo - s.committedRound) <= s.stack then
                    return "raise", raiseTo
                elseif (raiseTo - s.committedRound) >= s.stack then
                    return "allin", s.stack          -- treat an over-the-top as all-in
                end
                -- illegal raise: re-prompt the same player
                sendPocket(s.pocketId, { kind = "turn", seat = seatIdx, toCall = toCall,
                    minRaise = minRaise, stack = s.stack, currentBet = currentBet,
                    timeout = CFG.ACTION_TIMEOUT, note = "illegal raise" })
            end
        end
    end
end

-- Return uncalled chips when one player has out-committed everyone else this street.
local function refundUncalled(seq)
    local top, second, topSeat = -1, -1, nil
    for _, i in ipairs(seq) do
        local c = seats[i] and seats[i].committedRound or 0
        if c > top then second = top; top = c; topSeat = i
        elseif c > second then second = c end
    end
    if topSeat and top > second then
        local refund = top - second
        local s = seats[topSeat]
        s.stack = s.stack + refund
        s.committedRound = s.committedRound - refund
        s.committedHand  = s.committedHand - refund
        if s.status == "allin" and s.stack > 0 then s.status = "active" end
    end
end

-- Run one betting round over `seq` (already ordered from first-to-act).
-- Returns false if the hand is over (everyone folded but one), true otherwise.
local function bettingRound(seq, currentBet, minRaise)
    for _, i in ipairs(seq) do if seats[i] then seats[i].acted = false end end

    local n = #seq
    local k = 0
    while true do
        if inHandCount() <= 1 then refundUncalled(seq); return false end
        if activeCanActCount() == 0 then break end  -- everyone remaining is all-in

        local i = seq[(k % n) + 1]
        k = k + 1
        local s = seats[i]
        if s and s.status == "active" and s.stack > 0 then
            local need = currentBet - s.committedRound
            if not (s.acted and need == 0) then
                local move, amount = awaitAction(i, currentBet, minRaise)
                if move == "fold" then
                    s.status = "folded"
                elseif move == "check" then
                    s.acted = true
                elseif move == "call" then
                    commit(s, currentBet - s.committedRound)
                    s.acted = true
                elseif move == "raise" then
                    local prevBet = currentBet
                    commit(s, amount - s.committedRound)
                    currentBet = amount
                    minRaise = math.max(minRaise, amount - prevBet)
                    for _, j in ipairs(seq) do if seats[j] and seats[j].status == "active" then seats[j].acted = false end end
                    s.acted = true
                elseif move == "allin" then
                    local prevBet = currentBet
                    commit(s, s.stack)
                    if s.committedRound > prevBet then
                        currentBet = s.committedRound
                        minRaise = math.max(minRaise, currentBet - prevBet)
                        for _, j in ipairs(seq) do if seats[j] and seats[j].status == "active" then seats[j].acted = false end end
                    end
                    s.acted = true
                end
                broadcastState(); render()
            end
        end

        -- round complete? every active seat has acted and matched the bet
        local complete = true
        for _, j in ipairs(seq) do
            local sj = seats[j]
            if sj and sj.status == "active" then
                if not (sj.acted and sj.committedRound == currentBet) then complete = false break end
            end
        end
        if complete then break end
    end
    refundUncalled(seq)
    return true
end

local function collectStreet(order)
    for _, i in ipairs(order) do if seats[i] then seats[i].committedRound = 0 end end
end

local function burnDeal(deck, n)
    table.remove(deck)  -- burn one
    for _ = 1, n do community[#community + 1] = holdem.draw(deck) end
end

local function handNameOf(tuple)
    local names = { "High Card", "Pair", "Two Pair", "Trips", "Straight", "Flush", "Full House", "Quads", "Straight Flush" }
    return names[tuple[1]] or "?"
end

-- ─── One hand ─────────────────────────────────────────────────────────────────

local function playHand()
    local order = seatedOrder()
    if #order < 2 then return end
    inHand = true

    -- advance the button to the next seated player
    button = seqAfter(order, button)[1]

    -- reset hand state
    community = {}
    for _, i in ipairs(order) do
        local s = seats[i]
        s.committedRound, s.committedHand, s.status, s.hole, s.acted = 0, 0, "active", nil, false
    end

    local deck = holdem.newDeck()

    -- blinds
    local heads = (#order == 2)
    local sbSeat, bbSeat
    local afterBtn = seqAfter(order, button)
    if heads then sbSeat, bbSeat = button, afterBtn[1]
    else sbSeat, bbSeat = afterBtn[1], afterBtn[2] end
    commit(seats[sbSeat], CFG.SMALL_BLIND)
    commit(seats[bbSeat], CFG.BIG_BLIND)

    -- deal two hole cards each, sealed to each pocket
    for _, i in ipairs(order) do
        seats[i].hole = { holdem.draw(deck), holdem.draw(deck) }
    end
    for _, i in ipairs(order) do
        local s = seats[i]
        sendPocket(s.pocketId, { kind = "deal", sealed = pp.sealTable(s.sessionKey, { hole = s.hole, seat = i }) })
    end
    banner = "Hand in play"
    persistSeats()

    -- ── PRE-FLOP ── first to act is left of BB (in heads-up that's the button)
    local preSeq = seqAfter(order, bbSeat)
    bettingRound(preSeq, CFG.BIG_BLIND, CFG.BIG_BLIND)
    collectStreet(order)

    -- ── FLOP / TURN / RIVER ──
    local streets = { { name = "FLOP", n = 3 }, { name = "TURN", n = 1 }, { name = "RIVER", n = 1 } }
    for _, st in ipairs(streets) do
        if inHandCount() <= 1 then break end
        burnDeal(deck, st.n)
        broadcastState(); render()
        if activeCanActCount() >= 2 then
            banner = st.name
            local postSeq = seqAfter(order, button)  -- first active left of button
            bettingRound(postSeq, 0, CFG.BIG_BLIND)
            collectStreet(order)
        end
    end

    -- ── SHOWDOWN / PAYOUT ──
    local contenders = {}
    for _, i in ipairs(order) do
        if seats[i].status ~= "folded" then contenders[#contenders + 1] = i end
    end

    local win, handBySeat, results, reveal = {}, {}, {}, {}

    if #contenders == 1 then
        -- Everyone else folded: the last player standing takes the whole pot
        -- without a showdown (and without needing 5 community cards).
        local pot = 0
        for _, i in ipairs(order) do pot = pot + seats[i].committedHand end
        local w = contenders[1]
        win[w] = pot
        seats[w].stack = seats[w].stack + pot
        results[#results + 1] = { seat = w, won = pot, hand = "uncontested" }
    else
        local contrib, folded = {}, {}
        for _, i in ipairs(order) do
            local s = seats[i]
            contrib[i] = s.committedHand
            if s.status == "folded" then
                folded[i] = true
            else
                local seven = { s.hole[1], s.hole[2] }
                for _, c in ipairs(community) do seven[#seven + 1] = c end
                handBySeat[i] = holdem.evaluate7(seven)
            end
        end
        win = holdem.awardPots(holdem.buildPots(contrib, folded), handBySeat)
        for i, amt in pairs(win) do
            seats[i].stack = seats[i].stack + amt
            results[#results + 1] = { seat = i, won = amt, hand = handNameOf(handBySeat[i]) }
        end
        -- reveal every player who reached showdown (public information)
        for _, i in ipairs(contenders) do
            reveal[#reveal + 1] = { seat = i, hole = seats[i].hole, hand = handNameOf(handBySeat[i]) }
        end
    end
    persistSeats()

    rednet.broadcast({ kind = "result", results = results, reveal = reveal, community = community }, pp.PROTOCOL)
    banner = "Hand complete"
    broadcastState(); render()
    sleep(4)

    -- clear hands; bust out anyone with no chips
    for i = 1, CFG.SEATS do
        local s = seats[i]
        if s then
            s.hole, s.committedRound, s.committedHand = nil, 0, 0
            if s.stack <= 0 then
                sendPocket(s.pocketId, { kind = "busted" })
                seats[i] = nil
            else
                s.status = "sitout"
            end
        end
    end
    persistSeats()
    inHand = false
end

-- ─── Lobby / main loop ────────────────────────────────────────────────────────

local function countReady()
    local n = 0
    for _, s in pairs(seats) do if s.sessionKey and s.stack > 0 then n = n + 1 end end
    return n
end

local function lobby()
    -- Idle until at least two paired players, then count down and deal.
    banner = "Waiting for players..."
    broadcastState(); render()
    local startTimer = nil
    while true do
        processCashouts()
        if countReady() >= 2 then
            if not startTimer then
                banner = "Dealing in " .. CFG.START_DELAY .. "s..."
                startTimer = os.startTimer(CFG.START_DELAY)
                render()
            end
        else
            startTimer = nil
            banner = "Waiting for players..."
            render()
        end

        local ev = { os.pullEvent() }
        if ev[1] == "timer" and startTimer and ev[2] == startTimer then
            if countReady() >= 2 then return end  -- proceed to deal
            startTimer = nil
        else
            dispatch(ev, nil)
            broadcastState(); render()
        end
    end
end

local function adminLoop()
    print("Poker table admin:")
    print("  device <pocketId> <key>   register a pocket")
    print("  devices | seats | quit")
    while true do
        io.write("> ")
        local line = io.read()
        if not line then break end
        local p = {}
        for w in line:gmatch("%S+") do p[#p + 1] = w end
        if p[1] == "device" and p[2] and p[3] then
            devices[p[2]] = p[3]
            local f = fs.open(DEVICES_DB, "w"); f.write(textutils.serialize(devices)); f.close()
            print("  registered pocket " .. p[2])
        elseif p[1] == "devices" then
            for id in pairs(devices) do print("  pocket " .. id) end
        elseif p[1] == "seats" then
            for i, s in pairs(seats) do
                print(string.format("  seat %d: acct %s stack %d %s", i, tostring(s.accountId), s.stack, s.status))
            end
        elseif p[1] == "quit" then
            print("Cashing out all seats..."); for _, s in pairs(seats) do if s.stack > 0 then bankc.credit(s.accountId, s.stack) end end
            if fs.exists(SEATS_DB) then fs.delete(SEATS_DB) end
            os.queueEvent("terminate_admin")
            return
        else
            print("  device <pocketId> <key> | devices | seats | quit")
        end
    end
end

local function gameLoop()
    initPeripherals()
    math.randomseed(os.epoch("utc"))
    loadDevices()
    recoverStrandedChips()
    rednet.host(pp.PROTOCOL, pp.HOSTNAME)
    while true do
        lobby()
        playHand()
    end
end

parallel.waitForAny(gameLoop, adminLoop)
rednet.unhost(pp.PROTOCOL)
print("Table server stopped.")
