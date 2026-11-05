import { setupConvexAuth } from "@convex-dev/auth/server";
import { normalizeAppleProfile, setupApple, type AppleProfile } from "@convex-dev/auth/methods/apple/server";
import { setupGoogle } from "@convex-dev/auth/methods/google/server";
import { setupAnonymous } from "@convex-dev/auth/methods/anonymous/server";
import type { SignInComplete, TokenBundle } from "@convex-dev/auth";
import type { ObjectType, PropertyValidators } from "convex/values";
import type { RegisteredAction } from "convex/server";
import { ConvexError, v } from "convex/values";
import { api, components, internal } from "./_generated/api";
import { env, mutation, type ActionCtx } from "./_generated/server";
import { appleName, verifyAppleIdentityToken } from "./appleIdentityToken";

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

// Native Sign in with Apple (below) has to sign people into the same accounts as the web
// flow, and Convex Auth keys accounts by provider name plus Apple's `sub`. A second provider
// can't take the name "apple" (bindProvider refuses duplicates), so this hands setupApple a
// core that keeps the "apple" binding's function builders for signInWithAppleNative too.
// bindProvider is marked internal in 2.0.0-beta.0: check this still works when upgrading.
type AppleHelpers = {
  resolveUserId(providerAccountId: string): Promise<string | null>;
  completeSignUp(args: { providerAccountId: string; profile: AppleProfile }): Promise<TokenBundle>;
  completeSignIn(args: { providerAccountId: string; profile: AppleProfile }): Promise<TokenBundle>;
};
type AppleBuilders = {
  authAction<Args extends PropertyValidators, Result>(fn: {
    args: Args;
    handler: (ctx: ActionCtx & { convexAuth: AppleHelpers }, args: ObjectType<Args>) => Promise<Result>;
  }): RegisteredAction<"public", ObjectType<Args>, Promise<Result>>;
};
type CoreWithBind = typeof auth & { bindProvider(options: unknown): AppleBuilders };
let appleBuilders: AppleBuilders | undefined;
const appleCore = {
  ...auth,
  bindProvider: (options: unknown) => (appleBuilders = (auth as CoreWithBind).bindProvider(options)),
} as typeof auth;

export const { startSignInWithApple, completeSignInWithApple } = setupApple(appleCore, {
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

if (!appleBuilders) throw new Error("setupApple didn't bind its provider: native Sign in with Apple can't share its accounts");

/**
 * Sign in with the iPhone's own Apple sheet: the app sends the identity token Apple gave it,
 * the nonce it made for this attempt, and (first time only) the name Apple passed on. Mike
 * wants the system sheet in all his apps rather than Apple's web page. Same accounts and user
 * callbacks as the web flow, since it's the same "apple" provider and Apple's `sub` is the
 * same for the app and the Services ID.
 */
export const signInWithAppleNative = appleBuilders.authAction({
  args: {
    identityToken: v.string(),
    nonce: v.string(),
    firstName: v.optional(v.string()),
    lastName: v.optional(v.string()),
  },
  handler: async (ctx, args): Promise<SignInComplete> => {
    const claims = await verifyAppleIdentityToken(args.identityToken, args.nonce);
    const profile = normalizeAppleProfile(claims, appleName(args.firstName, args.lastName));
    // Like Convex Auth's own completion: a first sign-in makes the account, a return visit finds it.
    const existing = await ctx.convexAuth.resolveUserId(profile.id);
    const tokens =
      existing === null
        ? await ctx.convexAuth.completeSignUp({ providerAccountId: profile.id, profile })
        : await ctx.convexAuth.completeSignIn({ providerAccountId: profile.id, profile });
    return { status: "complete", tokens };
  },
});
