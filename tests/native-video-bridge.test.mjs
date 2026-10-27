// Run with Node.js 22+: node --test tests/native-video-bridge.test.mjs
// Exercise the actual methods in the Gecko patches without a full Gecko build.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

function patchedMethods(path, start, end) {
  const additions = readFileSync(new URL(path, import.meta.url), 'utf8')
    .split('\n').filter(line => (line.startsWith('+') && !line.startsWith('+++')) || line.startsWith(' '))
    .map(line => line.slice(1)).join('\n');
  return additions.slice(additions.indexOf(start), additions.indexOf(end));
}
const actorMethods = patchedMethods(
  '../patches/mobile/shared/actors/GeckoViewContentChild.sys.mjs.patch',
  '  nativeVideoViewport()', '  getFocusedInputBounds(');
const moduleMethods = patchedMethods(
  '../patches/mobile/shared/modules/geckoview/GeckoViewContent.sys.mjs.patch',
  '  _nativeVideoContexts()', '  async _fillOneTimeCode(');
let uuid = 0;
const Actor = vm.runInNewContext(`class Actor { ${actorMethods} }; Actor`, {
  URL, WeakRef, Services: { uuid: { generateUUID: () => `opaque-${++uuid}` } },
  Cu: {
    Sandbox(principal, options) {
      const document = options.sandboxPrototype.document;
      assert.equal(principal, document.nodePrincipal);
      assert.equal(options.wantXrays, true);
      const sandbox = { document, options, nuked: false };
      document.permissionSandboxes.push(sandbox);
      return sandbox;
    },
    evalInSandbox(code, sandbox) {
      assert.equal(code, 'document.fullscreenEnabled === true');
      if (sandbox.document.failPermissionEvaluation) throw new Error('Policy unavailable');
      return sandbox.document.contentFullscreenEnabled;
    },
    nukeSandbox(sandbox) { sandbox.nuked = true; },
  },
});
const Module = vm.runInNewContext(`class Module { ${moduleMethods} }; Module`);

function fixture() {
  const document = { title: 'Test video', fullscreenElement: null, elements: [],
    nodePrincipal: {}, fullscreenEnabled: true, contentFullscreenEnabled: true, permissionSandboxes: [],
    querySelectorAll: () => document.elements };
  const window = { innerWidth: 1000, innerHeight: 800,
    windowGlobalChild: { innerWindowId: 99 }, navigator: { userAgent: 'Gecko test' },
    HTMLVideoElement: { isInstance: element => !!element.isVideo },
    getComputedStyle: () => ({ display: 'block', visibility: 'visible', opacity: '1' }),
  };
  document.defaultView = window;
  window.document = document;
  const parent = { ownerDocument: document, isConnected: true };
  const actor = new Actor();
  Object.assign(actor, { document, contentWindow: window, browsingContext: { id: 42, children: [] } });
  function video(overrides = {}) {
    const listeners = new Map();
    const video = { isVideo: true, isConnected: true, ownerDocument: document, parentNode: parent,
      addEventListener(type, callback) { listeners.set(type, callback); },
      removeEventListener(type, callback) { if (listeners.get(type) === callback) listeners.delete(type); },
      dispatchEnded(trusted = true) { this.ended = true; listeners.get('ended')?.({ isTrusted: trusted }); },
      currentSrc: 'https://example.test/video.mp4',
      attributeSrc: '/video.mp4', srcObject: null, mediaKeys: null,
      currentTime: 12, duration: 120, paused: false, ended: false, playbackRate: 1,
      muted: false, volume: 0.75, videoWidth: 640, videoHeight: 360, readyState: 4,
      seekable: { length: 1, start: () => 0, end: () => 120 },
      getAttribute() { return this.attributeSrc; },
      getBoundingClientRect: () => ({ left: 0, top: 0, right: 640, bottom: 360 }),
      checkVisibility: () => true, getClientRects: () => [1], contains: () => false,
      pauseCalls: 0, playCalls: 0, fullscreenCalls: 0,
      pause() { this.pauseCalls++; this.paused = true; },
      async play() { this.playCalls++; this.paused = false; },
      async requestFullscreen() { this.fullscreenCalls++; document.fullscreenElement = this; },
      ...overrides,
    };
    document.elements.push(video);
    return video;
  }
  function command(descriptor, command, values = {}) {
    return actor.commandNativeVideo({ token: descriptor.token,
      browsingContextID: descriptor.browsingContextID,
      innerWindowID: descriptor.innerWindowID, command, ...values });
  }
  return { actor, document, window, video, command };
}

test('discovers and controls real DOM videos without a nonstandard ownerGlobal property', async () => {
  const f = fixture();
  const video = f.video();
  assert.equal('ownerGlobal' in video, false);
  assert.equal(video.ownerDocument.defaultView, f.window);
  const descriptor = f.actor.getNativeVideo();
  assert.equal(descriptor.innerWindowID, '99');
  assert.equal(descriptor.visibleArea, 640 * 360);
  assert.equal(descriptor.visibleVideoCount, 1);
  const status = await f.command(descriptor, 'status');
  assert.equal(status.token, descriptor.token);
  assert.equal(status.visibleArea, descriptor.visibleArea);
});

test('a video document without an active window has no visible area and reports a lookup error', () => {
  const f = fixture();
  const video = f.video();
  f.document.defaultView = null;
  assert.equal(f.actor.nativeVideoVisibleArea(video), 0);
  assert.throws(() => f.actor.getNativeVideo(), /document has no active window/);
});

test('selects fullscreen then playing then visible area, and preserves the exact token', () => {
  const f = fixture();
  const playing = f.video();
  const paused = f.video({ paused: true });
  assert.equal(f.actor.getNativeVideo().token, f.actor.getNativeVideo().token);
  assert.equal(f.actor._nativeVideoTarget.video.deref(), playing);
  f.document.fullscreenElement = paused;
  const selected = f.actor.getNativeVideo();
  assert.equal(f.actor._nativeVideoTarget.video.deref(), paused);
  assert.equal(selected.isFullscreen, true);
  assert.equal(selected.url, playing.currentSrc);
  assert.equal(selected.browsingContextID, '42');
  assert.equal(selected.innerWindowID, '99');
  assert.equal(selected.userAgent, 'Gecko test');
});

test('prepare saves state before pausing and restore targets only that element', async () => {
  const f = fixture();
  const selected = f.video();
  const unrelated = f.video({ paused: true });
  const descriptor = f.actor.getNativeVideo();
  const prepared = await f.command(descriptor, 'prepare');
  assert.equal(prepared.paused, false);
  assert.equal(prepared.currentTime, 12);
  assert.equal(prepared.handoffPrepared, true);
  assert.equal(selected.paused, true);
  await f.command(descriptor, 'restore', { currentTime: 44, playbackRate: 1.25,
    paused: false, muted: true, volume: 0.5 });
  assert.equal(selected.currentTime, 44);
  assert.equal(selected.paused, false);
  assert.equal(selected.playbackRate, 1.25);
  assert.equal(selected.muted, true);
  assert.equal(selected.volume, 0.5);
  assert.equal(unrelated.currentTime, 12);
  assert.equal(unrelated.playCalls, 0);
  await assert.rejects(f.command(descriptor, 'pause'), /changed/);
});

