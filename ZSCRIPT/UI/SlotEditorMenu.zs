// SlotEditorMenu.zs
// Slot editor with click-driven workflow per user spec
//
// Layout:
//   Left pane: 10 slot rows (0-9), click to select active slot
//   Right top: weapons currently assigned to active slot (vuws_user_slot_N)
//   Right bottom: all weapons in player inventory (sister-deduped)
//   Buttons row: Add (add selected weapon to active slot) and Remove (remove from slot)
//
// Flow:
//   1. Choose slot N -> highlights slot, right-top updates with that slot's weapons
//   2. Choose weapon in right-top OR right-bottom -> highlights it
//   3. Click Add -> assigns highlighted weapon to active slot
//      Click Remove -> removes highlighted weapon from active slot (only valid if from right-top)
//
// Keyboard:
//   0-9: select that slot
//   Arrow keys: nav within focused list
//   Tab: cycle focus across slots / top list / bottom list / buttons
//   Enter on slot: focuses right-bottom list
//   Enter on weapon: highlights it
//   A: add (add selected to active slot)
//   R: remove (remove selected from active slot)
//   Esc: close

class VUWS_SlotEditorMenu : GenericMenu
{
    // Constants for focused-pane state
    const FOCUS_SLOTS  = 0;
    const FOCUS_TOPLIST = 1;
    const FOCUS_BOTLIST = 2;
    const FOCUS_ADD = 3;
    const FOCUS_REMOVE = 4;
    const FOCUS_GIVE = 5;
    const FOCUS_DROP = 6;
    const FOCUS_RESET_SLOT = 7;
    const FOCUS_RESET_ALL = 8;

    // keybind ASCII codes (resolved in Init)
    // slot editor key = close toggle, exclude key = swap to exclude menu
    int toggleAsciiCode;
    int excludeAsciiCode;

    // cached TNT1A0 so ResolveWeaponIcon can reject invisible placeholder sprites
    TextureID cachedTnt1a0;

    // ellipsis-truncate to pixel width, handles PB/BD wider SmallFont replacements
    static ui String FitText(String s, Font f, int maxWidth)
    {
        if (!f || maxWidth <= 0) return s;
        if (f.StringWidth(s) <= maxWidth) return s;
        String suffix = "..";
        if (f.StringWidth(suffix) > maxWidth) return "";
        while (s.Length() > 1 && f.StringWidth(s .. suffix) > maxWidth)
            s = s.Left(s.Length() - 1);
        return s .. suffix;
    }

    // gate menu sound playback behind vuws_sound_enabled user CVar
    static void PlayUISound(Name snd)
    {
        let cv = CVar.FindCVar('vuws_sound_enabled');
        if (cv && !cv.GetBool()) return;
        MenuSound(snd);
    }

    // map mouse position to a unique hover key for state-change detection
    // returns 0 if hovering nothing actionable, packed int otherwise
    int ComputeHoverKey(int mx, int my)
    {
        if (addBtnRect && addBtnRect.Contains(mx, my)) return 401;
        if (removeBtnRect && removeBtnRect.Contains(mx, my)) return 402;
        if (giveBtnRect && giveBtnRect.Contains(mx, my)) return 403;
        if (dropBtnRect && dropBtnRect.Contains(mx, my)) return 404;
        if (resetSlotBtnRect && resetSlotBtnRect.Contains(mx, my)) return 405;
        if (resetBtnRect && resetBtnRect.Contains(mx, my)) return 406;
        for (int i = 0; i < slotRowRects.Size(); i++)
            if (slotRowRects[i].Contains(mx, my)) return 100 + i;
        for (int i = 0; i < topRowRects.Size(); i++)
            if (topRowRects[i].Contains(mx, my)) return 200 + i;
        for (int i = 0; i < botRowRects.Size(); i++)
            if (botRowRects[i].Contains(mx, my)) return 300 + i;
        return 0;
    }

    // Convert a keyboard scancode (Bindings) to lowercase ASCII (OnUIEvent.KeyChar)
    // QWERTY layout map, mirrors VUAS_AchievementBrowseMenu.ScancodeToAscii
    private static int ScancodeToAscii(int sc)
    {
        if (sc >= 2 && sc <= 10) return sc + 47;
        if (sc == 11) return 48;
        String row1 = "qwertyuiop";
        if (sc >= 16 && sc <= 25) return row1.ByteAt(sc - 16);
        String row2 = "asdfghjkl";
        if (sc >= 30 && sc <= 38) return row2.ByteAt(sc - 30);
        String row3 = "zxcvbnm";
        if (sc >= 44 && sc <= 50) return row3.ByteAt(sc - 44);
        if (sc == 57) return 32;
        return -1;
    }

    // State
    int activeSlot;            // 0-9, currently selected slot
    int focused;               // FOCUS_*
    int topCursor;             // index in topWeapons
    int botCursor;             // display row index (0..botDisplayOrder.Size()-1), NOT allWeapons index
    int selectedSource;        // 0 = top (in-slot), 1 = bottom (all)
    int selectedIdx;           // index within the source list, -1 = none
    class<Weapon> selectedClass;  // latched copy used to re-resolve selectedIdx after rebuilds
    int mouseX;
    int mouseY;

    // gametic latch, level.time freezes during menu pause
    int pendingScrollFollowTic;

    // hover state-change detection, fires menu/cursor only on change not every tic
    // packed int: 0=none, 1xx=slot row, 2xx=top row, 3xx=bot row, 4xx=button focus enum
    int lastHoverKey;

    // Snapshots refreshed on Init / after every reassign
    Array<class<Weapon> > allWeapons;          // bottom list source: registered weapons (engine slot ∪ owned)
    Array<TextureID> allIcons;
    Array<String> allNames;
    Array<int> allCurrentSlots;                // -1 if no engine slot
    Array<int> allUserSlots;                   // -1 if not in any user mapping, else 0-9
    Array<int> allOwned;                       // 1 if currently in player inventory, 0 if registered-only
    Array<int> botDisplayOrder;                // permutation: row -> allWeapons index (sorted by user slot for display)

    Array<class<Weapon> > topWeapons;          // top list source: user mapping or engine defaults
    Array<TextureID> topIcons;
    Array<String> topNames;
    Array<int> topIsDefault;                   // 1 = engine fallback row, 0 = user-mapped row

    // Scroll panes
    VUWS_ScrollPane topPane;
    VUWS_ScrollPane botPane;

    // Hit rects (computed each frame)
    Array<VUWS_HitRect> slotRowRects;
    Array<VUWS_HitRect> topRowRects;
    Array<VUWS_HitRect> botRowRects;
    VUWS_HitRect leftPaneRect;
    VUWS_HitRect topPaneRect;
    VUWS_HitRect botPaneRect;
    VUWS_HitRect rightPaneRect;       // 3rd column: preview area + buttons
    VUWS_HitRect previewRect;         // top of right pane: weapon preview
    VUWS_HitRect addBtnRect;
    VUWS_HitRect removeBtnRect;
    VUWS_HitRect giveBtnRect;
    VUWS_HitRect dropBtnRect;
    VUWS_HitRect resetSlotBtnRect;
    VUWS_HitRect resetBtnRect;
    VUWS_HitRect hintBarRect;

    override void Init(Menu parent)
    {
        Super.Init(parent);

        activeSlot = 1;          // Default to slot 1 (most common starting weapon)
        focused = FOCUS_SLOTS;
        topCursor = 0;
        botCursor = 0;
        selectedSource = -1;
        selectedIdx = -1;
        selectedClass = null;
        mouseX = 0;
        mouseY = 0;
        pendingScrollFollowTic = -1;
        lastHoverKey = 0;

        topPane = VUWS_ScrollPane(new("VUWS_ScrollPane"));
        botPane = VUWS_ScrollPane(new("VUWS_ScrollPane"));

        BuildAllWeaponsList();
        BuildTopList();

        // both hotkeys, editor key closes self, exclude key jumps to exclude menu
        toggleAsciiCode = -1;
        excludeAsciiCode = -1;
        int k1, k2;
        [k1, k2] = Bindings.GetKeysForCommand("vuws_slot_editor");
        if (k1 > 0) toggleAsciiCode = ScancodeToAscii(k1);
        [k1, k2] = Bindings.GetKeysForCommand("vuws_exclude_menu");
        if (k1 > 0) excludeAsciiCode = ScancodeToAscii(k1);

        cachedTnt1a0 = TexMan.CheckForTexture("TNT1A0", TexMan.Type_Sprite);
    }

