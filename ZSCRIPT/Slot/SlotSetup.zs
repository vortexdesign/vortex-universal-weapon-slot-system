// SlotSetup.zs
// Base class for modder callback overrides
// Subclass to override per-pickup decisions and event hooks
//
// USAGE:
//
//   class MySlotSetup : VUWS_SlotSetup
//   {
//       override bool IsCompatible()
//       {
//           // Disable VUWS when our mod is loaded since we have our own slot system
//           return false;
//       }
//
//       override class<Weapon> ChooseBumpVictim(int slot, PlayerInfo p)
//       {
//           // Bump oldest by tracking pickup order in a separate map
//           return MyOldestTracker.GetOldestInSlot(p, slot);
//       }
//   }
//
//   // ZMAPINFO:
//   GameInfo { AddEventHandlers = "MySlotSetup" }
//
// SetOrder higher than 5 to win cachedSetup over the default

class VUWS_SlotSetup : StaticEventHandler
{
    override void OnRegister()
    {
        SetOrder(5);
    }

    // register self for subclass-safe lookup, evaluate IsCompatible() here
    // (handler runs first at SetOrder 0, Find() would miss subclasses)
    override void WorldLoaded(WorldEvent e)
    {
        let handler = VUWS_SlotHandler.GetHandler();
        if (handler)
        {
            handler.cachedSetup = self;
            handler.suspendedByCompat = !IsCompatible();
        }
    }

    // ---- Static per-session decisions ----

    // false = suspend VUWS for the session (HD-style mods with their own slot system)
    virtual bool IsCompatible()
    {
        return true;
    }

    // ---- Per-pickup decisions ----

    // per-slot cap, -1 = use CVar (vuws_cap_<N> with vuws_cap_default fallback)
    virtual int GetSlotCap(int slot, PlayerInfo player)
    {
        return -1;  // -1 = use built-in CVar logic (handler.GetSlotCap handles this)
    }

    // false = exclude from cap count, sister dedup is separate
    virtual bool IsCountedAsSlotOccupant(Weapon w)
    {
        return true;
    }

    // at-cap pickup decision, override to allow (story weapons, quest items)
    virtual bool ShouldRejectPickup(PlayerInfo player, Weapon weap, int slot, int count, int cap)
    {
        return true;
    }

    // Pick which weapon class to bump when reassigning into a full slot or LRU-swapping
    // Default: last index in the slot per the player's runtime WeaponSlots
    // Override for FIFO/oldest by maintaining a separate timestamp map
    virtual class<Weapon> ChooseBumpVictim(int slot, PlayerInfo player)
    {
        let handler = VUWS_SlotHandler.GetHandler();
        if (!handler) return null;
        return handler.DefaultChooseBumpVictim(slot, player);
    }

    // per-class opt-out, false suppresses the use-key prompt for this weapon
    virtual bool ShouldOfferUseKeyPickup(Weapon w)
    {
        return true;
    }

    // ---- Event hooks ----

    // Fires when the sentinel rejects a walk-over pickup
    virtual void OnPickupBlocked(PlayerInfo player, Weapon weap, int slot) {}

    // reason = VUWS_DropReason
    virtual void OnWeaponDropped(PlayerInfo player, Weapon weap, int slot, int reason) {}

    // Fires when a slot reassignment completes (via menu, drag-and-drop, or quick-key)
    // bumpedClass is null when no bump happened (slot wasn't at cap)
    virtual void OnReassignment(PlayerInfo player, class<Weapon> weapClass,
        int oldSlot, int newSlot, class<Weapon> bumpedClass) {}
}