test('failed native startup can restore the complete original paused state', async () => {
  const f = fixture();
  const selected = f.video({ paused: true, playbackRate: 1.5, muted: true });
  const descriptor = f.actor.getNativeVideo();
  await f.command(descriptor, 'prepare');
  selected.currentTime = 65;
  selected.playbackRate = 1;
  await f.command(descriptor, 'restore');
  assert.equal(selected.currentTime, 12);
  assert.equal(selected.paused, true);
  assert.equal(selected.playbackRate, 1.5);
  assert.equal(selected.muted, true);
  assert.equal(selected.playCalls, 0);
});

test('source changes, detached elements, and inner window changes reject stale commands', async () => {
  for (const invalidate of [
    (f, v) => { v.currentSrc = 'https://example.test/other.mp4'; },
    (f, v) => { v.attributeSrc = '/other.mp4'; },
    (f, v) => { v.srcObject = {}; },
    (f, v) => { v.isConnected = false; },
    (f, v) => { v.ownerDocument = {}; },
    f => { f.window.windowGlobalChild.innerWindowId++; },
  ]) {
    const f = fixture();
    const selected = f.video();
    const descriptor = f.actor.getNativeVideo();
    await f.command(descriptor, 'prepare');
    invalidate(f, selected);
    await assert.rejects(f.command(descriptor, 'restore', { paused: false }), /changed/);
    assert.equal(selected.playCalls, 0);
  }
});

test('MSE, MediaStream and protected sources stay in Gecko and support targeted PiP commands', async () => {
  for (const overrides of [
    { currentSrc: 'blob:https://example.test/mse', duration: Infinity },
    { srcObject: {} },
    { mediaKeys: {} },
    { currentSrc: 'file:///private/video.mp4' },
  ]) {
    const f = fixture();
    const selected = f.video(overrides);
    const descriptor = f.actor.getNativeVideo();
    assert.equal(descriptor.url, null);
    assert.equal(descriptor.duration, Number.isFinite(selected.duration) ? 120 : null);
    assert.equal(descriptor.isLive, selected.duration === Infinity);
    await assert.rejects(f.command(descriptor, 'prepare'), /cannot be handed/);
    assert.equal(selected.pauseCalls, 0);
    await f.command(descriptor, 'pause');
    assert.equal((await f.command(descriptor, 'status')).paused, true);
    await f.command(descriptor, 'play');
    assert.equal(selected.paused, false);
    await f.command(descriptor, 'seek', { currentTime: 50 });
    assert.equal(selected.currentTime, 50);
  }
});

test('seeks clamp to real disjoint seekable ranges and release never mutates playback', async () => {
  const f = fixture();
  const selected = f.video({ seekable: { length: 2,
    start: i => [10, 40][i], end: i => [20, 60][i] } });
  const descriptor = f.actor.getNativeVideo();
  await f.command(descriptor, 'seek', { currentTime: 35 });
  assert.equal(selected.currentTime, 40);
  await f.command(descriptor, 'seek', { currentTime: 1 });
  assert.equal(selected.currentTime, 10);
  await assert.rejects(f.command(descriptor, 'seek', { currentTime: NaN }), /Invalid/);
  await f.command(descriptor, 'release');
  assert.equal(selected.pauseCalls, 0);
  assert.equal(selected.playCalls, 0);
  await assert.rejects(f.command(descriptor, 'status'), /changed/);
});

test('skip reads the current target position instead of a stale native snapshot and clamps VOD edges', async () => {
  const f = fixture();
  const selected = f.video({ seekable: { length: 0 } });
  const unrelated = f.video({ paused: true });
  const descriptor = f.actor.getNativeVideo();
  assert.equal(descriptor.currentTime, 12);
  selected.currentTime = 90;
  const skipped = await f.command(descriptor, 'skip', { interval: 10 });
  assert.equal(skipped.currentTime, 100);
  assert.equal(skipped.token, descriptor.token);
  assert.equal(unrelated.currentTime, 12);
  await f.command(descriptor, 'skip', { interval: 100 });
  assert.equal(selected.currentTime, 120);
  await f.command(descriptor, 'skip', { interval: -200 });
  assert.equal(selected.currentTime, 0);
});

test('DVR skips follow actual disjoint seekable ranges and reject changed sources', async () => {
  const f = fixture();
  const selected = f.video({ currentSrc: 'blob:https://example.test/live', duration: Infinity,
    currentTime: 15, seekable: { length: 2,
      start: i => [10, 40][i], end: i => [20, 60][i] } });
  const descriptor = f.actor.getNativeVideo();
  assert.equal(descriptor.isLive, true);
  assert.deepEqual(Array.from(descriptor.seekableRanges, range => [range.start, range.end]), [[10, 20], [40, 60]]);
  await f.command(descriptor, 'skip', { interval: 20 });
  assert.equal(selected.currentTime, 40);
  await f.command(descriptor, 'skip', { interval: 100 });
  assert.equal(selected.currentTime, 60);
  selected.currentSrc = 'blob:https://example.test/replacement';
  await assert.rejects(f.command(descriptor, 'skip', { interval: -10 }), /changed/);
  assert.equal(selected.currentTime, 60);
});

test('unknown duration is not classified as live and invalid skip intervals do not seek', async () => {
  const f = fixture();
  const selected = f.video({ duration: NaN, seekable: { length: 0 } });
  const descriptor = f.actor.getNativeVideo();
  assert.equal(descriptor.duration, null);
  assert.equal(descriptor.isLive, false);
  for (const interval of [NaN, Infinity, -Infinity, '10']) {
    await assert.rejects(f.command(descriptor, 'skip', { interval }), /Invalid video skip/);
    assert.equal(selected.currentTime, 12);
  }
});

test('fullscreen requests use the exact selected element and dispose the content-policy sandbox', async () => {
  const f = fixture();
  const selected = f.video();
  const unrelated = f.video({ paused: true });
  const descriptor = f.actor.getNativeVideo();
  unrelated.paused = false;
  selected.paused = true;
  const result = await f.command(descriptor, 'fullscreen');
  assert.equal(selected.fullscreenCalls, 1);
  assert.equal(unrelated.fullscreenCalls, 0);
  assert.equal(result.token, descriptor.token);
  assert.equal(result.isFullscreen, true);
  assert.equal(f.document.permissionSandboxes.length, 1);
  assert.equal(f.document.permissionSandboxes[0].nuked, true);
});

test('fullscreen fails closed on content policy denial or unreadable policy despite privileged getter access', async () => {
  for (const values of [
    { contentFullscreenEnabled: false },
    { failPermissionEvaluation: true },
  ]) {
    const f = fixture();
    const selected = f.video();
    const descriptor = f.actor.getNativeVideo();
    Object.assign(f.document, values);
    assert.equal(f.document.fullscreenEnabled, true);
    await assert.rejects(f.command(descriptor, 'fullscreen'), /Fullscreen is not permitted/);
    assert.equal(selected.fullscreenCalls, 0);
    assert.equal(f.document.permissionSandboxes[0].nuked, true);
  }
});

