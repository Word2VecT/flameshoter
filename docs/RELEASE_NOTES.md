# Flameshoter 0.2.3

Fixes a crash when beginning a region selection or selecting a thin region. Insetting the initial one-pixel selection produced a null rectangle with infinite coordinates, which AppKit rejected while updating cursor regions.

Move cursors are registered only when there is an interior area. Tiny selection image clipping stays within the selection bounds, and hidden dimension labels no longer receive invalid frames. A regression test exercises mouse-down before dragging, one-pixel selections and thin regions.

Retains the original menu-bar flame icon, menu-bar residency fix and fixed signing identity from 0.2.2.
