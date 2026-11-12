-- Emails are compared case-insensitively: Alice@Example.com and alice@example.com are one account.
-- The service lowercases on write and on lookup; this migration lowercases existing rows and makes the
-- database enforce both halves, so a write that skipped the service cannot reintroduce a duplicate.

-- +goose Up
UPDATE auth.users SET email = lower(email) WHERE email <> lower(email);

ALTER TABLE auth.users DROP CONSTRAINT users_email_key;
CREATE UNIQUE INDEX users_email_lower_key ON auth.users (lower(email));
ALTER TABLE auth.users ADD CONSTRAINT users_email_lowercase CHECK (email = lower(email));

-- +goose Down
ALTER TABLE auth.users DROP CONSTRAINT users_email_lowercase;
DROP INDEX auth.users_email_lower_key;
ALTER TABLE auth.users ADD CONSTRAINT users_email_key UNIQUE (email);
