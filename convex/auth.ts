import { setupConvexAuth } from "@convex-dev/auth/server";
import { setupApple } from "@convex-dev/auth/methods/apple/server";
import { setupGoogle } from "@convex-dev/auth/methods/google/server";
import { components, internal } from "./_generated/api";
import { env } from "./_generated/server";

const auth = setupConvexAuth({ component: components.auth });
export const { signOut, refreshSession, isAuthenticated } = auth;

// The iPhone app runs Apple's and Google's sign-in pages in a secure sheet, which
// ends on this deployment's own site (see http.ts). The app is linked to that
// domain, so the sheet hands the one-time code straight back to it.
const allowedRedirectOrigins = [new URL(env.CONVEX_SITE_URL).origin];

export const { startSignInWithApple, completeSignInWithApple } = setupApple(auth, {
  component: components.authApple,
  allowedRedirectOrigins,
}).attachUserCallbacks({
  createUser: internal.users.createUserApple,
  onSignIn: internal.users.onSignInApple,
});

export const { startSignInWithGoogle, completeSignInWithGoogle } = setupGoogle(auth, {
  component: components.authGoogle,
  allowedRedirectOrigins,
}).attachUserCallbacks({
  createUser: internal.users.createUserGoogle,
  onSignIn: internal.users.onSignInGoogle,
});
