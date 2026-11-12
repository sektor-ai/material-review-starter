import type { QueryClient } from "@tanstack/react-query";
import type { GetPackResponse, Issue, IssueEvent, ListPacksResponse, Pack, ReviewRun } from "@app/api";
import { toDate } from "../format.ts";

// Query keys and cache writes shared by the query hooks and the WatchPack
// stream. Mutation responses and stream updates both go through these, and
// every write keeps the higher version, so the order they arrive in does not
// matter.

export const keys = {
  packs: ["packs"] as const,
  pack: (id: string) => ["pack", id] as const,
  document: (id: string) => ["document", id] as const,
  issues: (packId: string) => ["issues", packId] as const,
  issueEvents: (issueId: string) => ["issueEvents", issueId] as const,
  runs: (packId: string) => ["runs", packId] as const,
};

// IssuesData is what the issues query caches: the issues and the event
// cursor read in the same snapshot, for WatchPack to resume from.
export type IssuesData = { issues: Issue[]; cursorSeq: bigint };

// upsertIssue inserts the issue, or replaces the cached copy if the incoming
// one is newer. It returns the input array when nothing changed.
export function upsertIssue(issues: Issue[], incoming: Issue): Issue[] {
  const index = issues.findIndex((i) => i.id === incoming.id);
  if (index === -1) return [...issues, incoming];
  if (issues[index].version >= incoming.version) return issues;
  const next = issues.slice();
  next[index] = incoming;
  return next;
}

// mergeIssues folds a fresh list into the cached one, keeping the higher
// version of each issue. A refetch can return a snapshot that is older than
// an update the stream already delivered; this keeps the newer one.
export function mergeIssues(cached: Issue[] | undefined, fetched: Issue[]): Issue[] {
  if (!cached) return fetched;
  let merged = fetched;
  for (const issue of cached) merged = upsertIssue(merged, issue);
  return merged;
}

// appendEvent adds an event to an issue's history once, in seq order.
export function appendEvent(events: IssueEvent[], event: IssueEvent): IssueEvent[] {
  if (events.some((e) => e.seq === event.seq)) return events;
  return [...events, event].sort((a, b) => (a.seq < b.seq ? -1 : a.seq > b.seq ? 1 : 0));
}

function createdMs(run: ReviewRun | undefined): number {
  return toDate(run?.createdAt)?.getTime() ?? 0;
}

// upsertRun replaces a run by id or adds it, keeping newest first.
export function upsertRun(runs: ReviewRun[], run: ReviewRun): ReviewRun[] {
  const rest = runs.filter((r) => r.id !== run.id);
  return [...rest, run].sort((a, b) => createdMs(b) - createdMs(a));
}

// latestRun picks which run a pack shows: the same run updated, or a newer one.
export function latestRun(current: ReviewRun | undefined, incoming: ReviewRun): ReviewRun {
  if (!current || current.id === incoming.id) return incoming;
  return createdMs(incoming) >= createdMs(current) ? incoming : current;
}

export function writeIssue(qc: QueryClient, issue: Issue) {
  qc.setQueryData<IssuesData>(keys.issues(issue.packId), (data) =>
    data ? { ...data, issues: upsertIssue(data.issues, issue) } : data,
  );
}

export function writeIssueEvent(qc: QueryClient, event: IssueEvent) {
  qc.setQueryData<IssueEvent[]>(keys.issueEvents(event.issueId), (events) =>
    events ? appendEvent(events, event) : events,
  );
}

export function writeRun(qc: QueryClient, run: ReviewRun) {
  qc.setQueryData<GetPackResponse>(keys.pack(run.packId), (data) =>
    data ? { ...data, latestRun: latestRun(data.latestRun, run) } : data,
  );
  qc.setQueryData<ReviewRun[]>(keys.runs(run.packId), (runs) => (runs ? upsertRun(runs, run) : runs));
}

export function writePack(qc: QueryClient, pack: Pack) {
  qc.setQueryData<GetPackResponse>(keys.pack(pack.id), (data) => (data ? { ...data, pack } : data));
  qc.setQueryData<ListPacksResponse>(keys.packs, (data) =>
    data ? { ...data, packs: data.packs.map((p) => (p.id === pack.id ? pack : p)) } : data,
  );
}
