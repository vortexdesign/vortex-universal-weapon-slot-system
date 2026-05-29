// ExcludeListMenu.zs
// Single scrollable pane with checkbox-per-weapon-class
// Iterates AllActorClasses for Weapon subclasses so user can pre-emptively exclude
// classes they don't currently own (akimbo classes etc.)

class VUWS_ExcludeListMenu : GenericMenu
{
    // All weapon classes registered in the game, sorted by tag
    Array<class<Weapon> > weaponClasses;
    Array<bool> excludedFlags;          // Parallel: current checkbox state
    Array<TextureID> iconCache;
    Array<String> nameCache;
    Array<String> classNameCache;       // Underlying class name (for CSV write)

    int cursor;
    int mouseX;
    int mouseY;

    // toggle keybind ASCII codes (resolved in Init)
    // exclude key closes, slot editor key swaps to slot editor
    int excludeAsciiCode;
    int slotEditorAsciiCode;

    VUWS_ScrollPane pane;

    VUWS_HitRect listRect;
    VUWS_HitRect hintRect;
    Array<VUWS_HitRect> rowRects;

    // hover state-change detection, fires menu/cursor only on row change
    int lastHoverKey;

    // truncate with ".." if width exceeds maxWidth
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

    // gate menu sound playback behind vuws_sound_enabled (mirrors SlotEditorMenu helper)
    static void PlayUISound(Name snd)
    {
        let cv = CVar.FindCVar('vuws_sound_enabled');
        if (cv && !cv.GetBool()) return;
        MenuSound(snd);
    }

    // Convert keyboard scancode to lowercase ASCII (mirrors SlotEditorMenu's helper)
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

    override void Init(Menu parent)
    {
        Super.Init(parent);
        cursor = 0;
        mouseX = 0;
        mouseY = 0;
        lastHoverKey = 0;
        pane = VUWS_ScrollPane(new("VUWS_ScrollPane"));

        excludeAsciiCode = -1;
        slotEditorAsciiCode = -1;
        int k1, k2;
        [k1, k2] = Bindings.GetKeysForCommand("vuws_exclude_menu");
        if (k1 > 0) excludeAsciiCode = ScancodeToAscii(k1);
        [k1, k2] = Bindings.GetKeysForCommand("vuws_slot_editor");
        if (k1 > 0) slotEditorAsciiCode = ScancodeToAscii(k1);

        BuildClassList();
    }

    void BuildClassList()
    {
        weaponClasses.Clear();
        excludedFlags.Clear();
        iconCache.Clear();
        nameCache.Clear();
        classNameCache.Clear();

        // Read current exclude list to populate checkboxes
        let excludeCV = CVar.GetCVar('vuws_exclude_classes', players[consoleplayer]);
        String currentRaw = excludeCV ? excludeCV.GetString() : "";
        Array<String> currentList;
        if (currentRaw.Length() > 0) currentRaw.Split(currentList, ",");
        for (int i = 0; i < currentList.Size(); i++)
        {
            String t = currentList[i];
            while (t.Length() > 0 && t.ByteAt(0) == 32) t = t.Mid(1);
            while (t.Length() > 0 && t.ByteAt(t.Length() - 1) == 32) t = t.Left(t.Length() - 1);
            currentList[i] = t;
        }

        // source from BuildSlotMenuWeapons (matches All Weapons list scope)
        // includeExcluded=true so excluded classes can still be un-checked
        let handler = VUWS_SlotHandler.GetHandler();
        if (!handler || consoleplayer < 0 || !players[consoleplayer].mo)
        {
            pane.SetContentHeight(0);
            return;
        }

        Array<class<Weapon> > sourceList;
        handler.BuildSlotMenuWeapons(players[consoleplayer].mo, sourceList, true);

        // sort by engine slot asc, unregistered = slot 100 sinks to bottom
        int n = sourceList.Size();
        for (int i = 0; i < n - 1; i++)
        {
            for (int j = 0; j < n - 1 - i; j++)
            {
                int slotA = VUWS_SlotHandler.LocateWeaponSlot(players[consoleplayer], sourceList[j]);
                int slotB = VUWS_SlotHandler.LocateWeaponSlot(players[consoleplayer], sourceList[j + 1]);
                int a = slotA >= 0 ? slotA : 100;
                int b = slotB >= 0 ? slotB : 100;
                if (a > b)
                {
                    class<Weapon> tmp = sourceList[j];
                    sourceList[j] = sourceList[j + 1];
                    sourceList[j + 1] = tmp;
                }
            }
        }

        for (int i = 0; i < sourceList.Size(); i++)
        {
            class<Weapon> wc = sourceList[i];
            if (!wc) continue;
            String cn = wc.GetClassName();

            // mirror SlotEditorMenu: GetTag (owned inv first, else defaults), fall back to class name
            String tag = "";
            let inv = players[consoleplayer].mo.FindInventory(wc);
            let w = inv ? Weapon(inv) : null;
            if (w) tag = w.GetTag();
            else
            {
                let defs = Weapon(GetDefaultByType(wc));
                if (defs) tag = defs.GetTag();
            }
            if (tag.Length() == 0) tag = cn;

            weaponClasses.Push(wc);
            classNameCache.Push(cn);
            nameCache.Push(tag);

            TextureID empty;
            iconCache.Push(empty);

            bool excluded = false;
            for (int j = 0; j < currentList.Size(); j++)
            {
                if (currentList[j] ~== cn) { excluded = true; break; }
            }
            excludedFlags.Push(excluded);
        }

        // duplicate-name disambiguation matches All Weapons list
        VUWS_SlotHandler.DisambiguateDuplicateNames(nameCache, weaponClasses);

        pane.SetContentHeight(weaponClasses.Size() * VUWS_SlotConfig.ROW_HEIGHT);
    }