test('fullscreen rejects hidden or stale targets and propagates a rejected platform request', async () => {
  const f = fixture();
  const selected = f.video();
  const descriptor = f.actor.getNativeVideo();
  selected.checkVisibility = () => false;
  await assert.rejects(f.command(descriptor, 'fullscreen'), /Fullscreen is not permitted/);
  assert.equal(f.document.permissionSandboxes.length, 0);
  selected.checkVisibility = () => true;
  selected.currentSrc += '?changed';
  await assert.rejects(f.command(descriptor, 'fullscreen'), /changed/);
  assert.equal(selected.fullscreenCalls, 0);
  selected.currentSrc = descriptor.sourceURL;
  selected.requestFullscreen = async () => { throw new Error('Fullscreen rejected'); };
  await assert.rejects(f.command(descriptor, 'fullscreen'), /Fullscreen rejected/);
  assert.equal(f.actor._nativeVideoTarget.token, descriptor.token);
});

test('fullscreen never evaluates its policy gate with a system principal', async () => {
  const f = fixture();
  const selected = f.video();
  const descriptor = f.actor.getNativeVideo();
  f.document.nodePrincipal.isSystemPrincipal = true;
  await assert.rejects(f.command(descriptor, 'fullscreen'), /Fullscreen is not permitted/);
  assert.equal(selected.fullscreenCalls, 0);
  assert.equal(f.document.permissionSandboxes.length, 0);
});

test('fullscreen detects source replacement during the asynchronous platform request', async () => {
  const f = fixture();
  const selected = f.video();
  const descriptor = f.actor.getNativeVideo();
  selected.requestFullscreen = async () => { selected.currentSrc += '?replacement'; };
  await assert.rejects(f.command(descriptor, 'fullscreen'), /changed during playback control/);
});

function context(id, innerWindowId, descriptor, children = []) {
  const context = { id, children };
  context.currentWindowGlobal = { innerWindowId,
    getActor: () => ({ sendQuery: async (name, data) => {
      const video = descriptor && typeof descriptor === 'object' ?
        { isPlaying: false, isFullscreen: !!data?.ancestorFullscreen, visibleVideoCount: 1, ...descriptor } : null;
      return name === 'NativeVideo:Snapshot' ? {
        video: data.select || data.target ? video : null,
        visibleVideoCount: video?.visibleVideoCount ?? 0,
        frames: children.map(child => ({ id: String(child.id), known: true, visible: true,
          clip: { left: 0, top: 0, right: 1000, bottom: 800 },
          ancestorFullscreen: !!data?.ancestorFullscreen })),
      } : descriptor;
    } }) };
  return context;
}
function attach(context, top = context) {
  context.top = top;
  for (const child of context.children) attach(child, top);
  return context;
}
function query(module, method, data) {
  return new Promise((resolve, reject) => {
    const callback = { onSuccess: resolve, onError: error => reject(new Error(error)) };
    if (data) module[method](data, callback); else module[method](callback);
  });
}

function actorContext(f, id, innerWindowId, children = []) {
  const item = { id, children, requests: [] };
  f.window.windowGlobalChild.innerWindowId = innerWindowId;
  f.actor.browsingContext = item;
  item.currentWindowGlobal = { innerWindowId, getActor: () => ({ sendQuery: async (name, data) => {
    item.requests.push({ name, data });
    if (name === 'NativeVideo:Snapshot') return f.actor.nativeVideoSnapshot(data);
    if (name === 'NativeVideo:Command') return f.actor.commandNativeVideo(data);
    throw new Error(`Unexpected actor request: ${name}`);
  } }) };
  Object.defineProperty(item, 'window', { get() { throw new Error('Parent chrome must not access a frame WindowProxy'); } });
  return item;
}

function element(f, overrides = {}) {
  const node = { ownerDocument: f.document, isConnected: true, parentNode: null,
    checkVisibility: () => true,
    contains(other) {
      for (let current = other; current; current = current.parentNode) {
        if (current === this) return true;
      }
      return false;
    },
    getBoundingClientRect: () => ({ left: 0, top: 0, right: 640, bottom: 360 }),
    ...overrides };
  f.document.elements.push(node);
  return node;
}

function embed(f, child, overrides = {}) {
  const frame = element(f, { offsetWidth: 640, offsetHeight: 360,
    clientWidth: 640, clientHeight: 360, clientLeft: 0, clientTop: 0, ...overrides });
  child.embedderElement = frame;
  return frame;
}

function moduleFor(top) {
  const module = new Module();
  module.browser = { browsingContext: attach(top) };
  return module;
}

test('inline video in nested cross-origin frames is discovered without reading frame WindowProxies', async () => {
  const outer = fixture(), middle = fixture(), inner = fixture();
  middle.window.innerWidth = inner.window.innerWidth = 640;
  middle.window.innerHeight = inner.window.innerHeight = 360;
  inner.video({ currentSrc: 'blob:https://remote.test/video' });
  const leaf = actorContext(inner, 3, 33);
  const mid = actorContext(middle, 2, 22, [leaf]);
  const top = actorContext(outer, 1, 11, [mid]);
  embed(outer, mid);
  embed(middle, leaf);
  const descriptor = await query(moduleFor(top), '_getNativeVideo');
  assert.equal(descriptor.browsingContextID, '3');
  assert.equal(descriptor.innerWindowID, '33');
  assert.equal(descriptor.isFullscreen, false);
  assert.equal(descriptor.totalVisibleVideoCount, 1);
  assert.equal(descriptor.visibleArea, 640 * 360);
});

test('ancestor iframe/container fullscreen is inherited and masks background videos and sibling frames', async () => {
  const outer = fixture(), inner = fixture(), background = fixture();
  outer.video();
  inner.video();
  background.video();
  const child = actorContext(inner, 2, 22);
  const sibling = actorContext(background, 3, 33);
  const top = actorContext(outer, 1, 11, [child, sibling]);
  const fullscreen = element(outer);
  embed(outer, child, { parentNode: fullscreen });
  embed(outer, sibling);
  outer.document.fullscreenElement = fullscreen;
  const module = moduleFor(top);
  const descriptor = await query(module, '_getNativeVideo');
  assert.equal(descriptor.browsingContextID, '2');
  assert.equal(inner.document.fullscreenElement, null);
  assert.equal(descriptor.isFullscreen, true);
  assert.equal(descriptor.totalVisibleVideoCount, 1);
  assert.equal(sibling.requests.length, 0);
  const original = inner.actor._nativeVideoTarget;
  const status = await query(module, '_commandNativeVideo', { ...descriptor, command: 'status' });
  assert.equal(status.isFullscreen, true);
  assert.equal(status.totalVisibleVideoCount, 1);
  assert.equal(status.token, descriptor.token);
  assert.equal(inner.actor._nativeVideoTarget, original);
  assert.equal(child.requests.at(-1).data.select, false);
});

