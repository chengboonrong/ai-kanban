-- GitHub "owner/name". Workers map it to a local checkout; the board never stores a machine path.
ALTER TABLE boards ADD COLUMN repository text CHECK (repository ~ '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$');
-- Whose worker reads it: connecting a repository shares your checkout of it with the board, and nobody else's.
ALTER TABLE boards ADD COLUMN repository_connected_by uuid REFERENCES users(id) ON DELETE SET NULL;

CREATE TABLE workers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name text NOT NULL CHECK (length(name) BETWEEN 1 AND 100),
  token_hash bytea NOT NULL UNIQUE,
  repositories text[] NOT NULL DEFAULT '{}', -- what it last said it can read
  last_seen_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE agent_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id uuid NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  requested_by uuid NOT NULL REFERENCES users(id),
  repository text NOT NULL,
  state text NOT NULL DEFAULT 'queued' CHECK (state IN ('queued', 'running', 'succeeded', 'failed', 'cancelled')),
  execution_target text NOT NULL DEFAULT 'local',
  worker_id uuid REFERENCES workers(id) ON DELETE SET NULL,
  harness text NOT NULL DEFAULT 'opencode',
  model text,
  session_id text,
  repository_commit_sha text,
  token_usage jsonb,
  cost numeric,
  error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  started_at timestamptz,
  completed_at timestamptz
);
-- At most one active run per task, so retries and double-clicks can't queue duplicates.
CREATE UNIQUE INDEX ON agent_runs (task_id) WHERE state IN ('queued', 'running');
CREATE INDEX ON agent_runs (created_at) WHERE state = 'queued';
CREATE INDEX ON agent_runs (task_id, created_at);
CREATE INDEX ON agent_runs (worker_id) WHERE worker_id IS NOT NULL;

CREATE TABLE run_events (
  id bigserial PRIMARY KEY,
  run_id uuid NOT NULL REFERENCES agent_runs(id) ON DELETE CASCADE,
  kind text NOT NULL,
  data jsonb NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON run_events (run_id, id);

CREATE TABLE specs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id uuid NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  run_id uuid NOT NULL UNIQUE REFERENCES agent_runs(id) ON DELETE CASCADE, -- one spec per run: a repeated completion can't add a version
  version int NOT NULL,
  content jsonb NOT NULL,
  repository_commit_sha text,
  approved_by uuid REFERENCES users(id),
  approved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (task_id, version)
);