    override void Drawer()
    {
        // No whole-screen dim, the content panel below provides its own background
        ComputeLayout();

        String titleStr = "Exclude From Weapon Slot Editor";
        int titleW = BigFont.StringWidth(titleStr);
        int titleX = (VUWS_SlotConfig.VIRT_W - titleW) / 2;
        Screen.DrawText(BigFont, Font.CR_GOLD,
            titleX, VUWS_SlotConfig.PAGE_MARGIN_TOP - 24,
            titleStr,
            DTA_VirtualWidth, VUWS_SlotConfig.VIRT_W,
            DTA_VirtualHeight, VUWS_SlotConfig.VIRT_H,
            DTA_KeepRatio, true);

        DrawList();
        DrawHint();
    }

    void ComputeLayout()
    {
        if (!listRect) listRect = new("VUWS_HitRect");
        if (!hintRect) hintRect = new("VUWS_HitRect");

        listRect.x = VUWS_SlotConfig.PAGE_MARGIN_X;
        listRect.y = VUWS_SlotConfig.PAGE_MARGIN_TOP + VUWS_SlotConfig.TITLE_HEIGHT;
        listRect.w = VUWS_SlotConfig.VIRT_W - 2 * VUWS_SlotConfig.PAGE_MARGIN_X;
        listRect.h = VUWS_SlotConfig.VIRT_H
            - VUWS_SlotConfig.PAGE_MARGIN_TOP - VUWS_SlotConfig.TITLE_HEIGHT
            - VUWS_SlotConfig.PAGE_MARGIN_BOTTOM - VUWS_SlotConfig.HINT_HEIGHT;

        pane.viewportX = listRect.x;
        pane.viewportY = listRect.y;
        pane.viewportW = listRect.w;
        pane.viewportH = listRect.h;
        pane.rowHeight = VUWS_SlotConfig.ROW_HEIGHT;
        // recompute scrollMax now that viewportH is real (Init ran before sizing)
        pane.SetContentHeight(weaponClasses.Size() * VUWS_SlotConfig.ROW_HEIGHT);

        hintRect.x = VUWS_SlotConfig.PAGE_MARGIN_X;
        hintRect.y = listRect.y + listRect.h + VUWS_SlotConfig.PAGE_MARGIN_BOTTOM;
        hintRect.w = listRect.w;
        hintRect.h = VUWS_SlotConfig.HINT_HEIGHT;
    }

    void DrawList()
    {
        VUWS_SlotConfig.DimVirt(0x101010, 0.5, listRect.x, listRect.y, listRect.w, listRect.h);

        rowRects.Clear();

        if (weaponClasses.Size() == 0)
        {
            Screen.DrawText(SmallFont, Font.CR_DARKGRAY,
                listRect.x + 8, listRect.y + 16, "(no weapon classes registered)",
                DTA_VirtualWidth, VUWS_SlotConfig.VIRT_W,
                DTA_VirtualHeight, VUWS_SlotConfig.VIRT_H,
                DTA_KeepRatio, true);
            return;
        }

        for (int i = 0; i < weaponClasses.Size(); i++)
        {
            int rowY = listRect.y + i * VUWS_SlotConfig.ROW_HEIGHT - pane.scrollOffset;

            let r = VUWS_HitRect.Create(
                listRect.x + 4,
                rowY,
                listRect.w - 8 - VUWS_SlotConfig.SCROLLBAR_WIDTH,
                VUWS_SlotConfig.ROW_HEIGHT);
            rowRects.Push(r);

            if (rowY + VUWS_SlotConfig.ROW_HEIGHT < listRect.y) continue;
            if (rowY > listRect.y + listRect.h) continue;

            DrawCheckRow(i, r);
        }

        DrawScrollbar();
    }

