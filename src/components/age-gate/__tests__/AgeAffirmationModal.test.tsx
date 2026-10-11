/**
 * @vitest-environment jsdom
 */
import { describe, it, expect, vi } from 'vitest';
import { render } from '@testing-library/react';

vi.mock('react-i18next', () => ({ useTranslation: () => ({ t: (k: string) => k }) }));
let checking = false;
vi.mock('@/hooks/useAgeAffirmation', () => ({
  useAgeAffirmation: () => ({ affirmed: false, checking, affirm: vi.fn() }),
}));

import { AgeAffirmationModal } from '../AgeAffirmationModal';

describe('AgeAffirmationModal', () => {
  it('renders inactive', () => {
    const { container } = render(<AgeAffirmationModal active={false} onDecline={vi.fn()} />);
    expect(container).toBeTruthy();
  });

  it('does not open while signed-in account confirmation is being restored', () => {
    checking = true;
    const { queryByRole } = render(<AgeAffirmationModal active onDecline={vi.fn()} />);
    expect(queryByRole('dialog')).toBeNull();
    checking = false;
  });
});
