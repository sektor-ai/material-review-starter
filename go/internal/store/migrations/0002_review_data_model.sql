-- Review data model: packs (submittals), their documents, agent review runs,
-- issues, and the append-only issue event log.
--
-- Conventions:
-- - Ids are uuid v4 (gen_random_uuid()).
-- - Enum values are lower-case; the Go store maps them to the proto enums.
-- - Nothing is deleted through the app, so foreign keys have no cascades.
-- - Writers that touch a pack's issues lock the pack row first
--   (SELECT ... FROM packs WHERE id = $1 FOR UPDATE). That serialises writes
--   per pack, so issue_events.seq order is commit order within a pack, and
--   it makes the pack status check race-free.

-- +goose Up

-- Users ----------------------------------------------------------------------

-- One users table for people and the review agent. The agent has no email
-- or password, so it cannot sign in.
CREATE TYPE auth.user_kind AS ENUM ('human', 'agent');

ALTER TABLE auth.users
    ADD COLUMN kind auth.user_kind NOT NULL DEFAULT 'human',
    ALTER COLUMN email DROP NOT NULL,
    ALTER COLUMN password_hash DROP NOT NULL,
    ADD CONSTRAINT users_human_has_credentials
        CHECK (kind = 'agent' OR (email IS NOT NULL AND password_hash IS NOT NULL));

-- The review agent, with a fixed id (store.AgentUserID).
INSERT INTO auth.users (id, kind, name)
VALUES ('00000000-0000-4000-8000-000000000001', 'agent', 'Review Agent');

-- Shared triggers --------------------------------------------------------------

-- +goose StatementBegin
CREATE FUNCTION set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END
$$;
-- +goose StatementEnd

CREATE TRIGGER users_set_updated_at
    BEFORE UPDATE ON auth.users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Live updates for PackService.WatchPack. Every API instance LISTENs on
-- 'pack_activity'; notifications are delivered on commit. Payload:
-- {"pack_id": "...", "kind": "issue_event" | "run" | "pack", "seq": n}
-- (seq only for issue_event).
-- +goose StatementBegin
CREATE FUNCTION notify_pack_activity() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    payload jsonb;
BEGIN
    -- IF branches, not CASE: PL/pgSQL resolves every NEW.<field> in a CASE
    -- against the firing table, and packs has no pack_id column.
    IF TG_TABLE_NAME = 'issue_events' THEN
        payload := jsonb_build_object('pack_id', NEW.pack_id, 'kind', 'issue_event', 'seq', NEW.seq);
    ELSIF TG_TABLE_NAME = 'review_runs' THEN
        payload := jsonb_build_object('pack_id', NEW.pack_id, 'kind', 'run');
    ELSE
        payload := jsonb_build_object('pack_id', NEW.id, 'kind', 'pack');
    END IF;
    PERFORM pg_notify('pack_activity', payload::text);
    RETURN NULL;
END
$$;
-- +goose StatementEnd

-- Packs ------------------------------------------------------------------------

-- open <-> resolved is maintained by the service; approved and cancelled are
-- set by an engineer and are final. Status changes are not audited.
CREATE TYPE pack_status AS ENUM ('open', 'resolved', 'approved', 'cancelled');

CREATE TABLE packs (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    submittal_no  text NOT NULL UNIQUE CHECK (submittal_no <> ''),
    title         text NOT NULL CHECK (title <> ''),
    design_basis  text NOT NULL DEFAULT '',
    status        pack_status NOT NULL DEFAULT 'open',
    created_by    uuid NOT NULL REFERENCES auth.users (id),
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    approved_by   uuid REFERENCES auth.users (id),
    approved_at   timestamptz,
    cancelled_by  uuid REFERENCES auth.users (id),
    cancelled_at  timestamptz,
    cancel_reason text NOT NULL DEFAULT '',

    CONSTRAINT packs_approval_matches_status
        CHECK ((status = 'approved') = (approved_by IS NOT NULL AND approved_at IS NOT NULL)),
    CONSTRAINT packs_cancellation_matches_status
        CHECK ((status = 'cancelled') = (cancelled_by IS NOT NULL AND cancelled_at IS NOT NULL))
);

CREATE INDEX packs_created_at_idx ON packs (created_at DESC);

-- Approved and cancelled packs are final.
-- +goose StatementBegin
CREATE FUNCTION packs_guard_final() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'pack % is %, and can no longer change', OLD.id, OLD.status
        USING ERRCODE = 'check_violation';
END
$$;
-- +goose StatementEnd

CREATE TRIGGER packs_guard_final
    BEFORE UPDATE ON packs
    FOR EACH ROW WHEN (OLD.status IN ('approved', 'cancelled'))
    EXECUTE FUNCTION packs_guard_final();

CREATE TRIGGER packs_set_updated_at
    BEFORE UPDATE ON packs
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER packs_notify
    AFTER INSERT OR UPDATE ON packs
    FOR EACH ROW EXECUTE FUNCTION notify_pack_activity();

