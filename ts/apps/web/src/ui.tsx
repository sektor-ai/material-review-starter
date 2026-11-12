import { useEffect, useId, useState, type ReactNode } from "react";
import type { Timestamp } from "@bufbuild/protobuf/wkt";
import {
  DocumentStatus,
  IssueSeverity,
  IssueStatus,
  PackStatus,
  ReviewRunStatus,
  type User,
} from "@app/api";
import {
  documentStatusLabel,
  formatDateTime,
  formatRelative,
  isAgent,
  issueStatusLabel,
  packStatusLabel,
  runStatusLabel,
  severityHelp,
  severityLabel,
  userName,
} from "./format.ts";

type Tone = "neutral" | "blue" | "green" | "amber" | "red" | "purple";

export function Badge({ tone = "neutral", title, children }: { tone?: Tone; title?: string; children: ReactNode }) {
  return (
    <span className={`badge badge-${tone}`} title={title}>
      {children}
    </span>
  );
}

const packTone: Record<PackStatus, Tone> = {
  [PackStatus.UNSPECIFIED]: "neutral",
  [PackStatus.OPEN]: "amber",
  [PackStatus.RESOLVED]: "blue",
  [PackStatus.APPROVED]: "green",
  [PackStatus.CANCELLED]: "neutral",
};

export function PackStatusBadge({ status }: { status: PackStatus }) {
  return <Badge tone={packTone[status]}>{packStatusLabel[status]}</Badge>;
}

const documentTone: Record<DocumentStatus, Tone> = {
  [DocumentStatus.UNSPECIFIED]: "neutral",
  [DocumentStatus.PROCESSING]: "amber",
  [DocumentStatus.READY]: "green",
  [DocumentStatus.FAILED]: "red",
};

export function DocumentStatusBadge({ status }: { status: DocumentStatus }) {
  return <Badge tone={documentTone[status]}>{documentStatusLabel[status]}</Badge>;
}

const severityTone: Record<IssueSeverity, Tone> = {
  [IssueSeverity.UNSPECIFIED]: "neutral",
  [IssueSeverity.CRITICAL]: "red",
  [IssueSeverity.MAJOR]: "amber",
  [IssueSeverity.MINOR]: "blue",
};

export function SeverityBadge({ severity }: { severity: IssueSeverity }) {
  return (
    <Badge tone={severityTone[severity]} title={severityHelp[severity]}>
      {severityLabel[severity]}
    </Badge>
  );
}

export function IssueStatusBadge({ status }: { status: IssueStatus }) {
  return <Badge tone={status === IssueStatus.OPEN ? "amber" : "green"}>{issueStatusLabel[status]}</Badge>;
}

const runTone: Record<ReviewRunStatus, Tone> = {
  [ReviewRunStatus.UNSPECIFIED]: "neutral",
  [ReviewRunStatus.QUEUED]: "neutral",
  [ReviewRunStatus.RUNNING]: "blue",
  [ReviewRunStatus.SUCCEEDED]: "green",
  [ReviewRunStatus.FAILED]: "red",
  [ReviewRunStatus.CANCELLED]: "neutral",
};

export function RunStatusBadge({ status }: { status: ReviewRunStatus }) {
  return <Badge tone={runTone[status]}>{runStatusLabel[status]}</Badge>;
}

// UserTag names an actor and marks the agent, so it is always clear whether
// a person or the agent made a change.
export function UserTag({ user }: { user: User | undefined }) {
  if (isAgent(user)) {
    return (
      <span className="user">
        <Badge tone="purple">Agent</Badge>
      </span>
    );
  }
  return <span className="user">{userName(user)}</span>;
}

// useNow re-renders every interval so relative times stay current.
function useNow(intervalMs = 30_000): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), intervalMs);
    return () => clearInterval(timer);
  }, [intervalMs]);
  return now;
}

export function TimeAgo({ ts }: { ts: Timestamp | undefined }) {
  const now = useNow();
  if (!ts) return null;
  return (
    <time className="muted" title={formatDateTime(ts)}>
      {formatRelative(ts, now)}
    </time>
  );
}

export function Modal({
  title,
  onClose,
  children,
  wide,
}: {
  title: string;
  onClose: () => void;
  children: ReactNode;
  wide?: boolean;
}) {
  const titleId = useId();
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);
  return (
    <div className="overlay" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className={wide ? "modal modal-wide" : "modal"} role="dialog" aria-modal="true" aria-labelledby={titleId}>
        <div className="modal-head">
          <h2 id={titleId}>{title}</h2>
          <button type="button" className="icon" onClick={onClose} aria-label="Close">
            ×
          </button>
        </div>
        {children}
      </div>
    </div>
  );
}

export function Drawer({ title, onClose, children }: { title: string; onClose: () => void; children: ReactNode }) {
  const titleId = useId();
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);
  return (
    <div className="overlay overlay-drawer" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <aside className="drawer" role="dialog" aria-modal="true" aria-labelledby={titleId}>
        <div className="modal-head">
          <h2 id={titleId}>{title}</h2>
          <button type="button" className="icon" onClick={onClose} aria-label="Close">
            ×
          </button>
        </div>
        <div className="drawer-body">{children}</div>
      </aside>
    </div>
  );
}

export function ErrorText({ error }: { error: string | null | undefined }) {
  return error ? (
    <p className="error" role="alert">
      {error}
    </p>
  ) : null;
}