    // Build the bottom list: player's owned weapons, sister-deduped, exclude-filtered
    void BuildAllWeaponsList()
    {
        allWeapons.Clear();
        allIcons.Clear();
        allNames.Clear();
        allCurrentSlots.Clear();
        allUserSlots.Clear();
        allOwned.Clear();

        if (consoleplayer < 0 || consoleplayer >= MAXPLAYERS) return;
        if (!players[consoleplayer].mo) return;

        let handler = VUWS_SlotHandler.GetHandler();
        if (!handler) return;

        handler.BuildSlotMenuWeapons(players[consoleplayer].mo, allWeapons);

        for (int i = 0; i < allWeapons.Size(); i++)
        {
            class<Weapon> wc = allWeapons[i];
            let inv = players[consoleplayer].mo.FindInventory(wc);
            let w = inv ? Weapon(inv) : null;
            allOwned.Push(w ? 1 : 0);

            // Pickup sprite (SpawnState world graphic) is the recognizable weapon image
            // Inventory.Icon is sized for the status bar and stays as fallback
            TextureID icon = ResolveWeaponIcon(wc, w);
            String tag = "";
            if (w)
            {
                tag = w.GetTag();
            }
            else
            {
                let weapDefaults = Weapon(GetDefaultByType(wc));
                if (weapDefaults) tag = weapDefaults.GetTag();
            }
            if (tag.Length() == 0) tag = wc.GetClassName();
            allIcons.Push(icon);
            allNames.Push(tag);

            // Engine's current slot for this weapon (replacement-aware)
            int slot = VUWS_SlotHandler.LocateWeaponSlot(players[consoleplayer], wc);
            allCurrentSlots.Push(slot);

            // VUWS user mapping slot (-1 if not assigned to any slot)
            int uSlot = -1;
            for (int s = 0; s <= 9; s++)
            {
                Array<class<Weapon> > slotList;
                handler.ReadUserSlot(s, players[consoleplayer], slotList);
                if (slotList.Find(wc) < slotList.Size()) { uSlot = s; break; }
            }
            allUserSlots.Push(uSlot);
        }

        // display permutation, sort by effective slot (user > engine, -1 last)
        // data arrays stay in inv order so handler indices stay valid
        botDisplayOrder.Clear();
        for (int i = 0; i < allWeapons.Size(); i++) botDisplayOrder.Push(i);
        int n = botDisplayOrder.Size();
        for (int i = 0; i < n - 1; i++)
        {
            for (int j = 0; j < n - 1 - i; j++)
            {
                int idxA = botDisplayOrder[j];
                int idxB = botDisplayOrder[j + 1];
                int slotA = allUserSlots[idxA] >= 0 ? allUserSlots[idxA] : allCurrentSlots[idxA];
                int slotB = allUserSlots[idxB] >= 0 ? allUserSlots[idxB] : allCurrentSlots[idxB];
                int a = (slotA < 0) ? 100 : slotA;
                int b = (slotB < 0) ? 100 : slotB;
                if (a > b)
                {
                    int tmp = botDisplayOrder[j];
                    botDisplayOrder[j] = botDisplayOrder[j + 1];
                    botDisplayOrder[j + 1] = tmp;
                }
            }
        }

        // BD parallel classes share Tags, rows look identical without disambig
        VUWS_SlotHandler.DisambiguateDuplicateNames(allNames, allWeapons);

        // reconcile selectedIdx via latched class (rebuild shuffles indices)
        // clear selection if class fell out of the new list
        if (selectedSource == 1 && selectedClass)
        {
            int newIdx = allWeapons.Find(selectedClass);
            if (newIdx < allWeapons.Size())
            {
                selectedIdx = newIdx;
            }
            else
            {
                selectedSource = -1;
                selectedIdx = -1;
                selectedClass = null;
            }
        }

        // Clamp cursor so a list shrink doesn't strand it past the end
        if (botCursor >= botDisplayOrder.Size())
            botCursor = botDisplayOrder.Size() > 0 ? botDisplayOrder.Size() - 1 : 0;
        if (botCursor < 0) botCursor = 0;
    }

    // first non-TNT1 sprite in state chain, 16-step loop guard
    TextureID WalkStateChainForSprite(State s)
    {
        TextureID result;
        for (int i = 0; i < 16 && s; i++)
        {
            if (s.sprite != 0)
            {
                TextureID sprIcon; bool flip; Vector2 ssize;
                [sprIcon, flip, ssize] = s.GetSpriteTexture(0);
                if (sprIcon.IsValid() && sprIcon != cachedTnt1a0)
                {
                    result = sprIcon;
                    return result;
                }
            }
            s = s.NextState;
        }
        return result;
    }

    // Priority: SpawnState chain -> ReadyState chain -> Inventory.Icon
    // Custom melee weapons often have Spawn: TNT1 A 0 (not world-droppable) so we walk states
    TextureID ResolveWeaponIcon(class<Weapon> wc, Weapon ownedInstance)
    {
        TextureID result;
        State sst = null;
        State ready = null;
        TextureID iconField;
        if (ownedInstance)
        {
            sst = ownedInstance.SpawnState;
            ready = ownedInstance.FindState('Ready');
            iconField = ownedInstance.Icon;
        }
        else
        {
            let weapDefaults = Weapon(GetDefaultByType(wc));
            if (weapDefaults)
            {
                sst = weapDefaults.SpawnState;
                ready = weapDefaults.FindState('Ready');
                iconField = weapDefaults.Icon;
            }
        }

        result = WalkStateChainForSprite(sst);
        if (!result.IsValid()) result = WalkStateChainForSprite(ready);
        if (!result.IsValid() && iconField.IsValid()) result = iconField;
        return result;
    }

    // top list = user mapping (or engine fallback flagged via topIsDefault)
    void BuildTopList()
    {
        topWeapons.Clear();
        topIcons.Clear();
        topNames.Clear();
        topIsDefault.Clear();

        let handler = VUWS_SlotHandler.GetHandler();
        if (!handler) return;

        // customized = user list verbatim, fallback = effective view (matches HUD)
        handler.ReadUserSlot(activeSlot, players[consoleplayer], topWeapons);
        bool isDefault = (topWeapons.Size() == 0);
        if (isDefault)
        {
            handler.BuildCurrentSlotEffective(activeSlot, players[consoleplayer], topWeapons);
        }

        for (int i = 0; i < topWeapons.Size(); i++)
        {
            class<Weapon> wc = topWeapons[i];
            let inv = players[consoleplayer].mo
                ? players[consoleplayer].mo.FindInventory(wc)
                : null;
            let w = inv ? Weapon(inv) : null;

            TextureID icon = ResolveWeaponIcon(wc, w);
            topIcons.Push(icon);

            String tag = w ? w.GetTag() : "";
            if (tag.Length() == 0)
            {
                let weapDefaults = Weapon(GetDefaultByType(wc));
                if (weapDefaults) tag = weapDefaults.GetTag();
            }
            if (tag.Length() == 0) tag = wc.GetClassName();
            topNames.Push(tag);

            topIsDefault.Push(isDefault ? 1 : 0);
        }

        // Reuse allNames so disambiguator suffixes stay in sync across both lists
        // (Drawer always calls BuildAllWeaponsList first so allNames is populated)
        for (int i = 0; i < topWeapons.Size(); i++)
        {
            int allIdx = allWeapons.Find(topWeapons[i]);
            if (allIdx < allWeapons.Size()) topNames[i] = allNames[allIdx];
        }

        // re-resolve top-list selectedIdx via latched class (rebuild reshuffles)
        // clear if weapon left this slot
        if (selectedSource == 0 && selectedClass)
        {
            int newIdx = topWeapons.Find(selectedClass);
            if (newIdx < topWeapons.Size())
            {
                selectedIdx = newIdx;
            }
            else
            {
                selectedSource = -1;
                selectedIdx = -1;
                selectedClass = null;
            }
        }

        // Clamp cursors to valid range so navigation doesn't pick up from a stale position
        if (topCursor >= topWeapons.Size()) topCursor = topWeapons.Size() > 0 ? topWeapons.Size() - 1 : 0;
        if (topCursor < 0) topCursor = 0;
    }

    override void Drawer()
    {
        // no whole-screen dim, content frame owns its own bg

        // Rebuild lists each frame so Add/Remove changes show immediately
        // CVar reads are cheap, this avoids a stale-list frame after netevent dispatch
        BuildAllWeaponsList();
        BuildTopList();

        // wait for gametic advance so RunNetSpecs has committed the netevent
        if (pendingScrollFollowTic >= 0 && gametic > pendingScrollFollowTic)
        {
            EnsureSelectedVisible();
            pendingScrollFollowTic = -1;
        }

        ComputeLayout();

        // Inner content panel
        int frameX = VUWS_SlotConfig.PAGE_MARGIN_X - 8;
        int frameY = VUWS_SlotConfig.PAGE_MARGIN_TOP - 8;
        int frameW = VUWS_SlotConfig.VIRT_W - 2 * VUWS_SlotConfig.PAGE_MARGIN_X + 16;
        int frameH = VUWS_SlotConfig.VIRT_H - VUWS_SlotConfig.PAGE_MARGIN_TOP
            - VUWS_SlotConfig.PAGE_MARGIN_BOTTOM + 16;
        VUWS_SlotConfig.DimVirt(0x080808, VUWS_SlotConfig.CONTENT_PANEL_ALPHA,
            frameX, frameY, frameW, frameH);

        int borderHex = ResolveAccentHex();
        VUWS_SlotConfig.DimVirt(borderHex, 0.6, frameX, frameY, frameW, 1);
        VUWS_SlotConfig.DimVirt(borderHex, 0.6, frameX, frameY + frameH - 1, frameW, 1);
        VUWS_SlotConfig.DimVirt(borderHex, 0.6, frameX, frameY, 1, frameH);
        VUWS_SlotConfig.DimVirt(borderHex, 0.6, frameX + frameW - 1, frameY, 1, frameH);

        String titleStr = "Weapon Slot Editor";
        int titleW = BigFont.StringWidth(titleStr);
        int titleX = (VUWS_SlotConfig.VIRT_W - titleW) / 2;
        Screen.DrawText(BigFont, Font.CR_GOLD,
            titleX, VUWS_SlotConfig.PAGE_MARGIN_TOP - 1,
            titleStr,
            DTA_VirtualWidth, VUWS_SlotConfig.VIRT_W,
            DTA_VirtualHeight, VUWS_SlotConfig.VIRT_H,
            DTA_KeepRatio, true);

        DrawSlotList();
        DrawTopList();
        DrawBotList();
        DrawPreviewPane();
        DrawButtons();
        DrawHintBar();
    }

