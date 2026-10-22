// Prints the contrast and separation figures recorded in DESIGN.md: WCAG contrast ratios and OKLab distance
// (Delta E x 100, normal vision) between the accent, the pool color and the danger and warn colors.
// Usage: node scripts/contrast.mjs
const themes = {
  light: {
    ground: '#edf0ee', surface: '#ffffff', accent: '#5a6438', hover: '#48502b', buttonText: '#ffffff',
    pool: '#5b7fb0', danger: '#b23b2a', warn: '#9a6614',
  },
  dark: {
    ground: '#0e1412', surface: '#151c1a', accent: '#a2ae82', hover: '#b3be97', buttonText: '#0e1412',
    pool: '#6f8ecc', danger: '#e07a66', warn: '#d9a54a',
  },
}

const channels = (hex) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255)
const linear = (c) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4)

function luminance(hex) {
  const [r, g, b] = channels(hex).map(linear)
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

function contrast(a, b) {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x)
  return (hi + 0.05) / (lo + 0.05)
}

function oklab(hex) {
  const [r, g, b] = channels(hex).map(linear)
  const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
  const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
  const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
  return [
    0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s,
  ]
}

const deltaE = (a, b) => Math.hypot(...oklab(a).map((v, i) => v - oklab(b)[i])) * 100

for (const [name, t] of Object.entries(themes)) {
  console.log(`${name}`)
  for (const [a, b] of [
    ['accent', 'buttonText'], ['hover', 'buttonText'], ['accent', 'ground'], ['accent', 'surface'],
    ['pool', 'ground'], ['pool', 'surface'],
  ]) {
    console.log(`  contrast ${a} / ${b}: ${contrast(t[a], t[b]).toFixed(2)}`)
  }
  for (const other of ['accent', 'danger', 'warn']) {
    console.log(`  delta E pool / ${other}: ${deltaE(t.pool, t[other]).toFixed(1)}`)
  }
}
