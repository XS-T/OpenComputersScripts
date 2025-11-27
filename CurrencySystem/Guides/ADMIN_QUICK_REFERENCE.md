# Banking System Quick Reference Card

## 🎯 For Server Administrators

---

## Configuration Quick Settings

### Location: `server_with_loans.lua`

```lua
-- Find this section near the top of the file:
local LOAN_CONFIG = {
    -- Interest Rates
    EXCELLENT = {min = 750, rate = 0.05},  -- 5%
    GOOD = {min = 700, rate = 0.08},       -- 8%
    FAIR = {min = 650, rate = 0.12},       -- 12%
    POOR = {min = 600, rate = 0.18},       -- 18%
    BAD = {min = 0, rate = 0.25},          -- 25%
    
    -- Loan Limits
    MAX_LOAN_EXCELLENT = 10000,
    MAX_LOAN_GOOD = 5000,
    MAX_LOAN_FAIR = 2000,
    MAX_LOAN_POOR = 500,
    MAX_LOAN_BAD = 0,
    
    -- Timing
    MIN_LOAN_AMOUNT = 100,
    MAX_LOAN_TERM_DAYS = 30,
    DAYS_UNTIL_LOCK = 7,      -- ⚠️ CHANGE THIS
    DAYS_UNTIL_DEFAULT = 30,   -- ⚠️ CHANGE THIS
    
    -- Fees & Penalties
    LATE_FEE_RATE = 0.10,      -- ⚠️ CHANGE THIS (10% per day)
    DEFAULT_PENALTY = 100,
    PAYMENT_BOOST = 5,
    
    -- Controls
    AUTO_LOCK_ENABLED = true   -- ⚠️ SET TO false TO DISABLE
}
```

---

## Quick Configuration Presets

### 🟢 Lenient (Casual Server)
```lua
DAYS_UNTIL_LOCK = 14
DAYS_UNTIL_DEFAULT = 60
LATE_FEE_RATE = 0.05
AUTO_LOCK_ENABLED = true
```

### 🟡 Balanced (Default)
```lua
DAYS_UNTIL_LOCK = 7
DAYS_UNTIL_DEFAULT = 30
LATE_FEE_RATE = 0.10
AUTO_LOCK_ENABLED = true
```

### 🔴 Strict (Economy Server)
```lua
DAYS_UNTIL_LOCK = 3
DAYS_UNTIL_DEFAULT = 14
LATE_FEE_RATE = 0.15
AUTO_LOCK_ENABLED = true
```

### ⚫ Manual Only
```lua
DAYS_UNTIL_LOCK = 999999
DAYS_UNTIL_DEFAULT = 30
LATE_FEE_RATE = 0.10
AUTO_LOCK_ENABLED = false
```

---

## Admin Panel Access

**Press F5** while server is running

**Default Password:** `ECU2025`
⚠️ **CHANGE THIS IMMEDIATELY!**

### Admin Menu
```
1. Create Account
2. Delete Account
3. Set Balance
4. Lock/Unlock Account
5. Reset Password
6. View All Accounts
7. View Locked Accounts      [NEW]
8. Unlock Account             [NEW]
9. View Loans                 [NEW]
10. Forgive Loan              [NEW]
11. Adjust Credit Score       [NEW]
12. Change Admin Password
```

---

## Common Admin Tasks

### Create ATM Register Account
```
F5 → Admin Panel
1. Create Account
   Username: ATM1
   Password: atm2025
   Balance: 10000
```

### Create Shop Owner Account
```
F5 → Admin Panel
1. Create Account
   Username: ShopOwner
   Password: <strong password>
   Balance: 0 (will receive payments)
```

### View Locked Accounts
```
F5 → Admin Panel
7. View Locked Accounts
   - Shows all locked accounts
   - Shows lock reason
   - Shows days locked
```

### Unlock Account
```
F5 → Admin Panel
8. Unlock Account
   Enter username
   Enter unlock reason
   Confirm
```

