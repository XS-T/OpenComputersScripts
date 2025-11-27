-- ATM.lua - Digital Currency ATM with AE2 ME Export/Import Buses
-- v2.2 - Inventory Controller Support, Multi-Slot Dispensing, Session Keep-Alive
-- Uses Database for item filtering and proper ME Export Bus API

local component = require("component")
local event = require("event")
local serialization = require("serialization")
local term = require("term")
local computer = require("computer")
local sides = require("sides")

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

-- Check for AE2 Export Bus (required for withdrawals)
local hasExportBus = component.isAvailable("me_exportbus")
local exportBus = hasExportBus and component.me_exportbus or nil

-- Check for AE2 Import Bus (for deposits)
local hasImportBus = component.isAvailable("me_importbus")
local importBus = hasImportBus and component.me_importbus or nil

-- Check for Database (required for item filtering)
local hasDatabase = component.isAvailable("database")
local database = hasDatabase and component.database or nil

-- Check for Inventory Controller (for reading chest contents and smart dispensing)
local hasDepositInventoryController = false
local hasWithdrawalInventoryController = false
local depositInvController = nil
local withdrawalInvController = nil

-- Collect all inventory controller addresses
local invControllers = {}
for address in component.list("inventory_controller") do
    table.insert(invControllers, address)
end

-- Check for Redstone (for triggering import/export buses)
local hasRedstoneImport = false
local hasRedstoneExport = false
local redstoneImport = nil
local redstoneExport = nil

-- Collect all redstone components
local redstoneComponents = {}
for address in component.list("redstone") do
    table.insert(redstoneComponents, address)
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
-- ATM CONFIGURATION - Edit these values to customize your ATM
-- ═══════════════════════════════════════════════════════════════════════════

-- ATM Register Account (the "cash drawer" account that holds ATM funds)
local ATM_REGISTER_USERNAME = "ATM1"
local ATM_REGISTER_PASSWORD = "atm2025"

-- Admin Exit Password (to exit/shutdown ATM)
local ADMIN_EXIT_PASSWORD = "ATMEXIT2025"  -- Change this to your password!

-- ATM Identification
local ATM_ID = "ATM_" .. tunnel.address:sub(1, 8)

-- Currency item definitions (SORTED HIGH TO LOW for proper change calculation)
local CURRENCY_ITEMS = {
    {name = "swc:galacticCredit3", label = "1000 Credit", value = 1000, dbSlot = 1},
    {name = "swc:galacticCredit2", label = "100 Credit", value = 100, dbSlot = 2},
    {name = "swc:galacticCredit", label = "1 Credit", value = 1, dbSlot = 3}
}

-- Redstone I/O Configuration (if using 2 blocks, specify addresses)
-- To find addresses: component.list("redstone")
-- Leave as nil to auto-detect (uses first for import, second for export)
local IMPORT_REDSTONE_ADDRESS = "3704c089-2748-4ffb-8523-d7fc16baf3c"  -- e.g., "abc123-def456-..."
local EXPORT_REDSTONE_ADDRESS = "b0af5ab0-6d2e-4fa9-b7a2-2dc9b645ffb4"  -- e.g., "xyz789-uvw012-..."

-- Sides configuration
local EXPORT_BUS_SIDE = sides.posz        -- Side where Export Bus Adapter is
local IMPORT_BUS_SIDE = sides.posx        -- Side where Import Bus redstone goes
local DEPOSIT_CHEST_SIDE = sides.down        -- Side where deposit chest is (for inventory controller)
local WITHDRAWAL_CHEST_SIDE = sides.down   -- Side where withdrawal chest is (for inventory controller)
local WITHDRAWAL_CHEST_SLOT = 1            -- Starting slot in withdrawal chest

-- Inventory Controller Configuration
local MAX_WITHDRAWAL_CHEST_SLOTS = 27      -- Default for standard chest (auto-detected)

-- Inventory Controller Addresses (if using 2 controllers, specify addresses)
-- To find addresses: component.list("inventory_controller")
local DEPOSIT_INVENTORY_CONTROLLER_ADDRESS = "aa6643c4-9a7c-45ad-8709-deb2d8633b16"  -- e.g., "abc123-def456-..."
local WITHDRAWAL_INVENTORY_CONTROLLER_ADDRESS = "d9a048eb-4abd-4216-855a-1e57b9358ab1"  -- e.g., "xyz789-uvw012-..."

-- Redstone sides (for triggering buses)
local EXPORT_REDSTONE_SIDE = sides.top     -- Side on export redstone I/O
local IMPORT_REDSTONE_SIDE = sides.down    -- Side on import redstone I/O

-- Timing Configuration
local IMPORT_BASE_DURATION = 1             -- Base seconds for import signal
local IMPORT_PER_ITEM_DURATION = 0.2       -- Additional seconds per item for import

-- Session Keep-Alive Configuration
local lastKeepAlive = 0
local KEEPALIVE_INTERVAL = 120  -- 2 minutes

-- Multi-Slot Dispensing
local nextAvailableSlot = 1

-- ═══════════════════════════════════════════════════════════════════════════
-- End of Configuration
-- ═══════════════════════════════════════════════════════════════════════════

-- Debug file
local debugFile = nil
local DEBUG_FILE_PATH = "/tmp/atm_debug.log"

-- Open debug file
local function openDebugFile()
    debugFile = io.open(DEBUG_FILE_PATH, "w")
    if debugFile then
        debugFile:write("=== ATM Debug Log ===\n")
        debugFile:write("Started: " .. os.date() .. "\n")
        debugFile:write("ATM ID: " .. ATM_ID .. "\n\n")
        debugFile:flush()
    end
end

-- Write to debug file
local function debugLog(message)
    if debugFile then
        debugFile:write(message .. "\n")
        debugFile:flush()
    end
