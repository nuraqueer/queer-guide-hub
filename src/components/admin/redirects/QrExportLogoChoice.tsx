import { Button } from '@/components/ui/button';
export function QrExportLogoChoice({
  mode,
  hide,
  saved,
  disabled = false,
}: {
  mode: 'saved' | 'custom' | 'none';
  hide: () => void;
  saved: () => void;
  disabled?: boolean;
}) {
  return (
    <div className="space-y-2 text-sm">
      <label className="flex items-center gap-2">
        <input
          type="checkbox"
          checked={mode === 'none'}
          disabled={disabled}
          onChange={(event) => (event.target.checked ? hide() : saved())}
        />
        Hide logos for this export
      </label>
      {mode !== 'saved' && (
        <Button variant="ghost" size="sm" disabled={disabled} onClick={saved}>
          Use saved logo
        </Button>
      )}
      <p className="text-xs text-muted-foreground">
        {mode === 'saved'
          ? 'Each code uses its saved domain or workspace logo.'
          : mode === 'custom'
            ? 'Your uploaded logo applies to this export.'
            : 'This export has no logo.'}
      </p>
    </div>
  );
}
