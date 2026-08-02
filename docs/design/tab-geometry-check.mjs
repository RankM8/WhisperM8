// Geometrie-Abgleich: HTML-Zwilling gegen den integrierten Swift-Stand.
//
// Prüft die Tab-Leiste in docs/design/agent-chats-layout-engine.html gegen die
// Sollwerte aus WhisperM8/Views/AgentChatChromeViews.swift (ChatTabButton,
// GroupPill, ChromeTabMetrics). Läuft absichtlich außerhalb von `swift test`:
// es ist ein Design-Werkzeug, kein Unit-Test der App.
//
// Voraussetzung: lokaler Server auf 8791 im Repo-Wurzelverzeichnis, z. B.
//   python3 -m http.server 8791
// Aufruf:
//   node docs/design/tab-geometry-check.mjs
//
// Ändert sich die Tab-Gestaltung in Swift, hier die SOLL-Werte nachziehen —
// dann zeigt der Check, wo der Zwilling nachgezogen werden muss.

import { chromium } from '/Users/giulianocosta/repos/headless-woo/node_modules/playwright/index.mjs';

const URL_ = 'http://127.0.0.1:8791/docs/design/agent-chats-layout-engine.html?check=' + Date.now();

// SOLL — Quelle jeweils in Klammern
const SOLL = {
  tabHoehe: 28,          // ChatTabButton: minHeight/maxHeight 28
  tabMinBreite: 100,     // ChatTabButton: minWidth 100
  tabMaxBreite: 190,     // ChatTabButton: maxWidth 190
  tabPaddingX: 8,        // ChatTabButton: .padding(.horizontal, 8)
  tabSpalten: 6,         // HStack(spacing: 6)
  titelGroesse: 11,      // Text(session.title).font(.system(size: 11))
  titelAktivFett: 600,   // isSelected ? .semibold : .regular
  avatarGroesse: 13,     // ProjectAvatar(size: 13)
  tailBreite: 18,        // trailingIndicator.frame(width: 18)
  zungenRadius: 7,       // ChromeTabShape.cornerRadius
  fussBreite: 7,         // ChromeTabMetrics.footSize
  gruppenKontur: 2,      // chromeShape.stroke(groupColor, lineWidth: 2)
  pilleHoehe: 19,        // GroupPill: .frame(height: 19)
  pillePaddingX: 7,      // GroupPill: .padding(.horizontal, 7)
  pilleRadius: 5,        // RoundedRectangle(cornerRadius: 5)
  pilleKontur: 1.5,      // strokeBorder(groupColor, lineWidth: 1.5)
  pilleTitel: 10,        // Text(title).font(.system(size: 10, weight: .semibold))
  pilleZaehler: 9,       // Text(count).font(.system(size: 9, weight: .medium))
  pilleSpalten: 4,       // HStack(spacing: 4)
  chevron: 7,            // Image(chevron.down).font(.system(size: 7, weight: .bold))
};

const zahl = wert => parseFloat(String(wert));
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1600, height: 900 } });
await page.goto(URL_);
await page.waitForSelector('.tab.active');
await page.waitForTimeout(300);

const ist = await page.evaluate(() => {
  const g = (el, prop) => getComputedStyle(el)[prop];
  const aktiv = document.querySelector('.tab.active');
  const inaktiv = document.querySelector('.tab:not(.active)');
  const pille = document.querySelector('.group-pill.closed') || document.querySelector('.group-pill');
  const vor = getComputedStyle(aktiv, '::before');
  return {
    stil: document.querySelector('#app').dataset.tabStyle,
    tabHoehe: aktiv.getBoundingClientRect().height,
    tabMinBreite: g(aktiv, 'minWidth'),
    tabMaxBreite: g(aktiv, 'maxWidth'),
    tabPaddingX: g(aktiv, 'paddingLeft'),
    tabSpalten: g(aktiv, 'columnGap'),
    titelGroesse: g(aktiv, 'fontSize'),
    titelAktivFett: g(aktiv, 'fontWeight'),
    titelInaktivFett: inaktiv ? g(inaktiv, 'fontWeight') : null,
    avatarGroesse: g(aktiv.querySelector('.avatar'), 'width'),
    tailBreite: g(aktiv.querySelector('.tail'), 'width'),
    zungenRadius: g(aktiv, 'borderTopLeftRadius'),
    fussBreite: vor.width,
    gruppenKontur: g(aktiv, 'borderTopWidth'),
    pilleHoehe: pille.getBoundingClientRect().height,
    pillePaddingX: g(pille, 'paddingLeft'),
    pilleRadius: g(pille, 'borderTopLeftRadius'),
    pilleKontur: (g(pille, 'boxShadow').match(/([\d.]+)px inset/) || [])[1] ?? g(pille, 'borderTopWidth'),
    pilleTitel: g(pille, 'fontSize'),
    pilleZaehler: g(pille.querySelector('.count'), 'fontSize'),
    pilleSpalten: g(pille, 'columnGap'),
    chevron: g(pille.querySelector('.fold'), 'fontSize'),
  };
});

let fehler = 0;
console.log(`Tab-Stil: ${ist.stil}\n`);
for (const [feld, soll] of Object.entries(SOLL)) {
  const gemessen = zahl(ist[feld]);
  const ok = Math.abs(gemessen - soll) < 0.51;
  if (!ok) fehler++;
  console.log(`  ${ok ? '✓' : '✗'} ${feld.padEnd(16)} soll ${String(soll).padStart(5)}   ist ${String(gemessen).padStart(6)}`);
}
// Inaktive Tabs müssen normal gewichtet sein (regular), nicht semibold
const inaktivOk = zahl(ist.titelInaktivFett) <= 400;
if (!inaktivOk) fehler++;
console.log(`  ${inaktivOk ? '✓' : '✗'} titelInaktivFett soll   400   ist ${String(zahl(ist.titelInaktivFett)).padStart(6)}`);

console.log(`\n${fehler === 0 ? 'ALLE WERTE STIMMEN' : fehler + ' ABWEICHUNG(EN)'}`);
await browser.close();
process.exit(fehler === 0 ? 0 : 1);
