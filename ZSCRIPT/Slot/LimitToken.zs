// LimitToken.zs
// Invisible inventory item granted to every player on spawn
// Its HandlePickup intercepts every Weapon pickup, applies the cap rules
//
// Pickup decision tree (called by engine BEFORE the weapon is added to inventory):
//   - if not a Weapon: pass through (return false, engine handles normally)
//   - if class is excluded: pass through
//   - if slot at cap:
//       block_action 0: silent reject
//       block_action 1: drop oldest, allow pickup
//       block_action 2: reject unless forceAccept (use-key path)
//   - else: pass through

class VUWS_LimitToken : Inventory
{
    Default
    {
        Inventory.MaxAmount 1;
        Inventory.InterHubAmount 1;
        +Inventory.Undroppable
        +Inventory.Untossable
        +Inventory.KEEPDEPLETED
        +Inventory.PERSISTENTPOWER
        +Inventory.QUIET
        -Inventory.INVBAR
    }

    override bool HandlePickup(Inventory item)
    {
        if (!item || !(item is "Weapon"))
            return Super.HandlePickup(item);

        let weap = Weapon(item);
        let handler = VUWS_SlotHandler.GetHandler();
        if (!handler || !owner || !owner.player)
            return Super.HandlePickup(item);

        if (handler.cachedEnabledCVar && !handler.cachedEnabledCVar.GetBool())
            return Super.HandlePickup(item);

        if (handler.suspendedByCompat)
            return Super.HandlePickup(item);

        int pnum = owner.PlayerNumber();
        if (pnum < 0 || pnum >= MAXPLAYERS)
            return Super.HandlePickup(item);

        // grace windows: spawn=Player.StartItem chain, firstLoad=pre-VUWS saves
        if (handler.spawnGracePending[pnum] || handler.firstLoadGrace)
            return Super.HandlePickup(item);

        if (handler.IsClassExcluded(weap.GetClass()))
            return Super.HandlePickup(item);

        // forceAccept = use-key trace allowing this pickup once
        if (handler.forceAcceptForPlayer[pnum])
        {
            handler.forceAcceptForPlayer[pnum] = false;
            return Super.HandlePickup(item);
        }

        // user_slot first so reassignments gate on the new slot
        int slot = handler.ResolveSlotForClass(owner.player, weap.GetClass());
        if (slot < 0)
            return Super.HandlePickup(item);

        int cap = handler.GetSlotCap(slot, owner.player);
        int count = handler.CountSlotOccupants(owner, slot);

        if (count < cap)
            return Super.HandlePickup(item);

        // at-cap path
        let setup = handler.GetSetup();
        bool shouldReject = true;
        if (setup) shouldReject = setup.ShouldRejectPickup(owner.player, weap, slot, count, cap);

        if (!shouldReject)
            return Super.HandlePickup(item);

        int blockAction = handler.cachedBlockActionCVar
            ? handler.cachedBlockActionCVar.GetInt() : 2;

        if (blockAction == 1)
        {
            class<Weapon> bumpClass = setup
                ? setup.ChooseBumpVictim(slot, owner.player)
                : handler.DefaultChooseBumpVictim(slot, owner.player);
            let bumpInv = bumpClass ? owner.FindInventory(bumpClass) : null;

            // null bump = slot locked (cap=0 empty, or Setup returned null), silent reject
            if (!bumpClass || !bumpInv)
            {
                item.bPickupGood = false;
                if (setup) setup.OnPickupBlocked(owner.player, weap, slot);
                handler.LogBlockedToast(weap, slot);
                return true;
            }

            // Undroppable bump victim, fall through to silent reject so pickup is blocked
            // rather than firing a phantom OnWeaponDropped + leaving player over-cap
            if (!handler.DropWithScatter(owner, bumpInv, 0, 1))
            {
                item.bPickupGood = false;
                if (setup) setup.OnPickupBlocked(owner.player, weap, slot);
                handler.LogBlockedToast(weap, slot);
                return true;
            }
            if (setup) setup.OnWeaponDropped(owner.player, Weapon(bumpInv), slot, VUWS_DROP_LRU_SWAP);
            handler.LogToast(weap, slot, bumpClass);
            return Super.HandlePickup(item);
        }

        // block_action 0 (silent) + 2 (use-key) reject path; 2 re-enters via forceAccept
        item.bPickupGood = false;
        if (setup) setup.OnPickupBlocked(owner.player, weap, slot);
        handler.LogBlockedToast(weap, slot);
        return true;
    }
}
