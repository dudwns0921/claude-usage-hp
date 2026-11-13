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

// The windows a published file holds; anything that is not one is dropped.
const limitsOf = (file: unknown): Limit[] => {
  const list = (file as { limits?: unknown } | null | undefined)?.limits

  return Array.isArray(list)
    ? list.filter((w): w is Limit => typeof w?.kind === 'string')
    : []
}

// A reset time as an instant, so two spellings of one moment compare equal.
// Missing or unparsable is NaN, which is near nothing and never in the future.
const instantOf = (text: unknown) => (typeof text === 'string' ? Date.parse(text) : NaN)

// Two writers can name one reset a few seconds apart; a minute is one moment.
const near = (a: number, b: number) => Math.abs(a - b) <= 60_000

// True when the reading cannot be this file's: the file still has a live
// window of some kind, and the reading's window of that kind ends at another
// moment. A window only moves its reset once the old one has passed.
const conflicts = (reading: Limit[], file: Limit[], nowMs: number): boolean =>
  reading.some(w => {
    const at = instantOf(w.resetsAt)

    return file.some(o => {
      const fileAt = instantOf(o.resetsAt)

      return o.kind === w.kind && fileAt > nowMs && !Number.isNaN(at) && !near(fileAt, at)
    })
  })

// A published file of the same email under another organization.
type Other = { key: string; file: Record<string, unknown> }

// The file a reading belongs to once it conflicts with the resolved one: the
// one whose window ends when the reading's does; failing that, the only other
// file, when nothing live in it disagrees. No answer means write nowhere.
const routeOf = (reading: Limit[], others: Other[], nowMs: number): Other | undefined => {
  const matching = others.find(other =>
    limitsOf(other.file).some(o =>
      reading.some(w => w.kind === o.kind && near(instantOf(w.resetsAt), instantOf(o.resetsAt))),
    ),
  )
  const only = others.length === 1 ? others[0] : undefined

  return matching ?? (only && !conflicts(reading, limitsOf(only.file), nowMs) ? only : undefined)
}

// The other files of this email, one per organization. A file that cannot be
// read counts as absent; a folder that cannot be listed is null, which is not
// the same as having no other file.
const othersOf = async (
  $: Dollar,
  folder: string,
  ownKey: string,
  email: string,
  organizationId: string,
): Promise<Other[] | null> => {
  try {
    const others: Other[] = []

    for (const entry of await $.fs.list(folder)) {
      if (
        entry.kind !== 'file' ||
        !entry.name.endsWith('.json') ||
        entry.name === 'labels.json' ||
        entry.name === `${ownKey}.json`
      ) {
        continue
      }

      try {
        const file = JSON.parse(await $.fs.read(`${folder}/${entry.name}`))
        const theirs = textOf(file?.organizationId)

        if (file?.account === email && theirs && theirs !== organizationId) {
          others.push({ key: entry.name.slice(0, -'.json'.length), file })
        }
      } catch {
        // Unreadable: as if it were not there.
      }
    }

    return others
  } catch {
    return null
  }
}

// The last write this process made: which file it was and what it held. A
// reading is the last API response, so right after a login change the same
// reading turns up again under the new account's name.
let written: { key: string; print: string } | null = null

// True when the account changed but the reading did not: it is still the old
// account's. The new account's first fresh reading differs and is written.
const staleAfterSwitch = (
  last: { key: string; print: string } | null,
  key: string,
  print: string,
): boolean => last !== null && last.key !== key && last.print === print

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
    const key = `${safeOf(email)}__${safeOf(organizationId)}`
    const folder = `${home}/.claude/usage-hp`
    const path = `${folder}/${key}.json`
    const print = JSON.stringify(reading)
    const source = (await set($.env.get('CLAUDE_CODE_ENTRYPOINT'))) ?? 'unknown'
    const updatedAt = new Date().toISOString()

    let before: unknown

    try {
      before = JSON.parse(await $.fs.read(path))
    } catch {
      // No earlier file: nothing to keep or compare with.
    }

    // The terminal and the desktop app share the login record on disk while
    // each can be signed in to its own organization of one email, so the
    // resolved organization can be the other one's. The reading then goes to
    // the file it does belong to, or nowhere. A folder that cannot be listed
    // leaves the resolved file as the target, as if nothing disagreed.
    if (conflicts(reading, limitsOf(before), Date.now())) {
      const others = await othersOf($, folder, key, email, organizationId)

      if (others !== null) {
        const route = routeOf(reading, others, Date.now())

        if (!route || staleAfterSwitch(written, route.key, print)) {
          return
        }

        // Its own name and plan stay: the login on disk is the wrong organization.
        await $.fs.write(
          `${folder}/${route.key}.json`,
          JSON.stringify({ ...route.file, source, updatedAt, limits: reading }, null, 2),
        )
        written = { key: route.key, print }

        return
      }
    }

    if (staleAfterSwitch(written, key, print)) {
      return
    }

    // The name and plan are only on disk, and only for the organization the
    // terminal is signed in to; otherwise keep what an earlier write recorded.
    let known: { organization?: string; plan?: string } = {}

    if (organizationId !== 'unknown' && disk.organizationId === organizationId) {
      known = { organization: disk.organization, plan: disk.plan }
    }

    const earlier = before as { organization?: unknown; plan?: unknown } | null | undefined

    known = {
      organization: known.organization ?? textOf(earlier?.organization),
      plan: known.plan ?? textOf(earlier?.plan),
    }

    await $.fs.write(
      path,
      JSON.stringify(
        {
          account: email,
          organizationId,
          ...(known.organization ? { organization: known.organization } : {}),
          ...(known.plan ? { plan: known.plan } : {}),
          source,
          updatedAt,
          limits: reading,
        },
        null,
        2,
      ),
    )
    written = { key, print }
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
