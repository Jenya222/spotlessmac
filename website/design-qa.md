# Design QA

Source: `../output/landing-concepts/selected-design.png` (1189 × 1323 raster), concept 3 with concept 2 identity.
Browser: actual Google Chrome via native computer-use. Screenshots saved in `qa/`.

## Evidence and normalization

- `qa/comparison.png`, `qa/comparison-final.png`: source and live implementation in the same browser capture. Source displayed at 720px width; live iframe is 1440 CSS px wide, scaled 0.5. Both panels therefore normalize to the same width. Chrome captures at 2x density. Live frame height is 2200 CSS px, so the longer production content continues beyond the source's shortened concept.
- `qa/desktop.png`: standalone desktop hero before final typography pass.
- `qa/mobile.png`, `qa/mobile-final.png`: 390 × 844 and 768 × 1024 live iframes. Adaptation checks, not comparison to a nonexistent mobile design.
- `qa/mobile-offer.png`: mobile offer reached through navigation, with menu closed.
- Focused hero, file-demo and offer regions visible in the above combined captures; separate crop not necessary.

## Findings and fixes

1. P2 initial hero wrapped to two lines at 1440. Restored the selected three-line lockup with responsive spans and adjusted font sizing. Confirmed in comparison-final.
2. P2 sample text was too small. Increased desktop sample labels, sizes and filter text. Verified against comparison-final.
3. P2 tablet illustration overlapped compatibility note. Moved image start below copy/action; verified in mobile-final and mobile-offer.
4. A font-subset import attempted during polish was unavailable. Restored the supported package import; refreshed and verified the error overlay disappeared in comparison-final. Final build rerun.

## Behavior checked

- Download CTA opens truthful public-release dialog; Escape dismisses it.
- Large files and installers start unchecked; selecting a film adds it to review, including path and size.
- Mobile menu expands; Plans anchor navigates and closes menu.
- Live app remains read-only demo with no filesystem access.
- Account explicitly states sample data, no account creation and no payments. Real service actions are not advertised as working.

## Scope and remaining work

The design is an expanded implementation of the concept: additional capabilities, offer, FAQs, release transparency, and account preview are intentional. Illustrative app imagery is labeled. Native and web builds pass. Browser console instrumentation was not available through the browser connector; no claim of exhaustive console or automated accessibility audit. Lower-page desktop screenshot coverage is limited; mobile offer and key interactions were inspected directly.

P3: generated laptop is a studio illustration and differs slightly in camera angle from the concept. English app imagery must be replaced when localization ships. Preview is not approved for paid traffic or real commerce.

final result: passed


## Native preview revision — 2026-09-26

- Replaced the light category sidebar with a graphite rail, macOS window chrome, system typography, compact file rows and visible paths. Colors follow native Theme.swift.
- Extracted FileDemo into its own component and scoped stylesheet; retained filtering, selection totals and review dialog.
- Regenerated the laptop hero with compact UI, aligned rows, smaller storage ring and button, preserving the blue studio and S sparkle identity. Saved hero-v2 PNG and optimized WebP; original retained.
- Production build passed. Browser loaded new hero and component; developer-filter state and default selection were visible in accessibility output. Console after reload showed no JavaScript errors.
- Full interaction and responsive visual recheck was interrupted by repeated computer-use noWindowsAvailable failures; do not treat that coverage as passed.


## Laptop regeneration v3
Rebuilt entire laptop with wider display, regular keyboard and trackpad, compact two-column screen composition. Removed generated extra counts and unsupported risk claim. Final image visually inspected; PNG and WebP connected under new hero-v3 URLs to avoid stale asset caching.


## Corrected scope: screen only, v4
Restored v2 laptop composition. Regenerated only the display with a macOS desktop and a normally scaled application window: small icons, compact file rows, paths, and a modest action button. Inspected generated image. Replaced both PNG fallback and WebP source with hero-v4 URLs.
