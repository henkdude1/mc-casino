-- CASINO BANK SERVER
-- Hardware: one modem (wired or wireless) attached to the computer.
-- balances.db is created automatically and persists across reboots.
-- Admin commands are available on this computer's own keyboard.

local proto    = require("lib.protocol")
local DB_PATH  = "balances.db"
local balances = {}

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

            else
                reply = { ok=false, reason="unknown action" }
            end

            rednet.send(sender, reply, proto.PROTOCOL)
        end
    end
end

-- Admin keyboard loop (runs in parallel with the server).
local function adminLoop()
    log(colors.yellow, "Admin: balance <id>  |  set <id> <n>  |  list  |  quit")
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

        elseif cmd == "list" then
            local n = 0
            for id, bal in pairs(balances) do
                print(string.format("  %s: %d", tostring(id), bal)); n = n + 1
            end
            if n == 0 then print("  (no accounts yet)") end

        elseif cmd == "quit" then
            print("Shutting down."); break

        else
            print("  Commands: balance <id> | set <id> <n> | list | quit")
        end
    end
end

-- Startup
load()
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
