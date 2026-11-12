import type { User } from "@app/api";
import { LoginPage } from "./LoginPage.tsx";
import { PackPage } from "./pages/PackPage.tsx";
import { PacksPage } from "./pages/PacksPage.tsx";
import { Link, useRoute } from "./router.tsx";
import { useMe, useSignOut } from "./session.ts";

export function App() {
  const { data: user, isPending, error } = useMe();

  if (isPending) return <main className="centered">Loading…</main>;
  if (error) return <main className="centered">Could not reach the API: {error.message}</main>;
  if (!user) return <LoginPage />;
  return <Shell user={user} />;
}

function Shell({ user }: { user: User }) {
  const route = useRoute();
  const signOut = useSignOut();
  return (
    <>
      <header className="topbar">
        <Link to="/" className="brand">
          Document Review
        </Link>
        <span>
          Signed in as {user.name}
          <button className="secondary" onClick={() => signOut.mutate()} disabled={signOut.isPending}>
            Sign out
          </button>
        </span>
      </header>
      <main className="page">
        {route.name === "packs" && <PacksPage />}
        {route.name === "pack" && <PackPage key={route.id} id={route.id} me={user} />}
        {route.name === "notFound" && (
          <p>
            Page not found. <Link to="/">Back to submittals</Link>
          </p>
        )}
      </main>
    </>
  );
}
