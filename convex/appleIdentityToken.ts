import { createLocalJWKSet, jwtVerify } from "jose";
import { ConvexError } from "convex/values";
import type { normalizeAppleProfile } from "@convex-dev/auth/methods/apple/server";

// Native Sign in with Apple (the iPhone's own sheet, ASAuthorizationAppleIDProvider) hands
// the app an identity token: a JWT Apple signs, addressed to the app's bundle ID. This
// checks one the way Apple says to
// (https://developer.apple.com/documentation/sign_in_with_apple/verifying-a-user), so
// auth:signInWithAppleNative can trust its `sub` and email.

/** The app's bundle ID: the `aud` Apple puts on tokens it issues to the iPhone app. */
export const APPLE_BUNDLE_ID = "com.mikecann.walkies";
const ISSUER = "https://appleid.apple.com";
const KEYS_URL = "https://appleid.apple.com/auth/keys";

export type AppleClaims = Parameters<typeof normalizeAppleProfile>[0];

const refused = () =>
  new ConvexError({ code: "appleTokenInvalid", message: "Apple didn't confirm who you are. Try signing in again." });

export async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * The token's claims, once it's checked out: signed with one of Apple's published keys,
 * issued by Apple, for this app, not expired, and carrying the hash of `nonce`, the random
 * value the app made for this one sign-in (so a token can't be lifted from another one).
 * Anything else throws the same "Apple didn't confirm" error.
 */
export async function verifyAppleIdentityToken(token: string, nonce: string): Promise<AppleClaims> {
  // Fetched each time rather than cached: signing in is rare, and Apple rotates its keys.
  const res = await fetch(KEYS_URL);
  if (!res.ok) throw new ConvexError({ code: "appleUnavailable", message: "Couldn't reach Apple. Try again." });
  const keys = createLocalJWKSet(await res.json());
  let payload;
  try {
    ({ payload } = await jwtVerify(token, keys, { issuer: ISSUER, audience: APPLE_BUNDLE_ID, algorithms: ["RS256"] }));
  } catch {
    throw refused();
  }
  if (typeof payload.sub !== "string" || payload.sub === "") throw refused();
  if (payload.nonce !== (await sha256Hex(nonce))) throw refused();
  return payload as AppleClaims;
}

/** The name the phone passed on (Apple only gives it the first time), cleaned like Convex Auth's web flow does. */
export function appleName(firstName?: string, lastName?: string) {
  const part = (s?: string) => {
    const trimmed = s?.trim();
    return trimmed && trimmed.length <= 256 ? trimmed : undefined;
  };
  const name = { firstName: part(firstName), lastName: part(lastName) };
  return name.firstName || name.lastName ? { name } : undefined;
}
