import { useState, type FormEvent } from "react";
import { DocumentStatus, IssueSeverity, IssueStatus, type Document, type Issue, type User } from "@app/api";
import { errorMessage } from "../api.ts";
import { fieldLabel, issueStatusLabel, severities, severityHelp, severityLabel, userName } from "../format.ts";
import { useCreateIssue, useUpdateIssue, type IssueFields } from "../queries/issues.ts";
import { ErrorText, Modal } from "../ui.tsx";

export type IssueForm = {
  documentId: string;
  status: IssueStatus;
  severity: IssueSeverity;
  title: string;
  description: string;
  evidence: string;
  section: string;
  part: string;
  clause: string;
  clauseTitle: string;
  // Kept as text while editing; empty means unknown.
  pdfPage: string;
};

export function formFromIssue(issue: Issue): IssueForm {
  return {
    documentId: issue.documentId,
    status: issue.status,
    severity: issue.severity,
    title: issue.title,
    description: issue.description,
    evidence: issue.evidence,
    section: issue.specRef?.section ?? "",
    part: issue.specRef?.part ?? "",
    clause: issue.specRef?.clause ?? "",
    clauseTitle: issue.specRef?.clauseTitle ?? "",
    pdfPage: issue.specRef?.pdfPage !== undefined ? String(issue.specRef.pdfPage) : "",
  };
}

function specRefOf(form: IssueForm) {
  const page = Number.parseInt(form.pdfPage, 10);
  return {
    section: form.section.trim(),
    part: form.part.trim(),
    clause: form.clause.trim(),
    clauseTitle: form.clauseTitle.trim(),
    pdfPage: Number.isFinite(page) && page > 0 ? page : undefined,
  };
}

// diffFields returns only the fields the form changes relative to the issue,
// so an update never overwrites a field the user did not touch. spec_ref is
// replaced as a whole, so any change to it sends all of it.
export function diffFields(issue: Issue, form: IssueForm): IssueFields {
  const before = formFromIssue(issue);
  const fields: IssueFields = {};
  if (form.status !== before.status) fields.status = form.status;
  if (form.severity !== before.severity) fields.severity = form.severity;
  if (form.title.trim() !== before.title.trim()) fields.title = form.title.trim();
  if (form.description.trim() !== before.description.trim()) fields.description = form.description.trim();
  if (form.evidence.trim() !== before.evidence.trim()) fields.evidence = form.evidence.trim();
  const ref = specRefOf(form);
  const oldRef = specRefOf(before);
  if (
    ref.section !== oldRef.section ||
    ref.part !== oldRef.part ||
    ref.clause !== oldRef.clause ||
    ref.clauseTitle !== oldRef.clauseTitle ||
    ref.pdfPage !== oldRef.pdfPage
  ) {
    fields.specRef = ref;
  }
  return fields;
}

// rebaseForm moves an edit that started from `base` onto `theirs`: it keeps
// their value for every field the user left alone, so saving afterwards
// does not undo the other person's change.
export function rebaseForm(base: Issue, mine: IssueForm, theirs: Issue): IssueForm {
  const original = formFromIssue(base);
  const next = formFromIssue(theirs);
  for (const key of Object.keys(mine) as (keyof IssueForm)[]) {
    if (mine[key] !== original[key]) (next as Record<keyof IssueForm, unknown>)[key] = mine[key];
  }
  return next;
}

const fieldNames: Record<keyof IssueFields, string> = {
  status: "status",
  severity: "severity",
  title: "title",
  description: "description",
  evidence: "evidence",
  specRef: "spec_ref",
};

function changedFieldLabels(fields: IssueFields): string {
  return (Object.keys(fields) as (keyof IssueFields)[]).map((k) => fieldLabel(fieldNames[k]).toLowerCase()).join(", ");
}

function emptyForm(documents: Document[]): IssueForm {
  const firstReady = documents.find((d) => d.status === DocumentStatus.READY) ?? documents[0];
  return {
    documentId: firstReady?.id ?? "",
    status: IssueStatus.OPEN,
    severity: IssueSeverity.MAJOR,
    title: "",
    description: "",
    evidence: "",
    section: "",
    part: "",
    clause: "",
    clauseTitle: "",
    pdfPage: "",
  };
}

