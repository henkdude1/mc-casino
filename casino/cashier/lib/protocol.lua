-- Shared protocol constants and bank request helper.
-- Copy this file to lib/protocol.lua on every casino computer.

local M = {}

M.PROTOCOL = "casino_bank"
M.HOSTNAME  = "bank"
M.SECRET    = "CHANGE_ME"   -- change this to the same value on all machines
M.TIMEOUT   = 5             -- seconds to wait for a bank reply

-- Look up the bank, send a request, and wait for the reply.
-- Returns (reply_table) or (nil, reason_string) on failure.
function M.request(action, diskID, amount)
    local bankID = rednet.lookup(M.PROTOCOL, M.HOSTNAME)
    if not bankID then return nil, "bank offline" end
    rednet.send(bankID, {
        secret = M.SECRET,
        action = action,
        id     = diskID,
        amount = amount or 0,
    }, M.PROTOCOL)
    local _, reply = rednet.receive(M.PROTOCOL, M.TIMEOUT)
    if not reply then return nil, "timeout" end
    return reply
end

return M
