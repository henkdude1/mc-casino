-- Reboots the computer if the slots game exits or crashes.
local ok, err = pcall(shell.run, "slots")
if not ok then
    term.setTextColor(colors.red)
    printError("Slots crashed: " .. tostring(err))
    term.setTextColor(colors.white)
    print("Rebooting in 3s...")
    sleep(3)
end
os.reboot()
