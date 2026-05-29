// SlotData.zs
// Shared types for VUWS

// Reasons a pickup gets blocked, surfaced via Setup callbacks and HUD toasts
enum VUWS_BlockReason
{
    VUWS_BLOCK_AT_CAP        = 0   // Slot at cap, walk-over rejected
}

// drop reason passed to OnWeaponDropped
enum VUWS_DropReason
{
    VUWS_DROP_RECONCILE      = 0,  // WorldTick over-cap drop
    VUWS_DROP_LRU_SWAP       = 1,  // block_action 1 swap
    VUWS_DROP_USE_KEY        = 2   // block_action 2 use-key bump
}

// per-frame cache, avoids per-draw CVar lookups
class VUWS_RenderSettings
{
    bool notify;
    int notifyDuration;
    double notifyOpacity;

    bool usePickupPrompt;

    int colorBlocked;
    int colorSwap;
    int colorMenuAccent;
    int colorPickupPrompt;

    // Current Slot HUD
    bool   slotHudEnabled;
    int    slotHudMode;          // 0=on-switch, 1=always
    int    slotHudOrientation;   // 0=vertical, 1=horizontal
    int    slotHudPosition;
    int    slotHudOffsetX;
    int    slotHudOffsetY;
    double slotHudScale;
    double slotHudOpacity;
    int    slotHudDuration;

    // Lazy-cached CVar refs so Refresh skips name-hashing every frame
    private transient CVar cvNotify;
    private transient CVar cvNotifyDuration;
    private transient CVar cvNotifyOpacity;
    private transient CVar cvUsePickupPrompt;
    private transient CVar cvColorBlocked;
    private transient CVar cvColorSwap;
    private transient CVar cvColorMenuAccent;
    private transient CVar cvColorPickupPrompt;
    private transient CVar cvSlotHudEnabled;
    private transient CVar cvSlotHudMode;
    private transient CVar cvSlotHudOrientation;
    private transient CVar cvSlotHudPosition;
    private transient CVar cvSlotHudOffsetX;
    private transient CVar cvSlotHudOffsetY;
    private transient CVar cvSlotHudScale;
    private transient CVar cvSlotHudOpacity;
    private transient CVar cvSlotHudDuration;

