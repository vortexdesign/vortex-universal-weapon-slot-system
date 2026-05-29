// SlotRenderer.zs
// HUD rendering for VUWS
// Three things drawn here:
//   1. Use-key pickup prompt (centered text near bottom of screen)
//   2. Toast queue (block / swap / reassign notifications, slide-fade)
//   3. Current slot HUD (icons for weapons in the active slot)

class VUWS_SlotRenderer : EventHandler
{
    // Per-frame settings cache (refreshed once per RenderOverlay)
    VUWS_RenderSettings settings;

    // one-shot first-frame guard for the slot-key bind hint, ui-scope since the check runs in RenderOverlay
    ui bool slotKeyHintChecked;

    const VIRT_W = 640;
    const VIRT_H = 480;

    override void OnRegister()
    {
        SetOrder(5);
        settings = new("VUWS_RenderSettings");
    }

    // play-scope hooks (WorldLoaded / PlayerSpawned / PlayerRespawned) fire interface events
    // override drops the explicit `ui` since parent already marks it (ZScript rejects rescope)
    override void InterfaceProcess(ConsoleEvent e)
    {
        if (e.Name ~== "vuws_open_slot_editor")
        {
            // skip if any menu is already showing, prevents stacking + respects unrelated menus
            if (Menu.GetCurrentMenu()) return;
            Menu.SetMenu("VUWS_SlotEditorMenu");
        }
    }

    override void RenderOverlay(RenderEvent e)
    {
        let handler = VUWS_SlotHandler.GetHandler();
        if (!handler) return;
        if (handler.suspendedByCompat) return;
        if (handler.cachedEnabledCVar && !handler.cachedEnabledCVar.GetBool()) return;
        if (consoleplayer < 0 || consoleplayer >= MAXPLAYERS) return;
        if (!players[consoleplayer].mo) return;

        if (!settings) return;
        settings.Refresh();

        // hint once per session if 1-9 or mwheel still point at engine slot/cycle
        if (!slotKeyHintChecked)
        {
            slotKeyHintChecked = true;
            int sk1, sk2;
            [sk1, sk2] = Bindings.GetKeysForCommand("vuws_slotk_5");
            if (sk1 == 0 && sk2 == 0)
            {
                Console.Printf("\c[Gold]VUWS:\c- slot keys 0-9 are still bound to the engine. Run \c[Gold]vuws_bind_slot_keys\c- in console so your custom slot assignments take effect.");
            }
            int wk1, wk2;
            [wk1, wk2] = Bindings.GetKeysForCommand("vuws_weapnext");
            if (wk1 == 0 && wk2 == 0)
            {
                Console.Printf("\c[Gold]VUWS:\c- mouse wheel is still bound to engine weapon cycle. Run \c[Gold]vuws_bind_scroll_keys\c- in console so scrolling respects your custom slot assignments.");
            }
        }

        DrawUsePickupPrompt(handler);
        DrawToasts(handler);
        DrawCurrentSlotHud(handler);
    }

    // ---- Use-key pickup prompt ----

