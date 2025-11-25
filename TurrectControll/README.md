# Cross-Dimensional Turret Control System

## Complete Guide for OpenComputers 1.7.10

**Version 2.0** - Multi-Dimension Support with Full Encryption

---

## 📖 Table of Contents

1. [Overview](#overview)
2. [System Architecture](#system-architecture)
3. [Hardware Requirements](#hardware-requirements)
4. [Installation Guide](#installation-guide)
5. [Quick Start](#quick-start)
6. [Component Details](#component-details)
7. [User Management](#user-management)
8. [Admin Panel](#admin-panel)
9. [Client Manager](#client-manager)
10. [Troubleshooting](#troubleshooting)
11. [FAQ](#faq)
12. [Quick Reference](#quick-reference)

---

## Overview

### What Is This?

A **comprehensive, secure system** for managing OpenComputers-controlled turrets across **multiple dimensions** in Minecraft. Control turrets in the Overworld, Nether, End, and any modded dimensions from a single interface.

### ✨ Key Features

- ✅ **Cross-Dimensional Control** - Manage turrets in any dimension
- ✅ **Secure Authentication** - Username/password with AES encryption
- ✅ **Global & Specific Permissions** - Trust players globally or per-dimension
- ✅ **Real-Time Sync** - Changes propagate within 30 seconds
- ✅ **Admin Panel** - F5 hotkey access to management
- ✅ **Auto-Recovery** - Self-healing from network issues
- ✅ **Activity Logging** - Full audit trail

### 🎯 Use Cases

**Multi-Dimension Server:**
- Trust admins globally (access everywhere)
- Trust team members per dimension (Nether mining team, End exploration team)
- Temporary guest access (specific dimensions only)

**Event Management:**
- Grant access for events
- Revoke after completion
- Track who added/removed players

**Security:**
- Encrypted communication
- Session management
- Admin account system

---

## System Architecture

### Network Topology

```
MAIN DIMENSION (Overworld)
┌─────────────────────────────────────────────────────────┐
│                                                         │
│  [Central Server] ←→ [Unified Relay]                    │
│       ↓ Admin (F5)       ↓ Multiple Linked Cards       │
│       ↓ Encrypted        ↓                             │
│                          ↓                             │
│                  ┌───────┼───────┐                     │
│                  ↓       ↓       ↓                     │
│           [Controller] [Controller] [Manager]          │
│            + Turrets    + Turrets   + Remote           │
└─────────────────────────────────────────────────────────┘

OTHER DIMENSIONS
┌─────────────────────────────────────────────────────────┐
│ Nether:    [Relay] ←→ [Controllers]                     │
│ End:       [Relay] ←→ [Controllers]                     │
│ Twilight:  [Relay] ←→ [Controllers]                     │
│                                                         │
│ Each relay connects back to Main World relay via       │
│ linked cards for cross-dimensional communication       │
└─────────────────────────────────────────────────────────┘
```

### Communication Flow

**When You Add a Player:**
```
1. Manager → Relay (linked card)
2. Relay → Server (wireless, encrypted)
3. Server updates list
4. Server → ALL Relays (broadcast, encrypted)
5. Each Relay → Controllers in that dimension
6. Controllers update turrets
```

**Automatic Sync (Every 30 seconds):**
```
1. Controller → Relay: "Request sync"
2. Relay → Server: "Controller wants sync"
3. Server → Relay: "Here's the latest list"
4. Relay → Controller: Forwards list
5. Controller compares and updates turrets if changed
```

---

## Hardware Requirements

### Central Server (Main Dimension Only)

**Required Components:**
- ⚙️ Tier 2+ Computer Case
- 🔷 Tier 2 CPU
- 💾 Tier 2 RAM (x2)
- 💿 Tier 3 Hard Drive
- 🔐 **Tier 2/3 Data Card** (for encryption)
- 📡 **Wireless Network Card**
- 🖥️ Tier 2 GPU
- 📺 Tier 2 Screen
- ⌨️ Keyboard

### Unified Relay (One Per Dimension)

**Required Components:**
- ⚙️ Tier 2+ Computer Case
- 🔷 Tier 2 CPU
- 💾 Tier 2 RAM (x2)
- 💿 Tier 2 Hard Drive
- 🔐 **Tier 2/3 Data Card** (for encryption)
- 📡 **Wireless Network Card**
- 🔗 **Multiple Linked Cards** (1 per controller + 1 per manager)
- 🖥️ Tier 1 GPU
- 📺 Tier 1 Screen
- ⌨️ Keyboard

**Note:** You need ONE linked card for EACH controller and manager in that dimension

### Turret Controller (Per Dimension)

**Required Components:**
- ⚙️ Tier 2+ Computer Case
- 🔷 Tier 2 CPU
- 💾 Tier 1 RAM (x2)
- 💿 Tier 2 Hard Drive
- 🔗 **Linked Card** (paired with relay)
- 🎯 **Turret Adapters** (one per turret)
- 🖥️ Tier 1 GPU
- 📺 Tier 1 Screen
- ⌨️ Keyboard

### Client Manager

**Required Components:**
- ⚙️ Tier 2 Computer Case
- 🔷 Tier 2 CPU
- 💾 Tier 1 RAM (x2)
- 💿 Tier 1 Hard Drive
- 🔗 **Linked Card** (paired with relay)
- 🖥️ Tier 2 GPU (for better UI)
- 📺 Tier 2 Screen
- ⌨️ Keyboard

---

## Installation Guide

### Step 1: Central Server Setup

1. **Assemble the computer** with all required components
2. **Install Data Card and Wireless Network Card**
3. **Upload the program:**
   ```lua
   turret-server-fixed.lua
   ```
4. **Start the server:**
   ```
   turret-server-fixed
   ```
5. **Immediately press F5** and login with:
   - Username: `admin`
   - Password: `admin123`
6. **Create your own admin account** (Option 2)
7. **Change the default password or delete default account**

**✅ Verification:**
- Shows "Controllers: 0"
- Shows "Port: 19321"
- Shows "Encryption: ENABLED"

### Step 2: Unified Relay Setup

1. **Assemble the computer** with Data Card and Wireless Network Card
2. **Upload the program:**
   ```lua
   turret-relay.lua
   ```
3. **Start the relay:**
   ```
   turret-relay
   ```
4. **Verify connection:**
   - Should show "Central Server: ✓ CONNECTED (ENCRYPTED)"
   - Should show "Encryption: ENABLED"

**📍 Important:** Relay must be within 400 blocks of server!

### Step 3: Turret Controller Setup (Each Dimension)

1. **Assemble computer in the dimension** with linked card and turret adapters
2. **Connect turret adapters to turrets** (must be adjacent)
3. **Upload programs:**
   ```lua
   setup-wizard.lua
   turret-controller.lua
   ```
4. **Run setup wizard:**
   ```
   setup-wizard
   ```
5. **Configure:**
   - Controller Name: (e.g., "Nether Base")
   - Dimension Name: (e.g., "Nether")
6. **Pair linked cards:**
   - Take one card from relay
   - Take card from this controller
   - Right-click them together to pair
   - Put relay card back in relay
   - Put controller card back in controller
7. **Start controller:**
   ```
   turret-controller
   ```

**✅ Verification:**
- Shows "✓ Connected to relay!"
- Shows "✓ Synced X global players"
- Server shows increased controller count

**🔁 Repeat for each dimension!**

### Step 4: Client Manager Setup

1. **Assemble computer** with linked card
2. **Upload program:**
   ```lua
   turret-client.lua
   ```
3. **Pair linked card** with relay (same process as controller)
4. **Start client:**
   ```
   turret-client
   ```
5. **Login** with your admin credentials
6. **You're ready to manage turrets!**

---

## Quick Start

### Adding Your First Player

**To Trust Player Globally (All Dimensions):**

1. Start client manager
2. Login with admin credentials
3. Press **1** - Add Trusted Player
4. Press **1** - ALL dimensions (global)
5. Enter player name: `Steve`
6. Confirm
7. ✅ Player added!
8. **Wait 30 seconds for sync**
9. Steve can now use ALL turrets in ALL dimensions

**To Trust Player in Specific Dimension:**

1. Start client manager
2. Login
3. Press **1** - Add Trusted Player
4. Press **2** - Specific controller
5. Select controller from list (e.g., #2 for Nether)
6. Enter player name: `NetherMiner`
7. Confirm
8. ✅ Player added to Nether only!
9. **Wait 30 seconds for sync**
10. NetherMiner can use turrets in Nether ONLY

### Removing a Player

**Remove Globally:**

1. Client → Press **2** - Remove Trusted Player
2. Press **1** - ALL dimensions
3. Enter player name
4. Confirm
5. ✅ Player removed from everywhere!

**Remove from Specific Dimension:**

1. Client → Press **2** - Remove Trusted Player
2. Press **2** - Specific controller
3. Select controller
4. Enter player name
5. Confirm
6. ✅ Player removed from that dimension only!

### Viewing Trusted Players

1. Client → Press **3** - View Trusted Players
2. See two sections:
   - **GLOBAL TRUSTED** - Players with access everywhere
   - **CONTROLLER-SPECIFIC** - Per-dimension access

Example Output:
```
GLOBAL TRUSTED (All Dimensions):
  • Steve          Global
  • Alex           Global

CONTROLLER-SPECIFIC TRUSTED:
  Nether:
    • NetherMiner
    • PiglinFriend
  The End:
    • DragonSlayer
```

### Managing Offline Controllers (Server)

1. Press **F5** on server
2. Login as admin
3. Press **6** - Manage Controllers
4. See all controllers with status (ONLINE/OFFLINE)
5. **To remove offline controllers:**
   - Press **A** - Cleanup all offline
   - Confirm with Y
   - ✅ All offline controllers removed!

---

## Component Details

### Central Server

**File:** `turret-server-fixed.lua`

**What It Does:**
- Stores global trusted player list
- Stores controller-specific trusted lists
- Authenticates managers (username/password)
- Processes add/remove commands
- Broadcasts changes to ALL relays
- Provides admin panel (F5 hotkey)

**Display:**
```
═══════════════════════════════════════════
     Cross-Dimensional Turret Server
═══════════════════════════════════════════
Controllers: 5       Total Turrets: 28
Trusted: 12          Port: 19321
Relays: 3            Commands: 42

CONTROLLERS BY WORLD:
World           Controller      Turrets  Status
────────────────────────────────────────────────
Overworld       Main Base         8      ONLINE
Nether          Fortress          6      ONLINE
The End         Portal            5      ONLINE
Twilight Forest Tree Base         9      ONLINE
```

**Admin Panel (F5):**
1. View All Admin Accounts
2. Create Admin Account
3. Delete Admin Account
4. View Activity Log (last 50 actions)
5. View Active Sessions
6. **Manage Controllers** ← NEW!
7. Exit Admin Mode

### Unified Relay

**File:** `turret-relay.lua`

**What It Does:**
- Routes messages between server and controllers
- Encrypts wireless messages (server ↔ relay)
- Routes via linked cards (relay ↔ controllers)
- Maintains connections to all components

**Display:**
```
═══════════════════════════════════════════
         Unified Relay Station
═══════════════════════════════════════════
Mode: MULTI-TUNNEL ←→ WIRELESS (ENCRYPTED)
Central Server: ✓ CONNECTED (ENCRYPTED)

Tunnels: 5 registered
Controllers: 4 active
Managers: 1 active

Messages:
→ Server: 142 (encrypted)
← Server: 138 (encrypted)
→ Clients: 280 (tunneled)

Encryption: ENABLED
```

### Turret Controller

**File:** `turret-controller.lua`

**What It Does:**
- Manages turrets in ONE dimension
- Syncs with server every 30 seconds
- Updates turret permissions automatically
- Monitors health via heartbeat

**Display:**
```
═══════════════════════════════════════════
      Turret Controller - Nether Base
═══════════════════════════════════════════
World: Nether
Status: ✓ CONNECTED TO RELAY

Turrets: 6 connected
Global Trusted: 3 players
Local Trusted: 2 players (this controller)

Last Sync: 12 seconds ago
Heartbeats Sent: 45
Syncs Received: 45

Recent Activity:
[14:23] ✓ Synced 3 global players
[14:23] ✓ Synced 2 local players
[14:22] Heartbeat #45
```

**Configuration:** `/home/turret-controller/config.cfg`
```lua
{
  controllerName = "Nether Base",
  worldName = "Nether"
}
```

### Client Manager

**File:** `turret-client.lua`

**What It Does:**
- User interface for remote management
- Connects via linked card to relay
- Authenticates with server
- Sends commands (add/remove players)

**Display:**
```
═══════════════════════════════════════════
      Turret Control Manager
═══════════════════════════════════════════
✓ Connected to Relay
User: admin

[1] Add Trusted Player
[2] Remove Trusted Player
[3] View Trusted Players
[4] View Controllers
[5] Logout

═══════════════════════════════════════════
```

---

## User Management

### Global vs Specific Permissions

**🌍 Global Trusted:**
- Access to ALL turrets in ALL dimensions
- Use for: Admins, moderators, core team
- Added via: Client → 1 → 1 → Player Name

**📍 Specific Trusted:**
- Access to ONE controller's turrets only
- Use for: Dimension teams, temporary access, guests
- Added via: Client → 1 → 2 → Select Controller → Player Name

### Example Scenarios

**Scenario 1: Server Staff**
```
Add "AdminSteve" globally
→ AdminSteve can use ALL turrets everywhere
```

**Scenario 2: Mining Team**
```
Add "Miner1" to Nether controller
Add "Miner2" to Nether controller
→ They can ONLY use Nether turrets
→ Blocked from Overworld, End, etc.
```

**Scenario 3: Event Guest**
```
Add "EventGuest" to Event dimension controller
[After event]
Remove "EventGuest" from Event controller
→ Temporary access, easy to revoke
```

**Scenario 4: Hybrid Access**
```
"CoreAdmin" - Global (everywhere)
"DimensionLead" - Global (everywhere)
"TeamMember1" - Specific to Nether (mining)
"TeamMember2" - Specific to End (dragon farm)
"Guest" - Specific to Spawn (protected area)
```

### Permission Priority

If player is in BOTH global AND specific lists:
- ✅ They have access (either list grants it)
- Removing from global doesn't affect specific
- Removing from specific doesn't affect global

**To completely remove a player everywhere:**
1. Remove from global list
2. Remove from each specific controller
3. Controllers sync within 30 seconds

---

## Admin Panel

### Accessing (Press F5 on Server)

1. Press **F5** key on server computer
2. Enter admin username
3. Enter admin password
4. Admin menu appears

**To Exit:** Press **F5** again or select Option 7

### Admin Account Management

**🔐 Default Account:**
- Username: `admin`
- Password: `admin123`
- ⚠️ **CHANGE THIS IMMEDIATELY!**

**Creating Admin Account:**
1. F5 → Login
2. Option 2 - Create Admin Account
3. Enter new username
4. Enter password (min 8 characters)
5. Confirm password
6. ✅ Account created!

**Deleting Admin Account:**
1. F5 → Login
2. Option 3 - Delete Admin Account
3. Enter username to delete
4. Confirm with Y/N
5. ✅ Account deleted!

**Note:** Cannot delete default "admin" account (safety feature)

### Activity Log

**View Recent Actions:**
1. F5 → Login
2. Option 4 - View Activity Log
3. See last 50 actions with:
   - Timestamp
   - Action description
   - Who did it
   - Type (TURRET/ADMIN/SECURITY)

**Example Log:**
```
[14:23:15] ✓ Added globally: Steve [by admin]
[14:25:42] Controller removed: Old Base [by admin]
[14:30:11] Failed login attempt: hacker
[14:31:05] Admin mode entered by: admin
[14:35:22] ✓ Removed from Nether: BadGuy [by moderator]
```

### Controller Management

**View and Remove Controllers:**
1. F5 → Login
2. Option 6 - Manage Controllers
3. See all controllers:

```
#  World/Dimension    Name          Status    HB
─────────────────────────────────────────────────
1  Overworld          Main Base    ONLINE    15s
2  Nether             Fortress     ONLINE    22s
3  The End            Portal       OFFLINE   245s
4  Twilight Forest    Old Base     OFFLINE   512s
```

**Remove Single Controller:**
- Enter controller number (e.g., `3`)
- Confirm with Y
- ✅ Controller removed!

**Cleanup All Offline:**
- Enter `A`
- Confirm with Y
- ✅ All offline controllers removed!

**Cancel:**
- Enter `0`
- Returns to menu

---

## Client Manager

### Menu Options

**Main Menu:**
```
[1] Add Trusted Player       → Grant access
[2] Remove Trusted Player    → Revoke access
[3] View Trusted Players     → See who has access
[4] View Controllers         → See all controllers
[5] Logout                   → End session
```

### Adding Players (Detailed)

**Global Add (All Dimensions):**
```
Steps:
1. Press 1
2. Enter player name: Steve
3. Press 1 (ALL dimensions)
4. Confirm
5. ✓ Added globally!
6. Wait 30s for sync
7. Done!

Result: Steve can use turrets in ALL dimensions
```

**Specific Add (One Dimension):**
```
Steps:
1. Press 1
2. Enter player name: NetherMiner
3. Press 2 (Specific controller)
4. Select controller (e.g., #2 - Nether)
5. Confirm
6. ✓ Added to Nether!
7. Wait 30s for sync
8. Done!

Result: NetherMiner can ONLY use Nether turrets
```

### Removing Players (Detailed)

**Global Remove:**
```
Steps:
1. Press 2
2. Enter player name: BadGuy
3. Press 1 (ALL dimensions)
4. Confirm
5. ✓ Removed from ALL!
6. Wait 30s for sync
7. Done!

Result: BadGuy removed from ALL turrets everywhere
```

**Specific Remove:**
```
Steps:
1. Press 2
2. Enter player name: ExGuest
3. Press 2 (Specific controller)
4. Select controller (e.g., #3 - Event Area)
5. Confirm
6. ✓ Removed from Event Area!
7. Wait 30s for sync
8. Done!

Result: ExGuest removed from Event Area only
```

### Viewing Information

**Trusted Players (Option 3):**
```
Shows:
GLOBAL TRUSTED (All Dimensions):
  • Steve          Global
  • Alex           Global

CONTROLLER-SPECIFIC TRUSTED:
  Nether:
    • NetherMiner
    • PiglinFriend
  The End:
    • DragonSlayer
    • EnderPearl
  Twilight Forest:
    • ForestExplorer
```

**Controllers (Option 4):**
```
Shows:
World/Dimension       Controller Name    Turrets
─────────────────────────────────────────────────
Overworld             Main Base            8
Nether                Fortress             6
The End               Portal               5
Twilight Forest       Tree Base            9
```

---

## Troubleshooting

### Server Won't Start

**"Data card required!"**
- ❌ Problem: No Data Card installed
- ✅ Solution: Install Tier 2 or Tier 3 Data Card
- ✅ Solution: Restart server

**"Wireless network card required!"**
- ❌ Problem: No Wireless Network Card
- ✅ Solution: Install Wireless Network Card (Tier 2 recommended)
- ✅ Solution: Restart server

### Relay Can't Find Server

**"Searching for server..."**
- ❌ Problem: Out of range or server offline
- ✅ Check: Server running?
- ✅ Check: Within 400 blocks?
- ✅ Check: Both have Data Cards?
- ✅ Wait: Discovery retries every 5 seconds

### Controller Won't Sync

**"No response from relay"**
- ❌ Problem: Linked cards not paired or relay offline
- ✅ Check: Cards paired? (right-click together)
- ✅ Check: Relay running?
- ✅ Check: Correct card installed in relay?
- ✅ Try: Re-pair linked cards

**"Lists unchanged - skipping"**
- ✅ This is NORMAL! Lists haven't changed
- ✅ Turrets are already correct
- ❌ Only updates when lists actually change

### Player Still Has Access

**After removing player, they still have access:**
- ⏰ Wait: Up to 30 seconds for sync
- ✅ Check: Removed from both global AND specific?
- ✅ Check: Controller shows "Remove player" in log?
- 🔄 Force: Restart controller if stuck

### Commands Timeout

**"No response from server"**
- ✅ Check: Server running?
- ✅ Check: Relay connected to server?
- ✅ Check: Within wireless range?
- ✅ Check: Session not expired? (30 minutes)
- 🔄 Try: Re-login to get fresh session

### Multi-Dimension Issues

**Players not syncing to other dimensions:**
- ✅ Fixed in latest version!
- ✅ Server now broadcasts to ALL relays
- ✅ Update: `turret-server-fixed.lua`
- ✅ Update: `turret-controller.lua`
- 🔄 Restart: All controllers

---

## FAQ

### General

**Q: How many dimensions can I support?**
A: Unlimited! Just add a relay and controllers in each dimension.

**Q: How many turrets per controller?**
A: Limited only by available adapters. Tested with 50+ turrets per controller.

**Q: How many controllers per dimension?**
A: Multiple controllers can share turrets for redundancy.

**Q: Does this work with modded dimensions?**
A: Yes! Works with Twilight Forest, RFTools, any dimension.

### Setup

**Q: Do I need a relay in every dimension?**
A: Yes, at least one relay per dimension where you have controllers or managers.

**Q: Can I have multiple relays per dimension?**
A: Yes, for redundancy. Both will work simultaneously.

**Q: How do I pair linked cards?**
A: Right-click two linked cards together, then install them in relay and client/controller.

**Q: Can I move a controller to another dimension?**
A: Yes, but run `setup-wizard` again to update the dimension name.

### Usage

**Q: How long does sync take?**
A: Maximum 30 seconds (one heartbeat interval).

**Q: Can I add the same player multiple times?**
A: Yes, but has no additional effect. Just confirms already trusted.

**Q: Can trusted players add other players?**
A: No, only admin accounts can manage. Trusted players can only USE turrets.

**Q: What if I forget admin password?**
A: Use default admin/admin123 if it still exists, or edit encrypted file (difficult).

### Technical

**Q: How secure is this?**
A: AES encryption for wireless, MD5+salt for passwords. Sufficient for Minecraft.

**Q: What's the network bandwidth?**
A: Minimal. ~1KB per controller per 30 seconds.

**Q: Does this cause lag?**
A: No, very lightweight. Tested with 20+ controllers.

**Q: Can I customize the port?**
A: Yes, change PORT in server and relay code (must match).

---

## Quick Reference

### 🎮 Common Commands

```
ADD PLAYER GLOBALLY:
  Client → 1 → 1 → Player Name → Confirm

REMOVE PLAYER GLOBALLY:
  Client → 2 → 1 → Player Name → Confirm

ADD PLAYER TO DIMENSION:
  Client → 1 → 2 → Select Controller → Player Name → Confirm

REMOVE OFFLINE CONTROLLERS:
  Server F5 → 6 → A → Confirm

VIEW TRUSTED PLAYERS:
  Client → 3

CREATE ADMIN ACCOUNT:
  Server F5 → 2 → Username → Password → Confirm
```

### ⚙️ Important Info

```
Port:              19321
Wireless Range:    400 blocks
Sync Time:         30 seconds (automatic)
Session Timeout:   30 minutes
Default Admin:     admin / admin123 (CHANGE THIS!)
```

### 📂 File Locations

```
Server:
  /home/turret-control/trusted-players.dat (encrypted)
  /home/turret-control/admin-accounts.dat (encrypted)

Controller:
  /home/turret-controller/config.cfg (plain text)
```

### 🔑 Keyboard Shortcuts

```
Server:
  F5         → Open/Close Admin Panel

Client:
  1-5        → Menu selections
  Backspace  → Delete character during input
  Enter      → Confirm input

Admin Confirmations:
  Y          → Yes/Confirm
  N          → No/Cancel
  ESC        → Cancel
```

---

## 🎉 You're All Set!

Your cross-dimensional turret control system is ready! 

**Quick Start Checklist:**
- ✅ Server running with F5 admin access
- ✅ Relay connected (shows "ENCRYPTED")
- ✅ Controllers synced (shows player counts)
- ✅ Client logged in (shows menu)
- ✅ Default password changed
- ✅ First player added and working

**Need Help?**
- Check Troubleshooting section
- Review error messages in activity log
- Verify all components within wireless range
- Ensure linked cards properly paired

**Enjoy your automated turret defense system!** 🎯

---

*End of README*
