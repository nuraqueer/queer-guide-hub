-- The designer's existing UPDATE grant was blocked by the missing RLS policy.
-- Match the existing admin-only SELECT boundary; grant no INSERT/DELETE access.
CREATE POLICY email_templates_admin_update
ON public.email_templates
FOR UPDATE TO authenticated
USING (public.has_role_jwt('admin'::public.app_role))
WITH CHECK (public.has_role_jwt('admin'::public.app_role));