test('a fullscreen iframe itself marks its child video fullscreen', async () => {
  const outer = fixture(), inner = fixture();
  inner.video();
  const child = actorContext(inner, 2, 22);
  const top = actorContext(outer, 1, 11, [child]);
  outer.document.fullscreenElement = embed(outer, child);
  const descriptor = await query(moduleFor(top), '_getNativeVideo');
  assert.equal(descriptor.isFullscreen, true);
  assert.equal(descriptor.totalVisibleVideoCount, 1);
});

test('deep shadow fullscreen resolves the actual subtree and excludes sibling shadow videos', () => {
  const f = fixture();
  const selected = f.video();
  const sibling = f.video();
  f.document.elements = [];
  const host = element(f);
  const shadow = { ownerDocument: f.document, host, getRootNode: () => shadow,
    querySelectorAll: () => [fullscreen, selected, sibling] };
  const fullscreen = { ownerDocument: f.document, parentNode: shadow };
  host.openOrClosedShadowRoot = shadow;
  shadow.fullscreenElement = fullscreen;
  selected.parentNode = fullscreen;
  sibling.parentNode = shadow;
  f.document.fullscreenElement = host;
  const descriptor = f.actor.getNativeVideo();
  assert.equal(f.actor._nativeVideoTarget.video.deref(), selected);
  assert.equal(descriptor.isFullscreen, true);
  assert.equal(descriptor.visibleVideoCount, 1);
  assert.equal(f.actor.nativeVideoVisibleArea(sibling), 0);
});

test('partial iframe viewport clipping selects the video portion actually visible in the parent', async () => {
  const outer = fixture(), inner = fixture();
  inner.window.innerWidth = 640;
  inner.window.innerHeight = 360;
  const selected = inner.video();
  inner.video({ getBoundingClientRect: () => ({ left: 0, top: 0, right: 200, bottom: 360 }) });
  const child = actorContext(inner, 2, 22);
  const top = actorContext(outer, 1, 11, [child]);
  embed(outer, child, { getBoundingClientRect: () => ({ left: -300, top: 0, right: 340, bottom: 360 }) });
  const descriptor = await query(moduleFor(top), '_getNativeVideo');
  assert.equal(inner.actor._nativeVideoTarget.video.deref(), selected);
  assert.equal(descriptor.visibleArea, 340 * 360);
  assert.equal(descriptor.totalVisibleVideoCount, 1);
});

test('hidden and offscreen ancestor frames are excluded without querying their documents', async () => {
  for (const overrides of [
    { checkVisibility: () => false },
    { getBoundingClientRect: () => ({ left: 1200, top: 0, right: 1840, bottom: 360 }) },
  ]) {
    const outer = fixture(), middle = fixture(), inner = fixture();
    inner.video();
    const leaf = actorContext(inner, 3, 33);
    const mid = actorContext(middle, 2, 22, [leaf]);
    const top = actorContext(outer, 1, 11, [mid]);
    embed(outer, mid, overrides);
    embed(middle, leaf);
    assert.equal(await query(moduleFor(top), '_getNativeVideo'), null);
    assert.equal(mid.requests.length, 0);
    assert.equal(leaf.requests.length, 0);
  }
});

test('pinch-zoom visual viewport offsets clip embedded videos in layout viewport coordinates', async () => {
  const outer = fixture(), inner = fixture();
  outer.window.visualViewport = { offsetLeft: 100, offsetTop: 20, width: 400, height: 300 };
  inner.video();
  const child = actorContext(inner, 2, 22);
  const top = actorContext(outer, 1, 11, [child]);
  embed(outer, child, { getBoxQuads: () => [{
    p1: { x: 0, y: 0 }, p2: { x: 640, y: 0 },
    p3: { x: 640, y: 360 }, p4: { x: 0, y: 360 },
  }] });
  const descriptor = await query(moduleFor(top), '_getNativeVideo');
  assert.equal(descriptor.visibleArea, 400 * 300);
  assert.equal(descriptor.totalVisibleVideoCount, 1);
  assert.deepEqual({ ...child.requests[0].data.clip }, { left: 100, top: 20, right: 500, bottom: 320 });
});

test('iframe border and axis-aligned scale map parent clipping into child CSS pixels', async () => {
  const outer = fixture(), inner = fixture();
  inner.video();
  const child = actorContext(inner, 2, 22);
  const top = actorContext(outer, 1, 11, [child]);
  embed(outer, child, { offsetWidth: 650, offsetHeight: 370, clientLeft: 5, clientTop: 5,
    getBoundingClientRect: () => ({ left: 10, top: 20, right: 1310, bottom: 760 }) });
  const descriptor = await query(moduleFor(top), '_getNativeVideo');
  assert.equal(descriptor.visibleArea, 490 * 360);
  assert.equal(descriptor.totalVisibleVideoCount, 1);
});

test('unknown rotated iframe geometry preserves a usable local video but marks PiP ambiguous', async () => {
  const outer = fixture(), inner = fixture();
  const selected = outer.video();
  inner.video();
  const child = actorContext(inner, 2, 22);
  const top = actorContext(outer, 1, 11, [child]);
  embed(outer, child, { getBoxQuads: () => [{
    p1: { x: 0, y: 0 }, p2: { x: 600, y: 100 },
    p3: { x: 500, y: 460 }, p4: { x: -100, y: 360 },
  }] });
  const descriptor = await query(moduleFor(top), '_getNativeVideo');
  assert.equal(outer.actor._nativeVideoTarget.video.deref(), selected);
  assert.equal(descriptor.totalVisibleVideoCount, 3);
  assert.equal(child.requests.length, 0);
});

test('overflow clipping propagates from a parent container into an embedded document', async () => {
  const outer = fixture(), inner = fixture();
  inner.video();
  const child = actorContext(inner, 2, 22);
  const top = actorContext(outer, 1, 11, [child]);
  const container = element(outer, { overflowX: 'hidden',
    getBoundingClientRect: () => ({ left: 0, top: 0, right: 200, bottom: 360 }) });
  outer.window.getComputedStyle = node => node;
  embed(outer, child, { parentNode: container });
  const descriptor = await query(moduleFor(top), '_getNativeVideo');
  assert.equal(descriptor.visibleArea, 200 * 360);
});

test('status preserves the original target when another video becomes preferable and detects hidden ancestors', async () => {
  const outer = fixture(), inner = fixture();
  const selected = inner.video({ paused: true });
  const child = actorContext(inner, 2, 22);
  const top = actorContext(outer, 1, 11, [child]);
  const frame = embed(outer, child);
  const module = moduleFor(top);
  const descriptor = await query(module, '_getNativeVideo');
  inner.video({ paused: false });
  const status = await query(module, '_commandNativeVideo', { ...descriptor, command: 'status' });
  assert.equal(status.token, descriptor.token);
  assert.equal(inner.actor._nativeVideoTarget.video.deref(), selected);
  assert.equal(status.totalVisibleVideoCount, 2);
  frame.checkVisibility = () => false;
  await assert.rejects(query(module, '_commandNativeVideo', { ...descriptor, command: 'status' }), /no longer visible/);
  assert.equal(inner.actor._nativeVideoTarget.video.deref(), selected);
});

