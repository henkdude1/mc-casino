-- Monitor drawing utilities and touchscreen button helpers.
-- Used by the cashier monitor and both game cabinets.

local M = {}

function M.clear(mon)
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)
    mon.clear()
end

-- Write text centered horizontally on row `y`.
function M.centerText(mon, y, text, fg, bg)
    local w = mon.getSize()
    local x = math.max(1, math.floor((w - #text) / 2) + 1)
    if bg then mon.setBackgroundColor(bg) end
    if fg then mon.setTextColor(fg) end
    mon.setCursorPos(x, y)
    mon.write(text)
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)
end

-- Write text at an exact position.
function M.text(mon, x, y, text, fg, bg)
    if bg then mon.setBackgroundColor(bg) end
    if fg then mon.setTextColor(fg) end
    mon.setCursorPos(x, y)
    mon.write(text)
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)
end

-- Fill a rectangle with a solid background color.
function M.fillRect(mon, x, y, w, h, color)
    mon.setBackgroundColor(color)
    local row = string.rep(" ", w)
    for r = y, y + h - 1 do
        mon.setCursorPos(x, r)
        mon.write(row)
    end
    mon.setBackgroundColor(colors.black)
end

-- Draw a labeled button and return a hit-test descriptor table.
-- `id` defaults to `label` if omitted.
function M.button(mon, x, y, w, h, label, bg, fg, id)
    bg = bg or colors.gray
    fg = fg or colors.white
    M.fillRect(mon, x, y, w, h, bg)
    local lx = x + math.floor((w - #label) / 2)
    local ly = y + math.floor(h / 2)
    mon.setBackgroundColor(bg)
    mon.setTextColor(fg)
    mon.setCursorPos(lx, ly)
    mon.write(label)
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)
    return { x=x, y=y, w=w, h=h, id=id or label }
end

-- Return the `id` of whichever button contains (tx, ty), or nil.
function M.hit(buttons, tx, ty)
    for _, b in ipairs(buttons) do
        if tx >= b.x and tx < b.x + b.w and ty >= b.y and ty < b.y + b.h then
            return b.id
        end
    end
end

-- Draw a playing card as a 5-wide x 4-tall box.
-- `rank` is a string ("A","2".."10","J","Q","K"); `suit` is one of S/H/D/C.
-- Hearts/Diamonds print red, Spades/Clubs black, on a white card face.
-- faceUp=false draws a solid blue card back instead.
function M.card(mon, x, y, rank, suit, faceUp)
    local W, H = 5, 4
    if faceUp == false then
        M.fillRect(mon, x, y, W, H, colors.blue)
        -- simple pattern dots on the back
        mon.setBackgroundColor(colors.blue)
        mon.setTextColor(colors.lightBlue)
        mon.setCursorPos(x + 1, y + 1)
        mon.write("***")
        mon.setCursorPos(x + 1, y + 2)
        mon.write("***")
        mon.setBackgroundColor(colors.black)
        mon.setTextColor(colors.white)
        return
    end

    M.fillRect(mon, x, y, W, H, colors.white)
    local suitColor = (suit == "H" or suit == "D") and colors.red or colors.black
    mon.setBackgroundColor(colors.white)

    -- top-left rank
    mon.setTextColor(suitColor)
    mon.setCursorPos(x, y)
    mon.write(rank)
    -- center suit
    mon.setCursorPos(x + 2, y + 1)
    mon.write(suit)
    -- bottom-right rank (right-aligned within the 5-wide box)
    local r = rank
    mon.setCursorPos(x + W - #r, y + H - 1)
    mon.write(r)

    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)
end

return M
