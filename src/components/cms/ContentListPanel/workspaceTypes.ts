import type { ReactNode } from 'react';
import type { ContentTypeConfig } from '@/types/cms';
export interface WorkspaceAction {
  label: string;
  run: () => void | Promise<void>;
  destructive?: boolean;
  disabled?: boolean;
}
export interface ListSource {
  rows: Record<string, unknown>[];
  loading: boolean;
  error?: string | null;
  refresh: () => void;
}
export interface WorkspaceListOptions {
  configOverride?: ContentTypeConfig;
  source?: ListSource;
  workspace?: boolean;
  operational?: boolean;
  onEditRow?: (row: Record<string, unknown>) => void;
  rowActions?: (row: Record<string, unknown>, refresh: () => void) => WorkspaceAction[];
  tools?: ReactNode;
  refreshKey?: number;
  selectionTools?: (rows: Record<string, unknown>[], refresh: () => void) => ReactNode;
}
