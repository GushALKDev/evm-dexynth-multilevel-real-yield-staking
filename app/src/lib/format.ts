const groupInt = (s: string) => s.replace(/\B(?=(\d{3})+(?!\d))/g, ',')

/**
 * Formats a fixed-point bigint. Truncates toward zero, so a balance is never shown higher than it is.
 * `shown` is the number of decimals displayed; trailing zeros are kept for column alignment.
 */
export function formatFixed(value: bigint, decimals: number, shown: number): string {
  const negative = value < 0n
  const abs = negative ? -value : value
  const scale = 10n ** BigInt(decimals)
  const int = abs / scale
  let out = groupInt(int.toString())
  if (shown > 0) {
    const frac = (abs % scale).toString().padStart(decimals, '0').slice(0, shown).padEnd(shown, '0')
    out += `.${frac}`
  }
  return negative ? `-${out}` : out
}

/** Compact form for large totals: 1.25M, 340.5K. */
export function formatCompact(value: bigint, decimals: number): string {
  const n = Number(value) / 10 ** decimals
  const abs = Math.abs(n)
  if (abs >= 1e9) return `${(n / 1e9).toFixed(2)}B`
  if (abs >= 1e6) return `${(n / 1e6).toFixed(2)}M`
  if (abs >= 1e4) return `${(n / 1e3).toFixed(1)}K`
  return n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

/** Fraction at 1e18 scale as a percentage. */
export function formatPct(value18: bigint, shown = 2): string {
  return `${formatFixed(value18 * 100n, 18, shown)}%`
}

export function shortAddress(address: string): string {
  return `${address.slice(0, 6)}…${address.slice(-4)}`
}

/** Parses a user-typed decimal amount into base units; null if it is not a valid number. */
export function parseAmount(input: string, decimals: number): bigint | null {
  const s = input.trim().replace(/,/g, '')
  if (!/^\d*\.?\d*$/.test(s) || s === '' || s === '.') return null
  const [int, frac = ''] = s.split('.')
  if (frac.length > decimals) return null
  return BigInt(int || '0') * 10n ** BigInt(decimals) + BigInt(frac.padEnd(decimals, '0') || '0')
}

/** Inverse of parseAmount for Max buttons: no grouping, trailing zeros trimmed. */
export function toInput(value: bigint, decimals: number): string {
  const scale = 10n ** BigInt(decimals)
  const frac = (value % scale).toString().padStart(decimals, '0').replace(/0+$/, '')
  return frac ? `${value / scale}.${frac}` : `${value / scale}`
}


/** A lock or epoch length in words: 3600 -> 1 hour, 259200 -> 3 days. */
export function formatDuration(seconds: bigint): string {
  const plural = (n: bigint, unit: string) => `${n} ${unit}${n === 1n ? '' : 's'}`
  if (seconds > 0n && seconds % 86_400n === 0n) return plural(seconds / 86_400n, 'day')
  if (seconds > 0n && seconds % 3_600n === 0n) return plural(seconds / 3_600n, 'hour')
  if (seconds > 0n && seconds % 60n === 0n) return plural(seconds / 60n, 'minute')
  return plural(seconds, 'second')
}

/** Countdown to a moment, coarse: 2 days 4 h, 3 h 12 min, 42 s. */
export function countdown(seconds: bigint): string {
  const s = Number(seconds > 0n ? seconds : 0n)
  if (s >= 86_400) return `${Math.floor(s / 86_400)} d ${Math.floor((s % 86_400) / 3600)} h`
  if (s >= 3600) return `${Math.floor(s / 3600)} h ${Math.floor((s % 3600) / 60)} min`
  if (s >= 60) return `${Math.floor(s / 60)} min ${s % 60} s`
  return `${s} s`
}

/** A chain timestamp as a local date and time. */
export function formatTime(timestamp: bigint): string {
  return new Date(Number(timestamp) * 1000).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' })
}

/** A chain timestamp as a local date. */
export function formatDate(timestamp: bigint): string {
  return new Date(Number(timestamp) * 1000).toLocaleDateString(undefined, { dateStyle: 'medium' })
}