    void DrawCheckRow(int idx, VUWS_HitRect r)
    {
        bool focused = (cursor == idx);
        bool hovered = r.Contains(mouseX, mouseY);

        if (focused || hovered)
        {
            int hex = ResolveAccentHex();
            VUWS_SlotConfig.DimVirt(hex, 0.25, r.x, r.y, r.w, r.h);
        }

        // Checkbox: just a filled or hollow rectangle to the left of the text
        int cbSize = 16;
        int cbX = r.x + 6;
        int cbY = r.y + (r.h - cbSize) / 2;

        // Outline (4 thin sides via DimVirt for virtual->actual coord scaling)
        int hexAccent = ResolveAccentHex();
        VUWS_SlotConfig.DimVirt(0x808080, 0.8, cbX, cbY, cbSize, 1);
        VUWS_SlotConfig.DimVirt(0x808080, 0.8, cbX, cbY + cbSize - 1, cbSize, 1);
        VUWS_SlotConfig.DimVirt(0x808080, 0.8, cbX, cbY, 1, cbSize);
        VUWS_SlotConfig.DimVirt(0x808080, 0.8, cbX + cbSize - 1, cbY, 1, cbSize);

        if (excludedFlags[idx])
        {
            VUWS_SlotConfig.DimVirt(hexAccent, 0.85, cbX + 3, cbY + 3, cbSize - 6, cbSize - 6);
        }

        // Class name
        int textX = cbX + cbSize + 8;
        int textY = r.y + (r.h - SmallFont.GetHeight()) / 2;
        int rowRight = r.x + r.w;
        int availW = rowRight - textX - 4;
        String displayName = FitText(nameCache[idx], SmallFont, availW);
        Screen.DrawText(SmallFont, Font.CR_WHITE, textX, textY, displayName,
            DTA_VirtualWidth, VUWS_SlotConfig.VIRT_W,
            DTA_VirtualHeight, VUWS_SlotConfig.VIRT_H,
            DTA_KeepRatio, true);
    }

    void DrawScrollbar()
    {
        VUWS_HitRect track;
        bool needScroll;
        [track, needScroll] = pane.ScrollbarTrackRect(VUWS_SlotConfig.SCROLLBAR_WIDTH);
        VUWS_SlotConfig.DimVirt(0x202020, 0.6, track.x, track.y, track.w, track.h);

        if (needScroll)
        {
            let thumb = pane.ThumbRect(VUWS_SlotConfig.SCROLLBAR_WIDTH);
            int hex = ResolveAccentHex();
            VUWS_SlotConfig.DimVirt(hex, 0.7, thumb.x, thumb.y, thumb.w, thumb.h);
        }
    }

    void DrawHint()
    {
        Screen.DrawText(SmallFont, Font.CR_DARKGRAY,
            hintRect.x, hintRect.y,
            "[Click / Enter] Toggle  [Up/Down] Navigate  [Esc] Save and Close",
            DTA_VirtualWidth, VUWS_SlotConfig.VIRT_W,
            DTA_VirtualHeight, VUWS_SlotConfig.VIRT_H,
            DTA_KeepRatio, true);
    }

    int ResolveAccentHex()
    {
        let cv = CVar.GetCVar('vuws_color_menu_accent', players[consoleplayer]);
        int idx = cv ? cv.GetInt() : 10;
        return VUWS_RenderSettings.GetColorHex(idx);
    }

    // ---- Input ----