-- Documents --------------------------------------------------------------------

CREATE TYPE document_status AS ENUM ('processing', 'ready', 'failed');

-- The original file lives in object storage under storage_key; the parsed
-- text the agent reviews lives here.
CREATE TABLE documents (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    pack_id        uuid NOT NULL REFERENCES packs (id),
    filename       text NOT NULL CHECK (filename <> ''),
    title          text NOT NULL CHECK (title <> ''),
    mime_type      text NOT NULL,
    size_bytes     bigint NOT NULL CHECK (size_bytes >= 0),
    sha256         bytea NOT NULL CHECK (octet_length(sha256) = 32),
    storage_key    text NOT NULL UNIQUE,
    status         document_status NOT NULL DEFAULT 'processing',
    parse_error    text NOT NULL DEFAULT '',
    parsed_content text,
    created_by     uuid NOT NULL REFERENCES auth.users (id),
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),

    -- Target for the composite foreign key from issues.
    UNIQUE (id, pack_id),
    CONSTRAINT documents_ready_has_content
        CHECK (status <> 'ready' OR parsed_content IS NOT NULL),
    CONSTRAINT documents_failed_has_error
        CHECK (status <> 'failed' OR parse_error <> '')
);

CREATE INDEX documents_pack_id_idx ON documents (pack_id);

CREATE TRIGGER documents_set_updated_at
    BEFORE UPDATE ON documents
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Review runs ------------------------------------------------------------------

CREATE TYPE review_run_status AS ENUM ('queued', 'running', 'succeeded', 'failed', 'cancelled');

-- Also the work queue. A worker claims a queued run, or a running one whose
-- lease has expired, with FOR UPDATE SKIP LOCKED, and renews the lease while
-- it drives the agent session. CancelReviewRun sets status = 'cancelled';
-- the worker sees that when its next renewal (WHERE status = 'running')
-- matches no row, and interrupts the session.
CREATE TABLE review_runs (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    pack_id          uuid NOT NULL REFERENCES packs (id),
    status           review_run_status NOT NULL DEFAULT 'queued',
    started_by       uuid NOT NULL REFERENCES auth.users (id),
    instructions     text NOT NULL DEFAULT '',
    agent_session_id text,
    progress_note    text NOT NULL DEFAULT '',
    issues_created   integer NOT NULL DEFAULT 0 CHECK (issues_created >= 0),
    summary          text NOT NULL DEFAULT '',
    error            text NOT NULL DEFAULT '',
    lease_owner      text,
    lease_expires_at timestamptz,
    created_at       timestamptz NOT NULL DEFAULT now(),
    started_at       timestamptz,
    finished_at      timestamptz,

    -- A run cancelled while queued never started.
    CONSTRAINT review_runs_started_at_matches_status
        CHECK (status = 'cancelled' OR (status = 'queued') = (started_at IS NULL)),
    CONSTRAINT review_runs_finished_at_matches_status
        CHECK ((status IN ('succeeded', 'failed', 'cancelled')) = (finished_at IS NOT NULL)),
    CONSTRAINT review_runs_failed_has_error
        CHECK (status <> 'failed' OR error <> '')
);

-- At most one active run per pack.
CREATE UNIQUE INDEX review_runs_one_active_per_pack
    ON review_runs (pack_id) WHERE status IN ('queued', 'running');

CREATE INDEX review_runs_pack_id_created_at_idx ON review_runs (pack_id, created_at DESC);

-- The worker's claim query.
CREATE INDEX review_runs_claimable_idx
    ON review_runs (created_at) WHERE status IN ('queued', 'running');

CREATE TRIGGER review_runs_notify
    AFTER INSERT OR UPDATE ON review_runs
    FOR EACH ROW EXECUTE FUNCTION notify_pack_activity();

-- Issues -----------------------------------------------------------------------

CREATE TYPE issue_status AS ENUM ('open', 'closed');
CREATE TYPE issue_severity AS ENUM ('critical', 'major', 'minor');

-- Current state only. Who created or changed an issue, and when, is in
-- issue_events: created_* from version 1, updated_* from the current version.
CREATE TABLE issues (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    pack_id           uuid NOT NULL REFERENCES packs (id),
    document_id       uuid NOT NULL,
    version           integer NOT NULL DEFAULT 1 CHECK (version >= 1),
    status            issue_status NOT NULL DEFAULT 'open',
    severity          issue_severity NOT NULL,
    title             text NOT NULL CHECK (title <> ''),
    description       text NOT NULL DEFAULT '',
    -- The QCS 2014 clause the issue breaks (issue.v1.SpecReference).
    spec_section      text NOT NULL CHECK (spec_section <> ''),
    spec_part         text NOT NULL CHECK (spec_part <> ''),
    spec_clause       text NOT NULL CHECK (spec_clause <> ''),
    spec_clause_title text NOT NULL DEFAULT '',
    spec_pdf_page     integer CHECK (spec_pdf_page > 0),
    evidence          text NOT NULL DEFAULT '',
    metadata          jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(metadata) = 'object'),

    -- The document must belong to the same pack.
    FOREIGN KEY (document_id, pack_id) REFERENCES documents (id, pack_id),
    -- Target for the composite foreign key from issue_events.
    UNIQUE (id, pack_id)
);

