// SlotHandler.zs
// Core handler for VUWS
// Owns cap logic, slot lookup, reconciliation, reassignment, use-key trace
//
// Pickup interception lives on VUWS_LimitToken (sentinel inventory)
// HUD rendering lives on VUWS_SlotRenderer
// Console commands live on VUWS_SlotCommands

class VUWS_SlotHandler : StaticEventHandler
{
    // Set by Setup.WorldLoaded so modder subclasses are found by lookup
    // Transient on save, re-cached on each WorldLoaded
    VUWS_SlotSetup cachedSetup;

    // Setup.IsCompatible() returned false means we suspend the whole library
    // Static per-session decision evaluated once at WorldLoaded
    bool suspendedByCompat;
    // save-load grace, suppresses pickup intercept + reconcile until next MAP* load
    // covers pre-VUWS saves; side effect: post-load `give` skips reconcile drops
    bool firstLoadGrace;

    // Cached CVar refs so hot paths skip CVar.FindCVar each tic
    transient CVar cachedDebugCVar;
    transient CVar cachedEnabledCVar;
    transient CVar cachedBlockActionCVar;
    transient CVar cachedSistersAsOneCVar;
    transient CVar cachedEnforceOnGrantCVar;
    transient CVar cachedExcludeClassesCVar;
    transient CVar cachedTraceIntervalCVar;
    transient CVar cachedUsePickupRangeCVar;
    transient CVar cachedPickupDetectionCVar;
    transient CVar cachedNotifyDurationCVar;

    // Parsed exclude list, refreshed when the CVar string changes
    transient String cachedExcludeRaw;
    transient Array<String> cachedExcludeParsed;
    // suppress poll-based revert after inline ApplyExcludeCsv until DEM_SINFCHANGED dispatches
    transient int excludeRefreshSuppressUntil;

    // Per-player transient state (cleared on WorldLoaded / respawn / death)
    bool spawnGracePending[MAXPLAYERS];      // Set true on PlayerSpawned, cleared on WorldTick
    bool forceAcceptForPlayer[MAXPLAYERS];   // Set by use-key trace, sentinel respects + clears
    Actor useEligibleWeapon[MAXPLAYERS];     // Currently aimed-at pickupable actor (Weapon or spawner)
    class<Weapon> useEligibleClass[MAXPLAYERS]; // Underlying Weapon class (= GetClass() for Weapon, name-stripped resolution for spawners)
    int  useEligibleSlot[MAXPLAYERS];        // Slot of the eligible weapon (precomputed for UI)
    class<Weapon> useEligibleBumpVictim[MAXPLAYERS]; // Precomputed bump-victim class for UI
    bool useEligibleAtCap[MAXPLAYERS];       // Whether the eligible weapon's slot is at cap
    bool useEligibleUseKey[MAXPLAYERS];      // Whether use-key would actually fire pickup
    int  useTraceCounter[MAXPLAYERS];        // Throttle counter for use-key trace
    bool prevUseHeld[MAXPLAYERS];            // Edge detection for BT_USE
    int  pendingSlotKey[MAXPLAYERS];         // -1 = none, 0-9 = slot key pressed this tic, processed in WorldTick
    int  pendingScrollAccum[MAXPLAYERS];     // accumulated cycle steps, positive = forward, negative = backward

    // Per-tic notification log for the renderer to consume
    // Cleared each WorldTick after the renderer reads it
    Array<VUWS_NotifyEntry> pendingToasts;

    // [pnum*10+slot], synced cross-client via PlayerEntered broadcast
    // user_slot_* CVars persist local player only
    String memoryUserSlots[MAXPLAYERS * 10];

    // auto-show menu state, WorldTick consumes after PlayerSpawned sets the just-spawned flag
    transient bool pendingAutoShowOnSpawn;      // set in WorldLoaded if !IsSaveGame
    transient bool autoShowFiredThisSession;    // once-per-session gate for first-map
    transient bool diedRecently[MAXPLAYERS];    // set in PlayerDied for the SP death route
    transient bool consolePlayerSpawnedThisTic; // set in PlayerSpawned, WorldTick clears

    // Slot HUD switch detection, transient since renderer reads in on-switch fade math
    transient int lastWeaponSwitchTic;
    transient class<Weapon> lastReadyWeaponSeen;

    override void OnRegister()
    {
        SetOrder(0);

        cachedDebugCVar              = CVar.FindCVar('vuws_debug');
        cachedEnabledCVar            = CVar.FindCVar('vuws_enabled');
        cachedBlockActionCVar        = CVar.FindCVar('vuws_block_action');
        cachedSistersAsOneCVar       = CVar.FindCVar('vuws_count_sisters_as_one');
        cachedEnforceOnGrantCVar     = CVar.FindCVar('vuws_enforce_on_grant');
        cachedExcludeClassesCVar     = CVar.FindCVar('vuws_exclude_classes');
        cachedTraceIntervalCVar      = CVar.FindCVar('vuws_use_trace_interval');
        cachedUsePickupRangeCVar     = CVar.FindCVar('vuws_use_pickup_range');
        cachedPickupDetectionCVar    = CVar.FindCVar('vuws_pickup_detection');
        cachedNotifyDurationCVar     = CVar.FindCVar('vuws_notify_duration');

        if (IsDebugEnabled())
            Console.Printf("VUWS: OnRegister complete");
    }

    // ---- Static helpers (mirror VUSS pattern) ----

    clearscope static int GetCVarInt(string cvarName, PlayerInfo p, int defaultVal = 0)
    {
        let cv = CVar.GetCVar(cvarName, p);
        return cv ? cv.GetInt() : defaultVal;
    }

    clearscope static bool GetCVarBool(string cvarName, PlayerInfo p, bool defaultVal = false)
    {
        let cv = CVar.GetCVar(cvarName, p);
        return cv ? cv.GetBool() : defaultVal;
    }

    static bool IsDebugEnabled()
    {
        let handler = GetHandler();
        if (handler && handler.cachedDebugCVar)
            return handler.cachedDebugCVar.GetBool();
        CVar dbg = CVar.FindCVar('vuws_debug');
        return dbg && dbg.GetBool();
    }

    clearscope static VUWS_SlotHandler GetHandler()
    {
        return VUWS_SlotHandler(StaticEventHandler.Find("VUWS_SlotHandler"));
    }

    static VUWS_SlotSetup GetSetup()
    {
        let handler = GetHandler();
        if (handler && handler.cachedSetup) return handler.cachedSetup;
        return VUWS_SlotSetup(StaticEventHandler.Find("VUWS_SlotSetup"));
    }

    // ---- Cap resolution ----

    // clearscope, no Setup virtual, safe from UI
    clearscope static int GetCVarSlotCap(int slot, PlayerInfo player)
    {
        if (slot < 0 || slot > 9) return 9999;

        if (slot == 0 && GetCVarBool('vuws_unlimited_for_slot_0', player, true))
            return 9999;

        String slotCVarName = String.Format("vuws_cap_%d", slot);
        int specificCap = GetCVarInt(slotCVarName, player, -1);
        if (specificCap >= 0) return specificCap;

        return GetCVarInt('vuws_cap_default', player, 3);
    }

    // play-scope, runs Setup virtual override
    static int GetSlotCap(int slot, PlayerInfo player)
    {
        if (slot < 0 || slot > 9) return 9999;

        let setup = GetSetup();
        if (setup)
        {
            int sc = setup.GetSlotCap(slot, player);
            if (sc >= 0) return sc;
        }
        return GetCVarSlotCap(slot, player);
    }

    // ---- Slot occupancy counting (sister dedup + exclude + replacement-aware) ----

    // clearscope, single source of truth for menu + NetworkProcess indexing
    // pass 1: engine slot 0-9 priority, pass 2: owned-but-unslotted
    clearscope void BuildSlotMenuWeapons(Actor pawn, out Array<class<Weapon> > outList,
        bool includeExcluded = false)
    {
        outList.Clear();
        if (!pawn || !pawn.player) return;

        // Pass 1: engine slot table, covers Player.WeaponSlot + KEYCONF setslot regardless of ownership
        for (int slot = 0; slot <= 9; slot++)
        {
            int sz = pawn.player.weapons.SlotSize(slot);
            for (int i = 0; i < sz; i++)
            {
                class<Weapon> wc = pawn.player.weapons.GetWeapon(slot, i);
                if (!wc) continue;
                if (!includeExcluded && IsClassExcluded(wc)) continue;
                if (outList.Find(wc) < outList.Size()) continue;
                outList.Push(wc);
            }
        }

        // Pass 2: owned weapons not in the engine slot table (added via inventory grant)
        bool sistersAsOne = cachedSistersAsOneCVar
            ? cachedSistersAsOneCVar.GetBool() : true;

        for (let it = pawn.Inv; it != null; it = it.Inv)
        {
            if (!(it is "Weapon")) continue;
            let w = Weapon(it);

            if (sistersAsOne && w.SisterWeapon)
            {
                // primary check respects exclude filter, prevents hiding both halves
                bool sisterIsPrimary = false;
                for (let probe = pawn.Inv; probe != it; probe = probe.Inv)
                {
                    if (probe == w.SisterWeapon)
                    {
                        bool probeIncluded = includeExcluded || !IsClassExcluded(probe.GetClass());
                        if (probeIncluded) sisterIsPrimary = true;
                        break;
                    }
                }
                if (sisterIsPrimary) continue;
            }

            if (!includeExcluded && IsClassExcluded(w.GetClass())) continue;
            if (outList.Find(w.GetClass()) < outList.Size()) continue;
            outList.Push(w.GetClass());
        }
    }

