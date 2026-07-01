-- CASHIER COMPUTER
-- ┌─────────────────────────────────────────────────────────────────┐
-- │ HARDWARE SETUP — edit CFG below to match your build.            │
-- │                                                                 │
-- │  • Wired modem attached to this computer (connects to network)  │
-- │  • Deposit chest on the modem network   -> depositName          │
-- │  • Vault barrel on the modem network    -> vaultName            │
-- │  • Payout chest on the modem network    -> payoutName           │
-- │    (pipe / funnel this chest to the player however you like)    │
-- │  • Disk drive directly attached to this computer -> driveSide   │
-- │  • Monitor directly attached or on the modem network            │
-- │                                                                 │
-- │  Run `peripheral.getNames()` in the Lua prompt to find names.   │
-- └─────────────────────────────────────────────────────────────────┘

local bankc = require("lib.bankclient")
local card  = require("lib.card")
local ui    = require("lib.ui")
local txlog = require("lib.txlog")

local CFG = {
    cashierLabel = "cashier1",             -- name shown by the bank's `vault` command
    COIN         = "numismatics:cog",
    depositName  = "minecraft:chest_0",    -- chest where players place cogs to deposit
    vaultName    = "sophisticatedbackpacks:backpack_0",   -- internal storage
    payoutName   = "minecraft:chest_1",    -- payout chest (funnel/pipe this to the player)
    monitorName  = "",                     -- exact monitor name; "" or nil = auto-find
    driveSide    = "top",                  -- side the disk drive is attached to
    monitorScale = 1,                      -- monitor text scale (0.5 – 5)
    STEPS        = {1, 10, 100},           -- withdraw increment buttons
    POLL_INTERVAL = 1,                     -- seconds between deposit-chest auto-sweeps
}

-- ─── Peripherals ──────────────────────────────────────────────────────────────

local deposit, vault, mon, monName

local function initPeripherals()
    bankc.open()
    deposit = peripheral.wrap(CFG.depositName)
    vault   = peripheral.wrap(CFG.vaultName)
    local payout = peripheral.wrap(CFG.payoutName)
    if CFG.monitorName and CFG.monitorName ~= "" then
        mon = peripheral.wrap(CFG.monitorName)
        assert(mon, "Monitor not found: " .. CFG.monitorName)
        monName = CFG.monitorName
    else
        mon = peripheral.find("monitor")
        assert(mon, "No monitor found — attach an Advanced Monitor")
        monName = peripheral.getName(mon)
    end
    assert(deposit, "Deposit chest not found: " .. CFG.depositName)
    assert(vault,   "Vault not found: "          .. CFG.vaultName)
    assert(payout,  "Payout chest not found: "   .. CFG.payoutName)
    assert(mon.isColor and mon.isColor(), "Monitor must be an Advanced (color) Monitor for touch")
    mon.setTextScale(CFG.monitorScale)
end

-- ─── Inventory helpers ────────────────────────────────────────────────────────

local function countCogs(inv)
    local n = 0
    for _, item in pairs(inv.list()) do
        if item.name == CFG.COIN then n = n + item.count end
    end
    return n
end

-- Append a transaction to the on-disk log and report the new vault total to
-- the bank (viewable there via the `vault` admin command). Call AFTER the
-- cogs have actually moved, so countCogs(vault) reflects the new total.
local function logTxn(kind, cardID, amount)
    local total = countCogs(vault)
    txlog.record(kind, cardID, amount, total)
    bankc.reportVault(CFG.cashierLabel, total)
end

-- ─── Actions ──────────────────────────────────────────────────────────────────

local function doDeposit(currentID)
    local n = countCogs(deposit)
    if n == 0 then return "Chest is empty — place cogs first" end

    local ok, result = bankc.credit(currentID, n)
    if not ok then return "Bank error: " .. tostring(result) end

    -- Sweep exactly n cogs into the vault. Cap at n so cogs that flow in AFTER the
    -- count (chute still feeding during the bank round-trip) stay in the chest and
    -- are credited on the next poll instead of being swept in uncredited.
    local remaining = n
    for slot, item in pairs(deposit.list()) do
        if remaining <= 0 then break end
        if item.name == CFG.COIN then
            local moved = deposit.pushItems(CFG.vaultName, slot, math.min(remaining, item.count))
            remaining = remaining - moved
        end
    end

    logTxn("DEPOSIT", currentID, n)
    return string.format("Deposited %d cogs!  Balance: %d", n, result)
