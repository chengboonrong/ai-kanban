-- One GitHub issue per task, created from its approved spec. Postgres is the queue: a row is claimed with a lease
-- (locked_until) committed on its own, so no transaction is ever open across a call to GitHub.
CREATE TABLE github_issues (
  task_id uuid PRIMARY KEY REFERENCES tasks(id) ON DELETE CASCADE,
  repository text NOT NULL, -- lowercase "owner/name", the repository the spec was refined against
  repository_id bigint,
  state text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'creating', 'created', 'failed')),
  number int,
  node_id text,
  url text,
  issue_state text CHECK (issue_state IN ('open', 'closed')),
  issue_updated_at timestamptz, -- of the last issue event applied, so an older one arriving late is ignored
  attempts int NOT NULL DEFAULT 0,
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  locked_until timestamptz,
  last_error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (repository_id, number)
);
CREATE INDEX ON github_issues (next_attempt_at) WHERE state IN ('pending', 'creating');

-- Webhook deliveries already processed, so GitHub's redeliveries and retries are no-ops.
CREATE TABLE github_deliveries (
  id text PRIMARY KEY,
  event text NOT NULL,
  received_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON github_deliveries (received_at);

-- Webhooks only mark a PR dirty (dirty_seq); the sync loop reads its current state from GitHub and records the
-- dirty_seq it saw as synced_seq, so a webhook arriving mid-read leaves it dirty for the next pass.
CREATE TABLE pull_requests (
  id bigserial PRIMARY KEY,
  repository_id bigint NOT NULL,
  repository text NOT NULL,
  number int NOT NULL,
  title text NOT NULL DEFAULT '',
  url text NOT NULL,
  author text,
  state text NOT NULL DEFAULT 'open' CHECK (state IN ('open', 'closed', 'merged')),
  draft boolean NOT NULL DEFAULT false,
  head_sha text,
  head_ref text,
  review text NOT NULL DEFAULT 'none' CHECK (review IN ('approved', 'changes_requested', 'review_required', 'none')),
  ci text NOT NULL DEFAULT 'none' CHECK (ci IN ('success', 'failure', 'pending', 'none')),
  github_updated_at timestamptz,
  dirty_seq bigint NOT NULL DEFAULT 1,
  synced_seq bigint NOT NULL DEFAULT 0,
  locked_until timestamptz,
  UNIQUE (repository_id, number)
);
CREATE INDEX ON pull_requests (repository_id, head_sha);
CREATE INDEX ON pull_requests (id) WHERE dirty_seq > synced_seq;

CREATE TABLE pull_request_tasks (
  pull_request_id bigint NOT NULL REFERENCES pull_requests(id) ON DELETE CASCADE,
  task_id uuid NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  PRIMARY KEY (pull_request_id, task_id)
);
CREATE INDEX ON pull_request_tasks (task_id);
