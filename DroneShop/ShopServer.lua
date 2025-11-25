-- OpenComputers Shop Server
-- Manages inventory and processes customer orders

local component = require("component")
local event = require("event")
local serialization = require("serialization")
local filesystem = require("filesystem")

local modem = component.modem
local gpu = component.gpu

-- Configuration
local SHOP_PORT = 200
local STATUS_PORT = 201
local CUSTOMER_PORT = 202
local DATA_FILE = "/home/shop_data.txt"

-- Open ports
modem.open(STATUS_PORT)
modem.open(CUSTOMER_PORT)

-- Shop data structure
local shop = {
  items = {},      -- item_name -> {slot=X, price=Y, stock=Z, description=""}
  sales = {},      -- transaction history
  droneStatus = "UNKNOWN",
  totalSales = 0
}

-- Load shop data
local function loadData()
  if filesystem.exists(DATA_FILE) then
    local file = io.open(DATA_FILE, "r")
    local data = file:read("*a")
    file:close()
    shop = serialization.unserialize(data) or shop
    print("Shop data loaded")
  else
    print("No existing shop data, starting fresh")
  end
end

-- Save shop data
local function saveData()
  local file = io.open(DATA_FILE, "w")
  file:write(serialization.serialize(shop))
  file:close()
end

-- Add item to shop
local function addItem(name, slot, price, stock, description)
  shop.items[name] = {
    slot = slot,
    price = price,
    stock = stock,
    description = description or ""
  }
  saveData()
  print("Added item: " .. name)
end

-- Update stock from drone inventory
local function updateStockFromDrone(invData)
  -- Parse inventory data: "INV:1=64,2=32,3=16,"
  local invStr = invData:match("INV:(.+)")
  if not invStr then return end
  
  for slotData in invStr:gmatch("[^,]+") do
    local slot, count = slotData:match("(%d+)=(%d+)")
    if slot and count then
      slot = tonumber(slot)
      count = tonumber(count)
      
      -- Find item with this slot and update stock
      for name, item in pairs(shop.items) do
        if item.slot == slot then
          item.stock = count
          break
        end
      end
    end
  end
  saveData()
end

-- Process purchase
local function processPurchase(customerName, itemName, quantity, customerX, customerY, customerZ)
  local item = shop.items[itemName]
  
  if not item then
    return false, "Item not found"
  end
  
  if item.stock < quantity then
    return false, "Insufficient stock (available: " .. item.stock .. ")"
  end
  
  local totalCost = item.price * quantity
  
  -- Send delivery command to drone (D = DELIVER)
  local deliveryCmd = string.format("D:%d:%d:%d:%d:%d", 
    customerX, customerY, customerZ, item.slot, quantity)
  modem.broadcast(SHOP_PORT, deliveryCmd)
  
  -- Update inventory (optimistically)
  item.stock = item.stock - quantity
  
  -- Record sale
  table.insert(shop.sales, {
    customer = customerName,
    item = itemName,
    quantity = quantity,
    cost = totalCost,
    timestamp = os.time()
  })
  
  shop.totalSales = shop.totalSales + totalCost
  saveData()
  
  return true, "Order placed! Total: " .. totalCost .. " credits. Drone delivering..."
end

-- Request drone status
local function requestDroneStatus()
  modem.broadcast(SHOP_PORT, "S")
end

-- Handle incoming messages
local function handleMessage(_, _, from, port, _, message)
  if port == STATUS_PORT then
    -- Drone status updates
    shop.droneStatus = message
    
    if message:match("^INV:") then
      updateStockFromDrone(message)
    elseif message:match("^E:") then
      -- Energy update
      shop.droneStatus = message
    end
    
    print("[DRONE] " .. message)
    
  elseif port == CUSTOMER_PORT then
    -- Customer orders: "ORDER:customerName:itemName:quantity:x:y:z"
    local parts = {}
    for part in string.gmatch(message, "[^:]+") do
      table.insert(parts, part)
    end
    
    if parts[1] == "ORDER" then
      local customerName = parts[2]
      local itemName = parts[3]
      local quantity = tonumber(parts[4]) or 1
      local cx = tonumber(parts[5])
      local cy = tonumber(parts[6])
      local cz = tonumber(parts[7])
      
      if customerName and itemName and cx and cy and cz then
        local success, msg = processPurchase(customerName, itemName, quantity, cx, cy, cz)
        
        local response = success and "SUCCESS:" .. msg or "ERROR:" .. msg
        modem.send(from, CUSTOMER_PORT, response)
        
        print(string.format("[ORDER] %s ordered %dx %s - %s", 
          customerName, quantity, itemName, success and "SUCCESS" or "FAILED"))
      end
      
    elseif parts[1] == "LIST" then
      -- Send item list to customer
      local itemList = "ITEMS:"
      for name, item in pairs(shop.items) do
        itemList = itemList .. name .. "=" .. item.price .. "=" .. item.stock .. ","
      end
      modem.send(from, CUSTOMER_PORT, itemList)
      
    elseif parts[1] == "INFO" then
      -- Send detailed item info
      local itemName = parts[2]
      local item = shop.items[itemName]
      if item then
        local info = string.format("INFO:%s:Price=%d:Stock=%d:Desc=%s", 
          itemName, item.price, item.stock, item.description)
        modem.send(from, CUSTOMER_PORT, info)
      else
        modem.send(from, CUSTOMER_PORT, "ERROR:Item not found")
      end
    end
  end
