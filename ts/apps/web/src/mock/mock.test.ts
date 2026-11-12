import { createClient } from "@connectrpc/connect";
import { QueryClient } from "@tanstack/react-query";
import { describe, expect, it } from "vitest";
import { create } from "@bufbuild/protobuf";
import { IssueService, IssueStatus, PackService, PackStatus, ReviewRunStatus, ReviewService, UpdateIssueRequestSchema } from "@app/api";
import { conflictIssue } from "../api.ts";
import { keys, type IssuesData } from "../queries/cache.ts";
import { applyWatchUpdate } from "../queries/watch.ts";
import { createMockApi, type SessionStore } from "./index.ts";
import { mockUsers, seed } from "./seed.ts";
import { MockStore, type Change } from "./store.ts";

// These tests run the mock through a real Connect transport, so they also
// check that the client code handles the contract as the proto describes it.

function memorySession(user = "alice@example.com"): SessionStore {
  let value: string | null = user;
  return { get: () => value, set: (v) => (value = v) };
}

function setup(user?: string) {
  const api = createMockApi({ isolated: true, session: memorySession(user), latencyMs: 0, agentStepMs: 20 });
  return {
    api,
    pack: createClient(PackService, api.transport),
    issue: createClient(IssueService, api.transport),
    review: createClient(ReviewService, api.transport),
  };
}

async function s001(c: ReturnType<typeof setup>) {
  const { packs } = await c.pack.listPacks({});
  return packs.find((p) => p.submittalNo === "S-001")!;
}

