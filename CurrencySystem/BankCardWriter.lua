-- magcard_writer.lua - Create Bank Cards on OpenSecurity Magnetic Cards
-- Beautiful modern UI version

local component = require("component")
local serialization = require("serialization")
local term = require("term")
local unicode = require("unicode")

-- Check for GPU
if not component.isAvailable("gpu") then
    print("ERROR: GPU required!")
    return
end

local gpu = component.gpu

-- Check for OpenSecurity card writer
if not component.isAvailable("os_cardwriter") then
    term.clear()
    print("")
    print("╔═══════════════════════════════════════════════════════════╗")
    print("║                     ⚠ HARDWARE ERROR ⚠                    ║")
    print("╚═══════════════════════════════════════════════════════════╝")
    print("")
    print("  OpenSecurity Card Writer not found!")
    print("")
    print("  Required Hardware:")
    print("    • OpenSecurity Magnetic Card Writer")
    print("    • Blank Magnetic Cards")
    print("")
    print("  Installation Steps:")
    print("    1. Install OpenSecurity mod")
    print("    2. Craft a Magnetic Card Writer")
    print("    3. Place it adjacent to this computer")
    print("    4. Restart this program")
    print("")
    return
end

local cardWriter = component.os_cardwriter

-- Color scheme
local colors = {
    bg = 0x0F0F0F,
    header = 0x1E3A8A,
    accent = 0x3B82F6,
    success = 0x10B981,
    error = 0xEF4444,
    warning = 0xF59E0B,
    text = 0xFFFFFF,
    textDim = 0x9CA3AF,
    border = 0x374151,
    inputBg = 0x1F2937,
    cardGold = 0xFFD700
}

-- Screen setup
local w, h = gpu.getResolution()

local function clear()
    gpu.setBackground(colors.bg)
    gpu.setForeground(colors.text)
    term.clear()
end

local function drawHeader(title, subtitle)
    gpu.setBackground(colors.header)
    gpu.setForeground(colors.text)
    gpu.fill(1, 1, w, 3, " ")
    
    local titleX = math.floor((w - unicode.len(title)) / 2)
    gpu.set(titleX, 2, title)
    
    if subtitle then
        gpu.setForeground(colors.textDim)
        local subX = math.floor((w - unicode.len(subtitle)) / 2)
        gpu.set(subX, 3, subtitle)
    end
    
    gpu.setBackground(colors.bg)
end

local function drawBox(x, y, width, height, title)
    gpu.setBackground(colors.bg)
    gpu.setForeground(colors.border)
    
    -- Top border
    gpu.set(x, y, "╔" .. string.rep("═", width - 2) .. "╗")
    
    -- Title if provided
    if title then
        gpu.setForeground(colors.accent)
        local titlePos = x + math.floor((width - unicode.len(title)) / 2)
        gpu.set(titlePos, y, title)
    end
    
    -- Sides
    gpu.setForeground(colors.border)
    for i = 1, height - 2 do
        gpu.set(x, y + i, "║")
        gpu.set(x + width - 1, y + i, "║")
        gpu.fill(x + 1, y + i, width - 2, 1, " ")
    end
    
    -- Bottom border
    gpu.set(x, y + height - 1, "╚" .. string.rep("═", width - 2) .. "╝")
end

local function centerText(y, text, color)
    color = color or colors.text
    gpu.setForeground(color)
    local x = math.floor((w - unicode.len(text)) / 2)
    gpu.set(x, y, text)
end

local function input(prompt, y, hidden, maxLen)
    maxLen = maxLen or 30
    
    -- Calculate centering
    local totalWidth = unicode.len(prompt) + maxLen + 2
    local startX = math.floor((w - totalWidth) / 2)
    
    gpu.setForeground(colors.text)
    gpu.set(startX, y, prompt)
    
    local inputX = startX + unicode.len(prompt)
    
    gpu.setBackground(colors.inputBg)
    gpu.fill(inputX, y, maxLen + 2, 1, " ")
    
    inputX = inputX + 1
    gpu.set(inputX, y, "")
    
    local text = ""
    while true do
        local _, _, char, code = require("event").pull("key_down")
        
        if code == 28 then -- Enter
            break
        elseif code == 14 and unicode.len(text) > 0 then -- Backspace
            text = unicode.sub(text, 1, -2)
            gpu.setBackground(colors.inputBg)
            gpu.fill(inputX, y, maxLen, 1, " ")
            if hidden then
                gpu.set(inputX, y, string.rep("•", unicode.len(text)))
            else
                gpu.set(inputX, y, text)
            end
        elseif char >= 32 and char < 127 and unicode.len(text) < maxLen then
            text = text .. string.char(char)
            if hidden then
                gpu.set(inputX, y, string.rep("•", unicode.len(text)))
            else
                gpu.set(inputX, y, text)
            end
        end
    end
    
    gpu.setBackground(colors.bg)
    return text
