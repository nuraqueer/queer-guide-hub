import { ContentListPanel } from '@/components/cms/ContentListPanel';
import { PersonhoodApprovalInfo } from '@/components/admin/PersonhoodApprovalInfo';

/**
 * Personalities admin surface: approval guidance above the standard CMS list.
 * The generic ContentListPanel is reused untouched via contentTypeId, so all
 * list/edit/bulk behaviour stays identical for personalities.
 *
 * Deep-link support: `?edit=<id>` opens the editor for that personality on
 * mount and strips the param (so refresh/back doesn't reopen). Lets the
 * read-only person-db companion tool hand a row off to the real admin editor
 * without embedding any auth of its own. That handling now lives in
 * ContentListPanel, which this page renders, so every registry type gets it
 * and `cmsEditPath` can build the link for any of them.
 */
export default function PersonalitiesAdmin() {
  return (
    /* gap-4, not px-4 pt-4 wrappers: AdminShell's <main> already owns the
       horizontal gutter, so the old wrappers double-padded the guidance panel
       against the list below them. */
    <div className="flex flex-col gap-4">
      <PersonhoodApprovalInfo />
      <ContentListPanel contentTypeId="personalities" />
    </div>
  );
}