    void ComputeLayout()
    {
        if (!leftPaneRect)   leftPaneRect = new("VUWS_HitRect");
        if (!topPaneRect)    topPaneRect = new("VUWS_HitRect");
        if (!botPaneRect)    botPaneRect = new("VUWS_HitRect");
        if (!rightPaneRect)  rightPaneRect = new("VUWS_HitRect");
        if (!previewRect)    previewRect = new("VUWS_HitRect");
        if (!addBtnRect)     addBtnRect = new("VUWS_HitRect");
        if (!removeBtnRect)    removeBtnRect = new("VUWS_HitRect");
        if (!giveBtnRect)      giveBtnRect = new("VUWS_HitRect");
        if (!dropBtnRect)      dropBtnRect = new("VUWS_HitRect");
        if (!resetSlotBtnRect) resetSlotBtnRect = new("VUWS_HitRect");
        if (!resetBtnRect)     resetBtnRect = new("VUWS_HitRect");
        if (!hintBarRect)      hintBarRect = new("VUWS_HitRect");

        // left pane slot list, -6 balances bottom gap vs top title gap
        leftPaneRect.x = VUWS_SlotConfig.PAGE_MARGIN_X;
        leftPaneRect.y = VUWS_SlotConfig.PAGE_MARGIN_TOP + VUWS_SlotConfig.TITLE_HEIGHT;
        leftPaneRect.w = VUWS_SlotConfig.LEFT_PANE_WIDTH;
        leftPaneRect.h = VUWS_SlotConfig.VIRT_H
            - VUWS_SlotConfig.PAGE_MARGIN_TOP - VUWS_SlotConfig.TITLE_HEIGHT
            - VUWS_SlotConfig.PAGE_MARGIN_BOTTOM - VUWS_SlotConfig.HINT_HEIGHT - 6;

        // Right pane: preview + buttons (rightmost column)
        rightPaneRect.x = VUWS_SlotConfig.VIRT_W - VUWS_SlotConfig.PAGE_MARGIN_X
            - VUWS_SlotConfig.RIGHT_PANE_WIDTH;
        rightPaneRect.y = leftPaneRect.y;
        rightPaneRect.w = VUWS_SlotConfig.RIGHT_PANE_WIDTH;
        rightPaneRect.h = leftPaneRect.h;

        // Middle column: in-slot list + all-weapons list, between left and right
        int midX = leftPaneRect.x + leftPaneRect.w + VUWS_SlotConfig.PANE_GAP;
        int midW = rightPaneRect.x - midX - VUWS_SlotConfig.PANE_GAP;

        topPaneRect.x = midX;
        topPaneRect.y = leftPaneRect.y;
        topPaneRect.w = midW;
        // match preview height, All Weapons header lines up with Add button top
        topPaneRect.h = VUWS_SlotConfig.PREVIEW_HEIGHT;

        botPaneRect.x = midX;
        botPaneRect.y = topPaneRect.y + topPaneRect.h + 8;
        botPaneRect.w = midW;
        botPaneRect.h = leftPaneRect.h - topPaneRect.h - 8;

        // Right pane content: preview at top, Add + Remove buttons stacked beneath
        previewRect.x = rightPaneRect.x;
        previewRect.y = rightPaneRect.y;
        previewRect.w = rightPaneRect.w;
        previewRect.h = VUWS_SlotConfig.PREVIEW_HEIGHT;

        // 3 button groups, 6px within / 14px between
        // Add+Remove, Give+Drop, Reset Slot N + Reset All
        int btnW = rightPaneRect.w - 8;
        int btnH = 22;
        addBtnRect.x = rightPaneRect.x + 4;
        addBtnRect.y = previewRect.y + previewRect.h + 8;
        addBtnRect.w = btnW;
        addBtnRect.h = btnH;
        removeBtnRect.x = rightPaneRect.x + 4;
        removeBtnRect.y = addBtnRect.y + btnH + 6;
        removeBtnRect.w = btnW;
        removeBtnRect.h = btnH;
        giveBtnRect.x = rightPaneRect.x + 4;
        giveBtnRect.y = removeBtnRect.y + btnH + 14;
        giveBtnRect.w = btnW;
        giveBtnRect.h = btnH;
        dropBtnRect.x = rightPaneRect.x + 4;
        dropBtnRect.y = giveBtnRect.y + btnH + 6;
        dropBtnRect.w = btnW;
        dropBtnRect.h = btnH;
        resetSlotBtnRect.x = rightPaneRect.x + 4;
        resetSlotBtnRect.y = dropBtnRect.y + btnH + 14;
        resetSlotBtnRect.w = btnW;
        resetSlotBtnRect.h = btnH;
        resetBtnRect.x = rightPaneRect.x + 4;
        resetBtnRect.y = resetSlotBtnRect.y + btnH + 6;
        resetBtnRect.w = btnW;
        resetBtnRect.h = btnH;

        // top pane viewport differs in default mode (smaller line height + subheader space)
        // computed here so wheel + scrollbar see consistent state
        topPane.viewportX = topPaneRect.x;
        topPane.viewportW = topPaneRect.w;
        bool topInDefaultMode = (topWeapons.Size() > 0 && topIsDefault.Size() > 0
            && topIsDefault[0] == 1);
        if (topInDefaultMode)
        {
            int slot1TextY = leftPaneRect.y + VUWS_SlotConfig.PANE_HEADER_HEIGHT + 4
                + VUWS_SlotConfig.ROW_HEIGHT + 4;
            int defaultRowsTop = slot1TextY + SmallFont.GetHeight() + 4;
            int paneBottom = topPaneRect.y + topPaneRect.h;
            int lineH = SmallFont.GetHeight() + 2;
            topPane.viewportY = defaultRowsTop;
            topPane.viewportH = paneBottom - defaultRowsTop;
            if (topPane.viewportH < 0) topPane.viewportH = 0;
            topPane.rowHeight = lineH;
            topPane.SetContentHeight(topWeapons.Size() * lineH);
        }
        else
        {
            topPane.viewportY = topPaneRect.y + VUWS_SlotConfig.PANE_HEADER_HEIGHT + 2;
            topPane.viewportH = topPaneRect.h - VUWS_SlotConfig.PANE_HEADER_HEIGHT - 2;
            topPane.rowHeight = VUWS_SlotConfig.ROW_HEIGHT;
            topPane.SetContentHeight(topWeapons.Size() * VUWS_SlotConfig.ROW_HEIGHT);
        }

        botPane.viewportX = botPaneRect.x;
        botPane.viewportY = botPaneRect.y + VUWS_SlotConfig.PANE_HEADER_HEIGHT + 2;
        botPane.viewportW = botPaneRect.w;
        botPane.viewportH = botPaneRect.h - VUWS_SlotConfig.PANE_HEADER_HEIGHT - 2;
        botPane.rowHeight = VUWS_SlotConfig.ROW_HEIGHT;
        botPane.SetContentHeight(allWeapons.Size() * VUWS_SlotConfig.ROW_HEIGHT);

        // hint bar inside frame, +12 mirrors the title gap for symmetric breathing
        hintBarRect.x = VUWS_SlotConfig.PAGE_MARGIN_X;
        hintBarRect.y = leftPaneRect.y + leftPaneRect.h + 12;
        hintBarRect.w = VUWS_SlotConfig.VIRT_W - 2 * VUWS_SlotConfig.PAGE_MARGIN_X;
        hintBarRect.h = VUWS_SlotConfig.HINT_HEIGHT;
    }

    // ---- Left pane (slot list) ----

    void DrawSlotList()
    {
        VUWS_SlotConfig.DimVirt(0x181818, VUWS_SlotConfig.PANE_BG_ALPHA,
            leftPaneRect.x, leftPaneRect.y, leftPaneRect.w, leftPaneRect.h);

        int hexAccent = ResolveAccentHex();
        VUWS_SlotConfig.DimVirt(hexAccent, 0.4,
            leftPaneRect.x, leftPaneRect.y,
            leftPaneRect.w, VUWS_SlotConfig.PANE_HEADER_HEIGHT);
        Screen.DrawText(SmallFont, Font.CR_WHITE,
            leftPaneRect.x + 6, leftPaneRect.y + 4, "SLOTS",
            DTA_VirtualWidth, VUWS_SlotConfig.VIRT_W,
            DTA_VirtualHeight, VUWS_SlotConfig.VIRT_H,
            DTA_KeepRatio, true);

        slotRowRects.Clear();

        // 1..9,0 order matches keyboard number row layout
        int rowH = VUWS_SlotConfig.ROW_HEIGHT;
        int rowsTop = leftPaneRect.y + VUWS_SlotConfig.PANE_HEADER_HEIGHT + 4;
        for (int row = 0; row < 10; row++)
        {
            int slot = (row + 1) % 10;
            let r = VUWS_HitRect.Create(
                leftPaneRect.x + 4,
                rowsTop + row * rowH,
                leftPaneRect.w - 8,
                rowH - 2);
            slotRowRects.Push(r);
            DrawSlotRow(slot, r);
        }
    }