end

local function doWithdraw(currentID, amount)
    if amount <= 0 then return "Amount must be positive" end

    -- Check vault stock BEFORE touching the bank balance
    local available = countCogs(vault)
    if available < amount then
        return string.format("Vault only has %d cogs (need %d)", available, amount)
    end

    local ok, result = bankc.debit(currentID, amount)
    if not ok then return "Declined: " .. tostring(result) end

    -- Push cogs from the vault into the payout chest, re-scanning each pass so a
    -- self-compacting vault (Sophisticated Backpack) can't strand a stale slot index.
    local remaining = amount
    while remaining > 0 do
        local movedThisPass = 0
        for slot, item in pairs(vault.list()) do
            if remaining <= 0 then break end
            if item.name == CFG.COIN then
                local moved = vault.pushItems(CFG.payoutName, slot, math.min(remaining, item.count))
                remaining     = remaining - moved
                movedThisPass = movedThisPass + moved
            end
        end
        if movedThisPass == 0 then break end   -- target genuinely full / no cogs left
    end

    if remaining > 0 then
        -- Payout chest was full; refund whatever didn't fit
        bankc.credit(currentID, remaining)
        logTxn("WITHDRAW", currentID, amount - remaining)
        return string.format("Payout chest full! Refunded %d credits. Collect cogs and retry.", remaining)
    end

    logTxn("WITHDRAW", currentID, amount)
    return string.format("Paid out %d cogs!", amount)
end

-- ─── Touchscreen state ────────────────────────────────────────────────────────

local STATE     = "INSERT"   -- INSERT | MENU | WITHDRAW | CONFIRM
local currentID              -- disk ID of the inserted card
local balance   = 0          -- cached account balance
local amount    = 0          -- withdraw amount being built
local message   = ""         -- status banner (last action result)
local buttons   = {}         -- current hit-test descriptors

local DEBOUNCE_MS = 300      -- ignore repeat touches within this window
local lastTouch   = 0

local function refreshBalance()
    if not currentID then balance = 0; return end
    local ok, res = bankc.balance(currentID)
    if ok then balance = res else balance = 0; message = "Bank: " .. tostring(res) end
end

-- Sweep any cogs waiting in the deposit chest onto the current card.
-- Called on a timer (chute-fed) and on card insert. No-op without a card or cogs.
local function autoDeposit()
    if not currentID then return end
    if countCogs(deposit) > 0 then
        message = doDeposit(currentID)   -- counts, credits, sweeps to vault
        refreshBalance()
    end
end

-- ─── Rendering ────────────────────────────────────────────────────────────────

-- Lay out a row of evenly-spaced buttons across the screen width.
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

