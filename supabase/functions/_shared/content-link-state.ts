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