### Forgive Loan
```
F5 → Admin Panel
10. Forgive Loan
   Enter loan ID (e.g., LOAN000042)
   Confirm
   Note: Also unlocks account if locked
```

### Adjust Credit Score
```
F5 → Admin Panel
11. Adjust Credit Score
   Enter username
   Enter adjustment (+50 or -50)
   Confirm
```

---

## Auto-Lock Timeline

### Example: 1000 CR loan, 15-day term

```
Day 0:  Loan issued
Day 15: Due date (no payment)
Day 16: Late fee: 1120 + 112 = 1,232 CR owed
Day 17: Late fee: 1232 + 123.2 = 1,355 CR owed
Day 18: Late fee: 1355 + 135.5 = 1,491 CR owed
...
Day 22: 🔒 ACCOUNT LOCKED (7 days overdue)
        - User cannot login
        - Session terminated
        - Credit event recorded
...
Day 45: ⚠️ LOAN DEFAULT (30 days overdue)
        - Credit score: -100 points
        - Loan status: "default"
```

---

## Credit Score Ranges

| Score | Rating | Color | Interest | Max Loan |
|-------|--------|-------|----------|----------|
| 750-850 | EXCELLENT | 🟢 | 5% | 10,000 CR |
| 700-749 | GOOD | 🔵 | 8% | 5,000 CR |
| 650-699 | FAIR | 🟡 | 12% | 2,000 CR |
| 600-649 | POOR | 🟠 | 18% | 500 CR |
| 300-599 | BAD | 🔴 | 25% | 0 CR |

**Starting Score:** 650 (FAIR)

---

## Server Commands

### Check Server Status
```lua
-- In server console
print("Accounts: " .. stats.totalAccounts)
print("Loans: " .. stats.activeLoans)
print("Locked: " .. stats.accountsLocked)
```

### Manual Account Unlock (Emergency)
```lua
-- In server console
local acc = getAccount("player1")
if acc then
    acc.locked = false
    acc.lockReason = nil
    saveAccounts()
    print("Unlocked: player1")
end
```

### View Overdue Loans
```lua
-- In server console
local overdue, locked = checkOverdueLoans()
print("Overdue loans: " .. #overdue)
print("Accounts locked: " .. #locked)
```

### Force Save All Data
```lua
-- In server console
saveAccounts()
saveLoans()
saveCreditScores()
saveConfig()
print("All data saved")
```

---

## File Locations

### Server Files
```
/home/currency/
├── accounts.dat        [Encrypted account database]
├── admin.cfg          [Encrypted admin config]
├── loans.dat          [Encrypted loan database]
├── credit_scores.dat  [Encrypted credit data]
└── transactions.log   [Transaction history]
```

### Backup Command
```bash
# From OpenOS shell
cp /home/currency/*.* /home/backup/
```

### Restore from Backup
```bash
# From OpenOS shell
cp /home/backup/*.* /home/currency/
# Then restart server
```

---

## Troubleshooting

### "Account locked but shouldn't be"
**Fix:**
```
F5 → Admin Panel → Unlock Account
Or manually unlock in console
```

### "Loans not locking accounts"
**Check:**
1. `AUTO_LOCK_ENABLED = true`?
2. Server timer running?
3. Correct days passed?

**Quick test:**
```lua
DAYS_UNTIL_LOCK = 1  -- Set to 1 day for testing
```

### "Late fees too aggressive"
**Reduce:**
```lua
LATE_FEE_RATE = 0.05  -- Change to 5% per day
```

### "Players complaining about credit scores"
**Check:**
- Payment history (35% of score)
- Account age (10% of score)
- Active loans (<2 is good)
- Defaults (very bad)

**Admin can adjust:**
```
F5 → Admin Panel → Adjust Credit Score
```

### "ATM/Shop out of money"
**Refill:**
```
F5 → Admin Panel → Set Balance
Select: ATM1 or ShopOwner
Set new balance: 10000
```

