-- Launches the poker pocket client. On exit (cash-out or stop), press any key
-- within 5s for the shell; otherwise reboot back into the client.
local ok, err = pcall(shell.run, "pocket")
if not ok then
    term.setTextColor(colors.red)
    printError("Pocket client stopped: " .. tostring(err))
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
