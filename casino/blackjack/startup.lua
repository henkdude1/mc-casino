-- Reboots the computer if the blackjack game exits or crashes.
local ok, err = pcall(shell.run, "blackjack")
if not ok then
    term.setTextColor(colors.red)
    printError("Blackjack crashed: " .. tostring(err))
    term.setTextColor(colors.white)
    print("Rebooting in 3s...")
    sleep(3)
end
os.reboot()