    // resolve duplicate display names by appending " (AmmoType)" or " (ClassName)"
    // shared by both menus so All Weapons and Exclude lists stay in sync
    clearscope static void DisambiguateDuplicateNames(out Array<String> names, Array<class<Weapon> > weapons)
    {
        int n = names.Size();
        if (n != weapons.Size()) return;

        Array<int> dupe;
        for (int i = 0; i < n; i++) dupe.Push(0);
        for (int i = 0; i < n; i++)
        {
            for (int j = i + 1; j < n; j++)
            {
                if (names[i] == names[j]) { dupe[i] = 1; dupe[j] = 1; }
            }
        }

        Array<String> suffixes;
        for (int i = 0; i < n; i++) suffixes.Push("");

        for (int i = 0; i < n; i++)
        {
            if (dupe[i] != 1 || !weapons[i]) continue;

            // ammo disambig fails if any entry lacks AmmoType1 OR two share an ammo type
            Array<String> groupAmmoNames;
            bool useAmmo = true;
            for (int j = 0; j < n; j++)
            {
                if (names[j] != names[i] || !weapons[j]) continue;
                let weapDef = Weapon(GetDefaultByType(weapons[j]));
                String ammoName = "";
                if (weapDef && weapDef.AmmoType1) ammoName = weapDef.AmmoType1.GetClassName();
                if (ammoName.Length() == 0) { useAmmo = false; break; }
                if (groupAmmoNames.Find(ammoName) < groupAmmoNames.Size()) { useAmmo = false; break; }
                groupAmmoNames.Push(ammoName);
            }

            if (useAmmo)
            {
                let weapDef = Weapon(GetDefaultByType(weapons[i]));
                suffixes[i] = weapDef.AmmoType1.GetClassName();
            }
            else
            {
                suffixes[i] = weapons[i].GetClassName();
            }
        }

        for (int i = 0; i < n; i++)
        {
            if (suffixes[i].Length() > 0)
                names[i] = names[i] .. " (" .. suffixes[i] .. ")";
        }
    }



    // replacement-aware, retries via GetReplacee for mods that `replaces` without SlotNumber
    clearscope static int LocateWeaponSlot(PlayerInfo player, class<Weapon> wc)
    {
        if (!player || !wc) return -1;
        bool found; int slot, idx;
        [found, slot, idx] = player.weapons.LocateWeapon(wc);
        if (found) return slot;

        class<Actor> replacee = Actor.GetReplacee(wc);
        if (replacee && replacee != wc)
        {
            let replaceeWeap = (class<Weapon>)(replacee);
            if (replaceeWeap)
            {
                [found, slot, idx] = player.weapons.LocateWeapon(replaceeWeap);
                if (found) return slot;
            }
        }

        return -1;
    }

    // clearscope, no Setup virtual
    // UI count, delegates to the same effective view HUD + cap gate use
    // Setup.IsCountedAsSlotOccupant virtual not applied (clearscope can't call it)
    clearscope int CountSlotOccupantsForUI(Actor pawn, int slot)
    {
        if (!pawn || !pawn.player) return 0;
        Array<class<Weapon> > effective;
        BuildCurrentSlotEffective(slot, pawn.player, effective);
        return effective.Size();
    }

    // play-scope, runs Setup virtual filter
    int CountSlotOccupants(Actor pawn, int slot)
    {
        if (!pawn || !pawn.player) return 0;
        // same dedup as HUD, BD variants count as one logical weapon
        Array<class<Weapon> > effective;
        BuildCurrentSlotEffective(slot, pawn.player, effective);

        let setup = GetSetup();
        if (!setup) return effective.Size();

        int count = 0;
        for (int i = 0; i < effective.Size(); i++)
        {
            let w = Weapon(pawn.FindInventory(effective[i]));
            if (w && setup.IsCountedAsSlotOccupant(w)) count++;
        }
        return count;
    }

    // ---- Exclude list ----

    // parse CSV to cachedExcludeRaw/Parsed and prune all players' memoryUserSlots
    // origin calls inline so the next menu render is fresh, peers catch up via WorldTick poll
    void ApplyExcludeCsv(String csv)
    {
        // SetString queues DEM_SINFCHANGED for next tic, cv.GetString() stays OLD until then
        // suppress the poll ~5 tics so it doesn't revert our inline write
        excludeRefreshSuppressUntil = gametic + 5;

        cachedExcludeRaw = csv;
        cachedExcludeParsed.Clear();
        if (csv.Length() > 0)
        {
            Array<String> tokens;
            csv.Split(tokens, ",");
            for (int i = 0; i < tokens.Size(); i++)
            {
                String tok = tokens[i];
                while (tok.Length() > 0 && tok.ByteAt(0) == 32) tok = tok.Mid(1);
                while (tok.Length() > 0 && tok.ByteAt(tok.Length() - 1) == 32)
                    tok = tok.Left(tok.Length() - 1);
                if (tok.Length() > 0) cachedExcludeParsed.Push(tok);
            }
        }

        // WriteUserSlot only persists CVar when pnum == consoleplayer
        for (int p = 0; p < MAXPLAYERS; p++)
        {
            if (!playeringame[p] || !players[p].mo) continue;
            for (int slot = 0; slot <= 9; slot++)
            {
                Array<class<Weapon> > list;
                ReadUserSlot(slot, players[p], list);
                bool changed = false;
                for (int i = list.Size() - 1; i >= 0; i--)
                {
                    if (IsClassExcluded(list[i]))
                    {
                        list.Delete(i);
                        changed = true;
                    }
                }
                if (changed) WriteUserSlot(slot, players[p], list);
            }
        }
    }

    // poll vuws_exclude_classes for change, every WorldTick on every client
    void RefreshExcludeListIfChanged()
    {
        if (gametic < excludeRefreshSuppressUntil) return;
        String raw = cachedExcludeClassesCVar
            ? cachedExcludeClassesCVar.GetString() : "";
        if (raw == cachedExcludeRaw) return;
        ApplyExcludeCsv(raw);
    }

    // clearscope read of parsed cache (refreshed in play scope)
    clearscope bool IsClassExcluded(class<Actor> cls)
    {
        if (!cls) return false;
        if (cachedExcludeParsed.Size() == 0) return false;

        String name = cls.GetClassName();
        for (int i = 0; i < cachedExcludeParsed.Size(); i++)
        {
            if (name ~== cachedExcludeParsed[i]) return true;
        }
        return false;
    }

    // ---- Bump victim selection ----

    // default: highest-index owned weapon in slot per WeaponSlots (lowest priority)
    // last entry in effective list = lowest user priority (or last engine occupant in fallback)
    clearscope class<Weapon> DefaultChooseBumpVictim(int slot, PlayerInfo player)
    {
        if (slot < 0 || slot > 9) return null;
        if (!player || !player.mo) return null;

        Array<class<Weapon> > effective;
        BuildCurrentSlotEffective(slot, player, effective);
        if (effective.Size() == 0) return null;
        return effective[effective.Size() - 1];
    }

    // ---- Reassignment ----

    // front-insert into user_slot_<targetSlot>, dedupe from other user slots
    // bumps tail if at cap, no engine setslot dispatch
    void ReassignWeapon(class<Weapon> wc, int targetSlot, PlayerInfo player)
    {
        if (!wc || !player || !player.mo) return;
        if (targetSlot < 0 || targetSlot > 9) return;

        // Read current user-slot list for targetSlot (this is OUR mapping, separate from engine)
        Array<class<Weapon> > newTargetList;
        ReadUserSlot(targetSlot, player, newTargetList);

        // seed via includeUnowned, fresh players keep engine occupants pre-pickup
        if (newTargetList.Size() == 0)
        {
            Array<class<Weapon> > seed;
            BuildCurrentSlotEffective(targetSlot, player, seed, true);
            for (int i = 0; i < seed.Size(); i++)
            {
                if (seed[i] == wc) continue;
                newTargetList.Push(seed[i]);
            }
        }

        // Already at front of user list, no-op
        if (newTargetList.Size() > 0 && newTargetList[0] == wc)
        {
            if (IsDebugEnabled())
                Console.Printf("VUWS: Reassign no-op, %s already at front of slot %d",
                    wc.GetClassName(), targetSlot);
            return;
        }

        // Remove wc from this list if it's somewhere else in it (avoid duplicates)
        int existingIdx = newTargetList.Find(wc);
        if (existingIdx < newTargetList.Size())
            newTargetList.Delete(existingIdx);

        // drop tail until under cap, while-loop covers mid-session cap-lower by 2+
        int cap = GetSlotCap(targetSlot, player);
        class<Weapon> bumpedClass = null;
        while (newTargetList.Size() >= cap && newTargetList.Size() > 0)
        {
            bumpedClass = newTargetList[newTargetList.Size() - 1];
            newTargetList.Delete(newTargetList.Size() - 1);
        }

        // Insert wc at front of target list
        newTargetList.Insert(0, wc);
        WriteUserSlot(targetSlot, player, newTargetList);

        // Remove wc from any OTHER user-slot lists (one weapon, one slot in user mapping)
        for (int s = 0; s <= 9; s++)
        {
            if (s == targetSlot) continue;
            Array<class<Weapon> > otherList;
            ReadUserSlot(s, player, otherList);
            int idx = otherList.Find(wc);
            if (idx < otherList.Size())
            {
                otherList.Delete(idx);
                WriteUserSlot(s, player, otherList);
            }
        }

        // No toast - menu-driven Add has its own visual feedback (slot pane updates)
        // Toasts reserved for in-game pickup events (blocked / swap)
        let setup = GetSetup();
        if (setup) setup.OnReassignment(player, wc, -1, targetSlot, bumpedClass);

        if (IsDebugEnabled())
        {
            String bumpedName = "(none)";
            if (bumpedClass) bumpedName = bumpedClass.GetClassName();
            Console.Printf("VUWS: Reassigned %s -> slot %d (bumped %s)",
                wc.GetClassName(), targetSlot, bumpedName);
        }
    }

