// SlotWidgets.zs
// Primitives for VUWS menus
//
// HitRect       - rectangle bounds + hit-test for mouse coords
// VUWS_ScrollPane - scroll offset state + scrollbar geometry
// VUWS_SlotRow   - one row in the left slot panel (number, occupant icons, cap)
// VUWS_WeaponRow - one row in the right weapon list (icon, name, current-slot badge)
// VUWS_CheckRow  - one row in the exclude menu (checkbox, icon, name)

// Rectangle bounds in virtual coord space, used for mouse hit-tests
// Class not struct since ZScript dynamic arrays only accept integral / reference types
class VUWS_HitRect ui
{
    int x;
    int y;
    int w;
    int h;

    static VUWS_HitRect Create(int xx, int yy, int ww, int hh)
    {
        let r = new("VUWS_HitRect");
        r.x = xx;
        r.y = yy;
        r.w = ww;
        r.h = hh;
        return r;
    }

    bool Contains(int mx, int my)
    {
        return mx >= x && mx < x + w && my >= y && my < y + h;
    }
}

// Scrollable list helper, owns scroll offset and scrollbar rect
class VUWS_ScrollPane ui
{
    int viewportX;
    int viewportY;
    int viewportW;
    int viewportH;
    int contentH;        // Total content height (sum of row heights)
    int scrollOffset;    // 0..max, pixels scrolled down
    int scrollMax;       // contentH - viewportH, clamped to >=0
    int rowHeight;       // Used by Page Up/Down

    void SetContentHeight(int totalH)
    {
        contentH = totalH;
        scrollMax = contentH - viewportH;
        if (scrollMax < 0) scrollMax = 0;
        if (scrollOffset > scrollMax) scrollOffset = scrollMax;
    }

    void ScrollBy(int delta)
    {
        scrollOffset += delta;
        if (scrollOffset < 0) scrollOffset = 0;
        if (scrollOffset > scrollMax) scrollOffset = scrollMax;
    }

    void EnsureRowVisible(int rowIndex)
    {
        int rowTop = rowIndex * rowHeight;
        int rowBottom = rowTop + rowHeight;
        if (rowTop < scrollOffset) scrollOffset = rowTop;
        else if (rowBottom > scrollOffset + viewportH)
            scrollOffset = rowBottom - viewportH;
        if (scrollOffset < 0) scrollOffset = 0;
        if (scrollOffset > scrollMax) scrollOffset = scrollMax;
    }

    // track rect (right edge, full viewport height); needsScroll = scrollMax > 0
    VUWS_HitRect, bool ScrollbarTrackRect(int sbWidth)
    {
        let r = VUWS_HitRect.Create(
            viewportX + viewportW - sbWidth, viewportY, sbWidth, viewportH);
        return r, scrollMax > 0;
    }

    // Returns the scrollbar thumb rect for drawing and drag handling
    VUWS_HitRect ThumbRect(int sbWidth)
    {
        if (contentH <= 0 || scrollMax <= 0)
        {
            return VUWS_HitRect.Create(
                viewportX + viewportW - sbWidth, viewportY, sbWidth, viewportH);
        }
        // Thumb height proportional to viewportH/contentH ratio
        double ratio = double(viewportH) / double(contentH);
        int thumbH = int(viewportH * ratio);
        if (thumbH < 12) thumbH = 12;
        if (thumbH > viewportH) thumbH = viewportH;

        // Thumb position based on scrollOffset
        int trackRange = viewportH - thumbH;
        double pos = (scrollMax > 0) ? double(scrollOffset) / double(scrollMax) : 0.0;
        return VUWS_HitRect.Create(
            viewportX + viewportW - sbWidth, viewportY + int(trackRange * pos),
            sbWidth, thumbH);
    }
}
