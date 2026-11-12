import { DocumentStatus, IssueSeverity, ReviewRunStatus } from "@app/api";
import type { MockStore, NewIssue } from "./store.ts";

// A scripted stand-in for the review agent: it walks a fixed list of
// findings per submittal, raising each as the agent user, so the UI's live
// updates can be exercised without the real worker.

export type Finding = Omit<NewIssue, "documentId" | "note"> & { progress: string };

const s001: Finding[] = [
  {
    progress: "Reading QCS 05-06 Table 6.4",
    severity: IssueSeverity.CRITICAL,
    title: "Water/cementitious ratio exceeds the maximum for C40",
    description:
      "The mix proposes a free water/cementitious ratio of 0.55. QCS 2014 limits it to 0.50 for this grade and exposure class.",
    evidence: "Free water/cementitious ratio: 0.55",
    specRef: { section: "05", part: "06", clause: "Table 6.4", clauseTitle: "Maximum free water/cementitious ratio", pdfPage: 652 },
    metadata: { confidence: 0.96 },
  },
  {
    progress: "Checking admixtures against QCS 05-05",
    severity: IssueSeverity.CRITICAL,
    title: "Calcium chloride accelerator is not permitted",
    description: "Admixtures containing chlorides shall not be used in reinforced concrete.",
    evidence: "Accelerator, calcium chloride based, 1.0% by mass of cement",
    specRef: { section: "05", part: "05", clause: "5.2.1", clauseTitle: "Admixtures – general", pdfPage: 645 },
    metadata: { confidence: 0.93 },
  },
  {
    progress: "Checking curing against QCS 05-10",
    severity: IssueSeverity.MAJOR,
    title: "Curing period is shorter than required",
    description: "Three days of curing compound is proposed; QCS 2014 requires a longer minimum curing period in hot weather.",
    evidence: "Curing period 3 days",
    specRef: { section: "05", part: "10", clause: "10.2.3", clauseTitle: "Curing period", pdfPage: 720 },
    metadata: { confidence: 0.81 },
  },
  {
    progress: "Checking aggregate approvals against QCS 05-02",
    severity: IssueSeverity.MINOR,
    title: "Aggregate source accreditation not provided",
    description: "The coarse aggregate supplier's Qatar Standards accreditation certificate is stated to follow.",
    evidence: "The supplier's Qatar Standards accreditation certificate will follow.",
    specRef: { section: "05", part: "02", clause: "2.1.2", clauseTitle: "Source approval", pdfPage: 625 },
    metadata: { confidence: 0.88 },
  },
  {
    progress: "Checking chloride content against QCS 05-06",
    severity: IssueSeverity.MAJOR,
    title: "Acid-soluble chloride content too high",
    description: "Calculated chloride content of 0.25% exceeds the limit for reinforced concrete.",
    evidence: "Acid-soluble chloride: 0.25% by mass of cementitious (calculated)",
    specRef: { section: "05", part: "06", clause: "6.3.2", clauseTitle: "Chloride content", pdfPage: 655 },
    metadata: { confidence: 0.77 },
  },
];