    override bool OnUIEvent(UIEvent ev)
    {
        // store mouse in virtual coords so hit-tests skip per-call conversion
        if (ev.Type == UIEvent.Type_MouseMove)
        {
            mouseX = (ev.MouseX * VUWS_SlotConfig.VIRT_W) / Screen.GetWidth();
            mouseY = (ev.MouseY * VUWS_SlotConfig.VIRT_H) / Screen.GetHeight();

            // hover state-change detection, fires only when the row under cursor changes
            int hk = 0;
            for (int i = 0; i < rowRects.Size(); i++)
            {
                if (rowRects[i].Contains(mouseX, mouseY)) { hk = 100 + i; break; }
            }
            if (hk != 0 && hk != lastHoverKey) PlayUISound("menu/cursor");
            lastHoverKey = hk;

            return Super.OnUIEvent(ev);
        }
        if (ev.Type == UIEvent.Type_LButtonDown)
        {
            mouseX = (ev.MouseX * VUWS_SlotConfig.VIRT_W) / Screen.GetWidth();
            mouseY = (ev.MouseY * VUWS_SlotConfig.VIRT_H) / Screen.GetHeight();
            for (int i = 0; i < rowRects.Size(); i++)
            {
                if (rowRects[i].Contains(mouseX, mouseY))
                {
                    cursor = i;
                    excludedFlags[i] = !excludedFlags[i];
                    PlayUISound("menu/choose");
                    return true;
                }
            }

            // click outside frame = close (commit runs from OnDestroy)
            int frameX = VUWS_SlotConfig.PAGE_MARGIN_X - 8;
            int frameY = VUWS_SlotConfig.PAGE_MARGIN_TOP - 8;
            int frameW = VUWS_SlotConfig.VIRT_W - 2 * VUWS_SlotConfig.PAGE_MARGIN_X + 16;
            int frameH = VUWS_SlotConfig.VIRT_H
                - VUWS_SlotConfig.PAGE_MARGIN_TOP
                - VUWS_SlotConfig.PAGE_MARGIN_BOTTOM + 16;
            if (mouseX < frameX || mouseX > frameX + frameW
                || mouseY < frameY || mouseY > frameY + frameH)
            {
                PlayUISound("menu/dismiss");
                Close();
                return true;
            }

            return Super.OnUIEvent(ev);
        }
        if (ev.Type == UIEvent.Type_WheelUp)
        {
            pane.ScrollBy(-VUWS_SlotConfig.ROW_HEIGHT);
            return true;
        }
        if (ev.Type == UIEvent.Type_WheelDown)
        {
            pane.ScrollBy(VUWS_SlotConfig.ROW_HEIGHT);
            return true;
        }
        if (ev.Type == UIEvent.Type_KeyDown)
        {
            int kc = ev.KeyChar;
            int kcLow = (kc >= 65 && kc <= 90) ? kc + 32 : kc;

            // Slot editor key: commit current edits and switch to the slot editor
            if (slotEditorAsciiCode >= 0 && kcLow == slotEditorAsciiCode)
            {
                PlayUISound("menu/activate");
                CommitAndClose();
                Menu.SetMenu("VUWS_SlotEditorMenu");
                return true;
            }
            // Exclude key: commit current edits and close (back to game)
            if (excludeAsciiCode >= 0 && kcLow == excludeAsciiCode)
            {
                PlayUISound("menu/dismiss");
                CommitAndClose();
                return true;
            }
        }
        return Super.OnUIEvent(ev);
    }

    override bool MenuEvent(int mkey, bool fromcontroller)
    {
        switch (mkey)
        {
        case MKEY_Up:
            if (weaponClasses.Size() > 0)
            {
                cursor--;
                if (cursor < 0) cursor = weaponClasses.Size() - 1;
                pane.EnsureRowVisible(cursor);
                return true;
            }
            break;
        case MKEY_Down:
            if (weaponClasses.Size() > 0)
            {
                cursor++;
                if (cursor >= weaponClasses.Size()) cursor = 0;
                pane.EnsureRowVisible(cursor);
                return true;
            }
            break;
        case MKEY_Enter:
            if (cursor >= 0 && cursor < excludedFlags.Size())
            {
                excludedFlags[cursor] = !excludedFlags[cursor];
                PlayUISound("menu/choose");
                return true;
            }
            break;
        case MKEY_Back:
            PlayUISound("menu/dismiss");
            CommitAndClose();
            return true;
        }
        return Super.MenuEvent(mkey, fromcontroller);
    }

    // OnDestroy is the single commit point so every close path commits exactly once
    override void OnDestroy()
    {
        CommitChanges();
        Super.OnDestroy();
    }

    void CommitAndClose()
    {
        Close();
    }

    void CommitChanges()
    {
        // 240-char cap, drop trailing entries past INI line limit
        uint MAX_LEN = 240;
        String csv = "";
        int dropped = 0;
        for (int i = 0; i < weaponClasses.Size(); i++)
        {
            if (!excludedFlags[i]) continue;
            String entry = classNameCache[i];
            int added = entry.Length() + (csv.Length() > 0 ? 1 : 0);
            if (csv.Length() + added > MAX_LEN) { dropped++; continue; }
            if (csv.Length() > 0) csv.AppendFormat(",");
            csv.AppendFormat("%s", entry);
        }
        if (dropped > 0)
            Console.Printf("\c[Red]VUWS: exclude list truncated, dropped %d classes past INI length limit\c-", dropped);

        let cv = CVar.GetCVar('vuws_pending_exclude_csv', players[consoleplayer]);
        if (cv) cv.SetString(csv);
        EventHandler.SendNetworkEvent("vuws_set_exclude", 0, 0, 0);
    }
}
