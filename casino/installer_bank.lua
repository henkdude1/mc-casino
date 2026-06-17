-- BANK COMPUTER INSTALLER
-- Change BASE to your repo's raw URL, then pastebin this file.
-- On the bank computer: pastebin run <code>

local BASE = "https://raw.githubusercontent.com/henkdude1/mc-casino/main/bank"

local files = {
    "lib/protocol.lua",
    "lib/bankclient.lua",
    "lib/card.lua",
    "lib/ui.lua",
    "bank_server.lua",
    "startup.lua",
}

print("=== Bank Installer ===")
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

print("\nDone! Edit lib/protocol.lua to set your SECRET, then reboot.")
