-- Reboots the computer if the bank server exits or crashes.
local ok, err = pcall(shell.run, "bank_server")
if not ok then
    term.setTextColor(colors.red)
    printError("Bank crashed: " .. tostring(err))
    term.setTextColor(colors.white)
    print("Rebooting in 5s...")
    sleep(5)
end
os.reboot()
