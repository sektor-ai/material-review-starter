import { useState, type FormEvent } from "react";
import { Code } from "@connectrpc/connect";
import { errorMessage, hasCode } from "../api.ts";
import { useCreatePack, usePacks } from "../queries/packs.ts";
import { Link, navigate, packPath } from "../router.tsx";
import { ErrorText, Modal, PackStatusBadge, TimeAgo, UserTag } from "../ui.tsx";

export function PacksPage() {
  const packs = usePacks();
  const [creating, setCreating] = useState(false);

  return (
    <section>
      <div className="section-head">
        <h1>Material submittals</h1>
        <button onClick={() => setCreating(true)}>New submittal</button>
      </div>

      {packs.isPending && <p className="muted">Loading…</p>}
      {packs.error && <ErrorText error={errorMessage(packs.error)} />}
      {packs.data && packs.data.packs.length === 0 && (
        <p className="empty">No submittals yet. Create one, upload its documents, and start a review.</p>
      )}
      {packs.data && packs.data.packs.length > 0 && (
        <div className="table-wrap">
          <table className="table">
            <thead>
              <tr>
                <th>No.</th>
                <th>Title</th>
                <th>Status</th>
                <th className="num">Documents</th>
                <th className="num">Open issues</th>
                <th>Created</th>
              </tr>
            </thead>
            <tbody>
              {packs.data.packs.map((pack) => (
                <tr key={pack.id}>
                  <td className="nowrap">
                    <Link to={packPath(pack.id)}>{pack.submittalNo}</Link>
                  </td>
                  <td>
                    <Link to={packPath(pack.id)}>{pack.title}</Link>
                    {pack.designBasis && <div className="muted small">{pack.designBasis}</div>}
                  </td>
                  <td>
                    <PackStatusBadge status={pack.status} />
                  </td>
                  <td className="num">{pack.documentCount}</td>
                  <td className="num">{pack.openIssueCount}</td>
                  <td className="nowrap">
                    <UserTag user={pack.createdBy} /> · <TimeAgo ts={pack.createdAt} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {creating && <NewPackModal onClose={() => setCreating(false)} />}
    </section>
  );
}

function NewPackModal({ onClose }: { onClose: () => void }) {
  const [submittalNo, setSubmittalNo] = useState("");
  const [title, setTitle] = useState("");
  const [designBasis, setDesignBasis] = useState("");
  const create = useCreatePack();

  function handleSubmit(event: FormEvent) {
    event.preventDefault();
    create.mutate(
      { submittalNo: submittalNo.trim(), title: title.trim(), designBasis: designBasis.trim() },
      { onSuccess: ({ pack }) => pack && navigate(packPath(pack.id)) },
    );
  }

  const error = create.error
    ? hasCode(create.error, Code.AlreadyExists)
      ? `Submittal ${submittalNo.trim()} already exists.`
      : errorMessage(create.error)
    : null;

  return (
    <Modal title="New submittal" onClose={onClose}>
      <form className="form" onSubmit={handleSubmit}>
        <label>
          Submittal no.
          <input value={submittalNo} onChange={(e) => setSubmittalNo(e.target.value)} placeholder="S-003" required />
        </label>
        <label>
          Title
          <input
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            placeholder="Concrete mix design – Level 3 slab"
            required
          />
        </label>
        <label>
          Design basis
          <textarea
            value={designBasis}
            onChange={(e) => setDesignBasis(e.target.value)}
            rows={3}
            placeholder="Suspended slabs Grade C40, exposure class X1, 25 mm cover"
          />
          <span className="hint">The requirements the submittal was designed for. The agent reviews against these.</span>
        </label>
        <ErrorText error={error} />
        <div className="actions">
          <button type="button" className="secondary" onClick={onClose}>
            Cancel
          </button>
          <button type="submit" disabled={create.isPending}>
            {create.isPending ? "Creating…" : "Create"}
          </button>
        </div>
      </form>
    </Modal>
  );
}
