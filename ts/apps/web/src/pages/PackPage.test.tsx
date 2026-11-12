// @vitest-environment jsdom
import { create } from "@bufbuild/protobuf";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { IssueStatus, UpdateIssueRequestSchema, type Issue } from "@app/api";
import { setTransport } from "../api.ts";
import { App } from "../App.tsx";
import { createMockApi, type MockApi, type SessionStore } from "../mock/index.ts";
import { mockUsers } from "../mock/seed.ts";

// End to end through the UI: the app runs against the in-browser mock, and
// "Bob" changes data directly in the mock store, as another browser would.

function memorySession(): SessionStore {
  let value: string | null = "alice@example.com";
  return { get: () => value, set: (v) => (value = v) };
}

let api: MockApi;

beforeEach(() => {
  api = createMockApi({ isolated: true, session: memorySession(), latencyMs: 0, agentStepMs: 20 });
  setTransport(api.transport);
  const s001 = [...api.store.packs.values()].find((p) => p.submittalNo === "S-001")!;
  window.history.pushState(null, "", `/packs/${s001.id}`);
});

afterEach(cleanup);

function renderApp() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={qc}>
      <App />
    </QueryClientProvider>,
  );
}

function openIssue(title: string): Issue {
  return [...api.store.issues.values()].find((i) => i.title === title && i.status === IssueStatus.OPEN)!;
}

function bobUpdates(issue: Issue, fields: { title?: string; severity?: number }) {
  act(() => {
    api.store.updateIssue(
      mockUsers.bob,
      create(UpdateIssueRequestSchema, { id: issue.id, expectedVersion: issue.version, ...fields }),
    );
  });
}

const W_C = "Water/cementitious ratio exceeds the maximum for C40";

describe("PackPage", () => {
  it("shows another user's change live, marked with who made it", async () => {
    renderApp();
    await screen.findByText(W_C);
    await screen.findByText("Live");

    bobUpdates(openIssue(W_C), { title: "W/C ratio 0.55 > 0.50" });

    const row = (await screen.findByText("W/C ratio 0.55 > 0.50")).closest("tr")!;
    expect(within(row).getByText("Updated by Bob Chen")).toBeTruthy();
    expect(row.className).toContain("flash");
  });

  it("warns while editing, and refuses a save over someone else's change", async () => {
    renderApp();
    const row = (await screen.findByText(W_C)).closest("tr")!;
    await screen.findByText("Live");
    fireEvent.click(within(row).getByText("Edit"));
    const dialog = await screen.findByRole("dialog");
    fireEvent.change(within(dialog).getByLabelText("Evidence", { exact: false }), {
      target: { value: "My evidence" },
    });

    bobUpdates(openIssue(W_C), { severity: 2 });
    await within(dialog).findByText(/Bob Chen changed this issue while you were editing/);

    fireEvent.click(within(dialog).getByText("Save"));
    await within(dialog).findByText("Not saved.");
    expect(openIssue(W_C).evidence).not.toBe("My evidence");

    // Keeping mine re-bases the edit on Bob's version; saving then applies
    // only my field and leaves his severity change in place.
    fireEvent.click(within(dialog).getByText("Keep mine on top of theirs"));
    fireEvent.click(within(dialog).getByText("Save"));
    await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
    expect(openIssue(W_C).evidence).toBe("My evidence");
    expect(openIssue(W_C).severity).toBe(2);
    expect(openIssue(W_C).updatedBy?.name).toBe("Alice Morgan");
  });

  it("closes an issue with a reason that shows in its history", async () => {
    renderApp();
    const row = (await screen.findByText(W_C)).closest("tr")!;
    fireEvent.click(within(row).getByText("Close…"));
    const dialog = await screen.findByRole("dialog");
    fireEvent.change(within(dialog).getByLabelText(/Reason/), { target: { value: "Resubmitted at 0.45" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Close issue" }));
    await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());

    const closedRow = (await screen.findByText(W_C)).closest("tr")!;
    fireEvent.click(within(closedRow).getByText("History"));
    const drawer = await screen.findByRole("dialog");
    await within(drawer).findByText("“Resubmitted at 0.45”");
    expect(within(drawer).getByText("Alice Morgan")).toBeTruthy();
  });
});