const s002: Finding[] = [
  {
    progress: "Checking fire rating against QCS 18-05 5.3",
    severity: IssueSeverity.CRITICAL,
    title: "Doorset rated 30 minutes; one hour required",
    description: "The design basis requires one-hour fire resisting door assemblies. The submitted doorset is 30/30.",
    evidence: "Fire resistance: 30/30 (30 minutes stability and integrity), BS 476",
    specRef: { section: "18", part: "05", clause: "5.3.4", clauseTitle: "Fire resisting doors", pdfPage: 3551 },
    metadata: { confidence: 0.97 },
  },
  {
    progress: "Checking hold-open devices against QCS 18-07",
    severity: IssueSeverity.CRITICAL,
    title: "Manual magnetic hold-open on a fire door",
    description: "Hold-open devices on fire doors must release automatically on fire alarm; a manual release is not acceptable.",
    evidence: "Hold-open: wall-mounted magnetic catch, manual release",
    specRef: { section: "18", part: "07", clause: "7.4.2", clauseTitle: "Door holders and releases", pdfPage: 3561 },
    metadata: { confidence: 0.9 },
  },
  {
    progress: "Checking hinges against QCS 18-07",
    severity: IssueSeverity.MAJOR,
    title: "Aluminium rising butt hinges on a fire door",
    description: "Hinges on fire doors must be steel or stainless steel with a melting point above 800 °C.",
    evidence: "Rising butt hinges, 2 no. per leaf, 100 x 75 mm, aluminium alloy",
    specRef: { section: "18", part: "07", clause: "7.3.1", clauseTitle: "Hinges", pdfPage: 3559 },
    metadata: { confidence: 0.86 },
  },
  {
    progress: "Checking certification against QCS 01-07 7.11",
    severity: IssueSeverity.MINOR,
    title: "Fire test certificate not provided",
    description: "Materials approval requires the test certificate with the submittal, not after it.",
    evidence: "Certification: Test certificate to follow",
    specRef: { section: "01", part: "07", clause: "7.11", clauseTitle: "Materials approvals", pdfPage: 41 },
    metadata: { confidence: 0.92 },
  },
];

const generic: Finding[] = [
  {
    progress: "Checking submittal completeness against QCS 01-07 7.11",
    severity: IssueSeverity.MINOR,
    title: "Manufacturer's data sheet missing",
    description: "Materials approval requests must include the manufacturer's technical data.",
    evidence: "",
    specRef: { section: "01", part: "07", clause: "7.11", clauseTitle: "Materials approvals", pdfPage: 41 },
    metadata: { confidence: 0.6 },
  },
];

export const findings: Record<string, Finding[]> = { "S-001": s001, "S-002": s002 };

type Timers = { delay: (ms: number) => Promise<void> };

const realTimers: Timers = { delay: (ms) => new Promise((r) => setTimeout(r, ms)) };

// runAgent drives one queued run to completion, raising the findings the
// pack does not already have. It stops if the run is cancelled.
export async function runAgent(store: MockStore, runId: string, timers: Timers = realTimers, stepMs = 2500) {
  const stillActive = () => {
    const status = store.runs.get(runId)?.status;
    return status === ReviewRunStatus.QUEUED || status === ReviewRunStatus.RUNNING;
  };
  const run = store.mustRun(runId);
  const pack = store.packs.get(run.packId);
  if (!pack) return;

  await timers.delay(1200);
  if (!stillActive()) return;
  store.updateRun(runId, {
    status: ReviewRunStatus.RUNNING,
    startedAt: store.now(),
    agentSessionId: `sesn_mock_${runId.slice(0, 8)}`,
    progressNote: "Reading the submittal",
  });

  const doc = [...store.docs.values()].find(
    (d) => d.doc.packId === pack.id && d.doc.status === DocumentStatus.READY,
  )?.doc;
  const existing = new Set([...store.issues.values()].filter((i) => i.packId === pack.id).map((i) => i.title));
  const todo = (findings[pack.submittalNo] ?? generic).filter((f) => !existing.has(f.title));

  let created = 0;
  for (const finding of todo) {
    await timers.delay(stepMs / 2);
    if (!stillActive()) return;
    store.updateRun(runId, { progressNote: finding.progress });
    await timers.delay(stepMs / 2);
    if (!stillActive() || !doc) return;
    const { progress: _, ...issue } = finding;
    try {
      store.createIssue(store.agent, { ...issue, documentId: doc.id }, runId);
    } catch {
      return; // the pack was approved or cancelled meanwhile
    }
    created++;
    store.updateRun(runId, { issuesCreated: created });
  }

  await timers.delay(stepMs / 2);
  if (!stillActive()) return;
  store.finishRun(runId, ReviewRunStatus.SUCCEEDED, {
    issuesCreated: created,
    summary:
      created === 0
        ? "No new non-compliances found against QCS 2014."
        : `Found ${created} non-compliance${created === 1 ? "" : "s"} against QCS 2014. See the issue table for clause references.`,
  });
}
