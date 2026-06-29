-- Cashier transaction log.
-- Appends one line per deposit / withdrawal to transactions.log on this
-- computer. View it in-game with:  edit transactions.log
-- (newest entries are at the bottom).

local M = {}
local FILE = "transactions.log"

-- kind: "DEPOSIT" | "WITHDRAW"   amount: cogs moved   vaultTotal: cogs in vault after
function M.record(kind, cardID, amount, vaultTotal)
    local line = string.format("%s  %-8s  card=%s  amount=%d  vault=%d",
        os.date("%Y-%m-%d %H:%M:%S"), kind, tostring(cardID), amount, vaultTotal)
    local f = fs.open(FILE, "a")
    if f then f.writeLine(line); f.close() end
end

return M