    void DrawSlotRow(int slot, VUWS_HitRect r)
    {
        bool isActive = (slot == activeSlot);
        bool isFocused = (focused == FOCUS_SLOTS && slot == activeSlot);
        bool hovered = r.Contains(mouseX, mouseY);

        if (isActive)
        {
            int hex = ResolveAccentHex();
            VUWS_SlotConfig.DimVirt(hex, 0.4, r.x, r.y, r.w, r.h);
        }
        else if (hovered)
        {
            // grey hover, distinct from active slot's yellow accent
            int greyHex = 0xAAAAAA;
            VUWS_SlotConfig.DimVirt(greyHex, 0.18, r.x, r.y, r.w, r.h);
            VUWS_SlotConfig.DimVirt(greyHex, 0.5, r.x, r.y, r.w, 1);
            VUWS_SlotConfig.DimVirt(greyHex, 0.5, r.x, r.y + r.h - 1, r.w, 1);
            VUWS_SlotConfig.DimVirt(greyHex, 0.5, r.x, r.y, 1, r.h);
            VUWS_SlotConfig.DimVirt(greyHex, 0.5, r.x + r.w - 1, r.y, 1, r.h);
        }

        let handler = VUWS_SlotHandler.GetHandler();
        int cap = VUWS_SlotHandler.GetCVarSlotCap(slot, players[consoleplayer]);
        int count = handler ? handler.CountSlotOccupantsForUI(players[consoleplayer].mo, slot) : 0;

        // sentinel 9999 cap looks like glitch, render as "-" for "uncapped"
        bool unlimited = (cap >= 999);
        String label = unlimited
            ? String.Format("Slot %d  (%d/-)", slot, count)
            : String.Format("Slot %d  (%d/%d)", slot, count, cap);
        label = FitText(label, SmallFont, r.w - 8);
        Screen.DrawText(SmallFont, Font.CR_WHITE, r.x + 4, r.y + 4, label,
            DTA_VirtualWidth, VUWS_SlotConfig.VIRT_W,
            DTA_VirtualHeight, VUWS_SlotConfig.VIRT_H,
            DTA_KeepRatio, true);
    }

    // ---- Top list (slot weapons) ----

    void DrawTopList()
    {
        VUWS_SlotConfig.DimVirt(0x181818, VUWS_SlotConfig.PANE_BG_ALPHA,
            topPaneRect.x, topPaneRect.y, topPaneRect.w, topPaneRect.h);

        int hexAccent = ResolveAccentHex();
        VUWS_SlotConfig.DimVirt(hexAccent, 0.4,
            topPaneRect.x, topPaneRect.y,
            topPaneRect.w, VUWS_SlotConfig.PANE_HEADER_HEIGHT);

        String header = String.Format("WEAPONS IN SLOT %d", activeSlot);
        Screen.DrawText(SmallFont, Font.CR_WHITE,
            topPaneRect.x + 6, topPaneRect.y + 4, header,
            DTA_VirtualWidth, VUWS_SlotConfig.VIRT_W,
            DTA_VirtualHeight, VUWS_SlotConfig.VIRT_H,
            DTA_KeepRatio, true);

        topRowRects.Clear();

        bool inDefaultMode = (topWeapons.Size() > 0 && topIsDefault.Size() > 0
            && topIsDefault[0] == 1);
        bool empty = (topWeapons.Size() == 0);
        // anchor empty-state + DEFAULT subheader below header band, NOT topPane.viewportY
        // (viewportY in default mode points past the subheader)
        int headerLineY = topPaneRect.y + VUWS_SlotConfig.PANE_HEADER_HEIGHT + 2 + 4;
        int rowsTop = topPane.viewportY;

        // Empty-state line shows when nothing user-mapped, regardless of whether engine has defaults
        if (empty || inDefaultMode)
        {
            Screen.DrawText(SmallFont, Font.CR_DARKGRAY,
                topPane.viewportX + 6, headerLineY,
                "NO CUSTOM ASSIGNMENTS",
                DTA_VirtualWidth, VUWS_SlotConfig.VIRT_W,
                DTA_VirtualHeight, VUWS_SlotConfig.VIRT_H,
                DTA_KeepRatio, true);

            if (inDefaultMode)
            {
                // align subheader to left-pane slot 1 baseline so they read on one line
                int slot1TextY = leftPaneRect.y + VUWS_SlotConfig.PANE_HEADER_HEIGHT + 4
                    + VUWS_SlotConfig.ROW_HEIGHT + 4;
                Screen.DrawText(SmallFont, Font.CR_GRAY,
                    topPane.viewportX + 6, slot1TextY,
                    "DEFAULT:",
                    DTA_VirtualWidth, VUWS_SlotConfig.VIRT_W,
                    DTA_VirtualHeight, VUWS_SlotConfig.VIRT_H,
                    DTA_KeepRatio, true);
            }
        }

        if (empty)
        {
            DrawScrollbar(topPane);
            return;
        }

        // default mode = read-only signage, scrollbar auto-hides at scrollMax==0
        if (inDefaultMode)
        {
            int lineH = topPane.rowHeight;
            int rowsStart = topPane.viewportY;
            int viewableH = topPane.viewportH;

            double sX = double(Screen.GetWidth()) / VUWS_SlotConfig.VIRT_W;
            double sY = double(Screen.GetHeight()) / VUWS_SlotConfig.VIRT_H;
            Screen.SetClipRect(
                int(topPane.viewportX * sX),
                int(rowsStart * sY),
                int(topPane.viewportW * sX),
                int(viewableH * sY));

            // Reserve room on the right for the scrollbar so text doesn't run under it
            int defaultLineMaxW = topPane.viewportW - 14 - 4 - VUWS_SlotConfig.SCROLLBAR_WIDTH;
            for (int i = 0; i < topWeapons.Size(); i++)
            {
                int lineY = rowsStart + i * lineH - topPane.scrollOffset;
                if (lineY + lineH < rowsStart) continue;
                if (lineY > rowsStart + viewableH) break;
                String name = FitText(topNames[i], SmallFont, defaultLineMaxW);
                Screen.DrawText(SmallFont, Font.CR_DARKGRAY,
                    topPane.viewportX + 14, lineY, name,
                    DTA_VirtualWidth, VUWS_SlotConfig.VIRT_W,
                    DTA_VirtualHeight, VUWS_SlotConfig.VIRT_H,
                    DTA_KeepRatio, true);
            }

            Screen.ClearClipRect();
            DrawScrollbar(topPane);
            return;
        }

        // SetClipRect (in screen pixels) physically truncates partial rows at viewport edges
        double sX = double(Screen.GetWidth()) / VUWS_SlotConfig.VIRT_W;
        double sY = double(Screen.GetHeight()) / VUWS_SlotConfig.VIRT_H;
        Screen.SetClipRect(
            int(topPane.viewportX * sX),
            int(topPane.viewportY * sY),
            int(topPane.viewportW * sX),
            int(topPane.viewportH * sY));

        for (int i = 0; i < topWeapons.Size(); i++)
        {
            int rowY = rowsTop + i * VUWS_SlotConfig.ROW_HEIGHT - topPane.scrollOffset;

            let r = VUWS_HitRect.Create(
                topPane.viewportX + 4,
                rowY,
                topPane.viewportW - 8 - VUWS_SlotConfig.SCROLLBAR_WIDTH,
                VUWS_SlotConfig.ROW_HEIGHT);
            topRowRects.Push(r);

            if (rowY + VUWS_SlotConfig.ROW_HEIGHT < topPane.viewportY) continue;
            if (rowY > topPane.viewportY + topPane.viewportH) continue;

            DrawWeaponRow(i, i, r, topIcons, topNames, true);
        }

        Screen.ClearClipRect();
        DrawScrollbar(topPane);
    }

    // ---- Bottom list (all weapons) ----

    void DrawBotList()
    {
        VUWS_SlotConfig.DimVirt(0x181818, VUWS_SlotConfig.PANE_BG_ALPHA,
            botPaneRect.x, botPaneRect.y, botPaneRect.w, botPaneRect.h);

        int hexAccent = ResolveAccentHex();
        VUWS_SlotConfig.DimVirt(hexAccent, 0.4,
            botPaneRect.x, botPaneRect.y,
            botPaneRect.w, VUWS_SlotConfig.PANE_HEADER_HEIGHT);
        Screen.DrawText(SmallFont, Font.CR_WHITE,
            botPaneRect.x + 6, botPaneRect.y + 4, "ALL WEAPONS",
            DTA_VirtualWidth, VUWS_SlotConfig.VIRT_W,
            DTA_VirtualHeight, VUWS_SlotConfig.VIRT_H,
            DTA_KeepRatio, true);

        botRowRects.Clear();

        if (allWeapons.Size() == 0)
        {
            Screen.DrawText(SmallFont, Font.CR_DARKGRAY,
                botPane.viewportX + 6, botPane.viewportY + 6,
                "(no weapons in inventory)",
                DTA_VirtualWidth, VUWS_SlotConfig.VIRT_W,
                DTA_VirtualHeight, VUWS_SlotConfig.VIRT_H,
                DTA_KeepRatio, true);
            return;
        }

        // botRowRects is parallel to botDisplayOrder (one rect per displayed row)
        // Each row maps to a real allWeapons index via botDisplayOrder[rowIdx]
        // Clip rect physically truncates partial rows at the viewport edges
        double sX = double(Screen.GetWidth()) / VUWS_SlotConfig.VIRT_W;
        double sY = double(Screen.GetHeight()) / VUWS_SlotConfig.VIRT_H;
        Screen.SetClipRect(
            int(botPane.viewportX * sX),
            int(botPane.viewportY * sY),
            int(botPane.viewportW * sX),
            int(botPane.viewportH * sY));

        for (int row = 0; row < botDisplayOrder.Size(); row++)
        {
            int rowY = botPane.viewportY + row * VUWS_SlotConfig.ROW_HEIGHT - botPane.scrollOffset;

            let r = VUWS_HitRect.Create(
                botPane.viewportX + 4,
                rowY,
                botPane.viewportW - 8 - VUWS_SlotConfig.SCROLLBAR_WIDTH,
                VUWS_SlotConfig.ROW_HEIGHT);
            botRowRects.Push(r);

            if (rowY + VUWS_SlotConfig.ROW_HEIGHT < botPane.viewportY) continue;
            if (rowY > botPane.viewportY + botPane.viewportH) continue;

            DrawWeaponRow(botDisplayOrder[row], row, r, allIcons, allNames, false);
        }

        Screen.ClearClipRect();
        DrawScrollbar(botPane);
    }

