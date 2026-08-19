# Monetization & Premium Activation — SwordFM Android

## Overview

SwordFM uses a **donations-only** monetization model — no in-app purchases, no AdMob, no third-party billing SDKs.
Users upgrade to Premium by sending money through one of two channels; an admin manually flips their account to premium in Firestore.

---

## Donation Channels

### bKash (Bangladesh)

- **Number:** `+8801723977791`
- **Steps for user:**
  1. Tap the bKash row in the donation dialog → opens the bKash app (`bkash://sendmoney?recipient=+8801723977791`)
  2. Enter amount → confirm with PIN
  3. Screenshot or note the transaction ID
- **Copy button** copies the number to clipboard as fallback

### BNB (BEP-20 / Binance Smart Chain)

- **Address:** `0x1Aeb51EeA471f6B7a826DE01e2c1381b8e618894`
- **Network:** BNB Smart Chain (BEP-20) only — do NOT send via Ethereum mainnet or other chains
- **Copy button** copies the address to clipboard

---

## Activation Runbook (Admin)

After a user donates, they email `support@swordfm.app` with:
- Their in-app UID (shown in Settings after signing in)
- Their registered email
- Transaction ID / screenshot

**To activate premium:**

```bash
# Via Firebase Console
# Navigate to: Firestore Database → users → {uid}
# Create/update document with fields:
{
  "entitlement": "premium",
  "source": "manual",
  "activatedAt": <serverTimestamp>
}
```

Or via FlutterFire CLI:
```bash
firebase functions:shell   # if using Cloud Functions
# Or directly from Firebase Console UI
```

**To verify activation in-app:** Sign in → Settings → Account card should show a gold "Premium" badge.

---

## Premium Features (Gated)

| Feature | Free | Premium |
|---------|------|---------|
| File browsing & operations | ✅ | ✅ |
| LAN sharing | ✅ | ✅ |
| Bluetooth sharing | ✅ | ✅ |
| Search & Trash | ✅ | ✅ |
| Document conversion (PDF/DOCX) | ❌ (shows donate dialog) | ✅ |
| Storage analysis | ✅ | ✅ |
| Duplicate detection | ✅ | ✅ |
| Network drive connections | ✅ | ✅ |

> **Note:** Conversion gating is planned but deferred in v1 for smoother launch. The PremiumGate widget is wired into the architecture and will enforce limits once the entitlement service is fully active.

---

## Firestore Schema

```
users/{uid}
  ├─ entitlement: "free" | "premium"
  ├─ source: "manual" | "billing" | "donation"
  └─ activatedAt: Timestamp
```

This is managed by `lib/services/entitlement_service.dart`. On sign-in/sign-up the app calls `loadEntitlement(uid)` which reads this document.

---

## Testing the Flow

1. **Sign in** with a test email via the app
2. Go to **Settings → Account** — you should see your email and a "Support / Premium" button
3. Tap it → donation dialog appears with bKash + BNB rows
4. Copy the address/number and confirm it works
5. In Firestore, manually set `entitlement: "premium"` for that uid
6. Reopen Settings → account card now shows a gold "Premium" badge

---

## Privacy & Compliance

- No payment data is stored in the app or on devices
- All financial data stays between the donor and the payment provider (bKash / Binance)
- The app does not track donation amounts or link payments to specific users beyond what the user voluntarily provides in an email
