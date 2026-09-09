'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'web/menu.html'), 'utf8');

// Keep the custom menu recognizable to assistive technology without adding
// any new renderer-to-shell capability.
assert.match(source,
  /id="menu" role="menu" aria-label="Avatar controls" aria-orientation="vertical"/);
assert.match(source, /item\.type==='checkbox'\?'menuitemcheckbox'/);
assert.match(source, /item\.type==='radio'\?'menuitemradio':'menuitem'/);
assert.match(source, /setAttribute\('aria-checked',String\(Boolean\(item\.checked\)\)\)/);
assert.match(source, /setAttribute\('aria-disabled',String\(!enabled\)\)/);
assert.match(source, /setAttribute\('role','separator'\)/);
assert.match(source, /setAttribute\('aria-orientation','horizontal'\)/);
assert.match(source, /setAttribute\('aria-haspopup','menu'\)/);
assert.match(source, /setAttribute\('aria-expanded','false'\)/);
assert.match(source, /setAttribute\('aria-controls',sub\.id\)/);
assert.match(source, /sub\.setAttribute\('role','menu'\)/);
assert.match(source, /setAttribute\('aria-labelledby'/);
assert.match(source, /setAttribute\('aria-describedby'/);
assert.match(source, /setAttribute\('aria-hidden','true'\)/);

// Roving tabindex keeps every visible row arrow-reachable while presenting
// only one tab stop at a time. Disabled menu rows remain discoverable but
// activate() refuses to invoke them.
assert.match(source, /el\.tabIndex=-1/);
assert.match(source,
  /root\.querySelectorAll\(ITEM_SELECTOR\)\.forEach\(item=>\{item\.tabIndex=item===el\?0:-1;\}\)/);
assert.match(source, /focusItem\(visibleItems\(\)\[0\]\)/);
assert.match(source, /getAttribute\('aria-disabled'\)==='true'\)return/);
assert.match(source, /\.item:focus-visible\{outline:/);

// The complete keyboard contract: wrap vertically, jump to either end,
// enter/leave the inline submenu, activate, and dismiss safely.
for (const key of [
  'ArrowDown', 'ArrowUp', 'ArrowRight', 'ArrowLeft',
  'Home', 'End', 'Enter', 'Escape',
]) {
  assert.ok(source.includes(`e.key==='${key}'`), `missing ${key} keyboard behavior`);
}
assert.match(source, /e\.key==='Enter'\|\|e\.key===' '\)\&\&current/);
assert.match(source, /setSubmenuOpen\(current,true,true\)/);
assert.match(source, /setSubmenuOpen\(trigger,false\)/);
assert.match(source, /else MENU\.close\(\)/);
assert.match(source, /e\.preventDefault\(\);e\.stopPropagation\(\)/);

// No Electron IPC contract was added or bypassed by this renderer-only fix.
const usedMenuMethods = [...source.matchAll(/MENU\.(\w+)/g)].map((match) => match[1]);
assert.deepEqual([...new Set(usedMenuMethods)].sort(), ['action', 'close', 'onSpec', 'size']);
assert.doesNotMatch(source, /ipcRenderer|require\(['"]electron['"]\)/);

// Inline JavaScript remains syntactically valid without starting Electron.
for (const [, script] of source.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/gi)) {
  // eslint-disable-next-line no-new-func
  new Function(script);
}

console.log('custom menu accessibility QA passed');

// Opening Dynamic motions replaces the root menu. The old native window can
// deliver blur/load after its replacement exists; it must not close that menu.
const vm = require('node:vm'), {EventEmitter} = require('node:events');
const main = fs.readFileSync(path.join(root,'electron/main.cjs'),'utf8');
const created=[];
class MenuWindow extends EventEmitter {
  constructor(){super();this.webContents=new EventEmitter();this.webContents.setZoomFactor=()=>{};
    this.webContents.setVisualZoomLevelLimits=()=>{};created.push(this);}
  setAlwaysOnTop(){}setVisibleOnAllWorkspaces(){}loadURL(){}
  isDestroyed(){return Boolean(this.destroyed);}destroy(){this.destroyed=true;}
}
const posted=[];
const context={BrowserWindow:MenuWindow,screen:{getCursorScreenPoint:()=>({x:10,y:20})},
  path,__dirname:path.join(root,'electron'),guardNavigation(){},baseUrl:()=>'',post:(...args)=>posted.push(args)};
vm.createContext(context);
vm.runInContext(main.slice(main.indexOf('let menuWindow = null;'),main.indexOf('function createSpeechBubbleWindow()'))
  +'\nthis.open=showMenuWindow;',context);
context.open([{name:'Root'}]);const old=created[0];
context.open([{name:'Dynamic motions'}]);const replacement=created[1];
old.emit('blur');old.webContents.emit('did-finish-load');
assert(!replacement.isDestroyed(),'an old blur cannot dismiss the replacement menu');
assert.equal(posted.length,0,'an old load cannot overwrite the replacement menu contents');
replacement.webContents.emit('did-finish-load');assert.equal(posted[0][0],replacement);
replacement.emit('blur');assert(replacement.isDestroyed(),'real focus departure still dismisses the active menu');
console.log('Desktop menu replacement survives late blur/load from its predecessor.');
