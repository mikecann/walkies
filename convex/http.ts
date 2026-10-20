import { httpRouter } from "convex/server";
import { httpAction } from "./_generated/server";

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

// The home page and privacy policy Google's sign-in screen links to.
function page(title: string, body: string) {
  return new Response(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title}</title><style>
body { margin: 0; background: #faf3e5; color: #343b30; font: 18px/1.6 system-ui, sans-serif; }
main { max-width: 34rem; margin: 0 auto; padding: 3rem 1.5rem; } h1 { font-size: 2rem; line-height: 1.2; }
a { color: #3c6549; }
</style></head><body><main>${body}</main></body></html>`, {
    status: 200,
    headers: { "Content-Type": "text/html; charset=utf-8", "X-Content-Type-Options": "nosniff" },
  });
}

http.route({
  path: "/",
  method: "GET",
  handler: httpAction(async () => page("Walkies", `<h1>Walkies</h1>
<p>Clear the clouds by walking. A small app by Mike Cann.</p>
<p><a href="/privacy">Privacy</a></p>`)),
});

http.route({
  path: "/privacy",
  method: "GET",
  handler: httpAction(async () => page("Walkies privacy", `<h1>Walkies privacy</h1>
<p>Walkies is a small app made by Mike Cann for exploring your area on foot.</p>
<p><strong>What it keeps:</strong> your name, email and profile photo from Google or Apple sign-in; the places you add; your walks (routes and times); the tiles and secrets you've uncovered; and your shells and rewards.</p>
<p><strong>Where:</strong> on your phone, and in your Walkies account on Convex (the database it runs on), so it's backed up and syncs.</p>
<p><strong>Location:</strong> Walkies uses your location in the background to record walks, and only to clear tiles on your map.</p>
<p><strong>Who sees it:</strong> just you. If you join a team, your teammates see your name and photo. Nothing is sold or shared, and there are no ads or trackers.</p>
<p><strong>Deleting your data:</strong> email <a href="mailto:mike.cann@gmail.com">mike.cann@gmail.com</a> and everything in your account is deleted.</p>
<p><a href="/">Walkies</a></p>`)),
});

export default http;
