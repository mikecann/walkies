// The few things about the website that change. scripts/build-web.mjs reads them.

/** Where the site lives: prod's Convex deployment, on its own domain. */
export const SITE_URL = "https://walkies.mikecann.app";

/** Walkies on the App Store (Apple ID 6826001880). Also used for Safari's Smart App Banner. */
export const APP_STORE_URL = "https://apps.apple.com/app/id6826001880";

/**
 * Flip to true once Walkies is out on the App Store. Until then every App Store badge
 * on the site says "Coming soon to the App Store" and isn't a link, and the structured
 * data leaves out the download link.
 */
export const APP_STORE_LIVE = false;

/** The code, for the GitHub corner. */
export const GITHUB_URL = "https://github.com/mikecann/walkies";

/** Where people write for help. */
export const SUPPORT_EMAIL = "walkies@mikecann.app";

/** The privacy policy's date. Change it whenever the policy changes. */
export const PRIVACY_UPDATED = "23 October 2026";