// IssueEditor creates an issue (no base) or edits one. When editing, `base`
// is the version the edit started from and `live` is the cached issue, which
// the stream keeps current; a newer live version means someone else changed
// it meanwhile.
export function IssueEditor({
  documents,
  me,
  base: initialBase,
  live,
  onClose,
}: {
  documents: Document[];
  me: User;
  base?: Issue;
  live?: Issue;
  onClose: () => void;
}) {
  const [base, setBase] = useState(initialBase);
  const [form, setForm] = useState<IssueForm>(() => (initialBase ? formFromIssue(initialBase) : emptyForm(documents)));
  const [note, setNote] = useState("");
  const [conflict, setConflict] = useState<Issue | null>(null);
  const create = useCreateIssue();
  const update = useUpdateIssue();
  const pending = create.isPending || update.isPending;
  const error = create.error ?? update.error;

  const theirs = conflict ?? (base && live && live.version > base.version && live.updatedBy?.id !== me.id ? live : null);
  const theirChanges = base && theirs ? diffFields(base, formFromIssue(theirs)) : {};

  function set<K extends keyof IssueForm>(key: K, value: IssueForm[K]) {
    setForm((f) => ({ ...f, [key]: value }));
  }

  function loadTheirs(issue: Issue) {
    setBase(issue);
    setForm(formFromIssue(issue));
    setConflict(null);
  }

  function keepMine(issue: Issue) {
    // Rebase the edit onto their version: their values, with only the
    // fields I edited laid over them.
    if (base) setForm(rebaseForm(base, form, issue));
    setBase(issue);
    setConflict(null);
  }

  function handleSubmit(event: FormEvent) {
    event.preventDefault();
    if (!base) {
      create.mutate(
        {
          documentId: form.documentId,
          severity: form.severity,
          title: form.title.trim(),
          description: form.description.trim(),
          evidence: form.evidence.trim(),
          specRef: specRefOf(form),
          note: note.trim(),
        },
        { onSuccess: onClose },
      );
      return;
    }
    const fields = diffFields(base, form);
    if (Object.keys(fields).length === 0) {
      onClose();
      return;
    }
    update.mutate(
      { id: base.id, expectedVersion: base.version, fields, note: note.trim() },
      {
        onSuccess: (outcome) => {
          if (outcome.kind === "saved") onClose();
          else setConflict(outcome.current);
        },
      },
    );
  }

  return (
    <Modal title={base ? "Edit issue" : "Add issue"} onClose={onClose} wide>
      <form className="form" onSubmit={handleSubmit}>
        {theirs && base && (
          <div className={conflict ? "notice notice-error" : "notice"} role="status">
            {conflict ? (
              <>
                <strong>Not saved.</strong> {userName(theirs.updatedBy)} changed this issue first
              </>
            ) : (
              <>{userName(theirs.updatedBy)} changed this issue while you were editing</>
            )}
            {Object.keys(theirChanges).length > 0 && <> ({changedFieldLabels(theirChanges)})</>}.
            <div className="actions">
              <button type="button" className="secondary" onClick={() => loadTheirs(theirs)}>
                Discard mine, load theirs
              </button>
              <button type="button" className="secondary" onClick={() => keepMine(theirs)}>
                Keep mine on top of theirs
              </button>
            </div>
          </div>
        )}

        <div className="form-grid">
          {!base && (
            <label className="span-2">
              Document
              <select value={form.documentId} onChange={(e) => set("documentId", e.target.value)} required>
                {documents.map((d) => (
                  <option key={d.id} value={d.id}>
                    {d.title || d.filename}
                  </option>
                ))}
              </select>
            </label>
          )}
          <label>
            Severity
            <select value={form.severity} onChange={(e) => set("severity", Number(e.target.value) as IssueSeverity)}>
              {severities.map((s) => (
                <option key={s} value={s}>
                  {severityLabel[s]}
                </option>
              ))}
            </select>
            <span className="hint">{severityHelp[form.severity]}</span>
          </label>
          {base && (
            <label>
              Status
              <select value={form.status} onChange={(e) => set("status", Number(e.target.value) as IssueStatus)}>
                {[IssueStatus.OPEN, IssueStatus.CLOSED].map((s) => (
                  <option key={s} value={s}>
                    {issueStatusLabel[s]}
                  </option>
                ))}
              </select>
            </label>
          )}
          <label className="span-2">
            Title
            <input value={form.title} onChange={(e) => set("title", e.target.value)} required />
          </label>
          <label className="span-2">
            Description
            <textarea value={form.description} onChange={(e) => set("description", e.target.value)} rows={4} />
          </label>
          <label className="span-2">
            Evidence
            <input
              value={form.evidence}
              onChange={(e) => set("evidence", e.target.value)}
              placeholder="Free water/cementitious ratio: 0.55"
            />
            <span className="hint">The quote or value in the submittal that shows the problem.</span>
          </label>
          <fieldset className="span-2 spec-ref">
            <legend>QCS 2014 reference</legend>
            <label>
              Section
              <input value={form.section} onChange={(e) => set("section", e.target.value)} placeholder="05" required />
            </label>
            <label>
              Part
              <input value={form.part} onChange={(e) => set("part", e.target.value)} placeholder="06" required />
            </label>
            <label>
              Clause
              <input
                value={form.clause}
                onChange={(e) => set("clause", e.target.value)}
                placeholder="Table 6.4"
                required
              />
            </label>
            <label>
              PDF page
              <input
                type="number"
                min={1}
                value={form.pdfPage}
                onChange={(e) => set("pdfPage", e.target.value)}
                placeholder="652"
              />
            </label>
            <label className="span-all">
              Clause title
              <input
                value={form.clauseTitle}
                onChange={(e) => set("clauseTitle", e.target.value)}
                placeholder="Maximum free water/cementitious ratio"
              />
            </label>
          </fieldset>
          <label className="span-2">
            Note for the change log (optional)
            <input value={note} onChange={(e) => setNote(e.target.value)} placeholder="Why you made this change" />
          </label>
        </div>
        <ErrorText error={error && errorMessage(error)} />
        <div className="actions">
          <button type="button" className="secondary" onClick={onClose}>
            Cancel
          </button>
          <button type="submit" disabled={pending || conflict !== null}>
            {pending ? "Saving…" : base ? "Save" : "Add issue"}
          </button>
        </div>
      </form>
    </Modal>
  );
}

