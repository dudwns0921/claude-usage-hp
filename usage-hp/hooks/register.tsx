import { atom, update } from 'claude-code'
import type { Hook, Register, SessionRateLimit } from 'claude-code'

type Dollar = Parameters<Hook<'session.measure'>>[0]

import type { Limit } from '../types'

// This mod draws nothing: it only feeds the menu bar / floating app, which
// reads the files `publish` writes. null = no reading yet.
const limits = atom({ plugin: 'usage-hp', key: 'limits' } as const, null)

const toLimits = (windows: SessionRateLimit[]): Limit[] | null =>
  windows.length === 0
    ? null
    : windows.map(w => ({ kind: w.kind, percentUsed: w.percentUsed, resetsAt: w.resetsAt }))

// A variable that is unset, empty or unreadable is one answer: undefined. The
// name stays a literal at each `$.env.get` call, which the engine requires.
const set = (value: Promise<string | undefined>) => value.then(v => v || undefined, () => undefined)

const textOf = (value: unknown) => (typeof value === 'string' && value !== '' ? value : undefined)

type Login = { email?: string; organizationId?: string; organization?: string; plan?: string }

// The login record a terminal session keeps. CLAUDE_CONFIG_DIR moves it; the
// home folder is where it is otherwise.
const loginOnDisk = async ($: Dollar, home: string): Promise<Login> => {
  const configDir = await set($.env.get('CLAUDE_CONFIG_DIR'))
  const paths = [...(configDir ? [`${configDir}/.claude.json`] : []), `${home}/.claude.json`]

  for (const path of paths) {
    try {
      const account = JSON.parse(await $.fs.read(path))?.oauthAccount

      if (textOf(account?.emailAddress)) {
        return {
          email: textOf(account.emailAddress),
          organizationId: textOf(account.organizationUuid),
          organization: textOf(account.organizationName),
          plan: textOf(account.organizationType),
        }
      }
    } catch {
      // Missing or unreadable: try the next place.
    }
  }

  return {}
}

const safeOf = (text: string) => text.replace(/[^A-Za-z0-9._-]/g, '_')

// The menu bar item reads these files, one per organization: one email can
// hold two plans, and two sessions on different plans must not overwrite each
// other. An empty reading never replaces a good one, and a failure here must
// not break the hook.
const publish = async ($: Dollar, reading: Limit[] | null) => {
  if (reading === null) {
    return
  }

  try {
    const home = await set($.env.get('HOME'))

    if (!home) {
      return
    }

    // Resolved at every publish, so an account switched mid-session is picked
    // up. Email and organization come from one source, never one from each: a
    // host that names the account in the environment (the desktop app) wins,
    // since its login can differ from the terminal's record on disk.
    const disk = await loginOnDisk($, home)
    const envEmail = await set($.env.get('CLAUDE_CODE_USER_EMAIL'))
    const envOrganizationId = await set($.env.get('CLAUDE_CODE_ORGANIZATION_UUID'))
    const email = envEmail ?? disk.email ?? 'unknown'
    const organizationId = (envEmail ? envOrganizationId : disk.organizationId) ?? 'unknown'
    const path = `${home}/.claude/usage-hp/${safeOf(email)}__${safeOf(organizationId)}.json`

    // The name and plan are only on disk, and only for the organization the
    // terminal is signed in to; otherwise keep what an earlier write recorded.
    let known: { organization?: string; plan?: string } = {}

    if (organizationId !== 'unknown' && disk.organizationId === organizationId) {
      known = { organization: disk.organization, plan: disk.plan }
    }

    if (!known.organization || !known.plan) {
      try {
        const before = JSON.parse(await $.fs.read(path))
        known = {
          organization: known.organization ?? textOf(before?.organization),
          plan: known.plan ?? textOf(before?.plan),
        }
      } catch {
        // No earlier file: nothing to keep.
      }
    }

    await $.fs.write(
      path,
      JSON.stringify(
        {
          account: email,
          organizationId,
          ...(known.organization ? { organization: known.organization } : {}),
          ...(known.plan ? { plan: known.plan } : {}),
          source: (await set($.env.get('CLAUDE_CODE_ENTRYPOINT'))) ?? 'unknown',
          updatedAt: new Date().toISOString(),
          limits: reading,
        },
        null,
        2,
      ),
    )
  } catch {
    // Nothing to do: the next measurement writes again.
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const usage = await $.session.usage()
    const seeded = toLimits(usage.rateLimits)
    await update($, limits, () => seeded)
    await publish($, seeded)

    return next(e)
  })

  on('session.measure', async ($, e, next) => {
    // Keep the last reading when a measurement arrives with no windows.
    const now = toLimits(e.rateLimits)

    if (now !== null) {
      await update($, limits, () => now)
      await publish($, now)
    }

    return next(e)
  })
}
