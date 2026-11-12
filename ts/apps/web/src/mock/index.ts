import { create } from "@bufbuild/protobuf";
import { Code, ConnectError, createRouterTransport, type Interceptor, type Transport } from "@connectrpc/connect";
import {
  AuthService,
  IssueService,
  PackService,
  ReviewRunStatus,
  ReviewService,
  WatchPackResponseSchema,
  type User,
  type WatchPackResponse,
} from "@app/api";
import { isActiveRun } from "../format.ts";
import { runAgent } from "./agent.ts";
import { mockUsers, seed } from "./seed.ts";
import { MockStore } from "./store.ts";
import { attachSync, loadState } from "./sync.ts";

// The dev mock: a Connect transport that serves every service from an
// in-memory store in the browser, so the frontend runs before the backend
// handlers exist. It is only loaded when VITE_MOCK_API=1 or ?mock=1 (see
// main.tsx) and never ships in a production build.

const HEARTBEAT_MS = 15_000;

export type SessionStore = { get(): string | null; set(value: string): void };

// Each tab has its own signed-in user, so two tabs can be Alice and Bob.
const tabSession: SessionStore = {
  get: () => sessionStorage.getItem("mockApi.user"),
  set: (v) => sessionStorage.setItem("mockApi.user", v),
};

export type MockApiOptions = {
  // Fresh seeded store, no persistence or cross-tab sync. For tests.
  isolated?: boolean;
  session?: SessionStore;
  // Artificial latency on unary calls, so pending states are visible.
  latencyMs?: number;
  // Speed of the scripted agent: ms per finding.
  agentStepMs?: number;
};

export type MockApi = {
  store: MockStore;
  transport: Transport;
  originalUrl: (documentId: string) => string;
};

