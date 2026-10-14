import { classifyHttpStatus } from './link-health.ts'

export function contentLinkHttpStatus(code: number): 'OK' | 'REDIRECT' | 'BROKEN' | 'BLOCKED' | 'TIMEOUT' {
  const status = classifyHttpStatus(code)
  if (status === 'ok') return 'OK'
  if (status === 'redirect') return 'REDIRECT'
  if (status === 'broken') return 'BROKEN'
  if (status === 'blocked') return 'BLOCKED'
  return 'TIMEOUT'
}

export function mayRemoveContentLink(status: string, httpStatus: number | null, checkCount: number): boolean {
  return status === 'BROKEN' && (httpStatus === 404 || httpStatus === 410) && checkCount >= 4
}

/** Transient attempts set retry backoff, but cannot advance a dead-link sequence. */
export function nextContentLinkCheckCount(
  previousStatus: string,
  previousHttpStatus: number | null,
  previousCount: number | null,
  status: string,
  httpStatus: number | null,
): number {
  if (status === 'OK' || status === 'REDIRECT') return 0
  const count = Math.max(0, Math.min(previousCount ?? 0, 3))
  if (status === 'BROKEN' && (httpStatus === 404 || httpStatus === 410)) {
    const previouslyDead = previousStatus === 'BROKEN' &&
      (previousHttpStatus === 404 || previousHttpStatus === 410)
    return previouslyDead ? count + 1 : 1
  }
  return Math.min(count + 1, 3)
}
