# Purchases and subscriptions

## Entitlements, not purchases

Google Play Billing hands back purchase objects with states, tokens,
acknowledgement flags, quantities and auto-renewal booleans. StoreKit hands back
something else entirely. None of that belongs in a game's menu code.

This SDK reduces all of it to a set of strings:

```gdscript
if MobileServices.iap.has_entitlement("remove_ads"):
    hide_the_ad_slot()

if MobileServices.iap.is_subscribed("premium"):
    $Label.text = "Premium — thank you"
```

An entitlement is granted by a **non-consumable** or a **subscription**, and is
re-checked against the store on every launch. `is_subscribed` is true only for
the subscription case, so a game can say "renews monthly" instead of "unlocked".

## Products

```ini
[iap.product.remove_ads]
type = "non_consumable"
entitlement = "remove_ads"

[iap.product.coins_100]
type = "consumable"
entitlement = ""            ; consumables grant nothing permanent

[iap.product.premium_monthly]
type = "subscription"
entitlement = "premium"
```

`android_id` and `ios_id` default to the section name, which is right for most
games — the same string on both stores.

## Buying

```gdscript
func _on_buy_pressed() -> void:
    MobileServices.iap.purchase("remove_ads")
```

`purchase()` returning `{}` means the store sheet opened. It is **not** a
completed purchase. A game that grants on that return value grants on a
cancelled purchase too.

```gdscript
func _ready() -> void:
    MobileServices.iap.purchase_completed.connect(_on_purchased)
    MobileServices.iap.purchase_pending.connect(_on_pending)
    MobileServices.iap.purchase_cancelled.connect(func(p): pass)  # not an error
    MobileServices.iap.purchase_failed.connect(_on_failed)

func _on_purchased(purchase: Dictionary) -> void:
    # Fires ONCE per purchase, including when it arrives from a restore.
    match purchase["product"]:
        "coins_100": coins += 100     # consumables are granted here
        _: pass                       # entitlements are granted by the SDK

func _on_pending(purchase: Dictionary) -> void:
    $Message.text = "Waiting for payment to clear — you'll get it automatically."
```

## Prices

Always show the store's own formatted price:

```gdscript
MobileServices.iap.products_loaded.connect(func(products):
    $BuyButton.text = "Remove ads — %s" % products["remove_ads"]["price"]
)
```

Building your own from `price_micros` and a currency code gets the symbol, the
separator or the position wrong in some locale — and the store screen is where
that is least forgivable. A player's App Store or Play account may be in a
different country than their phone's language.

The catalogue is empty until `products_loaded`, so build store screens from the
signal rather than on `_ready`.

## Consumables are never granted twice

A consumable is delivered once, on `purchase_completed`, and consumed with the
store immediately afterwards so it can be bought again. It grants no
entitlement, because an entitlement is a thing you keep and a hundred coins is a
thing you spend. The config validator warns if you try.

If a purchase completes and your game crashes before it saves the coins, the
consumable is already consumed and the coins are gone. That is true of every
mobile game and the reason `auto_consume` exists as a switch: turn it off, save
first, then call `MobileServices.iap` after your own save has landed.

## Pending purchases are not failures

Cash payments and Ask-to-Buy family approvals can leave a purchase pending for
days. Grant nothing, tell the player, and let it complete on a later launch —
which it will, because `iap/restore_on_start` re-reads what the account owns
every time the game starts.

## Restore

```gdscript
func _on_restore_pressed() -> void:
    MobileServices.iap.restore_purchases()
```

Apple **requires** a button that does this. Play does not, but a player on a new
phone expects one. It also runs automatically at start-up.

A restore is also how an entitlement is taken **away**: a subscription cancelled
in Play's own subscription screen simply stops appearing, and the SDK revokes it.
Entitlements you granted yourself with `grant_entitlement` are kept — they were
never the store's to report.

## Subscriptions and offers

```gdscript
var info := MobileServices.iap.get_product_info("premium_monthly")
for offer in info.get("offers", []):
    print("%s — %s every %s" % [offer["offer_id"], offer["price"], offer["billing_period"]])

# Buy a specific offer (a free trial, an introductory price):
MobileServices.iap.purchase("premium_monthly", offer["offer_token"])
```

Leave the token empty for the base plan. On Android a subscription **requires**
an offer token and a one-time product must not have one; the SDK picks the base
plan for you when you do not choose, because getting it wrong is a
`DEVELOPER_ERROR` with no explanation.

Every subscription needs an **active base plan** in the Play Console before any
of this works.

## The security limit, stated plainly

Entitlements are cached on the device (`user://mobile_services_entitlements.cfg`)
so a player who is off-line still owns what they bought. **A device cache is
editable by anyone who wants to edit it.** For a small game that is the right
trade: the alternative is a player who paid and cannot play on a train.

For a game where it matters, verify on a server:

```gdscript
MobileServices.iap.purchase_completed.connect(func(purchase):
    # purchase["token"] is the Play purchase token / StoreKit transaction id.
    # Send it to YOUR server, which verifies it with Google or Apple using
    # credentials that never leave the server, and answers yes or no.
    var ok := await my_backend.verify(purchase["token"], purchase["product"])
    if not ok:
        MobileServices.iap.revoke_entitlement(purchase["entitlement"])
)
```

Set `iap/auto_acknowledge = false` if the server should acknowledge, and be aware
of the deadline below.

**Never log a purchase token.** `MSLog.redact` strips them from anything this SDK
prints; do the same in your own code.

## Two deadlines that cost real money

- **An unacknowledged purchase is refunded by Google after three days.** The
  player paid, your game granted, and then the money goes back while the
  entitlement stays. `auto_acknowledge` handles it; if you turn it off, your
  server must acknowledge within three days.
- **An unconsumed consumable can never be bought again.** Play refuses the second
  purchase with `ITEM_ALREADY_OWNED`, which most games render as "something went
  wrong".

Both are silent until a player complains.

## Testing

Products only resolve for a build **signed with the same key as an uploaded
release** and installed from a Play track — internal testing is enough. A debug
APK sideloaded from your machine reports every product as unknown. That is Play's
behaviour, not this addon's, and it is the single most common "billing is
broken" report.

On iOS, use a **Sandbox tester** account and sign the Paid Applications
Agreement first.

Play's licence testers can buy anything for free and their purchases behave
exactly like real ones, including acknowledgement deadlines. Use them.
