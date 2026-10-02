# Spotless Mac website

English responsive landing based on selected concept 3, with the S sparkle identity from concept 2.

## Run

```sh
npm ci
npm run dev -- --host 127.0.0.1 --port 4173
npm run build
npm run test:sites
```

The app is in `src/App.jsx`, styling in `src/styles.css`, public service links in `src/config.js`. Generated PNG/WebP artwork and the transparent 1024px master icon are in `public/images`. `scripts/prepare-images.mjs` creates WebP assets and the macOS AppIcon catalog from these masters. Run it from this folder with `node scripts/prepare-images.mjs`.

## Delivered behavior

- Desktop, tablet and phone layouts; accessible navigation, native dialogs, keyboard focus styles and reduced motion.
- Interactive example file filtering/selection and a path/size preview. No real filesystem operations.
- Trial offer, capability explanations, FAQs and honest release/download state.
- `/#account`: explicitly labeled account design preview with overview, license, billing and subscription lifecycle states. It does not register users, authenticate, charge cards or issue licenses.
- One shared S sparkle identity in website, favicon, app icon and native app rail.

## Production setup still required

1. Approve a seller account in a supported jurisdiction. Paddle is the proposed provider, not a connected service. Do not assume eligibility based on language or nationality. See https://www.paddle.com/help/start/intro-to-paddle/which-countries-are-supported-by-paddle . MacPaw has publicly documented using Paddle: https://macpaw.com/news/macpaw-cybersecurity-as-a-backbone . This does not establish market-share leadership.
2. Implement email authentication, server-side sessions, account persistence and billing adapter. Prefer hosted checkout and provider billing portal. Keep customer-provider IDs on the server.
3. Verify signed webhooks using raw request bytes, deduplicate event IDs and handle out-of-order subscription events. Issue licenses only from verified paid entitlement state, never a browser success callback.
4. Add a versioned signed license payload with expiry/refresh and migration for existing perpetual licenses. The current Swift validator has no expiry. Preserve the Debug bypass.
5. Add English app localization, signed/notarized release download, support contact, domain, privacy/terms/refund policy and final prices/renewal terms.
6. Configure verified URLs using `.env.example`; rebuild. VITE variables are public: never put Paddle secrets or signing keys there.
7. Replace illustrative English app renders with accurate release captures. Configure absolute canonical and OpenGraph URLs and remove preview `noindex` only when ready to publish.
8. Configure ad conversion tracking and consent behavior for the chosen networks and markets. No advertising pixels currently run. Do not launch paid campaigns against this preview.

## Assets

Built-in ImageGen produced the hero, developer illustration and icon. Prompts are in `../output/landing-concepts` (and asset provenance below). The icon is raster, not a vector logo. Mechanical resizing/encoding uses Sharp; edits were generated with ImageGen. AppIcon representations: 16, 32, 128, 256 and 512 points at 1x/2x. Fonts are hosted locally via Fontsource; icons use Phosphor React.

Reference: `../output/landing-concepts/selected-design.png`. QA pages under `qa/` are dev-only inputs, not included in the production Vite bundle.
