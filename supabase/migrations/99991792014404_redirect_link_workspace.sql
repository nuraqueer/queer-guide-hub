CREATE TABLE public.redirect_link_folders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 100),
  description text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX redirect_link_folders_name_unique ON public.redirect_link_folders (lower(btrim(name)));

CREATE TABLE public.redirect_link_tags (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 100),
  color text NOT NULL DEFAULT 'gray' CHECK (color IN ('gray','red','orange','yellow','green','blue','purple','pink')),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX redirect_link_tags_name_unique ON public.redirect_link_tags (lower(btrim(name)));

CREATE TABLE public.redirect_utm_templates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 100),
  parameters jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (jsonb_typeof(parameters) = 'object'),
  CHECK (NOT jsonb_path_exists(parameters, '$.* ? (@.type() != "string")')),
  CHECK (parameters - ARRAY['utm_source','utm_medium','utm_campaign','utm_term','utm_content','ref']::text[] = '{}'::jsonb)
);
CREATE UNIQUE INDEX redirect_utm_templates_name_unique ON public.redirect_utm_templates (lower(btrim(name)));

-- Keys identify inventory records across every source; avoid duplicating the
-- automatic redirect tables or editing their routing behavior.
CREATE TABLE public.redirect_link_metadata (
  redirect_key text PRIMARY KEY CHECK (length(redirect_key) BETWEEN 1 AND 4096),
  folder_id uuid REFERENCES public.redirect_link_folders(id) ON DELETE SET NULL,
  comment text NOT NULL DEFAULT '' CHECK (length(comment) <= 10000),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX redirect_link_metadata_folder_idx ON public.redirect_link_metadata(folder_id);

CREATE TABLE public.redirect_link_tag_assignments (
  redirect_key text NOT NULL REFERENCES public.redirect_link_metadata(redirect_key) ON DELETE CASCADE,
  tag_id uuid NOT NULL REFERENCES public.redirect_link_tags(id) ON DELETE CASCADE,
  PRIMARY KEY (redirect_key, tag_id)
);
CREATE INDEX redirect_link_tag_assignments_tag_idx ON public.redirect_link_tag_assignments(tag_id);

ALTER TABLE public.redirect_link_folders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.redirect_link_tags ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.redirect_utm_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.redirect_link_metadata ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.redirect_link_tag_assignments ENABLE ROW LEVEL SECURITY;

CREATE POLICY redirect_link_folders_admin ON public.redirect_link_folders TO authenticated
  USING ((SELECT public.has_role_jwt('admin'::public.app_role)))
  WITH CHECK ((SELECT public.has_role_jwt('admin'::public.app_role)));
CREATE POLICY redirect_link_tags_admin ON public.redirect_link_tags TO authenticated
  USING ((SELECT public.has_role_jwt('admin'::public.app_role)))
  WITH CHECK ((SELECT public.has_role_jwt('admin'::public.app_role)));
CREATE POLICY redirect_utm_templates_admin ON public.redirect_utm_templates TO authenticated
  USING ((SELECT public.has_role_jwt('admin'::public.app_role)))
  WITH CHECK ((SELECT public.has_role_jwt('admin'::public.app_role)));
CREATE POLICY redirect_link_metadata_admin ON public.redirect_link_metadata TO authenticated
  USING ((SELECT public.has_role_jwt('admin'::public.app_role)))
  WITH CHECK ((SELECT public.has_role_jwt('admin'::public.app_role)));
CREATE POLICY redirect_link_tag_assignments_admin ON public.redirect_link_tag_assignments TO authenticated
  USING ((SELECT public.has_role_jwt('admin'::public.app_role)))
  WITH CHECK ((SELECT public.has_role_jwt('admin'::public.app_role)));

REVOKE ALL ON public.redirect_link_folders, public.redirect_link_tags, public.redirect_utm_templates,
  public.redirect_link_metadata, public.redirect_link_tag_assignments FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.redirect_link_folders, public.redirect_link_tags,
  public.redirect_utm_templates, public.redirect_link_metadata, public.redirect_link_tag_assignments TO authenticated;
GRANT ALL ON public.redirect_link_folders, public.redirect_link_tags, public.redirect_utm_templates,
  public.redirect_link_metadata, public.redirect_link_tag_assignments TO service_role;

CREATE FUNCTION public.set_redirect_link_metadata(p_redirect_key text, p_folder_id uuid, p_tag_ids uuid[], p_comment text)
RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
BEGIN
  IF NOT public.has_role_jwt('admin'::public.app_role) THEN RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501'; END IF;
  IF EXISTS (SELECT 1 FROM unnest(p_tag_ids) t WHERE NOT EXISTS (SELECT FROM public.redirect_link_tags WHERE id = t)) THEN
    RAISE EXCEPTION 'Unknown tag' USING ERRCODE = '23503';
  END IF;
  INSERT INTO public.redirect_link_metadata(redirect_key, folder_id, comment)
  VALUES (p_redirect_key, p_folder_id, coalesce(p_comment,''))
  ON CONFLICT (redirect_key) DO UPDATE SET folder_id=excluded.folder_id, comment=excluded.comment, updated_at=now();
  DELETE FROM public.redirect_link_tag_assignments WHERE redirect_key=p_redirect_key;
  INSERT INTO public.redirect_link_tag_assignments(redirect_key,tag_id)
  SELECT p_redirect_key, t FROM (SELECT DISTINCT unnest(coalesce(p_tag_ids,ARRAY[]::uuid[])) AS t) tags;
END $$;
REVOKE ALL ON FUNCTION public.set_redirect_link_metadata(text,uuid,uuid[],text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_redirect_link_metadata(text,uuid,uuid[],text) TO authenticated;

CREATE FUNCTION public.create_redirect_campaign_link(p_slug text, p_target text, p_folder_id uuid DEFAULT NULL, p_tag_ids uuid[] DEFAULT ARRAY[]::uuid[])
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE saved public.redirects;
BEGIN
  IF NOT public.has_role_jwt('admin'::public.app_role) THEN RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501'; END IF;
  IF lower(btrim(p_slug)) !~ '^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$' OR length(p_target) NOT BETWEEN 1 AND 8192 THEN
    RAISE EXCEPTION 'Invalid short link';
  END IF;
  INSERT INTO public.redirects(type,slug,target,match_kind,status_code,is_enabled,query_mode,preserve_query,created_by)
  VALUES ('SHORT',lower(btrim(p_slug)),p_target,'EXACT',302,true,'PRESERVE',true,auth.uid()) RETURNING * INTO saved;
  PERFORM public.set_redirect_link_metadata('redirects:' || saved.id::text, p_folder_id, p_tag_ids, '');
  RETURN to_jsonb(saved);
END $$;
REVOKE ALL ON FUNCTION public.create_redirect_campaign_link(text,text,uuid,uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_redirect_campaign_link(text,text,uuid,uuid[]) TO authenticated;
