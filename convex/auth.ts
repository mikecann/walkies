import { setupConvexAuth } from "@convex-dev/auth/server";
import { setupUsernamePasskey } from "@convex-dev/auth/methods/username-passkey/server";
import { components, internal } from "./_generated/api";
import { env } from "./_generated/server";

const auth = setupConvexAuth({ component: components.auth });
export const { signOut, refreshSession, isAuthenticated } = auth;

// Passkeys belong to this deployment's own site domain. The iPhone app is allowed
// to use them because http.ts serves Apple's association file from that domain,
// and on iPhone a passkey's origin is always https://<the domain>.
const site = new URL(env.CONVEX_SITE_URL);

export const {
  startSignInWithUsernamePasskey,
  startAutofillSignInWithUsernamePasskey,
  finishSignUpWithUsernamePasskey,
  finishSignInWithUsernamePasskey,
} = setupUsernamePasskey(auth, {
  component: components.authPasskey,
  usernameComponent: components.authUsername,
  rpId: site.host,
  origin: site.origin,
  rpName: "Walkies",
}).attachUserCallbacks({ createUser: internal.users.createUser });
