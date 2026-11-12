import { useState, type FormEvent } from "react";
import { PackStatus, type Pack } from "@app/api";
import { errorMessage } from "../api.ts";
import { isFinal } from "../format.ts";
import { useApprovePack, useCancelPack, useUpdatePack } from "../queries/packs.ts";
import { ErrorText, Modal, PackStatusBadge, TimeAgo, UserTag } from "../ui.tsx";

export function PackHeader({ pack }: { pack: Pack }) {
  const [editing, setEditing] = useState(false);
  const [cancelling, setCancelling] = useState(false);
  const approve = useApprovePack(pack.id);
  const locked = isFinal(pack.status);

  return (
    <section className="card-panel">
      <div className="section-head">
        <div>
          <h1>
            {pack.submittalNo} · {pack.title} <PackStatusBadge status={pack.status} />
          </h1>
          <p className="design-basis">
            <span className="muted">Design basis: </span>
            {pack.designBasis || <span className="muted">not set</span>}
          </p>
          <p className="muted small">
            Created by <UserTag user={pack.createdBy} /> · <TimeAgo ts={pack.createdAt} />
            {pack.status === PackStatus.APPROVED && (
              <>
                {" "}
                · Approved by <UserTag user={pack.approvedBy} /> · <TimeAgo ts={pack.approvedAt} />
              </>
            )}
            {pack.status === PackStatus.CANCELLED && (
              <>
                {" "}
                · Cancelled by <UserTag user={pack.cancelledBy} /> · <TimeAgo ts={pack.cancelledAt} />
                {pack.cancelReason && <> · “{pack.cancelReason}”</>}
              </>
            )}
          </p>
        </div>
        {!locked && (
          <div className="actions">
            <button className="secondary" onClick={() => setEditing(true)}>
              Edit details
            </button>
            <button className="secondary danger" onClick={() => setCancelling(true)}>
              Cancel submittal
            </button>
            <button
              onClick={() => approve.mutate()}
              disabled={pack.status !== PackStatus.RESOLVED || approve.isPending}
              title={
                pack.status === PackStatus.RESOLVED
                  ? "Approval is final"
                  : "A submittal can be approved once a review has succeeded and every issue is closed"
              }
            >
              {approve.isPending ? "Approving…" : "Approve"}
            </button>
          </div>
        )}
      </div>
      {locked && (
        <p className="notice">
          This submittal is {pack.status === PackStatus.APPROVED ? "approved" : "cancelled"}. Its documents, issues
          and details can no longer be changed.
        </p>
      )}
      <ErrorText error={approve.error && errorMessage(approve.error)} />
      {editing && <EditPackModal pack={pack} onClose={() => setEditing(false)} />}
      {cancelling && <CancelPackModal pack={pack} onClose={() => setCancelling(false)} />}
    </section>
  );
}

function EditPackModal({ pack, onClose }: { pack: Pack; onClose: () => void }) {
  const [title, setTitle] = useState(pack.title);
  const [designBasis, setDesignBasis] = useState(pack.designBasis);
  const update = useUpdatePack(pack.id);

  function handleSubmit(event: FormEvent) {
    event.preventDefault();
    update.mutate(
      {
        title: title.trim() !== pack.title ? title.trim() : undefined,
        designBasis: designBasis.trim() !== pack.designBasis ? designBasis.trim() : undefined,
      },
      { onSuccess: onClose },
    );
  }

  return (
    <Modal title={`Edit ${pack.submittalNo}`} onClose={onClose}>
      <form className="form" onSubmit={handleSubmit}>
        <label>
          Title
          <input value={title} onChange={(e) => setTitle(e.target.value)} required />
        </label>
        <label>
          Design basis
          <textarea value={designBasis} onChange={(e) => setDesignBasis(e.target.value)} rows={3} />
        </label>
        <ErrorText error={update.error && errorMessage(update.error)} />
        <div className="actions">
          <button type="button" className="secondary" onClick={onClose}>
            Cancel
          </button>
          <button type="submit" disabled={update.isPending}>
            {update.isPending ? "Saving…" : "Save"}
          </button>
        </div>
      </form>
    </Modal>
  );
}

function CancelPackModal({ pack, onClose }: { pack: Pack; onClose: () => void }) {
  const [reason, setReason] = useState("");
  const cancel = useCancelPack(pack.id);

  function handleSubmit(event: FormEvent) {
    event.preventDefault();
    cancel.mutate(reason.trim(), { onSuccess: onClose });
  }

  return (
    <Modal title={`Cancel ${pack.submittalNo}?`} onClose={onClose}>
      <form className="form" onSubmit={handleSubmit}>
        <p>
          The submittal is withdrawn and any running review stops. <strong>This can't be undone.</strong>
        </p>
        <label>
          Reason (optional)
          <textarea value={reason} onChange={(e) => setReason(e.target.value)} rows={2} />
        </label>
        <ErrorText error={cancel.error && errorMessage(cancel.error)} />
        <div className="actions">
          <button type="button" className="secondary" onClick={onClose}>
            Keep it
          </button>
          <button type="submit" className="danger" disabled={cancel.isPending}>
            {cancel.isPending ? "Cancelling…" : "Cancel submittal"}
          </button>
        </div>
      </form>
    </Modal>
  );
}
