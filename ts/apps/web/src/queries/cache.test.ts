import { create } from "@bufbuild/protobuf";
import { timestampFromMs } from "@bufbuild/protobuf/wkt";
import { describe, expect, it } from "vitest";
import { QueryClient } from "@tanstack/react-query";
import { GetPackResponseSchema, IssueEventSchema, IssueSchema, PackSchema, PackStatus, ReviewRunSchema, ReviewRunStatus } from "@app/api";
import {
  advanceCursor,
  appendEvent,
  keys,
  latestRun,
  mergeIssues,
  mergePackResponse,
  newerRunState,
  upsertIssue,
  upsertRun,
  writeIssue,
  type IssuesData,
} from "./cache.ts";

const issue = (id: string, version: number, title = `${id} v${version}`) =>
  create(IssueSchema, { id, version, title, packId: "p" });
const event = (seq: bigint) => create(IssueEventSchema, { seq, issueId: "a" });
const run = (id: string, createdMs: number) => create(ReviewRunSchema, { id, packId: "p", createdAt: timestampFromMs(createdMs) });

describe("upsertIssue", () => {
  const cases = [
    { name: "adds a new issue", list: [issue("a", 1)], incoming: issue("b", 1), want: ["a v1", "b v1"] },
    { name: "replaces with a newer version", list: [issue("a", 1)], incoming: issue("a", 2), want: ["a v2"] },
    { name: "ignores the same version", list: [issue("a", 2)], incoming: issue("a", 2, "replayed"), want: ["a v2"] },
    { name: "ignores an older version (replay after reconnect)", list: [issue("a", 3)], incoming: issue("a", 2), want: ["a v3"] },
  ];
  for (const c of cases) {
    it(c.name, () => {
      expect(upsertIssue(c.list, c.incoming).map((i) => i.title)).toEqual(c.want);
    });
  }

  it("returns the same array when nothing changed", () => {
    const list = [issue("a", 2)];
    expect(upsertIssue(list, issue("a", 1))).toBe(list);
  });
});

describe("mergeIssues", () => {
  it("keeps a newer cached version over an older fetched snapshot", () => {
    const merged = mergeIssues([issue("a", 3), issue("b", 1)], [issue("a", 2), issue("b", 2)]);
    expect(merged.map((i) => i.title)).toEqual(["a v3", "b v2"]);
  });

  it("uses the fetched list when nothing is cached", () => {
    const fetched = [issue("a", 1)];
    expect(mergeIssues(undefined, fetched)).toBe(fetched);
  });
});

describe("appendEvent", () => {
  it("adds once and keeps seq order", () => {
    let events = appendEvent([], event(3n));
    events = appendEvent(events, event(1n));
    events = appendEvent(events, event(3n));
    expect(events.map((e) => e.seq)).toEqual([1n, 3n]);
  });
});

describe("runs", () => {
  it("upsertRun replaces by id and orders newest first", () => {
    const runs = upsertRun([run("old", 1), run("new", 2)], create(ReviewRunSchema, { ...run("old", 1), summary: "x" }));
    expect(runs.map((r) => [r.id, r.summary])).toEqual([
      ["new", ""],
      ["old", "x"],
    ]);
  });

  it("latestRun takes an update to the same run or a newer run, not an older one", () => {
    expect(latestRun(run("a", 5), run("a", 5))?.id).toBe("a");
    expect(latestRun(run("a", 5), run("b", 6))?.id).toBe("b");
    expect(latestRun(run("a", 5), run("b", 4))?.id).toBe("a");
    expect(latestRun(undefined, run("b", 4))?.id).toBe("b");
  });
});

describe("newerRunState", () => {
  const at = (status: ReviewRunStatus, issuesCreated = 0) => create(ReviewRunSchema, { id: "r", status, issuesCreated });
  const cases = [
    { name: "a later stage wins", cur: at(ReviewRunStatus.RUNNING), inc: at(ReviewRunStatus.SUCCEEDED), want: ReviewRunStatus.SUCCEEDED },
    { name: "an earlier stage loses (stale refetch)", cur: at(ReviewRunStatus.SUCCEEDED), inc: at(ReviewRunStatus.RUNNING), want: ReviewRunStatus.SUCCEEDED },
    { name: "queued never overrides running", cur: at(ReviewRunStatus.RUNNING), inc: at(ReviewRunStatus.QUEUED), want: ReviewRunStatus.RUNNING },
  ];
  for (const c of cases) {
    it(c.name, () => expect(newerRunState(c.cur, c.inc).status).toBe(c.want));
  }

  it("within a stage keeps the snapshot with more issues raised", () => {
    expect(newerRunState(at(ReviewRunStatus.RUNNING, 3), at(ReviewRunStatus.RUNNING, 2)).issuesCreated).toBe(3);
    expect(newerRunState(at(ReviewRunStatus.RUNNING, 2), at(ReviewRunStatus.RUNNING, 3)).issuesCreated).toBe(3);
  });
});

describe("mergePackResponse", () => {
  const pack = (updatedMs: number, status: PackStatus) =>
    create(PackSchema, { id: "p", status, updatedAt: timestampFromMs(updatedMs) });
  const runAt = (status: ReviewRunStatus) => create(ReviewRunSchema, { id: "r", packId: "p", status, createdAt: timestampFromMs(1) });

  it("keeps newer streamed pack and run state over an older refetch", () => {
    const cached = create(GetPackResponseSchema, {
      pack: pack(2000, PackStatus.RESOLVED),
      latestRun: runAt(ReviewRunStatus.SUCCEEDED),
    });
    const fetched = create(GetPackResponseSchema, {
      pack: pack(1000, PackStatus.OPEN),
      latestRun: runAt(ReviewRunStatus.RUNNING),
      documents: [{ id: "d" }],
    });
    const merged = mergePackResponse(cached, fetched);
    expect(merged.pack?.status).toBe(PackStatus.RESOLVED);
    expect(merged.latestRun?.status).toBe(ReviewRunStatus.SUCCEEDED);
    expect(merged.documents.map((d) => d.id)).toEqual(["d"]);
  });

  it("takes a newer refetch", () => {
    const cached = create(GetPackResponseSchema, { pack: pack(1000, PackStatus.OPEN) });
    const fetched = create(GetPackResponseSchema, { pack: pack(2000, PackStatus.APPROVED) });
    expect(mergePackResponse(cached, fetched).pack?.status).toBe(PackStatus.APPROVED);
  });
});

describe("writeIssue and advanceCursor", () => {
  function cache() {
    const qc = new QueryClient();
    qc.setQueryData<IssuesData>(keys.issues("p"), { issues: [issue("a", 2)], cursorSeq: 5n });
    return qc;
  }

  it("reports whether the cache changed, so replays aren't news", () => {
    const qc = cache();
    expect(writeIssue(qc, issue("a", 2))).toBe(false);
    expect(writeIssue(qc, issue("a", 1))).toBe(false);
    expect(writeIssue(qc, issue("a", 3))).toBe(true);
    expect(writeIssue(qc, issue("b", 1))).toBe(true);
  });

  it("only moves the cursor forward", () => {
    const qc = cache();
    advanceCursor(qc, "p", 9n);
    advanceCursor(qc, "p", 7n);
    expect(qc.getQueryData<IssuesData>(keys.issues("p"))?.cursorSeq).toBe(9n);
  });
});
