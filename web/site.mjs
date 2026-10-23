// The few things about the website that change. scripts/build-web.mjs reads them.

/** Where the site lives: prod's Convex deployment, on its own domain. */
export const SITE_URL = "https://walkies.mikecann.app";

/**
 * The App Store page, e.g. "https://apps.apple.com/app/walkies/id1234567890". Until it's
 * set, the site says "Coming soon to the App Store" instead of showing the badge.
 */
export const APP_STORE_URL = null;

/** Where people write for help. A placeholder until the mailbox exists (docs/decisions.md). */
export const SUPPORT_EMAIL = "walkies@mikecann.app";

/** The privacy policy's date. Change it whenever the policy changes. */
export const PRIVACY_UPDATED = "23 October 2026";
