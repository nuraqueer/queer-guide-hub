import { render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { describe, it, expect } from 'vitest';
import QualityHub from '../QualityHub';
describe('engine diagnostics', () => {
  it('offers measurements and a return to the one queue, without another approval surface', () => {
    render(
      <MemoryRouter>
        <QualityHub />
      </MemoryRouter>,
    );
    expect(
      screen.getByRole('heading', { name: 'Engine diagnostics', level: 1 }),
    ).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Open Review queue' })).toHaveAttribute(
      'href',
      '/admin',
    );
    expect(screen.queryByRole('button', { name: /Approve/ })).not.toBeInTheDocument();
  });
});
