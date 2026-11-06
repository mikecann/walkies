// Threadbear patch (Threadbear's docs/protocol.md, "Patches"): Walkies' pages one click away, where
// its App Store versions stand, its Chef requests, and a button for updating Dad's Pixel that only
// shows when the phone's on the Wi-Fi. The numbers are in stats.ts. The panels read production or
// Apple, so they keep the answer for 15 minutes rather than asking on every refresh. On a machine
// without Mike's App Store key or Poddle's checkout, the App Store panel just doesn't show.

type Ctx = { sh: (command: string) => Promise<string> };
type Version = { version: string; state: string };
type Request = {
  number: number;
  title?: string;
  description?: string;
  state: string;
  kind?: string;
  mergedInto?: string;
  changelog?: string;
  completedAt?: number;
  _creationTime: number;
};

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

// A refinement is Chef's agent asking the requester a question, and a merged
// one lives on in the request it went into, so neither is a request to build.
const isRequest = (r: Request) => r.kind !== "refinement" && !r.mergedInto;
const isOpen = (r: Request) => isRequest(r) && r.state !== "completed" && r.state !== "rejected";

const STAGE: Record<string, string> = {
  submitted: "Needs your OK",
  requested: "Ready to build",
  planned: "Planned",
  inProgress: "Being built",
};

// "5d" at the end of a row: how long ago, as short as it'll go.
function ago(ms: number) {
  const mins = Math.max(0, (Date.now() - ms) / 60_000);
  if (mins < 60) return `${Math.max(1, Math.round(mins))}m`;
  if (mins < 60 * 24) return `${Math.round(mins / 60)}h`;
  const days = Math.round(mins / (60 * 24));
  if (days < 14) return `${days}d`;
  if (days < 60) return `${Math.round(days / 7)}w`;
  return `${Math.round(days / 30)}mo`;
}

// Chef cuts a long first sentence off with "…" to make a title; the
// description is the whole thing, and the panel cuts it to fit.
const titleOf = (r: Request) => (r.title && !r.title.endsWith("…") ? r.title : r.description || r.title || `#${r.number}`).trim();
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

// dns-sd never exits by itself, so it's killed after 3 seconds. Plain shell, not `perl -e 'alarm 3'`:
// Threadbear refuses a live command whose code its patch trust can't follow, and a perl one-liner
// is one, which hid this button for good (6 Nov). The group's stderr is dropped so a shell's
// "Terminated" note can't land in the count. The phone's serial is in a file on this Mac rather
// than here, as this repo is public. No file: the button never shows.
const PIXEL_ON_WIFI = `s=$(cat ~/.config/walkies/dads-pixel-serial 2>/dev/null) || { echo 0; exit 0; }; { dns-sd -B _adb-tls-connect._tcp local. & p=$!; sleep 3; kill $p; } 2>/dev/null | grep -c "adb-$s" || true`;

export default {
  icon: "figure.walk",
  actions: [
    { title: "Website", icon: "safari", url: "https://walkies.mikecann.app/" },
    { title: "App Store Connect", icon: "app.badge", url: CONNECT },
    { title: "Sentry", icon: "exclamationmark.triangle", url: "https://mikec.sentry.io/issues/?project=4512336956751872" },
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
      // Mike picked this layout on 5 Nov 2026: Waiting and Shipped under
      // headings with counts, what changed on two lines, and how long ago at
      // the end. With nothing waiting there's no Waiting heading at all.
      items: async ({ sh }: Ctx) => {
        const all = (await requests(sh)).filter(isRequest);
        const open = all.filter(isOpen).sort((a, b) => a._creationTime - b._creationTime);
        const shipped = all
          .filter((r) => r.state === "completed" && r.changelog)
          .sort((a, b) => (b.completedAt ?? 0) - (a.completedAt ?? 0));
        const waiting = `Waiting · ${open.length}`;
        const done = `Shipped · ${shipped.length}`;
        return [
          ...open.map((r) => {
            const title = titleOf(r);
            const asked = r.description && r.description.trim() !== title ? ` ${r.description.trim()}` : "";
            return { title, detail: `${STAGE[r.state] ?? r.state}.${asked}`, tone: "attention", section: waiting, trailing: ago(r._creationTime) };
          }),
          ...shipped.slice(0, 40).map((r) => ({
            title: titleOf(r),
            detail: r.changelog,
            tone: "done",
            section: done,
            trailing: r.completedAt ? ago(r.completedAt) : undefined,
          })),
        ];
      },
    },
  ],
};
