import { useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { Button } from '@/components/ui/button';
import { Label } from '@/components/ui/label';

type Permission = 'none' | 'view' | 'edit' | 'owner';
interface Access {
  folderId: string;
  defaultPermission: Exclude<Permission, 'owner'>;
  members: {
    id: string;
    label: string;
    kind: string;
    role: string;
    active: boolean;
    permission: Permission | null;
  }[];
}
async function request(folderId: string, body?: unknown): Promise<Access> {
  const { data, error } = await supabase.functions.invoke(
    `redirect-api/folders/${folderId}/access`,
    {
      method: body ? 'PATCH' : 'GET',
      ...(body ? { body } : {}),
    },
  );
  if (error || data?.error)
    throw new Error(data?.error ?? error?.message ?? 'Could not load folder access');
  return data;
}
export function RedirectFolderAccess({
  folderId,
  onClose,
  principalId,
}: {
  principalId?: string;
  folderId: string;
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const query = useQuery({
    queryKey: ['redirect-folder-access', folderId, principalId ?? 'admin'],
    queryFn: () => request(folderId),
  });
  const [draft, setDraft] = useState<Record<string, Permission | ''>>({});
  const [defaultPermission, setDefaultPermission] = useState<Access['defaultPermission'] | null>(
    null,
  );
  const save = useMutation({
    mutationFn: () =>
      request(folderId, {
        ...(defaultPermission ? { defaultPermission } : {}),
        overrides: Object.entries(draft).map(([memberId, permission]) => ({
          memberId,
          permission: permission || null,
        })),
      }),
    onSuccess: async () => {
      setDraft({});
      setDefaultPermission(null);
      await queryClient.invalidateQueries({
        queryKey: ['redirect-folder-access', folderId, principalId ?? 'admin'],
      });
      await queryClient.invalidateQueries({ queryKey: ['redirect-link-workspace'] });
    },
  });
  return (
    <section aria-label="Folder access" className="space-y-4 rounded-container border p-4">
      <div className="flex items-center justify-between gap-2">
        <h3 className="font-semibold">Folder access</h3>
        <Button variant="ghost" size="sm" onClick={onClose}>
          Close access
        </Button>
      </div>
      <p className="text-sm text-muted-foreground">
        Workspace administrators always have full access. Viewer memberships can never edit, even
        with an owner override.
      </p>
      {query.isPending && <p role="status">Loading folder access…</p>}
      {query.isError && (
        <p role="alert">
          {query.error.message}{' '}
          <Button variant="outline" size="sm" onClick={() => void query.refetch()}>
            Retry
          </Button>
        </p>
      )}
      {query.data && (
        <>
          <div className="space-y-2">
            <Label htmlFor="folder-default-access">Default for workspace members</Label>
            <select
              id="folder-default-access"
              className="block rounded-element border bg-background p-2"
              disabled={save.isPending}
              value={defaultPermission ?? query.data.defaultPermission}
              onChange={(e) => setDefaultPermission(e.target.value as Access['defaultPermission'])}
            >
              <option value="edit">Can edit</option>
              <option value="view">Can view</option>
              <option value="none">No access</option>
            </select>
          </div>
          <ul className="divide-y">
            {query.data.members.map((member) => (
              <li
                key={member.id}
                className="flex flex-wrap items-center justify-between gap-2 py-4"
              >
                <div>
                  <Label htmlFor={`access-${member.id}`}>{member.label}</Label>
                  <p className="text-xs text-muted-foreground">
                    {member.kind === 'machine' ? 'Machine' : 'Account'} · {member.role}
                    {!member.active ? ' · Inactive' : ''}
                  </p>
                </div>
                <select
                  id={`access-${member.id}`}
                  className="rounded-element border bg-background p-2 text-sm"
                  disabled={save.isPending}
                  value={draft[member.id] ?? member.permission ?? ''}
                  onChange={(e) =>
                    setDraft({ ...draft, [member.id]: e.target.value as Permission | '' })
                  }
                >
                  <option value="">Use folder default</option>
                  <option value="none">No access</option>
                  <option value="view">Can view</option>
                  <option value="edit">Can edit</option>
                  <option value="owner">Owner</option>
                </select>
              </li>
            ))}
          </ul>
          {!query.data.members.length && (
            <p className="text-sm text-muted-foreground">
              Add workspace members to assign individual access.
            </p>
          )}
          {save.isError && (
            <p role="alert" className="text-destructive">
              {save.error.message}
            </p>
          )}
          {save.isSuccess && !Object.keys(draft).length && !defaultPermission && (
            <p role="status">Access saved.</p>
          )}
          <Button
            disabled={save.isPending || (!Object.keys(draft).length && !defaultPermission)}
            onClick={() => save.mutate()}
          >
            {save.isPending ? 'Saving…' : 'Save access'}
          </Button>
        </>
      )}
    </section>
  );
}
