# Vortex's Universal Weapon Slot System (VUWS) v0.1.0

A clean universal weapon slot management and reassignment system for GZDoom/UZDoom by Vortex.

- Pure ZScript
- Sibling to [Vortex's Universal Achievement System (VUAS)](https://github.com/vortexdesign/vortex-universal-achievement-system), [Vortex's Universal Objective System (VUOS)](https://github.com/vortexdesign/vortex-universal-objective-system), and [Vortex's Universal Sprint System (VUSS)](https://github.com/vortexdesign/vortex-universal-sprint-system). Same design language and architecture.
- Easy to use three-pane Weapon Slot Editor
- Weapon Slot Exclusion Editor
- Import / Export your slot configuration via console commands
- Full options menu under **Options > Universal Weapon Slot System**
- Optional HUD of weapon icons in current weapon slot
- Works out-of-the-box with vanilla Doom/Doom 2 and tested with Brutal Doom, Project Brutality and many more
- Optional Gearbox 0.8.0+ wheel sync via the separate `VUWS_Gearbox.pk3` companion bridge (requires map restart/save reload to apply slot changes to Gearbox)

## License

- MIT (see LICENSE file)
- Credit appreciated (see CREDITS.txt)

## Getting Started (Players)

1. Load the VUWS PK3 alongside any GZDoom/UZDoom weapon mod
2. Run `vuws_bind_slot_keys` once to route slot keys `0-9` through VUWS so your customizations apply
3. Run `vuws_bind_scroll_keys` once so the mouse wheel cycle respects your custom slot layout via `vuws_weapnext` / `vuws_weapprev`
4. Set your cap limit in the options menu (defaults to 3 per slot, slot 0 uncapped)
5. Open the loadout editor with `Q` (default bind, only applied if `Q` is unbound). Click a slot, click a weapon, then click Add to customize your layout
6. When a slot is full, walking over a weapon does nothing. Aim at the weapon and the HUD shows `Press [E] to pick up [WeaponName]` with the weapon you'd swap out
7. Press your bound `+use` key to swap: your oldest weapon in that slot drops to the floor, the new one takes its place
8. Customize cap action, per-slot caps, prompt color, HUD anchors, and notification style under **Options > Universal Weapon Slot System**
9. Optionally add `VUWS_Gearbox.pk3` for the Gearbox companion bridge (requires map restart or save reload to apply slot changes to Gearbox)

## Getting Started (Modders)

1. Add VUWS to your project's load order
2. Call `VUWS_SlotHandler.IsAtCap(player, slot)` from ZScript to query slot state
3. For custom cap rules or pickup-rejection logic, subclass `VUWS_SlotSetup` and override the virtuals (`GetSlotCap`, `ShouldRejectPickup`, `ChooseBumpVictim`, `IsCountedAsSlotOccupant`, `ShouldOfferUseKeyPickup`, `IsCompatible`). Register your subclass in your `ZMAPINFO`
4. For pickup / reassignment / drop events, override `OnPickupBlocked`, `OnWeaponDropped`, or `OnReassignment` on your subclass
5. If your mod has its own slot system and shouldn't coexist with VUWS, override `IsCompatible` to return false. VUWS will detect this and suspend itself for the session

### Custom Cap Rules

```c
class MySlotCaps : VUWS_SlotSetup
{
    override int GetSlotCap(int slot, PlayerInfo player)
    {
        // Story-mode slot 3 is unlimited
        if (slot == 3) return 999;
        return -1;  // -1 = use built-in CVar logic
    }

    override bool IsCountedAsSlotOccupant(Weapon w)
    {
        // BD's akimbo classes shouldn't push the count past cap
        if (w is "PistolAkimbo") return false;
        return true;
    }

    override class<Weapon> ChooseBumpVictim(int slot, PlayerInfo player)
    {
        // FIFO instead of LRU: keep your own timestamp map
        return MyOldestInSlot(slot, player);
    }
}
```

Register in your mod's `ZMAPINFO`:

```
gameinfo
{
    AddEventHandlers = "MySlotCaps"
}
```

### Event Hooks

```c
class MyPickupReactions : VUWS_SlotSetup
{
    override void OnPickupBlocked(PlayerInfo player, Weapon weap, int slot)
    {
        // Player tried to pick up a weapon at-cap, log to journal
    }

    override void OnWeaponDropped(PlayerInfo player, Weapon weap, int slot, int reason)
    {
        // reason is VUWS_DropReason:
        //   0 = VUWS_DROP_RECONCILE  (WorldTick over-cap drop after GiveInventory bypass)
        //   1 = VUWS_DROP_LRU_SWAP   (block_action 1 pickup-time swap)
        //   2 = VUWS_DROP_USE_KEY    (block_action 2 use-key pre-bump)
    }

    override void OnReassignment(PlayerInfo player, class<Weapon> wc, int oldSlot, int newSlot, class<Weapon> bumped)
    {
        // Fire stat tracker, play sound, etc.
    }
}
```

### Hard Opt-Out for Incompatible Mods

```c
class MyHDCompatCheck : VUWS_SlotSetup
{
    override bool IsCompatible()
    {
        // Hideous Destructor has its own 4-weapon-total cap, suspend VUWS
        return false;
    }
}
```

`IsCompatible` is called once at `WorldLoaded`. Returning false suspends VUWS for the entire session. For per-pickup dynamic decisions use `ShouldRejectPickup` instead.

## Features

### Per-Slot Cap

Default 3 weapons per slot, configurable per slot via `vuws_cap_0` through `vuws_cap_9` (`-1` = fall through to `vuws_cap_default`). `vuws_unlimited_for_slot_0` defaults on so fist / chainsaw stay free.

Counting is replacement-aware: BD's `Pistol replaces Pistol` and similar chains all map to the original class for cap purposes. Sister weapons (primary + alt-fire pair) count as one occupant by default, toggle via `vuws_count_sisters_as_one`. User-configurable exclude list via `vuws_exclude_classes` for mod-specific edge cases like BD's `PistolAkimbo` / `DualMP40` that aren't sister-linked but conceptually shouldn't take a slot.

### At-Cap Pickup Actions (`vuws_block_action`)

| Mode | Behavior |
|---|---|
| `0` Silent reject | Walking over an at-cap weapon does nothing, weapon stays in world |
| `1` LRU swap | Walking over auto-swaps: oldest in slot drops, new one takes its place |
| `2` Use-key required (default) | Walk-over does nothing. Aim at the weapon, HUD shows the bump prompt, press `+use` to accept the swap |

The default mode is the most "shooter loadout" feeling: every swap is intentional, no surprise drops from bumping into ammo piles.

### Use-Key Pickup

In mode 2, the trace runs every 3 tics (`vuws_use_trace_interval`) at `vuws_use_pickup_range` map units (default 96). The HUD shows two lines:

```
(replaces Shotgun in slot 3)
Press [E] to pick up Super Shotgun
```

`[E]` resolves to whatever you have bound to `+use`. Press it and the swap fires: the bumped weapon drops at the player's feet, the new one enters your inventory with its full pickup ceremony (sound, message, screen flash, ammo).

`vuws_pickup_detection` picks between three modes:
- `0` LineTrace only (engine ray cast, can miss in cluttered rooms)
- `1` Proximity scan only (closest pickupable Weapon within range, ignores aim)
- `2` Auto, LineTrace first then proximity fallback if the trace missed (default)

**Player-class twin handling**: some weapon mods (Brutal Doom v21 for example) ship multiple `bSpecial` Inventory actors at the same XY, each restricted to a different player class via `+Inventory.RestrictAbsolutely`. Example: BD's SuperShotgun spawns BOTH `ClassicSSG` (Purist-only) AND `BrutalSSGSpawner` (BDoomer-only). VUWS mirrors the engine's `PIT_CheckThing` iterator at the trace hit XY so the matching twin always wins, regardless of which one the LineTrace returned first. Verified with BD v21 SuperShotgun pickup for both player classes.

### Slot Reassignment Menu (Q Key)

Three-pane editor: slot list on the left, in-slot weapons top-right, all weapons bottom-right. Click a weapon then click a slot to assign. Six buttons: ADD, REMOVE, GIVE (debug, gives you the weapon), DROP, RESET SLOT, RESET ALL. Mouse and keyboard driven, no drag-and-drop required.

Reassignment semantics:
- New weapon goes to **slot index 0** (front of slot, first cycled when pressing the slot key)
- Existing occupants shift down by one
- If slot was already at cap, the last weapon in the slot drops to the floor
- If reassigning to its own current slot, no-op
- If reassigning to a slot that was below cap, just appends

Cross-mod portability: when you load a different weapon mod, classes from your previous mod's customization that don't resolve in the new modset are silently skipped. Your BD layout doesn't crash PB.

### Exclude List Editor

Separate menu opened via `vuws_exclude_menu` console alias or the **Manage Exclude List** link in **Options > Universal Weapon Slot System**. Checkbox list of all registered Weapon classes. Check classes you want VUWS to ignore for cap-counting purposes. Committed to `vuws_exclude_classes` on close, persists across sessions via INI.

### Slot Key Routing (`0`-`9`)

Slot keys go through VUWS's netevent path instead of the engine's direct `slot N` dispatch. This lets the handler check your `vuws_user_slot_N` mapping first, then fall back to the engine slot table if you haven't customized.

Existing GZDoom users with pre-VUWS `1` `slot 1` binds keep their old binds. Type `vuws_bind_slot_keys` once to rebind all 10 keys to the VUWS-aware aliases. `vuws_unbind_slot_keys` reverts. Both persist to INI.

### Mouse Wheel Cycle (`vuws_weapnext` / `vuws_weapprev`)

Engine `weapnext` / `weapprev` (the default mouse wheel commands) walk the engine slot table directly, so they ignore your VUWS user_slot reassignments. VUWS ships parallel aliases that respect your custom layout.

Type `vuws_bind_scroll_keys` once to rebind `mwheelup` / `mwheeldown` to the VUWS-aware cycle. `vuws_unbind_scroll_keys` reverts. Both persist to INI.

Cycle order: slots `1, 2, 3, 4, 5, 6, 7, 8, 9, 0`, walking owned weapons within each slot using the same effective list the HUD shows (sister dedup, exclude filter, user_slot routing). Wraps at both ends. Rapid wheel ticks accumulate into one cycle per tic.

### Import / Export

Share your slot config with another player or back up before experimenting:

```
vuws_export_config
```

Prints your current 10-slot setup plus a compact 2-line import string. Paste the two lines into the recipient's console one at a time:

```
set vuws_pending_slot_config_csv "v1:|v1:|...|v1:Shotgun RocketLauncher|..."
vuws_import_config
```

The compact format trims to 240 chars per slot to stay under the INI line limit. Imports broadcast to all coop peers via `SendNetworkBuffer` so the layout syncs across the session.

### Auto-Show Loadout Menu

Three default-OFF user CVars that auto-open the loadout editor on specific events:

- `vuws_auto_show_on_first_map` opens on the first map load (once per session)
- `vuws_auto_show_on_map_change` opens every time a map loads
- `vuws_auto_show_on_death` opens after the player respawns

Useful for "kit-picker" feel where players pick their loadout before each map. Death wins over first-map wins over map-change, so the menu opens at most once per trigger frame.

### HUD Toasts

Toast notifications on cap block, swap, and reassignment. Slide-fade animation. Position, scale, opacity, duration, and colors all configurable. Disable entirely with `vuws_notify 0`.

### Current Slot HUD

Shows icons for owned weapons in the currently-active slot. Two alpha tiers: active weapon at full opacity, non-active owned weapons at `baseAlpha * 0.30`. Mode 0 (default) shows the HUD briefly on slot switch, mode 1 keeps it always visible. Eight position anchors with X/Y offsets, scale, and opacity.

### Player-Driven Settings vs Host-Driven Gameplay (MP Coop)

VUWS uses a hybrid CVar scope so MP coop stays deterministic without flattening per-player preferences:

**Server scope** (host-controlled, broadcasts to clients): `vuws_enabled`, `vuws_block_action`, `vuws_count_sisters_as_one`, `vuws_enforce_on_grant`, `vuws_use_trace_interval`, `vuws_use_pickup_range`, `vuws_pickup_detection`, `vuws_exclude_classes`. These drive the deterministic pickup decision tree, so all clients must agree.

**User scope** (per-player customization preserved): cap CVars (`vuws_cap_*`, `vuws_unlimited_for_slot_0`), HUD / notify / color CVars, `vuws_use_pickup_prompt`, `vuws_debug`. Each client keeps their own customization.

**Per-player slot configs** live in an in-handler `memoryUserSlots[80]` array (8 players × 10 slots). Synced cross-client via `SendNetworkBuffer('vuws_slot_full_sync')` from `PlayerEntered` and `PlayerSpawned`. CVar persistence (`vuws_user_slot_*` nosave strings) is per-machine local-player only, so MP coop never overwrites a client's local INI with another player's slot config.

VUWS is **single-player focused** as a primary design target but coop is supported deterministically for gameplay rules. Per-player visual prefs stay local.

### Gearbox Wheel Sync (Optional, Separate PK3)

The companion pk3 `VUWS_Gearbox.pk3` adds two pieces:

1. **VUWS_GearboxBridge** writes slot ORDER into Gearbox's `gb_custom_weapon_order` CVar (deferred to next map / save load since Gearbox's initialize is private)
2. **gb_HideService_VUWS** subclasses `gb_HideService` so Gearbox's wheel calls our dedup + slot-resolution logic each render frame, hiding BD-style variant duplicates and showing user-reassigned weapons in their new slot

