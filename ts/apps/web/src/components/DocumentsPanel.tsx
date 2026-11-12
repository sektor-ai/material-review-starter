import { useRef, useState, type ChangeEvent } from "react";
import { DocumentStatus, type Document } from "@app/api";
import { documentOriginalUrl, errorMessage } from "../api.ts";
import { formatBytes } from "../format.ts";
import { MAX_UPLOAD_BYTES, useDocument, useUploadDocument } from "../queries/packs.ts";
import { DocumentStatusBadge, Drawer, ErrorText, TimeAgo, UserTag } from "../ui.tsx";

export function DocumentsPanel({
  packId,
  documents,
  locked,
}: {
  packId: string;
  documents: Document[];
  locked: boolean;
}) {
  const upload = useUploadDocument(packId);
  const input = useRef<HTMLInputElement>(null);
  const [tooLarge, setTooLarge] = useState<string | null>(null);
  const [viewingId, setViewingId] = useState<string | null>(null);
  // Read from the live list, so the drawer follows the document's status.
  const viewing = documents.find((d) => d.id === viewingId);

  function handleFile(event: ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0];
    event.target.value = "";
    if (!file) return;
    if (file.size > MAX_UPLOAD_BYTES) {
      setTooLarge(`${file.name} is ${formatBytes(file.size)}. Files over 20 MB can't be uploaded.`);
      return;
    }
    setTooLarge(null);
    upload.mutate({ file });
  }

  return (
    <section className="card-panel">
      <div className="section-head">
        <h2>Documents</h2>
        {!locked && (
          <>
            <button className="secondary" onClick={() => input.current?.click()} disabled={upload.isPending}>
              {upload.isPending ? "Uploading…" : "Upload"}
            </button>
            <input ref={input} type="file" hidden onChange={handleFile} accept=".md,.txt,.pdf,text/*,application/pdf" />
          </>
        )}
      </div>
      <ErrorText error={tooLarge ?? (upload.error && errorMessage(upload.error))} />
      {documents.length === 0 ? (
        <p className="empty">No documents yet. Upload the submittal to review it.</p>
      ) : (
        <ul className="doc-list">
          {documents.map((doc) => (
            <li key={doc.id}>
              <div>
                <button type="button" className="link" onClick={() => setViewingId(doc.id)}>
                  {doc.title || doc.filename}
                </button>
                <div className="muted small">
                  {doc.filename} · {formatBytes(doc.sizeBytes)} · <UserTag user={doc.createdBy} /> ·{" "}
                  <TimeAgo ts={doc.createdAt} />
                </div>
                {doc.status === DocumentStatus.FAILED && doc.parseError && (
                  <p className="error small">{doc.parseError}</p>
                )}
              </div>
              <div className="doc-side">
                <DocumentStatusBadge status={doc.status} />
                <a href={documentOriginalUrl(doc.id)} target="_blank" rel="noreferrer" className="small">
                  Original
                </a>
              </div>
            </li>
          ))}
        </ul>
      )}
      {viewing && <DocumentDrawer document={viewing} onClose={() => setViewingId(null)} />}
    </section>
  );
}

function DocumentDrawer({ document, onClose }: { document: Document; onClose: () => void }) {
  const doc = useDocument(document.id, document.status);
  return (
    <Drawer title={document.title || document.filename} onClose={onClose}>
      {doc.isPending && <p className="muted">Loading…</p>}
      <ErrorText error={doc.error && errorMessage(doc.error)} />
      {doc.data && document.status !== DocumentStatus.READY && (
        <p className="notice">This document is {document.status === DocumentStatus.FAILED ? "not parsed" : "still being parsed"}.</p>
      )}
      {doc.data?.parsedContent && <pre className="parsed">{doc.data.parsedContent}</pre>}
    </Drawer>
  );
}