    // shared row drawer
    // dataIdx -> parallel arrays, displayRow -> visual position (top list: equal)
    void DrawWeaponRow(int dataIdx, int displayRow, VUWS_HitRect r,
        Array<TextureID> icons, Array<String> names, bool isTop)
    {
        bool isFocused = (focused == FOCUS_TOPLIST && isTop && topCursor == displayRow)
            || (focused == FOCUS_BOTLIST && !isTop && botCursor == displayRow);
        bool isSelected = (selectedSource == (isTop ? 0 : 1) && selectedIdx == dataIdx);
        bool hovered = r.Contains(mouseX, mouseY);

        int idx = dataIdx;

        // dim unowned rows in bottom list, pre-assign visible but quiet
        bool dimNotOwned = !isTop && idx < allOwned.Size() && allOwned[idx] == 0;
        // Top list dims rows that came from the engine fallback (no user mapping for this slot)
        bool dimDefault = isTop && idx < topIsDefault.Size() && topIsDefault[idx] == 1;
        bool dim = dimNotOwned || dimDefault;
        double iconAlpha = dim ? 0.4 : 1.0;
        int textColor = dim ? Font.CR_DARKGRAY : Font.CR_WHITE;

        // Manual clamp because Screen.SetClipRect doesn't catch Dim() in 4.14.2
        // (highlight band would leak past top/bottom edge into header / hint bar)
        int vpTop = isTop ? topPane.viewportY : botPane.viewportY;
        int vpBot = vpTop + (isTop ? topPane.viewportH : botPane.viewportH);
        int bgY = r.y;
        int bgH = r.h;
        if (bgY < vpTop) { bgH -= (vpTop - bgY); bgY = vpTop; }
        if (bgY + bgH > vpBot) bgH = vpBot - bgY;

        if (bgH > 0)
        {
            if (isSelected)
            {
                int hex = ResolveAccentHex();
                VUWS_SlotConfig.DimVirt(hex, 0.5, r.x, bgY, r.w, bgH);
            }
            else if (isFocused || hovered)
            {
                // Grey see-through bg + thin grey border, distinct from the selection accent
                int greyHex = 0xAAAAAA;
                VUWS_SlotConfig.DimVirt(greyHex, 0.18, r.x, bgY, r.w, bgH);
                VUWS_SlotConfig.DimVirt(greyHex, 0.5, r.x, bgY, r.w, 1);
                VUWS_SlotConfig.DimVirt(greyHex, 0.5, r.x, bgY + bgH - 1, r.w, 1);
                VUWS_SlotConfig.DimVirt(greyHex, 0.5, r.x, bgY, 1, bgH);
                VUWS_SlotConfig.DimVirt(greyHex, 0.5, r.x + r.w - 1, bgY, 1, bgH);
            }
        }

        // text-only rows, weapon sprites live in the preview pane
        int textX = r.x + 6;
        int textY = r.y + (r.h - SmallFont.GetHeight()) / 2;

        // bot list prefixes the weapon's effective slot (user > engine, [X] otherwise)
        // top list omits it since the pane header carries the slot
        if (!isTop && idx < allUserSlots.Size())
        {
            int uSlot = allUserSlots[idx];
            int eSlot = (idx < allCurrentSlots.Size()) ? allCurrentSlots[idx] : -1;
            int displaySlot = (uSlot >= 0) ? uSlot : eSlot;
            String tag = (displaySlot >= 0) ? String.Format("[%d]", displaySlot) : "[X]";
            int tagColor = dimNotOwned ? Font.CR_DARKGRAY
                : (displaySlot >= 0 ? Font.CR_GOLD : Font.CR_DARKGRAY);
            Screen.DrawText(SmallFont, tagColor, textX, textY, tag,
                DTA_VirtualWidth, VUWS_SlotConfig.VIRT_W,
                DTA_VirtualHeight, VUWS_SlotConfig.VIRT_H,
                DTA_KeepRatio, true);
            int tagW = SmallFont.StringWidth(tag) + 6;
            textX += tagW;
        }

        if (idx < names.Size())
        {
            int rowRight = r.x + r.w;
            int availW = rowRight - textX - 4;
            String displayName = FitText(names[idx], SmallFont, availW);
            Screen.DrawText(SmallFont, textColor, textX, textY, displayName,
                DTA_VirtualWidth, VUWS_SlotConfig.VIRT_W,
                DTA_VirtualHeight, VUWS_SlotConfig.VIRT_H,
                DTA_KeepRatio, true);
        }
    }

    void DrawScrollbar(VUWS_ScrollPane pane)
    {
        VUWS_HitRect track;
        bool needScroll;
        [track, needScroll] = pane.ScrollbarTrackRect(VUWS_SlotConfig.SCROLLBAR_WIDTH);
        // hide scrollbar when content fits, empty track misleads
        if (!needScroll) return;
        VUWS_SlotConfig.DimVirt(0x202020, 0.6, track.x, track.y, track.w, track.h);

        let thumb = pane.ThumbRect(VUWS_SlotConfig.SCROLLBAR_WIDTH);
        int hex = ResolveAccentHex();
        VUWS_SlotConfig.DimVirt(hex, 0.7, thumb.x, thumb.y, thumb.w, thumb.h);
    }

    // ---- Right pane: weapon preview ----

    void DrawPreviewPane()
    {
        // Determine empty state once, drives both the dimmer bg and the placeholder text below
        bool hasSelection = false;
        if (selectedSource == 0 && selectedIdx >= 0 && selectedIdx < topWeapons.Size())
            hasSelection = true;
        else if (selectedSource == 1 && selectedIdx >= 0 && selectedIdx < allWeapons.Size())
            hasSelection = true;

        // dim empty pane bg further, signals "needs input"
        double bgAlpha = hasSelection
            ? VUWS_SlotConfig.PANE_BG_ALPHA
            : VUWS_SlotConfig.PANE_BG_ALPHA * 0.55;
        VUWS_SlotConfig.DimVirt(0x181818, bgAlpha,
            previewRect.x, previewRect.y, previewRect.w, previewRect.h);

        // Header
        int hexAccent = ResolveAccentHex();
        VUWS_SlotConfig.DimVirt(hexAccent, 0.4,
            previewRect.x, previewRect.y,
            previewRect.w, VUWS_SlotConfig.PANE_HEADER_HEIGHT);
        Screen.DrawText(SmallFont, Font.CR_WHITE,
            previewRect.x + 6, previewRect.y + 4, "PREVIEW",
            DTA_VirtualWidth, VUWS_SlotConfig.VIRT_W,
            DTA_VirtualHeight, VUWS_SlotConfig.VIRT_H,
            DTA_KeepRatio, true);

        // pick preview weapon from selection, nameAlpha dims when idle
        TextureID icon;
        String weapName = "(no selection)";
        int textColor = Font.CR_DARKGRAY;
        double nameAlpha = 0.35;
        if (selectedSource == 0 && selectedIdx >= 0 && selectedIdx < topWeapons.Size())
        {
            icon = topIcons[selectedIdx];
            weapName = topNames[selectedIdx];
            textColor = Font.CR_WHITE;
            nameAlpha = 1.0;
        }
        else if (selectedSource == 1 && selectedIdx >= 0 && selectedIdx < allWeapons.Size())
        {
            icon = allIcons[selectedIdx];
            weapName = allNames[selectedIdx];
            textColor = (selectedIdx < allOwned.Size() && allOwned[selectedIdx] == 0)
                ? Font.CR_DARKGRAY : Font.CR_WHITE;
            nameAlpha = 1.0;
        }

        // raw pixels preserve aspect, virtual + KeepRatio skews X/Y on 16:9
        int maxBox = 70;  // virtual size of the bounding box (used for layout below)
        int boxLeft = previewRect.x + (previewRect.w - maxBox) / 2;
        int boxTop = previewRect.y + VUWS_SlotConfig.PANE_HEADER_HEIGHT + 8;
        bool hasIcon = icon.IsValid();
        int iconY = boxTop;
        if (hasIcon)
        {
            // Convert the bounding box from virtual to actual pixels (square in pixels)
            double sX = double(Screen.GetWidth()) / VUWS_SlotConfig.VIRT_W;
            double sY = double(Screen.GetHeight()) / VUWS_SlotConfig.VIRT_H;
            int actualBoxLeft = int(boxLeft * sX);
            int actualBoxTop = int(boxTop * sY);
            int actualBoxW = int(maxBox * sX);
            int actualBoxH = int(maxBox * sY);
            int actualBox = actualBoxW < actualBoxH ? actualBoxW : actualBoxH;

            Vector2 srcSize = TexMan.GetScaledSize(icon);
            double srcW = srcSize.X;
            double srcH = srcSize.Y;
            if (srcW < 1) srcW = 1;
            if (srcH < 1) srcH = 1;
            double scale = (srcW > srcH) ? (actualBox / srcW) : (actualBox / srcH);
            int destW = int(srcW * scale);
            int destH = int(srcH * scale);
            int drawX = actualBoxLeft + (actualBoxW - destW) / 2;
            int drawY = actualBoxTop + (actualBoxH - destH) / 2;
            Screen.DrawTexture(icon, true, drawX, drawY,
                DTA_DestWidth, destW,
                DTA_DestHeight, destH,
                DTA_TopLeft, true);
            iconY = boxTop + maxBox;
        }

        // Split " (suffix)" off the disambiguated name to render as two lines
        // (preview pane too narrow to fit the combined string)
        String mainName = weapName;
        String subName = "";
        int parenStart = weapName.IndexOf(" (");
        if (parenStart >= 0)
        {
            int parenEnd = weapName.IndexOf(")", parenStart);
            if (parenEnd > parenStart)
            {
                mainName = weapName.Left(parenStart);
                subName = weapName.Mid(parenStart + 2, parenEnd - parenStart - 2);
            }
        }

        int mainY;
        if (hasIcon)
        {
            mainY = iconY + 4;
        }
        else
        {
            int contentTop = previewRect.y + VUWS_SlotConfig.PANE_HEADER_HEIGHT;
            int contentH = previewRect.h - VUWS_SlotConfig.PANE_HEADER_HEIGHT;
            // Center the pair (or single line if no subtitle) inside the content area
            int totalH = SmallFont.GetHeight();
            if (subName.Length() > 0) totalH += SmallFont.GetHeight() + 2;
            mainY = contentTop + (contentH - totalH) / 2;
        }
        int previewMaxW = previewRect.w - 8;
        mainName = FitText(mainName, SmallFont, previewMaxW);
        int mainW = SmallFont.StringWidth(mainName);
        int mainX = previewRect.x + (previewRect.w - mainW) / 2;
        Screen.DrawText(SmallFont, textColor, mainX, mainY, mainName,
            DTA_VirtualWidth, VUWS_SlotConfig.VIRT_W,
            DTA_VirtualHeight, VUWS_SlotConfig.VIRT_H,
            DTA_KeepRatio, true,
            DTA_Alpha, nameAlpha);

        if (subName.Length() > 0)
        {
            // Wrap in parens to match the list-row disambiguator style ("(Chain_saw)")
            String subDisplay = FitText("(" .. subName .. ")", SmallFont, previewMaxW);
            int subY = mainY + SmallFont.GetHeight() + 2;
            int subW = SmallFont.StringWidth(subDisplay);
            int subX = previewRect.x + (previewRect.w - subW) / 2;
            Screen.DrawText(SmallFont, Font.CR_DARKGRAY, subX, subY, subDisplay,
                DTA_VirtualWidth, VUWS_SlotConfig.VIRT_W,
                DTA_VirtualHeight, VUWS_SlotConfig.VIRT_H,
                DTA_KeepRatio, true,
                DTA_Alpha, nameAlpha);
        }
    }

