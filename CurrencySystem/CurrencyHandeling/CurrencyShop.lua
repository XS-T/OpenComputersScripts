-- SHOP.lua - Digital Currency Shop with AE2 ME Export Bus
-- Players swipe card, browse items, purchase with bank account, items dispensed
-- v2.2 - Inventory Controller Support, Session Keep-Alive, Multi-Slot Dispensing

local component = require("component")
local event = require("event")
local serialization = require("serialization")
local term = require("term")
local computer = require("computer")
local sides = require("sides")
local filesystem = require("filesystem")

-- Check for Data Card (for password encryption)
local hasDataCard = component.isAvailable("data")
local dataCard = hasDataCard and component.data or nil

if not hasDataCard then
    print("WARNING: Data Card not found!")
    print("Password encryption disabled - install a Data Card for security")
    print("Continuing in 5 seconds...")
    os.sleep(5)
end

-- Check for tunnel
if not component.isAvailable("tunnel") then
    print("ERROR: Linked card required!")
    return
end

local tunnel = component.tunnel

-- Check for OpenSecurity mag card reader
if not component.isAvailable("os_magreader") then
    print("ERROR: OpenSecurity Mag Card Reader required!")
    return
end

local cardReader = component.os_magreader
local gpu = component.gpu

-- Check for AE2 Export Bus (required for item dispensing)
local hasExportBus = component.isAvailable("me_exportbus")
local exportBus = hasExportBus and component.me_exportbus or nil

-- Check for Database (required for item filtering)
local hasDatabase = component.isAvailable("database")
local database = hasDatabase and component.database or nil

-- Check for ME Controller (for inventory checking)
local hasME = component.isAvailable("me_controller")
local me = hasME and component.me_controller or nil

-- Check for Inventory Controller (for chest size detection)
local hasInventoryController = component.isAvailable("inventory_controller")
local invController = nil
local invControllers = {}

