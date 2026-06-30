-- POKER TABLE INSTALLER (the dealer computer)
-- Change BASE to your repo's raw URL, then pastebin this file.
-- On the table computer: pastebin run <code>

local BASE = "https://raw.githubusercontent.com/henkdude1/mc-casino/main/casino/poker"

local files = {
    "lib/protocol.lua",
    "lib/bankclient.lua",
    "lib/card.lua",
    "lib/ui.lua",
    "lib/crypto.lua",
    "lib/holdem.lua",
    "lib/pokerproto.lua",
    "table.lua",
    "startup.lua",
}

print("=== Poker Table Installer ===")
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

print("\nDone! Edit table.lua (CFG block) and lib/protocol.lua (SECRET).")
print("Register each pocket from the table console with:")
print("  device <pocketId> <key>")
print("Then reboot.")
