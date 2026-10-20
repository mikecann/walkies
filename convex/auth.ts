import { setupConvexAuth } from "@convex-dev/auth/server";
import { setupApple } from "@convex-dev/auth/methods/apple/server";
import { setupGoogle } from "@convex-dev/auth/methods/google/server";
import { setupAnonymous } from "@convex-dev/auth/methods/anonymous/server";
import type { SignInComplete } from "@convex-dev/auth";
import { ConvexError, v } from "convex/values";
import { api, components, internal } from "./_generated/api";
import { env, mutation } from "./_generated/server";

const auth = setupConvexAuth({ component: components.auth });
export const { signOut, refreshSession, isAuthenticated } = auth;

export const { signInAnonymously } = setupAnonymous(auth, {
  component: components.authAnonymous,
}).attachUserCallbacks({ createUser: internal.users.createUserAnonymous });

/** A fresh anonymous account, optionally named for its simulator (e.g. Sim A). */
export const signInForTesting = mutation({
  args: { name: v.optional(v.string()) },
  handler: async (ctx, { name }): Promise<SignInComplete> => {
    if (env.WALKIES_TEST_SIGNIN !== "1") {
      throw new ConvexError("Test sign-in is disabled on this deployment.");
    }
    const displayName = name?.trim();
    if (displayName && displayName.length > 80) {
      throw new ConvexError("Test names must be 80 characters or fewer.");
    }
    const result = await ctx.runMutation(api.auth.signInAnonymously, {});
    // Use only the newly minted user id, never a caller-supplied account id.
    if (displayName) {
      const userId = ctx.db.normalizeId("users", result.tokens.userId);
      if (userId === null) throw new Error("Invalid test user id");
      await ctx.db.patch("users", userId, { name: displayName });
    }
    return result;
  },
});

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