function delay(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

export function createMockApi(options: MockApiOptions = {}): MockApi {
  const { isolated = false, latencyMs = 150, agentStepMs = 2500 } = options;
  const session = options.session ?? tabSession;
  const store = new MockStore(mockUsers.agent);
  if (isolated || !loadState(store)) seed(store);
  if (!isolated) attachSync(store);

  // A scripted run is driven by the tab that started it, which holds a Web
  // Lock for as long as it does. A run whose lock is free has no driver
  // (its tab was closed or reloaded) and would stay RUNNING forever, so it
  // is failed instead.
  //
  // Known gaps, accepted for a dev-only mock: a tab that loads between
  // another tab committing a run and taking its lock can fail a live run,
  // and tabs that were already open don't notice a run abandoned later.
  const locks = !isolated && typeof navigator !== "undefined" ? navigator.locks : undefined;
  const runLock = (runId: string) => `mockApi.run.${runId}`;

  function driveRun(runId: string) {
    const drive = () => runAgent(store, runId, undefined, agentStepMs);
    if (locks) void locks.request(runLock(runId), drive);
    else void drive();
  }

  if (locks) {
    for (const run of store.runs.values()) {
      if (!isActiveRun(run.status)) continue;
      void locks.request(runLock(run.id), { ifAvailable: true }, async (lock) => {
        if (!lock || !isActiveRun(store.runs.get(run.id)?.status)) return;
        store.finishRun(run.id, ReviewRunStatus.FAILED, {
          error: "The browser tab running this mock review was closed before it finished.",
        });
      });
    }
  }

  const humans = [mockUsers.alice, mockUsers.bob];
  if (session.get() === null) session.set("alice@example.com");

  function me(): User {
    const user = humans.find((u) => u.email === session.get());
    if (!user) throw new ConnectError("not signed in", Code.Unauthenticated);
    return user;
  }

  const latency: Interceptor = (next) => async (req) => {
    if (latencyMs > 0 && !req.stream) await delay(latencyMs);
    return next(req);
  };

  async function* watch(packId: string, afterSeq: bigint, signal: AbortSignal): AsyncGenerator<WatchPackResponse> {
    const pack = store.packView(packId);
    if (!pack) throw new ConnectError("pack not found", Code.NotFound);
    const queue: WatchPackResponse[] = [];
    let wake: (() => void) | undefined;
    const unsubscribe = store.subscribe((pid, res) => {
      if (pid !== packId) return;
      queue.push(res);
      wake?.();
    });
    const onAbort = () => wake?.();
    signal.addEventListener("abort", onAbort);
    try {
      yield create(WatchPackResponseSchema, { update: { case: "packUpdated", value: pack } });
      const run = store.listRuns(packId)[0];
      if (run) yield create(WatchPackResponseSchema, { update: { case: "runUpdated", value: run } });
      for (const event of store.events) {
        if (event.packId !== packId || event.seq <= afterSeq) continue;
        const issue = store.issues.get(event.issueId);
        yield create(WatchPackResponseSchema, { update: { case: "issueChanged", value: { event, issue } } });
      }
      while (!signal.aborted) {
        const next = queue.shift();
        if (next) {
          yield next;
          continue;
        }
        const woken = await new Promise<boolean>((resolve) => {
          const timer = setTimeout(() => resolve(false), HEARTBEAT_MS);
          wake = () => {
            clearTimeout(timer);
            resolve(true);
          };
        });
        wake = undefined;
        if (!woken && !signal.aborted) {
          yield create(WatchPackResponseSchema, { update: { case: "heartbeat", value: {} } });
        }
      }
    } finally {
      signal.removeEventListener("abort", onAbort);
      unsubscribe();
    }
  }

  const transport = createRouterTransport(
    (router) => {
      router.service(AuthService, {
        signIn(req) {
          const user = humans.find((u) => u.email === req.email.trim().toLowerCase());
          if (!user) throw new ConnectError("invalid email or password", Code.Unauthenticated);
          session.set(user.email);
          return { user };
        },
        signOut() {
          session.set("");
          return {};
        },
        getMe() {
          return { user: me() };
        },
      });

      router.service(PackService, {
        createPack: (req) => ({ pack: store.createPack(me(), req) }),
        listPacks: () => (me(), { packs: store.listPacks() }),
        getPack: (req) => (me(), store.getPack(req.id)),
        updatePack: (req) => (me(), { pack: store.updatePack(req.id, req) }),
        approvePack: (req) => ({ pack: store.approvePack(me(), req.id) }),
        cancelPack: (req) => ({ pack: store.cancelPack(me(), req.id, req.reason) }),
        uploadDocument: (req) => ({
          document: store.uploadDocument(me(), req, (parse) => setTimeout(parse, 2500)),
        }),
        getDocument: (req) => (me(), store.getDocument(req.id)),
        watchPack: (req, ctx) => (me(), watch(req.packId, req.afterSeq, ctx.signal)),
      });

      router.service(IssueService, {
        listIssues: (req) => (me(), store.listIssues(req.packId)),
        getIssue: (req) => {
          me();
          const issue = store.issues.get(req.id);
          if (!issue) throw new ConnectError("issue not found", Code.NotFound);
          return { issue };
        },
        createIssue: (req) => store.createIssue(me(), { ...req, specRef: req.specRef }),
        updateIssue: (req) => store.updateIssue(me(), req),
        listIssueEvents: (req) => (me(), { events: store.listIssueEvents(req.issueId) }),
      });

      router.service(ReviewService, {
        startReview: (req) => {
          const run = store.startReview(me(), req.packId);
          driveRun(run.id);
          return { run };
        },
        getReviewRun: (req) => (me(), { run: store.mustRun(req.id) }),
        listReviewRuns: (req) => (me(), { runs: store.listRuns(req.packId) }),
        cancelReviewRun: (req) => (me(), { run: store.cancelReviewRun(req.id) }),
      });
    },
    { transport: { interceptors: [latency] } },
  );

  // Documents never change once uploaded, so one blob URL each is enough.
  const blobUrls = new Map<string, string>();
  const originalUrl = (documentId: string) => {
    const cached = blobUrls.get(documentId);
    if (cached) return cached;
    const record = store.docs.get(documentId);
    if (!record || record.content.length === 0) return "about:blank";
    const url = URL.createObjectURL(
      new Blob([new Uint8Array(record.content)], { type: record.doc.mimeType || "application/octet-stream" }),
    );
    blobUrls.set(documentId, url);
    return url;
  };

  return { store, transport, originalUrl };
}
