'use strict';

// A call belongs to the application, not its currently visible window. Keep
// its media in one renderer and let either presentation control that session.
class LiveTalkOwner {
  constructor(windows, post) {
    this.windows = windows;
    this.post = post;
    this.owner = null;
    this.lease = 0;
    this.phase = 'idle';
    this.frame = null;
    this.cleanup = () => {};
  }
  get active() { return this.phase !== 'idle'; }
  allowed(sender) {
    return this.windows().some(w => w && !w.isDestroyed() && w.webContents === sender);
  }
  snapshot(sender) {
    return this.allowed(sender)
      ? { phase: this.phase, owned: sender === this.owner, frame: this.frame }
      : { phase: 'idle' };
  }
  publish() {
    for (const w of this.windows()) {
      if (w && !w.isDestroyed()) this.post(w, 'openclam:live-state', this.snapshot(w.webContents));
    }
  }
  claim(sender) {
    if (!this.allowed(sender) || (this.owner && !this.owner.isDestroyed())) return null;
    this.cleanup();
    this.owner = sender;
    const lease = ++this.lease;
    this.phase = 'connecting';
    this.frame = null;
    const gone = () => this.release(sender, lease);
    const navigate = (_event, _url, inPlace, mainFrame) => {
      if (mainFrame && !inPlace) gone();
    };
    sender.once('destroyed', gone);
    sender.once('render-process-gone', gone);
    sender.on('did-start-navigation', navigate);
    this.cleanup = () => {
      sender.removeListener('destroyed', gone);
      sender.removeListener('render-process-gone', gone);
      sender.removeListener('did-start-navigation', navigate);
    };
    this.publish();
    return lease;
  }
  owns(sender, lease) { return sender === this.owner && lease === this.lease; }
  release(sender, lease) {
    if (!this.owns(sender, lease)) return;
    this.cleanup();
    this.cleanup = () => {};
    this.owner = null;
    this.phase = 'idle';
    this.frame = null;
    this.publish();
  }
  setPhase(sender, { lease, value } = {}) {
    if (!this.owns(sender, lease)) return;
    if (!value) return this.release(sender, lease);
    if (this.phase === 'ending') return;
    this.phase = ['connected', 'ending'].includes(value) ? value : 'connecting';
    this.publish();
  }
  end(sender) {
    if (!this.allowed(sender) || !this.owner || this.owner.isDestroyed() || this.phase === 'ending') return;
    this.phase = 'ending';
    this.publish();
    // Explicit hang-up is idempotent. A delayed toggle must never start a call.
    this.owner.send('openclam:live-stop');
  }
  shareFrame(sender, { lease, frame } = {}) {
    if (!this.owns(sender, lease) || !frame || this.phase === 'ending') return;
    try { if (JSON.stringify(frame).length > 8000) return; } catch { return; }
    this.frame = frame;
    for (const w of this.windows()) {
      if (w && !w.isDestroyed() && w.webContents !== sender) this.post(w, 'openclam:live-frame', frame);
    }
  }
}

module.exports = { LiveTalkOwner };