Loading the pk3 is the toggle. Removing it is the disable. Zero cost when Gearbox isn't loaded (CVar lookup at OnRegister, all paths bail on the cached `hasGearbox` bool).

VUWS_Gearbox is GPL-3.0 because it has compile-time references to Gearbox's `gb_*` classes. The main VUWS pk3 is MIT and has no Gearbox dependency.

Manual flush via `vuws_gearbox_resync` for cases where you edit `vuws_user_slot_*` directly in console and want the wheel to update without waiting for a map load.

## Keybinds

Rebindable under **Options > Customize Controls > Universal Weapon Slot System** and **Universal Weapon Slot Keys**:

| Key | Action |
|-----|--------|
| `Q` (defaultbind) | Open Slot Editor |
| `Z` (defaultbind) | Open Exclude List |
| `0`-`9` (defaultbind) | VUWS-aware slot keys (intercept + user_slot resolve) |

`defaultbind` only applies when the key isn't already bound. Existing users keep their bindings and can rebind via the menu.

## API Reference

### Static Query API

```c
static play int GetSlotCap(int slot, PlayerInfo player)
    // Effective cap (Setup virtual + per-slot CVar + default fallback)

static clearscope int GetCVarSlotCap(int slot, PlayerInfo player)
    // CVar-only cap, no Setup virtual dispatch (clearscope-safe)

static play bool IsAtCap(PlayerInfo player, int slot)
    // True if the player's slot is at or above its effective cap

static clearscope bool IsClassExcluded(class<Weapon> wc)
    // True if the class is in vuws_exclude_classes OR Setup.IsCountedAsSlotOccupant returns false

static clearscope class<Weapon> DefaultChooseBumpVictim(int slot, PlayerInfo player)
    // Default bump victim picker (last index in slot)

static clearscope int ResolveSlotForClass(PlayerInfo player, class<Weapon> wc)
    // user_slot first then engine fallback

static clearscope bool PlayerOwnsLogicalEquivalent(class<Weapon> wc, Actor pawn)
    // Tag / sister / Dual dedup-aware ownership check

static play void ReassignWeapon(PlayerInfo player, class<Weapon> wc, int targetSlot)
    // Move a class to a different slot; bumps cap if target full
```

