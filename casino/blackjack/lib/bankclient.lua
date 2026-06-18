-- Bank client wrappers for cashier / game computers.
-- Call open() once at startup before any balance/credit/debit calls.

local proto = require("lib.protocol")
local M = {}

function M.open()
    local modem = peripheral.find("modem")
    assert(modem, "No modem found — attach a wired or wireless modem")
    rednet.open(peripheral.getName(modem))
end

-- Each call returns (true, balance) on success or (false, reason) on failure.

local function call(action, id, amount)
    local reply, err = proto.request(action, id, amount)
    if not reply then return false, err end
    return reply.ok, reply.ok and reply.balance or reply.reason
end

function M.balance(id)   return call("balance", id, 0) end
function M.credit(id, n) return call("credit",  id, n) end
function M.debit(id, n)  return call("debit",   id, n) end

return M