describe("mock API", () => {
  it("rejects a stale expected_version with the current issue attached", async () => {
    const c = setup();
    const pack = await s001(c);
    const { issues } = await c.issue.listIssues({ packId: pack.id });
    const target = issues.find((i) => i.status === IssueStatus.OPEN)!;

    await c.issue.updateIssue({ id: target.id, expectedVersion: target.version, title: "First edit" });
    const error = await c.issue
      .updateIssue({ id: target.id, expectedVersion: target.version, title: "Second edit" })
      .catch((e: unknown) => e);

    const current = conflictIssue(error);
    expect(current?.title).toBe("First edit");
    expect(current?.version).toBe(target.version + 1);
  });

  it("writes no event for an update that changes nothing", async () => {
    const c = setup();
    const pack = await s001(c);
    const { issues } = await c.issue.listIssues({ packId: pack.id });
    const res = await c.issue.updateIssue({ id: issues[0].id, expectedVersion: issues[0].version, title: issues[0].title });
    expect(res.event).toBeUndefined();
    expect(res.issue?.version).toBe(issues[0].version);
  });

  it("records who changed what", async () => {
    const c = setup("bob@example.com");
    const pack = await s001(c);
    const { issues } = await c.issue.listIssues({ packId: pack.id });
    const target = issues.find((i) => i.status === IssueStatus.OPEN)!;
    await c.issue.updateIssue({ id: target.id, expectedVersion: target.version, status: IssueStatus.CLOSED, note: "fixed" });

    const { events } = await c.issue.listIssueEvents({ issueId: target.id });
    const last = events.at(-1)!;
    expect(last.actor?.name).toBe("Bob Chen");
    expect(last.note).toBe("fixed");
    expect(last.changes.map((ch) => ch.field)).toEqual(["status"]);
  });

  it("streams a replay after the cursor, then live changes, into the query cache", async () => {
    const c = setup();
    const pack = await s001(c);
    const listed = await c.issue.listIssues({ packId: pack.id });
    const qc = new QueryClient();
    qc.setQueryData<IssuesData>(keys.issues(pack.id), { issues: listed.issues, cursorSeq: listed.cursorSeq });

    // A change made before the stream opens must arrive as a replay.
    const target = listed.issues.find((i) => i.status === IssueStatus.OPEN)!;
    await c.issue.updateIssue({ id: target.id, expectedVersion: target.version, title: "Changed before watch" });

    const abort = new AbortController();
    const seen: string[] = [];
    const done = (async () => {
      try {
        for await (const res of c.pack.watchPack({ packId: pack.id, afterSeq: listed.cursorSeq }, { signal: abort.signal })) {
          applyWatchUpdate(qc, res);
          seen.push(res.update.case ?? "none");
          if (seen.filter((s) => s === "issueChanged").length === 2) abort.abort();
        }
      } catch {
        // aborted
      }
    })();

    await new Promise((r) => setTimeout(r, 10));
    await c.issue.updateIssue({ id: target.id, expectedVersion: target.version + 1, title: "Changed during watch" });
    await done;

    expect(seen.slice(0, 2)).toEqual(["packUpdated", "runUpdated"]);
    const cached = qc.getQueryData<IssuesData>(keys.issues(pack.id))!;
    expect(cached.issues.find((i) => i.id === target.id)?.title).toBe("Changed during watch");
  });

  it("runs the scripted agent: issues by the agent, run succeeds, pack stays open", async () => {
    const c = setup();
    const { packs } = await c.pack.listPacks({});
    const s002 = packs.find((p) => p.submittalNo === "S-002")!;
    const { run } = await c.review.startReview({ packId: s002.id });
    await expect(c.review.startReview({ packId: s002.id })).rejects.toThrow(/already queued or running/);

    for (let i = 0; i < 100; i++) {
      const { run: current } = await c.review.getReviewRun({ id: run!.id });
      if (current?.status === ReviewRunStatus.SUCCEEDED) break;
      await new Promise((r) => setTimeout(r, 30));
    }
    const { issues } = await c.issue.listIssues({ packId: s002.id });
    expect(issues.length).toBe(4);
    expect(issues.every((i) => i.createdBy?.name === "Review agent" && i.runId === run!.id)).toBe(true);
    const { pack } = await c.pack.getPack({ id: s002.id });
    expect(pack?.status).toBe(PackStatus.OPEN);
    expect(pack?.openIssueCount).toBe(4);
  });

  it("resolves a reviewed pack when its last issue closes, and locks it once approved", async () => {
    const c = setup();
    const pack = await s001(c);
    const { issues } = await c.issue.listIssues({ packId: pack.id });
    for (const i of issues.filter((i) => i.status === IssueStatus.OPEN)) {
      await c.issue.updateIssue({ id: i.id, expectedVersion: i.version, status: IssueStatus.CLOSED });
    }
    expect((await c.pack.getPack({ id: pack.id })).pack?.status).toBe(PackStatus.RESOLVED);

    await c.pack.approvePack({ id: pack.id });
    await expect(
      c.issue.updateIssue({ id: issues[0].id, expectedVersion: 99, status: IssueStatus.OPEN }),
    ).rejects.toThrow(/approved/);
  });

  it("rejects approval while a review is in progress, as the backend does", async () => {
    const c = setup();
    const pack = await s001(c);
    const { issues } = await c.issue.listIssues({ packId: pack.id });
    for (const i of issues.filter((i) => i.status === IssueStatus.OPEN)) {
      await c.issue.updateIssue({ id: i.id, expectedVersion: i.version, status: IssueStatus.CLOSED });
    }
    await c.review.startReview({ packId: pack.id });
    await expect(c.pack.approvePack({ id: pack.id })).rejects.toThrow(/review in progress/);
  });

  it("keeps both events when two tabs commit at once", () => {
    // Two tabs: each holds its own store, seeded the same, and receives the
    // other's commits, as BroadcastChannel delivers them.
    const tabA = new MockStore(mockUsers.agent);
    seed(tabA);
    const tabB = new MockStore(mockUsers.agent);
    for (const event of tabA.events) tabB.apply({ kind: "issue", issue: tabA.issues.get(event.issueId)!, event });
    for (const pack of tabA.packs.values()) tabB.apply({ kind: "pack", pack });

    const fromA: Change[] = [];
    const fromB: Change[] = [];
    tabA.onCommit = (ch) => fromA.push(ch);
    tabB.onCommit = (ch) => fromB.push(ch);
    const open = [...tabA.issues.values()].filter((i) => i.status === IssueStatus.OPEN);
    const update = (id: string, version: number, title: string) =>
      create(UpdateIssueRequestSchema, { id, expectedVersion: version, title });
    tabA.updateIssue(mockUsers.alice, update(open[0].id, open[0].version, "A's edit"));
    tabB.updateIssue(mockUsers.bob, update(open[1].id, open[1].version, "B's edit"));
    for (const ch of fromA) tabB.apply(ch);
    for (const ch of fromB) tabA.apply(ch);

    for (const tab of [tabA, tabB]) {
      expect(tab.issues.get(open[0].id)?.title).toBe("A's edit");
      expect(tab.issues.get(open[1].id)?.title).toBe("B's edit");
      expect(tab.events.length).toBe(tabA.events.length);
    }
  });
});
