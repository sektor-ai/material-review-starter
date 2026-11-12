import { useMemo, useState } from "react";
import { IssueSeverity, IssueStatus, type Document, type Issue, type User } from "@app/api";
import { errorMessage } from "../api.ts";
import { formatSpecRef, severities, severityLabel, toDate, userName } from "../format.ts";
import { useUpdateIssue } from "../queries/issues.ts";
import { ErrorText, IssueStatusBadge, SeverityBadge, TimeAgo, UserTag } from "../ui.tsx";
import { CloseIssueModal, IssueEditor } from "./IssueEditor.tsx";
import { IssueHistory } from "./IssueHistory.tsx";

type StatusFilter = "all" | "open" | "closed";

const severityRank: Record<IssueSeverity, number> = {
  [IssueSeverity.CRITICAL]: 0,
  [IssueSeverity.MAJOR]: 1,
  [IssueSeverity.MINOR]: 2,
  [IssueSeverity.UNSPECIFIED]: 3,
};

// sortIssues lists open issues first, then by severity, then oldest first,
// so the table does not reshuffle as new issues stream in at the bottom.
export function sortIssues(issues: Issue[]): Issue[] {
  return issues.slice().sort((a, b) => {
    if (a.status !== b.status) return a.status === IssueStatus.OPEN ? -1 : 1;
    if (a.severity !== b.severity) return severityRank[a.severity] - severityRank[b.severity];
    return (toDate(a.createdAt)?.getTime() ?? 0) - (toDate(b.createdAt)?.getTime() ?? 0);
  });
}

// conflictNotice explains a rejected quick change without blaming another
// person for what may have been the user's own earlier write.
export function conflictNotice(current: Issue, me: User): string {
  const who = current.updatedBy?.id === me.id ? "You" : userName(current.updatedBy);
  return `${who} changed “${current.title}” since this row was loaded, so your change wasn't saved. The table now shows the latest version; check it and try again.`;
}

type Dialog =
  | { kind: "create" }
  | { kind: "edit"; issue: Issue }
  | { kind: "close"; issue: Issue }
  | { kind: "history"; issueId: string };