    ui void DrawUsePickupPrompt(VUWS_SlotHandler handler)
    {
        if (!settings.usePickupPrompt) return;

        Actor weapActor = handler.useEligibleWeapon[consoleplayer];
        if (!weapActor) return;
        class<Weapon> wc = handler.useEligibleClass[consoleplayer];
        if (!wc) return;

        // Two-line prompt:
        //   Line 1: "Press [usekey] to pick up [Name]"
        //   Line 2: "(replaces [BumpedName] in slot N)"
        String keyName = ResolveUseKeyName();
        String weapName = ResolveDisplayName(wc);

        int slot = handler.useEligibleSlot[consoleplayer];
        class<Weapon> bumped = handler.useEligibleBumpVictim[consoleplayer];

        String bumpedName = "(unknown)";
        if (bumped)
        {
            bumpedName = bumped.GetClassName();
            // Tag-aware display: try to find the inventory instance for a richer name
            if (players[consoleplayer].mo)
            {
                let bumpInv = players[consoleplayer].mo.FindInventory(bumped);
                if (bumpInv && bumpInv.GetTag().Length() > 0)
                    bumpedName = bumpInv.GetTag();
            }
        }

        // Wrap the key name in the menu accent color, then revert to the prompt color
        String accent = VUWS_RenderSettings.GetColorCode(settings.colorMenuAccent);
        String basec  = VUWS_RenderSettings.GetColorCode(settings.colorPickupPrompt);
        String line1 = String.Format("Press %s%s%s to pick up %s", accent, keyName, basec, weapName);
        String line2 = String.Format("(replaces %s in slot %d)", bumpedName, slot);

        if (line1.Length() > 80) line1 = line1.Left(77) .. "...";
        if (line2.Length() > 80) line2 = line2.Left(77) .. "...";

        // centered, 40px above bottom edge, line 2 stacks above line 1
        Font fnt = SmallFont;
        int lineH = fnt.GetHeight();
        int y1 = VIRT_H - 40 - lineH;
        int y2 = y1 - lineH;

        int x1 = (VIRT_W - fnt.StringWidth(line1)) / 2;
        int x2 = (VIRT_W - fnt.StringWidth(line2)) / 2;

        Screen.DrawText(fnt, settings.colorPickupPrompt, x2, y2, line2,
            DTA_VirtualWidth, VIRT_W,
            DTA_VirtualHeight, VIRT_H,
            DTA_KeepRatio, true);
        Screen.DrawText(fnt, settings.colorPickupPrompt, x1, y1, line1,
            DTA_VirtualWidth, VIRT_W,
            DTA_VirtualHeight, VIRT_H,
            DTA_KeepRatio, true);
    }

    // resolve +use bound key, NameKeys injects color escapes between keys so strip
    ui String ResolveUseKeyName()
    {
        int k1, k2;
        [k1, k2] = Bindings.GetKeysForCommand("+use");
        if (k1 <= 0) return "[Use]";

        String raw = KeyBindings.NameKeys(k1, k2);
        return StripColorEscapes(raw);
    }

    // Drop \cX and \c[Name] color escapes from a string
    ui static String StripColorEscapes(String s)
    {
        String result = "";
        int i = 0;
        int n = s.Length();
        while (i < n)
        {
            int c = s.ByteAt(i);
            if (c == 28 /* TEXTCOLOR_ESCAPE */)
            {
                i++;
                if (i < n && s.ByteAt(i) == 91 /* '[' */)
                {
                    while (i < n && s.ByteAt(i) != 93 /* ']' */) i++;
                    if (i < n) i++; // skip ']'
                }
                else if (i < n)
                {
                    i++; // skip the single color char
                }
                continue;
            }
            result = result .. String.Format("%c", c);
            i++;
        }
        return result;
    }

    // class-level Tag lookup so spawner-wrapped weapons (no live instance) still display
    ui String ResolveDisplayName(class<Weapon> wc)
    {
        if (!wc) return "(unknown)";
        readonly<Weapon> def = GetDefaultByType(wc);
        String tag = def ? def.GetTag() : "";
        if (tag.Length() == 0) tag = wc.GetClassName();
        if (tag.Length() > 35) tag = tag.Left(32) .. "...";
        return tag;
    }

    // ---- Toast queue ----

