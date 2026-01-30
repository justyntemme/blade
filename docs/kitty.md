# Blade: Combined Text + Kitty Images (CPU/Mem Charts)

This document replaces the old kitty.md with a concrete plan to render
text tables via ANSI and charts via Kitty Graphics Protocol images in
one cohesive UI.

## Goals

- Keep fast text rendering for tables (ANSI text output).
- Render high-quality CPU/Mem charts as Kitty images in specific panels.
- Avoid full-screen image frames; update only the chart region.
- Maintain cross-terminal compatibility (fallback when Kitty unsupported).

## Constraints (must accept)

- Kitty/ghostty still require escape sequences written to stdout/TTY.
- Images are sent as bytes; there is no direct GPU canvas access.
- Full-screen image streaming is bandwidth-heavy; only update chart regions.

## Architecture Overview

Split rendering into two outputs per frame:

1) Text pass: existing zigtui buffer -> ANSI output
2) Chart pass: render chart pixels -> Kitty image placement

The layout stays the same. The chart panel (a Rect in cell units)
becomes the target region for the Kitty image placement.

## Rendering Flow (per frame)

1) Compute layout (existing layout engine).
2) Render all text widgets to the text buffer as usual.
3) Draw the text buffer to terminal using ANSI (existing zigtui path).
4) Render chart pixels into an RGBA buffer sized to the chart panel.
5) Send Kitty image placement anchored at chart panel x/y in cells.

Order matters:
- If you want the chart behind text labels, send the Kitty image
  with a negative z-index and then write labels via ANSI.
- If you want the chart on top of text, use a positive z-index.

## Capability Detection

At startup:
- If Kitty graphics supported -> enable chart images.
- If not -> fallback to text-only chart rendering (ASCII/Unicode blocks).

Detection options:
- Environment: TERM contains kitty, KITTY_WINDOW_ID exists.
- Protocol query: send Kitty `a=q` and wait for response.

## Chart Rendering Strategy

Start with a CPU rasterizer. GPU does not avoid the pixel transfer
cost (you still need readback), so CPU is simpler and often faster
end-to-end for terminal image transport.

Chart pixel buffer:
- RGBA, sRGB, pre-multiplied alpha off (opaque background).
- Size = chart_rect.width * cell_px_w by chart_rect.height * cell_px_h

Chart visuals:
- Use anti-aliased lines and filled areas for smooth graphs.
- Keep text labels in ANSI (faster, sharper) or render them into
  the chart image if you need precise alignment.

## Image Placement (Kitty Protocol)

Use a stable image id and placement id for the chart region.
Always re-use the same IDs to avoid image accumulation.

Example parameters (conceptual):
- a=T (transmit+display)
- f=32 (RGBA)
- s=<px_w>, v=<px_h>
- c=<cells_w>, r=<cells_h>
- x=<cell_x>, y=<cell_y>
- C=1 (do not move cursor)
- z=-1 (behind text)
- i=1 (image id)
- p=1 (placement id)

Transmission mode:
- Start with t=d (direct base64) for simplicity.
- Move to t=s (shared memory) for performance after it works.

## Update Policy

- Only update charts when data changes or on a fixed low FPS (10-30).
- Tables can update every frame as they are light-weight ANSI.
- If chart panel is hidden or collapsed, skip chart rendering entirely.

## Resize Handling

On resize:
- Recompute layout
- Recalculate chart pixel size
- Delete previous chart placement (by placement id)
- Re-send chart image with new size and placement

## Fallback Behavior

If Kitty support is missing:
- Render charts as text (existing zigtui buffer)
- Continue ANSI-only output

## Implementation Steps (incremental)

Phase 1: Structural split
- Separate "text render" and "chart render" in the draw loop.
- Add a chart Rect to layout (if not already explicit).

Phase 2: Kitty transport
- Implement a minimal Kitty sender that can transmit a test image.
- Place image in a fixed region and verify positioning.

Phase 3: Chart renderer
- Render CPU/mem chart to an RGBA buffer (CPU rasterizer).
- Send chart buffer to Kitty for only the chart region.

Phase 4: Integration
- Keep text rendering as-is for tables.
- Render labels either as ANSI or into the chart image.
- Ensure cursor state is preserved (`C=1`).

Phase 5: Performance upgrades
- Switch to shared memory transmission (t=s).
- Cache last image and send only if chart data changes.
- Optionally add dirty-rect updates within the chart region.

## Library Options for Chart Rasterization

CPU (recommended for v1):
- Use a small custom rasterizer for lines/areas (fast, minimal deps).
- Optional: integrate a Zig 2D CPU renderer later for higher quality.

GPU (optional future):
- GPU rendering still requires readback -> likely slower at full-screen.
- Only consider GPU if chart visuals demand it and chart region is small.

## Risks and Mitigations

Risk: full-screen image throughput is too slow
- Mitigation: only image the chart region, keep text ANSI.

Risk: chart images flicker
- Mitigation: stable image/placement IDs, avoid full delete each frame.

Risk: alignment between ANSI text and chart image
- Mitigation: use C=1 and fixed cell-based placement; test across
  terminal font sizes.

## Definition of Done

- Charts appear as smooth images in Kitty/Ghostty.
- Tables remain ANSI text with no regression in speed.
- Resizes reflow correctly with no stale images.
- Fallback works in non-Kitty terminals.
