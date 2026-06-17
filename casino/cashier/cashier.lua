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

local CFG = {
    COIN         = "numismatics:cog",
    depositName  = "minecraft:chest_0",    -- chest where players place cogs to deposit
    vaultName    = "minecraft:barrel_0",   -- internal storage barrel
    payoutName   = "minecraft:chest_1",    -- payout chest (funnel/pipe this to the player)
    driveSide    = "left",                 -- side the disk drive is attached to
    monitorScale = 1,                      -- monitor text scale (0.5 – 5)
}

local status = "Ready"

-- ─── Peripherals ──────────────────────────────────────────────────────────────

local deposit, vault, mon

local function initPeripherals()
    bankc.open()
    deposit = peripheral.wrap(CFG.depositName)
    vault   = peripheral.wrap(CFG.vaultName)
    local payout = peripheral.wrap(CFG.payoutName)
    mon     = peripheral.find("monitor")
    assert(deposit, "Deposit chest not found: " .. CFG.depositName)
    assert(vault,   "Vault not found: "          .. CFG.vaultName)
    assert(payout,  "Payout chest not found: "   .. CFG.payoutName)
end

-- ─── Monitor display ──────────────────────────────────────────────────────────

local function updateMonitor(currentID)
    if not mon then return end
    mon.setTextScale(CFG.monitorScale)
    local w, h = mon.getSize()
    ui.clear(mon)

    ui.centerText(mon, 1, "* CASINO CASHIER *", colors.yellow)
    ui.centerText(mon, 2, string.rep("-", w), colors.gray)

    if currentID then
        ui.centerText(mon, 4, "CARD ID:", colors.white)
        ui.centerText(mon, 5, tostring(currentID), colors.cyan)

        local ok, bal = bankc.balance(currentID)
        if ok then
            ui.centerText(mon, 7, "BALANCE", colors.white)
            ui.centerText(mon, 8, tostring(bal) .. " credits", colors.lime)
        else
            ui.centerText(mon, 7, "Bank:", colors.red)
            ui.centerText(mon, 8, tostring(bal), colors.red)
        end
    else
        ui.centerText(mon, math.floor(h / 2), "INSERT CARD", colors.red)
    end

    ui.centerText(mon, h, status, colors.yellow)
end

-- ─── Inventory helpers ────────────────────────────────────────────────────────

local function countCogs(inv)
    local n = 0
    for _, item in pairs(inv.list()) do
        if item.name == CFG.COIN then n = n + item.count end
    end
    return n
end

-- ─── Actions ──────────────────────────────────────────────────────────────────

local function doDeposit(currentID)
    local n = countCogs(deposit)
    if n == 0 then return "Chest is empty — place cogs first" end

    local ok, result = bankc.credit(currentID, n)
    if not ok then return "Bank error: " .. tostring(result) end

    -- Sweep cogs into the vault so they are never counted twice
    for slot, item in pairs(deposit.list()) do
        if item.name == CFG.COIN then
            deposit.pushItems(CFG.vaultName, slot, item.count)
        end
    end

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

    -- Push cogs directly from vault into the payout chest
    local remaining = amount
    for slot, item in pairs(vault.list()) do
        if remaining <= 0 then break end
        if item.name == CFG.COIN then
            local moved = vault.pushItems(CFG.payoutName, slot, math.min(remaining, item.count))
            remaining = remaining - moved
        end
    end

    if remaining > 0 then
        -- Payout chest was full; refund whatever didn't fit
        bankc.credit(currentID, remaining)
        return string.format("Payout chest full! Refunded %d credits. Collect cogs and retry.", remaining)
    end

    return string.format("Paid out %d cogs!", amount)
end

-- ─── Terminal UI ──────────────────────────────────────────────────────────────

local function printLine(color, text)
    term.setTextColor(color or colors.white)
    print(text)
    term.setTextColor(colors.white)
end

local function main()
    initPeripherals()

    while true do
        local currentID = card.id(CFG.driveSide)
        updateMonitor(currentID)

        term.clear(); term.setCursorPos(1, 1)
        printLine(colors.yellow, "=== CASINO CASHIER ===")

        if currentID then
            printLine(colors.cyan, "Card: " .. tostring(currentID))
            local ok, bal = bankc.balance(currentID)
            if ok then
                printLine(colors.lime, "Balance: " .. tostring(bal) .. " credits")
            else
                printLine(colors.red, "Bank: " .. tostring(bal))
            end
        else
            printLine(colors.red, "No card inserted.")
        end

        print()
        print("[D] Deposit cogs from chest")
        print("[W] Withdraw cogs (pay out)")
        print("[B] Refresh balance")
        print("[Q] Quit")
        print()
        printLine(colors.gray, "Status: " .. status)
        io.write("> ")

        local line = io.read()
        if not line then break end
        local choice = line:lower():match("^%s*(%a)")

        if choice == "d" then
            if not currentID then
                status = "Insert a card first!"
            else
                status = doDeposit(currentID)
            end

        elseif choice == "w" then
            if not currentID then
                status = "Insert a card first!"
            else
                io.write("Amount to withdraw: ")
                local amtStr = io.read()
                local amt    = math.floor(tonumber(amtStr) or 0)
                if amt > 0 then
                    status = doWithdraw(currentID, amt)
                else
                    status = "Invalid amount"
                end
            end

        elseif choice == "b" then
            status = "Refreshed."

        elseif choice == "q" then
            print("Goodbye.")
            break

        else
            status = "Press D, W, B, or Q"
        end
    end
end

main()
