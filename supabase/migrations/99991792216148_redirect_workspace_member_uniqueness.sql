-- One account may participate in independent workspaces. Keep one human
-- membership per workspace; machine identities retain nullable user_id behavior.
-- Selection/authorization and pending tenant activation fences remain unchanged.
ALTER TABLE public.redirect_workspace_members
 DROP CONSTRAINT redirect_workspace_members_user_id_key,
 ADD CONSTRAINT redirect_workspace_members_user_id_key UNIQUE(workspace_id,user_id);
