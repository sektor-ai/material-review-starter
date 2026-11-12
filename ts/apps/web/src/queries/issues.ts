import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import type { Issue, IssueEvent, IssueSeverity, IssueStatus, SpecReference } from "@app/api";
import { clients, conflictIssue } from "../api.ts";
import { keys, mergeIssues, writeIssue, writeIssueEvent, type IssuesData } from "./cache.ts";

export function useIssues(packId: string) {
  const qc = useQueryClient();
  return useQuery({
    queryKey: keys.issues(packId),
    queryFn: async (): Promise<IssuesData> => {
      const res = await clients().issue.listIssues({ packId });
      const cached = qc.getQueryData<IssuesData>(keys.issues(packId));
      return { issues: mergeIssues(cached?.issues, res.issues), cursorSeq: res.cursorSeq };
    },
    // WatchPack keeps this current, so never refetch on a timer or focus.
    staleTime: Infinity,
    refetchOnWindowFocus: false,
  });
}

export function useIssueEvents(issueId: string | undefined) {
  return useQuery({
    queryKey: keys.issueEvents(issueId ?? ""),
    queryFn: async (): Promise<IssueEvent[]> => (await clients().issue.listIssueEvents({ issueId: issueId! })).events,
    enabled: issueId !== undefined,
    // New events are appended from the stream.
    staleTime: Infinity,
  });
}

// SpecRefInput is the editable part of a SpecReference.
export type SpecRefInput = Pick<SpecReference, "section" | "part" | "clause" | "clauseTitle"> & { pdfPage?: number };

export type IssueFields = {
  status?: IssueStatus;
  severity?: IssueSeverity;
  title?: string;
  description?: string;
  evidence?: string;
  specRef?: SpecRefInput;
};

export type UpdateIssueInput = {
  id: string;
  // The version the user's edit is based on.
  expectedVersion: number;
  fields: IssueFields;
  note?: string;
};

// UpdateOutcome makes a version conflict a normal result rather than an
// error, since the UI handles it as part of the flow.
export type UpdateOutcome =
  | { kind: "saved"; issue: Issue; event?: IssueEvent }
  | { kind: "conflict"; current: Issue };

export function useUpdateIssue() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (input: UpdateIssueInput): Promise<UpdateOutcome> => {
      try {
        const res = await clients().issue.updateIssue({
          id: input.id,
          expectedVersion: input.expectedVersion,
          ...input.fields,
          note: input.note ?? "",
        });
        if (!res.issue) throw new Error("UpdateIssue returned no issue");
        return { kind: "saved", issue: res.issue, event: res.event };
      } catch (error) {
        const current = conflictIssue(error);
        if (current) return { kind: "conflict", current };
        throw error;
      }
    },
    onSuccess: (outcome) => {
      if (outcome.kind === "conflict") {
        writeIssue(qc, outcome.current);
        return;
      }
      writeIssue(qc, outcome.issue);
      if (outcome.event) writeIssueEvent(qc, outcome.event);
    },
  });
}

export type CreateIssueInput = {
  documentId: string;
  severity: IssueSeverity;
  title: string;
  description: string;
  evidence: string;
  specRef: SpecRefInput;
  note?: string;
};

export function useCreateIssue() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (input: CreateIssueInput) => clients().issue.createIssue({ ...input, note: input.note ?? "" }),
    onSuccess: ({ issue, event }) => {
      if (issue) writeIssue(qc, issue);
      if (event) writeIssueEvent(qc, event);
    },
  });
}