### Drop Reasons

```c
enum VUWS_DropReason
{
    VUWS_DROP_RECONCILE = 0,  // WorldTick over-cap drop (give cheat / GiveInventory bypass)
    VUWS_DROP_LRU_SWAP  = 1,  // block_action 1 swap-on-pickup
    VUWS_DROP_USE_KEY   = 2   // block_action 2 use-key pre-bump
}
```

### Setup Virtuals (override in `VUWS_SlotSetup` subclass)

```c
virtual bool IsCompatible()                                              { return true; }
virtual int  GetSlotCap(int slot, PlayerInfo player)                      { return -1; }  // -1 = CVar fallback
virtual bool IsCountedAsSlotOccupant(Weapon w)                            { return true; }
virtual bool ShouldRejectPickup(PlayerInfo player, Weapon weap, int slot, int count, int cap) { return true; }
virtual class<Weapon> ChooseBumpVictim(int slot, PlayerInfo player)
virtual bool ShouldOfferUseKeyPickup(Weapon w)                            { return true; }

virtual void OnPickupBlocked(PlayerInfo player, Weapon weap, int slot)
virtual void OnWeaponDropped(PlayerInfo player, Weapon weap, int slot, int reason)
virtual void OnReassignment(PlayerInfo player, class<Weapon> wc, int oldSlot, int newSlot, class<Weapon> bumped)
```

