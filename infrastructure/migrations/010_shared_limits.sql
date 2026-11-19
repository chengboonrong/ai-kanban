-- State every API process shares (issue #25): fixed-window rate limits and the GitHub rate-limit pause.
CREATE TABLE rate_limits (
  limiter text NOT NULL,
  key text NOT NULL,
  count integer NOT NULL,
  reset_at timestamptz NOT NULL,
  PRIMARY KEY (limiter, key)
);
CREATE INDEX rate_limits_reset_at ON rate_limits (reset_at);

-- One row: no GitHub request from the app until `until`.
CREATE TABLE github_pause (
  id boolean PRIMARY KEY DEFAULT true CHECK (id),
  until timestamptz NOT NULL
);
INSERT INTO github_pause (until) VALUES (now());