    // ---- Buttons ----

    void DrawButtons()
    {
        DrawButton(addBtnRect, "ADD [A]", focused == FOCUS_ADD, CanAdd(), false);
        DrawButton(removeBtnRect, "REMOVE [R]", focused == FOCUS_REMOVE, CanRemove(), false);
        DrawButton(giveBtnRect, "GIVE", focused == FOCUS_GIVE, CanGive(), false);
        DrawButton(dropBtnRect, "DROP", focused == FOCUS_DROP, CanDrop(), false);
        String resetSlotLabel = String.Format("RESET SLOT %d", activeSlot);
        DrawButton(resetSlotBtnRect, resetSlotLabel, focused == FOCUS_RESET_SLOT, true, true);
        DrawButton(resetBtnRect, "RESET ALL", focused == FOCUS_RESET_ALL, true, true);
    }

    void DrawButton(VUWS_HitRect r, String label, bool isFocused, bool enabled, bool useResetColor)
    {
        int hex = useResetColor ? ResolveResetHex() : ResolveAccentHex();
        // Disabled buttons ignore hover so they don't visually invite a click that won't fire
        bool hovered = enabled && r.Contains(mouseX, mouseY);
        bool active = enabled && (isFocused || hovered);

        // Default state runs at lower opacity, hover/focus restores the brighter look
        double bgAlpha     = enabled ? (active ? 0.4 : 0.25) : 0.10;
        double borderAlpha = enabled ? (active ? 0.9 : 0.6)  : 0.30;

        VUWS_SlotConfig.DimVirt(hex, bgAlpha, r.x, r.y, r.w, r.h);

        VUWS_SlotConfig.DimVirt(hex, borderAlpha, r.x, r.y, r.w, 1);
        VUWS_SlotConfig.DimVirt(hex, borderAlpha, r.x, r.y + r.h - 1, r.w, 1);
        VUWS_SlotConfig.DimVirt(hex, borderAlpha, r.x, r.y, 1, r.h);
        VUWS_SlotConfig.DimVirt(hex, borderAlpha, r.x + r.w - 1, r.y, 1, r.h);

        // Label centered
        int textColor = enabled ? Font.CR_WHITE : Font.CR_DARKGRAY;
        int textW = SmallFont.StringWidth(label);
        int textX = r.x + (r.w - textW) / 2;
        int textY = r.y + (r.h - SmallFont.GetHeight()) / 2;
        Screen.DrawText(SmallFont, textColor, textX, textY, label,
            DTA_VirtualWidth, VUWS_SlotConfig.VIRT_W,
            DTA_VirtualHeight, VUWS_SlotConfig.VIRT_H,
            DTA_KeepRatio, true);
    }

    // ---- Hint bar ----

    void DrawHintBar()
    {
        String line1 = "Choose slot then choose weapon, then ADD.";
        String line2 = "[0-9] Slot   [A] Add   [R] Remove   [Esc/Q] Done";
        int line1X = hintBarRect.x + (hintBarRect.w - SmallFont.StringWidth(line1)) / 2;
        int line2X = hintBarRect.x + (hintBarRect.w - SmallFont.StringWidth(line2)) / 2;
        Screen.DrawText(SmallFont, Font.CR_GRAY,
            line1X, hintBarRect.y, line1,
            DTA_VirtualWidth, VUWS_SlotConfig.VIRT_W,
            DTA_VirtualHeight, VUWS_SlotConfig.VIRT_H,
            DTA_KeepRatio, true);
        Screen.DrawText(SmallFont, Font.CR_DARKGRAY,
            line2X, hintBarRect.y + 12, line2,
            DTA_VirtualWidth, VUWS_SlotConfig.VIRT_W,
            DTA_VirtualHeight, VUWS_SlotConfig.VIRT_H,
            DTA_KeepRatio, true);
    }

    // ---- Action helpers ----

    // interactive when user-mapped, read-only signage when showing engine fallback
    bool TopListInteractive()
    {
        if (topWeapons.Size() == 0) return false;
        if (topIsDefault.Size() > 0 && topIsDefault[0] == 1) return false;
        return true;
    }

    bool CanAdd()
    {
        // Add: there's a selected weapon FROM the bottom list (all weapons)
        // Top-list selections are already in the active slot, Add doesn't make sense there
        if (selectedSource != 1 || selectedIdx < 0 || selectedIdx >= allWeapons.Size())
            return false;

        // disable if already user-mapped to active slot (no-op)
        // engine-default rows still allow Add (converts slot to user-managed)
        class<Weapon> wc = allWeapons[selectedIdx];
        let handler = VUWS_SlotHandler.GetHandler();
        if (handler)
        {
            Array<class<Weapon> > userList;
            handler.ReadUserSlot(activeSlot, players[consoleplayer], userList);
            if (userList.Find(wc) < userList.Size()) return false;
        }
        return true;
    }

    bool CanRemove()
    {
        // enabled when selected weapon is user-mapped to activeSlot (top OR bot list)
        if (selectedSource == 0)
        {
            if (selectedIdx < 0 || selectedIdx >= topWeapons.Size()) return false;
            if (selectedIdx < topIsDefault.Size() && topIsDefault[selectedIdx] == 1) return false;
            return true;
        }
        if (selectedSource == 1)
        {
            if (selectedIdx < 0 || selectedIdx >= allWeapons.Size()) return false;
            class<Weapon> wc = allWeapons[selectedIdx];
            let handler = VUWS_SlotHandler.GetHandler();
            if (!handler) return false;
            Array<class<Weapon> > userList;
            handler.ReadUserSlot(activeSlot, players[consoleplayer], userList);
            return userList.Find(wc) < userList.Size();
        }
        return false;
    }

    // selected class from either list, UI scope reads selectedSource/selectedIdx
    class<Weapon> SelectedWeaponClass()
    {
        if (selectedSource == 0 && selectedIdx >= 0 && selectedIdx < topWeapons.Size())
            return topWeapons[selectedIdx];
        if (selectedSource == 1 && selectedIdx >= 0 && selectedIdx < allWeapons.Size())
            return allWeapons[selectedIdx];
        return null;
    }

