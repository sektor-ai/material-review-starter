import { useState, type FormEvent } from "react";
import { ReviewRunStatus, type Pack, type ReviewRun } from "@app/api";
import { errorMessage } from "../api.ts";
import { isActiveRun, isFinal } from "../format.ts";
import { useCancelReviewRun, useReviewRuns, useStartReview } from "../queries/reviews.ts";
import { ErrorText, Modal, RunStatusBadge, TimeAgo, UserTag } from "../ui.tsx";

export function ReviewPanel({
  pack,
  latestRun,
  hasReadyDocuments,
}: {
  pack: Pack;
  latestRun: ReviewRun | undefined;
  hasReadyDocuments: boolean;
}) {
  const [starting, setStarting] = useState(false);
  const [showHistory, setShowHistory] = useState(false);
  const cancelRun = useCancelReviewRun();
  const active = isActiveRun(latestRun?.status);
  const canStart = !isFinal(pack.status) && !active && hasReadyDocuments;

  return (
    <section className="card-panel">
      <div className="section-head">
        <h2>Agent review</h2>
        <div className="actions">
          {latestRun && (
            <button className="secondary" onClick={() => setShowHistory(true)}>
              History
            </button>
          )}
          {!isFinal(pack.status) && (
            <button
              onClick={() => setStarting(true)}
              disabled={!canStart}
              title={
                active
                  ? "A review is already in progress"
                  : hasReadyDocuments
                    ? undefined
                    : "Upload a document and wait for it to be ready"
              }
            >
              {latestRun ? "Review again" : "Start review"}
            </button>
          )}
        </div>
      </div>

      {!latestRun && <p className="empty">Not reviewed yet. The agent checks every ready document against QCS 2014.</p>}
      {latestRun && <RunSummary run={latestRun} />}
      {latestRun && active && (
        <button
          className="secondary danger"
          onClick={() => cancelRun.mutate(latestRun.id)}
          disabled={cancelRun.isPending}
        >
          {cancelRun.isPending ? "Stopping…" : "Stop review"}
        </button>
      )}
      <ErrorText error={cancelRun.error && errorMessage(cancelRun.error)} />

      {starting && <StartReviewModal packId={pack.id} onClose={() => setStarting(false)} />}
      {showHistory && <RunHistoryModal packId={pack.id} onClose={() => setShowHistory(false)} />}
    </section>
  );
}

function RunSummary({ run }: { run: ReviewRun }) {
  return (
    <div className="run">
      <div className="run-line">
        <RunStatusBadge status={run.status} />
        <span className="muted small">
          started by <UserTag user={run.startedBy} /> · <TimeAgo ts={run.createdAt} />
          {run.finishedAt && (
            <>
              {" "}
              · finished <TimeAgo ts={run.finishedAt} />
            </>
          )}
        </span>
      </div>
      {isActiveRun(run.status) && (
        <p className="progress">
          <span className="spinner" aria-hidden="true" />
          {run.progressNote || (run.status === ReviewRunStatus.QUEUED ? "Waiting for a worker…" : "Working…")}
        </p>
      )}
      <p className="small">
        {run.issuesCreated} {run.issuesCreated === 1 ? "issue" : "issues"} raised
      </p>
      {run.summary && <p className="run-summary">{run.summary}</p>}
      {run.error && <p className="error small">{run.error}</p>}
    </div>
  );
}

function StartReviewModal({ packId, onClose }: { packId: string; onClose: () => void }) {
  const [instructions, setInstructions] = useState("");
  const start = useStartReview(packId);

  function handleSubmit(event: FormEvent) {
    event.preventDefault();
    start.mutate(instructions.trim(), { onSuccess: onClose });
  }

  return (
    <Modal title="Start agent review" onClose={onClose}>
      <form className="form" onSubmit={handleSubmit}>
        <p className="small">
          The agent reads every ready document, checks it against QCS 2014 and the design basis, and adds what it
          finds to the issue table as it goes.
        </p>
        <label>
          Extra instructions (optional)
          <textarea
            value={instructions}
            onChange={(e) => setInstructions(e.target.value)}
            rows={3}
            placeholder="e.g. Pay particular attention to curing."
          />
        </label>
        <ErrorText error={start.error && errorMessage(start.error)} />
        <div className="actions">
          <button type="button" className="secondary" onClick={onClose}>
            Cancel
          </button>
          <button type="submit" disabled={start.isPending}>
            {start.isPending ? "Starting…" : "Start review"}
          </button>
        </div>
      </form>
    </Modal>
  );
}

function RunHistoryModal({ packId, onClose }: { packId: string; onClose: () => void }) {
  const runs = useReviewRuns(packId);
  return (
    <Modal title="Review history" onClose={onClose} wide>
      {runs.isPending && <p className="muted">Loading…</p>}
      <ErrorText error={runs.error && errorMessage(runs.error)} />
      <ul className="run-list">
        {runs.data?.map((run) => (
          <li key={run.id}>
            <RunSummary run={run} />
          </li>
        ))}
      </ul>
    </Modal>
  );
}