    // setslot ccmd unreachable from ZS/ACS, user_slot CVars + KEYCONF netevent path

    // reads memoryUserSlots, format: "v1:WeaponA WeaponB ..." (v1: prefix optional)
    clearscope void ReadUserSlot(int slot, PlayerInfo player, out Array<class<Weapon> > outList)
    {
        outList.Clear();
        if (slot < 0 || slot > 9 || !player) return;

        int pnum = player.mo ? player.mo.PlayerNumber() : -1;
        if (pnum < 0 || pnum >= MAXPLAYERS) return;

        String raw = memoryUserSlots[pnum * 10 + slot];
        if (raw.Length() == 0) return;

        String body = raw;
        if (body.Length() >= 3 && body.Left(3) == "v1:")
            body = body.Mid(3);

        Array<String> tokens;
        body.Split(tokens, " ");
        for (int i = 0; i < tokens.Size(); i++)
        {
            String t = tokens[i];
            while (t.Length() > 0 && t.ByteAt(0) == 32) t = t.Mid(1);
            while (t.Length() > 0 && t.ByteAt(t.Length() - 1) == 32) t = t.Left(t.Length() - 1);
            if (t.Length() == 0) continue;

            class<Weapon> wc = t;
            if (!wc) continue;
            outList.Push(wc);
        }
    }

    // writes memory always, CVar only when pnum == consoleplayer (local INI per-player isolation)
    void WriteUserSlot(int slot, PlayerInfo player, Array<class<Weapon> > list)
    {
        if (slot < 0 || slot > 9 || !player) return;

        int pnum = player.mo ? player.mo.PlayerNumber() : -1;
        if (pnum < 0 || pnum >= MAXPLAYERS) return;

        String s = "v1:";
        for (int i = 0; i < list.Size(); i++)
        {
            if (i > 0) s.AppendFormat(" ");
            s.AppendFormat("%s", list[i].GetClassName());
        }

        // 240-char cap to fit INI line limit, drop oldest if exceeded
        uint MAX_LEN = 240;
        while (s.Length() > MAX_LEN && list.Size() > 1)
        {
            list.Delete(list.Size() - 1);
            s = "v1:";
            for (int i = 0; i < list.Size(); i++)
            {
                if (i > 0) s.AppendFormat(" ");
                s.AppendFormat("%s", list[i].GetClassName());
            }
        }

        memoryUserSlots[pnum * 10 + slot] = s;

        if (pnum == consoleplayer)
        {
            String cvName = String.Format("vuws_user_slot_%d", slot);
            let cv = CVar.GetCVar(cvName, player);
            if (cv) cv.SetString(s);
        }
    }

    // CVar -> memory hydration for the local consoleplayer only
    void RestoreLocalSlotsToMemory(int pnum)
    {
        if (pnum < 0 || pnum >= MAXPLAYERS) return;
        for (int slot = 0; slot <= 9; slot++)
        {
            String cvName = String.Format("vuws_user_slot_%d", slot);
            let cv = CVar.GetCVar(cvName, players[pnum]);
            memoryUserSlots[pnum * 10 + slot] = cv ? cv.GetString() : "";
        }
    }

    // push 10 slots so coop peers populate memoryUserSlots[pnum * 10 + s]
    void BroadcastFullSlotConfig(int pnum)
    {
        if (pnum < 0 || pnum >= MAXPLAYERS) return;
        let buf = new("NetworkBuffer");
        buf.AddInt8(pnum);
        Array<String> slots;
        for (int slot = 0; slot <= 9; slot++)
            slots.Push(memoryUserSlots[pnum * 10 + slot]);
        buf.AddStringArray(slots);
        EventHandler.SendNetworkBuffer('vuws_slot_full_sync', buf);
    }

    // mirrors engine PickWeapon cycling on the user list
    // null = no owned preference, caller falls through to engine pick
    clearscope class<Weapon> ResolveUserSlotPick(int slot, PlayerInfo player)
    {
        if (!player || !player.mo) return null;
        Array<class<Weapon> > list;
        ReadUserSlot(slot, player, list);
        if (list.Size() == 0) return null;

        // Locate ReadyWeapon's index in the user list, if present
        int readyIdx = -1;
        if (player.ReadyWeapon)
        {
            class<Weapon> readyClass = player.ReadyWeapon.GetClass();
            for (int i = 0; i < list.Size(); i++)
            {
                if (list[i] == readyClass) { readyIdx = i; break; }
            }
        }

        // If ReadyWeapon is in the list, cycle forward looking for the next owned entry
        if (readyIdx >= 0)
        {
            for (int step = 1; step <= list.Size(); step++)
            {
                int idx = (readyIdx + step) % list.Size();
                if (IsClassExcluded(list[idx])) continue;
                if (player.mo.FindInventory(list[idx])) return list[idx];
            }
        }

        // ReadyWeapon not in list (or list cycled back to itself): pick first owned
        for (int i = 0; i < list.Size(); i++)
        {
            if (IsClassExcluded(list[i])) continue;
            if (player.mo.FindInventory(list[i])) return list[i];
        }
        return null;
    }

    // does singleName look like the single half of "Dual<suffix>"?
    // splits suffix at camelCase, strips trailing s, 3-char floor per segment
    clearscope static bool IsDualSingleMatch(String singleName, String dualSuffix)
    {
        if (dualSuffix.Length() == 0) return false;
        String hay = singleName.MakeLower();

        if (SegmentMatches(hay, dualSuffix)) return true;

        // split at lowercase->uppercase transitions
        int segStart = 0;
        int n = dualSuffix.Length();
        for (int i = 1; i <= n; i++)
        {
            bool atBreak = (i == n);
            if (!atBreak)
            {
                int prev = dualSuffix.ByteAt(i - 1);
                int cur = dualSuffix.ByteAt(i);
                bool prevLower = (prev >= 97 && prev <= 122);
                bool curUpper = (cur >= 65 && cur <= 90);
                if (prevLower && curUpper) atBreak = true;
            }
            if (atBreak)
            {
                int segLen = i - segStart;
                if (segLen >= 3)
                {
                    String seg = dualSuffix.Mid(segStart, segLen);
                    if (SegmentMatches(hay, seg)) return true;
                }
                segStart = i;
            }
        }
        return false;
    }

    clearscope static bool SegmentMatches(String hayLower, String seg)
    {
        String needle = seg.MakeLower();
        if (needle.Length() < 3) return false;
        if (hayLower.IndexOf(needle) >= 0) return true;
        if (needle.ByteAt(needle.Length() - 1) == 115)  // trailing 's'
        {
            String singular = needle.Left(needle.Length() - 1);
            if (singular.Length() >= 3 && hayLower.IndexOf(singular) >= 0) return true;
        }
        return false;
    }

