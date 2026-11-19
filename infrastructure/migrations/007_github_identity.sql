-- The GitHub account a user signed in with (AUTH_MODE=github). NULL for dev accounts; the first GitHub sign-in with the
-- same login adopts one. No GitHub token is stored.
ALTER TABLE users ADD COLUMN github_id bigint UNIQUE;