test('a descendant descriptor is dropped if an ancestor document changes during its query', async () => {
  const outer = fixture(), middle = fixture(), inner = fixture();
  inner.video();
  const leaf = actorContext(inner, 3, 33);
  const mid = actorContext(middle, 2, 22, [leaf]);
  const top = actorContext(outer, 1, 11, [mid]);
  embed(outer, mid);
  embed(middle, leaf);
  const snapshot = inner.actor.nativeVideoSnapshot.bind(inner.actor);
  inner.actor.nativeVideoSnapshot = async data => {
    const result = await snapshot(data);
    mid.currentWindowGlobal = { innerWindowId: 222 };
    return result;
  };
  assert.equal(await query(moduleFor(top), '_getNativeVideo'), null);
});

test('module finds the best video across remote frames and ignores unloaded frames', async () => {
  const child = context(2, 22, { token: 'child', isPlaying: true, visibleArea: 200 });
  const absent = { id: 3, children: [], currentWindowGlobal: null };
  const top = attach(context(1, 11, { token: 'top', visibleArea: 500 }, [child, absent]));
  const module = new Module();
  module.browser = { browsingContext: top };
  const descriptor = await query(module, '_getNativeVideo');
  assert.equal(descriptor.token, 'child');
  assert.equal(descriptor.browsingContextID, '2');
  assert.equal(descriptor.innerWindowID, '22');
});

test('module preserves actor lookup errors when no usable video is found', async () => {
  const child = context(2, 22, null);
  const top = attach(context(1, 11, null, [child]));
  top.currentWindowGlobal.getActor = () => ({ sendQuery: async () => {
    throw new TypeError('missing runtime property');
  } });
  const module = new Module();
  module.browser = { browsingContext: top };
  await assert.rejects(query(module, '_getNativeVideo'),
    /Cannot select video:.*Video lookup failed: Frame 1:.*missing runtime property/);
});

test('a failed frame lookup does not block a usable video in another frame', async () => {
  const child = context(2, 22, { token: 'usable', isPlaying: true, visibleArea: 200 });
  const broken = context(3, 33, null);
  const top = attach(context(1, 11, null, [child, broken]));
  broken.currentWindowGlobal.getActor = () => ({ sendQuery: async () => {
    throw new Error('unloaded frame');
  } });
  const module = new Module();
  module.browser = { browsingContext: top };
  const descriptor = await query(module, '_getNativeVideo');
  assert.equal(descriptor.token, 'usable');
  assert.equal(descriptor.browsingContextID, '2');
});

test('module never routes native control outside this tab or into a replacement document', async () => {
  const child = context(2, 22, true);
  const top = attach(context(1, 11, null, [child]));
  const module = new Module();
  module.browser = { browsingContext: top };
  await assert.rejects(query(module, '_commandNativeVideo', {
    browsingContextID: '999', innerWindowID: '22' }), /no longer available/);
  await assert.rejects(query(module, '_commandNativeVideo', {
    browsingContextID: '2', innerWindowID: '21' }), /no longer available/);
  assert.equal(await query(module, '_commandNativeVideo', {
    browsingContextID: '2', innerWindowID: '22' }), true);
});

test('module drops descriptors from a WindowGlobal replaced during query', async () => {
  const top = attach(context(1, 11, null));
  const oldGlobal = top.currentWindowGlobal;
  oldGlobal.getActor = () => ({ sendQuery: async () => {
    top.currentWindowGlobal = { innerWindowId: 12 };
    return { token: 'stale', isPlaying: true, visibleArea: 100 };
  } });
  const module = new Module();
  module.browser = { browsingContext: top };
  assert.equal(await query(module, '_getNativeVideo'), null);
});

test('module rejects a command result if its document navigates during the request', async () => {
  const top = attach(context(1, 11, null));
  top.currentWindowGlobal.getActor = () => ({ sendQuery: async () => {
    top.currentWindowGlobal = { innerWindowId: 12 };
    return { token: 'stale' };
  } });
  const module = new Module();
  module.browser = { browsingContext: top };
  await assert.rejects(query(module, '_commandNativeVideo', {
    browsingContextID: '1', innerWindowID: '11' }), /changed during control/);
});

test('a visible paused video takes priority over an offscreen playing preview', () => {
  const f = fixture();
  f.video({ getBoundingClientRect: () => ({ left: 0, top: 900, right: 640, bottom: 1260 }) });
  const visible = f.video({ paused: true });
  const descriptor = f.actor.getNativeVideo();
  assert.equal(f.actor._nativeVideoTarget.video.deref(), visible);
  assert.equal(descriptor.visibleVideoCount, 1);
  assert.ok(descriptor.visibleArea > 0);
});

test('status counts visible videos including closed shadow roots without replacing its token', async () => {
  const f = fixture();
  const selected = f.video();
  const shadowVideo = f.video({ paused: true });
  f.document.elements.pop();
  f.document.elements.push({ openOrClosedShadowRoot: {
    querySelectorAll: () => [shadowVideo],
  } });
  const descriptor = f.actor.getNativeVideo();
  assert.equal(descriptor.visibleVideoCount, 2);
  assert.equal(f.actor.nativeVideoVisibleCount(), 2);
  shadowVideo.checkVisibility = () => false;
  const status = await f.command(descriptor, 'status');
  assert.equal(status.token, descriptor.token);
  assert.equal(status.visibleVideoCount, 1);
  assert.equal(f.actor._nativeVideoTarget.video.deref(), selected);
});

test('selection and targeted snapshots share one composed-tree scan and one visible video measurement', async () => {
  const f = fixture();
  const counts = { document: 0, shadow: 0, selected: 0, preview: 0 };
  const selected = f.video({ getBoundingClientRect() {
    counts.selected++;
    return { left: 0, top: 0, right: 640, bottom: 360 };
  } });
  const preview = f.video({ paused: true, getBoundingClientRect() {
    counts.preview++;
    return { left: 0, top: 400, right: 640, bottom: 760 };
  } });
  f.document.elements.pop();
  f.document.elements.push({ openOrClosedShadowRoot: { querySelectorAll() {
    counts.shadow++;
    return [preview];
  } } });
  f.document.querySelectorAll = () => { counts.document++; return f.document.elements; };
  const first = await f.actor.nativeVideoSnapshot({ select: true });
  assert.equal(first.visibleVideoCount, 2);
  assert.equal(first.video.visibleVideoCount, 2);
  assert.equal(f.actor._nativeVideoTarget.video.deref(), selected);
  assert.deepEqual(counts, { document: 1, shadow: 1, selected: 1, preview: 1 });

  for (const key in counts) counts[key] = 0;
  const next = await f.actor.nativeVideoSnapshot({ target: first.video });
  assert.equal(next.video.token, first.video.token);
  assert.equal(next.visibleVideoCount, 2);
  assert.deepEqual(counts, { document: 1, shadow: 1, selected: 1, preview: 1 });
});

