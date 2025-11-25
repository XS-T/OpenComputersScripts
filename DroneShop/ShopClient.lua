-- OpenComputers Shop Customer Terminal
-- Place this at customer locations to order items

local component = require("component")
local event = require("event")
local term = require("term")
local computer = require("computer")

local modem = component.modem
local gpu = component.gpu

-- Configuration
local CUSTOMER_PORT = 202
local CUSTOMER_NAME = "Customer" -- Change this for each terminal
local DELIVERY_X = 0  -- Set to your delivery location
local DELIVERY_Y = 64
local DELIVERY_Z = 0

-- Open port
modem.open(CUSTOMER_PORT)

-- Store available items
local shopItems = {}
local lastResponse = ""

-- Request item list from shop
local function requestItemList()
  modem.broadcast(CUSTOMER_PORT, "LIST")
  
  -- Wait for response
  local timeout = 3
  local start = computer.uptime()
  
  while computer.uptime() - start < timeout do
    local _, _, from, port, _, message = event.pull(0.1, "modem_message")
    if message and message:match("^ITEMS:") then
      parseItemList(message)
      return true
    end
  end
  
  return false
end

-- Parse item list from shop
local function parseItemList(data)
  shopItems = {}
  local itemStr = data:match("ITEMS:(.+)")
  if not itemStr then return end
  
  for itemData in itemStr:gmatch("[^,]+") do
    local name, price, stock = itemData:match("([^=]+)=([^=]+)=([^=]+)")
    if name and price and stock then
      shopItems[name] = {
        price = tonumber(price),
        stock = tonumber(stock)
      }
    end
  end
end

-- Place order
local function placeOrder(itemName, quantity)
  local item = shopItems[itemName]
  if not item then
    return false, "Item not found in shop"
  end
  
  if item.stock < quantity then
    return false, "Insufficient stock (available: " .. item.stock .. ")"
  end
  
  local totalCost = item.price * quantity
  
  -- Send order
  local orderMsg = string.format("ORDER:%s:%s:%d:%d:%d:%d",
    CUSTOMER_NAME, itemName, quantity, DELIVERY_X, DELIVERY_Y, DELIVERY_Z)
  modem.broadcast(CUSTOMER_PORT, orderMsg)
  
  -- Wait for response
  local timeout = 5
  local start = computer.uptime()
  
  while computer.uptime() - start < timeout do
    local _, _, from, port, _, message = event.pull(0.1, "modem_message")
    if message then
      if message:match("^SUCCESS:") then
        lastResponse = message:match("SUCCESS:(.+)")
        item.stock = item.stock - quantity -- Update local stock
        return true, lastResponse
      elseif message:match("^ERROR:") then
        lastResponse = message:match("ERROR:(.+)")
        return false, lastResponse
      end
    end
  end
  
  return false, "No response from shop (timeout)"
end

-- Display shop UI
local function displayShop()
  term.clear()
  gpu.setBackground(0x000000)
  gpu.setForeground(0xFFFFFF)
  
  gpu.set(1, 1, "╔════════════════════════════════════════╗")
  gpu.set(1, 2, "║        DRONE DELIVERY SHOP             ║")
  gpu.set(1, 3, "╚════════════════════════════════════════╝")
  
  gpu.setForeground(0x00FFFF)
  gpu.set(1, 4, "Customer: " .. CUSTOMER_NAME)
  gpu.set(1, 5, "Delivery Location: " .. DELIVERY_X .. ", " .. DELIVERY_Y .. ", " .. DELIVERY_Z)
  
  gpu.setForeground(0xFFFFFF)
  gpu.set(1, 7, "═══════════ AVAILABLE ITEMS ═══════════")
  
  local row = 8
  local index = 1
  for name, item in pairs(shopItems) do
    local stockColor = item.stock > 10 and 0x00FF00 or (item.stock > 0 and 0xFFFF00 or 0xFF0000)
    
    gpu.setForeground(0xFFFF00)
    gpu.set(1, row, string.format("%d.", index))
    
    gpu.setForeground(0xFFFFFF)
    gpu.set(4, row, name)
    
    gpu.setForeground(0x00FF00)
    gpu.set(25, row, string.format("%d credits", item.price))
    
    gpu.setForeground(stockColor)
    gpu.set(38, row, string.format("[%d]", item.stock))
    
    row = row + 1
    index = index + 1
  end
  
  gpu.setForeground(0xFFFFFF)
  gpu.set(1, row + 1, "═══════════════════════════════════════")
  
  if lastResponse ~= "" then
    local color = lastResponse:match("success") and 0x00FF00 or 0xFF0000
    gpu.setForeground(color)
    gpu.set(1, row + 2, "Last: " .. lastResponse)
    gpu.setForeground(0xFFFFFF)
  end
  
  gpu.set(1, 25, "Commands: buy <item> [qty], list, config, quit")
end

-- Display config screen
local function displayConfig()
  term.clear()
  print("=== TERMINAL CONFIGURATION ===\n")
  print("Current Settings:")
  print("  Customer Name: " .. CUSTOMER_NAME)
  print("  Delivery X: " .. DELIVERY_X)
  print("  Delivery Y: " .. DELIVERY_Y)
  print("  Delivery Z: " .. DELIVERY_Z)
  print("\nTo change settings, edit the script:")
  print("  CUSTOMER_NAME = \"YourName\"")
  print("  DELIVERY_X = x")
  print("  DELIVERY_Y = y")
  print("  DELIVERY_Z = z")
  print("\nPress Enter to return...")
  io.read()
end

-- Handle command
local function handleCommand(cmd)
  local parts = {}
  for part in string.gmatch(cmd, "[^%s]+") do
    table.insert(parts, part)
  end
  
  local command = parts[1]
  
  if command == "buy" or command == "order" then
    if #parts >= 2 then
      local itemName = parts[2]
      local quantity = tonumber(parts[3]) or 1
      
      print("\nOrdering " .. quantity .. "x " .. itemName .. "...")
      local success, message = placeOrder(itemName, quantity)
      
      if success then
        gpu.setForeground(0x00FF00)
        print("✓ " .. message)
        computer.beep(1000, 0.1)
        computer.beep(1200, 0.1)
      else
        gpu.setForeground(0xFF0000)
        print("✗ " .. message)
        computer.beep(400, 0.2)
      end
      gpu.setForeground(0xFFFFFF)
    else
      print("Usage: buy <item> [quantity]")
    end
    
  elseif command == "list" or command == "refresh" then
    print("\nRefreshing item list...")
    if requestItemList() then
      print("Item list updated!")
      displayShop()
    else
      print("Failed to connect to shop")
    end
    
  elseif command == "config" then
    displayConfig()
    displayShop()
    
  elseif command == "help" then
    print("\nCommands:")
    print("  buy <item> [qty] - Purchase items")
    print("  list - Refresh item list")
    print("  config - View/edit configuration")
    print("  quit - Exit terminal")
    
  elseif command == "quit" or command == "exit" then
    return false
    
  else
    print("Unknown command. Type 'help' for commands.")
  end
  
  return true
end

-- Main function
local function main()
  print("Connecting to shop...")
  
  if not requestItemList() then
    print("Warning: Could not connect to shop")
    print("Make sure the shop server is running!")
  end
  
  displayShop()
  
  -- Main loop
  while true do
    io.write("\n> ")
    local input = io.read()
    if not input or not handleCommand(input) then
      break
    end
  end
  
  modem.close(CUSTOMER_PORT)
  print("\nThank you for shopping!")
end

-- Run the terminal
main()
