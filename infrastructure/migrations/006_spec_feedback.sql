-- What a reviewer said about the spec version a run revises: {specVersion, general?, items?: [{section, index, comment}]}.
-- NULL for a plain refinement. A retry carries it over, so the next attempt still answers the same comments.
ALTER TABLE agent_runs ADD COLUMN feedback jsonb;
