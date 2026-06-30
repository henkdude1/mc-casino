-- pokerproto.lua — the casino_poker rednet protocol shared by the table server
-- and the pocket clients.
--
-- Unlike casino_bank (a simple request/reply to the bank), poker is
-- BIDIRECTIONAL and push-based: the server sends each pocket its own sealed
-- hole cards and broadcasts public state; pockets send action intents back.
--
-- Message kinds (envelope field `kind`):
--   pocket -> table : "join"   { pocketId, pin, mac, nonce }   (auth, plaintext)
--                     "action" { pocketId, move, amount }      (intent, plaintext)
--                     "cashout"{ pocketId }
--   table  -> pocket: "joined" { ok, sessionNonce, seat | reason }
--                     "deal"   { sealed }   <- hole cards, ENCRYPTED per session
--                     "state"  { ... }      <- public board, plaintext broadcast
--                     "turn"   { seat, toCall, minRaise, stack, deadline }
--                     "result" { ... }      <- showdown summary
--
-- Only "deal" is encrypted — it is the sole private payload. Everything else is
-- public information that already shows on the shared monitor anyway.

local crypto = require("lib.crypto")

local M = {}

M.PROTOCOL = "casino_poker"
M.HOSTNAME = "poker_table"

-- Serializer: textutils in CC; falls back to a tiny encoder so the module also
-- loads under standalone Lua for tests (tests don't exercise the wire path).
local function serialize(t)
    if textutils and textutils.serialize then return textutils.serialize(t) end
    error("serialize requires CC:Tweaked textutils")
end
local function unserialize(s)
    if textutils and textutils.unserialize then return textutils.unserialize(s) end
    error("unserialize requires CC:Tweaked textutils")
end

-- Open the first attached modem for rednet. Returns the modem's side.
function M.open()
    local modem = peripheral.find("modem")
    assert(modem, "No modem found — attach a wireless (ideally ender) modem")
    local side = peripheral.getName(modem)
    if not rednet.isOpen(side) then rednet.open(side) end
    return side
end

-- Seal an arbitrary table under a session key -> wire-safe table.
function M.sealTable(key, tbl)
    return crypto.seal(key, serialize(tbl))
end

-- Open a sealed table. Returns the table, or nil if the MAC fails.
function M.openTable(key, sealed)
    local pt = crypto.open(key, sealed)
    if not pt then return nil end
    local ok, val = pcall(unserialize, pt)
    if ok then return val end
    return nil
end

return M