    ui void DrawToasts(VUWS_SlotHandler handler)
    {
        if (!settings.notify) return;
        if (handler.pendingToasts.Size() == 0) return;

        // Find the latest non-expired toast (handler's WorldTick prunes expired entries)
        VUWS_NotifyEntry toast = null;
        for (int i = handler.pendingToasts.Size() - 1; i >= 0; i--)
        {
            if (handler.pendingToasts[i].expireTic > level.time)
            {
                toast = handler.pendingToasts[i];
                break;
            }
        }
        if (!toast) return;
        int remaining = toast.expireTic - level.time;
        int total = settings.notifyDuration;
        if (total <= 0) total = 70;
        double phase = double(remaining) / double(total);
        if (phase < 0.0) phase = 0.0;
        if (phase > 1.0) phase = 1.0;

        // Build the text per kind
        String text = BuildToastText(toast);
        if (text.Length() == 0) return;

        int colorIdx = (toast.kind == VUWS_TOAST_BLOCKED)
            ? settings.colorBlocked : settings.colorSwap;

        // Fade in last quarter, full opacity middle, fade out first quarter
        double alpha = settings.notifyOpacity;
        if (phase < 0.25) alpha *= phase / 0.25;       // fading out (last 25% of life)
        else if (phase > 0.75) alpha *= (1.0 - phase) / 0.25; // fading in (first 25%)
        if (alpha < 0.0) alpha = 0.0;

        Font fnt = SmallFont;
        int textWidth = fnt.StringWidth(text);
        int x = (VIRT_W - textWidth) / 2;
        int y = 80;

        Screen.DrawText(fnt, colorIdx, x, y, text,
            DTA_VirtualWidth, VIRT_W,
            DTA_VirtualHeight, VIRT_H,
            DTA_KeepRatio, true,
            DTA_Alpha, alpha);
    }

    ui String BuildToastText(VUWS_NotifyEntry t)
    {
        String weapName = "(unknown)";
        if (t.weaponClass) weapName = t.weaponClass.GetClassName();
        String bumpedName = "(none)";
        if (t.bumpedClass) bumpedName = t.bumpedClass.GetClassName();

        switch (t.kind)
        {
        case VUWS_TOAST_BLOCKED:
            return String.Format("Slot %d full, can't pick up %s", t.slot, weapName);
        case VUWS_TOAST_SWAPPED:
            return String.Format("Picked up %s, dropped %s from slot %d",
                weapName, bumpedName, t.slot);
        }
        return "";
    }

    // ---- Current Slot HUD ----

    const ICON_BASE = 32;     // virtual px per icon at scale 1.0
    const HUD_MARGIN = 12;    // edge inset for anchored layouts

    ui void DrawCurrentSlotHud(VUWS_SlotHandler handler)
    {
        if (!settings.slotHudEnabled) return;

        let p = players[consoleplayer];
        if (!p || !p.mo) return;
        if (!p.ReadyWeapon) return;

        class<Weapon> readyClass = p.ReadyWeapon.GetClass();

        int slot = handler.ResolveSlotForClass(p, readyClass);
        if (slot < 0) return;

        Array<class<Weapon> > list;
        handler.BuildCurrentSlotEffective(slot, p, list);
        if (list.Size() == 0) return;

        double baseAlpha = settings.slotHudOpacity;
        if (settings.slotHudMode == 0)
        {
            int dur = settings.slotHudDuration;
            if (dur <= 0) dur = 70;
            int elapsed = gametic - handler.lastWeaponSwitchTic;
            if (elapsed >= dur) return;

            // fade out last 25% of duration
            int fadeStart = (dur * 3) / 4;
            if (elapsed > fadeStart)
            {
                double t = double(dur - elapsed) / double(dur - fadeStart);
                if (t < 0.0) t = 0.0;
                baseAlpha *= t;
            }
        }
        if (baseAlpha <= 0.0) return;

        // raw pixels per icon, virtual coords skew aspect on widescreen
        double s = settings.slotHudScale;
        int iconV = int(ICON_BASE * s);
        if (iconV < 8) iconV = 8;

        int n = list.Size();
        int boxW = (settings.slotHudOrientation == 0) ? iconV : iconV * n;
        int boxH = (settings.slotHudOrientation == 0) ? iconV * n : iconV;

        int vx, vy;
        [vx, vy] = GetHudPosition(settings.slotHudPosition, boxW, boxH);
        vx += settings.slotHudOffsetX;
        vy += settings.slotHudOffsetY;

        double sX = double(Screen.GetWidth()) / VIRT_W;
        double sY = double(Screen.GetHeight()) / VIRT_H;
        int actualIconW = int(iconV * sX);
        int actualIconH = int(iconV * sY);
        int actualBox = actualIconW < actualIconH ? actualIconW : actualIconH;

        // BuildCurrentSlotEffective filters to owned, so list is owned-only
        for (int i = 0; i < n; i++)
        {
            class<Weapon> wc = list[i];
            if (!wc) continue;

            int cellVx = vx;
            int cellVy = vy;
            if (settings.slotHudOrientation == 0)
                cellVy += iconV * i;
            else
                cellVx += iconV * i;

            int actualCellLeft = int(cellVx * sX);
            int actualCellTop  = int(cellVy * sY);

            let inv = p.mo.FindInventory(wc);
            Weapon weapInst = inv ? Weapon(inv) : null;
            TextureID icon = ResolveWeaponIcon(wc, weapInst);
            if (!icon.IsValid()) continue;

            Vector2 srcSize = TexMan.GetScaledSize(icon);
            double srcW = srcSize.X;
            double srcH = srcSize.Y;
            if (srcW < 1) srcW = 1;
            if (srcH < 1) srcH = 1;
            double fit = (srcW > srcH) ? (actualBox / srcW) : (actualBox / srcH);
            int destW = int(srcW * fit);
            int destH = int(srcH * fit);
            int drawX = actualCellLeft + (actualIconW - destW) / 2;
            int drawY = actualCellTop  + (actualIconH - destH) / 2;

            double a = (wc == readyClass) ? baseAlpha : baseAlpha * 0.30;

            Screen.DrawTexture(icon, true, drawX, drawY,
                DTA_DestWidth, destW,
                DTA_DestHeight, destH,
                DTA_TopLeft, true,
                DTA_Alpha, a);
        }
    }

