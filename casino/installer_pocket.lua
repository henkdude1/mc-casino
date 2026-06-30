-- POKER POCKET INSTALLER (run on each Advanced Pocket Computer)
-- Change BASE to your repo's raw URL, then pastebin this file.
-- On the pocket computer: pastebin run <code>
--
-- Besides downloading the client, this generates a unique device key for THIS
-- pocket and prints the line the table operator must register. The key is what
-- authenticates the pocket and seeds the per-session encryption of hole cards —
-- it is stored locally and NEVER transmitted.

local BASE = "https://raw.githubusercontent.com/henkdude1/mc-casino/main/casino/pocket"

local files = {
    "lib/crypto.lua",
    "lib/pokerproto.lua",
    "lib/ui.lua",
    "pocket.lua",
    "startup.lua",
}

print("=== Poker Pocket Installer ===")
for _, path in ipairs(files) do
    local dir = path:match("^(.+)/[^/]+$")
    if dir and not fs.exists(dir) then fs.makeDir(dir) end

    local url = BASE .. "/" .. path
    local ok, err = http.get(url)
    if not ok then
        printError("FAIL: " .. path .. " (" .. tostring(err) .. ")")
    else
        local f = fs.open(path, "w")
        f.write(ok.readAll())
        f.close()
        ok.close()
        print("OK: " .. path)
    end
end

-- Generate (or keep) this pocket's device key.
if not fs.exists("devicekey") then
    math.randomseed(os.epoch("utc") + os.getComputerID())
    local key = ""
    for _ = 1, 40 do
        local n = math.random(0, 15)
        key = key .. ("0123456789abcdef"):sub(n + 1, n + 1)
    end
    local f = fs.open("devicekey", "w"); f.write(key); f.close()
    print("\nGenerated device key.")
else
    print("\nKeeping existing device key.")
end

local f = fs.open("devicekey", "r"); local key = f.readAll(); f.close()
print("=====================================================")
print("On the TABLE console, register this pocket with:")
print("  device " .. os.getComputerID() .. " " .. key)
print("=====================================================")
print("Then reboot this pocket.")
