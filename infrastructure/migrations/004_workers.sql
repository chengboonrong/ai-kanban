-- A running run holds a lease its worker renews with every event batch; the sweeper fails a lapsed one and retries it.
ALTER TABLE agent_runs
  ADD COLUMN lease_until timestamptz,
  ADD COLUMN attempt int NOT NULL DEFAULT 1,
  ADD COLUMN retry_reason text,
  -- NOT VALID: checks new writes only; development databases may hold older experimental values.
  ADD CHECK (harness IN ('opencode', 'claude-code')) NOT VALID;
UPDATE agent_runs SET lease_until = now() + interval '90 seconds' WHERE state = 'running';
CREATE INDEX ON agent_runs (lease_until) WHERE state = 'running';

-- One-time codes the app shows and `connect` trades for a worker token; only the hash is stored.
CREATE TABLE worker_pairings (
  code_hash bytea PRIMARY KEY,
  owner_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  expires_at timestamptz NOT NULL,
  used_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
