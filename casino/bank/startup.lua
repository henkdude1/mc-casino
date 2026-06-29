-- Launches the bank server. If it exits or crashes, offers a 5s window to
-- drop to the shell (press any key) before auto-rebooting. The key window
-- means you never have to fight the Ctrl+T timing to reach the shell.
local ok, err = pcall(shell.run, "bank_server")
if not ok then
    term.setTextColor(colors.red)
    printError("Bank stopped: " .. tostring(err))
    term.setTextColor(colors.white)
end

print("Press any key for the shell, or wait 5s to reboot...")
local timer = os.startTimer(5)
while true do
    local ev, p = os.pullEvent()
    if ev == "key" then
        print("Dropping to shell. Type 'reboot' to restart the bank.")
        return
    elseif ev == "timer" and p == timer then
        os.reboot()
    end
end
