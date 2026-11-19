-- GitHub doesn't retry webhooks: each repository with a filed or imported issue is swept periodically for what changed
-- while none arrived. Claimed with a lease (locked_until) committed on its own, like the other jobs.
CREATE TABLE github_repositories (
  repository_id bigint PRIMARY KEY,
  repository text NOT NULL,
  swept_until timestamptz, -- when the last sweep that succeeded started; the next lists what changed since (with overlap)
  next_sweep_at timestamptz NOT NULL DEFAULT now(),
  locked_until timestamptz,
  last_error text
);
