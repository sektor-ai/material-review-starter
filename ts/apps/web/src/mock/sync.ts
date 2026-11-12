import { fromJson, toJson, type JsonValue } from "@bufbuild/protobuf";
import { base64Decode, base64Encode } from "@bufbuild/protobuf/wire";
import { DocumentSchema, IssueEventSchema, IssueSchema, PackSchema, ReviewRunSchema } from "@app/api";
import type { Change, MockStore } from "./store.ts";

// Shares one mock backend between the tabs of a browser: every commit is
// broadcast to the other tabs and the whole state is kept in localStorage,
// so two tabs signed in as different users see each other's changes live,
// and a reload keeps the data. Each tab still runs its own copy.

const STORAGE_KEY = "mockApi.state.v1";
const CHANNEL = "mockApi.v1";
// Large uploads are kept in memory but not persisted.
const MAX_PERSISTED_CONTENT = 512 * 1024;

type ChangeJson =
  | { kind: "pack"; pack: JsonValue }
  | { kind: "doc"; doc: JsonValue; content: string; parsed: string }
  | { kind: "issue"; issue: JsonValue; event: JsonValue }
  | { kind: "run"; run: JsonValue };

export function changeToJson(c: Change, persist = false): ChangeJson {
  switch (c.kind) {
    case "pack":
      return { kind: "pack", pack: toJson(PackSchema, c.pack) };
    case "doc": {
      const keep = !persist || c.record.content.length <= MAX_PERSISTED_CONTENT;
      return {
        kind: "doc",
        doc: toJson(DocumentSchema, c.record.doc),
        content: keep ? base64Encode(c.record.content) : "",
        parsed: c.record.parsed,
      };
    }
    case "issue":
      return { kind: "issue", issue: toJson(IssueSchema, c.issue), event: toJson(IssueEventSchema, c.event) };
    case "run":
      return { kind: "run", run: toJson(ReviewRunSchema, c.run) };
  }
}

export function changeFromJson(j: ChangeJson): Change {
  switch (j.kind) {
    case "pack":
      return { kind: "pack", pack: fromJson(PackSchema, j.pack) };
    case "doc":
      return {
        kind: "doc",
        record: { doc: fromJson(DocumentSchema, j.doc), content: base64Decode(j.content), parsed: j.parsed },
      };
    case "issue":
      return { kind: "issue", issue: fromJson(IssueSchema, j.issue), event: fromJson(IssueEventSchema, j.event) };
    case "run":
      return { kind: "run", run: fromJson(ReviewRunSchema, j.run) };
  }
}

// snapshot lists the store's whole state as changes that rebuild it.
export function snapshot(store: MockStore): Change[] {
  const changes: Change[] = [];
  for (const pack of store.packs.values()) changes.push({ kind: "pack", pack });
  for (const record of store.docs.values()) changes.push({ kind: "doc", record });
  for (const run of store.runs.values()) changes.push({ kind: "run", run });
  for (const event of store.events) {
    const issue = store.issues.get(event.issueId);
    if (issue) changes.push({ kind: "issue", issue, event });
  }
  return changes;
}

function readStorage(): ChangeJson[] | null {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    return raw ? (JSON.parse(raw) as ChangeJson[]) : null;
  } catch {
    return null;
  }
}

function writeStorage(store: MockStore) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(snapshot(store).map((c) => changeToJson(c, true))));
  } catch {
    // Storage full or blocked: the mock keeps working in memory.
  }
}

// loadState fills the store from localStorage and reports whether it found
// anything.
export function loadState(store: MockStore): boolean {
  const saved = readStorage();
  if (!saved || saved.length === 0) return false;
  try {
    for (const c of saved) store.apply(changeFromJson(c));
    return true;
  } catch {
    return false;
  }
}

export function resetState() {
  try {
    localStorage.removeItem(STORAGE_KEY);
  } catch {
    // ignore
  }
}

export function attachSync(store: MockStore): () => void {
  let saveTimer: ReturnType<typeof setTimeout> | undefined;
  const scheduleSave = () => {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(() => writeStorage(store), 200);
  };
  const channel = typeof BroadcastChannel === "undefined" ? null : new BroadcastChannel(CHANNEL);
  store.onCommit = (c) => {
    channel?.postMessage(changeToJson(c));
    scheduleSave();
  };
  if (channel) {
    channel.onmessage = (e: MessageEvent<ChangeJson>) => {
      store.apply(changeFromJson(e.data));
      scheduleSave();
    };
  }
  writeStorage(store);
  return () => {
    clearTimeout(saveTimer);
    channel?.close();
    store.onCommit = undefined;
  };
}
