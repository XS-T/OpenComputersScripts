# Automatic Account Locking for Overdue Loans - Feature Guide

## Overview

The enhanced banking server now includes **automatic account locking** when loans become severely overdue. This prevents delinquent borrowers from continuing to use banking services while having unpaid debts.

---

## Configuration

### Settings (in server code)

```lua
LOAN_CONFIG = {
    -- Account locking settings
    DAYS_UNTIL_LOCK = 7,        -- Lock account after 7 days overdue
    DAYS_UNTIL_DEFAULT = 30,    -- Mark as default after 30 days overdue
    AUTO_LOCK_ENABLED = true    -- Set to false to disable auto-locking
}
```

### Customization Options

**Adjust lock threshold:**
```lua
DAYS_UNTIL_LOCK = 7     -- Lock after 7 days (default)
DAYS_UNTIL_LOCK = 3     -- More strict - lock after 3 days
DAYS_UNTIL_LOCK = 14    -- More lenient - lock after 14 days
```

**Disable auto-locking:**
```lua
AUTO_LOCK_ENABLED = false  -- Manual admin locking only
```

---

## How It Works

### Timeline of Overdue Loan

```
Day 0:  Loan issued (1000 CR, 15-day term)
Day 15: Due date - no payment made
Day 16: Late fee applied (10% = 112 CR added)
Day 17: Late fee applied (10% of 1112 = 111.2 CR added)
...
Day 22: Account LOCKED (7 days overdue) 🔒
        - User cannot login
        - Active session terminated
        - Credit event recorded
Day 45: Loan marked as DEFAULT (30 days overdue)
        - Credit score penalty: -100 points
        - Loan status changed to "default"
```

### What Happens When Account is Locked

1. **Account Status Updated:**
   ```lua
   account.locked = true
   account.lockReason = "Loan LOAN000042 overdue by 7 days"
   account.lockedDate = timestamp
   ```

2. **Active Session Terminated:**
   - User is immediately logged out
   - Cannot log back in until unlocked

3. **Credit Event Recorded:**
   ```lua
   recordCreditEvent(username, "account_locked", "Account locked due to loan...")
   ```

4. **Admin Notification:**
   - Lock logged in transaction log
   - Visible in admin panel
   - Alert in server console

### What Locked Users Cannot Do

❌ **Blocked Actions:**
- Login to account
- Transfer funds
- Apply for new loans
- Make purchases (ATM/Shop)
- Check balance
- Any banking operations

✓ **What Still Works:**
- Account exists in system
- Balance is preserved
- Loan continues accumulating late fees
- Credit history maintained

---

## Checking Lock Status

### From Server Admin Panel

**Press F5 → View All Accounts**

Locked accounts show:
```
USERNAME        BALANCE    SESSION    LOCKED     TXNS
player1         1500.00    none       YES        42
player2         2300.00    ACTIVE     no         18
```

### From Code (Admin Command)

```lua
{
    command = "check_account_status",
    username = "admin",
    password = "adminpass",
    targetUser = "player1"
}

-- Response:
{
    success = true,
    username = "player1",
    locked = true,
    lockReason = "Loan LOAN000042 overdue by 7 days",
    lockedDate = 1234567890,
    overdueLoans = {
        {loanId = "LOAN000042", daysOverdue = 7, remaining = 1500}
    }
}
```

---

## Unlocking Accounts

### Admin Manual Unlock

**Two scenarios for unlocking:**

#### 1. **Unlock with Payment Requirement**
User must pay off loan before unlock:

```lua
-- Admin checks overdue amount
{
    command = "admin_view_overdue_loans",
    username = "admin",
    password = "adminpass",
    targetUser = "player1"
}

-- User pays via admin (admin adds funds or forgives loan)
{
    command = "admin_forgive_loan",
    username = "admin",
    password = "adminpass",
    loanId = "LOAN000042"
}

-- Admin unlocks account
{
    command = "admin_unlock_account",
    username = "admin",
    password = "adminpass",
    targetUser = "player1"
}
```

#### 2. **Immediate Unlock (Override)**
Admin unlocks without payment:

```lua
{
    command = "admin_force_unlock",
    username = "admin",
    password = "adminpass",
    targetUser = "player1",
    reason = "Payment arrangement made"
}
```

### Admin Panel UI

**New Admin Menu Options:**

```
[7] View Locked Accounts
[8] Unlock Account
[9] View Overdue Loans by User
```

**Unlock Process:**
1. Press F5 → Admin Panel
2. Option 7: View Locked Accounts
3. Note username and reason
4. Option 8: Unlock Account
5. Enter username
6. Confirm unlock

---

## User Experience

### When User Tries to Login (Account Locked)