    // Current Slot HUD composition: user_slot first else engine fallback
    // includeUnowned=true is ReassignWeapon's seed pass for fresh players
    clearscope void BuildCurrentSlotEffective(int slot, PlayerInfo player,
        out Array<class<Weapon> > outList, bool includeUnowned = false)
    {
        outList.Clear();
        if (slot < 0 || slot > 9) return;
        if (!player || !player.mo) return;

        Array<class<Weapon> > userList;
        ReadUserSlot(slot, player, userList);
        bool userAuthoritative = (userList.Size() > 0);

        Array<class<Weapon> > raw;
        if (userAuthoritative)
        {
            for (int i = 0; i < userList.Size(); i++) raw.Push(userList[i]);
        }
        else
        {
            int sz = player.weapons.SlotSize(slot);
            for (int i = 0; i < sz; i++)
            {
                class<Weapon> wc = player.weapons.GetWeapon(slot, i);
                if (wc) raw.Push(wc);
            }
        }

        bool sistersAsOne = cachedSistersAsOneCVar
            ? cachedSistersAsOneCVar.GetBool() : true;

        for (int i = 0; i < raw.Size(); i++)
        {
            class<Weapon> wc = raw[i];
            if (!wc) continue;
            if (IsClassExcluded(wc)) continue;
            if (outList.Find(wc) < outList.Size()) continue;

            // engine fallback only, drop weapons claimed by other user_slots
            if (!userAuthoritative && IsClaimedByOtherUserSlot(wc, slot, player)) continue;

            // mirrors Inventory.CanPickup, filters BD-style class restrictions
            // (ClassicWeapon Restricted to Purist, BrutalWeapon Forbidden to Purist)
            // catches the transient post-give-all window before RestrictAbsolutely removes them
            readonly<Weapon> def = GetDefaultByType(wc);
            if (def)
            {
                int rsize = def.RestrictedToPlayerClass.Size();
                if (rsize > 0)
                {
                    bool allowed = false;
                    for (int r = 0; r < rsize; r++)
                    {
                        if (player.mo is def.RestrictedToPlayerClass[r]) { allowed = true; break; }
                    }
                    if (!allowed) continue;
                }
                int fsize = def.ForbiddenToPlayerClass.Size();
                bool forbidden = false;
                for (int f = 0; f < fsize; f++)
                {
                    if (player.mo is def.ForbiddenToPlayerClass[f]) { forbidden = true; break; }
                }
                if (forbidden) continue;
            }

            // owned-only filter, HUD reflects what you can actually cycle to
            // skip when seeding so unowned engine occupants stay in the customized slot
            let inv = player.mo.FindInventory(wc);
            if (!includeUnowned && !inv) continue;

            // sister dedup, owned uses instance chain, unowned falls back to class SisterWeaponType
            if (sistersAsOne)
            {
                bool sisterDup = false;
                if (inv)
                {
                    Inventory probe = inv;
                    Inventory chainStart = inv;
                    int chainSteps = 0;
                    while (probe && chainSteps < 8)
                    {
                        let w = Weapon(probe);
                        if (!w || !w.SisterWeapon) break;
                        class<Weapon> sisterClass = (class<Weapon>)(w.SisterWeapon.GetClass());
                        if (sisterClass && outList.Find(sisterClass) < outList.Size())
                        {
                            sisterDup = true;
                            break;
                        }
                        probe = w.SisterWeapon;
                        if (probe == chainStart) break;
                        chainSteps++;
                    }
                }
                else if (def && def.SisterWeaponType)
                {
                    class<Weapon> sisterClass = def.SisterWeaponType;
                    int chainSteps = 0;
                    while (sisterClass && chainSteps < 8)
                    {
                        if (outList.Find(sisterClass) < outList.Size())
                        {
                            sisterDup = true;
                            break;
                        }
                        if (sisterClass == wc) break;
                        readonly<Weapon> nextDef = GetDefaultByType(sisterClass);
                        if (!nextDef || !nextDef.SisterWeaponType) break;
                        sisterClass = nextDef.SisterWeaponType;
                        chainSteps++;
                    }
                }
                if (sisterDup) continue;
            }

            // tag dedup, owned uses instance Tag, unowned uses defaults Tag
            if (sistersAsOne)
            {
                String wcTag = inv ? inv.GetTag() : (def ? def.GetTag() : "");
                if (wcTag.Length() > 0)
                {
                    bool tagDup = false;
                    for (int j = 0; j < outList.Size(); j++)
                    {
                        let exInv = player.mo.FindInventory(outList[j]);
                        String exTag = "";
                        if (exInv) exTag = exInv.GetTag();
                        else
                        {
                            readonly<Weapon> exDef = GetDefaultByType(outList[j]);
                            if (exDef) exTag = exDef.GetTag();
                        }
                        if (exTag.Length() > 0 && exTag == wcTag) { tagDup = true; break; }
                    }
                    if (tagDup) continue;
                }
            }

            // BD dual-variant dedup, drop single if Dual counterpart already added
            // heuristic: class name suffix match vs any "Dual*" in outList
            if (sistersAsOne)
            {
                String wcName = wc.GetClassName();
                bool dualDup = false;
                for (int j = 0; j < outList.Size(); j++)
                {
                    String exName = outList[j].GetClassName();
                    if (exName.Length() <= 4) continue;
                    if (exName.Left(4) != "Dual") continue;
                    String suffix = exName.Mid(4);
                    if (IsDualSingleMatch(wcName, suffix)) { dualDup = true; break; }
                }
                if (dualDup) continue;

                // also handle the reverse order, drop earlier-added single if wc is its Dual
                if (wcName.Length() > 4 && wcName.Left(4) == "Dual")
                {
                    String suffix = wcName.Mid(4);
                    for (int j = outList.Size() - 1; j >= 0; j--)
                    {
                        String exName = outList[j].GetClassName();
                        if (exName.Left(4) == "Dual") continue;
                        if (IsDualSingleMatch(exName, suffix)) outList.Delete(j);
                    }
                }
            }

            outList.Push(wc);
        }
    }

    // true if wc appears in any user_slot list other than excludeSlot
    clearscope bool IsClaimedByOtherUserSlot(class<Weapon> wc, int excludeSlot, PlayerInfo player)
    {
        if (!wc || !player) return false;
        for (int s = 0; s <= 9; s++)
        {
            if (s == excludeSlot) continue;
            Array<class<Weapon> > list;
            ReadUserSlot(s, player, list);
            if (list.Find(wc) < list.Size()) return true;
        }
        return false;
    }

    // true if player already owns wc OR a tag/sister/Dual-variant equivalent
    // used by use-key trace to skip prompts when pickup would just absorb ammo
    clearscope bool PlayerOwnsLogicalEquivalent(class<Weapon> wc, Actor pawn)
    {
        if (!wc || !pawn) return false;
        if (pawn.FindInventory(wc)) return true;

        bool sistersAsOne = cachedSistersAsOneCVar
            ? cachedSistersAsOneCVar.GetBool() : true;
        if (!sistersAsOne) return false;

        readonly<Weapon> wcDef = GetDefaultByType(wc);
        String wcTag = wcDef ? wcDef.GetTag() : "";
        String wcName = wc.GetClassName();
        bool wcIsDual = (wcName.Length() > 4 && wcName.Left(4) == "Dual");
        String wcDualSuffix = wcIsDual ? wcName.Mid(4) : "";

        for (let it = pawn.Inv; it != null; it = it.Inv)
        {
            if (!(it is "Weapon")) continue;
            let invW = Weapon(it);
            if (!invW) continue;
            class<Weapon> invClass = (class<Weapon>)(invW.GetClass());

            // tag match
            if (wcTag.Length() > 0 && invW.GetTag() == wcTag) return true;

            // sister chain match, walk wc's class-level chain looking for invClass
            if (wcDef && wcDef.SisterWeaponType)
            {
                class<Weapon> chainClass = wcDef.SisterWeaponType;
                int steps = 0;
                while (chainClass && steps < 8)
                {
                    if (chainClass == invClass) return true;
                    if (chainClass == wc) break;
                    readonly<Weapon> chainDef = GetDefaultByType(chainClass);
                    if (!chainDef || !chainDef.SisterWeaponType) break;
                    chainClass = chainDef.SisterWeaponType;
                    steps++;
                }
            }

            // Dual variant: inv is Dual, wc is its single (or vice versa)
            String invName = invClass.GetClassName();
            bool invIsDual = (invName.Length() > 4 && invName.Left(4) == "Dual");
            if (invIsDual)
            {
                String suffix = invName.Mid(4);
                if (IsDualSingleMatch(wcName, suffix)) return true;
            }
            if (wcIsDual && IsDualSingleMatch(invName, wcDualSuffix)) return true;
        }
        return false;
    }

    // direct Weapon cast, else strip Spawner/Replacer/SpawnerReplacer suffix
    // "@filename" mod-renamed suffix stripped first
    clearscope static class<Weapon> ResolveUnderlyingWeaponClass(Actor act)
    {
        if (!act) return null;
        class<Weapon> direct = (class<Weapon>)(act.GetClass());
        if (direct) return direct;
        if (!(act is "Inventory")) return null;

        String cname = act.GetClass().GetClassName();
        int atIdx = cname.IndexOf("@");
        if (atIdx >= 0) cname = cname.Left(atIdx);

        int len = cname.Length();
        if (len > 15 && cname.Mid(len - 15, 15) == "SpawnerReplacer")
            cname = cname.Left(len - 15);
        else if (len > 8 && cname.Mid(len - 8, 8) == "Replacer")
            cname = cname.Left(len - 8);
        else if (len > 7 && cname.Mid(len - 7, 7) == "Spawner")
            cname = cname.Left(len - 7);
        else
            return null;

        class<Weapon> resolved = cname;
        return resolved;
    }

    // user_slot first, engine fallback, -1 = nowhere
    clearscope int ResolveSlotForClass(PlayerInfo player, class<Weapon> wc)
    {
        if (!wc || !player) return -1;
        for (int s = 0; s <= 9; s++)
        {
            Array<class<Weapon> > list;
            ReadUserSlot(s, player, list);
            if (list.Find(wc) < list.Size()) return s;
        }
        return LocateWeaponSlot(player, wc);
    }

    // ---- Drop with scatter (radial outward velocity) ----

