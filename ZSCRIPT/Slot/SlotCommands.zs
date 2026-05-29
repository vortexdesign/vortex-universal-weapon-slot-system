// SlotCommands.zs
// Console command dispatcher for VUWS
// KEYCONF aliases fire netevents and this handler interprets them

class VUWS_SlotCommands : StaticEventHandler
{
    override void OnRegister()
    {
        SetOrder(5);
    }

    override void NetworkProcess(ConsoleEvent e)
    {
        if (e.Name ~== "vuws_help")
        {
            if (e.Player != consoleplayer) return;
            Console.Printf("\c[Gold]=== VUWS Weapon Slot System Commands ===\c-");
            Console.Printf("vuws_help              - Show this help text");
            Console.Printf("vuws_status            - Show cap state for your player");
            Console.Printf("vuws_list              - List all slot occupants for your player");
            Console.Printf("vuws_clear_user_slots  - Clear all user slot reassignments");
            Console.Printf("vuws_clear_user_slot_N - Clear one slot N (0-9)");
            Console.Printf("vuws_reset_defaults    - Reset all settings to defaults");
            Console.Printf("vuws_slot_editor      - Open the slot editor");
            Console.Printf("vuws_exclude_menu      - Open the exclude list");
            Console.Printf("vuws_export_config    - Print your slot configuration for sharing");
            Console.Printf("vuws_import_config    - Apply a slot configuration from vuws_pending_slot_config_csv");
            Console.Printf("vuws_bind_slot_keys    - One-shot rebind 0-9 to VUWS-aware slot keys");
            Console.Printf("vuws_unbind_slot_keys  - Revert 0-9 to engine slot keys");
            Console.Printf("vuws_bind_scroll_keys  - One-shot rebind mwheel to VUWS-aware weapon cycle");
            Console.Printf("vuws_unbind_scroll_keys - Revert mwheel to engine weapnext / weapprev");
            Console.Printf("vuws_gearbox_resync    - Force-flush Gearbox bridge (no-op without VUWS_Gearbox.pk3)");
            Console.Printf("");
            Console.Printf("\c[DarkGray]Default bind: Q opens the slot editor (if Q is unbound)");
            Console.Printf("Rebind in Options > Customize Controls > Universal Weapon Slot System\c-");
            return;
        }

        if (e.Name ~== "vuws_status")
        {
            if (e.Player != consoleplayer) return;
            int pnum = e.Player;
            if (pnum < 0 || pnum >= MAXPLAYERS || !playeringame[pnum])
            {
                Console.Printf("VUWS: No player for this event");
                return;
            }

            let handler = VUWS_SlotHandler.GetHandler();
            if (!handler)
            {
                Console.Printf("VUWS: Handler not available");
                return;
            }

            bool enabled = VUWS_SlotHandler.GetCVarBool('vuws_enabled', players[pnum], true);
            int blockAction = VUWS_SlotHandler.GetCVarInt('vuws_block_action', players[pnum], 2);
            int defaultCap = VUWS_SlotHandler.GetCVarInt('vuws_cap_default', players[pnum], 3);

            Console.Printf("\c[Gold]--- VUWS Status (player %d) ---\c-", pnum);
            Console.Printf("  Library enabled:    %s", enabled ? "yes" : "no");
            Console.Printf("  Suspended by mod:   %s", handler.suspendedByCompat ? "yes" : "no");
            String actionStr = "silent reject";
            if (blockAction == 1) actionStr = "auto-swap (LRU)";
            else if (blockAction == 2) actionStr = "use-key required";
            Console.Printf("  At-cap action:      %s", actionStr);
            Console.Printf("  Default cap:        %d", defaultCap);
            return;
        }

        if (e.Name ~== "vuws_list")
        {
            if (e.Player != consoleplayer) return;
            int pnum = e.Player;
            if (pnum < 0 || pnum >= MAXPLAYERS || !playeringame[pnum] || !players[pnum].mo)
            {
                Console.Printf("VUWS: No player for this event");
                return;
            }

            let handler = VUWS_SlotHandler.GetHandler();
            if (!handler) return;

            Console.Printf("\c[Gold]--- VUWS Slot Occupants (player %d) ---\c-", pnum);
            for (int slot = 0; slot <= 9; slot++)
            {
                int cap = VUWS_SlotHandler.GetSlotCap(slot, players[pnum]);
                int count = handler.CountSlotOccupants(players[pnum].mo, slot);

                // effective view so listed weapons match the count
                Array<class<Weapon> > effective;
                handler.BuildCurrentSlotEffective(slot, players[pnum], effective);
                if (effective.Size() == 0) continue;

                String classes = "";
                for (int i = 0; i < effective.Size(); i++)
                {
                    class<Weapon> wc = effective[i];
                    if (!wc) continue;
                    if (i > 0) classes.AppendFormat(", ");
                    classes.AppendFormat("%s*", wc.GetClassName());
                }
                Console.Printf("  Slot %d (%d/%d): %s", slot, count, cap, classes);
            }
            Console.Printf("\c[DarkGray]  * = currently in inventory\c-");
            return;
        }

        if (e.Name ~== "vuws_clear_user_slots")
        {
            // no consoleplayer gate so memory clears on every client, WriteUserSlot self-gates CVar
            if (!playeringame[e.Player]) return;
            let handler = VUWS_SlotHandler.GetHandler();
            if (!handler) return;
            Array<class<Weapon> > emptyList;
            for (int slot = 0; slot <= 9; slot++)
                handler.WriteUserSlot(slot, players[e.Player], emptyList);

            if (e.Player == consoleplayer)
                Console.Printf("VUWS: Cleared user slot assignments. Run vuws_gearbox_resync if using the Gearbox bridge.");
            return;
        }

        if (e.Name ~== "vuws_clear_user_slot")
        {
            if (!playeringame[e.Player]) return;
            int slot = e.Args[0];
            if (slot < 0 || slot > 9) return;
            let handler = VUWS_SlotHandler.GetHandler();
            if (!handler) return;
            Array<class<Weapon> > emptyList;
            handler.WriteUserSlot(slot, players[e.Player], emptyList);

            if (e.Player == consoleplayer)
                Console.Printf("VUWS: Cleared slot %d. Run vuws_gearbox_resync if using the Gearbox bridge.", slot);
            return;
        }

        if (e.Name ~== "vuws_export_config")
        {
            if (e.Player != consoleplayer) return;
            // Pipe-delimited compact form: each slot's user_slot_N CVar value, in order 0-9
            String compact = "";
            Console.Printf("\c[Gold]--- VUWS Slot Configuration Export ---\c-");
            Console.Printf("\c[DarkGray]Here's your current setup:\c-");
            for (int slot = 0; slot <= 9; slot++)
            {
                String cvName = String.Format("vuws_user_slot_%d", slot);
                let cv = CVar.GetCVar(cvName, players[consoleplayer]);
                String val = cv ? cv.GetString() : "";
                Console.Printf("set %s \"%s\"", cvName, val);
                if (slot > 0) compact = compact .. "|";
                compact = compact .. val;
            }
            Console.Printf("");
            Console.Printf("\c[DarkGray]Paste these two lines one at a time into another player's console to share:\c-");
            Console.Printf("set vuws_pending_slot_config_csv \"%s\"", compact);
            Console.Printf("vuws_import_config");
            return;
        }

        if (e.Name ~== "vuws_import_config")
        {
            // staging CVar is machine-local so origin-only, broadcast after to sync peers
            if (e.Player != consoleplayer) return;
            let pendingCV = CVar.GetCVar('vuws_pending_slot_config_csv', players[consoleplayer]);
            String csv = pendingCV ? pendingCV.GetString() : "";
            if (csv.Length() == 0)
            {
                Console.Printf("VUWS: No slot configuration to import. First run: \c[Gold]set vuws_pending_slot_config_csv \"<exported string>\"\c-");
                return;
            }

            let handler = VUWS_SlotHandler.GetHandler();
            if (!handler) return;

            // round-trip through ReadUserSlot+WriteUserSlot for 240-char trim
            Array<String> pieces;
            csv.Split(pieces, "|");
            int count = pieces.Size();
            if (count > 10) count = 10;
            for (int slot = 0; slot < count; slot++)
            {
                handler.memoryUserSlots[consoleplayer * 10 + slot] = pieces[slot];
                Array<class<Weapon> > parsed;
                handler.ReadUserSlot(slot, players[consoleplayer], parsed);
                handler.WriteUserSlot(slot, players[consoleplayer], parsed);
            }

            handler.BroadcastFullSlotConfig(consoleplayer);

            // clear staging so a stale value doesn't re-import next call
            if (pendingCV) pendingCV.SetString("");

            Console.Printf("VUWS: Imported slot configuration into %d slot(s). Run vuws_gearbox_resync if using the Gearbox bridge.",
                count);
            return;
        }
    }
}