    void Refresh()
    {
        let p = players[consoleplayer];

        if (!cvNotify)              cvNotify              = CVar.GetCVar('vuws_notify', p);
        if (!cvNotifyDuration)      cvNotifyDuration      = CVar.GetCVar('vuws_notify_duration', p);
        if (!cvNotifyOpacity)       cvNotifyOpacity       = CVar.GetCVar('vuws_notify_opacity', p);
        if (!cvUsePickupPrompt)     cvUsePickupPrompt     = CVar.GetCVar('vuws_use_pickup_prompt', p);
        if (!cvColorBlocked)        cvColorBlocked        = CVar.GetCVar('vuws_color_blocked', p);
        if (!cvColorSwap)           cvColorSwap           = CVar.GetCVar('vuws_color_swap', p);
        if (!cvColorMenuAccent)     cvColorMenuAccent     = CVar.GetCVar('vuws_color_menu_accent', p);
        if (!cvColorPickupPrompt)   cvColorPickupPrompt   = CVar.GetCVar('vuws_color_pickup_prompt', p);
        if (!cvSlotHudEnabled)      cvSlotHudEnabled      = CVar.GetCVar('vuws_slot_hud_enabled', p);
        if (!cvSlotHudMode)         cvSlotHudMode         = CVar.GetCVar('vuws_slot_hud_mode', p);
        if (!cvSlotHudOrientation)  cvSlotHudOrientation  = CVar.GetCVar('vuws_slot_hud_orientation', p);
        if (!cvSlotHudPosition)     cvSlotHudPosition     = CVar.GetCVar('vuws_slot_hud_position', p);
        if (!cvSlotHudOffsetX)      cvSlotHudOffsetX      = CVar.GetCVar('vuws_slot_hud_offset_x', p);
        if (!cvSlotHudOffsetY)      cvSlotHudOffsetY      = CVar.GetCVar('vuws_slot_hud_offset_y', p);
        if (!cvSlotHudScale)        cvSlotHudScale        = CVar.GetCVar('vuws_slot_hud_scale', p);
        if (!cvSlotHudOpacity)      cvSlotHudOpacity      = CVar.GetCVar('vuws_slot_hud_opacity', p);
        if (!cvSlotHudDuration)     cvSlotHudDuration     = CVar.GetCVar('vuws_slot_hud_duration', p);

        notify              = cvNotify              ? cvNotify.GetBool()              : true;
        notifyDuration      = cvNotifyDuration      ? cvNotifyDuration.GetInt()       : 70;
        notifyOpacity       = cvNotifyOpacity       ? cvNotifyOpacity.GetFloat()      : 0.9;
        if (notifyOpacity < 0.0) notifyOpacity = 0.0;
        if (notifyOpacity > 1.0) notifyOpacity = 1.0;

        usePickupPrompt     = cvUsePickupPrompt     ? cvUsePickupPrompt.GetBool()     : true;

        colorBlocked        = cvColorBlocked        ? cvColorBlocked.GetInt()        : 6;
        colorSwap           = cvColorSwap           ? cvColorSwap.GetInt()           : 5;
        colorMenuAccent     = cvColorMenuAccent     ? cvColorMenuAccent.GetInt()     : 10;
        colorPickupPrompt   = cvColorPickupPrompt   ? cvColorPickupPrompt.GetInt()   : 9;

        slotHudEnabled      = cvSlotHudEnabled      ? cvSlotHudEnabled.GetBool()      : true;
        slotHudMode         = cvSlotHudMode         ? cvSlotHudMode.GetInt()          : 0;
        slotHudOrientation  = cvSlotHudOrientation  ? cvSlotHudOrientation.GetInt()   : 0;
        slotHudPosition     = cvSlotHudPosition     ? cvSlotHudPosition.GetInt()      : 7;
        slotHudOffsetX      = cvSlotHudOffsetX      ? cvSlotHudOffsetX.GetInt()       : 0;
        slotHudOffsetY      = cvSlotHudOffsetY      ? cvSlotHudOffsetY.GetInt()       : 0;
        slotHudScale        = cvSlotHudScale        ? cvSlotHudScale.GetFloat()       : 1.5;
        if (slotHudScale < 0.5) slotHudScale = 0.5;
        if (slotHudScale > 2.0) slotHudScale = 2.0;
        slotHudOpacity      = cvSlotHudOpacity      ? cvSlotHudOpacity.GetFloat()     : 0.9;
        if (slotHudOpacity < 0.0) slotHudOpacity = 0.0;
        if (slotHudOpacity > 1.0) slotHudOpacity = 1.0;
        slotHudDuration     = cvSlotHudDuration     ? cvSlotHudDuration.GetInt()      : 70;
    }

    // Font.CR_ index (0-25) to inline `\cX` escape for use in DrawText strings
    static String GetColorCode(int fontColorIndex)
    {
        if (fontColorIndex < 0) fontColorIndex = 0;
        if (fontColorIndex > 25) fontColorIndex = 25;
        return "\c" .. String.Format("%c", 65 + fontColorIndex);
    }

    // Font.CR_ index to RGB hex for Screen.Dim or Color() construction
    static int GetColorHex(int fontColorIndex)
    {
        switch (fontColorIndex)
        {
        case 0:  return 0xD03030;
        case 1:  return 0xD2BE8A;
        case 2:  return 0x808080;
        case 3:  return 0x50D050;
        case 4:  return 0x8B6914;
        case 5:  return 0xD4A017;
        case 6:  return 0xFF3030;
        case 7:  return 0x5050FF;
        case 8:  return 0xFF8000;
        case 9:  return 0xF0F0F0;
        case 10: return 0xFFFF00;
        case 11: return 0xD0D0D0;
        case 12: return 0x202020;
        case 13: return 0x90C0FF;
        case 14: return 0xFFF0C0;
        case 15: return 0x808000;
        case 16: return 0x308030;
        case 17: return 0x800000;
        case 18: return 0x604020;
        case 19: return 0x9030D0;
        case 20: return 0x505050;
        case 21: return 0x50E0E0;
        case 22: return 0xA0D0E0;
        case 23: return 0xFF6030;
        case 24: return 0x3060FF;
        case 25: return 0x40A0A0;
        default: return 0xF0F0F0;
        }
    }
}