    // floor drop with small radial outward velocity to avoid visual stacking
    // returns true if the engine actually dropped the inv, false for Undroppable / Untossable / Owner mismatch
    bool DropWithScatter(Actor pawn, Inventory inv, int dropIndex, int totalDrops)
    {
        if (!pawn || !inv) return false;
        let dropped = pawn.DropInventory(inv, 1);
        if (!dropped) return false;

        // Radial scatter, evenly spaced around the player
        double angle = (totalDrops > 0) ? (360.0 / totalDrops) * dropIndex : 0;
        double speed = 3.0;
        dropped.vel = (cos(angle) * speed, sin(angle) * speed, 1.0);

        if (IsDebugEnabled())
            Console.Printf("VUWS: Dropped %s at (%.0f, %.0f, %.0f)",
                inv.GetClass().GetClassName(), dropped.pos.x, dropped.pos.y, dropped.pos.z);
        return true;
    }

    // ---- Reconciliation (over-cap detection from grant bypass) ----

    // single inv pass binned by slot, dedup-aware
    private void BuildAllSlotCounts(Actor pawn, out Array<int> counts)
    {
        counts.Clear();
        for (int i = 0; i < 10; i++) counts.Push(0);

        if (!pawn || !pawn.player) return;
        let setup = GetSetup();

        // same dedup as HUD + cap check, drops match what user sees as extra
        for (int slot = 0; slot <= 9; slot++)
        {
            Array<class<Weapon> > effective;
            BuildCurrentSlotEffective(slot, pawn.player, effective);
            if (!setup)
            {
                counts[slot] = effective.Size();
                continue;
            }
            int c = 0;
            for (int j = 0; j < effective.Size(); j++)
            {
                let w = Weapon(pawn.FindInventory(effective[j]));
                if (w && setup.IsCountedAsSlotOccupant(w)) c++;
            }
            counts[slot] = c;
        }
    }

    void ReconcilePlayer(int pnum)
    {
        if (pnum < 0 || pnum >= MAXPLAYERS) return;
        if (!playeringame[pnum] || !players[pnum].mo) return;
        if (spawnGracePending[pnum] || firstLoadGrace) return;

        let pawn = players[pnum].mo;

        Array<int> counts;
        BuildAllSlotCounts(pawn, counts);

        for (int slot = 0; slot <= 9; slot++)
        {
            int cap = GetSlotCap(slot, players[pnum]);
            int count = counts[slot];
            if (count <= cap) continue;

            // recount each iter: dropping a sister-paired primary promotes the secondary
            // local count-- would underestimate by 1
            int totalToScatter = count - cap;
            int dropped = 0;
            int safety = 32; // pathological loop guard
            while (count > cap && safety > 0)
            {
                safety--;
                let setup = GetSetup();
                class<Weapon> bumpClass = setup
                    ? setup.ChooseBumpVictim(slot, players[pnum])
                    : DefaultChooseBumpVictim(slot, players[pnum]);
                if (!bumpClass) break;

                let bumpInv = pawn.FindInventory(bumpClass);
                if (!bumpInv) break;

                // engine refuses Undroppable / Untossable, break before firing OnWeaponDropped
                // accepts over-cap state instead of spinning 32 phantom callbacks per slot
                bool ok = DropWithScatter(pawn, bumpInv, dropped, totalToScatter);
                if (!ok)
                {
                    if (IsDebugEnabled())
                        Console.Printf("VUWS: %s undroppable, slot %d stays %d/%d",
                            bumpInv.GetClass().GetClassName(), slot, count, cap);
                    break;
                }

                if (IsDebugEnabled())
                    Console.Printf("VUWS: Dropped %s from slot %d at (%.0f, %.0f, %.0f) (over cap, %d/%d)",
                        bumpInv.GetTag(), slot, pawn.pos.x, pawn.pos.y, pawn.pos.z, count, cap);

                if (setup) setup.OnWeaponDropped(players[pnum], Weapon(bumpInv), slot, VUWS_DROP_RECONCILE);
                dropped++;
                count = CountSlotOccupants(pawn, slot);
            }
        }
    }

    // ---- Use-key trace ----

    // hits the actor under the player's aim, accepts Weapon and spawner-wrapped Inventory
    private Actor TraceForWeapon(Actor pawn, double range)
    {
        FLineTraceData ltd;
        double offsetZ = pawn.player.viewz - pawn.pos.z;
        bool hit = pawn.LineTrace(pawn.angle, range, pawn.pitch, TRF_ALLACTORS, offsetZ, 0, 0, ltd);
        if (!hit || !ltd.HitActor) return null;
        if (ResolveUnderlyingWeaponClass(ltd.HitActor) == null) return null;
        return ltd.HitActor;
    }

    // replicate Inventory.Touch ceremony, CallTryPickup alone skips sound/message/flash
    private bool TryPickupOne(Actor pawn, Inventory inv)
    {
        if (!inv || inv.Owner) return false;
        bool localview = pawn.CheckLocalView();
        Actor newToucher;
        bool ok;
        [ok, newToucher] = inv.CallTryPickup(pawn);
        if (!ok) return false;
        if (!inv.bQuiet)
        {
            Inventory.PrintPickupMessage(localview, inv.PickupMessage());
            if (pawn.player)
            {
                inv.PlayPickupSound(pawn);
                if (!inv.bNoScreenFlash && pawn.player.playerstate != PST_DEAD)
                    pawn.player.bonuscount = 6;  // BONUSADD per engine
            }
        }
        return true;
    }

    // mirror engine PIT_CheckThing, BD twins share XY each restricted to a player class
    // iterate co-located bSpecial Inventory actors, first success wins
    private bool TryPickupTwinsAt(Actor pawn, Actor anchor)
    {
        if (!pawn || !anchor) return false;
        if (TryPickupOne(pawn, Inventory(anchor))) return true;
        let it = BlockThingsIterator.Create(anchor, 64);
        while (it.Next())
        {
            let act = it.thing;
            if (!act || act == anchor) continue;
            // restrict to actors physically co-located with the trace hit, BD twins share XY
            double dx = act.pos.x - anchor.pos.x;
            double dy = act.pos.y - anchor.pos.y;
            if (dx * dx + dy * dy > 32 * 32) continue;
            if (TryPickupOne(pawn, Inventory(act))) return true;
        }
        return false;
    }

    // Proximity scan: closest pickupable Weapon within `range` units (3D)
    private Actor ProximityScanForWeapon(Actor pawn, double range)
    {
        Actor closest = null;
        double closestDist2 = range * range;
        let it = BlockThingsIterator.Create(pawn, range);
        while (it.Next())
        {
            let act = it.thing;
            if (!act) continue;
            if (ResolveUnderlyingWeaponClass(act) == null) continue;
            let inv = Inventory(act);
            if (!inv || inv.Owner) continue;
            double dx = act.pos.x - pawn.pos.x;
            double dy = act.pos.y - pawn.pos.y;
            double dz = act.pos.z - pawn.pos.z;
            double d2 = dx*dx + dy*dy + dz*dz;
            if (d2 < closestDist2) { closestDist2 = d2; closest = act; }
        }
        return closest;
    }

    void RunUseKeyTraceForPlayer(int pnum, bool force = false)
    {
        if (pnum < 0 || pnum >= MAXPLAYERS) return;
        if (!playeringame[pnum] || !players[pnum].mo) return;
        let pawn = players[pnum].mo;

        // throttle to every Nth tic, USE press-edge forces a re-trace to dodge stale eligibility
        int interval = cachedTraceIntervalCVar ? cachedTraceIntervalCVar.GetInt() : 3;
        if (interval < 1) interval = 1;
        if (!force)
        {
            useTraceCounter[pnum]++;
            if (useTraceCounter[pnum] < interval) return;
        }
        useTraceCounter[pnum] = 0;

        // Reset eligibility before re-evaluating
        useEligibleWeapon[pnum] = null;
        useEligibleClass[pnum] = null;
        useEligibleAtCap[pnum] = false;
        useEligibleUseKey[pnum] = false;

        // Prompt only matters when block_action is "use-key required at cap"
        int blockAction = cachedBlockActionCVar ? cachedBlockActionCVar.GetInt() : 2;
        if (blockAction != 2) return;

        double range = cachedUsePickupRangeCVar
            ? cachedUsePickupRangeCVar.GetFloat() : 96.0;

        // 0=trace, 1=proximity, 2=auto (trace first, fall back to proximity if no hit)
        // freelook readout removed since it's CVAR_GLOBALCONFIG (per-machine, would desync coop)
        int mode = cachedPickupDetectionCVar ? cachedPickupDetectionCVar.GetInt() : 2;
        bool useTrace = (mode != 1);

        Actor target = useTrace ? TraceForWeapon(pawn, range) : ProximityScanForWeapon(pawn, range);

        // auto-mode fallback: trace can miss in cluttered rooms (LineTrace stops at first actor)
        if (!target && mode == 2)
            target = ProximityScanForWeapon(pawn, range);

        if (!target)
        {
            // if (IsDebugEnabled()) Console.Printf("VUWS trace: no target");
            return;
        }

        class<Weapon> wc = ResolveUnderlyingWeaponClass(target);
        if (!wc) return;
        // String wname = wc.GetClassName();  // debug only

        if (IsClassExcluded(wc))
        {
            // if (IsDebugEnabled()) Console.Printf("VUWS trace: %s excluded", wname);
            return;
        }
        let setup = GetSetup();
        // ShouldOfferUseKeyPickup needs a Weapon instance, skip the hook for spawners
        let weapInst = Weapon(target);
        if (setup && weapInst && !setup.ShouldOfferUseKeyPickup(weapInst))
        {
            // if (IsDebugEnabled()) Console.Printf("VUWS trace: %s Setup.ShouldOfferUseKeyPickup=false", wname);
            return;
        }

        if (PlayerOwnsLogicalEquivalent(wc, pawn))
        {
            // if (IsDebugEnabled()) Console.Printf("VUWS trace: %s PlayerOwnsLogicalEquivalent=true", wname);
            return;
        }

        int slot = ResolveSlotForClass(players[pnum], wc);
        if (slot < 0)
        {
            // if (IsDebugEnabled()) Console.Printf("VUWS trace: %s no slot", wname);
            return;
        }

        int cap = GetSlotCap(slot, players[pnum]);
        int count = CountSlotOccupants(pawn, slot);

        if (count < cap)
        {
            // if (IsDebugEnabled()) Console.Printf("VUWS trace: %s slot=%d count=%d cap=%d below-cap", wname, slot, count, cap);
            return;
        }

        class<Weapon> bumpVictim = setup
            ? setup.ChooseBumpVictim(slot, players[pnum])
            : DefaultChooseBumpVictim(slot, players[pnum]);
        if (!bumpVictim)
        {
            // if (IsDebugEnabled()) Console.Printf("VUWS trace: %s slot=%d at-cap but bump victim null", wname, slot);
            return;
        }

        // if (IsDebugEnabled()) Console.Printf("VUWS trace: %s slot=%d at-cap, bump=%s, prompt SET", wname, slot, bumpVictim.GetClassName());

        useEligibleWeapon[pnum] = target;
        useEligibleClass[pnum] = wc;
        useEligibleSlot[pnum] = slot;
        useEligibleAtCap[pnum] = true;
        useEligibleUseKey[pnum] = true;
        useEligibleBumpVictim[pnum] = bumpVictim;
    }