**Client Display:**
```
═══════════════════════════════════════════════════════
                    LOGIN FAILED
═══════════════════════════════════════════════════════

        ⚠ ACCOUNT LOCKED ⚠

        Reason: Loan LOAN000042 overdue by 7 days

        Please contact a server administrator to resolve
        your overdue loan and unlock your account.

        Total owed: 1,547.32 CR
        Days overdue: 7

        Press Enter to return
═══════════════════════════════════════════════════════
```

### When Active Session Gets Locked

**If user is logged in when lock occurs:**
```
═══════════════════════════════════════════════════════
              SESSION TERMINATED
═══════════════════════════════════════════════════════

        Your account has been locked due to an overdue
        loan payment.

        Loan ID: LOAN000042
        Days overdue: 7
        Amount owed: 1,547.32 CR

        Contact an administrator to resolve this issue.

        Press Enter to exit
═══════════════════════════════════════════════════════
```

---

## Prevention Tips for Users

### How to Avoid Account Locking

1. **Set Payment Reminders:**
   - Track loan due dates
   - Pay early if possible
   - Make partial payments to reduce balance

2. **Monitor Credit Score:**
   - Check credit regularly
   - Maintain good payment history
   - Avoid taking loans you can't repay

3. **Communication:**
   - Contact admin if having trouble
   - Request payment extension before due date
   - Ask about loan forgiveness programs

4. **Financial Planning:**
   - Only borrow what you need
   - Ensure you can repay within term
   - Keep emergency balance for payments

---

## Admin Best Practices

### Managing Locked Accounts

**Regular Review:**
```
Daily: Check overdue loans
Weekly: Review locked accounts
Monthly: Analyze default trends
```

**Communication:**
- Message locked users (external chat)
- Explain unlock requirements
- Document payment arrangements

**Flexibility:**
- Consider payment plans
- Partial loan forgiveness for hardship
- Temporary unlock for emergency access

### Unlock Decision Matrix

| Situation | Recommendation | Action |
|-----------|---------------|--------|
| Small loan, willing to pay | Immediate unlock | Forgive or accept payment |
| Large loan, payment plan | Conditional unlock | Written agreement |
| Repeat offender | Keep locked | Require full payment |
| Account compromise | Emergency unlock | Investigate, reset password |
| Inactive player | Keep locked | Archive account |

---

## Technical Details

### Database Changes

**Account Record (Enhanced):**
```lua
{
    name = "player1",
    passwordHash = "...",
    balance = 1500,
    locked = true,                -- NEW: Lock status
    lockReason = "Loan overdue",  -- NEW: Why locked
    lockedDate = 1234567890,      -- NEW: When locked
    -- ... other fields
}
```

**Loan Record (Enhanced):**
```lua
{
    loanId = "LOAN000042",
    username = "player1",
    status = "active",
    accountLocked = true,         -- NEW: Caused account lock
    -- ... other fields
}
```

### Lock Check in Login

```lua
-- During login validation
if account.locked then
    return {
        success = false,
        message = "Account locked: " .. (account.lockReason or "Contact admin"),
        locked = true,
        lockReason = account.lockReason,
        lockedDate = account.lockedDate
    }
end
```

### Automatic Unlock on Payment

**Option: Auto-unlock when loan paid:**

```lua
-- In makeLoanPayment function
if loan.remaining <= 0.01 then
    loan.status = "paid"
    
    -- Auto-unlock if this loan caused the lock
    if loan.accountLocked then
        local acc = getAccount(username)
        
        -- Check if user has other overdue loans
        local hasOtherOverdue = false
        for _, otherLoanId in ipairs(loans[username] or {}) do
            local otherLoan = loanIndex[otherLoanId]
            if otherLoan and otherLoan.status == "active" and 
               os.time() > otherLoan.dueDate then
                hasOtherOverdue = true
                break
            end
        end
        
        -- Unlock if no other overdue loans
        if not hasOtherOverdue and acc.locked then
            acc.locked = false
            acc.lockReason = nil
            log("Auto-unlocked account: " .. username .. " (loan paid)", "SECURITY")
        end
    end
end
```

---

## Security Considerations

### Why Auto-Lock is Important

1. **Debt Recovery:**
   - Incentivizes payment
   - Prevents further borrowing
   - Protects bank's assets

2. **Fair System:**
   - Consistent enforcement
   - No favoritism
   - Clear consequences

3. **Credit System Integrity:**
   - Makes credit scores meaningful
   - Prevents abuse
   - Maintains economic balance

### Safeguards

**Prevents Exploits:**
- Cannot create new account while locked
- Cannot transfer funds out before lock
- Session terminated immediately
- Lock persists across restarts

**Admin Oversight:**
- All locks logged
- Admin can override
- Manual unlock available
- Appeal process possible

---

## Configuration Examples

