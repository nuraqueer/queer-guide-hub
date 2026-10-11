import { venueContentType } from '@/config/contentTypes/venue';
import { validateAgainstRegistry } from './zodFromFields';

/** Existing unchanged branches cannot prevent an identity-only correction. */
export function validateOrganisationLocations(value: unknown, original: unknown): string | null {
  if (!Array.isArray(value)) return 'Locations must be a list.';
  const prior = Array.isArray(original) ? (original as Record<string, unknown>[]) : [];
  for (const [index, row] of value.entries()) {
    if (!row || typeof row !== 'object' || Array.isArray(row))
      return `Location ${index + 1} is invalid.`;
    const location = row as Record<string, unknown>;
    const before = location.id ? prior.find((item) => item.id === location.id) : null;
    if (before && JSON.stringify(before) === JSON.stringify(location)) continue;
    const schema = validateAgainstRegistry(venueContentType, {
      ...location,
      ...Object.fromEntries(
        ['website', 'email', 'phone', 'booking_url']
          .filter((key) => location[key] === '')
          .map((key) => [key, null]),
      ),
    });
    if (!schema.ok) return `Location ${index + 1}: ${schema.issues[0].message}`;
    const validation = venueContentType.validate?.(location);
    if (validation && !validation.isValid)
      return `Location ${index + 1}: ${validation.errors[0].message}`;
  }
  return null;
}
