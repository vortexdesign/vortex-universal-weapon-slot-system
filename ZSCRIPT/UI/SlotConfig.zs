// SlotConfig.zs
// Layout constants for the slot editor and exclude menu
// Separated from menu logic so layout can be tweaked without touching code

class VUWS_SlotConfig
{
    // virtual coord space, all draws translate to actual screen
    const VIRT_W = 640;
    const VIRT_H = 480;

    // page margins, wide enough to feel centered not edge-to-edge
    const PAGE_MARGIN_X = 80;
    const PAGE_MARGIN_TOP = 60;
    const PAGE_MARGIN_BOTTOM = 56;

    // Title bar at top of content frame
    const TITLE_HEIGHT = 18;

    // Hint bar at bottom of content frame
    const HINT_HEIGHT = 28;

    // Pane gap between adjacent columns (left slots / middle lists / right preview+buttons)
    const PANE_GAP = 8;

    // left pane: slot list
    const LEFT_PANE_WIDTH = 130;

    // Right pane: weapon preview + add/remove buttons stacked vertically
    const RIGHT_PANE_WIDTH = 130;

    // Preview area height inside the right pane (icon + name)
    const PREVIEW_HEIGHT = 120;

    // Row sizes
    const ROW_HEIGHT = 28;
    const ICON_SIZE = 22;
    const SLOT_ICON_SIZE = 18;

    // Pane header band height (where SLOTS / WEAPONS labels go)
    const PANE_HEADER_HEIGHT = 18;

    // Scrollbar
    const SCROLLBAR_WIDTH = 6;
    const SCROLLBAR_INSET = 4;

    // lighter dim, keeps game readable behind menu
    const BACKGROUND_DIM_ALPHA = 0.4;

    // Inner content panel dim, slightly darker than background for contrast
    const CONTENT_PANEL_ALPHA = 0.65;

    // Pane background dim, mid-tone so rows stand out
    const PANE_BG_ALPHA = 0.55;

    // virt -> pixel scaling for Screen.Dim, matches DTA_KeepRatio DrawText
    ui static void DimVirt(int hex, double alpha, int vx, int vy, int vw, int vh)
    {
        int sw = Screen.GetWidth();
        int sh = Screen.GetHeight();
        int sx = vx * sw / VIRT_W;
        int sy = vy * sh / VIRT_H;
        int sw2 = vw * sw / VIRT_W;
        int sh2 = vh * sh / VIRT_H;
        Screen.Dim(hex, alpha, sx, sy, sw2, sh2);
    }
}
