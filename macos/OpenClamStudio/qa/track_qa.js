#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.resolve(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'web', 'index.html'), 'utf8');
const start = html.indexOf('/* track-stabiliser:start */');
const end = html.indexOf('/* track-stabiliser:end */', start);
if (start < 0 || end < 0) throw new Error('runtime track helpers not found');

const context = {};
vm.createContext(context);
vm.runInContext(
  html.slice(start, end) +
    '\nthis.qa={stabiliseTrack,MIN_POSE,XFADE,VISUAL_LEAD};',
  context,
);

const {stabiliseTrack, MIN_POSE, XFADE, VISUAL_LEAD} = context.qa;
const timed = [[0, 'sil'], [0.100, 'FF'], [0.125, 'aa'],
               [0.150, 'TH'], [0.175, 'ih'], [0.220, 'sil']];
const full = ['sil', 'PP', 'FF', 'TH', 'DD', 'kk', 'CH', 'SS',
              'nn', 'RR', 'aa', 'E', 'ih', 'oh', 'ou'];
const kept = stabiliseTrack(timed, 0.220, full).map(event => event[1]);
if (kept.join(',') !== timed.map(event => event[1]).join(',')) {
  throw new Error(`25ms phoneme was deleted: ${kept.join(',')}`);
}

const noisy = stabiliseTrack(
  [[0, 'sil'], [0.100, 'FF'], [0.110, 'aa'], [0.200, 'sil']],
  0.200, full,
).map(event => event[1]);
if (noisy.join(',') !== 'sil,aa,sil') {
  throw new Error(`sub-frame noise was not collapsed: ${noisy.join(',')}`);
}
if (MIN_POSE > 0.020001) throw new Error(`MIN_POSE too high: ${MIN_POSE}`);
if (XFADE > 0.020001) {
  throw new Error(`mouth texture crossfade can double rigid teeth: ${XFADE * 1000}ms`);
}
if (Math.abs(VISUAL_LEAD - XFADE / 2) > 1e-9) {
  throw new Error('crossfade is not centered on its audio event');
}

const light = ['sil', 'FF', 'TH', 'nn', 'RR', 'aa', 'E', 'ih', 'ou'];
const mapped = stabiliseTrack([[0, 'sil'], [.1, 'PP'], [.2, 'oh']], .3, light)
  .map(event => event[1]);
if (mapped.join(',') !== 'sil,FF,ou') {
  throw new Error(`reduced avatar viseme mapping failed: ${mapped.join(',')}`);
}

console.log('Track QA passed: 25ms phonemes retained; 10ms noise collapsed.');
