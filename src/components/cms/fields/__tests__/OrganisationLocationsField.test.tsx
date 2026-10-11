/** @vitest-environment jsdom */
import { useState } from 'react';
import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { FieldProps } from '../FieldRenderer';
const { propsByName } = vi.hoisted(() => ({ propsByName: new Map<string, FieldProps>() }));
vi.mock('@/components/cms/EntityAuditHistory', () => ({ EntityAuditHistory: () => null }));
vi.mock('../FieldRenderer', () => ({
  FieldRenderer: (props: FieldProps) => {
    propsByName.set(props.field.name, props);
    return (
      <input
        aria-label={props.field.name}
        value={String(props.value ?? '')}
        onChange={(event) => props.onChange(event.target.value)}
      />
    );
  },
}));
import { OrganisationLocationsField } from '../OrganisationLocationsField';

const location = {
  id: 'branch-1',
  name: 'Original name',
  address: 'Original address',
  city: 'Zurich',
  country: 'CH',
  category: 'bar',
};
function Harness({ initial = [location] }: { initial?: Record<string, unknown>[] }) {
  const [value, setValue] = useState(initial);
  return (
    <OrganisationLocationsField
      field={{
        name: '_locations',
        label: 'Locations',
        type: 'organisation_locations',
        group: 'location',
      }}
      value={value}
      onChange={(next) => setValue(next as Record<string, unknown>[])}
      allValues={{ _focused_location_id: 'branch-1' }}
    />
  );
}

describe('location field updates', () => {
  beforeEach(() => {
    propsByName.clear();
  });
  it('merges a delayed address lookup into current edits', async () => {
    render(<Harness />);
    await screen.findByLabelText('location-0-address');
    const delayed = propsByName.get('location-0-address')!.setFields!;
    fireEvent.change(screen.getByLabelText('location-0-name'), {
      target: { value: 'Edited name' },
    });
    await act(async () => {
      delayed({ address: 'Resolved address', city_id: 'resolved-city' });
    });
    expect(screen.getByLabelText('location-0-name')).toHaveValue('Edited name');
    expect(screen.getByLabelText('location-0-address')).toHaveValue('Resolved address');
  });
  it('does not apply a removed draft row lookup to another row', async () => {
    render(<Harness initial={[]} />);
    fireEvent.click(screen.getByRole('button', { name: 'Add location' }));
    await screen.findByLabelText('location-0-address');
    const delayed = propsByName.get('location-0-address')!.setFields!;
    fireEvent.click(screen.getByRole('button', { name: 'Add location' }));
    await screen.findByLabelText('location-1-address');
    fireEvent.click(screen.getAllByRole('button', { name: 'Discard new location' })[0]);
    await waitFor(() =>
      expect(screen.queryByLabelText('location-1-address')).not.toBeInTheDocument(),
    );
    await act(async () => {
      delayed({ address: 'Discarded lookup' });
    });
    expect(screen.getByLabelText('location-0-address')).toHaveValue('');
  });
});
