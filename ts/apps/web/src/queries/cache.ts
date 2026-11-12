import type { QueryClient } from "@tanstack/react-query";
import { ReviewRunStatus, type GetPackResponse, type Issue, type IssueEvent, type ListPacksResponse, type Pack, type ReviewRun } from "@app/api";
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

// appendEvent adds an event to an issue's history once, in seq order. An
// event is identified by the issue version it produced, not by its seq.
export function appendEvent(events: IssueEvent[], event: IssueEvent): IssueEvent[] {
  if (events.some((e) => e.issueId === event.issueId && e.version === event.version)) return events;
  return [...events, event].sort((a, b) => (a.seq < b.seq ? -1 : a.seq > b.seq ? 1 : 0));
}

function createdMs(run: ReviewRun | undefined): number {
  return toDate(run?.createdAt)?.getTime() ?? 0;
}

// A run only moves forward: queued, then running, then finished.
function runStage(run: ReviewRun): number {
  switch (run.status) {
    case ReviewRunStatus.QUEUED:
      return 0;
    case ReviewRunStatus.RUNNING:
      return 1;
    case ReviewRunStatus.UNSPECIFIED:
      return -1;
    default:
      return 2;
  }
}

// newerRunState picks the later of two snapshots of the same run. Runs
// carry no version, so a snapshot from a later stage wins, and within a
// stage the one with more issues raised; on a tie the incoming one.
export function newerRunState(current: ReviewRun, incoming: ReviewRun): ReviewRun {
  const stage = runStage(incoming) - runStage(current);
  if (stage !== 0) return stage > 0 ? incoming : current;
  return incoming.issuesCreated >= current.issuesCreated ? incoming : current;
}

// upsertRun replaces a run by id or adds it, keeping newest first.
export function upsertRun(runs: ReviewRun[], run: ReviewRun): ReviewRun[] {
  const existing = runs.find((r) => r.id === run.id);
  const next = existing ? newerRunState(existing, run) : run;
  const rest = runs.filter((r) => r.id !== run.id);
  return [...rest, next].sort((a, b) => createdMs(b) - createdMs(a));
}

// latestRun picks which run a pack shows: the latest state of the same
// run, or a newer run.
export function latestRun(current: ReviewRun | undefined, incoming: ReviewRun | undefined): ReviewRun | undefined {
  if (!current || !incoming) return incoming ?? current;
  if (current.id === incoming.id) return newerRunState(current, incoming);
  return createdMs(incoming) >= createdMs(current) ? incoming : current;
}

// newerPack keeps the later snapshot of a pack. The server bumps
// updated_at on every change to the pack row, status included; derived
// counts don't bump it, so on a tie the incoming snapshot wins.
export function newerPack(current: Pack | undefined, incoming: Pack | undefined): Pack | undefined {
  if (!current || !incoming) return incoming ?? current;
  const cur = toDate(current.updatedAt)?.getTime() ?? 0;
  const inc = toDate(incoming.updatedAt)?.getTime() ?? 0;
  return cur > inc ? current : incoming;
}

// mergePackResponse folds a GetPack refetch into the cache. The stream may
// have delivered newer pack or run state while the request was in flight;
// this keeps that instead of rolling it back. Documents are not streamed,
// so they come from the refetch.
export function mergePackResponse(cached: GetPackResponse | undefined, fetched: GetPackResponse): GetPackResponse {
  if (!cached) return fetched;
  return {
    ...fetched,
    pack: newerPack(cached.pack, fetched.pack),
    latestRun: latestRun(cached.latestRun, fetched.latestRun),
  };
}

// writeIssue stores the issue if it is newer than the cached copy and
// reports whether it was.
export function writeIssue(qc: QueryClient, issue: Issue): boolean {
  const data = qc.getQueryData<IssuesData>(keys.issues(issue.packId));
  if (!data) return false;
  const issues = upsertIssue(data.issues, issue);
  if (issues === data.issues) return false;
  qc.setQueryData<IssuesData>(keys.issues(issue.packId), { ...data, issues });
  return true;
}

// advanceCursor records that the cache holds every event up to seq, so a
// stream opened later (e.g. on returning to the page) does not replay them.
export function advanceCursor(qc: QueryClient, packId: string, seq: bigint) {
  qc.setQueryData<IssuesData>(keys.issues(packId), (data) =>
    data && seq > data.cursorSeq ? { ...data, cursorSeq: seq } : data,
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
  qc.setQueryData<GetPackResponse>(keys.pack(pack.id), (data) =>
    data ? { ...data, pack: newerPack(data.pack, pack) } : data,
  );
  qc.setQueryData<ListPacksResponse>(keys.packs, (data) =>
    data
      ? { ...data, packs: data.packs.map((p) => (p.id === pack.id ? (newerPack(p, pack) ?? pack) : p)) }
      : data,
  );
}
