import { httpRouter } from "convex/server";
import { registerStaticRoutes } from "@convex-dev/static-hosting";
import { components } from "./_generated/api";
import { httpAction, type ActionCtx } from "./_generated/server";

const http = httpRouter();

// Links the Walkies app to this domain (team ID + bundle ID). The app's sign-in
// sheet needs it to catch the redirect back to /app/signed-in.
http.route({
  path: "/.well-known/apple-app-site-association",
  method: "GET",
  handler: httpAction(async () => {
    const association = { webcredentials: { apps: ["4DTAZSZL6B.com.mikecann.walkies"] } };
    return new Response(JSON.stringify(association), {
      headers: { "Content-Type": "application/json" },
    });
  }),
});

// Where Apple's and Google's sign-in pages end up, with ?convexAuthCode=... It
// hands the same query on to walkies://signed-in, which the app's sign-in sheet
// catches. (Catching this https address directly needs iOS to have checked the
// association file above first, and on iOS 18 the sheet just won't open until it has.)
http.route({
  path: "/app/signed-in",
  method: "GET",
  handler: httpAction(async (_ctx, request) => {
    const { search } = new URL(request.url);
    return new Response(null, { status: 302, headers: { Location: `walkies://signed-in${search}` } });
  }),
});

function escapeHtml(value: string) {
  return value.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
}

http.route({
  pathPrefix: "/join/",
  method: "GET",
  handler: httpAction(async (_ctx, request) => {
    const code = new URL(request.url).pathname.slice("/join/".length);
    // Never look up the code here. Real and nonexistent invites have the same
    // public response, so this endpoint cannot be used as an invite oracle.
    const normalized = code.trim().toUpperCase();
    const valid = /^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{8}$/.test(normalized);
    const deepLink = valid ? `walkies://join/${normalized}` : null;
    const heading = "Open Walkies to join a team";
    return new Response(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Join a Walkies team</title><style>
body { margin: 0; min-height: 100svh; display: grid; place-items: center; background: #faf3e5; color: #343b30; font: 18px/1.5 system-ui, sans-serif; }
main { max-width: 30rem; padding: 2rem; text-align: center; } h1 { font-size: 2rem; line-height: 1.2; }
a { display: inline-block; padding: .8rem 1.4rem; border-radius: 1rem; background: #3c6549; color: white; text-decoration: none; }
</style></head><body><main><h1>${heading}</h1>
${deepLink === null ? "<p>Ask someone in the team for a fresh link or check the eight-character code in Walkies.</p>" :
  `<p>Your team can see each other here. Your clouds and secrets stay yours.</p><a href="${deepLink}">Open Walkies</a><p>If nothing opens, install Walkies and enter <strong>${escapeHtml(normalized)}</strong> in Join a team.</p>`}
</main>${deepLink === null ? "" : `<script>window.location.href = ${JSON.stringify(deepLink)};</script>`}</body></html>`, {
      status: 200,
      headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" },
    });
  }),
});

// The website: the home page, /privacy and /support, built from web/ and uploaded to
// static hosting (`npm run web:upload:prod`). The App Store listing and Google's sign-in
// screen link to /privacy and /support, which are plain .html files there.
async function uploadedPage(ctx: ActionCtx, path: string): Promise<string | null> {
  try {
    const asset = await ctx.runQuery(components.staticHosting.lib.resolveAssetForHttp, { path, spaFallback: false });
    if (asset?.storageUrl) {
      const res = await fetch(asset.storageUrl);
      if (res.ok) return await res.text();
    }
  } catch (error) {
    console.error(`Couldn't load ${path} from static hosting`, error);
  }
  return null;
}

/** Until the site's uploaded: just enough to read, and who to ask. */
function fallbackPage(title: string, body: string) {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title}</title><style>
body { margin: 0; background: #fbf4e6; color: #3b312b; font: 18px/1.6 system-ui, sans-serif; }
main { max-width: 34rem; margin: 0 auto; padding: 3rem 1.5rem; } h1 { font-size: 2rem; line-height: 1.2; }
a { color: #c9573b; }
</style></head><body><main>${body}</main></body></html>`;
}

const FALLBACK: Record<string, string> = {
  "/privacy": fallbackPage("Privacy · Walkies", `<h1>Walkies privacy</h1>
<p>Walkies keeps your name, email and Google photo from sign-in, the places you add, your walks (GPS routes, times and steps), the tiles and secrets you've uncovered, your shells and rewards, your teams, and any feature requests you send. It's stored on your phone and in your account on Convex, in Sydney, so it's backed up and syncs. No ads, no tracking, and nothing is sold.</p>
<p>To delete your account and everything in it, go to Settings in the app and tap Delete account, or email <a href="mailto:walkies@mikecann.app">walkies@mikecann.app</a>.</p>`),
  "/support": fallbackPage("Help · Walkies", `<h1>Help with Walkies</h1>
<p>Email <a href="mailto:walkies@mikecann.app">walkies@mikecann.app</a>, or tap Suggest a feature in the app's Settings.</p>`),
};

for (const path of ["/privacy", "/support"]) {
  http.route({
    path,
    method: "GET",
    handler: httpAction(async (ctx) => {
      const html = (await uploadedPage(ctx, `${path}.html`)) ?? FALLBACK[path]!;
      return new Response(html, {
        status: 200,
        headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "public, max-age=300", "X-Content-Type-Options": "nosniff" },
      });
    }),
  });
}

// Everything else, the home page included: the uploaded site's files, and a real 404
// for anything that isn't one.
registerStaticRoutes(http, components.staticHosting, { spaFallback: false });

export default http;
