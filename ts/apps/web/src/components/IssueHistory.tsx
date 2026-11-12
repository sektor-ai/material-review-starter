import { IssueEventKind, type Issue, type IssueEvent } from "@app/api";
import { errorMessage } from "../api.ts";
import { describeChange, formatSpecRef } from "../format.ts";
import { useIssueEvents } from "../queries/issues.ts";
import { Drawer, ErrorText, IssueStatusBadge, SeverityBadge, TimeAgo, UserTag } from "../ui.tsx";

// IssueHistory shows an issue in full and its change log: who changed what,
// when, and why. New events arrive from the stream while it is open.
export function IssueHistory({
  issue,
  documentTitle,
  onClose,
}: {
  issue: Issue;
  documentTitle: string | undefined;
  onClose: () => void;
}) {
  const events = useIssueEvents(issue.id);
  const newestFirst = events.data ? [...events.data].reverse() : [];
  const metadata = issue.metadata && Object.keys(issue.metadata).length > 0 ? issue.metadata : null;

  return (
    <Drawer title={issue.title} onClose={onClose}>
      <div className="issue-detail">
        <p>
          <SeverityBadge severity={issue.severity} /> <IssueStatusBadge status={issue.status} />{" "}
          <span className="muted small">v{issue.version}</span>
        </p>
        {issue.description && <p className="prewrap">{issue.description}</p>}
        <dl>
          <dt>QCS 2014</dt>
          <dd>
            {formatSpecRef(issue.specRef) || "—"}
            {issue.specRef?.clauseTitle && <> · {issue.specRef.clauseTitle}</>}
            {issue.specRef?.pdfPage !== undefined && <> · PDF p. {issue.specRef.pdfPage}</>}
          </dd>
          <dt>Evidence</dt>
          <dd>{issue.evidence ? <q>{issue.evidence}</q> : "—"}</dd>
          <dt>Document</dt>
          <dd>{documentTitle ?? "—"}</dd>
          {metadata && (
            <>
              <dt>Agent notes</dt>
              <dd>
                <pre className="metadata">{JSON.stringify(metadata, null, 2)}</pre>
              </dd>
            </>
          )}
        </dl>
      </div>

      <h3>Change log</h3>
      {events.isPending && <p className="muted">Loading…</p>}
      <ErrorText error={events.error && errorMessage(events.error)} />
      <ol className="events">
        {newestFirst.map((event) => (
          <EventItem key={String(event.seq)} event={event} />
        ))}
      </ol>
    </Drawer>
  );
}

function EventItem({ event }: { event: IssueEvent }) {
  const created = event.kind === IssueEventKind.CREATED;
  const changes = event.changes.map(describeChange);
  return (
    <li>
      <div className="event-head">
        <UserTag user={event.actor} /> {created ? "raised this issue" : "changed"} · <TimeAgo ts={event.createdAt} />{" "}
        <span className="muted small">v{event.version}</span>
      </div>
      {event.note && <p className="event-note">“{event.note}”</p>}
      {!created && changes.length > 0 && (
        <ul className="changes">
          {changes.map((c) => (
            <li key={c.field}>
              <span className="muted">{c.label}:</span> <del>{c.from}</del> → <ins>{c.to}</ins>
            </li>
          ))}
        </ul>
      )}
      {created && (
        <ul className="changes">
          {changes
            .filter((c) => c.field === "severity" || c.field === "title" || c.field === "spec_ref")
            .map((c) => (
              <li key={c.field}>
                <span className="muted">{c.label}:</span> {c.to}
              </li>
            ))}
        </ul>
      )}
    </li>
  );
}
