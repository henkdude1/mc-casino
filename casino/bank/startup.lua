-- Auto-restarts the bank server if it crashes.
while true do
    local ok, err = pcall(shell.run, "bank_server")
    if not ok then
        term.setTextColor(colors.red)
        printError("Bank crashed: " .. tostring(err))
        term.setTextColor(colors.white)
        print("Restarting in 5s...")
        sleep(5)
    end
end