end

local function drawCard(y, cardName, username)
    -- Center the card (40 chars wide)
    local cardWidth = 40
    local x = math.floor((w - cardWidth) / 2)
    
    -- Draw a visual card representation
    gpu.setBackground(colors.inputBg)
    gpu.fill(x, y, cardWidth, 8, " ")
    
    -- Card border
    gpu.setForeground(colors.cardGold)
    gpu.set(x, y, "╔" .. string.rep("═", cardWidth - 2) .. "╗")
    for i = 1, 6 do
        gpu.set(x, y + i, "║")
        gpu.set(x + cardWidth - 1, y + i, "║")
    end
    gpu.set(x, y + 7, "╚" .. string.rep("═", cardWidth - 2) .. "╝")
    
    -- Card content (centered within card)
    gpu.setForeground(colors.text)
    local line1 = "💳 " .. cardName
    gpu.set(x + math.floor((cardWidth - unicode.len(line1)) / 2), y + 2, line1)
    
    gpu.setForeground(colors.textDim)
    local line2 = "Account: " .. username
    gpu.set(x + math.floor((cardWidth - unicode.len(line2)) / 2), y + 4, line2)
    
    gpu.setForeground(colors.cardGold)
    local line3 = "★ BANK CARD ★"
    gpu.set(x + math.floor((cardWidth - unicode.len(line3)) / 2), y + 6, line3)
    
    gpu.setBackground(colors.bg)
end

-- Main program
clear()
drawHeader("◆ MAGNETIC CARD WRITER ◆", "Create secure bank access cards")

-- Welcome screen - centered box
local boxWidth = 50
local boxX = math.floor((w - boxWidth) / 2)
drawBox(boxX, 6, boxWidth, 8, "═ CARD CREATION ═")

centerText(8, "This tool creates magnetic bank cards", colors.textDim)
centerText(9, "that store your account credentials.", colors.textDim)

centerText(11, "⚠ Keep your card secure!", colors.warning)

centerText(13, "Press any key to continue...", colors.text)
require("event").pull("key_down")

-- Input screen
clear()
drawHeader("◆ MAGNETIC CARD WRITER ◆", "Enter account credentials")

local boxWidth = 60
local boxX = math.floor((w - boxWidth) / 2)
drawBox(boxX, 6, boxWidth, 14)

centerText(7, "ACCOUNT INFORMATION", colors.accent)
centerText(8, "Enter your banking credentials below", colors.textDim)

local username = input("Username:     ", 11, false, 25)

if not username or username == "" then
    centerText(h - 1, "✗ Username cannot be empty!", colors.error)
    os.sleep(2)
    return
end

local password = input("Password:     ", 13, true, 25)

if not password or password == "" then
    centerText(h - 1, "✗ Password cannot be empty!", colors.error)
    os.sleep(2)
    return
end

centerText(15, "Optional: Give your card a custom name", colors.textDim)

local cardName = input("Card Label:   ", 17, false, 25)

if cardName == "" or not cardName then
    cardName = username .. "'s Bank Card"
end

-- Confirmation screen
clear()
drawHeader("◆ MAGNETIC CARD WRITER ◆", "Review and confirm")

local boxWidth = 70
local boxX = math.floor((w - boxWidth) / 2)
drawBox(boxX, 6, boxWidth, 18)

centerText(7, "CARD PREVIEW", colors.accent)

-- Draw the card (centered)
drawCard(10, cardName, username)

