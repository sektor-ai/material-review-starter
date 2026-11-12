import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { setTransport } from "./api.ts";
import { App } from "./App.tsx";
import "./styles.css";

// mockEnabled decides whether to serve the API from the in-browser dev mock
// (src/mock) instead of the Go backend. VITE_MOCK_API=1 turns it on for the
// dev server; ?mock=1 / ?mock=0 toggles it for this browser. Production
// builds never include it: import.meta.env.DEV is false there, so the
// dynamic import below is dropped.
function mockEnabled(): boolean {
  if (!import.meta.env.DEV) return false;
  try {
    const param = new URLSearchParams(window.location.search).get("mock");
    if (param === "1" || param === "0") localStorage.setItem("mockApi", param);
    const saved = localStorage.getItem("mockApi");
    if (saved !== null) return saved === "1";
  } catch {
    // Storage blocked: fall back to the env var.
  }
  return import.meta.env.VITE_MOCK_API === "1";
}

async function start() {
  if (import.meta.env.DEV && mockEnabled()) {
    const { createMockApi } = await import("./mock/index.ts");
    // ?as=bob signs this tab in as Bob, so two tabs can be two users.
    const as = new URLSearchParams(window.location.search).get("as");
    if (as) sessionStorage.setItem("mockApi.user", `${as}@example.com`);
    const mock = createMockApi();
    setTransport(mock.transport, mock.originalUrl);
    document.title = `${document.title} (mock API)`;
  }

  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: 1 } },
  });

  createRoot(document.getElementById("root")!).render(
    <StrictMode>
      <QueryClientProvider client={queryClient}>
        <App />
      </QueryClientProvider>
    </StrictMode>,
  );
}

void start();
