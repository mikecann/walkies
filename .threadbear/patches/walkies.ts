// Threadbear patch (Threadbear's docs/protocol.md, "Patches"): Walkies' pages one click away, where
// its App Store versions stand, its Chef requests, and a button for updating Dad's Pixel that only
// shows when the phone's on the Wi-Fi. The numbers are in stats.ts. The panels read production or
// Apple, so they keep the answer for 15 minutes rather than asking on every refresh. On a machine
// without Mike's App Store key or Poddle's checkout, the App Store panel just doesn't show.

type Ctx = { sh: (command: string) => Promise<string> };
type Version = { version: string; state: string };
type Request = { number: number; title?: string; description?: string; state: string; changelog?: string; completedAt?: number };

const APP_ID = "6826001880";
const CONNECT = `https://appstoreconnect.apple.com/apps/${APP_ID}/distribution`;
const KEEP_MS = 15 * 60 * 1000;

// One fetch at a time and one answer for 15 minutes, however many functions ask.
function kept<T>(load: (sh: Ctx["sh"]) => Promise<T>) {
  let cached: { at: number; value: T } | undefined;
  let pending: Promise<T> | undefined;
  return (sh: Ctx["sh"]): Promise<T> => {
    if (cached && Date.now() - cached.at < KEEP_MS) return Promise.resolve(cached.value);
    pending ??= load(sh)
      .then((value) => {
        cached = { at: Date.now(), value };
        return value;
      })
      .finally(() => {
        pending = undefined;
      });
    return pending;
  };
}

const versions = kept(async (sh) => JSON.parse(await sh(`node ~/dev/me/poddle/scripts/asc-status.mjs ${APP_ID}`)).versions as Version[]);
const requests = kept(async (sh) =>
  (await sh("npx convex data items --component feedback --prod --format jsonLines --limit 200"))
    .split("\n")
    .filter((line) => line.startsWith("{"))
    .map((line) => JSON.parse(line) as Request),
);

const isOpen = (r: Request) => r.state !== "completed" && r.state !== "rejected";
const needsMike = (state: string) => state === "PENDING_DEVELOPER_RELEASE" || state.endsWith("REJECTED");

const WORDS: Record<string, string> = {
  READY_FOR_DISTRIBUTION: "Live",
  PENDING_DEVELOPER_RELEASE: "Approved, waiting for you to release it",
  PENDING_APPLE_RELEASE: "Approved, on its way out",
  WAITING_FOR_REVIEW: "Waiting for review",
  IN_REVIEW: "In review",
  REJECTED: "Rejected",
  METADATA_REJECTED: "Rejected for its listing",
  DEVELOPER_REJECTED: "Pulled from review",
  PREPARE_FOR_SUBMISSION: "Not submitted yet",
};

// dns-sd never exits by itself, so perl's alarm stops it after 3 seconds. The phone's serial is in
// a file on this Mac rather than here, as this repo is public. No file: the button never shows.
const PIXEL_ON_WIFI = `s=$(cat ~/.config/walkies/dads-pixel-serial 2>/dev/null) || { echo 0; exit 0; }; perl -e 'alarm 3; exec @ARGV' dns-sd -B _adb-tls-connect._tcp local. 2>/dev/null | grep -c "adb-$s" || true`;

export default {
  icon: "figure.walk",
  actions: [
    { title: "Website", icon: "safari", run: "open https://walkies.mikecann.app/" },
    { title: "App Store Connect", icon: "app.badge", run: `open ${CONNECT}` },
    { title: "Sentry", icon: "exclamationmark.triangle", run: "open 'https://mikec.sentry.io/issues/?project=4512336956751872'" },
    {
      title: "Update Dad's phone",
      icon: "iphone.gen3",
      note: "Shows when Dad's Pixel is on the Wi-Fi with wireless debugging on",
      prompt: "Dad's Pixel is on the Wi-Fi. Build Walkies' release APK from main and install it over wireless debugging. Its serial is in ~/.config/walkies/dads-pixel-serial. Find the port with `dns-sd -L adb-<serial>-<suffix> _adb-tls-connect._tcp local.` (`dns-sd -B _adb-tls-connect._tcp` gives the suffix), `adb connect <ip>:<port>`, then `adb install -r`. Signing needs android/keystore.properties, which is only in the main checkout, and the cert must start 654e471b32c9. Run adb and Gradle with the sandbox off.",
      when: async ({ sh }: Ctx) => Number((await sh(PIXEL_ON_WIFI)).trim()) > 0,
    },
    {
      title: "Release it",
      icon: "paperplane",
      note: "Shows once Apple has approved a version",
      prompt: "Apple has approved a version of Walkies. Check where it stands with `node ~/dev/me/poddle/scripts/asc-status.mjs 6826001880`, check the build still works with today's prod backend, release it through the App Store Connect API (POST /v1/appStoreVersionReleaseRequests), then flip APP_STORE_LIVE once the listing shows.",
      when: async ({ sh }: Ctx) => {
        try {
          return (await versions(sh))[0]?.state === "PENDING_DEVELOPER_RELEASE";
        } catch {
          return false;
        }
      },
    },
    {
      title: "Build the next request",
      icon: "hammer",
      note: "Shows when someone has asked for something in Chef",
      prompt: "Look at the open Chef requests on Walkies' prod (`npx convex data items --component feedback --prod --format jsonLines`), then build the oldest one that's been approved. Ask me if none has.",
      when: async ({ sh }: Ctx) => (await requests(sh)).some(isOpen),
      badge: async ({ sh }: Ctx) => (await requests(sh)).filter(isOpen).length,
    },
  ],
  panels: [
    {
      title: "App Store",
      icon: "app.badge",
      when: async ({ sh }: Ctx) => {
        try {
          return (await versions(sh)).length > 0;
        } catch {
          return false;
        }
      },
      badge: async ({ sh }: Ctx) => ((await versions(sh))[0] && needsMike((await versions(sh))[0].state) ? 1 : 0),
      items: async ({ sh }: Ctx) =>
        (await versions(sh)).slice(0, 3).map((v) => ({
          title: v.version,
          detail: WORDS[v.state] ?? v.state,
          url: CONNECT,
          icon: "app.badge",
          tone: needsMike(v.state) ? "attention" : v.state === "READY_FOR_DISTRIBUTION" ? "done" : undefined,
        })),
    },
    {
      title: "Chef requests",
      icon: "text.bubble",
      badge: async ({ sh }: Ctx) => (await requests(sh)).filter(isOpen).length,
      items: async ({ sh }: Ctx) => {
        const all = await requests(sh);
        const open = all.filter(isOpen).map((r) => ({ title: `#${r.number} ${r.title ?? r.description ?? ""}`.trim(), detail: r.state, icon: "text.bubble", tone: "attention" }));
        const shipped = all
          .filter((r) => r.state === "completed" && r.changelog)
          .sort((a, b) => (b.completedAt ?? 0) - (a.completedAt ?? 0))
          .slice(0, 5)
          .map((r) => ({ title: `#${r.number} ${r.title ?? ""}`.trim(), detail: r.changelog, icon: "checkmark.circle" }));
        return [...(open.length ? open : [{ title: "Nothing waiting", tone: "done" }]), ...shipped];
      },
    },
  ],
};
