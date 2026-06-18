-- Disk-drive (player card) helpers.
-- The "card" is a formatted floppy disk; its unique integer ID is the account key.

local M = {}

-- True if a formatted disk is currently in the drive on `side`.
function M.present(side)
    return disk.isPresent(side) and disk.hasData(side)
end

-- Returns the disk's unique integer ID, or nil if no card is present.
function M.id(side)
    if not M.present(side) then return nil end
    return disk.getID(side)
end

-- Blocks until a formatted disk is inserted; returns its ID.
function M.waitForInsert(side)
    while true do
        local id = M.id(side)
        if id then return id end
        os.pullEvent("disk")
    end
end

-- Blocks until the disk is removed from the drive.
function M.waitForRemove(side)
    while disk.isPresent(side) do
        os.pullEvent("disk_eject")
    end
end

-- Physically eject the card from the drive on `side`.
function M.eject(side)
    if disk.isPresent(side) then disk.eject(side) end
end

return M
