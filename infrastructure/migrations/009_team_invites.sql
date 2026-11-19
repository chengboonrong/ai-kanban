-- Team invites (issue #16): an admin role between owner and member, the verified GitHub addresses an invite is checked
-- against, and invites by email. Only a token's hash is stored, as for sessions.
ALTER TABLE workspace_members DROP CONSTRAINT workspace_members_role_check;
ALTER TABLE workspace_members ADD CONSTRAINT workspace_members_role_check CHECK (role IN ('owner', 'admin', 'member'));

-- Lowercased; replaced on every GitHub sign-in. Dev accounts have none.
CREATE TABLE user_emails (
  user_id uuid REFERENCES users(id) ON DELETE CASCADE,
  email text NOT NULL,
  PRIMARY KEY (user_id, email)
);

CREATE TABLE workspace_invites (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  email text NOT NULL,
  token_hash bytea NOT NULL UNIQUE,
  invited_by uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  accepted_by uuid REFERENCES users(id) ON DELETE SET NULL,
  accepted_at timestamptz,
  revoked_at timestamptz
);
-- One pending invite per address (expired ones included): inviting the address again resends it.
CREATE UNIQUE INDEX ON workspace_invites (workspace_id, email) WHERE accepted_at IS NULL AND revoked_at IS NULL;
