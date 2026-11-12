import { create, fromJson, toJson, type JsonValue, type MessageInitShape } from "@bufbuild/protobuf";
import { timestampNow, ValueSchema, type Timestamp } from "@bufbuild/protobuf/wkt";
import { Code, ConnectError } from "@connectrpc/connect";
import {
  DocumentSchema,
  DocumentStatus,
  FieldChangeSchema,
  IssueChangedSchema,
  IssueEventKind,
  IssueEventSchema,
  IssueSchema,
  IssueSeverity,
  IssueStatus,
  PackSchema,
  PackStatus,
  ReviewRunSchema,
  ReviewRunStatus,
  SpecReferenceSchema,
  WatchPackResponseSchema,
  type Document,
  type FieldChange,
  type Issue,
  type IssueEvent,
  type Pack,
  type ReviewRun,
  type SpecReference,
  type UpdateIssueRequest,
  type User,
  type WatchPackResponse,
} from "@app/api";
import { isActiveRun, isFinal } from "../format.ts";
import { MAX_UPLOAD_BYTES } from "../queries/packs.ts";

// MockStore is an in-memory stand-in for the backend, used only by the dev
// mock (VITE_MOCK_API) and tests. It follows the behaviour the proto
// comments describe: versioned issues with an event log, derived pack
// status, and final APPROVED/CANCELLED packs.

export type DocRecord = { doc: Document; content: Uint8Array; parsed: string };

// Change is one committed write, as other tabs receive it.
export type Change =
  | { kind: "pack"; pack: Pack }
  | { kind: "doc"; record: DocRecord }
  | { kind: "issue"; issue: Issue; event: IssueEvent }
  | { kind: "run"; run: ReviewRun };

type Listener = (packId: string, update: WatchPackResponse) => void;

// RunPatch is a partial ReviewRun to merge into a stored run.
export type RunPatch = Partial<Omit<ReviewRun, "$typeName" | "$unknown">>;

export type SpecRefInit = MessageInitShape<typeof SpecReferenceSchema>;

export type NewIssue = {
  documentId: string;
  severity: IssueSeverity;
  title: string;
  description: string;
  evidence: string;
  specRef?: SpecRefInit;
  note?: string;
  metadata?: Record<string, JsonValue>;
};

function failedPrecondition(message: string): never {
  throw new ConnectError(message, Code.FailedPrecondition);
}

function notFound(what: string): never {
  throw new ConnectError(`${what} not found`, Code.NotFound);
}

function millis(ts: { seconds: bigint; nanos: number } | undefined): number {
  return ts ? Number(ts.seconds) * 1000 + ts.nanos / 1e6 : 0;
}

const statusName = (s: IssueStatus) => `ISSUE_STATUS_${IssueStatus[s]}`;
const severityName = (s: IssueSeverity) => `ISSUE_SEVERITY_${IssueSeverity[s]}`;

function specRefJson(ref: SpecReference | undefined): JsonValue {
  return ref ? toJson(SpecReferenceSchema, ref) : null;
}

function change(field: string, oldValue: JsonValue, newValue: JsonValue): FieldChange {
  return create(FieldChangeSchema, {
    field,
    oldValue: fromJson(ValueSchema, oldValue),
    newValue: fromJson(ValueSchema, newValue),
  });
}

function issueFieldsJson(issue: Issue): Record<string, JsonValue> {
  return {
    status: statusName(issue.status),
    severity: severityName(issue.severity),
    title: issue.title,
    description: issue.description,
    spec_ref: specRefJson(issue.specRef),
    evidence: issue.evidence,
  };
}

export class MockStore {
  readonly packs = new Map<string, Pack>();
  readonly docs = new Map<string, DocRecord>();
  readonly issues = new Map<string, Issue>();
  readonly events: IssueEvent[] = [];
  readonly runs = new Map<string, ReviewRun>();
  private readonly listeners = new Set<Listener>();
  // Called with every local commit, so other tabs can apply it.
  onCommit: ((change: Change) => void) | undefined;

  // The seed swaps the clock to backdate its data.
  now: () => Timestamp = timestampNow;

  constructor(readonly agent: User) {}

  // ---- change application (local and remote) ----

  commit(c: Change) {
    this.apply(c);
    this.onCommit?.(c);
  }

