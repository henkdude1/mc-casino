-- SLOTS CABINET INSTALLER
-- Change BASE to your repo's raw URL, then pastebin this file.
-- On the slots computer: pastebin run <code>

local BASE = "https://raw.githubusercontent.com/henkdude1/mc-casino/main/casino/slots"

local files = {
    "lib/protocol.lua",
    "lib/bankclient.lua",
    "lib/card.lua",
    "lib/ui.lua",
    "slots.lua",
    "startup.lua",
}

print("=== Slots Installer ===")
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

print("\nDone! Edit slots.lua (CFG block) then reboot.")
