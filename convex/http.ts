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

// Where Apple's and Google's sign-in pages end up, with ?convexAuthCode=... The
// app's sign-in sheet catches this address before it loads, so this page only
// shows if it's somehow opened in a browser instead.
http.route({
  path: "/app/signed-in",
  method: "GET",
  handler: httpAction(async () => {
    const page = `<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Walkies</title><body style="font-family:-apple-system,sans-serif;background:#fbf4e6;color:#3b312b;text-align:center;padding:4rem 1.5rem">
<h1>Nearly there</h1><p>Head back to the Walkies app to finish signing in.</p></body>`;
    return new Response(page, { headers: { "Content-Type": "text/html; charset=utf-8" } });
  }),
});

export default http;