    // ---- API entry points ----

    bool IsAtCap(PlayerInfo player, int slot)
    {
        if (!player || !player.mo) return false;
        if (slot < 0 || slot > 9) return false;
        int cap = GetSlotCap(slot, player);
        int count = CountSlotOccupants(player.mo, slot);
        return count >= cap;
    }

    // ---- Token grant ----

    static void GrantTokenIfMissing(PlayerPawn pawn)
    {
        if (!pawn) return;
        if (pawn.FindInventory("VUWS_LimitToken")) return;
        pawn.GiveInventory("VUWS_LimitToken", 1);

        if (IsDebugEnabled())
            Console.Printf("VUWS: Granted LimitToken to player %d", pawn.PlayerNumber());
    }

    // ---- Toast helpers (called from sentinel) ----

    void LogBlockedToast(Weapon w, int slot)
    {
        let e = new("VUWS_NotifyEntry");
        e.kind = VUWS_TOAST_BLOCKED;
        e.weaponClass = w.GetClass();
        e.bumpedClass = null;
        e.slot = slot;
        e.expireTic = level.time + (cachedNotifyDurationCVar
            ? cachedNotifyDurationCVar.GetInt() : 70);
        pendingToasts.Push(e);
    }

    void LogToast(Weapon w, int slot, class<Weapon> bumpedClass)
    {
        let e = new("VUWS_NotifyEntry");
        e.kind = (bumpedClass != null) ? VUWS_TOAST_SWAPPED : VUWS_TOAST_BLOCKED;
        e.weaponClass = w.GetClass();
        e.bumpedClass = bumpedClass;
        e.slot = slot;
        e.expireTic = level.time + (cachedNotifyDurationCVar
            ? cachedNotifyDurationCVar.GetInt() : 70);
        pendingToasts.Push(e);
    }

    // ---- EventHandler hooks ----

    override void WorldLoaded(WorldEvent e)
    {
        // Setup.WorldLoaded (SetOrder 5) writes the authoritative value
        // virtual IsCompatible() only dispatches to subclasses from Setup itself
        suspendedByCompat = false;

        // first-load grace only fires for pre-VUWS saves (no LimitToken in restored inventory)
        // check BEFORE the grant loop below since PlayerSpawned doesn't fire on save loads
        // VUWS-created saves had the token so the restored inv already contains it
        // cleared on next map transition
        bool consoleHadToken = false;
        if (e.IsSaveGame
            && consoleplayer >= 0 && consoleplayer < MAXPLAYERS
            && playeringame[consoleplayer] && players[consoleplayer].mo)
        {
            consoleHadToken = (players[consoleplayer].mo.FindInventory("VUWS_LimitToken") != null);
        }
        firstLoadGrace = e.IsSaveGame && !consoleHadToken;

        // Reset transient state for all players
        for (int p = 0; p < MAXPLAYERS; p++)
        {
            spawnGracePending[p] = false;
            forceAcceptForPlayer[p] = false;
            useEligibleWeapon[p] = null;
            useEligibleClass[p] = null;
            useEligibleSlot[p] = -1;
            useEligibleBumpVictim[p] = null;
            useEligibleAtCap[p] = false;
            useEligibleUseKey[p] = false;
            useTraceCounter[p] = 0;
            prevUseHeld[p] = false;
            pendingSlotKey[p] = -1;
            pendingScrollAccum[p] = 0;
            diedRecently[p] = false;

            if (playeringame[p] && players[p].mo)
            {
                GrantTokenIfMissing(players[p].mo);
                // No replay needed: override mechanism reads vuws_user_slot_* directly per tic
            }
        }

        // PlayerSpawned and PlayerEntered both skip on save load (engine g_level.cpp:1496-1499)
        // so restore the local player's slot mapping from CVars here, then sync to peers
        if (e.IsSaveGame
            && consoleplayer >= 0 && consoleplayer < MAXPLAYERS
            && playeringame[consoleplayer] && players[consoleplayer].mo)
        {
            RestoreLocalSlotsToMemory(consoleplayer);
            BroadcastFullSlotConfig(consoleplayer);
        }

        pendingToasts.Clear();

        // queue auto-show for the next consoleplayer PlayerSpawned, skip save loads
        if (!e.IsSaveGame) pendingAutoShowOnSpawn = true;

        if (IsDebugEnabled())
            Console.Printf("VUWS: WorldLoaded suspendedByCompat=%d firstLoadGrace=%d",
                suspendedByCompat ? 1 : 0, firstLoadGrace ? 1 : 0);
    }

    override void PlayerEntered(PlayerEvent e)
    {
        // re-broadcast self on any entry so mid-session joiners see existing players
        // restore inline since PlayerEntered may fire before PlayerSpawned on map load
        if (consoleplayer < 0 || consoleplayer >= MAXPLAYERS) return;
        if (!playeringame[consoleplayer]) return;
        if (!players[consoleplayer].mo) return;
        RestoreLocalSlotsToMemory(consoleplayer);
        BroadcastFullSlotConfig(consoleplayer);
    }

    override void PlayerSpawned(PlayerEvent e)
    {
        if (e.PlayerNumber < 0 || e.PlayerNumber >= MAXPLAYERS) return;
        if (!players[e.PlayerNumber].mo) return;
        GrantTokenIfMissing(players[e.PlayerNumber].mo);

        // clear per-player transient state, int 0 is a valid slot so phantom-press 0 must be avoided
        spawnGracePending[e.PlayerNumber] = true;
        forceAcceptForPlayer[e.PlayerNumber] = false;
        useEligibleWeapon[e.PlayerNumber] = null;
        useEligibleClass[e.PlayerNumber] = null;
        useEligibleSlot[e.PlayerNumber] = -1;
        useEligibleBumpVictim[e.PlayerNumber] = null;
        useEligibleAtCap[e.PlayerNumber] = false;
        useEligibleUseKey[e.PlayerNumber] = false;
        useTraceCounter[e.PlayerNumber] = 0;
        prevUseHeld[e.PlayerNumber] = false;
        pendingSlotKey[e.PlayerNumber] = -1;
        pendingScrollAccum[e.PlayerNumber] = 0;

        // covers fresh start, save load, mid-session join (PlayerEntered handles peers)
        if (e.PlayerNumber == consoleplayer)
        {
            RestoreLocalSlotsToMemory(e.PlayerNumber);
            BroadcastFullSlotConfig(e.PlayerNumber);
            // signal WorldTick consumer, can't consume here since WorldLoaded queues AFTER us
            consolePlayerSpawnedThisTic = true;
        }
    }

    override void PlayerRespawned(PlayerEvent e)
    {
        if (e.PlayerNumber < 0 || e.PlayerNumber >= MAXPLAYERS) return;
        if (!players[e.PlayerNumber].mo) return;
        GrantTokenIfMissing(players[e.PlayerNumber].mo);

        spawnGracePending[e.PlayerNumber] = true;
        forceAcceptForPlayer[e.PlayerNumber] = false;
        useEligibleWeapon[e.PlayerNumber] = null;
        useEligibleClass[e.PlayerNumber] = null;
        useEligibleSlot[e.PlayerNumber] = -1;
        useEligibleBumpVictim[e.PlayerNumber] = null;
        useEligibleAtCap[e.PlayerNumber] = false;
        useEligibleUseKey[e.PlayerNumber] = false;
        useTraceCounter[e.PlayerNumber] = 0;
        prevUseHeld[e.PlayerNumber] = false;
        pendingSlotKey[e.PlayerNumber] = -1;
        pendingScrollAccum[e.PlayerNumber] = 0;

        // PST_REBORN path, clear diedRecently to skip the PlayerSpawned death-menu re-fire
        if (e.PlayerNumber == consoleplayer)
        {
            diedRecently[consoleplayer] = false;
            if (GetCVarBool('vuws_auto_show_on_death', players[consoleplayer]))
            {
                EventHandler.SendInterfaceEvent(consoleplayer, "vuws_open_slot_editor");
                if (IsDebugEnabled()) Console.Printf("VUWS: auto-show fired (death, coop respawn)");
            }
        }
    }

