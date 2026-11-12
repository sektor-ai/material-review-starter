import { useSyncExternalStore, type MouseEvent, type ReactNode } from "react";

// A two-route router: the app has a pack list and a pack page, which does
// not justify a routing dependency.

export type Route = { name: "packs" } | { name: "pack"; id: string } | { name: "notFound" };

export function parseRoute(pathname: string): Route {
  if (pathname === "/" || pathname === "") return { name: "packs" };
  const match = /^\/packs\/([^/]+)\/?$/.exec(pathname);
  if (match) return { name: "pack", id: decodeURIComponent(match[1]) };
  return { name: "notFound" };
}

export function packPath(id: string): string {
  return `/packs/${encodeURIComponent(id)}`;
}

const NAVIGATE = "app:navigate";

function subscribe(onChange: () => void) {
  window.addEventListener("popstate", onChange);
  window.addEventListener(NAVIGATE, onChange);
  return () => {
    window.removeEventListener("popstate", onChange);
    window.removeEventListener(NAVIGATE, onChange);
  };
}

export function useRoute(): Route {
  const pathname = useSyncExternalStore(subscribe, () => window.location.pathname);
  return parseRoute(pathname);
}

export function navigate(path: string) {
  if (path === window.location.pathname) return;
  window.history.pushState(null, "", path);
  window.dispatchEvent(new Event(NAVIGATE));
  window.scrollTo(0, 0);
}

export function Link({ to, className, children }: { to: string; className?: string; children: ReactNode }) {
  function handleClick(event: MouseEvent<HTMLAnchorElement>) {
    // Let the browser handle new-tab and other modified clicks.
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    navigate(to);
  }
  return (
    <a href={to} className={className} onClick={handleClick}>
      {children}
    </a>
  );
}