---

## Monitoring

### Daily Checks
- [ ] Check overdue loans
- [ ] Review locked accounts
- [ ] Check ATM/Shop balances
- [ ] Review transaction log

### Weekly Checks
- [ ] Backup all data
- [ ] Review credit trends
- [ ] Check for system abuse
- [ ] Update documentation

### Monthly Checks
- [ ] Full system backup
- [ ] Review configuration
- [ ] Analyze loan defaults
- [ ] Consider rate adjustments

---

## Security Best Practices

### 🔐 Passwords
- ✅ Change admin password immediately
- ✅ Use strong passwords (10+ characters)
- ✅ Don't share admin password
- ✅ Change ATM/Shop passwords from defaults

### 💾 Backups
- ✅ Daily backups of /home/currency/
- ✅ Store backups off-server
- ✅ Test restore procedure
- ✅ Keep 7-day rolling backups

### 👥 User Management
- ✅ Monitor new account requests
- ✅ Set reasonable initial balances
- ✅ Watch for suspicious transfers
- ✅ Review locked accounts regularly

### 📊 Monitoring
- ✅ Check transaction log daily
- ✅ Watch for unusual loan patterns
- ✅ Monitor credit score trends
- ✅ Track default rates

---

## Emergency Procedures

### Server Crash
```
1. Restart server
2. Check data files exist
3. Restore from backup if corrupted
4. Notify users
```

### Data Corruption
```
1. Stop server
2. Restore from most recent backup
3. Restart server
4. Check transaction log for lost data
5. Manually recreate if necessary
```

### Mass Default Event
```
1. Review loan terms (too strict?)
2. Consider adjusting LATE_FEE_RATE
3. Offer loan forgiveness program
4. Unlock accounts individually
5. Adjust credit scores if warranted
```

### Exploit Discovered
```
1. Disable affected feature
2. Review transaction log
3. Rollback if necessary
4. Fix code
5. Notify users
```

---

## Performance Tips

### If Server is Lagging
```lua
-- Reduce check frequency
event.timer(7200, checkOverdueLoans, math.huge)  -- Every 2 hours instead of 1

-- Limit transaction log
if #transactionLog > 50 then  -- Reduce from 100
    table.remove(transactionLog)
end
```

### If Storage is Full
```bash
# Archive old logs
mv /home/currency/transactions.log /home/archive/trans_$(date).log

# Enable RAID for automatic distribution
# Label drives: "RAID" or "BANK"
```

---

## Quick Commands Reference

| Task | Command |
|------|---------|
| Admin Panel | `F5` |
| Exit Admin | `F5` or `F1` |
| View Accounts | `F5 → 6` |
| View Locked | `F5 → 7` |
| Unlock Account | `F5 → 8` |
| Server Status | `F5 → View UI` |
| Change Password | `F5 → 12` |

---

## Support Resources

### Documentation Files
- `BANKING_SYSTEM_GUIDE.md` - Complete system guide
- `LOAN_SYSTEM_DOCUMENTATION.md` - Loan system details
- `AUTO_LOCK_FEATURE_GUIDE.md` - Auto-lock documentation
- `AUTO_LOCK_IMPLEMENTATION.md` - Technical implementation

### Common Issues
- Lock not working → Check AUTO_LOCK_ENABLED
- Can't login → Check if account locked
- Late fees wrong → Check LATE_FEE_RATE
- No loans → Check credit score minimums

---

## Version History

**v2.2 (Current)**
- ✅ Credit score system
- ✅ Loan system
- ✅ Auto-lock feature
- ✅ Late fees
- ✅ Default handling

---

## Contact & Support

**For bugs or issues:**
- Check troubleshooting section
- Review documentation files
- Check OpenComputers forums
- Test in isolated environment

---

**🎉 End of Quick Reference Card**

Print this card and keep it near your server for easy reference!