    override void PlayerDied(PlayerEvent e)
    {
        if (e.PlayerNumber < 0 || e.PlayerNumber >= MAXPLAYERS) return;
        // Clear all use-key + slot-key state so nothing lingers across the death screen
        useEligibleWeapon[e.PlayerNumber] = null;
        useEligibleClass[e.PlayerNumber] = null;
        useEligibleSlot[e.PlayerNumber] = -1;
        useEligibleBumpVictim[e.PlayerNumber] = null;
        useEligibleAtCap[e.PlayerNumber] = false;
        useEligibleUseKey[e.PlayerNumber] = false;
        pendingSlotKey[e.PlayerNumber] = -1;
        pendingScrollAccum[e.PlayerNumber] = 0;

        // SP death routes via PST_ENTER -> PlayerSpawned (not PlayerRespawned)
        // flag lets the WorldTick consumer pick death CVar over map-change
        diedRecently[e.PlayerNumber] = true;
        if (IsDebugEnabled() && e.PlayerNumber == consoleplayer)
            Console.Printf("VUWS: PlayerDied -> diedRecently set for player %d", e.PlayerNumber);
    }

    override void WorldTick()
    {
        // Master toggle off: skip all per-tic logic
        if (cachedEnabledCVar && !cachedEnabledCVar.GetBool()) return;
        if (suspendedByCompat) return;

        // Keep parsed exclude list in sync (cheap diff check)
        RefreshExcludeListIfChanged();

        // auto-show consumer fires the tic after a PlayerSpawned (WorldLoaded queue is set by then)
        // flag-gate avoids firing during the death screen where no PlayerSpawned has happened
        if (consolePlayerSpawnedThisTic
            && consoleplayer >= 0 && consoleplayer < MAXPLAYERS
            && playeringame[consoleplayer] && players[consoleplayer].mo)
        {
            consolePlayerSpawnedThisTic = false;
            bool fire = false;
            String reason = "";
            if (diedRecently[consoleplayer])
            {
                diedRecently[consoleplayer] = false;
                pendingAutoShowOnSpawn = false;
                if (GetCVarBool('vuws_auto_show_on_death', players[consoleplayer]))
                {
                    fire = true;
                    reason = "death";
                }
            }
            else if (pendingAutoShowOnSpawn)
            {
                pendingAutoShowOnSpawn = false;
                bool firstMap = GetCVarBool('vuws_auto_show_on_first_map', players[consoleplayer]);
                bool mapChange = GetCVarBool('vuws_auto_show_on_map_change', players[consoleplayer]);
                if (firstMap && !autoShowFiredThisSession)
                {
                    fire = true;
                    autoShowFiredThisSession = true;
                    reason = "first-map";
                }
                else if (mapChange)
                {
                    fire = true;
                    reason = "map-change";
                }
            }
            if (fire)
            {
                EventHandler.SendInterfaceEvent(consoleplayer, "vuws_open_slot_editor");
                if (IsDebugEnabled()) Console.Printf("VUWS: auto-show fired (%s)", reason);
            }
            else if (IsDebugEnabled())
            {
                Console.Printf("VUWS: auto-show no-fire (died=%d pending=%d firstFired=%d)",
                    diedRecently[consoleplayer] ? 1 : 0,
                    pendingAutoShowOnSpawn ? 1 : 0,
                    autoShowFiredThisSession ? 1 : 0);
            }
        }

        // Prune expired toasts so the renderer (UI scope) doesn't have to mutate this array
        for (int i = pendingToasts.Size() - 1; i >= 0; i--)
        {
            if (pendingToasts[i].expireTic <= level.time)
                pendingToasts.Delete(i);
        }

        // Track ReadyWeapon switch for Slot HUD on-switch fade
        if (consoleplayer >= 0 && consoleplayer < MAXPLAYERS
            && playeringame[consoleplayer] && players[consoleplayer].mo)
        {
            let rw = players[consoleplayer].ReadyWeapon;
            class<Weapon> nowReady = rw ? rw.GetClass() : null;
            if (nowReady != lastReadyWeaponSeen)
            {
                lastWeaponSwitchTic = gametic;
                lastReadyWeaponSeen = nowReady;
            }
        }

        bool enforceOnGrant = cachedEnforceOnGrantCVar
            ? cachedEnforceOnGrantCVar.GetBool() : true;

        for (int p = 0; p < MAXPLAYERS; p++)
        {
            if (!playeringame[p]) continue;
            if (!players[p].mo) continue;

            // Spawn grace clears one tic after PlayerSpawned so reconciliation can run normally next
            if (spawnGracePending[p])
            {
                spawnGracePending[p] = false;
                continue;
            }

            // Reconciliation pass for grant-bypass detection
            if (enforceOnGrant)
                ReconcilePlayer(p);

            // Use-key trace + edge detection
            RunUseKeyTraceForPlayer(p);

            bool useHeld = (players[p].cmd.buttons & BT_USE) != 0;
            bool justPressed = useHeld && !prevUseHeld[p];
            prevUseHeld[p] = useHeld;

            if (justPressed)
            {
                // re-trace at press tic, stale cache could pickup something the player pivoted off of
                RunUseKeyTraceForPlayer(p, true);

                if (useEligibleWeapon[p] && useEligibleUseKey[p])
                {
                    // pre-bump at cap so reconcile doesn't drop the new weapon
                    // null bump victim = abort, force-accept here would push +1 over cap
                    // Undroppable bump victim = abort too, no point picking up if we can't free the slot
                    bool bumpOk = false;
                    if (useEligibleBumpVictim[p])
                    {
                        let bumpInv = players[p].mo.FindInventory(useEligibleBumpVictim[p]);
                        if (bumpInv && DropWithScatter(players[p].mo, bumpInv, 0, 1))
                        {
                            let setup = GetSetup();
                            if (setup) setup.OnWeaponDropped(players[p], Weapon(bumpInv), useEligibleSlot[p], VUWS_DROP_USE_KEY);
                            bumpOk = true;
                        }
                    }

                    if (bumpOk)
                    {
                        // mirror engine PIT_CheckThing iterator, see TryPickupTwinsAt for the why
                        Actor target = useEligibleWeapon[p];
                        forceAcceptForPlayer[p] = true;
                        if (target)
                            TryPickupTwinsAt(players[p].mo, target);
                        forceAcceptForPlayer[p] = false;
                    }
                    else if (IsDebugEnabled())
                    {
                        Console.Printf("VUWS: use-key pickup aborted (no valid bump victim)");
                    }

                    useEligibleWeapon[p] = null;
                    useEligibleClass[p] = null;
                    useEligibleAtCap[p] = false;
                    useEligibleUseKey[p] = false;
                    useEligibleBumpVictim[p] = null;
                }
            }

            // Slot key handling deferred from netevent to WorldTick, see ProcessPendingSlotKey
            if (pendingSlotKey[p] >= 0)
            {
                ProcessPendingSlotKey(p);
                pendingSlotKey[p] = -1;
            }

            // Scroll cycle accumulator
            if (pendingScrollAccum[p] != 0)
            {
                ProcessPendingScroll(p, pendingScrollAccum[p]);
                pendingScrollAccum[p] = 0;
            }
        }
    }

    // Cycle owned weapons in slot order 1..9,0 using BuildCurrentSlotEffective per slot
    // delta positive = forward, negative = backward, wraps at both ends
    void ProcessPendingScroll(int pnum, int delta)
    {
        if (suspendedByCompat) return;
        if (delta == 0) return;
        let pi = players[pnum];
        if (!pi.mo) return;

        Array<Weapon> flat;
        // walk slots 1..9 then 0 (engine cycle order, slot 0 last)
        for (int i = 0; i < 10; i++)
        {
            int slot = (i < 9) ? (i + 1) : 0;
            Array<class<Weapon> > effective;
            BuildCurrentSlotEffective(slot, pi, effective);
            for (int j = 0; j < effective.Size(); j++)
            {
                let weap = Weapon(pi.mo.FindInventory(effective[j]));
                if (weap) flat.Push(weap);
            }
        }

        int n = flat.Size();
        if (n == 0) return;

        // WP_NOCHANGE is a sentinel DObject not null, deref crashes (d_player.h:153)
        Weapon ref = pi.ReadyWeapon;
        if (pi.PendingWeapon && pi.PendingWeapon != WP_NOCHANGE)
            ref = pi.PendingWeapon;
        int curIdx = -1;
        for (int k = 0; k < n; k++)
        {
            if (flat[k] == ref) { curIdx = k; break; }
            if (ref && flat[k].SisterWeapon == ref) { curIdx = k; break; }
            if (ref && ref.SisterWeapon == flat[k]) { curIdx = k; break; }
        }

        int newIdx;
        if (curIdx < 0)
        {
            newIdx = (delta > 0) ? 0 : n - 1;
        }
        else
        {
            newIdx = ((curIdx + delta) % n + n) % n;
        }

        flat[newIdx].Use(false);
        if (IsDebugEnabled())
            Console.Printf("VUWS: scroll %s%d -> %s",
                delta > 0 ? "+" : "", delta, flat[newIdx].GetClass().GetClassName());
    }

