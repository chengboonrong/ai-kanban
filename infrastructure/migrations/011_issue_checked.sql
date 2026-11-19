-- The reconciliation sweep reads a bounded number of tracked issues per repository directly, to learn of deleted or
-- transferred ones that no longer appear in the listing; the least recently checked go first.
ALTER TABLE github_issues ADD COLUMN checked_at timestamptz;