## Console Commands

```
vuws_help                 - Show available commands
vuws_status               - Show cap state for your player
vuws_list                 - List all slot occupants for your player
vuws_slot_editor          - Open the slot editor menu
vuws_exclude_menu         - Open the exclude list menu
vuws_clear_user_slots     - Clear all user slot assignments
vuws_clear_user_slot_N    - Clear one slot N (0-9)
vuws_export_config        - Print your slot configuration for sharing
vuws_import_config        - Apply a slot config previously stashed in vuws_pending_slot_config_csv
vuws_reset_defaults       - Reset all settings CVars to defaults
vuws_bind_slot_keys       - One-shot rebind 0-9 to VUWS-aware slot keys
vuws_unbind_slot_keys     - Revert 0-9 to engine slot keys
vuws_bind_scroll_keys     - One-shot rebind mwheelup / mwheeldown to VUWS-aware cycle
vuws_unbind_scroll_keys   - Revert mwheel to engine weapnext / weapprev
vuws_gearbox_resync       - Force-flush Gearbox bridge (no-op without VUWS_Gearbox.pk3)
```

`vuws_reset_defaults` is a KEYCONF alias chaining `set` commands directly, not a netevent. Chained `set` is used because ZScript `CVar.SetInt` on user-scope CVars doesn't reliably persist across game restart. Known engine quirk.

