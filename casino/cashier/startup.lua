-- Auto-restarts the cashier if it crashes.
while true do
    local ok, err = pcall(shell.run, "cashier")
    if not ok then
        term.setTextColor(colors.red)
        printError("Cashier crashed: " .. tostring(err))
        term.setTextColor(colors.white)
        print("Restarting in 3s...")
        sleep(3)
    end
end
