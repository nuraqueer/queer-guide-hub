import type { ReactNode } from 'react';

export function HubModuleHeader({
  title,
  description,
  action,
}: {
  title: string;
  description: string;
  action?: ReactNode;
}) {
  return (
    <header className="flex flex-col gap-2 border-b border-border-hairline pb-4 sm:flex-row sm:items-end sm:justify-between">
      <div className="min-w-0">
        <h1 className="text-headline font-display text-balance">{title}</h1>
        <p className="mt-1 max-w-[65ch] text-sm text-muted-foreground text-pretty">{description}</p>
      </div>
      {action && <div className="shrink-0">{action}</div>}
    </header>
  );
}