## Architecture

```
VUWS_LimitToken (Inventory)
  - Invisible item granted per player on PlayerSpawned
  - HandlePickup intercepts every Weapon pickup
  - Decision tree: spawn-grace / first-load-grace / exclude / forceAccept / at-cap

VUWS_SlotHandler (StaticEventHandler, order 0)
  - Per-player state (spawn grace, forceAccept, useEligible*, prevUseHeld, pending slot key)
  - Cached CVar refs (refreshed in OnRegister, read-only in hot paths)
  - cachedSetup (subclass-safe Setup lookup, mirrors sibling-mod pattern)
  - WorldTick: ReconcilePlayer + use-key trace + BT_USE edge fire + pending slot key dispatch
  - NetworkProcess: slot key intercept, add/remove/give/drop, exclude list commit, clear, export/import
  - TryPickupTwinsAt: mirrors engine PIT_CheckThing iterator over co-located bSpecial Inventory actors
  - TryPickupOne: replicates Inventory.Touch post-pickup ceremony (sound, message, screen flash)
  - Static API: GetSlotCap, IsAtCap, IsClassExcluded, ResolveSlotForClass,
                PlayerOwnsLogicalEquivalent, ReassignWeapon, LocateWeaponSlot

VUWS_SlotSetup (StaticEventHandler, order 5)
  - Modder subclass base with virtuals for cap, pickup, bump, drop, reassign
  - WorldLoaded registers self on handler.cachedSetup + writes suspendedByCompat

VUWS_SlotCommands (StaticEventHandler, order 5)
  - Console command dispatcher via KEYCONF alias -> netevent -> NetworkProcess

VUWS_SlotRenderer (EventHandler, order 5)
  - HUD toast queue (block / swap / reassign, slide-fade)
  - Use-pickup two-line prompt (replaces line + Press [E] line)
  - Current Slot HUD (icon strip for owned weapons in active slot)
  - InterfaceProcess receives "vuws_open_slot_editor" from play-scope hooks (auto-show flow)

VUWS_SlotEditorMenu (GenericMenu, UI scope)
  - Centered 3-pane slot editor
  - Buttons: ADD, REMOVE, GIVE, DROP, RESET SLOT, RESET ALL
  - Mouse + keyboard

VUWS_ExcludeListMenu (GenericMenu, UI scope)
  - Scrollable checkbox list per registered Weapon class
  - Commits on close via vuws_pending_exclude_csv staging CVar + netevent
```