// CloseIssueModal closes an issue with an optional reason, which is recorded
// on the change log.
export function CloseIssueModal({
  issue,
  live,
  me,
  onClose,
}: {
  issue: Issue;
  live?: Issue;
  me: User;
  onClose: () => void;
}) {
  const [base, setBase] = useState(issue);
  const [note, setNote] = useState("");
  const [conflict, setConflict] = useState(false);
  const update = useUpdateIssue();
  const current = live ?? base;
  const changedByOther = current.version > base.version && current.updatedBy?.id !== me.id;
  const alreadyClosed = current.status === IssueStatus.CLOSED;

  function handleSubmit(event: FormEvent) {
    event.preventDefault();
    // The notice shows the other person's change; closing after seeing it
    // confirms the close against their version.
    const expectedVersion = changedByOther ? current.version : base.version;
    update.mutate(
      { id: base.id, expectedVersion, fields: { status: IssueStatus.CLOSED }, note: note.trim() },
      {
        onSuccess: (outcome) => {
          if (outcome.kind === "saved") {
            onClose();
            return;
          }
          setBase(outcome.current);
          setConflict(true);
        },
      },
    );
  }

  return (
    <Modal title="Close issue" onClose={onClose}>
      <form className="form" onSubmit={handleSubmit}>
        <p>
          <strong>{current.title}</strong>
        </p>
        {alreadyClosed ? (
          <p className="notice">{userName(current.updatedBy)} has already closed this issue.</p>
        ) : (
          (conflict || changedByOther) && (
            <p className={conflict ? "notice notice-error" : "notice"}>
              {userName(current.updatedBy)} changed this issue {conflict ? "first, so it wasn't closed" : "just now"}.
              Check the table, then close it again if it still applies.
            </p>
          )
        )}
        <label>
          Reason (optional)
          <textarea
            value={note}
            onChange={(e) => setNote(e.target.value)}
            rows={3}
            placeholder="e.g. Supplier resubmitted with w/c 0.45"
          />
        </label>
        <ErrorText error={update.error && errorMessage(update.error)} />
        <div className="actions">
          <button type="button" className="secondary" onClick={onClose}>
            Cancel
          </button>
          <button type="submit" disabled={update.isPending || alreadyClosed}>
            {update.isPending ? "Closing…" : "Close issue"}
          </button>
        </div>
      </form>
    </Modal>
  );
}
