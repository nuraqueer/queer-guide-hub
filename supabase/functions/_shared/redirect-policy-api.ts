import { policyErrors, LINK_POLICY_FIELDS, type LinkPolicy } from './link-policy.ts';
export function policyPatchInput(value: unknown): {
  patch: Record<string, unknown>;
  changePassword: boolean;
  password: string | null;
} {
  if (!value || typeof value !== 'object' || Array.isArray(value))
    throw new Error('Provide a policy patch');
  const body = value as Record<string, unknown>;
  if (
    !Object.keys(body).length ||
    Object.keys(body).some((key) => !['policy', 'password'].includes(key))
  )
    throw new Error('Invalid policy request fields');
  const patch = body.policy === undefined ? {} : body.policy;
  if (
    !patch ||
    typeof patch !== 'object' ||
    Array.isArray(patch) ||
    Object.keys(patch).some((key) => !LINK_POLICY_FIELDS.includes(key))
  )
    throw new Error('Invalid policy fields');
  const entries = Object.entries(patch),
    changePassword = Object.prototype.hasOwnProperty.call(body, 'password');
  if (!entries.length && !changePassword) throw new Error('Provide fields to update');
  if (
    changePassword &&
    body.password !== null &&
    (typeof body.password !== 'string' || body.password.length < 1 || body.password.length > 256)
  )
    throw new Error('Password must be 1–256 characters or null');
  const errors = policyErrors(
    Object.fromEntries(entries.filter(([, item]) => item !== null)) as LinkPolicy,
  );
  if (errors.length) throw new Error(errors.join('; '));
  return {
    patch: patch as Record<string, unknown>,
    changePassword,
    password: typeof body.password === 'string' ? body.password : null,
  };
}