## Examples

### Example 1: Story-Mode Quest Weapon Always Allowed

```c
class StoryQuestCaps : VUWS_SlotSetup
{
    override int GetSlotCap(int slot, PlayerInfo player)
    {
        // The "Ancient Sword" lives in slot 1 and never counts against cap
        if (slot == 1) return 999;
        return -1;
    }
}
```

### Example 2: Sprint-Based Loadout Restriction

```c
class HeavyWeaponLockout : VUWS_SlotSetup
{
    override bool ShouldRejectPickup(PlayerInfo player, Weapon weap, int slot, int count, int cap)
    {
        // Heavy weapons (slot 6+) only pickable while NOT sprinting
        if (slot >= 6 && VUSS_SprintHandler.IsSprinting(player.mo))
            return true;  // reject pickup
        return Super.ShouldRejectPickup(player, weap, slot, count, cap);
    }
}
```

### Example 3: Achievement on First Custom Reassignment

```c
class FirstLoadoutAchievement : VUWS_SlotSetup
{
    override void OnReassignment(PlayerInfo player, class<Weapon> wc, int oldSlot, int newSlot, class<Weapon> bumped)
    {
        VUAS_AchievementHandler.Unlock("first_loadout_customization");
    }
}
```

### Example 4: Map Script Locks the Loadout Editor During a Cutscene

ACS bridge is not provided by VUWS. Use a netevent from a script instead:

```c
// ZDoom ACS - mid-cutscene linedef sets a "VUWS suspended" CVar via console pass-through
SetCVar("vuws_enabled", 0);
// ... cutscene runs ...
SetCVar("vuws_enabled", 1);
```

### Example 5: Per-Map Exclude List Override

```c
class MapSpecificExcludes : VUWS_SlotSetup
{
    override bool IsCountedAsSlotOccupant(Weapon w)
    {
        // On MAP07 the rocket launcher counts as zero so players can hoard them
        if (level.mapName ~== "MAP07" && w is "RocketLauncher")
            return false;
        return Super.IsCountedAsSlotOccupant(w);
    }
}
```

---

## Changelog