    bool CanGive()
    {
        // GIVE: selected + not owned + target slot under cap
        // target = user mapping else engine slot else uncapped
        class<Weapon> wc = SelectedWeaponClass();
        if (!wc) return false;
        if (consoleplayer < 0 || !players[consoleplayer].mo) return false;
        if (players[consoleplayer].mo.FindInventory(wc)) return false;

        let handler = VUWS_SlotHandler.GetHandler();
        if (!handler) return false;

        int targetSlot = handler.ResolveSlotForClass(players[consoleplayer], wc);
        if (targetSlot < 0) return true; // no slot, no cap to enforce

        int cap = VUWS_SlotHandler.GetCVarSlotCap(targetSlot, players[consoleplayer]);
        if (cap >= 999) return true; // unlimited
        int count = handler.CountSlotOccupantsForUI(players[consoleplayer].mo, targetSlot);
        return count < cap;
    }

    bool CanDrop()
    {
        // mirror CreateTossable rules so button disables when DropInventory would no-op
        // (vanilla Fist/Pistol have no SpawnState)
        class<Weapon> wc = SelectedWeaponClass();
        if (!wc) return false;
        if (consoleplayer < 0 || !players[consoleplayer].mo) return false;
        let inv = players[consoleplayer].mo.FindInventory(wc);
        if (!inv) return false;
        if (inv.bUndroppable || inv.bUntossable) return false;

        let actorDefault = GetDefaultByType("Actor");
        if (!inv.SpawnState) return false;
        if (actorDefault && inv.SpawnState == actorDefault.SpawnState) return false;

        // Slot 0 + unlimited = always-available utility class (BD HandGrenades etc)
        // Engine drop technically works but mods ammo-merge so user sees no effect
        int wSlot = VUWS_SlotHandler.LocateWeaponSlot(players[consoleplayer], wc);
        if (wSlot == 0)
        {
            let unlimCV = CVar.GetCVar('vuws_unlimited_for_slot_0', players[consoleplayer]);
            if (unlimCV && unlimCV.GetBool()) return false;
        }
        return true;
    }

    // keep selected row in view after rebuild reshuffles display order
    void EnsureSelectedVisible()
    {
        if (selectedSource == 1 && selectedIdx >= 0 && selectedIdx < allWeapons.Size())
        {
            int displayRow = botDisplayOrder.Find(selectedIdx);
            if (displayRow < botDisplayOrder.Size())
            {
                botCursor = displayRow;
                botPane.EnsureRowVisible(displayRow);
            }
        }
        else if (selectedSource == 0 && selectedIdx >= 0 && selectedIdx < topWeapons.Size())
        {
            topCursor = selectedIdx;
            topPane.EnsureRowVisible(selectedIdx);
        }
    }

    void DoAdd()
    {
        if (!CanAdd()) return;
        // CanAdd guarantees selectedSource == 1 and a valid bottom-list index
        class<Weapon> wc = allWeapons[selectedIdx];
        if (!wc) return;

        EventHandler.SendNetworkEvent("vuws_add_to_slot", activeSlot, selectedIdx, 0);
        PlayUISound("menu/choose");

        BuildAllWeaponsList();
        BuildTopList();
        pendingScrollFollowTic = gametic;
    }

    void DoRemove()
    {
        if (!CanRemove()) return;
        // Resolve the weapon class regardless of which list the user selected from
        class<Weapon> wc = SelectedWeaponClass();
        if (!wc) return;

        // Use the all-weapons list for index-based dispatch (handler rebuilds the same list)
        int idx = allWeapons.Find(wc);
        if (idx >= allWeapons.Size()) return;

        EventHandler.SendNetworkEvent("vuws_remove_from_slot", activeSlot, idx, 0);
        PlayUISound("menu/choose");

        BuildAllWeaponsList();
        BuildTopList();
        pendingScrollFollowTic = gametic;
    }

    void DoGive()
    {
        if (!CanGive()) return;
        class<Weapon> wc = SelectedWeaponClass();
        if (!wc) return;
        // index dispatch, handler rebuilds same list server-side
        int idx = allWeapons.Find(wc);
        if (idx >= allWeapons.Size()) return;
        EventHandler.SendNetworkEvent("vuws_give_weapon", 0, idx, 0);
        PlayUISound("misc/w_pkup");

        BuildAllWeaponsList();
        BuildTopList();
        pendingScrollFollowTic = gametic;
    }

    void DoDrop()
    {
        if (!CanDrop()) return;
        class<Weapon> wc = SelectedWeaponClass();
        if (!wc) return;
        int idx = allWeapons.Find(wc);
        if (idx >= allWeapons.Size()) return;
        EventHandler.SendNetworkEvent("vuws_drop_weapon", 0, idx, 0);
        PlayUISound("menu/choose");

        BuildAllWeaponsList();
        BuildTopList();
        pendingScrollFollowTic = gametic;
    }

    void DoReset()
    {
        EventHandler.SendNetworkEvent("vuws_clear_user_slots", 0, 0, 0);
        PlayUISound("menu/choose");

        BuildAllWeaponsList();
        BuildTopList();
        pendingScrollFollowTic = gametic;
    }

    void DoResetSlot()
    {
        EventHandler.SendNetworkEvent("vuws_clear_user_slot", activeSlot, 0, 0);
        PlayUISound("menu/choose");

        BuildAllWeaponsList();
        BuildTopList();
        pendingScrollFollowTic = gametic;
    }

    // ---- Mouse / keyboard ----

    override bool OnUIEvent(UIEvent ev)
    {
        // mouseX/Y stored in virtual coords, convert once at event entry
        if (ev.Type == UIEvent.Type_MouseMove)
        {
            mouseX = (ev.MouseX * VUWS_SlotConfig.VIRT_W) / Screen.GetWidth();
            mouseY = (ev.MouseY * VUWS_SlotConfig.VIRT_H) / Screen.GetHeight();

            // hover state-change detection, only fires sound when key changes (not every frame)
            int hk = ComputeHoverKey(mouseX, mouseY);
            if (hk != 0 && hk != lastHoverKey) PlayUISound("menu/cursor");
            lastHoverKey = hk;

            return Super.OnUIEvent(ev);
        }

        if (ev.Type == UIEvent.Type_LButtonDown)
        {
            mouseX = (ev.MouseX * VUWS_SlotConfig.VIRT_W) / Screen.GetWidth();
            mouseY = (ev.MouseY * VUWS_SlotConfig.VIRT_H) / Screen.GetHeight();
            int virtMx = mouseX;
            int virtMy = mouseY;

            // Check buttons first
            if (addBtnRect.Contains(virtMx, virtMy)) { DoAdd(); return true; }
            if (removeBtnRect.Contains(virtMx, virtMy)) { DoRemove(); return true; }
            if (giveBtnRect.Contains(virtMx, virtMy)) { DoGive(); return true; }
            if (dropBtnRect.Contains(virtMx, virtMy)) { DoDrop(); return true; }
            if (resetSlotBtnRect.Contains(virtMx, virtMy)) { DoResetSlot(); return true; }
            if (resetBtnRect.Contains(virtMx, virtMy)) { DoReset(); return true; }

            // visual order 1..9,0 maps row -> slot via (i+1)%10
            // selection persists across slot switches
            for (int i = 0; i < slotRowRects.Size(); i++)
            {
                if (slotRowRects[i].Contains(virtMx, virtMy))
                {
                    ChangeActiveSlot((i + 1) % 10);
                    focused = FOCUS_SLOTS;
                    PlayUISound("menu/choose");
                    return true;
                }
            }

            // Top list rows - clicking the same row again toggles off the selection
            for (int i = 0; i < topRowRects.Size(); i++)
            {
                if (topRowRects[i].Contains(virtMx, virtMy))
                {
                    if (selectedSource == 0 && selectedIdx == i)
                    {
                        selectedSource = -1;
                        selectedIdx = -1;
                        selectedClass = null;
                    }
                    else
                    {
                        selectedSource = 0;
                        selectedIdx = i;
                        selectedClass = (i < topWeapons.Size()) ? topWeapons[i] : null;
                        topCursor = i;
                    }
                    focused = FOCUS_TOPLIST;
                    PlayUISound("menu/choose");
                    return true;
                }
            }

            // bot row index = display row, data index via botDisplayOrder
            // click same row toggles off
            for (int row = 0; row < botRowRects.Size(); row++)
            {
                if (botRowRects[row].Contains(virtMx, virtMy))
                {
                    int dataIdx = (row < botDisplayOrder.Size()) ? botDisplayOrder[row] : row;
                    if (selectedSource == 1 && selectedIdx == dataIdx)
                    {
                        selectedSource = -1;
                        selectedIdx = -1;
                        selectedClass = null;
                    }
                    else
                    {
                        selectedSource = 1;
                        selectedIdx = dataIdx;
                        selectedClass = (dataIdx < allWeapons.Size()) ? allWeapons[dataIdx] : null;
                        botCursor = row;
                    }
                    focused = FOCUS_BOTLIST;
                    PlayUISound("menu/choose");
                    return true;
                }
            }

            // Click outside the menu frame closes the menu (same as Esc / Q)
            int frameX = VUWS_SlotConfig.PAGE_MARGIN_X - 8;
            int frameY = VUWS_SlotConfig.PAGE_MARGIN_TOP - 8;
            int frameW = VUWS_SlotConfig.VIRT_W - 2 * VUWS_SlotConfig.PAGE_MARGIN_X + 16;
            int frameH = VUWS_SlotConfig.VIRT_H
                - VUWS_SlotConfig.PAGE_MARGIN_TOP
                - VUWS_SlotConfig.PAGE_MARGIN_BOTTOM + 16;
            if (virtMx < frameX || virtMx > frameX + frameW
                || virtMy < frameY || virtMy > frameY + frameH)
            {
                PlayUISound("menu/dismiss");
                Close();
                return true;
            }

            return Super.OnUIEvent(ev);
        }

        if (ev.Type == UIEvent.Type_WheelUp || ev.Type == UIEvent.Type_WheelDown)
        {
            // GZDoom 4.14.2 wheel events have ev.MouseX/Y == 0, use cached MouseMove pos
            int dir = (ev.Type == UIEvent.Type_WheelUp) ? -1 : 1;
            VUWS_ScrollPane target;
            if (topPaneRect.Contains(mouseX, mouseY)) target = topPane;
            else target = botPane;
            target.ScrollBy(dir * target.rowHeight);
            return true;
        }

        if (ev.Type == UIEvent.Type_KeyDown)
        {
            int kc = ev.KeyChar;
            // Lowercase normalization for letter keys
            int kcLow = kc;
            if (kcLow >= 65 && kcLow <= 90) kcLow += 32;

            // Press the bound toggle key again to close (Q by default)
            if (toggleAsciiCode >= 0 && kcLow == toggleAsciiCode)
            {
                PlayUISound("menu/dismiss");
                Close();
                return true;
            }
            // Press the exclude-menu key to switch directly to the exclude editor
            // Close() before SetMenu so we swap rather than stack (one Esc always exits)
            if (excludeAsciiCode >= 0 && kcLow == excludeAsciiCode)
            {
                PlayUISound("menu/activate");
                Close();
                Menu.SetMenu("VUWS_ExcludeListMenu");
                return true;
            }

            // 0-9 select slot - bot-list selection persists, top-list cleared (slot mismatch)
            if (kc >= 48 && kc <= 57)
            {
                ChangeActiveSlot(kc - 48);
                focused = FOCUS_SLOTS;
                return true;
            }
            // A or a = Add
            if (kc == 65 || kc == 97) { DoAdd(); return true; }
            // R or r = Remove
            if (kc == 82 || kc == 114) { DoRemove(); return true; }
        }
        return Super.OnUIEvent(ev);
    }