  // apply stores a change and notifies watchers. Remote changes come here
  // directly; they never re-broadcast.
  apply(c: Change) {
    switch (c.kind) {
      case "pack":
        this.packs.set(c.pack.id, c.pack);
        this.emitPack(c.pack.id);
        break;
      case "doc":
        this.docs.set(c.record.doc.id, c.record);
        this.emitPack(c.record.doc.packId);
        break;
      case "issue": {
        const existing = this.issues.get(c.issue.id);
        if (!existing || existing.version < c.issue.version) this.issues.set(c.issue.id, c.issue);
        // An event is identified by the issue version it produced; two
        // tabs may still pick the same seq, and neither event may be lost.
        if (!this.events.some((e) => e.issueId === c.event.issueId && e.version === c.event.version)) {
          this.events.push(c.event);
          this.events.sort((a, b) => (a.seq < b.seq ? -1 : 1));
        }
        const current = this.issues.get(c.issue.id)!;
        this.emit(c.issue.packId, {
          case: "issueChanged",
          value: create(IssueChangedSchema, { event: c.event, issue: current }),
        });
        this.emitPack(c.issue.packId);
        break;
      }
      case "run":
        this.runs.set(c.run.id, c.run);
        this.emit(c.run.packId, { case: "runUpdated", value: c.run });
        break;
    }
  }