### v0.1.0 (May 2026)

**Core System**
- Static handler with per-player slot state, spawn grace, first-load grace, reconciliation
- Sentinel-inventory pickup interception via VUWS_LimitToken's HandlePickup override
- Per-slot cap (default 3), per-slot CVars `vuws_cap_0` through `vuws_cap_9`
- Sister-weapon dedup (primary + alt-fire pair counts as one occupant)
- Replacement-aware class matching for mods using `replaces` (BD, PB)
- User-configurable exclude list via `vuws_exclude_classes` and the dedicated menu

**At-Cap Pickup Behavior**
- `vuws_block_action 0` silent reject (weapon stays in world)
- `vuws_block_action 1` LRU swap (oldest in slot drops on pickup)
- `vuws_block_action 2` use-key required (default, matches CoD / BF / Apex loadout feel)
- Pre-bump before forceAccept ensures the new weapon enters at index 0 of the slot
- Null bump-victim safety: pickup aborts entirely if no valid victim found (prevents +1 over cap)

**Use-Key Pickup**
- LineTrace with TRF_ALLACTORS at `vuws_use_pickup_range` (default 96 map units)
- Proximity scan fallback via BlockThingsIterator when LineTrace misses
- Auto mode (`vuws_pickup_detection 2`) tries LineTrace first then falls back
- Two-line HUD prompt with replaces-line above and Press-[key]-line below
- `[E]` placeholder resolves to whatever the player has bound to `+use` via Bindings.GetKeysForCommand
- StripColorEscapes helper cleans engine color codes from NameKeys output for the prompt

**BD-Style Player-Class Twin Handling**
- BD ships multiple bSpecial Inventory actors at the same XY each restricted via `+Inventory.RestrictAbsolutely`
- `TryPickupTwinsAt` mirrors engine `PIT_CheckThing` iterator: walks all co-located actors at the trace hit XY and calls CallTryPickup on each
- First success wins, `TryPickup` self-destroys the picked-up actor via GoAwayAndDie
- Replicates engine `Inventory.Touch` post-success ceremony (PlayPickupSound + PrintPickupMessage + screen bonusflash) since CallTryPickup alone skips them
- Verified working for BD v21 SuperShotgun pickup on both BDoomer and Purist player classes

**Slot Reassignment**
- Centered 3-pane editor menu (slot list, in-slot weapons, all weapons)
- ADD, REMOVE, GIVE, DROP, RESET SLOT, RESET ALL buttons
- Click weapon then click slot (or use ADD button) to assign
- Mouse + keyboard navigation, weapon icons reference loaded mod's `Weapon.Icon`
- Selection latched by `class<Weapon>` so external CVar changes don't ghost the cursor
- Scroll-follow uses `gametic` not `level.time` so menu pause doesn't freeze the gate

**Per-Slot User Persistence**
- `vuws_user_slot_0` through `vuws_user_slot_9` (nosave string) for local-player INI persistence
- In-session per-player state in `memoryUserSlots[80]` array (MAXPLAYERS × 10 slots)
- 240-char trim safety per slot to stay under the ~255 INI line limit
- Cross-mod portability: unknown class names silently skipped on read

**Slot Key Routing (0-9)**
- KEYCONF aliases fire `netevent vuws_slot_key N`, handler dispatches via `Weapon.Use(false)`
- `Weapon.Use(false)` not `A_SelectWeapon` so Heretic Tome of Power sister swap fires correctly
- No engine `slot N` chain in the alias (would let the engine start the down-animation before the handler could override)
- `vuws_bind_slot_keys` / `vuws_unbind_slot_keys` for one-shot setup/revert

