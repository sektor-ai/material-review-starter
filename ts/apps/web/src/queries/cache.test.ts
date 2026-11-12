import { create } from "@bufbuild/protobuf";
import { timestampFromMs } from "@bufbuild/protobuf/wkt";
import { describe, expect, it } from "vitest";
import { IssueEventSchema, IssueSchema, ReviewRunSchema } from "@app/api";
import { appendEvent, latestRun, mergeIssues, upsertIssue, upsertRun } from "./cache.ts";

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
    expect(latestRun(run("a", 5), run("a", 5)).id).toBe("a");
    expect(latestRun(run("a", 5), run("b", 6)).id).toBe("b");
    expect(latestRun(run("a", 5), run("b", 4)).id).toBe("a");
    expect(latestRun(undefined, run("b", 4)).id).toBe("b");
  });
});
