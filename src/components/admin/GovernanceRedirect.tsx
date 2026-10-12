import { Navigate, useLocation } from 'react-router';
import type { GovernanceMode } from '@/pages/admin/AdminGovernance';

/** Keep legacy links working while selecting their canonical Governance mode. */
export function GovernanceRedirect({ mode }: { mode: GovernanceMode }) {
  const location = useLocation();
  const params = new URLSearchParams(location.search);
  params.set('mode', mode);
  return (
    <Navigate
      to={{ pathname: '/admin/governance', search: `?${params}`, hash: location.hash }}
      replace
    />
  );
}