-- Collect all inventory controllers
if hasInventoryController then
    for address in component.list("inventory_controller") do
        table.insert(invControllers, {
            address = address,
            component = component.proxy(address)
        })
    end
    
    -- Use first one by default (can be changed in config)
    invController = invControllers[1].component
    
    print("Found " .. #invControllers .. " Inventory Controller(s)")
    for i, ctrl in ipairs(invControllers) do
        print("  [" .. i .. "] " .. ctrl.address:sub(1, 8))
    end
end

if not hasInventoryController then
    print("WARNING: Inventory Controller not found!")
    print("Dynamic chest size detection disabled")
    print("Install an Inventory Controller for automatic slot management")
    print("Continuing in 5 seconds...")
    os.sleep(5)
end

if not hasExportBus then
    print("ERROR: ME Export Bus not found!")
    print("Connect an ME Export Bus via an Adapter to this computer.")
    os.sleep(5)
    return
end

if not hasDatabase then
    print("ERROR: Database component not found!")
    print("Craft a Database and install it in the computer.")
    os.sleep(5)
    return
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SHOP CONFIGURATION - Edit these values to customize your shop
-- ═══════════════════════════════════════════════════════════════════════════

-- Shop Information
local SHOP_NAME = "General Store"
local SHOP_ID = "SHOP_" .. tunnel.address:sub(1, 8)

-- Admin Exit Password (for debugging only - separate from owner access)
local ADMIN_EXIT_PASSWORD = "SHOPEXIT2025"  -- Change this!

-- Configuration Files
local CONFIG_FILE = "/home/shop_config.txt"
local CATALOG_FILE = "/home/shop_catalog.txt"

-- Shop Owner (set on first run)
local SHOP_OWNER_USERNAME = nil
local SHOP_OWNER_PASSWORD = nil

-- Item Catalog (loaded from file)
local CATALOG = {}

-- Export Bus Configuration
local EXPORT_BUS_SIDE = sides.south        -- Side where Export Bus Adapter is
local PICKUP_CHEST_SLOT = 1                -- Starting slot in pickup chest

-- Inventory Controller Configuration
local PICKUP_CHEST_SIDE = sides.down       -- Side where pickup chest is located
local MAX_CHEST_SLOTS = 27                 -- Default for standard chest (auto-detected)

-- Inventory Controller Address (REQUIRED if you have inventory controller)
-- To find address: component.list("inventory_controller")
-- Leave as empty string "" if you don't have an inventory controller
local INVENTORY_CONTROLLER_ADDRESS = ""  -- e.g., "abc123-def456-..."

-- Session Keep-Alive Configuration
local lastKeepAlive = 0
local KEEPALIVE_INTERVAL = 120  -- 2 minutes (server timeout is 30 min)

-- Multi-Slot Dispensing
local nextAvailableSlot = 1

-- ═══════════════════════════════════════════════════════════════════════════
-- End of Configuration
-- ═══════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════
-- INVENTORY CONTROLLER FUNCTIONS
-- ═══════════════════════════════════════════════════════════════════════════

-- Detect actual chest size using inventory controller
local function detectChestSize()
    if not hasInventoryController then
        return MAX_CHEST_SLOTS  -- Use default if no controller
    end
    
    local success, size = pcall(invController.getInventorySize, PICKUP_CHEST_SIDE)
    
    if success and size then
        MAX_CHEST_SLOTS = size
        return size
    else
        return MAX_CHEST_SLOTS  -- Fallback to default
    end
end

-- Get empty slots in chest using inventory controller
local function getEmptySlots()
    if not hasInventoryController then
        return {}  -- Can't detect without controller
    end
    
    local emptySlots = {}
    
    for slot = 1, MAX_CHEST_SLOTS do
        local success, stack = pcall(invController.getStackInSlot, PICKUP_CHEST_SIDE, slot)
        
        if success and not stack then
            -- Slot is empty
            table.insert(emptySlots, slot)
        end
    end
    
    return emptySlots
end

-- Find next available empty slot
local function findNextEmptySlot(startSlot)
    if not hasInventoryController then
        -- Without controller, just increment
        return startSlot
    end
    
    for slot = startSlot, MAX_CHEST_SLOTS do
        local success, stack = pcall(invController.getStackInSlot, PICKUP_CHEST_SIDE, slot)
        
        if success and not stack then
            return slot  -- Found empty slot
        end
    end
    
    return nil  -- No empty slots
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CONFIG FILE MANAGEMENT
-- ═══════════════════════════════════════════════════════════════════════════

-- Encryption key derived from tunnel address (16 bytes for AES-128)
local function getEncryptionKey()
    local baseKey = tunnel.address .. "SHOP_ENCRYPT"
    -- Pad or truncate to exactly 16 bytes for AES-128
    if #baseKey < 16 then
        baseKey = baseKey .. string.rep("0", 16 - #baseKey)
    else
        baseKey = baseKey:sub(1, 16)
    end
    return baseKey
end

-- IV (Initialization Vector) for AES - can be stored in plain text
local ENCRYPTION_IV = "ShopTerminalIV16"  -- Exactly 16 bytes for AES

-- Encrypt password using Data Card
local function encryptPassword(password)
    if not hasDataCard then
        -- No encryption available - store plaintext with warning marker
        return "PLAIN:" .. password
    end
    
    local key = getEncryptionKey()
    local encrypted = dataCard.encrypt(password, key, ENCRYPTION_IV)
    return "AES:" .. dataCard.encode64(encrypted)
end

-- Decrypt password using Data Card
local function decryptPassword(encrypted)
    if not encrypted then
        return nil
    end
    
    -- Check if plaintext (no Data Card was available)
    if encrypted:sub(1, 6) == "PLAIN:" then
        return encrypted:sub(7)
    end
    
    -- Check if AES encrypted
    if encrypted:sub(1, 4) == "AES:" then
        if not hasDataCard then
            error("Data Card required to decrypt password!")
        end
        
        local key = getEncryptionKey()
        local encryptedData = dataCard.decode64(encrypted:sub(5))
        local decrypted = dataCard.decrypt(encryptedData, key, ENCRYPTION_IV)
        return decrypted
    end
    
    -- Old format or corrupted
    return encrypted
end

local function saveShopConfig()
    local config = {
        shopName = SHOP_NAME,
        ownerUsername = SHOP_OWNER_USERNAME,
        ownerPassword = encryptPassword(SHOP_OWNER_PASSWORD),  -- Encrypt before saving
        exportBusSide = EXPORT_BUS_SIDE,
        pickupChestSlot = PICKUP_CHEST_SLOT,
        pickupChestSide = PICKUP_CHEST_SIDE
    }
    
    local file = io.open(CONFIG_FILE, "w")
    if file then
        file:write(serialization.serialize(config))
        file:close()
        return true
    end
    return false
end

local function loadShopConfig()
    if not filesystem.exists(CONFIG_FILE) then
        return false
    end
    
    local file = io.open(CONFIG_FILE, "r")
    if not file then
        return false
    end
    
    local data = file:read("*a")
    file:close()
    
    if data and data ~= "" then
        local success, config = pcall(serialization.unserialize, data)
        if success and config then
            SHOP_NAME = config.shopName or SHOP_NAME
            SHOP_OWNER_USERNAME = config.ownerUsername
            
            -- Decrypt password
            local decryptSuccess, decryptedPassword = pcall(decryptPassword, config.ownerPassword)
            if decryptSuccess then
                SHOP_OWNER_PASSWORD = decryptedPassword
            else
                print("ERROR: Failed to decrypt owner password!")
                print("You may need to delete shop_config.txt and re-setup")
                os.sleep(5)
                return false
            end
            
            EXPORT_BUS_SIDE = config.exportBusSide or EXPORT_BUS_SIDE
            PICKUP_CHEST_SLOT = config.pickupChestSlot or PICKUP_CHEST_SLOT
            PICKUP_CHEST_SIDE = config.pickupChestSide or PICKUP_CHEST_SIDE
            return true
        end
    end
    
    return false
end

local function saveCatalog()
    local file = io.open(CATALOG_FILE, "w")
    if file then
        file:write(serialization.serialize(CATALOG))
        file:close()
        return true
    end
    return false
end

local function loadCatalog()
    if not filesystem.exists(CATALOG_FILE) then
        return false
    end
    
    local file = io.open(CATALOG_FILE, "r")
    if not file then
        return false
    end
    
    local data = file:read("*a")
    file:close()
    
    if data and data ~= "" then
        local success, catalog = pcall(serialization.unserialize, data)
        if success and catalog then
            CATALOG = catalog
            return true
        end
    end
    
    return false
end

-- State
local currentUser = nil
local currentPass = nil
local currentBalance = 0
local sessionActive = false
local cart = {}  -- Shopping cart

-- Set resolution
gpu.setResolution(80, 25)
local w, h = 80, 25

-- Colors
local colors = {
    bg = 0x0F0F0F,
    header = 0x1E3A8A,
    accent = 0x3B82F6,
    success = 0x10B981,
    error = 0xEF4444,
    warning = 0xF59E0B,
    text = 0xFFFFFF,
    textDim = 0x9CA3AF
}

-- Safe print function
local function safePrint(x, y, text, fg, bg)
    if bg then gpu.setBackground(bg) end
    if fg then gpu.setForeground(fg) end
    term.setCursor(x, y)
    io.write(tostring(text))
end

local function clearScreen()
    gpu.setBackground(colors.bg)
    gpu.setForeground(colors.text)
    term.clear()
end

local function drawBox(x, y, width, height, color)
    gpu.setBackground(color or colors.bg)
    for i = y, y + height - 1 do
        term.setCursor(x, i)
        io.write(string.rep(" ", width))
    end
end

local function drawHeader(title)
    gpu.setBackground(colors.header)
    gpu.fill(1, 1, w, 3, " ")
    local x = math.floor((w - #title) / 2)
    safePrint(x, 2, title, colors.text, colors.header)
    gpu.setBackground(colors.bg)
end

local function drawFooter(text)
    gpu.setBackground(colors.header)
    gpu.fill(1, h, w, 1, " ")
    safePrint(2, h, text, colors.textDim, colors.header)
    gpu.setBackground(colors.bg)
end

local function centerText(y, text, fg)
    local x = math.floor((w - #text) / 2)
    safePrint(x, y, text, fg or colors.text)
end

-- Get item stock from ME system
local function getItemStock(itemName)
    if not hasME then
        return nil  -- Unknown stock
    end
    
    local success, items = pcall(me.getItemsInNetwork)
    if not success or not items then
        return nil
    end
    
    for _, item in pairs(items) do
        if item.name == itemName then
            return item.size or 0
        end
    end
    
    return 0  -- Item not in system
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SESSION KEEP-ALIVE
-- ═══════════════════════════════════════════════════════════════════════════

-- Session keep-alive (prevents 30-minute timeout)
local function keepSessionAlive()
    if not sessionActive or not currentUser then
        return
    end
    
    local now = computer.uptime()
    if now - lastKeepAlive > KEEPALIVE_INTERVAL then
        -- Silently refresh session by checking balance
        -- Uses short timeout to not block UI
        local response = sendCommand({
            command = "balance",
            username = currentUser,
            password = currentPass
        }, 2)
        
        if response and response.success then
            currentBalance = response.balance
            lastKeepAlive = now
        else
            -- Session might have expired
            if response and response.message and response.message:find("[Ss]ession") then
                -- Force re-login on next interaction
                sessionActive = false
            end
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ITEM VALIDATION - CRITICAL SECURITY
-- ═══════════════════════════════════════════════════════════════════════════

-- Validate database slot matches expected item
local function validateDatabaseSlot(dbSlot, expectedItemName)
    if not hasDatabase then
        return false, "Database not available"
    end
    
    -- Get item from database slot
    local success, dbItem = pcall(database.get, dbSlot)
    
    if not success or not dbItem then
        return false, "Database slot " .. dbSlot .. " is empty or invalid"
    end
    
    -- Check if item name matches expected
    if dbItem.name ~= expectedItemName then
        return false, string.format(
            "Database slot %d mismatch! Expected '%s' but found '%s'",
            dbSlot,
            expectedItemName,
            dbItem.name or "unknown"
        )
    end
    
    return true, "Validated"
end

-- Validate entire cart before ANY transaction
local function validateCart()
    if not next(cart) then
        return false, "Cart is empty"
    end
    
    -- Validate each item in cart
    for itemName, item in pairs(cart) do
        -- CRITICAL: Check database slot matches catalog
        local valid, err = validateDatabaseSlot(item.dbSlot, itemName)
        if not valid then
            return false, "VALIDATION FAILED: " .. item.label .. " - " .. err
        end
        
        -- Check stock availability
        local stock = getItemStock(itemName)
        if stock then
            if item.quantity > stock then
                return false, string.format(
                    "Insufficient stock for %s (Need: %d, Available: %d)",
                    item.label,
                    item.quantity,
                    stock
                )
            end
        else
            -- If we can't verify stock, fail safe
            return false, "Cannot verify stock availability for " .. item.label
        end
    end
    
    return true, "All items validated"
end

-- ═══════════════════════════════════════════════════════════════════════════
-- IMPROVED EXPORT FUNCTION - Multi-Slot + Non-Stackable Support
-- ═══════════════════════════════════════════════════════════════════════════

-- Export item using ME Export Bus (IMPROVED with Inventory Controller)
local function exportItem(dbSlot, count, startSlot)
    if not hasExportBus then
        return false, "Export Bus not available"
    end
    
    -- Use dynamic slot allocation
    local currentSlot = startSlot or nextAvailableSlot
    
    local success, err = pcall(function()
        -- Configure export bus to export specific item from database slot
        local configured = exportBus.setExportConfiguration(EXPORT_BUS_SIDE, 1, database.address, dbSlot)
        
        if not configured then
            error("Failed to configure export bus")
        end
        
        -- Export items using multiple slots (handles non-stackables and stacks)
        local exported = 0
        local consecutiveFailures = 0  -- Track if we need to move to next slot
        
        for i = 1, count do
            -- Find next empty slot if using inventory controller AND we've had failures
            if hasInventoryController and consecutiveFailures > 0 then
                local emptySlot = findNextEmptySlot(currentSlot)
                if not emptySlot then
                    error("Chest full! Only exported " .. exported .. " of " .. count)
                end
                currentSlot = emptySlot
                consecutiveFailures = 0  -- Reset failure counter for new slot
            end
            
            local result = exportBus.exportIntoSlot(EXPORT_BUS_SIDE, currentSlot)
            
            if result then
                exported = exported + 1
                consecutiveFailures = 0  -- Reset failure counter on success
                -- Stay in same slot to allow stacking
            else
                -- Export failed - slot is probably full or item is non-stackable
                consecutiveFailures = consecutiveFailures + 1
                currentSlot = currentSlot + 1
                
                -- Check if we've run out of space
                if currentSlot > MAX_CHEST_SLOTS then
                    error("Chest full! Only exported " .. exported .. " of " .. count)
                end
                
                -- Retry with next slot
                result = exportBus.exportIntoSlot(EXPORT_BUS_SIDE, currentSlot)
                if result then
                    exported = exported + 1
                    consecutiveFailures = 0  -- Reset on success
                else
                    error("Failed to export item " .. i .. " of " .. count)
                end
            end
        end
        
        if exported < count then
            error("Only exported " .. exported .. " of " .. count)
        end
        
        -- Update next available slot for next item type
        nextAvailableSlot = currentSlot + 1
        
        return true, exported
    end)
    
    if not success then
        return false, tostring(err)
    end
    
    return true, "Exported " .. count .. " items to chest"
end

-- Send command to bank server
local function sendCommand(cmd, timeout)
    timeout = timeout or 5
    
    cmd.tunnelAddress = tunnel.address
    cmd.tunnelChannel = tunnel.getChannel()
    
    local msg = serialization.serialize(cmd)
    tunnel.send(msg)
    
    local deadline = computer.uptime() + timeout
    while computer.uptime() < deadline do
        local eventData = {event.pull(0.5, "modem_message")}
        if eventData[1] then
            local _, _, _, port, _, response = table.unpack(eventData)
            if port == 0 then
                local success, data = pcall(serialization.unserialize, response)
                if success and data and data.type == "response" then
                    return data
                end
            end
        end
    end
    return nil
end

-- Check if current user is shop owner
local function isOwner()
    return currentUser == SHOP_OWNER_USERNAME
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ADMIN PANEL - Catalog Management
-- ═══════════════════════════════════════════════════════════════════════════

-- Add item to catalog
local function adminAddItem()
    clearScreen()
    drawHeader("ADMIN - ADD ITEM")
    
    drawBox(10, 6, 60, 16, colors.bg)
    
    safePrint(15, 7, "Enter Item Details:", colors.accent)
    
    -- Item name
    safePrint(15, 9, "Item Name (e.g., minecraft:diamond):", colors.text)
    safePrint(15, 10, "> ", colors.accent)
    term.setCursor(18, 10)
    gpu.setForeground(colors.text)
    local itemName = term.read()
    if itemName then
        itemName = itemName:gsub("\n", ""):gsub("\r", "")  -- Remove newlines
    end
    
    if not itemName or itemName == "" then
        centerText(20, "Cancelled", colors.error)
        os.sleep(1)
        return
    end
    
    -- Display label
    safePrint(15, 12, "Display Label (e.g., Diamond):", colors.text)
    safePrint(15, 13, "> ", colors.accent)
    term.setCursor(18, 13)
    gpu.setForeground(colors.text)
    local label = term.read()
    if label then
        label = label:gsub("\n", ""):gsub("\r", "")  -- Remove newlines
    end
    
    if not label or label == "" then
        label = itemName
    end
    
    -- Price
    safePrint(15, 15, "Price (CR):", colors.text)
    safePrint(15, 16, "> ", colors.accent)
    term.setCursor(18, 16)
    gpu.setForeground(colors.text)
    local priceStr = term.read()
    if priceStr then
        priceStr = priceStr:gsub("\n", ""):gsub("\r", "")
    end
    local price = tonumber(priceStr)
    
    if not price or price <= 0 then
        centerText(20, "Invalid price", colors.error)
        os.sleep(1)
        return
    end
    
    -- Database slot
    safePrint(15, 18, "Database Slot (1-81):", colors.text)
    safePrint(15, 19, "> ", colors.accent)
    term.setCursor(18, 19)
    gpu.setForeground(colors.text)
    local slotStr = term.read()
    if slotStr then
        slotStr = slotStr:gsub("\n", ""):gsub("\r", "")
    end
    local dbSlot = tonumber(slotStr)
    
    if not dbSlot or dbSlot < 1 or dbSlot > 81 then
        centerText(20, "Invalid slot (must be 1-81)", colors.error)
        os.sleep(1)
        return
    end
    
    -- Category (optional)
    clearScreen()
    drawHeader("ADMIN - ADD ITEM")
    drawBox(10, 6, 60, 10, colors.bg)
    
    safePrint(15, 7, "Item: " .. label, colors.textDim)
    safePrint(15, 8, "Price: " .. price .. " CR", colors.textDim)
    safePrint(15, 9, "DB Slot: " .. dbSlot, colors.textDim)
    
    safePrint(15, 11, "Category (optional, e.g., Materials):", colors.text)
    safePrint(15, 12, "> ", colors.accent)
    term.setCursor(18, 12)
    gpu.setForeground(colors.text)
    local category = term.read()
    if category then
        category = category:gsub("\n", ""):gsub("\r", "")
    end
    if not category or category == "" then
        category = "General"
    end
    
    -- Add to catalog
    table.insert(CATALOG, {
        name = itemName,
        label = label,
        price = price,
        dbSlot = dbSlot,
        category = category
    })
    
    -- Save catalog
    if saveCatalog() then
        centerText(15, "Item added successfully!", colors.success)
    else
        centerText(15, "Added but failed to save to file", colors.warning)
    end
    
    os.sleep(2)
end

-- Remove item from catalog
local function adminRemoveItem()
    clearScreen()
    drawHeader("ADMIN - REMOVE ITEM")
    
    if #CATALOG == 0 then
        drawBox(15, 10, 50, 5, colors.bg)
        centerText(12, "Catalog is empty", colors.textDim)
        centerText(16, "Press Enter to continue", colors.textDim)
        io.read()
        return
    end
    
    drawBox(2, 4, 76, 17, colors.bg)
    
    -- Header
    safePrint(4, 5, "#", colors.textDim)
    safePrint(8, 5, "ITEM", colors.textDim)
    safePrint(40, 5, "PRICE", colors.textDim)
    safePrint(55, 5, "DB SLOT", colors.textDim)
    
    local y = 7
    for i = 1, math.min(12, #CATALOG) do
        local item = CATALOG[i]
        safePrint(4, y, tostring(i), colors.text)
        safePrint(8, y, item.label, colors.text)
        safePrint(40, y, string.format("%.2f CR", item.price), colors.accent)
        safePrint(55, y, tostring(item.dbSlot), colors.textDim)
        y = y + 1
    end
    
    if #CATALOG > 12 then
        centerText(20, "... and " .. (#CATALOG - 12) .. " more items", colors.textDim)
    end
    
    centerText(22, "Enter item number to remove (0 to cancel):", colors.text)
    safePrint(38, 23, "> ", colors.accent)
    term.setCursor(41, 23)
    local numStr = io.read()
    local num = tonumber(numStr)
    
    if not num or num == 0 then
        return
    end
    
    if num < 1 or num > #CATALOG then
        centerText(24, "Invalid item number", colors.error)
        os.sleep(1)
        return
    end
    
    local removedItem = table.remove(CATALOG, num)
    
    if saveCatalog() then
        centerText(24, "Removed: " .. removedItem.label, colors.success)
    else
        centerText(24, "Removed but failed to save", colors.warning)
    end
    
    os.sleep(2)
end

-- Edit item in catalog
local function adminEditItem()
    clearScreen()
    drawHeader("ADMIN - EDIT ITEM")
    
    if #CATALOG == 0 then
        drawBox(15, 10, 50, 5, colors.bg)
        centerText(12, "Catalog is empty", colors.textDim)
        centerText(16, "Press Enter to continue", colors.textDim)
        io.read()
        return
    end
    
    drawBox(2, 4, 76, 17, colors.bg)
    
    -- Header
    safePrint(4, 5, "#", colors.textDim)
    safePrint(8, 5, "ITEM", colors.textDim)
    safePrint(40, 5, "PRICE", colors.textDim)
    safePrint(55, 5, "DB SLOT", colors.textDim)
    
    local y = 7
    for i = 1, math.min(12, #CATALOG) do
        local item = CATALOG[i]
        safePrint(4, y, tostring(i), colors.text)
        safePrint(8, y, item.label, colors.text)
        safePrint(40, y, string.format("%.2f CR", item.price), colors.accent)
        safePrint(55, y, tostring(item.dbSlot), colors.textDim)
        y = y + 1
    end
    
    if #CATALOG > 12 then
        centerText(20, "... and " .. (#CATALOG - 12) .. " more items", colors.textDim)
    end
    
    centerText(22, "Enter item number to edit (0 to cancel):", colors.text)
    safePrint(38, 23, "> ", colors.accent)
    term.setCursor(41, 23)
    local numStr = io.read()
    local num = tonumber(numStr)
    
    if not num or num == 0 then
        return
    end
    
    if num < 1 or num > #CATALOG then
        centerText(24, "Invalid item number", colors.error)
        os.sleep(1)
        return
    end
    
    local item = CATALOG[num]
    
    -- Edit screen
    clearScreen()
    drawHeader("EDIT: " .. item.label)
    
    drawBox(10, 6, 60, 12, colors.bg)
    
    safePrint(15, 7, "Current: " .. item.label .. " - " .. string.format("%.2f CR", item.price), colors.textDim)
    
    -- New price
    safePrint(15, 9, "New Price (Enter to keep " .. item.price .. "):", colors.text)
    safePrint(15, 10, "> ", colors.accent)
    term.setCursor(18, 10)
    gpu.setForeground(colors.text)
    local newPriceStr = term.read()
    if newPriceStr then
        newPriceStr = newPriceStr:gsub("\n", ""):gsub("\r", "")
    end
    
    if newPriceStr and newPriceStr ~= "" then
        local newPrice = tonumber(newPriceStr)
        if newPrice and newPrice > 0 then
            item.price = newPrice
        end
    end
    
    -- New label
    safePrint(15, 12, "New Label (Enter to keep " .. item.label .. "):", colors.text)
    safePrint(15, 13, "> ", colors.accent)
    term.setCursor(18, 13)
    gpu.setForeground(colors.text)
    local newLabel = term.read()
    if newLabel then
        newLabel = newLabel:gsub("\n", ""):gsub("\r", "")
    end
    
    if newLabel and newLabel ~= "" then
        item.label = newLabel
    end
    
    -- New DB slot
    safePrint(15, 15, "New DB Slot (Enter to keep " .. item.dbSlot .. "):", colors.text)
    safePrint(15, 16, "> ", colors.accent)
    term.setCursor(18, 16)
    gpu.setForeground(colors.text)
    local newSlotStr = term.read()
    if newSlotStr then
        newSlotStr = newSlotStr:gsub("\n", ""):gsub("\r", "")
    end
    
    if newSlotStr and newSlotStr ~= "" then
        local newSlot = tonumber(newSlotStr)
        if newSlot and newSlot >= 1 and newSlot <= 81 then
            item.dbSlot = newSlot
        end
    end
    
    if saveCatalog() then
        centerText(18, "Item updated successfully!", colors.success)
    else
        centerText(18, "Updated but failed to save", colors.warning)
    end
    
    os.sleep(2)
end

-- Admin panel menu
local function adminPanel()
    while true do
        clearScreen()
        drawHeader("ADMIN PANEL - " .. SHOP_NAME)
        
        drawBox(15, 7, 50, 2, colors.bg)
        safePrint(20, 8, "Owner:", colors.textDim)
        safePrint(28, 8, tostring(SHOP_OWNER_USERNAME), colors.text)
        
        drawBox(15, 10, 50, 12, colors.bg)
        
        safePrint(25, 11, "[1] Add Item", colors.text)
        safePrint(25, 13, "[2] Edit Item", colors.text)
        safePrint(25, 15, "[3] Remove Item", colors.text)
        safePrint(25, 17, "[4] View Catalog (" .. #CATALOG .. " items)", colors.textDim)
        safePrint(25, 19, "[5] Change Shop Name", colors.text)
        safePrint(25, 21, "[0] Back to Shop", colors.accent)
        
        drawFooter("Admin Panel - Catalog Management")
        
        local _, _, char = event.pull("key_down")
        
        if char == string.byte('1') then
            adminAddItem()
        elseif char == string.byte('2') then
            adminEditItem()
        elseif char == string.byte('3') then
            adminRemoveItem()
        elseif char == string.byte('4') then
            -- View catalog (admin view - no cart functionality)
            clearScreen()
            drawHeader("ADMIN - VIEW CATALOG")
            
            if #CATALOG == 0 then
                drawBox(15, 10, 50, 5, colors.bg)
                centerText(12, "Catalog is empty", colors.textDim)
                centerText(16, "Press Enter to continue", colors.textDim)
                io.read()
            else
                drawBox(2, 4, 76, 17, colors.bg)
                
                -- Header
                safePrint(4, 5, "#", colors.textDim)
                safePrint(8, 5, "ITEM", colors.textDim)
                safePrint(35, 5, "PRICE", colors.textDim)
                safePrint(50, 5, "DB SLOT", colors.textDim)
                safePrint(65, 5, "CATEGORY", colors.textDim)
                
                local y = 7
                for i = 1, math.min(12, #CATALOG) do
                    local item = CATALOG[i]
                    safePrint(4, y, tostring(i), colors.text)
                    safePrint(8, y, item.label, colors.text)
                    safePrint(35, y, string.format("%.2f CR", item.price), colors.accent)
                    safePrint(50, y, tostring(item.dbSlot), colors.textDim)
                    safePrint(65, y, item.category or "General", colors.textDim)
                    y = y + 1
                end
                
                if #CATALOG > 12 then
                    centerText(20, "... and " .. (#CATALOG - 12) .. " more items", colors.textDim)
                end
                
                centerText(22, "Total: " .. #CATALOG .. " items in catalog", colors.accent)
                centerText(24, "Press Enter to continue", colors.textDim)
                io.read()
            end
        elseif char == string.byte('5') then
            clearScreen()
            drawHeader("CHANGE SHOP NAME")
            
            drawBox(15, 10, 50, 8, colors.bg)
            safePrint(20, 11, "Current name:", colors.textDim)
            safePrint(20, 12, SHOP_NAME, colors.text)
            
            safePrint(20, 14, "New name:", colors.text)
            safePrint(20, 15, "> ", colors.accent)
            term.setCursor(23, 15)
            local newName = io.read()
            
            if newName and newName ~= "" then
                SHOP_NAME = newName
                if saveShopConfig() then
                    centerText(17, "Shop name updated!", colors.success)
                else
                    centerText(17, "Updated but failed to save", colors.warning)
                end
            end
            
            os.sleep(2)
        elseif char == string.byte('0') then
            return
        end
    end
end

-- Read card swipe
local function waitForCard()
    clearScreen()
    drawHeader(SHOP_NAME .. " - " .. SHOP_ID)
    
    drawBox(15, 8, 50, 7, colors.bg)
    
    centerText(10, "Please swipe your card...", colors.accent)
    centerText(12, "Card required for shopping", colors.textDim)
    
    drawFooter("AE2 Shop System | Swipe card to begin")
    
    while true do
        local eventData = {event.pull(0.5)}
        
        if eventData[1] == "magData" then
            local _, _, _, data, cardname = table.unpack(eventData)
            
            centerText(14, "Card detected!", colors.success)
            if cardname then
                centerText(15, tostring(cardname), colors.textDim)
            end
            
            os.sleep(0.5)
            
            if data and data ~= "" then
                local success, card = pcall(serialization.unserialize, data)
                if success and card and card.type == "bank_card" and card.username and card.password then
                    return card
                end
                
                if data:find(":") then
                    local username, password = data:match("([^:]+):(.+)")
                    if username and password then
                        return {username = username, password = password}
                    end
                end
            end
            
            centerText(17, "Invalid card format", colors.error)
            os.sleep(2)
            
            clearScreen()
            drawHeader(SHOP_NAME .. " - " .. SHOP_ID)
            centerText(10, "Please swipe your card...", colors.accent)
            centerText(12, "Card required for shopping", colors.textDim)
        end
    end
end

-- Shop Login
local function shopLogin()
    local card = waitForCard()
    
    currentUser = card.username
    currentPass = card.password
    
    clearScreen()
    drawHeader("CARD LOGIN")
    
    drawBox(15, 10, 50, 5, colors.bg)
    centerText(11, "Card holder: " .. tostring(currentUser), colors.text)
    centerText(13, "Authenticating...", colors.textDim)
    
    os.sleep(0.5)
    centerText(15, "Connecting to bank...", colors.accent)
    
    local response = sendCommand({
        command = "login",
        username = currentUser,
        password = currentPass
    })
    
    if response and response.success then
        sessionActive = true
        currentBalance = response.balance
        lastKeepAlive = computer.uptime()  -- Initialize keep-alive timer
        
        clearScreen()
        drawHeader("LOGIN SUCCESSFUL")
        
        drawBox(15, 10, 50, 5, colors.bg)
        centerText(11, "Welcome, " .. tostring(currentUser), colors.success)
        centerText(13, "Balance: " .. string.format("%.2f CR", currentBalance), colors.text)
        
        os.sleep(2)
        return true
    else
        clearScreen()
        drawHeader("LOGIN FAILED")
        
        drawBox(15, 10, 50, 5, colors.bg)
        local errMsg = response and response.message or "No response from server"
        centerText(12, errMsg, colors.error)
        
        centerText(17, "Press Enter to try again", colors.textDim)
        io.read()
        
        currentUser = nil
        currentPass = nil
        return false
    end
end

-- Calculate cart total
local function getCartTotal()
    local total = 0
    for _, item in pairs(cart) do
        total = total + (item.price * item.quantity)
    end
    return total
end

-- Browse catalog
local function browseCatalog()
    local page = 1
    local itemsPerPage = 10
    local maxPage = math.ceil(#CATALOG / itemsPerPage)
    
    while true do
        -- Keep session alive while browsing
        keepSessionAlive()
        
        clearScreen()
        drawHeader("SHOP CATALOG - Page " .. page .. "/" .. maxPage)
        
        drawBox(2, 4, 76, 17, colors.bg)
        
        -- Header
        safePrint(4, 5, "# ", colors.textDim)
        safePrint(7, 5, "ITEM", colors.textDim)
        safePrint(35, 5, "PRICE", colors.textDim)
        safePrint(50, 5, "STOCK", colors.textDim)
        safePrint(65, 5, "IN CART", colors.textDim)
        
        local startIdx = (page - 1) * itemsPerPage + 1
        local endIdx = math.min(startIdx + itemsPerPage - 1, #CATALOG)
        
        local y = 7
        for i = startIdx, endIdx do
            local item = CATALOG[i]
            local stock = getItemStock(item.name)
            local inCart = cart[item.name] and cart[item.name].quantity or 0
            
            safePrint(4, y, tostring(i), colors.text)
            safePrint(7, y, item.label, colors.text)
            safePrint(35, y, string.format("%.2f CR", item.price), colors.accent)
            
            if stock then
                local stockColor = stock > 10 and colors.success or stock > 0 and colors.warning or colors.error
                safePrint(50, y, tostring(stock), stockColor)
            else
                safePrint(50, y, "???", colors.textDim)
            end
            
            if inCart > 0 then
                safePrint(65, y, tostring(inCart), colors.warning)
            end
            
            y = y + 1
        end
        
        -- Cart summary
        local cartTotal = getCartTotal()
        local cartItems = 0
        for _, item in pairs(cart) do
            cartItems = cartItems + item.quantity
        end
        
        drawBox(2, 21, 76, 3, colors.bg)
        safePrint(4, 22, "Cart: " .. cartItems .. " items | Total: " .. string.format("%.2f CR", cartTotal), colors.accent)
        safePrint(50, 22, "Balance: " .. string.format("%.2f CR", currentBalance), colors.success)
        
        drawFooter("[#] Add | [C] Cart | [N]ext | [P]rev | [B]ack")
        
        local _, _, char = event.pull("key_down")
        
        if char == string.byte('n') or char == string.byte('N') then
            if page < maxPage then
                page = page + 1
            end
        elseif char == string.byte('p') or char == string.byte('P') then
            if page > 1 then
                page = page - 1
            end
        elseif char == string.byte('c') or char == string.byte('C') then
            return "cart"
        elseif char == string.byte('b') or char == string.byte('B') then
            return "back"
        elseif char >= string.byte('0') and char <= string.byte('9') then
            -- Add item to cart
            local num = string.char(char)
            
            clearScreen()
            drawHeader("ADD TO CART")
            
            drawBox(15, 10, 50, 8, colors.bg)
            centerText(11, "Item #" .. num .. " (press Enter or type more digits)", colors.text)
            term.setCursor(45, 11)
            local moreDigits = io.read()
            
            -- If user just pressed Enter, use single digit
            if moreDigits then
                moreDigits = moreDigits:gsub("\n", ""):gsub("\r", "")
            end
            
            local itemNum
            if not moreDigits or moreDigits == "" then
                -- User pressed Enter - use single digit
                itemNum = tonumber(num)
            else
                -- User typed more digits
                itemNum = tonumber(num .. moreDigits)
            end
            
            if itemNum and itemNum >= 1 and itemNum <= #CATALOG then
                local item = CATALOG[itemNum]
                
                centerText(13, item.label .. " - " .. string.format("%.2f CR", item.price), colors.accent)
                centerText(14, "Quantity: ", colors.text)
                term.setCursor(45, 14)
                local qtyStr = io.read()
                local qty = tonumber(qtyStr)
                
                if qty and qty > 0 then
                    -- Check stock
                    local stock = getItemStock(item.name)
                    if stock and qty > stock then
                        centerText(16, "Insufficient stock! Only " .. stock .. " available", colors.error)
                        os.sleep(2)
                    else
                        -- Add to cart
                        if not cart[item.name] then
                            cart[item.name] = {
                                label = item.label,
                                price = item.price,
                                quantity = 0,
                                dbSlot = item.dbSlot
                            }
                        end
                        cart[item.name].quantity = cart[item.name].quantity + qty
                        
                        centerText(16, "Added " .. qty .. "x " .. item.label .. " to cart!", colors.success)
                        os.sleep(1)
                    end
                else
                    centerText(16, "Invalid quantity", colors.error)
                    os.sleep(1)
                end
            else
                centerText(13, "Invalid item number", colors.error)
                os.sleep(1)
            end
        end
    end
end

-- View cart and checkout
local function viewCart()
    clearScreen()
    drawHeader("SHOPPING CART")
    
    if not next(cart) then
        drawBox(15, 10, 50, 5, colors.bg)
        centerText(12, "Your cart is empty", colors.textDim)
        centerText(16, "Press Enter to continue", colors.textDim)
        io.read()
        return
    end
    
    drawBox(2, 4, 76, 14, colors.bg)
    
    -- Header
    safePrint(4, 5, "ITEM", colors.textDim)
    safePrint(35, 5, "PRICE", colors.textDim)
    safePrint(50, 5, "QTY", colors.textDim)
    safePrint(60, 5, "TOTAL", colors.textDim)
    
    local y = 7
    local total = 0
    for itemName, item in pairs(cart) do
        safePrint(4, y, item.label, colors.text)
        safePrint(35, y, string.format("%.2f CR", item.price), colors.accent)
        safePrint(50, y, tostring(item.quantity), colors.text)
        
        local itemTotal = item.price * item.quantity
        safePrint(60, y, string.format("%.2f CR", itemTotal), colors.success)
        total = total + itemTotal
        
        y = y + 1
    end
    
    -- Total
    drawBox(2, 18, 76, 3, colors.bg)
    safePrint(4, 19, "TOTAL:", colors.accent)
    safePrint(60, 19, string.format("%.2f CR", total), colors.success)
    
    safePrint(4, 20, "Your Balance:", colors.textDim)
    safePrint(60, 20, string.format("%.2f CR", currentBalance), currentBalance >= total and colors.success or colors.error)
    
    if currentBalance < total then
        centerText(22, "Insufficient funds!", colors.error)
        drawFooter("[B]ack | [C]lear Cart")
    else
        drawFooter("[P]urchase | [C]lear Cart | [B]ack")
    end
    
    local _, _, char = event.pull("key_down")
    
    if char == string.byte('b') or char == string.byte('B') then
        return
    elseif char == string.byte('c') or char == string.byte('C') then
        cart = {}
        centerText(22, "Cart cleared", colors.success)
        os.sleep(1)
        return
    elseif char == string.byte('p') or char == string.byte('P') then
        if currentBalance >= total then
            -- CRITICAL: Validate cart BEFORE any transaction
            clearScreen()
            drawHeader("VALIDATING PURCHASE")
            
            drawBox(15, 10, 50, 8, colors.bg)
            centerText(11, "Validating items...", colors.accent)
            
            local validCart, validError = validateCart()
            
            if not validCart then
                -- VALIDATION FAILED - ABORT EVERYTHING
                centerText(13, "VALIDATION FAILED", colors.error)
                centerText(14, validError, colors.textDim)
                centerText(16, "Transaction ABORTED", colors.error)
                centerText(17, "No charges made", colors.success)
                
                drawFooter("Press Enter to continue")
                io.read()
                return
            end
            
            centerText(13, "Validation passed ✓", colors.success)
            os.sleep(0.5)

            -- Process purchase
            clearScreen()
            drawHeader("PROCESSING PURCHASE")
            
            drawBox(15, 10, 50, 8, colors.bg)
            centerText(11, "Processing payment...", colors.accent)
            
            -- Send transfer command directly using customer's active session
            -- Customer pays shop owner
            local response = sendCommand({
                command = "transfer",
                username = currentUser,
                password = currentPass,
                recipient = SHOP_OWNER_USERNAME,
                amount = total
            })
            
            if not response or not response.success then
                centerText(13, "Payment failed!", colors.error)
                centerText(14, response and response.message or "No response", colors.textDim)
                
                -- Check if it's a session issue
                if response and response.message and response.message:find("[Ss]ession") then
                    centerText(16, "Session may have expired", colors.warning)
                    centerText(17, "Refreshing session...", colors.accent)
                    
                    -- Try to refresh session by checking balance
                    local balanceResponse = sendCommand({
                        command = "balance",
                        username = currentUser,
                        password = currentPass
                    })
                    
                    if balanceResponse and balanceResponse.success then
                        currentBalance = balanceResponse.balance
                        lastKeepAlive = computer.uptime()
                        centerText(18, "Session refreshed! Please retry purchase", colors.success)
                        os.sleep(2)
                        return
                    else
                        -- Session truly expired, force re-login
                        centerText(18, "Please re-login", colors.error)
                        sessionActive = false
                        currentUser = nil
                        currentPass = nil
                        currentBalance = 0
                        cart = {}
                        os.sleep(2)
                        return
                    end
                end
                
                centerText(18, "Press Enter to continue", colors.textDim)
                io.read()
                return
            end
            
            -- Payment successful! Update balance
            currentBalance = response.balance
            lastKeepAlive = computer.uptime()
            
            centerText(13, "Payment successful!", colors.success)
            centerText(14, "Dispensing items...", colors.accent)
            
            os.sleep(1)
            
            -- Dispense items
            clearScreen()
            drawHeader("DISPENSING ITEMS")
            
            drawBox(15, 8, 50, 14, colors.bg)
            
            local y = 9
            
            -- CRITICAL: Detect chest and reset slot counter
            detectChestSize()
            nextAvailableSlot = PICKUP_CHEST_SLOT
            
            -- Check chest space if controller available
            if hasInventoryController then
                local emptySlots = getEmptySlots()
                if #emptySlots == 0 then
                    centerText(y, "ERROR: Pickup chest is full!", colors.error)
                    centerText(y + 1, "Please empty the chest", colors.textDim)
                    centerText(y + 3, "Payment already processed!", colors.warning)
                    centerText(y + 4, "Contact shop owner for refund", colors.textDim)
                    centerText(y + 6, "Press Enter to continue", colors.textDim)
                    io.read()
                    return
                end
                centerText(y, "Chest: " .. #emptySlots .. " empty slots", colors.success)
                y = y + 2
            end
            
            local allExported = true
            
            for itemName, item in pairs(cart) do
                safePrint(20, y, "Dispensing " .. item.quantity .. "x " .. item.label .. "...", colors.text)
                
                -- Use inventory-aware slot allocation
                local success, err = exportItem(item.dbSlot, item.quantity, nextAvailableSlot)
                
                if success then
                    safePrint(65, y, "OK", colors.success)
                else
                    safePrint(62, y, "FAIL", colors.error)
                    -- Show error details if space allows
                    if y + 1 < 20 then
                        local errMsg = tostring(err):sub(1, 45)
                        safePrint(22, y + 1, errMsg, colors.textDim)
                    end
                    allExported = false
                end
                
                y = y + 1
            end
            
            y = y + 1
            
            if allExported then
                centerText(y, "All items dispensed!", colors.success)
                y = y + 1
                centerText(y, "Take items from pickup chest", colors.accent)
                y = y + 2
                centerText(y, "New Balance: " .. string.format("%.2f CR", currentBalance), colors.text)
                
                -- Clear cart
                cart = {}
                
                -- Refresh balance to keep session alive
                local refreshResponse = sendCommand({
                    command = "balance",
                    username = currentUser,
                    password = currentPass
                }, 2)
                
                if refreshResponse and refreshResponse.success then
                    currentBalance = refreshResponse.balance
                    lastKeepAlive = computer.uptime()
                end
            else
                centerText(y, "Some items failed to dispense", colors.error)
                y = y + 1
                centerText(y, "Contact shop owner", colors.textDim)
                y = y + 2
                centerText(y, "Your payment went through", colors.warning)
                centerText(y + 1, "Balance: " .. string.format("%.2f CR", currentBalance), colors.text)
                
                -- Refresh balance even on partial failure
                local refreshResponse = sendCommand({
                    command = "balance",
                    username = currentUser,
                    password = currentPass
                }, 2)
                
                if refreshResponse and refreshResponse.success then
                    currentBalance = refreshResponse.balance
                    lastKeepAlive = computer.uptime()
                end
            end
            
            centerText(22, "Press Enter to continue", colors.textDim)
            io.read()
        end
    end
end

-- Main Menu
local function mainMenu()
    -- Keep session alive
    keepSessionAlive()
    
    clearScreen()
    drawHeader(SHOP_NAME)
    
    drawBox(15, 7, 50, 2, colors.bg)
    safePrint(20, 8, "Customer:", colors.textDim)
    safePrint(31, 8, tostring(currentUser), colors.text)
    
    -- Show different menu for owner
    if isOwner() then
        drawBox(15, 10, 50, 12, colors.bg)
        
        safePrint(25, 11, "[1] Browse Catalog", colors.text)
        safePrint(25, 13, "[2] View Cart", colors.text)
        safePrint(25, 15, "[3] Check Balance", colors.text)
        safePrint(25, 17, "[A] Admin Panel", colors.warning)
        safePrint(25, 19, "[4] Logout", colors.text)
        safePrint(25, 21, "[0] Exit Shop", colors.error)
    else
        drawBox(15, 10, 50, 10, colors.bg)
        
        safePrint(25, 11, "[1] Browse Catalog", colors.text)
        safePrint(25, 13, "[2] View Cart", colors.text)
        safePrint(25, 15, "[3] Check Balance", colors.text)
        safePrint(25, 17, "[4] Logout", colors.text)
        safePrint(25, 19, "[0] Exit Shop", colors.error)
    end
    
    local cartTotal = getCartTotal()
    local footerMsg = "Balance: " .. string.format("%.2f CR", currentBalance) .. " | Cart: " .. string.format("%.2f CR", cartTotal)
    drawFooter(footerMsg)
    
    local _, _, char = event.pull("key_down")
    
    if char == string.byte('1') then
        local result = browseCatalog()
        if result == "cart" then
            viewCart()
        end
    elseif char == string.byte('2') then
        viewCart()
    elseif char == string.byte('3') then
        clearScreen()
        drawHeader("BALANCE INQUIRY")
        
        drawBox(15, 10, 50, 5, colors.bg)
        centerText(11, "Checking balance...", colors.accent)
        
        local response = sendCommand({
            command = "balance",
            username = currentUser,
            password = currentPass
        })
        
        if response and response.success then
            currentBalance = response.balance
            lastKeepAlive = computer.uptime()
            centerText(13, "Balance: " .. string.format("%.2f CR", currentBalance), colors.success)
        else
            centerText(13, "Error checking balance", colors.error)
        end
        
        centerText(17, "Press Enter to continue", colors.textDim)
        io.read()
    elseif (char == string.byte('a') or char == string.byte('A')) and isOwner() then
        adminPanel()
    elseif char == string.byte('4') then
        clearScreen()
        drawHeader("LOGGING OUT")
        centerText(12, "Please wait...", colors.accent)
        
        sendCommand({
            command = "logout",
            username = currentUser,
            password = currentPass
        })
        
        sessionActive = false
        currentUser = nil
        currentPass = nil
        currentBalance = 0
        cart = {}
        
        centerText(14, "Logged out successfully", colors.success)
        os.sleep(1)
    elseif char == string.byte('0') then
        -- Exit shop (password protected)
        clearScreen()
        drawHeader("EXIT SHOP")
        
        drawBox(15, 10, 50, 8, colors.bg)
        centerText(11, "ADMIN ACCESS REQUIRED", colors.error)
        centerText(13, "Enter exit password:", colors.text)
        
        safePrint(25, 15, "Password: ", colors.text)
        term.setCursor(36, 15)
        
        -- Read password (hidden)
        local password = ""
        while true do
            local _, _, ch = event.pull("key_down")
            if ch == 13 then -- Enter
                break
            elseif ch == 8 then -- Backspace
                if #password > 0 then
                    password = password:sub(1, -2)
                    term.setCursor(36 + #password, 15)
                    io.write(" ")
                    term.setCursor(36 + #password, 15)
                end
            elseif ch >= 32 and ch <= 126 then -- Printable characters
                password = password .. string.char(ch)
                io.write("*")
            end
        end
        
        if password == ADMIN_EXIT_PASSWORD then
            clearScreen()
            drawHeader("SHUTTING DOWN")
            centerText(12, "Closing shop...", colors.accent)
            
            -- Logout current user if any
            if currentUser then
                sendCommand({
                    command = "logout",
                    username = currentUser,
                    password = currentPass
                })
            end
            
            centerText(14, "Goodbye!", colors.success)
            os.sleep(1)
            os.exit()
        else
            centerText(18, "Incorrect password!", colors.error)
            os.sleep(2)
        end
    end
end

-- Main Loop
local function main()
    -- Load configuration
    local configLoaded = loadShopConfig()
    local catalogLoaded = loadCatalog()
    
    -- First-time setup if no config exists
    if not configLoaded or not SHOP_OWNER_USERNAME then
        clearScreen()
        drawHeader("FIRST-TIME SETUP")
        
        drawBox(10, 6, 60, 16, colors.bg)
        
        centerText(7, "Welcome to Shop Terminal Setup!", colors.accent)
        centerText(8, "This is a one-time configuration", colors.textDim)
        
        -- Shop name
        safePrint(15, 10, "Shop Name:", colors.text)
        safePrint(15, 11, "> ", colors.accent)
        term.setCursor(18, 11)
        local shopName = io.read()
        if shopName and shopName ~= "" then
            SHOP_NAME = shopName
        end
        
        -- Owner username
        safePrint(15, 13, "Owner Username (bank account):", colors.text)
        safePrint(15, 14, "> ", colors.accent)
        term.setCursor(18, 14)
        SHOP_OWNER_USERNAME = io.read()
        
        if not SHOP_OWNER_USERNAME or SHOP_OWNER_USERNAME == "" then
            centerText(16, "Owner username is required!", colors.error)
            centerText(18, "Please restart and try again", colors.textDim)
            os.sleep(3)
            return
        end
        
        -- Owner password
        safePrint(15, 16, "Owner Password:", colors.text)
        safePrint(15, 17, "> ", colors.accent)
        term.setCursor(18, 17)
        
        -- Read password (hidden)
        SHOP_OWNER_PASSWORD = ""
        while true do
            local _, _, ch = event.pull("key_down")
            if ch == 13 then -- Enter
                break
            elseif ch == 8 then -- Backspace
                if #SHOP_OWNER_PASSWORD > 0 then
                    SHOP_OWNER_PASSWORD = SHOP_OWNER_PASSWORD:sub(1, -2)
                    term.setCursor(18 + #SHOP_OWNER_PASSWORD, 17)
                    io.write(" ")
                    term.setCursor(18 + #SHOP_OWNER_PASSWORD, 17)
                end
            elseif ch >= 32 and ch <= 126 then -- Printable characters
                SHOP_OWNER_PASSWORD = SHOP_OWNER_PASSWORD .. string.char(ch)
                io.write("*")
            end
        end
        
        if not SHOP_OWNER_PASSWORD or SHOP_OWNER_PASSWORD == "" then
            centerText(19, "Owner password is required!", colors.error)
            centerText(21, "Please restart and try again", colors.textDim)
            os.sleep(3)
            return
        end
        
        -- Save configuration
        centerText(19, "Saving configuration...", colors.accent)
        
        if saveShopConfig() then
            centerText(20, "Configuration saved!", colors.success)
        else
            centerText(20, "Failed to save config file", colors.error)
        end
        
        -- Create empty catalog if none exists
        if #CATALOG == 0 then
            centerText(21, "Creating empty catalog...", colors.textDim)
            saveCatalog()
        end
        
        os.sleep(2)
    end
    
    clearScreen()
    drawHeader("SHOP INITIALIZING")
    
    drawBox(15, 9, 50, 15, colors.bg)
    
    safePrint(20, 10, "Shop ID:", colors.textDim)
    safePrint(29, 10, SHOP_ID, colors.text)
    
    safePrint(20, 12, "Shop Name:", colors.textDim)
    safePrint(31, 12, SHOP_NAME, colors.text)
    
    safePrint(20, 14, "Owner:", colors.textDim)
    safePrint(31, 14, SHOP_OWNER_USERNAME, colors.success)
    
    safePrint(20, 16, "Status:", colors.textDim)
    safePrint(29, 16, "Ready", colors.success)
    
    safePrint(20, 18, "Card Reader:", colors.textDim)
    safePrint(33, 18, "Active", colors.success)
    
    safePrint(20, 20, "Export Bus:", colors.textDim)
    safePrint(33, 20, hasExportBus and "Connected" or "Missing", hasExportBus and colors.success or colors.error)
    
    safePrint(20, 22, "Database:", colors.textDim)
    safePrint(33, 22, hasDatabase and "Ready" or "Missing", hasDatabase and colors.success or colors.error)
    
    safePrint(20, 24, "Data Card:", colors.textDim)
    safePrint(33, 24, hasDataCard and "Encryption ON" or "No Encryption", hasDataCard and colors.success or colors.warning)
    
    -- Detect chest size and show inventory controller status
    local chestSize = detectChestSize()
    
    local y = 26
    safePrint(20, y, "Inv Controller:", colors.textDim)
    safePrint(36, y, hasInventoryController and "Connected" or "Missing", 
        hasInventoryController and colors.success or colors.warning)
    
    if hasInventoryController then
        y = y + 1
        safePrint(20, y, "Chest Size:", colors.textDim)
        safePrint(36, y, chestSize .. " slots", colors.success)
    end
    
    y = y + 1
    safePrint(20, y, "Items:", colors.textDim)
    safePrint(36, y, #CATALOG .. " in catalog", #CATALOG > 0 and colors.success or colors.warning)
    
    drawFooter("AE2 Shop System v2.2 - Multi-Slot | Inv Controller | Session Keep-Alive")
    
    if not hasExportBus or not hasDatabase then
        centerText(y + 2, "Cannot start - missing components", colors.error)
        return
    end
    
    if #CATALOG == 0 then
        centerText(y + 2, "Warning: Catalog is empty!", colors.warning)
        centerText(y + 3, "Owner can add items via Admin Panel", colors.textDim)
        os.sleep(3)
    else
        os.sleep(2)
    end
    
    while true do
        if not sessionActive then
            shopLogin()
        else
            mainMenu()
        end
    end
end

-- Run
local success, err = pcall(main)
if not success then
    term.clear()
    print("Shop Error: " .. tostring(err))
end