**Mouse Wheel Cycle**
- KEYCONF aliases `vuws_weapnext` / `vuws_weapprev` parallel to engine `weapnext` / `weapprev`
- Handler builds flat ordered list across slots 1..9,0 using `BuildCurrentSlotEffective` (sister dedup + exclude filter + user_slot routing)
- Accumulator coalesces rapid wheel ticks into one cycle per WorldTick
- Reference weapon is `PendingWeapon` if set else `ReadyWeapon`, sister-aware lookup
- Wraps at both ends of the flat list
- `vuws_bind_scroll_keys` / `vuws_unbind_scroll_keys` for the one-shot setup, persistent across sessions

**Exclude List Editor**
- Scrollable checkbox list per registered Weapon class
- Sorted by engine slot ascending, unregistered classes sort to slot 100 (bottom)
- Commits on close via `vuws_pending_exclude_csv` staging CVar + netevent
- 240-char trim safety on commit with console-visible warning when classes get dropped

**Import / Export**
- `vuws_export_config` prints 10 `set vuws_user_slot_N "..."` lines plus a compact 2-line import form
- `vuws_import_config` reads `vuws_pending_slot_config_csv` (nosave noarchive), splits on `|`, applies up to 10 slots
- Round-trips through ReadUserSlot + WriteUserSlot for the 240-char trim safety
- Broadcasts to all MP peers via SendNetworkBuffer so coop loadouts sync

**Auto-Show Loadout Editor**
- Three default-OFF user CVars: `vuws_auto_show_on_first_map`, `vuws_auto_show_on_map_change`, `vuws_auto_show_on_death`
- Death wins over first-map (once-per-session) wins over map-change
- play->UI dispatch via `EventHandler.SendInterfaceEvent`, opened in UI scope via `Menu.SetMenu` in the renderer

**HUD**
- Toast notifications on block / swap / reassign with slide-fade animation
- Current Slot HUD icon strip for owned weapons in the active slot (8 anchors, configurable scale and opacity)
- Two alpha tiers: active weapon at full opacity, non-active owned at `baseAlpha * 0.30`

**Multiplayer / Coop**
- Hybrid CVar scope: behavior CVars server-scope (host-controlled, broadcasts to clients), preference CVars user-scope (per-player)
- Per-player slot configs isolated via `memoryUserSlots[80]` in-handler array
- Sync via `SendNetworkBuffer('vuws_slot_full_sync')` from PlayerEntered + PlayerSpawned
- CVar persistence gated to local consoleplayer only so MP coop slot configs never overwrite each other's local INI

**Optional Gearbox Bridge (separate VUWS_Gearbox.pk3, GPL-3.0)**
- Mirrors VUWS user_slot layout into Gearbox's `gb_custom_weapon_order` CVar (deferred to next map / save load)
- Two-pass op generator (D1 RotateSlot for placement, D2 RotatePriority for in-slot order) with replay-verify before write
- VUWS_MD5 is a BSD-3-Clause fork of 3saster's gb_MD5, renamed so VUWS has no typed `gb_*` references
- `gb_HideService_VUWS` subclasses gb_HideService so the wheel calls VUWS's dedup + slot-resolution per-render frame (visibility sync without needing map reload)
- Zero cost when Gearbox isn't loaded (CVar lookup at OnRegister, all paths bail on cached `hasGearbox` bool)

**Settings & Customization**
- Full options menu under **Options > Universal Weapon Slot System** (non-destructive `AddOptionMenu`)
- ~30 CVars across master / caps / behavior / use-pickup / HUD / colors / auto-show
- All CVars exposed in the menu
- `vuws_reset_defaults` alias chains `set` commands directly (bypasses the ZScript CVar.SetInt INI-persistence bug on user-scope CVars)

**Console Commands**
- `vuws_help`, `vuws_status`, `vuws_list`, `vuws_clear_user_slots`, `vuws_clear_user_slot_N`
- `vuws_export_config`, `vuws_import_config`, `vuws_reset_defaults`
- `vuws_bind_slot_keys`, `vuws_unbind_slot_keys`, `vuws_bind_scroll_keys`, `vuws_unbind_scroll_keys`, `vuws_gearbox_resync`