CREATE INDEX issues_pack_id_idx ON issues (pack_id);
CREATE INDEX issues_document_id_idx ON issues (document_id);
-- Open issue counts per pack (Pack.open_issue_count, auto-resolve).
CREATE INDEX issues_open_by_pack_idx ON issues (pack_id) WHERE status = 'open';

-- Issues are never deleted, never move between packs or documents, and every
-- update bumps version by exactly one.
-- +goose StatementBegin
CREATE FUNCTION issues_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'issues cannot be deleted' USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.pack_id <> OLD.pack_id OR NEW.document_id <> OLD.document_id THEN
        RAISE EXCEPTION 'issue % cannot move to another pack or document', OLD.id
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.version <> OLD.version + 1 THEN
        RAISE EXCEPTION 'issue % update must set version to %, got %', OLD.id, OLD.version + 1, NEW.version
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;
-- +goose StatementEnd

CREATE TRIGGER issues_guard
    BEFORE UPDATE OR DELETE ON issues
    FOR EACH ROW EXECUTE FUNCTION issues_guard();

-- Issue events -----------------------------------------------------------------

CREATE TYPE issue_event_kind AS ENUM ('created', 'updated');

-- Append-only record of who changed what. One row per issue version.
-- changes is a JSON array of {"field": "status", "old": ..., "new": ...},
-- with field names as in issue.v1.Issue; "old" is null on 'created'.
CREATE TABLE issue_events (
    seq        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    issue_id   uuid NOT NULL,
    pack_id    uuid NOT NULL,
    version    integer NOT NULL CHECK (version >= 1),
    kind       issue_event_kind NOT NULL,
    actor_id   uuid NOT NULL REFERENCES auth.users (id),
    -- Set when the agent made the change during a review run.
    run_id     uuid REFERENCES review_runs (id),
    note       text NOT NULL DEFAULT '',
    changes    jsonb NOT NULL CHECK (jsonb_typeof(changes) = 'array'),
    created_at timestamptz NOT NULL DEFAULT now(),

    FOREIGN KEY (issue_id, pack_id) REFERENCES issues (id, pack_id),
    UNIQUE (issue_id, version),
    CONSTRAINT issue_events_created_is_version_1
        CHECK ((kind = 'created') = (version = 1))
);

-- WatchPack replay: events of one pack after a cursor.
CREATE INDEX issue_events_pack_id_seq_idx ON issue_events (pack_id, seq);

-- +goose StatementBegin
CREATE FUNCTION forbid_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% is append-only', TG_TABLE_NAME USING ERRCODE = 'check_violation';
END
$$;
-- +goose StatementEnd

CREATE TRIGGER issue_events_append_only
    BEFORE UPDATE OR DELETE ON issue_events
    FOR EACH ROW EXECUTE FUNCTION forbid_change();

CREATE TRIGGER issue_events_no_truncate
    BEFORE TRUNCATE ON issue_events
    FOR EACH STATEMENT EXECUTE FUNCTION forbid_change();

CREATE TRIGGER issue_events_notify
    AFTER INSERT ON issue_events
    FOR EACH ROW EXECUTE FUNCTION notify_pack_activity();

-- No issue write without its event: at commit, every inserted or updated
-- issue row must have the event for its current version.
-- +goose StatementBegin
CREATE FUNCTION issues_require_event() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM issue_events WHERE issue_id = NEW.id AND version = NEW.version
    ) THEN
        RAISE EXCEPTION 'issue % version % has no issue_events row', NEW.id, NEW.version
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END
$$;
-- +goose StatementEnd

CREATE CONSTRAINT TRIGGER issues_require_event
    AFTER INSERT OR UPDATE ON issues
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION issues_require_event();

-- +goose Down

DROP TABLE issue_events;
DROP TABLE issues;
DROP TABLE review_runs;
DROP TABLE documents;
DROP TABLE packs;

DROP FUNCTION issues_require_event();
DROP FUNCTION forbid_change();
DROP FUNCTION issues_guard();
DROP FUNCTION packs_guard_final();
DROP FUNCTION notify_pack_activity();

DROP TYPE issue_event_kind;
DROP TYPE issue_severity;
DROP TYPE issue_status;
DROP TYPE review_run_status;
DROP TYPE document_status;
DROP TYPE pack_status;

DROP TRIGGER users_set_updated_at ON auth.users;
DROP FUNCTION set_updated_at();

DELETE FROM auth.users WHERE kind = 'agent';
ALTER TABLE auth.users
    DROP CONSTRAINT users_human_has_credentials,
    ALTER COLUMN email SET NOT NULL,
    ALTER COLUMN password_hash SET NOT NULL,
    DROP COLUMN kind;
DROP TYPE auth.user_kind;
