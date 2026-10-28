import { defineApp } from "convex/server";
import { v } from "convex/values";
import core from "@convex-dev/auth/convex.config.js";
import apple from "@convex-dev/auth/components/apple/convex.config.js";
import google from "@convex-dev/auth/components/google/convex.config.js";
import anonymous from "@convex-dev/auth/components/anonymous/convex.config.js";
import feedback from "@convex-dev/feedback/convex.config.js";
import staticHosting from "@convex-dev/static-hosting/convex.config.js";
import workflow from "@convex-dev/workflow/convex.config.js";
import agent from "@convex-dev/agent/convex.config.js";
import stateMachines from "@convex-dev/state-machines/convex.config.js";

const app = defineApp({
  env: {
    AUTH_PRIVATE_KEY: v.string(),
    AUTH_JWKS: v.string(),
    // A Services ID made for Walkies, the team ID, and a Sign in with Apple key
    // (its ID and the contents of its AuthKey_<id>.p8 file).
    AUTH_APPLE_CLIENT_ID: v.string(),
    AUTH_APPLE_TEAM_ID: v.string(),
    AUTH_APPLE_KEY_ID: v.string(),
    AUTH_APPLE_PRIVATE_KEY: v.string(),
    // A Google OAuth client of the "Web application" type.
    AUTH_GOOGLE_CLIENT_ID: v.string(),
    AUTH_GOOGLE_CLIENT_SECRET: v.string(),
    // Unset on production. Only an explicit "1" enables simulator test accounts.
    WALKIES_TEST_SIGNIN: v.optional(v.string()),
    // The switch for research from walks. Only an explicit "1" lets walks start paid
    // research runs for new suburbs, and quiet or failed ones go back on the queue (lore.ts).
    LORE_AUTO: v.optional(v.string()),
    // For the research, writing, fact-checking and sticker calls. Only read in actions.
    OPENROUTER_API_KEY: v.optional(v.string()),
  },
});

app.use(core, {
  httpPrefix: "/auth",
  env: {
    AUTH_PRIVATE_KEY: app.env.AUTH_PRIVATE_KEY,
    AUTH_JWKS: app.env.AUTH_JWKS,
  },
});

// Apple and Google send people back to <site>/oauth/apple/callback and
// <site>/oauth/google/callback, so those are the return URLs to register.
app.use(apple, {
  httpPrefix: "/oauth/apple",
  env: {
    CLIENT_ID: app.env.AUTH_APPLE_CLIENT_ID,
    TEAM_ID: app.env.AUTH_APPLE_TEAM_ID,
    KEY_ID: app.env.AUTH_APPLE_KEY_ID,
    PRIVATE_KEY: app.env.AUTH_APPLE_PRIVATE_KEY,
  },
});
app.use(google, {
  httpPrefix: "/oauth/google",
  env: {
    CLIENT_ID: app.env.AUTH_GOOGLE_CLIENT_ID,
    CLIENT_SECRET: app.env.AUTH_GOOGLE_CLIENT_SECRET,
  },
});
app.use(anonymous);

// Chef: requests, voting and approvals.
app.use(feedback);

// The website (web/, `npm run web:upload:prod`). http.ts serves it under its own routes.
app.use(staticHosting);

// Secrets for new suburbs: the research pipeline's steps (lorePipeline.ts) and the
// threads its research agents keep their searches and pages in.
app.use(workflow);
app.use(agent);

// The history of the research's state machines (machines.ts, loreMachines.ts).
app.use(stateMachines);

export default app;
