#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const read = relative => fs.readFileSync(path.join(root, relative), 'utf8');
const desktop = read('web/index.html');
const settings = read('web/settings.html');
const menu = read('web/menu.html');
const appearance = read('web/appearance.html');
const bubble = read('web/bubble.html');
const electron = read('electron/main.cjs');

const exactCodexTokens = [
  ['surface', '#181818'],
  ['editor', '#212121'],
  ['elevated', '#282828'],
  ['control', '#303030'],
  ['under', '#0d0d0d'],
  ['focus', '#339cff'],
];

assert.ok(
  desktop.indexOf('/* Codex Work visual contract:') > desktop.indexOf('@media (prefers-reduced-motion: reduce)'),
  'desktop Codex contract must be the final visual cascade',
);
for (const [name, value] of exactCodexTokens) {
  assert.match(desktop, new RegExp(`--codex-${name}:\\s*${value.replace('#', '\\#')}`),
    `desktop is missing Codex ${name}`);
}
assert.match(desktop, /--codex-text-secondary:\s*rgba\(255, 255, 255, \.70\)/);
assert.match(desktop, /--codex-text-tertiary:\s*rgba\(255, 255, 255, \.50\)/);
assert.match(desktop, /--codex-border:\s*rgba\(255, 255, 255, \.08\)/);
assert.match(desktop, /--codex-border-heavy:\s*rgba\(255, 255, 255, \.16\)/);
assert.match(desktop, /#composerShell\s*\{[\s\S]{0,220}border-radius:\s*24px/);
assert.match(desktop, /#chatDock\s*\{\s*left:\s*var\(--pet-edge\);[\s\S]{0,900}background:\s*transparent/);
assert.match(desktop, /#chatDock:has\(#conversation:not\(:empty\)\)/);
assert.match(desktop, /\.work-thread\s*\{/);
assert.doesNotMatch(desktop, /\.work-card\s*\{/);
assert.doesNotMatch(desktop, /append\('Command'/);
assert.doesNotMatch(desktop, /append\('Output'/);
assert.match(desktop, /#sendButton\s*\{\s*background:\s*var\(--codex-text\);\s*color:\s*var\(--codex-under\)/);
assert.match(desktop, /\.message\.assistant \.bubble\s*\{[\s\S]{0,200}background:\s*transparent/);
assert.match(desktop, /\.message\.user \.bubble\s*\{[\s\S]{0,220}background:\s*var\(--codex-control\)/);

assert.ok(
  settings.indexOf('/* Codex macOS visual contract.') > settings.indexOf('.settings-intro'),
  'settings Codex contract must override the legacy palette',
);
for (const [token, value] of [
  ['gray-0', '#fff'], ['gray-50', '#f9f9f9'], ['gray-75', '#f3f3f3'],
  ['gray-100', '#ededed'], ['gray-700', '#303030'], ['gray-750', '#282828'],
  ['gray-800', '#212121'], ['gray-900', '#181818'], ['gray-1000', '#0d0d0d'],
  ['focus', '#339cff'],
]) {
  assert.match(settings, new RegExp(`--codex-${token}:${value.replace('#', '\\#')}`),
    `settings is missing Codex ${token}`);
}
assert.match(settings, /header\{position:fixed;inset:0 auto 0 0;[\s\S]{0,100}width:232px/);
assert.match(settings, /nav\{display:flex;flex-direction:column/);
assert.match(settings, /main\{max-width:none;margin:0 0 0 232px/);
assert.match(settings, /\.savebar\{left:232px/);
assert.match(settings, /@media\(max-width:840px\)\{[\s\S]{0,900}main\{margin-left:0/);
assert.match(settings, /--ok-text:#007a30/);
assert.match(settings, /--warn-text:#a33a00/);
assert.match(settings, /--bad-text:#b51f1b/);

// Every auxiliary window uses the same Codex palette rather than retaining
// an inherited pink, bronze, or serif theme.
assert.match(menu, /--bg:rgba\(33,33,33,\.96\)/);
assert.match(menu, /--focus:#339cff/);
assert.doesNotMatch(menu, /data-design=atelier/);
assert.match(appearance, /--panel:rgba\(33,33,33,\.96\)/);
assert.match(appearance, /--accent:#339cff/);
assert.match(appearance, /localStorage\.getItem\('openclam-theme'\)/);
assert.match(bubble, /background:rgba\(33,33,33,\.96\)/);
assert.match(bubble, /border:1px solid rgba\(255,255,255,\.08\)/);
assert.match(bubble, /#text a\{color:#99ceff/);
assert.doesNotMatch(bubble, /data-design=atelier/);
assert.match(electron, /backgroundColor: '#181818'/);

// The visual rewrite may never turn icon-only desktop controls into unnamed
// AX nodes, or turn the settings sidebar into an unlabeled row of buttons.
for (const label of [
  'Start Live Talk', 'Switch to next avatar', 'Switch to Avatar mode',
  'Choose avatar motion', 'Read latest reply aloud',
  'Bring avatar layer forward', 'Adjust avatar opacity', 'Mirror avatar',
  'Open Character Studio', 'Fold controls', 'Hold to talk', 'Message',
  'Send message', 'Close conversation', 'Open chat history',
  'Close chat history', 'Start a new chat',
]) {
  assert.ok(desktop.includes(`aria-label="${label}"`), `missing desktop AX label: ${label}`);
}
assert.match(desktop, /<nav id="rail" aria-label="Avatar controls">/);
assert.match(desktop, /<section id="chatDock" aria-label="Conversation">/);
assert.match(desktop, /<aside id="chatHistoryPanel" aria-label="Chat history" aria-hidden="true" inert>/);
assert.match(desktop, /role="log" aria-live="polite"/);
assert.match(desktop, /openclam\.chat\.threads\.v1/);
assert.match(desktop, /const restoreChatThread = async thread =>/);
assert.match(desktop, /const createNewChat = async \(\) =>/);
assert.match(desktop, /const deleteChatThread = async id =>/);
assert.match(desktop, /openClawSessionID = thread\.openClawSessionID \|\| ''/);
assert.match(desktop, /CHAT_HISTORY_MAX_THREADS = 30/);
assert.match(desktop, /CHAT_HISTORY_MAX_BYTES = 3_500_000/);
assert.match(desktop, /prefers-reduced-motion:\s*reduce/);
assert.match(settings, /<nav aria-label="Settings sections">/);
assert.match(settings, /data-tab="avatar" class="on" aria-current="page"/);
assert.match(settings, /if \(selected\) x\.setAttribute\('aria-current', 'page'\)/);
assert.match(settings, /else x\.removeAttribute\('aria-current'\)/);
assert.match(menu, /id="menu" role="menu" aria-label="Avatar controls"/);
assert.match(menu, /<html lang="en">/);
assert.match(appearance, /aria-label="Character size"/);
assert.match(appearance, /aria-label="Character opacity"/);
assert.match(appearance, /aria-label="Animation size"/);
assert.match(bubble, /class="bubble" role="status" aria-live="polite"/);

// Deterministic contrast checks for the core dark surfaces. Secondary text
// is composited at the same 70% opacity Codex uses before it is measured.
const channel = byte => {
  const value = byte / 255;
  return value <= .04045 ? value / 12.92 : ((value + .055) / 1.055) ** 2.4;
};
const rgb = value => {
  const match = /^#([0-9a-f]{6})$/i.exec(value);
  assert.ok(match, `invalid QA colour ${value}`);
  return [0, 2, 4].map(offset => parseInt(match[1].slice(offset, offset + 2), 16));
};
const luminance = value => {
  const [red, green, blue] = rgb(value).map(channel);
  return .2126 * red + .7152 * green + .0722 * blue;
};
const contrast = (left, right) => {
  const values = [luminance(left), luminance(right)].sort((a, b) => b - a);
  return (values[0] + .05) / (values[1] + .05);
};
const composite = (foreground, background, alpha) => {
  const front = rgb(foreground), back = rgb(background);
  return `#${front.map((value, index) => Math.round(value * alpha + back[index] * (1 - alpha))
    .toString(16).padStart(2, '0')).join('')}`;
};

assert.ok(contrast('#ffffff', '#181818') >= 7, 'primary text must meet AAA contrast');
assert.ok(contrast(composite('#ffffff', '#181818', .70), '#181818') >= 4.5,
  'secondary text must meet AA contrast');
assert.ok(contrast('#339cff', '#181818') >= 3, 'focus ring must remain visible on graphite');
assert.ok(contrast('#0d0d0d', '#ffffff') >= 7, 'inverse primary controls must meet AAA contrast');
assert.ok(contrast('#007a30', composite('#00a240', '#ffffff', .07)) >= 4.5,
  'light success text must meet AA contrast on its tinted status surface');
assert.ok(contrast('#a33a00', '#ffe7d9') >= 4.5,
  'light warning text must meet AA contrast on its tinted status surface');
assert.ok(contrast('#b51f1b', '#ffd9d9') >= 4.5,
  'light error text must meet AA contrast on its tinted status surface');

console.log('Codex macOS visual token and accessibility QA passed');