    // wrap slot, rebuild top list, invalidate stale selectedIdx
    void ChangeActiveSlot(int newSlot)
    {
        activeSlot = (newSlot + 10) % 10;
        if (selectedSource == 0)
        {
            selectedSource = -1;
            selectedIdx = -1;
            selectedClass = null;
        }
        BuildTopList();
    }

    // right-pane button focus, Up/Down navigates the button stack
    bool FocusedOnButton()
    {
        return focused == FOCUS_ADD || focused == FOCUS_REMOVE
            || focused == FOCUS_GIVE || focused == FOCUS_DROP
            || focused == FOCUS_RESET_SLOT || focused == FOCUS_RESET_ALL;
    }

    // Right-pane buttons in their visual stack order, top to bottom
    int, int ButtonStackOrder(int idx)
    {
        // Returns (focusValue, total)
        if (idx == 0) return FOCUS_ADD, 6;
        if (idx == 1) return FOCUS_REMOVE, 6;
        if (idx == 2) return FOCUS_GIVE, 6;
        if (idx == 3) return FOCUS_DROP, 6;
        if (idx == 4) return FOCUS_RESET_SLOT, 6;
        return FOCUS_RESET_ALL, 6;
    }

    int ButtonIndex(int focusValue)
    {
        if (focusValue == FOCUS_ADD) return 0;
        if (focusValue == FOCUS_REMOVE) return 1;
        if (focusValue == FOCUS_GIVE) return 2;
        if (focusValue == FOCUS_DROP) return 3;
        if (focusValue == FOCUS_RESET_SLOT) return 4;
        if (focusValue == FOCUS_RESET_ALL) return 5;
        return -1;
    }

    bool IsButtonEnabled(int focusValue)
    {
        if (focusValue == FOCUS_ADD) return CanAdd();
        if (focusValue == FOCUS_REMOVE) return CanRemove();
        if (focusValue == FOCUS_GIVE) return CanGive();
        if (focusValue == FOCUS_DROP) return CanDrop();
        if (focusValue == FOCUS_RESET_SLOT) return true;
        if (focusValue == FOCUS_RESET_ALL) return true;
        return false;
    }

    // next enabled button in stack, wraps; -1 if none
    int NextEnabledButton(int fromIdx, int dir)
    {
        for (int step = 1; step <= 6; step++)
        {
            int idx = (fromIdx + dir * step + 6) % 6;
            int focusValue, total;
            [focusValue, total] = ButtonStackOrder(idx);
            if (IsButtonEnabled(focusValue)) return focusValue;
        }
        return -1;
    }

    override bool MenuEvent(int mkey, bool fromcontroller)
    {
        switch (mkey)
        {
        case MKEY_Up:
            if (focused == FOCUS_SLOTS)
            {
                ChangeActiveSlot(activeSlot - 1);
                return true;
            }
            if (focused == FOCUS_TOPLIST && TopListInteractive())
            {
                topCursor--;
                if (topCursor < 0) topCursor = topWeapons.Size() - 1;
                topPane.EnsureRowVisible(topCursor);
                return true;
            }
            if (focused == FOCUS_BOTLIST && botDisplayOrder.Size() > 0)
            {
                botCursor--;
                if (botCursor < 0) botCursor = botDisplayOrder.Size() - 1;
                botPane.EnsureRowVisible(botCursor);
                return true;
            }
            if (FocusedOnButton())
            {
                int idx = ButtonIndex(focused);
                int next = NextEnabledButton(idx, -1);
                if (next >= 0) focused = next;
                return true;
            }
            break;
        case MKEY_Down:
            if (focused == FOCUS_SLOTS)
            {
                ChangeActiveSlot(activeSlot + 1);
                return true;
            }
            if (focused == FOCUS_TOPLIST && TopListInteractive())
            {
                topCursor++;
                if (topCursor >= topWeapons.Size()) topCursor = 0;
                topPane.EnsureRowVisible(topCursor);
                return true;
            }
            if (focused == FOCUS_BOTLIST && botDisplayOrder.Size() > 0)
            {
                botCursor++;
                if (botCursor >= botDisplayOrder.Size()) botCursor = 0;
                botPane.EnsureRowVisible(botCursor);
                return true;
            }
            if (FocusedOnButton())
            {
                int idx = ButtonIndex(focused);
                int next = NextEnabledButton(idx, 1);
                if (next >= 0) focused = next;
                return true;
            }
            break;
        case MKEY_Left:
        case MKEY_Right:
            // Left/Right cycles slots/top/bot/buttons-group, Up/Down nav within buttons
            bool skipTop = !TopListInteractive();
            // entering buttons group lands on the first enabled button, not necessarily ADD
            int firstEnabled = NextEnabledButton(-1, 1);
            int btnEntry = (firstEnabled >= 0) ? firstEnabled : FOCUS_ADD;
            if (mkey == MKEY_Right)
            {
                if (focused == FOCUS_SLOTS) focused = FOCUS_BOTLIST;
                else if (focused == FOCUS_TOPLIST) focused = FOCUS_BOTLIST;
                else if (focused == FOCUS_BOTLIST) focused = btnEntry;
                else if (FocusedOnButton()) focused = FOCUS_SLOTS;
            }
            else
            {
                if (focused == FOCUS_SLOTS) focused = btnEntry;
                else if (FocusedOnButton()) focused = FOCUS_BOTLIST;
                else if (focused == FOCUS_BOTLIST) focused = skipTop ? FOCUS_SLOTS : FOCUS_TOPLIST;
                else if (focused == FOCUS_TOPLIST) focused = FOCUS_SLOTS;
            }
            return true;
        case MKEY_Enter:
            if (focused == FOCUS_TOPLIST && TopListInteractive()
                && topCursor >= 0 && topCursor < topWeapons.Size())
            {
                selectedSource = 0; selectedIdx = topCursor;
                selectedClass = topWeapons[topCursor];
                return true;
            }
            if (focused == FOCUS_BOTLIST && botCursor >= 0 && botCursor < botDisplayOrder.Size())
            {
                selectedSource = 1;
                selectedIdx = botDisplayOrder[botCursor];
                selectedClass = (selectedIdx < allWeapons.Size()) ? allWeapons[selectedIdx] : null;
                return true;
            }
            if (focused == FOCUS_ADD) { DoAdd(); return true; }
            if (focused == FOCUS_REMOVE) { DoRemove(); return true; }
            if (focused == FOCUS_GIVE) { DoGive(); return true; }
            if (focused == FOCUS_DROP) { DoDrop(); return true; }
            if (focused == FOCUS_RESET_SLOT) { DoResetSlot(); return true; }
            if (focused == FOCUS_RESET_ALL) { DoReset(); return true; }
            // From slots, Enter jumps to bottom list
            if (focused == FOCUS_SLOTS) { focused = FOCUS_BOTLIST; return true; }
            break;
        case MKEY_Back:
            PlayUISound("menu/dismiss");
            Close();
            return true;
        }
        return Super.MenuEvent(mkey, fromcontroller);
    }

    int ResolveAccentHex()
    {
        let cv = CVar.GetCVar('vuws_color_menu_accent', players[consoleplayer]);
        int idx = cv ? cv.GetInt() : 10;
        return VUWS_RenderSettings.GetColorHex(idx);
    }

    int ResolveResetHex()
    {
        let cv = CVar.GetCVar('vuws_color_menu_reset', players[consoleplayer]);
        int idx = cv ? cv.GetInt() : 6;
        return VUWS_RenderSettings.GetColorHex(idx);
    }
}