local function draw()
    local w, h = mon.getSize()
    ui.clear(mon)
    ui.centerText(mon, 1, "* CASINO CASHIER *", colors.yellow)

    if STATE == "INSERT" then
        ui.centerText(mon, math.floor(h / 2) - 1, "INSERT CARD", colors.red)
        ui.centerText(mon, math.floor(h / 2) + 1, "TO BEGIN", colors.red)
        ui.centerText(mon, h, message, colors.gray)
        buttons = {}

    elseif STATE == "MENU" then
        ui.centerText(mon, 3, "CARD " .. tostring(currentID), colors.cyan)
        ui.centerText(mon, 5, "BALANCE", colors.white)
        ui.centerText(mon, 6, balance .. " credits", colors.lime)
        ui.centerText(mon, 8, "Drop cogs in chest to deposit", colors.gray)
        ui.centerText(mon, h - 4, message, colors.gray)
        buttons = rowButtons({
            { label = "WITHDRAW", id = "withdraw", bg = colors.blue },
            { label = "EJECT",    id = "eject",    bg = colors.red },
        }, h - 2, 3)

    elseif STATE == "WITHDRAW" then
        ui.centerText(mon, 3, "BALANCE: " .. balance .. " credits", colors.lime)
        ui.centerText(mon, 5, "WITHDRAW", colors.white)
        ui.centerText(mon, 6, tostring(amount), colors.yellow)
        ui.centerText(mon, h - 6, message, colors.gray)

        local defs = {}
        for _, step in ipairs(CFG.STEPS) do
            defs[#defs + 1] = { label = "+" .. step, id = "step:" .. step, bg = colors.blue }
        end
        defs[#defs + 1] = { label = "ALL",   id = "all",   bg = colors.cyan, fg = colors.black }
        defs[#defs + 1] = { label = "CLEAR", id = "clear", bg = colors.gray }
        buttons = rowButtons(defs, h - 4, 3)

        local okAmt = amount >= 1 and amount <= balance
        local row2 = rowButtons({
            { label = "BACK",     id = "back",     bg = colors.gray },
            { label = "WITHDRAW", id = "confirm",  bg = okAmt and colors.green or colors.gray },
        }, h - 1, 1)
        for _, b in ipairs(row2) do buttons[#buttons + 1] = b end

    elseif STATE == "CONFIRM" then
        ui.centerText(mon, math.floor(h / 2) - 2, "Withdraw " .. amount .. " cogs?", colors.white)
        ui.centerText(mon, math.floor(h / 2), "Balance: " .. balance, colors.lime)
        buttons = rowButtons({
            { label = "YES", id = "yes", bg = colors.green },
            { label = "NO",  id = "no",  bg = colors.red },
        }, h - 2, 3)
    end
end

-- ─── Touch handling ───────────────────────────────────────────────────────────

local function handleTouch(id)
    if not id then return end

    if STATE == "MENU" then
        if id == "withdraw" then
            amount, message = 0, ""
            STATE = "WITHDRAW"
        elseif id == "eject" then
            card.eject(CFG.driveSide)
            -- disk_eject event resets to INSERT
        end

    elseif STATE == "WITHDRAW" then
        if id:match("^step:") then
            local step = tonumber(id:match("^step:(%d+)"))
            amount = math.min(amount + step, balance)
            message = ""
        elseif id == "all" then
            amount, message = balance, ""
        elseif id == "clear" then
            amount, message = 0, ""
        elseif id == "back" then
            message = ""
            STATE = "MENU"
        elseif id == "confirm" then
            if amount >= 1 and amount <= balance then
                STATE = "CONFIRM"
            end
        end

    elseif STATE == "CONFIRM" then
        if id == "yes" then
            message = doWithdraw(currentID, amount)
            refreshBalance()
            amount = 0
            STATE = "MENU"
        elseif id == "no" then
            STATE = "WITHDRAW"
        end
    end
end

-- ─── Main loop ────────────────────────────────────────────────────────────────

local function enterMenu()
    currentID = card.id(CFG.driveSide)
    if not currentID then STATE = "INSERT"; return end
    amount, message = 0, ""
    refreshBalance()
    autoDeposit()        -- sweep any cogs already waiting in the chest
    STATE = "MENU"
end

local function main()
    initPeripherals()
    bankc.reportVault(CFG.cashierLabel, countCogs(vault))   -- seed the bank's vault readout

    -- If a card is already present at boot, go straight to the menu.
    if card.id(CFG.driveSide) then enterMenu() else STATE = "INSERT" end

    local pollTimer = os.startTimer(CFG.POLL_INTERVAL)

    while true do
        draw()
        local ev = { os.pullEvent() }
        local name = ev[1]

        if name == "monitor_touch" and ev[2] == monName then
            local now = os.epoch("utc")
            if now - lastTouch >= DEBOUNCE_MS then
                lastTouch = now
                local _, _, x, y = table.unpack(ev)
                handleTouch(ui.hit(buttons, x, y))
            end

        elseif name == "timer" then
            autoDeposit()

        elseif name == "disk" then
            if STATE == "INSERT" then enterMenu() end

        elseif name == "disk_eject" then
            currentID = nil
            amount, message = 0, ""
            STATE = "INSERT"
        end

        -- Re-arm the deposit poll every iteration. A fresh timer each pass survives
        -- bank-call (rednet.receive) filtered pulls that would otherwise swallow a
        -- lone timer event and kill the polling chain permanently.
        os.cancelTimer(pollTimer)
        pollTimer = os.startTimer(CFG.POLL_INTERVAL)
    end
end

main()
