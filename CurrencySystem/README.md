# OpenComputers Digital Currency System - Comprehensive Guide

## Table of Contents
1. [System Overview](#system-overview)
2. [Architecture](#architecture)
3. [Component Requirements](#component-requirements)
4. [Installation Guide](#installation-guide)
5. [Configuration](#configuration)
6. [Features](#features)
7. [Security](#security)
8. [API Reference](#api-reference)
9. [Troubleshooting](#troubleshooting)

---

## System Overview

This is a complete digital banking system for OpenComputers in Minecraft 1.7.10. It provides:

- **Secure P2P Banking** - Transfer credits between accounts
- **ATM System** - Withdraw/deposit physical currency items via AE2
- **Shop System** - Automated stores with inventory management
- **Encrypted Storage** - Password hashing and data encryption
- **RAID Support** - Distributed storage across multiple drives
- **API Library** - Reusable banking interface for custom programs

### Key Technologies

- **Linked Cards (Tunnel)** - Secure client-server communication
- **AE2 Integration** - Physical item dispensing via ME Export/Import Buses
- **Data Card Encryption** - Password hashing and data security
- **OpenSecurity** - Mag card reader for card-based authentication
- **Inventory Controller** - Smart multi-slot item dispensing

---

## Architecture

The system uses a 3-tier architecture:

```
[Clients] ←→ [Relay] ←→ [Server]
  Tunnel      Tunnel       Wireless
  (Linked     + Wireless   (Network)
   Cards)
```

### Components

1. **Server** - Central database, account management, transaction processing
2. **Relay** - Protocol converter (Tunnel ↔ Wireless), supports multiple clients
3. **Client** - User interface for banking operations
4. **ATM** - Physical cash withdrawal/deposit via AE2
5. **Shop** - Automated store with catalog and checkout
6. **API Library** - Reusable banking functions

### Communication Flow

```
Client → [Linked Card] → Relay → [Wireless] → Server
                                                  ↓
Server → [Wireless] → Relay → [Linked Card] → Client
```

**Why this architecture?**
- Linked cards provide secure, dedicated channels (no wireless sniffing)
- Relay allows wireless server while maintaining client security
- Multiple clients can connect via one relay (multi-tunnel support)
- Server remains accessible to admins via wireless

---

## Component Requirements

### Server Computer

**Required:**
- Tier 2+ Computer
- Wireless Network Card
- Data Card (Tier 2+ for encryption)
- Keyboard
- Screen

**Optional:**
- Multiple Hard Drives (for RAID)
  - Label drives with "RAID" or "BANK"
  - Need 2+ drives for redundancy

### Relay Computer

**Required:**
- Tier 2+ Computer  
- Wireless Network Card
- Linked Card(s) - One per client
- Keyboard
- Screen

**Notes:**
- Supports multiple linked cards (one relay, many clients)
- Each client needs a paired linked card

### Client Computer

**Required:**
- Tier 2+ Computer
- Linked Card (paired with relay)
- Keyboard
- Screen

### ATM Computer

**Required:**
- Tier 2+ Computer
- Linked Card (paired with relay)
- OpenSecurity Mag Card Reader
- ME Export Bus (via Adapter)
- Database (with currency items)
- Keyboard
- Screen

**Optional:**
- ME Import Bus (for deposits)
- Redstone I/O (x2 for import/export control)
- Inventory Controller (for smart dispensing)

**Physical Setup:**
- Withdrawal chest (connected to ME Export Bus)
- Deposit chest (connected to ME Import Bus)
- Database must contain currency items in slots 1-3

### Shop Computer

**Required:**
- Tier 2+ Computer
- Linked Card (paired with relay)
- OpenSecurity Mag Card Reader
- ME Export Bus (via Adapter)
- Database (with shop items)
- Keyboard
- Screen

**Optional:**
- ME Controller (for stock checking)
- Data Card (for password encryption)
- Inventory Controller (for smart dispensing)

**Physical Setup:**
- Pickup chest (connected to ME Export Bus)
- Database must contain all shop items
- AE2 network with items to sell

---

## Installation Guide

### Step 1: Server Setup

1. **Craft and place server computer**
   - Insert Wireless Network Card
   - Insert Data Card
   - Insert multiple Hard Drives (optional, for RAID)

2. **Label RAID drives** (if using)
   ```
   label set BANK1
   label set BANK2
   # etc - need 2+ drives
   ```

3. **Copy server.lua to computer**
   ```lua
   wget https://yoururl.com/server.lua /home/server.lua
   ```

4. **Start server**
   ```
   server
   ```

5. **First-time setup**
   - Default admin password: `ECU2025`
   - Press F5 to enter admin panel
   - Change admin password immediately!

6. **Create accounts**
   - Press F5 → Admin Panel
   - Option 1: Create Account
   - Create user accounts
   - **Important:** Create ATM register account (e.g., "ATM1")

### Step 2: Relay Setup

1. **Craft linked card pairs**
   - Recipe: 2 Linked Cards + Ender Pearl = Linked Card Pair
   - Craft one pair per client

2. **Place relay computer**
   - Insert Wireless Network Card
   - Insert all linked cards (one per client)

3. **Copy relay.lua**
   ```
   wget https://yoururl.com/relay.lua /home/relay.lua
   ```

4. **Start relay**
   ```
   relay
   ```

5. **Verify connection**
   - Relay should auto-detect server
   - Check log for "Server found" message

### Step 3: Client Setup

1. **Place client computer**
   - Insert paired linked card

2. **Copy client.lua**
   ```
   wget https://yoururl.com/client.lua /home/client.lua
   ```

3. **Start client**
   ```
   client
   ```

4. **Connect to relay**
   - Should auto-connect on startup
   - Press 1 to login

### Step 4: ATM Setup (Optional)

1. **Physical Setup**
   - Place computer next to chests
   - Connect ME Export Bus to withdrawal chest via Adapter
   - Connect ME Import Bus to deposit chest via Adapter (optional)
   - Place Inventory Controller adjacent to computer and chests (optional)
   - Place Redstone I/O blocks for bus control (optional)

2. **Prepare Database**
   ```
   1. Craft Database component
   2. Place in computer
   3. Right-click with currency items:
      - Slot 1: 1000 Credit item
      - Slot 2: 100 Credit item  
      - Slot 3: 1 Credit item
   ```

3. **Configure ATM.lua**
   Edit the configuration section:
   ```lua
   -- ATM Register Account
   local ATM_REGISTER_USERNAME = "ATM1"
   local ATM_REGISTER_PASSWORD = "atm2025"
   
   -- Admin Exit Password
   local ADMIN_EXIT_PASSWORD = "ATMEXIT2025"
   
   -- Currency definitions (MUST match database slots!)
   local CURRENCY_ITEMS = {
       {name = "swc:galacticCredit3", label = "1000 Credit", value = 1000, dbSlot = 1},
       {name = "swc:galacticCredit2", label = "100 Credit", value = 100, dbSlot = 2},
       {name = "swc:galacticCredit", label = "1 Credit", value = 1, dbSlot = 3}
   }
   
   -- Redstone addresses (run 'component.list("redstone")' to find)
   local IMPORT_REDSTONE_ADDRESS = "abc123..."
   local EXPORT_REDSTONE_ADDRESS = "def456..."
   
   -- Inventory Controller addresses (run 'component.list("inventory_controller")' to find)
   local DEPOSIT_INVENTORY_CONTROLLER_ADDRESS = "xyz789..."
   local WITHDRAWAL_INVENTORY_CONTROLLER_ADDRESS = "uvw012..."
   
   -- Chest sides (adjust based on your physical setup)
   local EXPORT_BUS_SIDE = sides.south
   local DEPOSIT_CHEST_SIDE = sides.down
   local WITHDRAWAL_CHEST_SIDE = sides.down
   ```

4. **Start ATM**
   ```
   atm
   ```

5. **Create bank cards** (see Mag Card section)

### Step 5: Shop Setup (Optional)

1. **Physical Setup**
   - Place computer next to pickup chest
   - Connect ME Export Bus to pickup chest via Adapter
   - Connect ME Controller to computer (for stock checking)
   - Place Inventory Controller adjacent to computer and chest (optional)

2. **Prepare Database**
   ```
   1. Craft Database component
   2. Place in computer
   3. Right-click with ALL items you want to sell
   4. Note which slot each item is in
   ```

3. **Start Shop**
   ```
   shop
   ```

4. **First-time setup**
   - Enter shop name
   - Enter owner username (bank account)
   - Enter owner password
   - Config is encrypted and saved

5. **Add items to catalog**
   - Swipe owner's card
   - Press A for Admin Panel
   - Option 1: Add Item
   - Enter item details:
     - Item name (e.g., `minecraft:diamond`)
     - Display label
     - Price
     - Database slot number
     - Category

---

## Configuration

### Server Configuration

**Location:** `/home/currency/admin.cfg` (encrypted)

**Settings:**
- Admin password hash
- Default: `ECU2025` (change immediately!)

**Data Files:**
- `/home/currency/accounts.dat` - Account database (encrypted)
- `/home/currency/transactions.log` - Transaction history
- `/home/currency/*.chunk*` - RAID data chunks (if enabled)

### RAID Configuration

**Automatic Detection:**
- Label drives with "RAID" or "BANK"
- Need 2+ drives for redundancy
- Restart server to detect

**RAID Features:**
- Automatic data splitting
- Redundant storage (2+ copies per chunk)
- Checksum verification
- Automatic failover on drive failure

### ATM Configuration

**Currency Items:**
```lua
local CURRENCY_ITEMS = {
    {name = "item:id", label = "Display", value = 1000, dbSlot = 1},
    {name = "item:id", label = "Display", value = 100, dbSlot = 2},
    {name = "item:id", label = "Display", value = 1, dbSlot = 3}
}
```

**Important:**
- Must be sorted high to low by value
- dbSlot must match actual database slot
- Change calculation works via greedy algorithm

### Shop Configuration

**Location:** `/home/shop_config.txt` (encrypted)

**Catalog:** `/home/shop_catalog.txt`

**First-time Setup:**
- Automatically runs on first launch
- Owner credentials encrypted with Data Card
- Falls back to plaintext if no Data Card

---

## Features

### Account Management

**Admin Functions:**
- Create accounts with initial balance
- Delete accounts
- Set/modify balance
- Lock/unlock accounts
- Reset passwords
- View all accounts

**User Functions:**
- Login/logout
- Check balance
- Transfer funds
- View account directory

### Security Features

1. **Password Encryption**
   - MD5 hashing via Data Card
   - Salted with server name
   - Never transmitted in plaintext

2. **Data Encryption**
   - AES encryption for database
   - Unique key per server
   - IV-based encryption

3. **Session Management**
   - 30-minute timeout
   - Session validation on each request
   - Automatic keep-alive (ATM/Shop)

4. **Access Control**
   - Admin-only registration
   - Password-protected admin panel
   - Card-based authentication

### ATM Features

1. **Withdrawal**
   - Calculates optimal change
   - Multi-slot dispensing
   - Handles non-stackable items
   - Chest full detection

2. **Deposit**
   - Validates items before transfer
   - Automatic import to AE2
   - Verification via Inventory Controller

3. **Session Keep-Alive**
   - Auto-refresh every 2 minutes
   - Prevents timeout during use

### Shop Features

1. **Shopping**
   - Browse catalog by category
   - Shopping cart
   - Stock checking (if ME Controller)
   - Multi-item checkout

2. **Item Validation**
   - Verifies database slot matches catalog
   - Checks stock before payment
   - Prevents wrong-item exploits

3. **Admin Panel**
   - Add/edit/remove items
   - Change prices
   - Edit catalog
   - Encrypted credentials

---

## Security

### Threat Model

**Protected Against:**
- Wireless packet sniffing (tunnel encryption)
- Password theft (hashing)
- Database theft (encryption)
- Unauthorized access (admin panel)
- Session hijacking (validation)
- Wrong-item dispensing (validation)

**Not Protected Against:**
- Physical computer access
- Source code modification
- Relay compromise (can intercept)
- Social engineering

### Best Practices

1. **Server Security**
   - Change admin password immediately
   - Restrict physical access
   - Regular backups
   - Monitor transaction logs

2. **Client Security**
   - Keep cards secure
   - Don't share passwords
   - Log out when done
   - Report suspicious activity

3. **ATM Security**
   - Secure register account
   - Change exit password
   - Monitor dispensing logs
   - Verify currency items

4. **Shop Security**
   - Validate all catalog entries
   - Regular inventory audits
   - Secure owner account
   - Monitor transactions

---

## API Reference

### Banking API Library

**Location:** `bank_api.lua`

#### Functions

**connect()**
```lua
local success, message = bankAPI.connect()
```
Establishes connection to relay. Must be called first.

**login(username, password)**
```lua
local success, balance = bankAPI.login("user", "pass")
```
Authenticates and creates session. Returns balance on success.

**getBalance(username, password)**
```lua
local success, balance = bankAPI.getBalance("user", "pass")
```
Retrieves current account balance.

**transfer(username, password, recipient, amount)**
```lua
local success, newBalance = bankAPI.transfer("user", "pass", "recipient", 100)
```
Transfers funds to another account. Returns new balance on success.

**listAccounts()**
```lua
local success, accounts, total = bankAPI.listAccounts()
```
Returns list of accounts with online status.

**logout(username, password)**
```lua
local success, message = bankAPI.logout("user", "pass")
```
Ends session. Requires password for security.

**disconnect()**
```lua
bankAPI.disconnect()
```
Disconnects from relay. Auto-logs out all tracked users.

#### Helper Functions

**accountExists(username)**
```lua
local exists, online = bankAPI.accountExists("user")
```
Checks if account exists and online status.

**validateAmount(amount)**
```lua
local valid, error = bankAPI.validateAmount(100)
```
Validates monetary amount.

**formatCurrency(amount, symbol)**
```lua
local formatted = bankAPI.formatCurrency(100.5, "$")
-- Returns: "$100.50"
```
Formats currency for display.

#### Example Usage

```lua
local bankAPI = require("bank_api")

-- Connect
if not bankAPI.connect() then
    print("Connection failed")
    return
end

-- Login
local success, balance = bankAPI.login("myuser", "mypass")
if success then
    print("Balance: " .. balance)
    
    -- Transfer
    local ok, newBalance = bankAPI.transfer("myuser", "mypass", "friend", 50)
    if ok then
        print("New balance: " .. newBalance)
    end
    
    -- Logout
    bankAPI.logout("myuser", "mypass")
end

-- Disconnect
bankAPI.disconnect()
```

---

## Troubleshooting

### Server Issues

**"Data card required for encryption!"**
- Install Tier 2+ Data Card in server
- Required for password hashing and data encryption

**"RAID Mode: DISABLED"**
- Label drives with "RAID" or "BANK"
- Need 2+ drives for redundancy
- Restart server after adding drives

**"Admin password changed successfully but can't login"**
- Config file corrupted
- Delete `/home/currency/admin.cfg`
- Server will recreate with default password

### Relay Issues

**"No Tunnel (Linked Card) found!"**
- Install at least one linked card
- Craft linked card pairs (2 cards + ender pearl)

**"Server not found"**
- Check wireless range (default 400 blocks)
- Ensure server is running
- Check modem port (default 1000)

**"CLIENT REGISTERED but no ACK sent"**
- Check tunnel.send() errors
- Verify channel matching
- Restart relay

### Client Issues

**"ERROR: LINKED CARD REQUIRED!"**
- Install linked card in client
- Must be paired with card in relay

**"Not connected to relay"**
- Check if relay is running
- Verify linked cards are paired
- Check tunnel channel

**"Login failed: Invalid username or password"**
- Verify account exists (admin creates accounts)
- Check spelling
- Ensure session not already active

**"Session invalid. Please login again."**
- Session expired (30 minute timeout)
- Re-login required
- Check server logs for issues

### ATM Issues

**"Export Bus not available"**
- Connect ME Export Bus to computer via Adapter
- Check adapter placement
- Verify AE2 power

**"Database component not found"**
- Install Database in computer
- Load currency items into database slots

**"Failed to configure export bus"**
- Check database slot numbers
- Verify items in database
- Check EXPORT_BUS_SIDE setting

**"Chest full! Only exported X of Y"**
- Empty withdrawal chest
- Install Inventory Controller for detection
- Check MAX_CHEST_SLOTS setting

**"ATM register not configured"**
- Create register account on server
- Username: ATM_REGISTER_USERNAME
- Fund with sufficient balance (10000+ CR)

**"Validation failed"**
- Deposit chest items don't match amount
- Check CURRENCY_ITEMS configuration
- Verify Inventory Controller side

### Shop Issues

**"Owner password encryption failed"**
- Data Card not available
- Install Data Card for encryption
- System will use plaintext fallback (warning shown)

**"VALIDATION FAILED: Database slot mismatch"**
- Catalog dbSlot doesn't match database
- Re-enter item in catalog with correct slot
- Verify database items haven't changed

**"Chest full! Only exported X of Y"**
- Empty pickup chest
- Install Inventory Controller for detection
- Check MAX_CHEST_SLOTS setting

**"Payment went through but items failed"**
- Critical! Customer paid but no items
- Manually refund via admin panel
- Check ME Export Bus connection
- Verify items exist in AE2 network

### General Issues

**"Timeout - no response from server"**
- Check relay is running
- Check server is running
- Verify wireless range
- Check network congestion

**"Components keep restarting"**
- Too much power draw
- Add more power
- Reduce component usage

**Lag or freezing**
- Too many open files
- Restart computers
- Reduce transaction frequency
- Check for infinite loops

---

## Advanced Topics

### Custom Currency Items

To use different currency items:

1. **Update CURRENCY_ITEMS table**
   ```lua
   local CURRENCY_ITEMS = {
       {name = "modid:item1", label = "Gold Coin", value = 1000, dbSlot = 1},
       {name = "modid:item2", label = "Silver Coin", value = 100, dbSlot = 2},
       {name = "modid:item3", label = "Copper Coin", value = 1, dbSlot = 3}
   }
   ```

2. **Load items into database**
   - Right-click database with items
   - Note slot numbers
   - Update dbSlot values

3. **Update both ATM and Shop**
   - Keep configurations synchronized
   - Test withdrawals with small amounts

### Multiple ATMs

1. **Create separate register accounts**
   ```
   ATM1 / password1
   ATM2 / password2
   ```

2. **Configure each ATM differently**
   ```lua
   local ATM_REGISTER_USERNAME = "ATM2"
   local ATM_REGISTER_PASSWORD = "password2"
   ```

3. **Use unique ATM_IDs**
   - Automatically generated from tunnel address
   - Each ATM has unique ID

### Multiple Shops

1. **Each shop needs own config**
   - Separate owner accounts
   - Independent catalogs
   - Unique shop names

2. **Share database slots**
   - Use same item → slot mapping
   - Coordinate catalog entries
   - Prevents confusion

### Extending the API

Create custom programs using `bank_api.lua`:

```lua
local bankAPI = require("bank_api")

-- Custom vending machine
function vendingMachine()
    bankAPI.connect()
    
    -- Wait for card swipe
    local username, password = getCardData()
    
    -- Check balance
    local success, balance = bankAPI.getBalance(username, password)
    
    if success and balance >= ITEM_PRICE then
        -- Process payment
        local ok = bankAPI.transfer(username, password, "VENDING1", ITEM_PRICE)
        
        if ok then
            dispenseItem()
        end
    end
    
    bankAPI.disconnect()
end
```

### Backup and Recovery

**Manual Backup:**
```bash
# On server computer
cp /home/currency/accounts.dat /home/backup/accounts_$(date +%Y%m%d).dat
cp /home/currency/admin.cfg /home/backup/admin_$(date +%Y%m%d).cfg
```

**Restore from Backup:**
```bash
cp /home/backup/accounts_YYYYMMDD.dat /home/currency/accounts.dat
# Restart server
```

**RAID Recovery:**
- If one drive fails, data recoverable from redundant copies
- Replace failed drive
- Restart server
- RAID automatically rebuilds

---

## Frequently Asked Questions

**Q: Can I use this without AE2?**
A: Server, relay, and client work without AE2. ATM and Shop require AE2 for item dispensing.

**Q: Is wireless communication secure?**
A: Clients use tunnel (linked cards) for security. Only relay-server uses wireless. Server is admin-only access.

**Q: Can players create accounts themselves?**
A: No. Admin must create accounts. This prevents spam and ensures moderation.

**Q: What happens if server crashes?**
A: All data is encrypted and saved. Restart server to resume. RAID provides redundancy.

**Q: Can I have multiple servers?**
A: Each server is independent. Accounts don't transfer between servers. Use separate relay setups.

**Q: How do I reset admin password?**
A: Delete `/home/currency/admin.cfg`. Server recreates with default password `ECU2025`.

**Q: Can ATM run out of money?**
A: Yes. ATM register account must have sufficient balance. Monitor and refill as needed.

**Q: What if someone forgets their password?**
A: Admin can reset passwords via admin panel (F5 → Reset Password).

**Q: Can I modify the UI?**
A: Yes! Edit color schemes, layouts, and text in source code. Keep core logic intact.

**Q: Does this work in multiplayer?**
A: Yes! Designed for multiplayer servers. Multiple clients can connect simultaneously.

---

## Credits

- **System Design:** OpenComputers banking architecture
- **AE2 Integration:** ME Export/Import Bus support
- **Security:** Data Card encryption implementation
- **Multi-Slot Dispensing:** Inventory Controller integration
- **Session Management:** Keep-alive and timeout handling

---

## Version History

**v2.2 - Current**
- Multi-slot dispensing support
- Inventory Controller integration
- Session keep-alive (ATM/Shop)
- Dynamic chest size detection
- Non-stackable item support

**v2.1**
- Shop system with catalog management
- Item validation and security
- Data Card encryption for shop config
- Admin panel for shop owners

**v2.0**
- ATM system with AE2 integration
- Deposit/withdrawal functionality
- Currency item validation
- Redstone bus control

**v1.0**
- Core banking server
- Multi-client relay
- Client interface
- Basic API library

---

## Support

For issues, suggestions, or contributions:
- Check troubleshooting section
- Review configuration settings
- Test with minimal setup
- Check OpenComputers forums

---

**End of Guide**