end

-- Close debug file
local function closeDebugFile()
    if debugFile then
        debugFile:write("\n=== End of Log ===\n")
        debugFile:close()
        debugFile = nil
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- INVENTORY CONTROLLER FUNCTIONS
-- ═══════════════════════════════════════════════════════════════════════════

-- Detect actual chest size using inventory controller
local function detectWithdrawalChestSize()
    if not hasWithdrawalInventoryController then
        return MAX_WITHDRAWAL_CHEST_SLOTS
    end
    
    local success, size = pcall(withdrawalInvController.getInventorySize, WITHDRAWAL_CHEST_SIDE)
    
    if success and size then
        MAX_WITHDRAWAL_CHEST_SLOTS = size
        return size
    else
        return MAX_WITHDRAWAL_CHEST_SLOTS
    end
end

-- Get empty slots in withdrawal chest
local function getEmptyWithdrawalSlots()
    if not hasWithdrawalInventoryController then
        return {}
    end
    
    local emptySlots = {}
    
    for slot = 1, MAX_WITHDRAWAL_CHEST_SLOTS do
        local success, stack = pcall(withdrawalInvController.getStackInSlot, WITHDRAWAL_CHEST_SIDE, slot)
        
        if success and not stack then
            table.insert(emptySlots, slot)
        end
    end
    
    return emptySlots
end

-- Find next available empty slot in withdrawal chest
local function findNextEmptyWithdrawalSlot(startSlot)
    if not hasWithdrawalInventoryController then
        return startSlot
    end
    
    for slot = startSlot, MAX_WITHDRAWAL_CHEST_SLOTS do
        local success, stack = pcall(withdrawalInvController.getStackInSlot, WITHDRAWAL_CHEST_SIDE, slot)
        
        if success and not stack then
            return slot
        end
    end
    
    return nil  -- No empty slots
end