test('successive snapshots discover newly attached nested shadow roots and changed visibility immediately', async () => {
  const f = fixture();
  assert.equal((await f.actor.nativeVideoSnapshot({ select: true })).video, null);
  const shadowElements = [];
  f.document.elements.push({ openOrClosedShadowRoot: { querySelectorAll: () => shadowElements } });
  assert.equal((await f.actor.nativeVideoSnapshot({ select: true })).video, null);
  const added = f.video({ paused: true });
  f.document.elements.pop();
  shadowElements.push({ openOrClosedShadowRoot: { querySelectorAll: () => [added] } });
  const found = await f.actor.nativeVideoSnapshot({ select: true });
  assert.equal(found.visibleVideoCount, 1);
  assert.equal(f.actor._nativeVideoTarget.video.deref(), added);

  added.checkVisibility = () => false;
  const hidden = await f.actor.nativeVideoSnapshot({ select: true });
  assert.equal(hidden.video, null);
  assert.equal(hidden.visibleVideoCount, 0);
  added.checkVisibility = () => true;
  assert.equal((await f.actor.nativeVideoSnapshot({ select: true })).visibleVideoCount, 1);
});

test('each snapshot refreshes geometry and overflow clips while skipping non-clipping ancestor bounds', async () => {
  const f = fixture();
  let clipping = false, ancestorBounds = 0;
  const parent = element(f, { getBoundingClientRect() {
    ancestorBounds++;
    return { left: 10, top: 10, right: 100, bottom: 100 };
  } });
  f.window.getComputedStyle = () => ({ overflowX: clipping ? 'hidden' : 'visible',
    overflowY: clipping ? 'hidden' : 'visible' });
  let bounds = { left: 0, top: 0, right: 640, bottom: 360 };
  const selected = f.video({ parentNode: parent, getBoundingClientRect: () => bounds });
  const first = await f.actor.nativeVideoSnapshot({ select: true });
  assert.equal(first.video.visibleArea, 640 * 360);
  assert.equal(ancestorBounds, 0);

  clipping = true;
  const clipped = await f.actor.nativeVideoSnapshot({ target: first.video });
  assert.equal(clipped.video.visibleArea, 90 * 90);
  assert.equal(clipped.video.token, first.video.token);
  assert.equal(ancestorBounds, 1);
  bounds = { left: 200, top: 200, right: 640, bottom: 360 };
  const outside = await f.actor.nativeVideoSnapshot({ target: first.video });
  assert.equal(outside.video.visibleArea, 0);
  assert.equal(outside.visibleVideoCount, 0);
  assert.equal(outside.video.elementRect.x, 200);
  assert.equal(ancestorBounds, 2);

  selected.currentSrc = 'https://example.test/replacement.mp4';
  await assert.rejects(f.actor.nativeVideoSnapshot({ target: first.video }), /changed/);
  clipping = false;
  const replacement = await f.actor.nativeVideoSnapshot({ select: true });
  assert.notEqual(replacement.video.token, first.video.token);
  assert.equal(replacement.video.sourceURL, selected.currentSrc);
  assert.equal(replacement.video.visibleArea, 440 * 160);
  assert.equal(ancestorBounds, 3);
});

test('module prefers a visible frame and includes the global visible video count', async () => {
  const child = context(2, 22, { token: 'visible', isPlaying: false,
    visibleArea: 200, visibleVideoCount: 2 });
  const top = attach(context(1, 11, { token: 'hidden', isPlaying: true,
    visibleArea: 0, visibleVideoCount: 0 }, [child]));
  const module = new Module();
  module.browser = { browsingContext: top };
  const descriptor = await query(module, '_getNativeVideo');
  assert.equal(descriptor.token, 'visible');
  assert.equal(descriptor.totalVisibleVideoCount, 2);
});

test('status aggregates frame visibility without selecting or replacing any target', async () => {
  const child = context(2, 22, null);
  const top = attach(context(1, 11, null, [child]));
  for (const item of [top, child]) {
    item.currentWindowGlobal.getActor = () => ({ sendQuery: async (name, data) => {
      assert.notEqual(name, 'NativeVideo:Get');
      assert.equal(name, 'NativeVideo:Snapshot');
      assert.equal(data.select, false);
      return { video: data.target ? { token: 'original', visibleVideoCount: 1 } : null,
        visibleVideoCount: 1,
        frames: item.children.map(child => ({ id: String(child.id), known: true, visible: true,
          clip: { left: 0, top: 0, right: 1000, bottom: 800 } })),
      };
    } });
  }
  const module = new Module();
  module.browser = { browsingContext: top };
  const status = await query(module, '_commandNativeVideo', {
    browsingContextID: '1', innerWindowID: '11', token: 'original', command: 'status',
  });
  assert.equal(status.token, 'original');
  assert.equal(status.totalVisibleVideoCount, 2);
});


test('inline geometry maps a top-level video into the visual viewport', async () => {
  const f = fixture();
  f.window.visualViewport = { offsetLeft: 100, offsetTop: 40, width: 400, height: 300 };
  f.video({ getBoundingClientRect: () => ({ left: 50, top: 100, right: 450, bottom: 300 }) });
  const top = actorContext(f, 1, 11);
  const descriptor = await query(moduleFor(top), '_getNativeVideo');
  assert.deepEqual({ ...descriptor.visibleRect }, { x: 0, y: 60, width: 350, height: 200 });
  assert.deepEqual({ ...descriptor.elementRect }, { x: -50, y: 60, width: 400, height: 200 });
  assert.equal(descriptor.viewportWidth, 400);
  assert.equal(descriptor.viewportHeight, 300);
});

test('inline geometry composes nested frame positions and scaling into the top viewport', async () => {
  const outer = fixture(), middle = fixture(), inner = fixture();
  middle.window.innerWidth = inner.window.innerWidth = 640;
  middle.window.innerHeight = inner.window.innerHeight = 360;
  inner.video({ getBoundingClientRect: () => ({ left: 20, top: 10, right: 220, bottom: 110 }) });
  const leaf = actorContext(inner, 3, 33);
  const mid = actorContext(middle, 2, 22, [leaf]);
  const top = actorContext(outer, 1, 11, [mid]);
  embed(outer, mid, { getBoundingClientRect: () => ({ left: 100, top: 50, right: 420, bottom: 230 }) });
  embed(middle, leaf, { getBoundingClientRect: () => ({ left: 40, top: 20, right: 680, bottom: 380 }) });
  const descriptor = await query(moduleFor(top), '_getNativeVideo');
  assert.deepEqual({ ...descriptor.visibleRect }, { x: 130, y: 65, width: 100, height: 50 });
  assert.equal(descriptor.viewportWidth, 1000);
  const status = await query(moduleFor(top), '_commandNativeVideo', { ...descriptor, command: 'status' });
  assert.deepEqual({ ...status.visibleRect }, { ...descriptor.visibleRect });
});

test('continuation requires explicit PiP arming and never refreshes an ordinary stale target', async () => {
  const f = fixture();
  const selected = f.video();
  const descriptor = f.actor.getNativeVideo();
  await assert.rejects(f.command(descriptor, 'continue'), /not enabled/);
  selected.currentSrc += '?next';
  await assert.rejects(f.command(descriptor, 'follow', { enabled: true }), /changed/);
  await assert.rejects(f.command(descriptor, 'status'), /changed/);
});