    void ProcessPendingSlotKey(int pnum)
    {
        if (suspendedByCompat) return;

        let pi = players[pnum];
        if (!pi.mo) return;
        int slot = pendingSlotKey[pnum];

        // user-assigned weapon for this slot wins
        class<Weapon> userPick = ResolveUserSlotPick(slot, pi);
        if (userPick)
        {
            let userInv = Weapon(pi.mo.FindInventory(userPick));
            if (userInv) userInv.Use(false);
            if (IsDebugEnabled())
                Console.Printf("VUWS: slot %d -> %s (user assignment)",
                    slot, userPick.GetClassName());
            return;
        }

        // no user pick, defer to engine PickWeapon for this slot
        Weapon enginePick = pi.mo.PickWeapon(slot, true);
        if (!enginePick)
        {
            if (IsDebugEnabled())
                Console.Printf("VUWS: slot %d - engine had nothing", slot);
            return;
        }

        class<Weapon> engineClass = enginePick.GetClass();
        if (IsClassExcluded(engineClass))
        {
            // User has this class on the exclude list, never select via fallback
            if (IsDebugEnabled())
                Console.Printf("VUWS: slot %d engine pick %s suppressed (excluded)",
                    slot, engineClass.GetClassName());
            return;
        }
        if (IsClaimedByOtherUserSlot(engineClass, slot, pi))
        {
            // Engine's pick belongs to a different user slot, suppress (no switch, no animation)
            if (IsDebugEnabled())
                Console.Printf("VUWS: slot %d engine pick %s suppressed (claimed elsewhere)",
                    slot, engineClass.GetClassName());
            return;
        }

        // Engine's pick is fair game (vanilla behavior for unassigned slots)
        enginePick.Use(false);
        if (IsDebugEnabled())
            Console.Printf("VUWS: slot %d -> %s (engine fallback)", slot, engineClass.GetClassName());
    }

    override void NetworkCommandProcess(NetworkCommand cmd)
    {
        // 10-slot config sync from PlayerEntered/PlayerSpawned broadcast
        if (cmd.Command == 'vuws_slot_full_sync')
        {
            int pnum = cmd.ReadInt8();
            if (pnum < 0 || pnum >= MAXPLAYERS) return;
            Array<String> slots;
            cmd.ReadStringArray(slots);
            int n = slots.Size();
            if (n > 10) n = 10;
            for (int slot = 0; slot < n; slot++)
                memoryUserSlots[pnum * 10 + slot] = slots[slot];

            if (IsDebugEnabled())
                Console.Printf("VUWS: full-slot-config sync received for player %d", pnum);
            return;
        }
    }

    override void NetworkProcess(ConsoleEvent e)
    {
        // bounds-check once: every netevent below is per-player, OOB = UB
        if (e.Player < 0 || e.Player >= MAXPLAYERS) return;

        // Slot key intercept: fired by KEYCONF alias `vuws_slotk_N` -> `netevent vuws_slot_key N`
        // No engine `slot N` chain so we own the switch entirely
        if (e.Name ~== "vuws_slot_key")
        {
            int slot = e.Args[0];
            if (slot < 0 || slot > 9) return;

            // defer to WorldTick, no engine PendingWeapon to suppress (KEYCONF skips `slot N`)
            pendingSlotKey[e.Player] = slot;
            return;
        }

        // Scroll intercept: KEYCONF aliases vuws_weapnext / vuws_weapprev replace engine weapnext / weapprev
        // accumulator coalesces rapid wheel ticks into one cycle per WorldTick
        if (e.Name ~== "vuws_weapnext")
        {
            pendingScrollAccum[e.Player] += 1;
            return;
        }
        if (e.Name ~== "vuws_weapprev")
        {
            pendingScrollAccum[e.Player] -= 1;
            return;
        }

        // menu Add-to-slot, Args[0]=slot Args[1]=index in BuildSlotMenuWeapons
        if (e.Name ~== "vuws_add_to_slot")
        {
            int slot = e.Args[0];
            int weapIdx = e.Args[1];
            if (slot < 0 || slot > 9) return;
            if (!playeringame[e.Player]) return;
            if (!players[e.Player].mo) return;

            Array<class<Weapon> > playList;
            BuildSlotMenuWeapons(players[e.Player].mo, playList);
            if (weapIdx < 0 || weapIdx >= playList.Size()) return;

            class<Weapon> wc = playList[weapIdx];
            if (!wc) return;
            ReassignWeapon(wc, slot, players[e.Player]);
            return;
        }

        if (e.Name ~== "vuws_remove_from_slot")
        {
            int slot = e.Args[0];
            int weapIdx = e.Args[1];
            if (slot < 0 || slot > 9) return;
            if (!playeringame[e.Player]) return;
            if (!players[e.Player].mo) return;

            Array<class<Weapon> > playList;
            BuildSlotMenuWeapons(players[e.Player].mo, playList);
            if (weapIdx < 0 || weapIdx >= playList.Size()) return;

            class<Weapon> wc = playList[weapIdx];
            if (!wc) return;

            // Remove wc from vuws_user_slot_<slot>
            Array<class<Weapon> > current;
            ReadUserSlot(slot, players[e.Player], current);
            int idx = current.Find(wc);
            if (idx < current.Size())
            {
                current.Delete(idx);
                WriteUserSlot(slot, players[e.Player], current);
                if (IsDebugEnabled())
                    Console.Printf("VUWS: Removed %s from slot %d", wc.GetClassName(), slot);
            }
            return;
        }

        if (e.Name ~== "vuws_set_exclude")
        {
            // origin commits the server CVar + applies inline (DEM_SINFCHANGED is one tic late)
            // peers rely on the WorldTick poll, origin needs freshness for the next menu render
            if (e.Player != consoleplayer) return;
            if (!playeringame[e.Player]) return;
            let pending = CVar.GetCVar('vuws_pending_exclude_csv', players[e.Player]);
            if (!pending) return;
            String csv = pending.GetString();
            let target = CVar.GetCVar('vuws_exclude_classes', players[e.Player]);
            if (target) target.SetString(csv);
            pending.SetString("");
            ApplyExcludeCsv(csv);
            return;
        }

        // menu give/drop, Args[1] = index in BuildSlotMenuWeapons
        // GIVE pre-checks cap so reconcile doesn't immediately drop it back
        if (e.Name ~== "vuws_give_weapon")
        {
            int weapIdx = e.Args[1];
            if (!playeringame[e.Player]) return;
            if (!players[e.Player].mo) return;

            Array<class<Weapon> > playList;
            BuildSlotMenuWeapons(players[e.Player].mo, playList);
            if (weapIdx < 0 || weapIdx >= playList.Size()) return;

            class<Weapon> wc = playList[weapIdx];
            if (!wc) return;

            // Already owned - no-op
            if (players[e.Player].mo.FindInventory(wc))
            {
                if (IsDebugEnabled())
                    Console.Printf("VUWS: %s already in inventory", wc.GetClassName());
                return;
            }

            int targetSlot = ResolveSlotForClass(players[e.Player], wc);

            // Cap check (skip for unlimited slot 0 toggle)
            if (targetSlot >= 0)
            {
                int cap = GetSlotCap(targetSlot, players[e.Player]);
                if (cap < 999)
                {
                    int count = CountSlotOccupants(players[e.Player].mo, targetSlot);
                    if (count >= cap)
                    {
                        Console.Printf("Cannot give %s, slot %d at cap (%d/%d)",
                            wc.GetClassName(), targetSlot, count, cap);
                        return;
                    }
                }
            }

            players[e.Player].mo.GiveInventory(wc, 1);
            if (IsDebugEnabled())
                Console.Printf("VUWS: Gave %s", wc.GetClassName());
            return;
        }

        if (e.Name ~== "vuws_drop_weapon")
        {
            int weapIdx = e.Args[1];
            if (!playeringame[e.Player]) return;
            if (!players[e.Player].mo) return;

            Array<class<Weapon> > playList;
            BuildSlotMenuWeapons(players[e.Player].mo, playList);
            if (weapIdx < 0 || weapIdx >= playList.Size()) return;

            class<Weapon> wc = playList[weapIdx];
            if (!wc) return;

            let inv = players[e.Player].mo.FindInventory(wc);
            if (!inv) return;
            players[e.Player].mo.DropInventory(inv, 1);
            if (IsDebugEnabled())
                Console.Printf("VUWS: Dropped %s", wc.GetClassName());
            return;
        }
    }
}

// toast kinds
enum VUWS_ToastKind
{
    VUWS_TOAST_BLOCKED  = 0,
    VUWS_TOAST_SWAPPED  = 1
}

// One-off notification entry queued by handler logic, drained by renderer
// Class not struct since ZScript dynamic arrays only accept integral / reference types
class VUWS_NotifyEntry
{
    int kind;
    class<Weapon> weaponClass;
    class<Weapon> bumpedClass;
    int slot;
    int expireTic;
}
