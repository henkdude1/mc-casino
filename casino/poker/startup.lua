-- Launches the poker table server. After it exits or is stopped (hold Ctrl+T),
-- press any key within 5s to drop to the shell; otherwise it auto-reboots.
local ok, err = pcall(shell.run, "table")
if not ok then
    term.setTextColor(colors.red)
    printError("Table server stopped: " .. tostring(err))
    term.setTextColor(colors.white)
end

print("Press any key for the shell, or wait 5s to reboot...")
local timer = os.startTimer(5)
while true do
    local ev, p = os.pullEvent()
    if ev == "key" then
        print("Dropping to shell. Type 'reboot' to restart.")
        return
    elseif ev == "timer" and p == timer then
        os.reboot()
    end
end
