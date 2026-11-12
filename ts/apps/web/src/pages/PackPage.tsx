import { Code } from "@connectrpc/connect";
import { DocumentStatus, type User } from "@app/api";
import { errorMessage, hasCode } from "../api.ts";
import { DocumentsPanel } from "../components/DocumentsPanel.tsx";
import { IssuesTable } from "../components/IssuesTable.tsx";
import { PackHeader } from "../components/PackHeader.tsx";
import { ReviewPanel } from "../components/ReviewPanel.tsx";
import { isFinal } from "../format.ts";
import { useIssues } from "../queries/issues.ts";
import { usePack } from "../queries/packs.ts";
import { usePackWatch, type WatchStatus } from "../queries/watch.ts";
import { Link } from "../router.tsx";
import { ErrorText } from "../ui.tsx";

export function PackPage({ id, me }: { id: string; me: User }) {
  const pack = usePack(id);
  const issues = useIssues(id);
  const watch = usePackWatch(id, issues.data?.cursorSeq, me.id);

  if (pack.isPending) return <p className="muted">Loading…</p>;
  if (pack.error) {
    return hasCode(pack.error, Code.NotFound) ? (
      <p>
        This submittal doesn't exist. <Link to="/">Back to submittals</Link>
      </p>
    ) : (
      <ErrorText error={errorMessage(pack.error)} />
    );
  }

  const { pack: current, documents, latestRun } = pack.data;
  if (!current) return <ErrorText error="The server returned no pack." />;
  const locked = isFinal(current.status);

  return (
    <div className="stack">
      <nav className="crumbs">
        <Link to="/">Submittals</Link> / {current.submittalNo}
        <LiveIndicator status={watch.status} />
      </nav>
      <PackHeader pack={current} latestRun={latestRun} />
      <div className="grid-2">
        <DocumentsPanel packId={id} documents={documents} locked={locked} />
        <ReviewPanel pack={current} latestRun={latestRun} hasReadyDocuments={documents.some((d) => d.status === DocumentStatus.READY)}
        />
      </div>
      {issues.error ? (
        <ErrorText error={errorMessage(issues.error)} />
      ) : (
        <IssuesTable
          issues={issues.data?.issues}
          documents={documents}
          locked={locked}
          me={me}
          recent={watch.recent}
        />
      )}
    </div>
  );
}

const liveLabel: Record<WatchStatus, string> = {
  connecting: "Connecting…",
  live: "Live",
  reconnecting: "Reconnecting…",
};

function LiveIndicator({ status }: { status: WatchStatus }) {
  return (
    <span className={`live live-${status}`} title="Changes by other people appear here without refreshing">
      <span className="dot" aria-hidden="true" />
      {liveLabel[status]}
    </span>
  );
}