test('same-element autoplay after a trusted end rotates its token and retires old controls', async () => {
  const f = fixture();
  const selected = f.video();
  const descriptor = f.actor.getNativeVideo();
  await f.command(descriptor, 'follow', { enabled: true });
  selected.dispatchEnded();
  selected.currentSrc += '?next';
  selected.ended = false;
  selected.currentTime = 0;
  const next = await f.command(descriptor, 'continue');
  assert.notEqual(next.token, descriptor.token);
  assert.equal(next.currentTime, 0);
  assert.equal(f.actor._nativeVideoTarget.video.deref(), selected);
  await assert.rejects(f.command(descriptor, 'pause'), /changed/);
  await f.command(next, 'pause');
  assert.equal(selected.pauseCalls, 1);
});

test('PiP continuation preserves its owner when another video becomes more attractive', async () => {
  const f = fixture();
  const selected = f.video({ paused: true });
  const descriptor = f.actor.getNativeVideo();
  await f.command(descriptor, 'follow', { enabled: true });
  f.video({ paused: false, getBoundingClientRect: () => ({ left: 0, top: 0, right: 1000, bottom: 800 }) });
  assert.equal(f.actor.getNativeVideo().token, descriptor.token);
  assert.equal((await f.command(descriptor, 'continue')).token, descriptor.token);
  assert.equal(f.actor._nativeVideoTarget.video.deref(), selected);
});

test('mid-video source changes and synthetic ended events do not adopt adverts or previews', async () => {
  for (const synthetic of [false, true]) {
    const f = fixture();
    const selected = f.video();
    const descriptor = f.actor.getNativeVideo();
    await f.command(descriptor, 'follow', { enabled: true });
    if (synthetic) selected.dispatchEnded(false);
    selected.ended = false;
    selected.currentSrc += '?advert';
    assert.equal(await f.command(descriptor, 'continue'), null);
    assert.equal(f.actor._nativeVideoTarget.token, descriptor.token);
    assert.equal(f.actor.getNativeVideo(), null);
  }
});

test('continuation waits through source loading and can follow a unique replacement in the same player', async () => {
  const f = fixture();
  const selected = f.video();
  const descriptor = f.actor.getNativeVideo();
  await f.command(descriptor, 'follow', { enabled: true });
  selected.dispatchEnded();
  selected.isConnected = false;
  assert.equal(await f.command(descriptor, 'continue'), null);
  const nextVideo = f.video({ currentSrc: 'blob:https://example.test/next', readyState: 0 });
  assert.equal(await f.command(descriptor, 'continue'), null);
  nextVideo.readyState = 1;
  const next = await f.command(descriptor, 'continue');
  assert.notEqual(next.token, descriptor.token);
  assert.equal(f.actor._nativeVideoTarget.video.deref(), nextVideo);
});

test('continuation rejects ambiguous replacements and videos from other player containers', async () => {
  for (const ambiguous of [false, true]) {
    const f = fixture();
    const selected = f.video();
    const descriptor = f.actor.getNativeVideo();
    await f.command(descriptor, 'follow', { enabled: true });
    selected.dispatchEnded();
    selected.isConnected = false;
    if (ambiguous) { f.video(); f.video(); }
    else f.video({ parentNode: { ownerDocument: f.document, isConnected: true } });
    assert.equal(await f.command(descriptor, 'continue'), null);
    assert.equal(f.actor._nativeVideoTarget.token, descriptor.token);
  }
});

test('closing PiP disarms source-changed targets and prevents subsequent autoplay reopening', async () => {
  const f = fixture();
  const selected = f.video();
  const descriptor = f.actor.getNativeVideo();
  await f.command(descriptor, 'follow', { enabled: true });
  selected.dispatchEnded();
  selected.currentSrc += '?next';
  selected.ended = false;
  assert.equal(await f.command(descriptor, 'follow', { enabled: false }), null);
  await assert.rejects(f.command(descriptor, 'continue'), /not enabled/);
  selected.dispatchEnded();
  assert.equal(f.actor._nativeVideoTarget.follow, null);
});

test('continuation observes ended state between polls and keeps an unchanged MSE source target', async () => {
  const f = fixture();
  const selected = f.video({ currentSrc: 'blob:https://example.test/mse' });
  const descriptor = f.actor.getNativeVideo();
  await f.command(descriptor, 'follow', { enabled: true });
  selected.ended = true;
  assert.equal((await f.command(descriptor, 'continue')).ended, true);
  selected.ended = false;
  selected.currentTime = 0;
  selected.duration = 900;
  const next = await f.command(descriptor, 'continue');
  assert.equal(next.token, descriptor.token);
  assert.equal(next.duration, 900);
});

test('continuation works in an offscreen owning frame while rejecting a navigated document', async () => {
  const outer = fixture(), inner = fixture();
  inner.video();
  const child = actorContext(inner, 2, 22);
  const top = actorContext(outer, 1, 11, [child]);
  const frame = embed(outer, child);
  const module = moduleFor(top);
  const descriptor = await query(module, '_getNativeVideo');
  await query(module, '_commandNativeVideo', { ...descriptor, command: 'follow', enabled: true });
  frame.checkVisibility = () => false;
  const status = await query(module, '_commandNativeVideo', { ...descriptor, command: 'continue' });
  assert.equal(status.token, descriptor.token);
  assert.equal(status.visibleRect, null);
  assert.equal(status.totalVisibleVideoCount, 0);
  child.currentWindowGlobal = { innerWindowId: 222 };
  await assert.rejects(query(module, '_commandNativeVideo', { ...descriptor, command: 'continue' }), /no longer available/);
});


test('a hidden owner continuation cannot cross to another tab after a tree reparent', async () => {
  const f = fixture();
  f.video();
  const top = actorContext(f, 1, 11);
  const module = moduleFor(top);
  const descriptor = await query(module, '_getNativeVideo');
  await query(module, '_commandNativeVideo', { ...descriptor, command: 'follow', enabled: true });
  const original = f.actor.commandNativeVideo.bind(f.actor);
  f.actor.commandNativeVideo = async data => {
    const value = await original(data);
    top.top = { id: 99 };
    return value;
  };
  await assert.rejects(query(module, '_commandNativeVideo', { ...descriptor, command: 'continue' }), /changed during control/);
});

test('a stale release cannot disable a retokened autoplay owner', async () => {
  const f = fixture();
  const selected = f.video();
  const descriptor = f.actor.getNativeVideo();
  await f.command(descriptor, 'follow', { enabled: true });
  selected.dispatchEnded();
  selected.currentSrc += '?next';
  selected.ended = false;
  const next = await f.command(descriptor, 'continue');
  await assert.rejects(f.command(descriptor, 'release'), /changed/);
  assert.equal((await f.command(next, 'continue')).token, next.token);
  assert.ok(f.actor._nativeVideoTarget.follow);
});

