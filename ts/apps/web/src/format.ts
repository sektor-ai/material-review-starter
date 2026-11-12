import { toJson, type JsonValue } from "@bufbuild/protobuf";
import { timestampDate, ValueSchema, type Timestamp, type Value } from "@bufbuild/protobuf/wkt";
import {
  DocumentStatus,
  IssueSeverity,
  IssueStatus,
  PackStatus,
  ReviewRunStatus,
  UserKind,
  type FieldChange,
  type SpecReference,
  type User,
} from "@app/api";

export const packStatusLabel: Record<PackStatus, string> = {
  [PackStatus.UNSPECIFIED]: "Unknown",
  [PackStatus.OPEN]: "Open",
  [PackStatus.RESOLVED]: "Resolved",
  [PackStatus.APPROVED]: "Approved",
  [PackStatus.CANCELLED]: "Cancelled",
};

export const documentStatusLabel: Record<DocumentStatus, string> = {
  [DocumentStatus.UNSPECIFIED]: "Unknown",
  [DocumentStatus.PROCESSING]: "Processing",
  [DocumentStatus.READY]: "Ready",
  [DocumentStatus.FAILED]: "Failed",
};

export const issueStatusLabel: Record<IssueStatus, string> = {
  [IssueStatus.UNSPECIFIED]: "Unknown",
  [IssueStatus.OPEN]: "Open",
  [IssueStatus.CLOSED]: "Closed",
};

export const severityLabel: Record<IssueSeverity, string> = {
  [IssueSeverity.UNSPECIFIED]: "Unset",
  [IssueSeverity.CRITICAL]: "Critical",
  [IssueSeverity.MAJOR]: "Major",
  [IssueSeverity.MINOR]: "Minor",
};

export const severityHelp: Record<IssueSeverity, string> = {
  [IssueSeverity.UNSPECIFIED]: "",
  [IssueSeverity.CRITICAL]: "Safety, structural or fire and life safety. Blocks approval.",
  [IssueSeverity.MAJOR]: "Non-compliance that must be fixed before approval.",
  [IssueSeverity.MINOR]: "Missing information, documentation or clarification.",
};

export const runStatusLabel: Record<ReviewRunStatus, string> = {
  [ReviewRunStatus.UNSPECIFIED]: "Unknown",
  [ReviewRunStatus.QUEUED]: "Queued",
  [ReviewRunStatus.RUNNING]: "Running",
  [ReviewRunStatus.SUCCEEDED]: "Succeeded",
  [ReviewRunStatus.FAILED]: "Failed",
  [ReviewRunStatus.CANCELLED]: "Cancelled",
};

// Severities in the order the UI lists them, most severe first.
export const severities = [IssueSeverity.CRITICAL, IssueSeverity.MAJOR, IssueSeverity.MINOR] as const;

// isFinal reports whether a pack can no longer be changed.
export function isFinal(status: PackStatus): boolean {
  return status === PackStatus.APPROVED || status === PackStatus.CANCELLED;
}

export function isActiveRun(status: ReviewRunStatus | undefined): boolean {
  return status === ReviewRunStatus.QUEUED || status === ReviewRunStatus.RUNNING;
}

export function isAgent(user: User | undefined): boolean {
  return user?.kind === UserKind.AGENT;
}

export function userName(user: User | undefined): string {
  if (!user) return "Unknown";
  return user.name || (isAgent(user) ? "Review agent" : user.email || "Unknown");
}

// formatSpecRef renders a QCS 2014 reference, e.g. "QCS 05-06 Table 6.4".
export function formatSpecRef(ref: Pick<SpecReference, "section" | "part" | "clause"> | undefined): string {
  if (!ref || (!ref.section && !ref.part && !ref.clause)) return "";
  const sectionPart = [ref.section, ref.part].filter(Boolean).join("-");
  return ["QCS", sectionPart, ref.clause].filter(Boolean).join(" ");
}

export function toDate(ts: Timestamp | undefined): Date | undefined {
  return ts ? timestampDate(ts) : undefined;
}

export function formatDateTime(ts: Timestamp | undefined): string {
  const date = toDate(ts);
  return date ? date.toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" }) : "";
}

// formatRelative renders a past time as "just now", "5 min ago", "3 h ago",
// or a date once it is more than a week old.
export function formatRelative(ts: Timestamp | undefined, now: number = Date.now()): string {
  const date = toDate(ts);
  if (!date) return "";
  const seconds = Math.max(0, Math.round((now - date.getTime()) / 1000));
  if (seconds < 45) return "just now";
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours} h ago`;
  const days = Math.round(hours / 24);
  if (days < 7) return `${days} d ago`;
  return date.toLocaleDateString(undefined, { dateStyle: "medium" });
}

export function formatBytes(bytes: bigint | number): string {
  const n = Number(bytes);
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
}

const fieldLabels: Record<string, string> = {
  status: "Status",
  severity: "Severity",
  title: "Title",
  description: "Description",
  spec_ref: "Spec reference",
  evidence: "Evidence",
  document_id: "Document",
  metadata: "Metadata",
};

export function fieldLabel(field: string): string {
  return fieldLabels[field] ?? field.replace(/_/g, " ");
}

// Enum values arrive by name in event JSON ("ISSUE_SEVERITY_CRITICAL").
const enumNameLabels: Record<string, string> = {
  ISSUE_STATUS_OPEN: issueStatusLabel[IssueStatus.OPEN],
  ISSUE_STATUS_CLOSED: issueStatusLabel[IssueStatus.CLOSED],
  ISSUE_SEVERITY_CRITICAL: severityLabel[IssueSeverity.CRITICAL],
  ISSUE_SEVERITY_MAJOR: severityLabel[IssueSeverity.MAJOR],
  ISSUE_SEVERITY_MINOR: severityLabel[IssueSeverity.MINOR],
};

function asString(value: JsonValue | undefined): string {
  return typeof value === "string" ? value : typeof value === "number" ? String(value) : "";
}

// formatJsonValue renders one FieldChange value for people to read.
export function formatJsonValue(value: JsonValue | undefined): string {
  if (value === undefined || value === null || value === "") return "—";
  if (typeof value === "string") return enumNameLabels[value] ?? value;
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  if (Array.isArray(value)) return value.map(formatJsonValue).join(", ");
  // An object is a spec_ref. Accept both proto and JSON field names.
  if ("section" in value || "part" in value || "clause" in value) {
    const ref = formatSpecRef({
      section: asString(value.section),
      part: asString(value.part),
      clause: asString(value.clause),
    });
    const title = asString(value.clauseTitle ?? value.clause_title);
    return [ref, title && `(${title})`].filter(Boolean).join(" ") || "—";
  }
  return JSON.stringify(value);
}

function valueJson(value: Value | undefined): JsonValue | undefined {
  return value ? toJson(ValueSchema, value) : undefined;
}

export type ChangeLine = { field: string; label: string; from: string; to: string };

export function describeChange(change: FieldChange): ChangeLine {
  return {
    field: change.field,
    label: fieldLabel(change.field),
    from: formatJsonValue(valueJson(change.oldValue)),
    to: formatJsonValue(valueJson(change.newValue)),
  };
}