-- Function to initialize redstone (call after debug file is opened)
local function initializeRedstone()
    debugLog("DEBUG: ===== INITIALIZING REDSTONE =====")
    debugLog("DEBUG: Found " .. #redstoneComponents .. " redstone I/O block(s)")
    
    -- Assign redstone components based on configuration
    if IMPORT_REDSTONE_ADDRESS and EXPORT_REDSTONE_ADDRESS then
        debugLog("DEBUG: Using manual redstone address configuration")
        
        if component.proxy(IMPORT_REDSTONE_ADDRESS) then
            hasRedstoneImport = true
            redstoneImport = component.proxy(IMPORT_REDSTONE_ADDRESS)
            debugLog("DEBUG: Import redstone assigned to: " .. IMPORT_REDSTONE_ADDRESS:sub(1, 8))
        else
            debugLog("DEBUG: ERROR - Import redstone address not found: " .. IMPORT_REDSTONE_ADDRESS)
        end
        
        if component.proxy(EXPORT_REDSTONE_ADDRESS) then
            hasRedstoneExport = true
            redstoneExport = component.proxy(EXPORT_REDSTONE_ADDRESS)
            debugLog("DEBUG: Export redstone assigned to: " .. EXPORT_REDSTONE_ADDRESS:sub(1, 8))
        else
            debugLog("DEBUG: ERROR - Export redstone address not found: " .. EXPORT_REDSTONE_ADDRESS)
        end
    elseif #redstoneComponents >= 2 then
        debugLog("DEBUG: Auto-detecting redstone (first=import, second=export)")
        
        hasRedstoneImport = true
        redstoneImport = component.proxy(redstoneComponents[1])
        debugLog("DEBUG: Import redstone (auto): " .. redstoneComponents[1]:sub(1, 8))
        
        hasRedstoneExport = true
        redstoneExport = component.proxy(redstoneComponents[2])
        debugLog("DEBUG: Export redstone (auto): " .. redstoneComponents[2]:sub(1, 8))
    elseif #redstoneComponents == 1 then
        debugLog("DEBUG: Only 1 redstone I/O found - using for import only")
        
        hasRedstoneImport = true
        redstoneImport = component.redstone
        debugLog("DEBUG: Import redstone (single): " .. redstoneComponents[1]:sub(1, 8))
        
        hasRedstoneExport = false
        redstoneExport = nil
        debugLog("DEBUG: No export redstone available")
    else
        debugLog("DEBUG: No redstone I/O found!")
    end
    
    debugLog("DEBUG: hasRedstoneImport = " .. tostring(hasRedstoneImport))
    debugLog("DEBUG: hasRedstoneExport = " .. tostring(hasRedstoneExport))
end

-- Function to initialize inventory controller (call after debug file is opened)
local function initializeInventoryController()
    debugLog("DEBUG: ===== INITIALIZING INVENTORY CONTROLLERS =====")
    debugLog("DEBUG: Found " .. #invControllers .. " inventory controller(s)")
    
    -- Assign deposit inventory controller
    if DEPOSIT_INVENTORY_CONTROLLER_ADDRESS then
        debugLog("DEBUG: Using manual deposit inventory controller address configuration")
        
        if component.proxy(DEPOSIT_INVENTORY_CONTROLLER_ADDRESS) then
            hasDepositInventoryController = true
            depositInvController = component.proxy(DEPOSIT_INVENTORY_CONTROLLER_ADDRESS)
            debugLog("DEBUG: Deposit inventory controller assigned to: " .. DEPOSIT_INVENTORY_CONTROLLER_ADDRESS:sub(1, 8))
        else
            debugLog("DEBUG: ERROR - Deposit inventory controller address not found: " .. DEPOSIT_INVENTORY_CONTROLLER_ADDRESS)
        end
    else
        debugLog("DEBUG: No DEPOSIT_INVENTORY_CONTROLLER_ADDRESS set")
    end
    
    -- Assign withdrawal inventory controller
    if WITHDRAWAL_INVENTORY_CONTROLLER_ADDRESS then
        debugLog("DEBUG: Using manual withdrawal inventory controller address configuration")
        
        if component.proxy(WITHDRAWAL_INVENTORY_CONTROLLER_ADDRESS) then
            hasWithdrawalInventoryController = true
            withdrawalInvController = component.proxy(WITHDRAWAL_INVENTORY_CONTROLLER_ADDRESS)
            debugLog("DEBUG: Withdrawal inventory controller assigned to: " .. WITHDRAWAL_INVENTORY_CONTROLLER_ADDRESS:sub(1, 8))
        else
            debugLog("DEBUG: ERROR - Withdrawal inventory controller address not found: " .. WITHDRAWAL_INVENTORY_CONTROLLER_ADDRESS)
        end
    else
        debugLog("DEBUG: No WITHDRAWAL_INVENTORY_CONTROLLER_ADDRESS set")
    end
    
    debugLog("DEBUG: hasDepositInventoryController = " .. tostring(hasDepositInventoryController))
    debugLog("DEBUG: hasWithdrawalInventoryController = " .. tostring(hasWithdrawalInventoryController))
end

-- State
local currentUser = nil
local currentPass = nil
local currentBalance = 0
local sessionActive = false

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
        -- Silently refresh session
        local response = sendCommand({
            command = "balance",
            username = currentUser,
            password = currentPass
        }, 2)
        
        if response and response.success then
            currentBalance = response.balance
            lastKeepAlive = now
        else
            if response and response.message and response.message:find("[Ss]ession") then
                sessionActive = false
            end
        end
    end
end

-- Calculate items needed for amount (Greedy algorithm: high to low)
local function calculateItems(amount)
    debugLog("DEBUG: ===== CALCULATE ITEMS =====")
    debugLog("DEBUG: Amount to calculate: " .. amount)
    
    local items = {}
    local remaining = amount
    
    debugLog("DEBUG: Starting calculation with remaining = " .. remaining)
    debugLog("DEBUG: CURRENCY_ITEMS count: " .. #CURRENCY_ITEMS)
    
    for i, currency in ipairs(CURRENCY_ITEMS) do
        debugLog("DEBUG: [" .. i .. "] Checking " .. currency.label .. " (value=" .. currency.value .. ")")
        debugLog("DEBUG:   Remaining before: " .. remaining)
        
        if remaining >= currency.value then
            local count = math.floor(remaining / currency.value)
            debugLog("DEBUG:   Count: " .. count)
            
            remaining = remaining - (count * currency.value)
            debugLog("DEBUG:   Remaining after: " .. remaining)
            
            table.insert(items, {
                name = currency.name,
                label = currency.label,
                count = count,
                value = currency.value * count,
                dbSlot = currency.dbSlot
            })
            
            debugLog("DEBUG:   Added " .. count .. "x " .. currency.label .. " to items list")
        else
            debugLog("DEBUG:   Skipped (not enough remaining)")
        end
    end
    
    debugLog("DEBUG: Calculation complete!")
    debugLog("DEBUG: Total items to dispense: " .. #items)
    debugLog("DEBUG: Final remaining: " .. remaining)
    
    return items, remaining
end

-- ═══════════════════════════════════════════════════════════════════════════
-- IMPROVED EXPORT FUNCTION - Multi-Slot + Non-Stackable Support
-- ═══════════════════════════════════════════════════════════════════════════

-- Export item using ME Export Bus (IMPROVED with Inventory Controller)
local function exportItem(itemDbSlot, count, startSlot)
    debugLog("DEBUG: ===== EXPORT ITEM =====")
    debugLog("DEBUG: itemDbSlot: " .. itemDbSlot)
    debugLog("DEBUG: count: " .. count)
    debugLog("DEBUG: startSlot: " .. startSlot)
    
    if not hasExportBus then
        debugLog("DEBUG: ERROR - No export bus available!")
        return false, "Export Bus not available"
    end
    
    debugLog("DEBUG: Export bus available")
    
    -- Use dynamic slot allocation
    local currentSlot = startSlot or nextAvailableSlot
    
    local success, err = pcall(function()
        debugLog("DEBUG: Configuring export bus...")
        debugLog("DEBUG:   EXPORT_BUS_SIDE: " .. EXPORT_BUS_SIDE)
        debugLog("DEBUG:   database.address: " .. database.address)
        debugLog("DEBUG:   itemDbSlot: " .. itemDbSlot)
        
        local configured = exportBus.setExportConfiguration(EXPORT_BUS_SIDE, 1, database.address, itemDbSlot)
        
        debugLog("DEBUG: setExportConfiguration returned: " .. tostring(configured))
        
        if not configured then
            debugLog("DEBUG: ERROR - Failed to configure export bus!")
            error("Failed to configure export bus")
        end
        
        debugLog("DEBUG: Export bus configured successfully")
        debugLog("DEBUG: Starting export loop for " .. count .. " items...")
        
        -- Export items using multiple slots (handles stacking and non-stackables)
        local exported = 0
        local consecutiveFailures = 0  -- Track if we need to move to next slot
        
        for i = 1, count do
            -- Find next empty slot if using inventory controller AND we've had failures
            if hasWithdrawalInventoryController and consecutiveFailures > 0 then
                local emptySlot = findNextEmptyWithdrawalSlot(currentSlot)
                if not emptySlot then
                    error("Chest full! Only exported " .. exported .. " of " .. count)
                end
                currentSlot = emptySlot
                consecutiveFailures = 0  -- Reset failure counter for new slot
            end
            
            debugLog("DEBUG:   Attempt " .. i .. "/" .. count .. " to slot " .. currentSlot)
            
            local result = exportBus.exportIntoSlot(EXPORT_BUS_SIDE, currentSlot)
            
            debugLog("DEBUG:     exportIntoSlot returned: " .. tostring(result))
            
            if result then
                exported = exported + 1
                debugLog("DEBUG:     SUCCESS! Total exported: " .. exported .. "/" .. count)
                consecutiveFailures = 0  -- Reset failure counter on success
                -- Stay in same slot to allow stacking
            else
                -- Export failed - slot is probably full or item is non-stackable
                debugLog("DEBUG:     FAILED! Moving to next slot")
                consecutiveFailures = consecutiveFailures + 1
                currentSlot = currentSlot + 1
                
                if currentSlot > MAX_WITHDRAWAL_CHEST_SLOTS then
                    error("Chest full! Only exported " .. exported .. " of " .. count)
                end
                
                -- Retry with next slot
                result = exportBus.exportIntoSlot(EXPORT_BUS_SIDE, currentSlot)
                if result then
                    exported = exported + 1
                    consecutiveFailures = 0  -- Reset on success
                else
                    debugLog("DEBUG:     FAILED! Stopping export")
                    break
                end
            end
        end
        
        debugLog("DEBUG: Export loop finished. Exported " .. exported .. " out of " .. count)
        
        if exported < count then
            debugLog("DEBUG: ERROR - Not all items exported!")
            error("Only exported " .. exported .. " of " .. count)
        end
        
        -- Update next available slot for next item type
        nextAvailableSlot = currentSlot + 1
        
        debugLog("DEBUG: All items exported successfully!")
        return true, exported
    end)
    
    if not success then
        debugLog("DEBUG: Export FAILED with error: " .. tostring(err))
        return false, tostring(err)
    end
    
    debugLog("DEBUG: Export completed successfully")
    return true, "Exported " .. count .. " items"
end

-- Trigger import bus with redstone signal
local function triggerImportBus(itemCount)
    debugLog("DEBUG: ===== TRIGGER IMPORT BUS =====")
    
    -- Configure import bus if available
    if hasImportBus and hasDatabase then
        debugLog("DEBUG: Configuring import bus with currency items...")
        
        -- Configure import bus to accept all currency items
        for i, currency in ipairs(CURRENCY_ITEMS) do
            debugLog("DEBUG:   Slot " .. i .. ": " .. currency.label .. " (dbSlot " .. currency.dbSlot .. ")")
            
            local success, err = pcall(function()
                importBus.setImportConfiguration(IMPORT_BUS_SIDE, i, database.address, currency.dbSlot)
            end)
            
            if success then
                debugLog("DEBUG:   ✓ Configured slot " .. i)
            else
                debugLog("DEBUG:   ✗ Failed to configure slot " .. i .. ": " .. tostring(err))
            end
        end
        
        debugLog("DEBUG: Import bus configured with " .. #CURRENCY_ITEMS .. " currency types")
    else
        if not hasImportBus then
            debugLog("DEBUG: WARNING - No import bus available, cannot configure filters")
        end
        if not hasDatabase then
            debugLog("DEBUG: WARNING - No database available, cannot configure filters")
        end
    end
    
    -- Trigger redstone signal
    if not hasRedstoneImport then
        debugLog("DEBUG: triggerImportBus called but no redstone available")
        return false, "Redstone not available"
    end
    
    local totalDuration = IMPORT_BASE_DURATION + (itemCount * IMPORT_PER_ITEM_DURATION)
    totalDuration = math.max(2, math.min(10, totalDuration))
    
    debugLog("DEBUG: Triggering import bus with redstone")
    debugLog("DEBUG:   Item count: " .. itemCount)
    debugLog("DEBUG:   Total duration: " .. totalDuration .. "s")
    
    redstoneImport.setOutput(IMPORT_REDSTONE_SIDE, 15)
    debugLog("DEBUG:   Redstone ON (strength 15)")
    
    os.sleep(totalDuration)
    
    redstoneImport.setOutput(IMPORT_REDSTONE_SIDE, 0)
    debugLog("DEBUG:   Redstone OFF (after " .. totalDuration .. "s)")
    
    return true
end

-- Verify items in deposit chest match the amount
local function verifyDepositChest(expectedAmount)
    debugLog("DEBUG: ===== VERIFY DEPOSIT CHEST =====")
    debugLog("DEBUG: Expected amount: " .. expectedAmount .. " CR")
    debugLog("DEBUG: DEPOSIT_CHEST_SIDE: " .. DEPOSIT_CHEST_SIDE)
    
    if not hasDepositInventoryController then
        debugLog("DEBUG: No deposit inventory controller available!")
        return true, "Cannot verify - no inventory controller"
    end
    
    local success, chestSize = pcall(depositInvController.getInventorySize, DEPOSIT_CHEST_SIDE)
    debugLog("DEBUG: getInventorySize success: " .. tostring(success))
    debugLog("DEBUG: Chest size: " .. tostring(chestSize))
    
    if not success or not chestSize then
        debugLog("DEBUG: ERROR - Cannot access chest!")
        debugLog("DEBUG: Make sure deposit chest is on side: " .. DEPOSIT_CHEST_SIDE)
        return false, "Cannot access deposit chest - check side configuration"
    end
    
    debugLog("DEBUG: CURRENCY_ITEMS configuration:")
    for i, currency in ipairs(CURRENCY_ITEMS) do
        debugLog("DEBUG:   [" .. i .. "] name='" .. currency.name .. "', value=" .. currency.value .. ", label='" .. currency.label .. "'")
    end
    
    local totalValue = 0
    local itemCounts = {}
    local itemDetails = {}
    local foundItems = {}  -- Track all items found for debugging
    
    debugLog("DEBUG: Starting chest scan, size=" .. chestSize)
    
    for slot = 1, chestSize do
        local getSuccess, stack = pcall(depositInvController.getStackInSlot, DEPOSIT_CHEST_SIDE, slot)
        
        if getSuccess then
            if stack then
                debugLog("DEBUG: Slot " .. slot .. " - Found item")
                debugLog("DEBUG:   stack.name: " .. tostring(stack.name))
                debugLog("DEBUG:   stack.label: " .. tostring(stack.label))
                debugLog("DEBUG:   stack.size: " .. tostring(stack.size))
                debugLog("DEBUG:   stack.maxSize: " .. tostring(stack.maxSize))
                
                -- Store for debugging
                table.insert(foundItems, {
                    slot = slot,
                    name = stack.name or "nil",
                    label = stack.label or "nil",
                    size = stack.size or 0
                })
            else
                debugLog("DEBUG: Slot " .. slot .. " - Empty")
            end
        else
            debugLog("DEBUG: Slot " .. slot .. " - Error reading: " .. tostring(stack))
        end
        
        if getSuccess and stack and stack.name then
            local matchedCurrency = nil
            
            -- Try exact match first
            for i, currency in ipairs(CURRENCY_ITEMS) do
                debugLog("DEBUG:   Comparing '" .. stack.name .. "' with '" .. currency.name .. "'")
                if stack.name == currency.name then
                    matchedCurrency = currency
                    debugLog("DEBUG:   EXACT MATCH with " .. currency.label)
                    break
                end
            end
            
            -- If no exact match, try label matching as fallback
            if not matchedCurrency then
                debugLog("DEBUG:   No exact match, trying label matching...")
                for i, currency in ipairs(CURRENCY_ITEMS) do
                    if stack.label and stack.label:find(currency.label) then
                        matchedCurrency = currency
                        debugLog("DEBUG:   LABEL MATCH with " .. currency.label)
                        break
                    end
                end
            end
            
            if matchedCurrency then
                local count = stack.size or 1
                local slotValue = matchedCurrency.value * count
                totalValue = totalValue + slotValue
                
                debugLog("DEBUG: ✓ Matched currency: " .. matchedCurrency.label)
                debugLog("DEBUG:   Count: " .. count)
                debugLog("DEBUG:   Unit value: " .. matchedCurrency.value)
                debugLog("DEBUG:   Slot value: " .. slotValue)
                debugLog("DEBUG:   Running total: " .. totalValue)
                
                itemCounts[matchedCurrency.label] = (itemCounts[matchedCurrency.label] or 0) + count
                
                table.insert(itemDetails, {
                    slot = slot,
                    name = stack.name,
                    label = matchedCurrency.label,
                    count = count,
                    unitValue = matchedCurrency.value,
                    totalValue = slotValue
                })
            else
                debugLog("DEBUG: ✗ No match for item: " .. stack.name)
            end
        end
    end
    
    debugLog("DEBUG: ========================================")
    debugLog("DEBUG: SCAN SUMMARY:")
    debugLog("DEBUG: Total items found: " .. #foundItems)
    for i, item in ipairs(foundItems) do
        debugLog("DEBUG:   [" .. item.slot .. "] " .. item.name .. " (x" .. item.size .. ")")
    end
    debugLog("DEBUG: Total value calculated: " .. totalValue .. " CR")
    debugLog("DEBUG: Expected amount: " .. expectedAmount .. " CR")
    debugLog("DEBUG: ========================================")
    
    if totalValue < expectedAmount then
        debugLog("DEBUG: FAIL - Not enough (" .. totalValue .. " < " .. expectedAmount .. ")")
        return false, "Chest only has " .. totalValue .. " CR worth of items (need " .. expectedAmount .. " CR)", itemCounts, itemDetails
    end
    
    debugLog("DEBUG: PASS - Enough items (" .. totalValue .. " >= " .. expectedAmount .. ")")
    
    return true, "Verified " .. totalValue .. " CR in chest", itemCounts, itemDetails
end

-- Send command to server
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

-- Read card swipe
local function waitForCard()
    clearScreen()
    drawHeader("ATM - " .. ATM_ID)
    
    drawBox(15, 8, 50, 7, colors.bg)
    
    centerText(10, "Please swipe your card...", colors.accent)
    centerText(12, "Card required for access", colors.textDim)
    
    local statusMsg = "Card Reader Active | AE2 Export Bus Connected"
    drawFooter(statusMsg)
    
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
            drawHeader("ATM - " .. ATM_ID)
            centerText(10, "Please swipe your card...", colors.accent)
            centerText(12, "Card required for access", colors.textDim)
        end
    end
end

-- ATM Login
local function atmLogin()
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
        lastKeepAlive = computer.uptime()
        
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

-- Check Balance
local function checkBalance()
    clearScreen()
    drawHeader("BALANCE INQUIRY")
    
    drawBox(15, 10, 50, 3, colors.bg)
    centerText(11, "Checking balance...", colors.accent)
    
    local response = sendCommand({
        command = "balance",
        username = currentUser,
        password = currentPass
    })
    
    clearScreen()
    drawHeader("BALANCE INQUIRY")
    
    if response and response.success then
        currentBalance = response.balance
        lastKeepAlive = computer.uptime()
        
        drawBox(15, 9, 50, 6, colors.bg)
        
        safePrint(20, 10, "Account:", colors.textDim)
        safePrint(30, 10, tostring(currentUser), colors.text)
        
        safePrint(20, 12, "Balance:", colors.textDim)
        safePrint(30, 12, string.format("%.2f CR", currentBalance), colors.success)
    else
        drawBox(15, 10, 50, 3, colors.bg)
        centerText(11, "Error: " .. (response and response.message or "No response"), colors.error)
    end
    
    centerText(17, "Press Enter to continue", colors.textDim)
    drawFooter("Account: " .. tostring(currentUser))
    io.read()
end

-- Withdraw Cash
local function withdrawCash()
    clearScreen()
    drawHeader("CASH WITHDRAWAL")
    
    drawBox(15, 8, 50, 10, colors.bg)
    
    safePrint(20, 9, "Available:", colors.textDim)
    safePrint(31, 9, string.format("%.2f CR", currentBalance), colors.text)
    
    safePrint(20, 11, "Withdrawal amount: ", colors.text)
    term.setCursor(40, 11)
    local amountStr = io.read()
    local amount = tonumber(amountStr)
    
    if not amount or amount <= 0 then
        centerText(14, "Invalid amount", colors.error)
        os.sleep(2)
        return
    end
    
    if amount ~= math.floor(amount) then
        centerText(14, "Amount must be a whole number", colors.error)
        os.sleep(2)
        return
    end
    
    if amount < 1 then
        centerText(14, "Minimum withdrawal: 1 CR", colors.error)
        os.sleep(2)
        return
    end
    
    if amount > currentBalance then
        centerText(14, "Insufficient funds", colors.error)
        os.sleep(2)
        return
    end
    
    -- Calculate items
    local items, remaining = calculateItems(amount)
    
    if remaining > 0 then
        clearScreen()
        drawHeader("WITHDRAWAL")
        drawBox(15, 10, 50, 5, colors.bg)
        centerText(11, "Cannot dispense exact amount", colors.error)
        centerText(12, "Requested: " .. amount .. " CR", colors.textDim)
        centerText(13, "Can dispense: " .. (amount - remaining) .. " CR", colors.success)
        centerText(15, "Press Enter to continue", colors.textDim)
        io.read()
        return
    end
    
    -- Confirm
    clearScreen()
    drawHeader("CONFIRM WITHDRAWAL")
    
    drawBox(15, 9, 50, 8, colors.bg)
    centerText(10, "Withdraw " .. string.format("%.2f CR", amount) .. "?", colors.text)
    
    local y = 12
    for _, item in ipairs(items) do
        safePrint(22, y, item.count .. "x " .. item.label, colors.textDim)
        y = y + 1
    end
    
    centerText(16, "Press Y to confirm, N to cancel", colors.textDim)
    
    local _, _, char = event.pull("key_down")
    if char ~= string.byte('y') and char ~= string.byte('Y') then
        centerText(18, "Cancelled", colors.error)
        os.sleep(1)
        return
    end
    
    -- Transfer money first
    clearScreen()
    drawHeader("PROCESSING")
    centerText(11, "Transferring money...", colors.accent)
    
    local response = sendCommand({
        command = "transfer",
        username = currentUser,
        password = currentPass,
        recipient = ATM_REGISTER_USERNAME,
        amount = amount
    })
    
    if not response or not response.success then
        clearScreen()
        drawHeader("WITHDRAWAL FAILED")
        
        drawBox(15, 10, 50, 3, colors.bg)
        centerText(11, "Transfer failed", colors.error)
        centerText(12, response and response.message or "No response", colors.textDim)
        
        centerText(20, "Press Enter to continue", colors.textDim)
        io.read()
        return
    end
    
    -- Transfer successful! Update balance
    currentBalance = response.balance
    lastKeepAlive = computer.uptime()
    
    clearScreen()
    drawHeader("DISPENSING CASH")
    
    drawBox(15, 9, 50, 14, colors.bg)
    centerText(10, "Transfer successful!", colors.success)
    centerText(11, "Dispensing items...", colors.accent)
    
    local y = 13
    
    -- CRITICAL: Detect chest and reset slot counter
    detectWithdrawalChestSize()
    nextAvailableSlot = WITHDRAWAL_CHEST_SLOT
    
    -- Check chest space if controller available
    if hasWithdrawalInventoryController then
        local emptySlots = getEmptyWithdrawalSlots()
        if #emptySlots == 0 then
            centerText(y, "ERROR: Withdrawal chest is full!", colors.error)
            centerText(y + 1, "Please empty the chest", colors.textDim)
            centerText(y + 3, "Payment already processed!", colors.warning)
            centerText(y + 4, "Contact admin for manual refund", colors.textDim)
            centerText(y + 6, "Press Enter to continue", colors.textDim)
            io.read()
            return
        end
        centerText(y, "Chest: " .. #emptySlots .. " empty slots", colors.success)
        y = y + 2
    end
    
    -- Export items
    local allExported = true
    local dispensedItems = {}
    
    for _, item in ipairs(items) do
        safePrint(20, y, "Exporting " .. item.count .. "x " .. item.label .. "...", colors.textDim)
        
        local success, err = exportItem(item.dbSlot, item.count, nextAvailableSlot)
        
        if success then
            safePrint(55, y, "OK", colors.success)
            table.insert(dispensedItems, {
                label = item.label,
                count = item.count,
                value = item.value
            })
        else
            safePrint(52, y, "FAIL", colors.error)
            if err and y + 1 < 20 then
                local errMsg = tostring(err):sub(1, 45)
                safePrint(22, y + 1, errMsg, colors.textDim)
            end
            allExported = false
        end
        
        y = y + 1
    end
    
    y = y + 1
    
    if allExported then
        centerText(y, "Dispensed successfully!", colors.success)
        y = y + 1
        centerText(y, "Take items from withdrawal chest!", colors.accent)
    else
        centerText(y, "Some items failed to export", colors.error)
        y = y + 1
        centerText(y, "Contact administrator", colors.textDim)
    end
    
    centerText(y + 3, "New balance: " .. string.format("%.2f CR", currentBalance), colors.text)
    
    centerText(22, "Press Enter to continue", colors.textDim)
    io.read()
end

-- Deposit Cash
local function depositCash()
    clearScreen()
    drawHeader("CASH DEPOSIT")
    
    drawBox(15, 8, 50, 12, colors.bg)
    
    safePrint(20, 9, "Current balance:", colors.textDim)
    safePrint(37, 9, string.format("%.2f CR", currentBalance), colors.text)
    
    centerText(11, "Place items in deposit chest", colors.accent)
    centerText(12, "Then enter deposit amount below", colors.textDim)
    
    safePrint(20, 14, "Deposit amount: ", colors.text)
    term.setCursor(37, 14)
    local amountStr = io.read()
    local amount = tonumber(amountStr)
    
    if not amount or amount <= 0 then
        centerText(16, "Invalid amount", colors.error)
        os.sleep(2)
        return
    end
    
    if amount ~= math.floor(amount) then
        centerText(16, "Amount must be a whole number", colors.error)
        os.sleep(2)
        return
    end
    
    -- STEP 1: Verify items in chest FIRST
    clearScreen()
    drawHeader("VERIFYING DEPOSIT")
    
    drawBox(15, 9, 50, 14, colors.bg)
    centerText(10, "Checking deposit chest...", colors.accent)
    
    local verified, message, itemCounts, itemDetails = verifyDepositChest(amount)
    
    if not verified then
        centerText(12, "Verification failed!", colors.error)
        centerText(13, message, colors.textDim)
        
        if itemCounts and next(itemCounts) then
            centerText(15, "Found in chest:", colors.textDim)
            local y = 16
            for label, count in pairs(itemCounts) do
                safePrint(25, y, count .. "x " .. label, colors.text)
                y = y + 1
            end
        else
            centerText(15, "No currency items found", colors.textDim)
        end
        
        centerText(19, "Items NOT taken - still in chest", colors.success)
        centerText(20, "Please deposit correct amount", colors.textDim)
        
        centerText(22, "Press Enter to continue", colors.textDim)
        io.read()
        return
    end
    
    centerText(12, "Items verified!", colors.success)
    centerText(13, message, colors.textDim)
    
    if itemCounts then
        local y = 15
        for label, count in pairs(itemCounts) do
            local itemValue = 0
            for _, currency in ipairs(CURRENCY_ITEMS) do
                if currency.label == label then
                    itemValue = currency.value
                    break
                end
            end
            safePrint(20, y, count .. "x " .. label .. " = " .. (count * itemValue) .. " CR", colors.text)
            y = y + 1
        end
    end
    
    os.sleep(1)
    
    -- STEP 2: Import items
    clearScreen()
    drawHeader("IMPORTING ITEMS")
    
    drawBox(15, 10, 50, 5, colors.bg)
    centerText(11, "Importing items to AE2...", colors.accent)
    centerText(12, "Sending redstone signal...", colors.textDim)
    
    if hasRedstoneImport then
        local totalItems = 0
        if itemCounts then
            for label, count in pairs(itemCounts) do
                totalItems = totalItems + count
            end
        end
        
        triggerImportBus(totalItems)
        centerText(14, "Items imported!", colors.success)
    else
        centerText(14, "No redstone - manual import needed", colors.error)
    end
    
    os.sleep(1)
    
    -- STEP 3: Transfer money
    clearScreen()
    drawHeader("PROCESSING DEPOSIT")
    centerText(11, "Verifying ATM register...", colors.accent)
    
    local savedUser = currentUser
    local savedPass = currentPass
    local savedBalance = currentBalance
    
    sendCommand({
        command = "logout",
        username = currentUser,
        password = currentPass
    })
    
    os.sleep(0.3)
    
    centerText(12, "Authorizing transfer...", colors.textDim)
    
    local atmLoginResponse = sendCommand({
        command = "login",
        username = ATM_REGISTER_USERNAME,
        password = ATM_REGISTER_PASSWORD
    })
    
    if not atmLoginResponse or not atmLoginResponse.success then
        clearScreen()
        drawHeader("DEPOSIT FAILED")
        
        drawBox(15, 9, 50, 11, colors.bg)
        centerText(10, "ATM register not configured", colors.error)
        centerText(11, "", colors.textDim)
        centerText(12, "Administrator must create account:", colors.textDim)
        centerText(13, "Username: " .. ATM_REGISTER_USERNAME, colors.accent)
        centerText(14, "Password: " .. ATM_REGISTER_PASSWORD, colors.accent)
        centerText(15, "Balance: 10000+", colors.accent)
        centerText(16, "", colors.textDim)
        centerText(17, "Items already imported to AE2", colors.success)
        centerText(18, "Contact admin for manual credit", colors.textDim)
        
        centerText(22, "Press Enter to continue", colors.textDim)
        io.read()
        
        sendCommand({
            command = "login",
            username = savedUser,
            password = savedPass
        })
        
        currentUser = savedUser
        currentPass = savedPass
        currentBalance = savedBalance
        return
    end
    
    centerText(13, "Transferring funds...", colors.textDim)
    
    local response = sendCommand({
        command = "transfer",
        username = ATM_REGISTER_USERNAME,
        password = ATM_REGISTER_PASSWORD,
        recipient = savedUser,
        amount = amount
    })
    
    sendCommand({
        command = "logout",
        username = ATM_REGISTER_USERNAME,
        password = ATM_REGISTER_PASSWORD
    })
    
    os.sleep(0.3)
    
    local playerLoginResponse = sendCommand({
        command = "login",
        username = savedUser,
        password = savedPass
    })
    
    currentUser = savedUser
    currentPass = savedPass
    
    if playerLoginResponse and playerLoginResponse.success then
        currentBalance = playerLoginResponse.balance
        lastKeepAlive = computer.uptime()
    else
        currentBalance = savedBalance
    end
    
    clearScreen()
    drawHeader("DEPOSIT")
    
    if response and response.success then
        drawBox(15, 10, 50, 7, colors.bg)
        centerText(11, "Deposit successful!", colors.success)
        centerText(12, "Deposited: " .. string.format("%.2f CR", amount), colors.text)
        centerText(14, "Items imported to AE2 network", colors.textDim)
        centerText(16, "New balance: " .. string.format("%.2f CR", currentBalance), colors.text)
    else
        drawBox(15, 10, 50, 9, colors.bg)
        centerText(11, "Money transfer failed", colors.error)
        
        local errMsg = response and response.message or "No response from server"
        
        if errMsg:find("Insufficient") then
            centerText(12, "ATM register has insufficient funds", colors.textDim)
            centerText(13, "Contact administrator to add funds", colors.textDim)
        else
            centerText(12, errMsg, colors.textDim)
        end
        
        centerText(15, "", colors.textDim)
        centerText(16, "Items already imported to AE2!", colors.success)
        centerText(17, "Contact admin for manual credit", colors.textDim)
        centerText(18, "Amount: " .. amount .. " CR", colors.accent)
    end
    
    centerText(22, "Press Enter to continue", colors.textDim)
    io.read()
end

-- Main Menu
local function mainMenu()
    -- Keep session alive
    keepSessionAlive()
    
    clearScreen()
    drawHeader("ATM MENU")
    
    drawBox(15, 7, 50, 2, colors.bg)
    safePrint(20, 8, "Account:", colors.textDim)
    safePrint(30, 8, tostring(currentUser), colors.text)
    
    drawBox(15, 10, 50, 10, colors.bg)
    
    safePrint(25, 11, "[1] Check Balance", colors.text)
    safePrint(25, 13, "[2] Withdraw Cash", colors.text)
    safePrint(25, 15, "[3] Deposit Cash", colors.text)
    safePrint(25, 17, "[4] Logout", colors.text)
    safePrint(25, 19, "[0] Exit ATM", colors.error)
    
    local footerMsg = "Balance: " .. string.format("%.2f CR", currentBalance) .. " | AE2 Export Bus"
    drawFooter(footerMsg)
    
    local _, _, char = event.pull("key_down")
    
    if char == string.byte('1') then
        checkBalance()
    elseif char == string.byte('2') then
        withdrawCash()
    elseif char == string.byte('3') then
        depositCash()
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
        
        centerText(14, "Logged out successfully", colors.success)
        os.sleep(1)
    elseif char == string.byte('0') then
        -- Exit ATM (password protected)
        clearScreen()
        drawHeader("EXIT ATM")
        
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
            centerText(12, "Closing ATM...", colors.accent)
            
            if currentUser then
                sendCommand({
                    command = "logout",
                    username = currentUser,
                    password = currentPass
                })
            end
            
            centerText(14, "Goodbye!", colors.success)
            os.sleep(1)
            
            closeDebugFile()
            os.exit()
        else
            centerText(18, "Incorrect password!", colors.error)
            os.sleep(2)
        end
    end
end

-- Main Loop
local function main()
    openDebugFile()
    debugLog("ATM Starting...")
    
    initializeRedstone()
    initializeInventoryController()
    
    clearScreen()
    drawHeader("ATM INITIALIZING")
    
    drawBox(15, 9, 50, 15, colors.bg)
    
    safePrint(20, 10, "ATM ID:", colors.textDim)
    safePrint(29, 10, ATM_ID, colors.text)
    
    safePrint(20, 12, "Status:", colors.textDim)
    safePrint(29, 12, "Ready", colors.success)
    
    safePrint(20, 14, "Card Reader:", colors.textDim)
    safePrint(33, 14, "Active", colors.success)
    
    safePrint(20, 16, "Export Bus:", colors.textDim)
    safePrint(33, 16, hasExportBus and "Connected" or "Missing", hasExportBus and colors.success or colors.error)
    
    safePrint(20, 17, "Import Bus:", colors.textDim)
    safePrint(33, 17, hasImportBus and "Connected" or "Optional", hasImportBus and colors.success or colors.textDim)
    
    safePrint(20, 18, "Database:", colors.textDim)
    safePrint(33, 18, hasDatabase and "Ready" or "Missing", hasDatabase and colors.success or colors.error)
    
    safePrint(20, 20, "Deposit Ctrl:", colors.textDim)
    safePrint(33, 20, hasDepositInventoryController and "Ready" or "Optional", hasDepositInventoryController and colors.success or colors.textDim)
    
    safePrint(20, 21, "Withdraw Ctrl:", colors.textDim)
    safePrint(33, 21, hasWithdrawalInventoryController and "Ready" or "Optional", hasWithdrawalInventoryController and colors.success or colors.textDim)
    
    -- Detect withdrawal chest size
    local chestSize = detectWithdrawalChestSize()
    
    if hasWithdrawalInventoryController then
        safePrint(20, 23, "Withdrawal Chest:", colors.textDim)
        safePrint(33, 23, chestSize .. " slots", colors.success)
    end
    
    drawFooter("AE2 ATM System v2.2 - Multi-Slot | Inv Controller | Session Keep-Alive")
    
    if not hasExportBus or not hasDatabase then
        centerText(24, "Cannot start - missing components", colors.error)
        return
    end
    
    os.sleep(2)
    
    while true do
        if not sessionActive then
            atmLogin()
        else
            mainMenu()
        end
    end
end

-- Run
local success, err = pcall(main)
if not success then
    if debugFile then
        debugLog("FATAL ERROR: " .. tostring(err))
        closeDebugFile()
    end
    term.clear()
    print("ATM Error: " .. tostring(err))
    print("Check debug log: " .. DEBUG_FILE_PATH)
else
    closeDebugFile()
end
