-- Reboots the computer if the cashier exits or crashes.
local ok, err = pcall(shell.run, "cashier")
if not ok then
    term.setTextColor(colors.red)
    printError("Cashier crashed: " .. tostring(err))
    term.setTextColor(colors.white)
    print("Rebooting in 3s...")
    sleep(3)
end
os.reboot()
