import React from 'react';
import { useLocation } from 'react-router';
import { stripLocale } from '@/lib/locale';
import { isRouteMotionAllowed } from './routeJourney';

/** Quiet content arrival only. Loading UI reflects actual pending work;
 * navigation never draws a timed, route-coloured full-screen overlay. */
export const RouteFade = ({ children }: { children: React.ReactNode }) => {
  const location = useLocation();
  const segmentKey = stripLocale(location.pathname).split('/').slice(0, 3).join('/') || 'root';
  return (
    <div
      key={segmentKey}
      className={isRouteMotionAllowed(location.pathname) ? 'station-arrive' : undefined}
      style={{ minHeight: '100%' }}
    >
      {children}
    </div>
  );
};
