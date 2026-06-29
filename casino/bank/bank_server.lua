-- CASINO BANK SERVER
-- Hardware: one modem (wired or wireless) attached to the computer.
-- balances.db is created automatically and persists across reboots.
-- Admin commands are available on this computer's own keyboard.

local proto      = require("lib.protocol")
local DB_PATH    = "balances.db"
local VAULT_PATH = "vaults.db"
local balances   = {}
local vaults     = {}   -- label -> { total = cogs, time = epoch ms }

local function persist()
    local f = fs.open(DB_PATH, "w")
    f.write(textutils.serialize(balances))
    f.close()
end

local function load()
    if fs.exists(DB_PATH) then
        local f = fs.open(DB_PATH, "r")
        local raw = f.readAll(); f.close()
        balances = textutils.unserialize(raw) or {}
    end
end

local function persistVaults()
    local f = fs.open(VAULT_PATH, "w")
    f.write(textutils.serialize(vaults))
    f.close()
end

local function loadVaults()
    if fs.exists(VAULT_PATH) then
        local f = fs.open(VAULT_PATH, "r")
        local raw = f.readAll(); f.close()
        vaults = textutils.unserialize(raw) or {}
    end
end

local function log(color, fmt, ...)
    term.setTextColor(color)
    print(string.format(fmt, ...))
    term.setTextColor(colors.white)
end

-- Rednet server: handles balance / credit / debit requests.
local function serverLoop()
    while true do
        local sender, msg = rednet.receive(proto.PROTOCOL)
        if type(msg) ~= "table" or msg.secret ~= proto.SECRET then
            -- drop silently: bad secret or malformed message
        else
            local id  = msg.id
            local amt = tonumber(msg.amount) or 0
            local reply

            if msg.action == "balance" then
                reply = { ok=true, balance=balances[id] or 0 }

            elseif msg.action == "credit" and amt > 0 then
                balances[id] = (balances[id] or 0) + amt
                persist()
                reply = { ok=true, balance=balances[id] }
                log(colors.lime, "[+] ID %s  +%d  => %d", tostring(id), amt, balances[id])

            elseif msg.action == "debit" and amt > 0 then
                local cur = balances[id] or 0
                if cur >= amt then
                    balances[id] = cur - amt
                    persist()
                    reply = { ok=true, balance=balances[id] }
                    log(colors.red, "[-] ID %s  -%d  => %d", tostring(id), amt, balances[id])
                else
                    reply = { ok=false, reason="insufficient", balance=cur }
                    log(colors.orange, "[!] ID %s  debit %d refused (has %d)", tostring(id), amt, cur)
                end

            elseif msg.action == "vault" then
                vaults[id] = { total = amt, time = os.epoch("local") }
                persistVaults()
                reply = { ok=true }
                log(colors.cyan, "[V] %s vault => %d cogs", tostring(id), amt)

            else
                reply = { ok=false, reason="unknown action" }
            end

            rednet.send(sender, reply, proto.PROTOCOL)
        end
    end
end

-- Admin keyboard loop (runs in parallel with the server).
local function adminLoop()
    log(colors.yellow, "Admin commands:")
    log(colors.yellow, "  list | balance <id> | set <id> <n> | del <id>")
    log(colors.yellow, "  backup | vault | quit")
    while true do
        io.write("> ")
        local line = io.read()
        if not line then break end
        local parts = {}
        for w in line:gmatch("%S+") do parts[#parts+1] = w end
        local cmd = parts[1]

        if cmd == "balance" and parts[2] then
            local id = tonumber(parts[2]) or parts[2]
            print(string.format("  %s: %d credits", tostring(id), balances[id] or 0))

        elseif cmd == "set" and parts[2] and parts[3] then
            local id  = tonumber(parts[2]) or parts[2]
            local amt = tonumber(parts[3])
            if amt then
                balances[id] = amt; persist()
                print(string.format("  %s => %d credits", tostring(id), amt))
            else
                print("  Usage: set <id> <amount>")
            end

        elseif cmd == "del" and parts[2] then
            local id = tonumber(parts[2]) or parts[2]
            if balances[id] ~= nil then
                balances[id] = nil; persist()
                print(string.format("  deleted %s", tostring(id)))
            else
                print(string.format("  %s has no account", tostring(id)))
            end

        elseif cmd == "backup" then
            if fs.exists(DB_PATH) then
                local name = "balances_backup_" .. os.date("%Y%m%d_%H%M%S") .. ".db"
                fs.copy(DB_PATH, name)
                print("  Backed up balances to " .. name)
            else
                print("  No balances.db to back up yet")
            end

        elseif cmd == "list" then
            -- Sort by id and page 10 at a time so 30+ accounts don't scroll off.
            local ids = {}
            for id in pairs(balances) do ids[#ids + 1] = id end
            table.sort(ids, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)
            if #ids == 0 then print("  (no accounts yet)") end
            for i, id in ipairs(ids) do
                print(string.format("  %s: %d", tostring(id), balances[id]))
                if i % 10 == 0 and i < #ids then
                    io.write(string.format("  -- %d/%d shown, Enter = more, q = stop -- ", i, #ids))
                    if io.read() == "q" then break end
                end
            end

        elseif cmd == "vault" then
            local n = 0
            for label, v in pairs(vaults) do
                local when = os.date("%Y-%m-%d %H:%M:%S", math.floor((v.time or 0) / 1000))
                print(string.format("  %s: %d cogs  (as of %s)", tostring(label), v.total or 0, when))
                n = n + 1
            end
            if n == 0 then print("  (no vault reports yet)") end

        elseif cmd == "quit" then
            print("Shutting down."); break

        else
            print("  Commands: list | balance <id> | set <id> <n> | del <id> | backup | vault | quit")
        end
    end
end

-- Startup
load()
loadVaults()
local modem = peripheral.find("modem")
assert(modem, "Bank: no modem attached!")
rednet.open(peripheral.getName(modem))
rednet.host(proto.PROTOCOL, proto.HOSTNAME)

term.clear(); term.setCursorPos(1, 1)
log(colors.yellow, "=== CASINO BANK SERVER ===")
print(string.format("Protocol : %s", proto.PROTOCOL))
print(string.format("Hostname : %s", proto.HOSTNAME))
local n = 0; for _ in pairs(balances) do n = n + 1 end
print(string.format("Accounts : %d loaded from %s", n, DB_PATH))
print()

parallel.waitForAny(serverLoop, adminLoop)
rednet.unhost(proto.PROTOCOL)
