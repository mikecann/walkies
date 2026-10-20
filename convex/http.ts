import { httpRouter } from "convex/server";
import { httpAction } from "./_generated/server";
import { internal } from "./_generated/api";

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
  handler: httpAction(async (ctx, request) => {
    const code = new URL(request.url).pathname.slice("/join/".length);
    const invite = await ctx.runQuery(internal.crews.inviteForPage, { code });
    const deepLink = invite === null ? null : `walkies://join/${invite.code}`;
    const heading = invite === null ? "This invite wasn't found" : `Open Walkies to join ${escapeHtml(invite.name)}`;
    return new Response(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Join a Walkies crew</title><style>
body { margin: 0; min-height: 100svh; display: grid; place-items: center; background: #faf3e5; color: #343b30; font: 18px/1.5 system-ui, sans-serif; }
main { max-width: 30rem; padding: 2rem; text-align: center; } h1 { font-size: 2rem; line-height: 1.2; }
a { display: inline-block; padding: .8rem 1.4rem; border-radius: 1rem; background: #3c6549; color: white; text-decoration: none; }
</style></head><body><main><h1>${heading}</h1>
${deepLink === null ? "<p>Ask someone in the crew for a fresh link or check the six-character code in Walkies.</p>" :
  `<p>Your next walk can help fill in the map together.</p><a href="${deepLink}">Open Walkies</a><p>If nothing opens, install Walkies and enter <strong>${invite!.code}</strong> in Join a crew map.</p>`}
</main>${deepLink === null ? "" : `<script>window.location.href = ${JSON.stringify(deepLink)};</script>`}</body></html>`, {
      status: invite === null ? 404 : 200,
      headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" },
    });
  }),
});

export default http;