  subscribe(listener: Listener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private emitPack(packId: string) {
    const pack = this.packView(packId);
    if (pack) this.emit(packId, { case: "packUpdated", value: pack });
  }

  private emit(packId: string, update: WatchPackResponse["update"]) {
    const res = create(WatchPackResponseSchema, { update });
    for (const l of this.listeners) l(packId, res);
  }

  // nextSeq numbers events without coordinating between tabs: from the
  // clock, with a random low part, never below the last seq seen. Two tabs
  // committing in the same millisecond are very unlikely to collide, and
  // seq still follows commit order closely enough for a dev mock.
  private nextSeq(): bigint {
    const next = (this.events.at(-1)?.seq ?? 0n) + 1n;
    const fromClock = BigInt(Date.now()) * 1000n + BigInt(Math.floor(Math.random() * 1000));
    return fromClock > next ? fromClock : next;
  }

  // ---- packs ----

  // packView is the pack as clients see it, with its counts filled in.
  packView(id: string): Pack | undefined {
    const pack = this.packs.get(id);
    if (!pack) return undefined;
    const documentCount = [...this.docs.values()].filter((d) => d.doc.packId === id).length;
    const openIssueCount = [...this.issues.values()].filter(
      (i) => i.packId === id && i.status === IssueStatus.OPEN,
    ).length;
    return create(PackSchema, { ...pack, documentCount, openIssueCount });
  }

  private mustPack(id: string): Pack {
    return this.packs.get(id) ?? notFound("pack");
  }

  private mustWritablePack(id: string): Pack {
    const pack = this.mustPack(id);
    if (isFinal(pack.status)) failedPrecondition(`pack is ${PackStatus[pack.status].toLowerCase()}`);
    return pack;
  }

  listPacks(): Pack[] {
    return [...this.packs.values()]
      .sort((a, b) => millis(b.createdAt) - millis(a.createdAt))
      .map((p) => this.packView(p.id)!);
  }

  createPack(me: User, input: { submittalNo: string; title: string; designBasis: string }): Pack {
    if (!input.submittalNo.trim() || !input.title.trim()) {
      throw new ConnectError("submittal_no and title are required", Code.InvalidArgument);
    }
    if ([...this.packs.values()].some((p) => p.submittalNo === input.submittalNo.trim())) {
      throw new ConnectError(`submittal ${input.submittalNo} already exists`, Code.AlreadyExists);
    }
    const now = this.now();
    const pack = create(PackSchema, {
      id: crypto.randomUUID(),
      submittalNo: input.submittalNo.trim(),
      title: input.title.trim(),
      designBasis: input.designBasis.trim(),
      status: PackStatus.OPEN,
      createdBy: me,
      createdAt: now,
      updatedAt: now,
    });
    this.commit({ kind: "pack", pack });
    return this.packView(pack.id)!;
  }

  getPack(id: string) {
    this.mustPack(id);
    const documents = [...this.docs.values()]
      .filter((d) => d.doc.packId === id)
      .map((d) => d.doc)
      .sort((a, b) => millis(a.createdAt) - millis(b.createdAt));
    return { pack: this.packView(id)!, documents, latestRun: this.listRuns(id)[0] };
  }

  updatePack(id: string, input: { title?: string; designBasis?: string }): Pack {
    const pack = this.mustWritablePack(id);
    const next = create(PackSchema, {
      ...pack,
      title: input.title ?? pack.title,
      designBasis: input.designBasis ?? pack.designBasis,
      updatedAt: this.now(),
    });
    this.commit({ kind: "pack", pack: next });
    return this.packView(id)!;
  }

  approvePack(me: User, id: string): Pack {
    const pack = this.mustPack(id);
    if (pack.status !== PackStatus.RESOLVED) failedPrecondition("only a resolved pack can be approved");
    // As the backend does: approving mid-review would leave the run
    // writing issues into a pack that can no longer change.
    if (this.listRuns(id).some((r) => isActiveRun(r.status))) {
      failedPrecondition(`pack ${pack.submittalNo} has a review in progress`);
    }
    const now = this.now();
    this.commit({
      kind: "pack",
      pack: create(PackSchema, { ...pack, status: PackStatus.APPROVED, approvedBy: me, approvedAt: now, updatedAt: now }),
    });
    return this.packView(id)!;
  }

  cancelPack(me: User, id: string, reason: string): Pack {
    const pack = this.mustWritablePack(id);
    for (const run of this.listRuns(id)) if (isActiveRun(run.status)) this.finishRun(run.id, ReviewRunStatus.CANCELLED);
    const now = this.now();
    this.commit({
      kind: "pack",
      pack: create(PackSchema, {
        ...pack,
        status: PackStatus.CANCELLED,
        cancelledBy: me,
        cancelledAt: now,
        cancelReason: reason,
        updatedAt: now,
      }),
    });
    return this.packView(id)!;
  }

  // recomputeStatus applies the OPEN/RESOLVED rule after an issue or run change.
  recomputeStatus(packId: string) {
    const pack = this.packs.get(packId);
    if (!pack || isFinal(pack.status)) return;
    const reviewed = this.listRuns(packId).some((r) => r.status === ReviewRunStatus.SUCCEEDED);
    const open = this.packView(packId)!.openIssueCount;
    const status = reviewed && open === 0 ? PackStatus.RESOLVED : PackStatus.OPEN;
    if (status !== pack.status) {
      this.commit({ kind: "pack", pack: create(PackSchema, { ...pack, status, updatedAt: this.now() }) });
    }
  }

  // ---- documents ----

  uploadDocument(
    me: User,
    input: { packId: string; filename: string; mimeType: string; content: Uint8Array; title: string },
    onParsed: (fn: () => void) => void,
  ): Document {
    this.mustWritablePack(input.packId);
    if (input.content.length > MAX_UPLOAD_BYTES) {
      throw new ConnectError("file is larger than 20 MB", Code.InvalidArgument);
    }
    if (!input.filename) throw new ConnectError("filename is required", Code.InvalidArgument);
    const inline = input.mimeType.startsWith("text/") || /\.(md|txt)$/i.test(input.filename);
    const doc = create(DocumentSchema, {
      id: crypto.randomUUID(),
      packId: input.packId,
      filename: input.filename,
      title: input.title || input.filename.replace(/\.[^.]+$/, ""),
      mimeType: input.mimeType,
      sizeBytes: BigInt(input.content.length),
      sha256: "",
      status: inline ? DocumentStatus.READY : DocumentStatus.PROCESSING,
      createdBy: me,
      createdAt: this.now(),
    });
    const parsed = inline ? new TextDecoder().decode(input.content) : "";
    this.commit({ kind: "doc", record: { doc, content: input.content, parsed } });
    if (!inline) {
      onParsed(() => {
        const record = this.docs.get(doc.id);
        if (!record) return;
        this.commit({
          kind: "doc",
          record: {
            ...record,
            doc: create(DocumentSchema, { ...record.doc, status: DocumentStatus.READY }),
            parsed: `(The dev mock does not parse ${record.doc.mimeType}. This stands in for the text of ${record.doc.filename}.)`,
          },
        });
      });
    }
    return doc;
  }

  getDocument(id: string) {
    const record = this.docs.get(id) ?? notFound("document");
    return { document: record.doc, parsedContent: record.parsed };
  }

  // ---- issues ----

  private mustIssue(id: string): Issue {
    return this.issues.get(id) ?? notFound("issue");
  }

  listIssues(packId: string) {
    this.mustPack(packId);
    const issues = [...this.issues.values()].filter((i) => i.packId === packId);
    const cursorSeq = this.events.at(-1)?.seq ?? 0n;
    return { issues, cursorSeq };
  }

  createIssue(actor: User, input: NewIssue, runId?: string) {
    const record = this.docs.get(input.documentId) ?? notFound("document");
    this.mustWritablePack(record.doc.packId);
    if (!input.title.trim()) throw new ConnectError("title is required", Code.InvalidArgument);
    const now = this.now();
    const issue = create(IssueSchema, {
      id: crypto.randomUUID(),
      packId: record.doc.packId,
      documentId: input.documentId,
      version: 1,
      status: IssueStatus.OPEN,
      severity: input.severity,
      title: input.title.trim(),
      description: input.description,
      specRef: input.specRef,
      evidence: input.evidence,
      metadata: input.metadata,
      createdBy: actor,
      createdAt: now,
      updatedBy: actor,
      updatedAt: now,
      runId,
    });
    const event = create(IssueEventSchema, {
      seq: this.nextSeq(),
      issueId: issue.id,
      packId: issue.packId,
      version: 1,
      kind: IssueEventKind.CREATED,
      actor,
      runId,
      note: input.note ?? "",
      changes: Object.entries(issueFieldsJson(issue)).map(([field, value]) => change(field, null, value)),
      createdAt: now,
    });
    this.commit({ kind: "issue", issue, event });
    this.recomputeStatus(issue.packId);
    return { issue, event };
  }

  updateIssue(me: User, req: UpdateIssueRequest): { issue: Issue; event?: IssueEvent } {
    const issue = this.mustIssue(req.id);
    this.mustWritablePack(issue.packId);
    if (req.expectedVersion !== issue.version) {
      throw new ConnectError(
        `issue is at version ${issue.version}, not ${req.expectedVersion}`,
        Code.Aborted,
        undefined,
        [{ desc: IssueSchema, value: issue }],
      );
    }
    const next = create(IssueSchema, {
      ...issue,
      status: req.status ?? issue.status,
      severity: req.severity ?? issue.severity,
      title: req.title ?? issue.title,
      description: req.description ?? issue.description,
      specRef: req.specRef ?? issue.specRef,
      evidence: req.evidence ?? issue.evidence,
    });
    const before = issueFieldsJson(issue);
    const after = issueFieldsJson(next);
    const changes = Object.keys(after)
      .filter((f) => JSON.stringify(before[f]) !== JSON.stringify(after[f]))
      .map((f) => change(f, before[f], after[f]));
    if (changes.length === 0) return { issue };

    const now = this.now();
    next.version = issue.version + 1;
    next.updatedBy = me;
    next.updatedAt = now;
    const event = create(IssueEventSchema, {
      seq: this.nextSeq(),
      issueId: issue.id,
      packId: issue.packId,
      version: next.version,
      kind: IssueEventKind.UPDATED,
      actor: me,
      note: req.note,
      changes,
      createdAt: now,
    });
    this.commit({ kind: "issue", issue: next, event });
    this.recomputeStatus(issue.packId);
    return { issue: next, event };
  }

  listIssueEvents(issueId: string): IssueEvent[] {
    this.mustIssue(issueId);
    return this.events.filter((e) => e.issueId === issueId);
  }

  // ---- review runs ----

  listRuns(packId: string): ReviewRun[] {
    return [...this.runs.values()]
      .filter((r) => r.packId === packId)
      .sort((a, b) => millis(b.createdAt) - millis(a.createdAt));
  }

  mustRun(id: string): ReviewRun {
    return this.runs.get(id) ?? notFound("review run");
  }

  startReview(me: User, packId: string): ReviewRun {
    this.mustWritablePack(packId);
    if (this.listRuns(packId).some((r) => isActiveRun(r.status))) failedPrecondition("a review is already queued or running");
    const ready = [...this.docs.values()].some(
      (d) => d.doc.packId === packId && d.doc.status === DocumentStatus.READY,
    );
    if (!ready) failedPrecondition("the pack has no ready documents");
    const run = create(ReviewRunSchema, {
      id: crypto.randomUUID(),
      packId,
      status: ReviewRunStatus.QUEUED,
      startedBy: me,
      createdAt: this.now(),
    });
    this.commit({ kind: "run", run });
    return run;
  }

  updateRun(id: string, patch: RunPatch): ReviewRun {
    const run = create(ReviewRunSchema, { ...this.mustRun(id), ...patch });
    this.commit({ kind: "run", run });
    return run;
  }

  finishRun(id: string, status: ReviewRunStatus, patch: RunPatch = {}) {
    const run = this.updateRun(id, { ...patch, status, progressNote: "", finishedAt: this.now() });
    this.recomputeStatus(run.packId);
    return run;
  }

  cancelReviewRun(id: string): ReviewRun {
    const run = this.mustRun(id);
    if (!isActiveRun(run.status)) failedPrecondition("the review is not running");
    return this.finishRun(id, ReviewRunStatus.CANCELLED);
  }
}