    ui static int, int GetHudPosition(int anchor, int w, int h)
    {
        int x, y;
        switch (anchor)
        {
        case 0:  x = HUD_MARGIN;                   y = HUD_MARGIN;                  break;
        case 1:  x = VIRT_W - w - HUD_MARGIN;      y = HUD_MARGIN;                  break;
        case 2:  x = HUD_MARGIN;                   y = VIRT_H - h - HUD_MARGIN;     break;
        case 3:  x = VIRT_W - w - HUD_MARGIN;      y = VIRT_H - h - HUD_MARGIN;     break;
        case 5:  x = (VIRT_W - w) / 2;             y = HUD_MARGIN;                  break;
        case 6:  x = HUD_MARGIN;                   y = (VIRT_H - h) / 2;            break;
        case 7:  x = VIRT_W - w - HUD_MARGIN;      y = (VIRT_H - h) / 2;            break;
        case 4:
        default: x = (VIRT_W - w) / 2;             y = VIRT_H - h - HUD_MARGIN;     break;
        }
        return x, y;
    }

    // walks state chain for first non-TNT1 sprite, capped at 16 steps
    ui TextureID WalkStateChainForSprite(State s, TextureID tnt1a0)
    {
        TextureID result;
        for (int i = 0; i < 16 && s; i++)
        {
            if (s.sprite != 0)
            {
                TextureID sprIcon; bool flip; Vector2 ssize;
                [sprIcon, flip, ssize] = s.GetSpriteTexture(0);
                if (sprIcon.IsValid() && sprIcon != tnt1a0)
                {
                    result = sprIcon;
                    return result;
                }
            }
            s = s.NextState;
        }
        return result;
    }

    // mirrors SlotEditorMenu.ResolveWeaponIcon
    // priority SpawnState -> ReadyState -> Inventory.Icon
    ui TextureID ResolveWeaponIcon(class<Weapon> wc, Weapon ownedInstance)
    {
        TextureID tnt1a0 = TexMan.CheckForTexture("TNT1A0", TexMan.Type_Sprite);

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

        result = WalkStateChainForSprite(sst, tnt1a0);
        if (!result.IsValid()) result = WalkStateChainForSprite(ready, tnt1a0);
        if (!result.IsValid() && iconField.IsValid()) result = iconField;
        return result;
    }
}
