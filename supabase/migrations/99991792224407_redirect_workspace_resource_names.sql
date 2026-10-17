-- Names belong to a workspace. Preserve existing trim/case normalization and
-- duplicate protection within that workspace; no resource or tenant is moved.
DROP INDEX public.redirect_link_folders_name_unique;
CREATE UNIQUE INDEX redirect_link_folders_name_unique ON public.redirect_link_folders(workspace_id,lower(btrim(name)));
DROP INDEX public.redirect_link_tags_name_unique;
CREATE UNIQUE INDEX redirect_link_tags_name_unique ON public.redirect_link_tags(workspace_id,lower(btrim(name)));
DROP INDEX public.redirect_utm_templates_name_unique;
CREATE UNIQUE INDEX redirect_utm_templates_name_unique ON public.redirect_utm_templates(workspace_id,lower(btrim(name)));