end

-- Display shop status
local function displayStatus()
  gpu.setBackground(0x000000)
  gpu.setForeground(0xFFFFFF)
  gpu.fill(1, 1, 80, 25, " ")
  
  gpu.set(1, 1, "=== SHOP SERVER STATUS ===")
  gpu.set(1, 2, "Drone: " .. shop.droneStatus)
  gpu.set(1, 3, "Total Sales: " .. shop.totalSales .. " credits")
  gpu.set(1, 4, "Transactions: " .. #shop.sales)
  
  gpu.set(1, 6, "=== INVENTORY ===")
  local row = 7
  for name, item in pairs(shop.items) do
    local stockColor = item.stock > 10 and 0x00FF00 or (item.stock > 0 and 0xFFFF00 or 0xFF0000)
    gpu.setForeground(stockColor)
    gpu.set(1, row, string.format("%-20s Price: %-6d Stock: %-4d Slot: %d", 
      name, item.price, item.stock, item.slot))
    gpu.setForeground(0xFFFFFF)
    row = row + 1
    if row > 24 then break end
  end
  
  gpu.set(1, 25, "Commands: add, restock, status, sales, quit")
end

-- Command interface
local function handleCommand(cmd)
  local parts = {}
  for part in string.gmatch(cmd, "[^%s]+") do
    table.insert(parts, part)
  end
  
  local command = parts[1]
  
  if command == "add" then
    -- add <name> <slot> <price> <stock> [description]
    if #parts >= 5 then
      local name = parts[2]
      local slot = tonumber(parts[3])
      local price = tonumber(parts[4])
      local stock = tonumber(parts[5])
      local description = table.concat(parts, " ", 6)
      addItem(name, slot, price, stock, description)
    else
      print("Usage: add <name> <slot> <price> <stock> [description]")
    end
    
  elseif command == "restock" then
    modem.broadcast(SHOP_PORT, "R")
    print("Restocking drone...")
    
  elseif command == "status" then
    requestDroneStatus()
    
  elseif command == "sales" then
    print("\n=== Recent Sales ===")
    for i = math.max(1, #shop.sales - 9), #shop.sales do
      local sale = shop.sales[i]
      print(string.format("%s: %s bought %dx %s for %d credits", 
        os.date("%H:%M", sale.timestamp), sale.customer, sale.quantity, sale.item, sale.cost))
    end
    
  elseif command == "home" then
    modem.broadcast(SHOP_PORT, "H")
    print("Calling drone home...")
    
  elseif command == "clear" then
    displayStatus()
    
  elseif command == "help" then
    print("\nCommands:")
    print("  add <name> <slot> <price> <stock> [desc] - Add item to shop")
    print("  restock - Tell drone to restock from chest")
    print("  status - Request drone status")
    print("  sales - Show recent sales")
    print("  home - Call drone home")
    print("  clear - Refresh display")
    print("  quit - Exit shop server")
    
  elseif command == "quit" or command == "exit" then
    return false
  end
  
  return true
end

-- Main function
local function main()
  loadData()
  displayStatus()
  
  -- Listen for messages
  event.listen("modem_message", handleMessage)
  
  -- Request initial drone status
  requestDroneStatus()
  
  print("\nShop server running. Type 'help' for commands.")
  
  -- Command loop
  while true do
    io.write("\n> ")
    local input = io.read()
    if not input or not handleCommand(input) then
      break
    end
  end
  
  event.ignore("modem_message", handleMessage)
  saveData()
  print("Shop server stopped.")
end

-- Run the shop
main()