### Strict Configuration (High-Security Server)
```lua
LOAN_CONFIG = {
    DAYS_UNTIL_LOCK = 3,         -- Lock after 3 days
    DAYS_UNTIL_DEFAULT = 14,     -- Default after 14 days
    AUTO_LOCK_ENABLED = true,
    LATE_FEE_RATE = 0.15         -- 15% late fee (aggressive)
}
```

### Lenient Configuration (Casual Server)
```lua
LOAN_CONFIG = {
    DAYS_UNTIL_LOCK = 14,        -- Lock after 14 days
    DAYS_UNTIL_DEFAULT = 60,     -- Default after 60 days
    AUTO_LOCK_ENABLED = true,
    LATE_FEE_RATE = 0.05         -- 5% late fee (gentle)
}
```

### Manual-Only Configuration (Admin Controlled)
```lua
LOAN_CONFIG = {
    DAYS_UNTIL_LOCK = 999999,    -- Effectively disabled
    DAYS_UNTIL_DEFAULT = 30,     -- Still track defaults
    AUTO_LOCK_ENABLED = false,   -- No auto-lock
    LATE_FEE_RATE = 0.10         -- Standard late fee
}
```

---

## Statistics & Monitoring

### Admin Dashboard Stats

**New stats tracked:**
```lua
stats = {
    -- ... existing stats ...
    accountsLocked = 5,          -- Currently locked accounts
    totalLocks = 42,             -- All-time locks
    autoLocks = 38,              -- Automatic locks
    manualLocks = 4,             -- Admin manual locks
    averageDaysToLock = 7.2      -- Average overdue days before lock
}
```

### Lock Report Example

```
═══════════════════════════════════════════════════════
            LOCKED ACCOUNTS REPORT
═══════════════════════════════════════════════════════

Total Locked: 5 accounts
Total Owed: 12,547.32 CR

USERNAME      LOCKED DATE    DAYS    AMOUNT OWED    REASON
player1       11/20/2025     12      2,547.32       Loan LOAN000042
player2       11/23/2025     9       1,200.00       Loan LOAN000051
player3       11/25/2025     7       890.50         Loan LOAN000063
player4       11/24/2025     8       5,432.50       Loan LOAN000058
player5       11/26/2025     6       1,477.00       Loan LOAN000071

Oldest Lock: player1 (12 days)
Largest Debt: player4 (5,432.50 CR)
═══════════════════════════════════════════════════════
```

---

## FAQ

**Q: Can I disable auto-locking?**
A: Yes, set `AUTO_LOCK_ENABLED = false` in LOAN_CONFIG.

**Q: What if player is offline when lock occurs?**
A: Lock is applied when server checks (hourly). They'll see lock message on next login attempt.

**Q: Can locked users pay their loan?**
A: No - they cannot login. Admin must either accept payment externally or forgive loan.

**Q: Does lock affect existing session?**
A: Yes - active session is immediately terminated when lock occurs.

**Q: Can admin unlock without payment?**
A: Yes - admin has override capability for special circumstances.

**Q: What happens to late fees after lock?**
A: Late fees continue accumulating daily until loan is paid or forgiven.

**Q: Does unlock happen automatically when loan paid?**
A: By default, no. Admin must manually unlock. Can be enabled in code (see Technical Details).

**Q: Can user appeal a lock?**
A: System doesn't have built-in appeals. Handle via external communication/admin discretion.

---

## Troubleshooting

### Lock Not Triggering

**Check:**
1. `AUTO_LOCK_ENABLED = true`?
2. Server timer running? (hourly check)
3. Loan actually overdue by `DAYS_UNTIL_LOCK` days?
4. Account already locked?

**Debug:**
```lua
-- Add logging to checkOverdueLoans()
print("Checking loans at " .. os.date())
print("Found " .. #overdue .. " overdue loans")
```

### Cannot Unlock Account

**Check:**
1. Admin authenticated?
2. Username spelled correctly?
3. Account actually locked?
4. Database saved after unlock?

**Manual Unlock (Emergency):**
```lua
-- In server console
local acc = getAccount("player1")
acc.locked = false
acc.lockReason = nil
saveAccounts()
print("Account unlocked: player1")
```

### Late Fees Too Aggressive

**Adjust:**
```lua
LATE_FEE_RATE = 0.05  -- Reduce to 5% per day
-- or
LATE_FEE_RATE = 0.02  -- Very gentle: 2% per day
```

---

## Summary

**Automatic account locking provides:**
✅ Debt enforcement mechanism
✅ Incentive for on-time payments
✅ Protection for banking system
✅ Automatic admin assistance
✅ Clear consequences for delinquency

**Configuration options allow:**
⚙️ Adjustable lock threshold (days)
⚙️ Enable/disable auto-locking
⚙️ Custom late fee rates
⚙️ Admin override capability

**Best used with:**
💬 Clear user communication
📊 Regular account monitoring
🤝 Flexible unlock policies
📋 Documented procedures

---

**End of Guide**
