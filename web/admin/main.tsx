// The admin page at walkies.mikecann.app/admin/machines: sign in with Google or Apple (the
// same web flows the iPhone app's sheet uses), then, for Chef's admin only, the state
// machines viewer on the deployment's live data. convex/viewer.ts decides who's an admin
// and answers null to everyone else, so nothing here is the gate; it only shows the answer.
// scripts/build-web.mjs builds it into web/dist/admin, and convex/http.ts serves it.
import { StrictMode, useState, type ReactNode } from "react";
import { createRoot } from "react-dom/client";
import { ConvexReactClient, useConvexAuth, useQuery } from "convex/react";
import { ConvexAuthProvider, useAuthActions } from "@convex-dev/auth/react";
import { useSignInWithGoogle } from "@convex-dev/auth/methods/google/react";
import { useOauth, useSignInWithApple } from "@convex-dev/auth/methods/apple/react";
import { MachinesViewer } from "@convex-dev/state-machines/viewer";
import "@convex-dev/state-machines/viewer.css";
import { api } from "../../convex/_generated/api";
import "./admin.css";

const PAGE = "/admin/machines";
const convex = new ConvexReactClient(import.meta.env.VITE_CONVEX_URL as string);

function Spinner() {
  return <span className="spinner" aria-hidden="true" />;
}

function Screen({ children }: { children: ReactNode }) {
  return <main className="screen">{children}</main>;
}

function SignIn() {
  const { signIn: google } = useSignInWithGoogle(api.auth);
  const { signIn: apple } = useSignInWithApple(api.auth);
  const { flowError } = useOauth();
  // Which button was pressed: it spins and both stay off until the page leaves for the
  // provider, or the start fails and they come back.
  const [pending, setPending] = useState<"google" | "apple" | null>(null);
  const [failed, setFailed] = useState(false);

  const start = async (provider: "google" | "apple") => {
    setPending(provider);
    setFailed(false);
    // Back to this page, keeping the viewer's place (its #/ route).
    const redirectTo = `${window.location.origin}${PAGE}${window.location.hash}`;
    const result = await (provider === "google" ? google : apple)({ redirectTo });
    if (result.status === "error") {
      setPending(null);
      setFailed(true);
    }
  };

  const problem = failed || (flowError !== null && flowError.error !== "ACCESS_DENIED");
  return (
    <Screen>
      <div className="card">
        <img className="mark" src="/img/icon-192.png" alt="" width="64" height="64" />
        <h1>Walkies admin</h1>
        <div className="buttons">
          <button type="button" className="button" disabled={pending !== null} onClick={() => void start("google")}>
            {pending === "google" ? <Spinner /> : <GoogleLogo />}
            Continue with Google
          </button>
          <button type="button" className="button" disabled={pending !== null} onClick={() => void start("apple")}>
            {pending === "apple" ? <Spinner /> : <AppleLogo />}
            Continue with Apple
          </button>
        </div>
        {problem && <p className="note" role="alert">That didn't work. Try again.</p>}
      </div>
    </Screen>
  );
}

function SignOutButton() {
  const { signOut } = useAuthActions();
  const [pending, setPending] = useState(false);
  return (
    <button
      type="button"
      className="button quiet"
      disabled={pending}
      onClick={() => {
        setPending(true);
        // Signed out, the page swaps to the sign-in; if it fails, the button comes back.
        void signOut().catch(() => setPending(false));
      }}
    >
      {pending && <Spinner />}
      Sign out
    </button>
  );
}

function Admin() {
  const me = useQuery(api.users.me, {});
  // The same query the viewer opens first, so it's one subscription: null means not an admin.
  const overview = useQuery(api.viewer.overview, {});
  if (me === undefined || overview === undefined) return <Loading />;
  if (overview === null) {
    return (
      <Screen>
        <div className="card">
          <h1>Not an admin</h1>
          {me?.email && <p className="note">{me.email}</p>}
          <SignOutButton />
        </div>
      </Screen>
    );
  }
  return (
    <div className="admin">
      <header className="bar">
        <img src="/img/icon-192.png" alt="" width="24" height="24" />
        <span className="title">Machines</span>
        <span className="who">{me?.email ?? me?.name}</span>
        <SignOutButton />
      </header>
      <MachinesViewer functions={api.viewer} config={{ settings: { theme: "dark" } }} />
    </div>
  );
}

function Loading() {
  return (
    <Screen>
      <Spinner />
    </Screen>
  );
}

function App() {
  const { isLoading, isAuthenticated } = useConvexAuth();
  if (isLoading) return <Loading />;
  return isAuthenticated ? <Admin /> : <SignIn />;
}

function GoogleLogo() {
  return (
    <svg className="logo" viewBox="0 0 24 24" aria-hidden="true">
      <path fill="#4285F4" d="M23.5 12.27c0-.85-.08-1.67-.22-2.45H12v4.64h6.45a5.5 5.5 0 0 1-2.4 3.62v3h3.88c2.27-2.1 3.57-5.18 3.57-8.81Z" />
      <path fill="#34A853" d="M12 24c3.24 0 5.96-1.07 7.94-2.92l-3.88-3c-1.07.72-2.45 1.15-4.06 1.15-3.13 0-5.78-2.11-6.72-4.95H1.27v3.1A12 12 0 0 0 12 24Z" />
      <path fill="#FBBC05" d="M5.28 14.28a7.2 7.2 0 0 1 0-4.56v-3.1H1.27a12 12 0 0 0 0 10.76l4.01-3.1Z" />
      <path fill="#EA4335" d="M12 4.77c1.76 0 3.34.6 4.59 1.8l3.44-3.44A11.97 11.97 0 0 0 1.27 6.62l4.01 3.1C6.22 6.88 8.87 4.77 12 4.77Z" />
    </svg>
  );
}

function AppleLogo() {
  return (
    <svg className="logo" viewBox="0 0 24 24" aria-hidden="true">
      <path fill="currentColor" d="M16.37 12.6c-.02-2.2 1.8-3.26 1.88-3.31-1.03-1.5-2.62-1.7-3.18-1.73-1.35-.14-2.65.8-3.33.8-.7 0-1.75-.78-2.88-.76-1.48.02-2.85.86-3.61 2.19-1.55 2.68-.4 6.63 1.1 8.8.74 1.06 1.61 2.25 2.75 2.2 1.11-.04 1.52-.71 2.86-.71 1.33 0 1.71.71 2.87.69 1.19-.02 1.94-1.07 2.66-2.14.85-1.23 1.19-2.43 1.21-2.49-.03-.01-2.31-.89-2.33-3.54ZM14.2 6.17c.6-.74 1.01-1.75.9-2.77-.87.04-1.94.59-2.56 1.32-.56.64-1.05 1.69-.92 2.68.97.08 1.97-.49 2.58-1.23Z" />
    </svg>
  );
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <ConvexAuthProvider client={convex} api={{ refreshSession: api.auth.refreshSession, signOut: api.auth.signOut }}>
      <App />
    </ConvexAuthProvider>
  </StrictMode>,
);