test('continuation cancellation retains the exact context and inner-window identity gate', async () => {
  const f = fixture();
  f.video();
  const descriptor = f.actor.getNativeVideo();
  await f.command(descriptor, 'follow', { enabled: true });
  await assert.rejects(f.command({ ...descriptor, innerWindowID: 'stale' }, 'follow', { enabled: false }), /changed/);
  await assert.rejects(f.command({ ...descriptor, browsingContextID: 'other-tab' }, 'follow', { enabled: false }), /changed/);
  assert.ok(f.actor._nativeVideoTarget.follow);
  await f.command(descriptor, 'follow', { enabled: false });
  assert.equal(f.actor._nativeVideoTarget.follow, null);
});


test('a lost autoplay callback recovers its current token through the same follow lease', async () => {
  const f = fixture();
  const selected = f.video();
  const original = f.actor.getNativeVideo();
  await f.command(original, 'follow', { enabled: true });
  selected.dispatchEnded();
  selected.currentSrc += '?next';
  selected.ended = false;
  // The actor adopted the successor but the native caller timed out before
  // receiving this response. The caller still holds only the original token.
  const lostResponse = await f.command(original, 'continue');
  assert.notEqual(lostResponse.token, original.token);
  const recovered = await f.command(original, 'continue');
  assert.equal(recovered.token, lostResponse.token);
  assert.equal(f.actor._nativeVideoTarget.video.deref(), selected);
  await assert.rejects(f.command(original, 'pause'), /changed/);
  await assert.rejects(f.command(original, 'status'), /changed/);
  await assert.rejects(f.command(original, 'release'), /changed/);
  await assert.rejects(f.command(original, 'follow', { enabled: true }), /changed/);
  await f.command(original, 'follow', { enabled: false });
  assert.equal(f.actor._nativeVideoTarget.follow, null);
  await assert.rejects(f.command(original, 'continue'), /changed/);
});

test('fresh manual PiP arming retires every old continuation alias', async () => {
  const f = fixture();
  const selected = f.video();
  const original = f.actor.getNativeVideo();
  await f.command(original, 'follow', { enabled: true });
  selected.dispatchEnded();
  selected.currentSrc += '?next';
  selected.ended = false;
  const next = await f.command(original, 'continue');
  await f.command(next, 'follow', { enabled: false });
  await f.command(next, 'follow', { enabled: true });
  await assert.rejects(f.command(original, 'continue'), /changed/);
  await assert.rejects(f.command(original, 'follow', { enabled: false }), /changed/);
  assert.equal((await f.command(next, 'continue')).token, next.token);
  assert.ok(f.actor._nativeVideoTarget.follow);
});

test('continuation aliases preserve context and document checks after a lost response', async () => {
  const f = fixture();
  const selected = f.video();
  const original = f.actor.getNativeVideo();
  await f.command(original, 'follow', { enabled: true });
  selected.dispatchEnded();
  selected.currentSrc += '?next';
  selected.ended = false;
  await f.command(original, 'continue');
  for (const identity of [
    { ...original, browsingContextID: 'other-tab' },
    { ...original, innerWindowID: 'replaced-document' },
  ]) {
    await assert.rejects(f.command(identity, 'continue'), /changed/);
    await assert.rejects(f.command(identity, 'follow', { enabled: false }), /changed/);
  }
  assert.ok(f.actor._nativeVideoTarget.follow);
});

test('continuation keeps at most 64 previous token aliases per active lease', async () => {
  const f = fixture();
  const selected = f.video();
  const original = f.actor.getNativeVideo();
  await f.command(original, 'follow', { enabled: true });
  const descriptors = [original];
  for (let index = 0; index < 65; index++) {
    selected.dispatchEnded();
    selected.currentSrc = `https://example.test/video-${index}.mp4`;
    selected.ended = false;
    descriptors.push(await f.command(descriptors.at(-1), 'continue'));
  }
  assert.equal(f.actor._nativeVideoTarget.follow.aliases.length, 64);
  await assert.rejects(f.command(original, 'continue'), /changed/);
  await assert.rejects(f.command(original, 'follow', { enabled: false }), /changed/);
  assert.equal((await f.command(descriptors[1], 'continue')).token, descriptors.at(-1).token);
  await f.command(descriptors[1], 'follow', { enabled: false });
  assert.equal(f.actor._nativeVideoTarget.follow, null);
});

test('a callback stalled after actor retokening can recover and cancel through the original lease token', async () => {
  const f = fixture();
  const selected = f.video();
  const top = actorContext(f, 1, 11);
  const module = moduleFor(top);
  const original = await query(module, '_getNativeVideo');
  await query(module, '_commandNativeVideo', { ...original, command: 'follow', enabled: true });
  selected.dispatchEnded();
  selected.currentSrc += '?next';
  selected.ended = false;
  let beginAnnotation, finishAnnotation;
  const annotationStarted = new Promise(resolve => { beginAnnotation = resolve; });
  const annotationGate = new Promise(resolve => { finishAnnotation = resolve; });
  const snapshot = module._nativeVideoSnapshot.bind(module);
  let stalled = false;
  module._nativeVideoSnapshot = async (...arguments_) => {
    if (!stalled) {
      stalled = true;
      beginAnnotation();
      await annotationGate;
    }
    return snapshot(...arguments_);
  };
  const delayed = query(module, '_commandNativeVideo', { ...original, command: 'continue' });
  await annotationStarted;
  const actorToken = f.actor._nativeVideoTarget.token;
  assert.notEqual(actorToken, original.token);
  // Native callback timeout leaves only the original token available, while
  // the first command is still waiting for unrelated frame geometry.
  const recovered = await query(module, '_commandNativeVideo', { ...original, command: 'continue' });
  assert.equal(recovered.token, actorToken);
  assert.equal(recovered.totalVisibleVideoCount, 1);
  await query(module, '_commandNativeVideo', { ...original, command: 'follow', enabled: false });
  assert.equal(f.actor._nativeVideoTarget.follow, null);
  finishAnnotation();
  assert.equal((await delayed).token, actorToken);
  assert.equal(f.actor._nativeVideoTarget.follow, null);
});


test('metadata-only autoplay successors preserve readiness until current and future frames arrive', async () => {
  const f = fixture();
  const selected = f.video();
  const original = f.actor.getNativeVideo();
  assert.equal(original.readyState, 4);
  await f.command(original, 'follow', { enabled: true });
  selected.dispatchEnded();
  selected.currentSrc += '?next';
  selected.ended = false;
  selected.readyState = 0;
  assert.equal(await f.command(original, 'continue'), null);
  // Metadata is enough to retain the successor target, but must remain
  // distinguishable from actual decoded data when native code budgets time.
  selected.readyState = 1;
  const metadata = await f.command(original, 'continue');
  assert.notEqual(metadata.token, original.token);
  assert.equal(metadata.readyState, 1);
  selected.readyState = 2;
  const currentData = await f.command(metadata, 'continue');
  assert.equal(currentData.token, metadata.token);
  assert.equal(currentData.readyState, 2);
  selected.readyState = 3;
  const futureData = await f.command(currentData, 'continue');
  assert.equal(futureData.token, metadata.token);
  assert.equal(futureData.readyState, 3);
});