centerText(19, "Security Information:", colors.textDim)
centerText(20, "• Password length: " .. #password .. " characters", colors.textDim)
centerText(21, "• Card data will be encrypted on the magnetic strip", colors.textDim)
centerText(22, "• Keep this card as secure as a credit card", colors.textDim)

centerText(24, "⚠ WARNING: Anyone with this card can access your account!", colors.warning)

-- Centered input prompt
local promptText = "Type 'YES' to write card, or 'NO' to cancel: "
local promptX = math.floor((w - unicode.len(promptText) - 6) / 2)
gpu.setForeground(colors.text)
gpu.set(promptX, 26, promptText)
gpu.setBackground(colors.inputBg)
gpu.fill(promptX + unicode.len(promptText), 26, 6, 1, " ")
gpu.set(promptX + unicode.len(promptText) + 1, 26, "")

local confirm = ""
while true do
    local _, _, char, code = require("event").pull("key_down")
    if code == 28 then break
    elseif code == 14 and #confirm > 0 then
        confirm = confirm:sub(1, -2)
        gpu.setBackground(colors.inputBg)
        gpu.fill(promptX + unicode.len(promptText) + 1, 26, 5, 1, " ")
        gpu.set(promptX + unicode.len(promptText) + 1, 26, confirm)
    elseif char >= 32 and char < 127 and #confirm < 5 then
        confirm = confirm .. string.char(char)
        gpu.set(promptX + unicode.len(promptText) + 1, 26, confirm)
    end
end

gpu.setBackground(colors.bg)

if confirm:upper() ~= "YES" then
    centerText(h - 1, "✗ Card creation cancelled", colors.warning)
    os.sleep(2)
    return
end

-- Writing screen
clear()
drawHeader("◆ MAGNETIC CARD WRITER ◆", "Writing card data")

local boxWidth = 50
local boxX = math.floor((w - boxWidth) / 2)
drawBox(boxX, 8, boxWidth, 12)

centerText(9, "CARD WRITING IN PROGRESS", colors.accent)

centerText(11, "Insert blank magnetic card now", colors.text)
centerText(12, "into the card writer...", colors.text)

local dataSize = #serialization.serialize({username=username, password=password})
centerText(15, "Data size: " .. dataSize .. " bytes", colors.textDim)
centerText(16, "Encoding: Magnetic strip encryption", colors.textDim)

centerText(18, "Press ENTER when card is inserted", colors.text)

require("event").pull("key_down")

-- Create card data
local cardData = {
    type = "bank_card",
    username = username,
    password = password,
    name = cardName,
    created = os.time(),
    version = "1.0"
}

local serialized = serialization.serialize(cardData)

centerText(20, "⚡ Writing data...", colors.warning)
os.sleep(0.5)

-- Write to card
local success, err = pcall(function()
    cardWriter.write(serialized, cardName, false)
end)

os.sleep(0.5)

-- Result screen
clear()

if success then
    drawHeader("◆ MAGNETIC CARD WRITER ◆", "Card created successfully")
    
    local boxWidth = 60
    local boxX = math.floor((w - boxWidth) / 2)
    drawBox(boxX, 6, boxWidth, 30)
    
    centerText(7, "✓ CARD CREATED SUCCESSFULLY!", colors.success)
    
    centerText(9, "═══════════════════════════════════════════════════════", colors.accent)
    
    -- Draw the completed card
    drawCard(11, cardName, username)
    
    centerText(20, "Card Details:", colors.text)
    centerText(21, "• Name: " .. cardName, colors.textDim)
    centerText(22, "• User: " .. username, colors.textDim)
    centerText(23, "• Date: " .. os.date("%Y-%m-%d %H:%M"), colors.textDim)
    
    centerText(25, "═══════════════════════════════════════════════════════", colors.accent)
    
    centerText(27, "Usage Instructions:", colors.success)
    centerText(28, "1. Remove card from writer", colors.textDim)
    centerText(29, "2. Go to ATM with card reader", colors.textDim)
    centerText(30, "3. Swipe card when prompted", colors.textDim)
    centerText(31, "4. Card will auto-login", colors.textDim)
    
    centerText(33, "⚠ SECURITY: Keep this card safe!", colors.warning)
    centerText(34, "This card contains your password.", colors.textDim)
    
    centerText(36, "Remove card when ready. Press any key to exit...", colors.text)
    
else
    drawHeader("◆ MAGNETIC CARD WRITER ◆", "Error occurred")
    
    local boxWidth = 60
    local boxX = math.floor((w - boxWidth) / 2)
    drawBox(boxX, 8, boxWidth, 22)
    
    centerText(9, "✗ CARD WRITING FAILED", colors.error)
    
    centerText(11, "═══════════════════════════════════════════════════════", colors.accent)
    
    centerText(13, "Error Details:", colors.text)
    local errorMsg = tostring(err)
    if #errorMsg > 50 then
        errorMsg = errorMsg:sub(1, 47) .. "..."
    end
    centerText(14, errorMsg, colors.error)
    
    centerText(16, "═══════════════════════════════════════════════════════", colors.accent)
    
    centerText(18, "Possible Causes:", colors.warning)
    centerText(19, "• Card already contains data", colors.textDim)
    centerText(20, "• Card not properly inserted", colors.textDim)
    centerText(21, "• Wrong type of card", colors.textDim)
    centerText(22, "• Card writer malfunction", colors.textDim)
    
    centerText(24, "Solutions:", colors.text)
    centerText(25, "1. Use a blank magnetic card", colors.textDim)
    centerText(26, "2. Check card is fully inserted", colors.textDim)
    centerText(27, "3. Try a different card", colors.textDim)
    centerText(28, "4. Restart card writer", colors.textDim)
    
    centerText(30, "Press any key to exit...", colors.text)
end

require("event").pull("key_down")

-- Cleanup
clear()
gpu.setForeground(colors.text)
print("Card Writer closed.")
