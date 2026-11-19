-- 'imported': the card was made from an issue someone opened on GitHub. GitHub owns that issue's title and body, so
-- approving the card's spec comments on it (github_comments) instead of filing an issue.
ALTER TABLE github_issues ADD COLUMN origin text NOT NULL DEFAULT 'filed' CHECK (origin IN ('filed', 'imported'));

-- The one spec comment on an imported task's issue, queued and leased like github_issues. A newer approved version
-- edits the same comment (comment_id) rather than adding another.
CREATE TABLE github_comments (
  task_id uuid PRIMARY KEY REFERENCES tasks(id) ON DELETE CASCADE,
  version int NOT NULL, -- the approved spec version the comment shows (or is about to)
  state text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'posting', 'posted', 'failed')),
  comment_id bigint,
  url text,
  attempts int NOT NULL DEFAULT 0,
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  locked_until timestamptz,
  last_error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON github_comments (next_attempt_at) WHERE state IN ('pending', 'posting');