export function IssuesTable({
  issues,
  documents,
  locked,
  me,
  recent,
}: {
  issues: Issue[] | undefined;
  documents: Document[];
  locked: boolean;
  me: User;
  recent: Record<string, string>;
}) {
  const [status, setStatus] = useState<StatusFilter>("all");
  const [severity, setSeverity] = useState<IssueSeverity | "all">("all");
  const [documentId, setDocumentId] = useState<string>("all");
  const [dialog, setDialog] = useState<Dialog | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  // Issues with a quick change in flight. Their controls are disabled so a
  // second change can't be sent with the version the first one replaces.
  const [saving, setSaving] = useState<ReadonlySet<string>>(new Set());
  const update = useUpdateIssue();

  const documentTitles = useMemo(
    () => new Map(documents.map((d) => [d.id, d.title || d.filename])),
    [documents],
  );
  const all = issues ?? [];
  const openCount = all.filter((i) => i.status === IssueStatus.OPEN).length;
  const visible = useMemo(
    () =>
      sortIssues(
        all.filter(
          (i) =>
            (status === "all" || (status === "open") === (i.status === IssueStatus.OPEN)) &&
            (severity === "all" || i.severity === severity) &&
            (documentId === "all" || i.documentId === documentId),
        ),
      ),
    [all, status, severity, documentId],
  );
  const byId = (id: string) => all.find((i) => i.id === id);

  async function quickUpdate(issue: Issue, fields: { severity?: IssueSeverity; status?: IssueStatus }) {
    if (saving.has(issue.id)) return;
    setNotice(null);
    setSaving((s) => new Set(s).add(issue.id));
    // The version on screen: the change is based on what the user sees.
    const expectedVersion = byId(issue.id)?.version ?? issue.version;
    try {
      const outcome = await update.mutateAsync({ id: issue.id, expectedVersion, fields });
      if (outcome.kind === "conflict") setNotice(conflictNotice(outcome.current, me));
    } catch (error) {
      setNotice(errorMessage(error));
    } finally {
      setSaving((s) => {
        const next = new Set(s);
        next.delete(issue.id);
        return next;
      });
    }
  }

  return (
    <section className="card-panel">
      <div className="section-head">
        <h2>
          Issues{" "}
          <span className="muted small">
            {openCount} open of {all.length}
          </span>
        </h2>
        <div className="actions filters">
          <select value={status} onChange={(e) => setStatus(e.target.value as StatusFilter)} aria-label="Status">
            <option value="all">All statuses</option>
            <option value="open">Open</option>
            <option value="closed">Closed</option>
          </select>
          <select
            value={severity}
            onChange={(e) => setSeverity(e.target.value === "all" ? "all" : (Number(e.target.value) as IssueSeverity))}
            aria-label="Severity"
          >
            <option value="all">All severities</option>
            {severities.map((s) => (
              <option key={s} value={s}>
                {severityLabel[s]}
              </option>
            ))}
          </select>
          {documents.length > 1 && (
            <select value={documentId} onChange={(e) => setDocumentId(e.target.value)} aria-label="Document">
              <option value="all">All documents</option>
              {documents.map((d) => (
                <option key={d.id} value={d.id}>
                  {d.title || d.filename}
                </option>
              ))}
            </select>
          )}
          {!locked && documents.length > 0 && <button onClick={() => setDialog({ kind: "create" })}>Add issue</button>}
        </div>
      </div>

      <ErrorText error={notice} />

      {!issues && <p className="muted">Loading…</p>}
      {issues && all.length === 0 && <p className="empty">No issues yet. Run a review, or add one by hand.</p>}
      {issues && all.length > 0 && visible.length === 0 && <p className="empty">No issues match these filters.</p>}
      {visible.length > 0 && (
        <div className="table-wrap">
          <table className="table issues">
            <thead>
              <tr>
                <th>Severity</th>
                <th>Status</th>
                <th>Issue</th>
                <th>QCS 2014</th>
                <th>Evidence</th>
                <th>Raised</th>
                <th>Last change</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {visible.map((issue) => (
                <tr key={issue.id} className={recent[issue.id] ? "flash" : undefined} data-issue-id={issue.id}>
                  <td>
                    {locked ? (
                      <SeverityBadge severity={issue.severity} />
                    ) : (
                      <select
                        className={`severity-select sev-${issue.severity}`}
                        value={issue.severity}
                        disabled={saving.has(issue.id)}
                        aria-label={`Severity of ${issue.title}`}
                        onChange={(e) => quickUpdate(issue, { severity: Number(e.target.value) as IssueSeverity })}
                      >
                        {severities.map((s) => (
                          <option key={s} value={s}>
                            {severityLabel[s]}
                          </option>
                        ))}
                      </select>
                    )}
                  </td>
                  <td>
                    <IssueStatusBadge status={issue.status} />
                    {!locked &&
                      (issue.status === IssueStatus.OPEN ? (
                        <button
                          className="link small block"
                          disabled={saving.has(issue.id)}
                          onClick={() => setDialog({ kind: "close", issue })}
                        >
                          Close…
                        </button>
                      ) : (
                        <button
                          className="link small block"
                          disabled={saving.has(issue.id)}
                          onClick={() => quickUpdate(issue, { status: IssueStatus.OPEN })}
                        >
                          Reopen
                        </button>
                      ))}
                  </td>
                  <td className="issue-cell">
                    <strong>{issue.title}</strong>
                    {issue.description && <p className="clamp">{issue.description}</p>}
                    <span className="muted small">{documentTitles.get(issue.documentId) ?? "Unknown document"}</span>
                  </td>
                  <td className="nowrap">
                    {formatSpecRef(issue.specRef)}
                    {issue.specRef?.clauseTitle && <div className="muted small wrap">{issue.specRef.clauseTitle}</div>}
                    {issue.specRef?.pdfPage !== undefined && (
                      <div className="muted small">PDF p. {issue.specRef.pdfPage}</div>
                    )}
                  </td>
                  <td className="evidence">{issue.evidence && <q>{issue.evidence}</q>}</td>
                  <td className="nowrap small">
                    <UserTag user={issue.createdBy} />
                    <div>
                      <TimeAgo ts={issue.createdAt} />
                    </div>
                  </td>
                  <td className="nowrap small">
                    {recent[issue.id] ? (
                      <span className="changed-by">Updated by {recent[issue.id]}</span>
                    ) : (
                      <>
                        <UserTag user={issue.updatedBy} />
                        <div>
                          <TimeAgo ts={issue.updatedAt} /> · v{issue.version}
                        </div>
                      </>
                    )}
                  </td>
                  <td className="nowrap row-actions">
                    {!locked && (
                      <button
                        className="link"
                        disabled={saving.has(issue.id)}
                        onClick={() => setDialog({ kind: "edit", issue })}
                      >
                        Edit
                      </button>
                    )}
                    <button className="link" onClick={() => setDialog({ kind: "history", issueId: issue.id })}>
                      History
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {dialog?.kind === "create" && <IssueEditor documents={documents} me={me} onClose={() => setDialog(null)} />}
      {dialog?.kind === "edit" && (
        <IssueEditor
          documents={documents}
          me={me}
          base={dialog.issue}
          live={byId(dialog.issue.id)}
          onClose={() => setDialog(null)}
        />
      )}
      {dialog?.kind === "close" && (
        <CloseIssueModal issue={dialog.issue} live={byId(dialog.issue.id)} me={me} onClose={() => setDialog(null)} />
      )}
      {dialog?.kind === "history" && byId(dialog.issueId) && (
        <IssueHistory
          issue={byId(dialog.issueId)!}
          documentTitle={documentTitles.get(byId(dialog.issueId)!.documentId)}
          onClose={() => setDialog(null)}
        />
      )}
    </section>
  );
}
