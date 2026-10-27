// Run with Node.js 22+: node tests/native-video-discovery-benchmark.mjs [actor-patch]
// To compare revisions, save the older actor patch and pass its path explicitly.
// Operation counts are deterministic. Elapsed host time is only a rough check:
// this synthetic fixture has no Gecko layout, rendering or iPhone FPS measurement.
import { readFileSync } from 'node:fs';
import { performance } from 'node:perf_hooks';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const patchPath = process.argv[2] ? resolve(process.argv[2]) : fileURLToPath(new URL(
  '../patches/mobile/shared/actors/GeckoViewContentChild.sys.mjs.patch', import.meta.url));
const additions = readFileSync(patchPath, 'utf8').split('\n')
  .filter(line => (line.startsWith('+') && !line.startsWith('+++')) || line.startsWith(' '))
  .map(line => line.slice(1)).join('\n');
const start = additions.indexOf('  nativeVideoViewport()');
const end = additions.indexOf('  getFocusedInputBounds(');
if (start < 0 || end < start) throw new Error('Native video actor methods were not found');
let uuid = 0;
const Actor = vm.runInNewContext(`class Actor { ${additions.slice(start, end)} }; Actor`, {
  URL, WeakRef, Services: { uuid: { generateUUID: () => `benchmark-${++uuid}` } },
});

function fixture(videoCount) {
  const counts = { queries: 0, visited: 0, videoRects: 0, ancestorRects: 0, styles: 0 };
  const document = { title: 'Synthetic benchmark', fullscreenElement: null };
  const window = { innerWidth: 1000, innerHeight: 800,
    windowGlobalChild: { innerWindowId: 99 }, navigator: { userAgent: 'Synthetic fixture' },
    HTMLVideoElement: { isInstance: node => !!node.isVideo },
    getComputedStyle() {
      counts.styles++;
      return { overflowX: 'visible', overflowY: 'visible', display: 'block',
        visibility: 'visible', opacity: '1' };
    },
  };
  document.defaultView = window;
  window.document = document;
  const actor = new Actor();
  Object.assign(actor, { document, contentWindow: window, browsingContext: { id: 42, children: [] } });
  let parent = null;
  for (let index = 0; index < 8; index++) {
    parent = { ownerDocument: document, parentNode: parent, getBoundingClientRect() {
      counts.ancestorRects++;
      return { left: 0, top: 0, right: 1000, bottom: 800 };
    } };
  }
  const nodes = Array.from({ length: 12000 }, () => ({}));
  for (let index = 0; index < videoCount; index++) {
    nodes.push({ isVideo: true, isConnected: true, ownerDocument: document, parentNode: parent,
      readyState: 4, videoWidth: 640, videoHeight: 360,
      currentSrc: `https://example.test/${index}.mp4`, getAttribute: () => '/video.mp4',
      currentTime: 12, duration: 120, paused: index > 0, ended: false,
      playbackRate: 1, muted: false, volume: 1,
      seekable: { length: 1, start: () => 0, end: () => 120 }, checkVisibility: () => true,
      getBoundingClientRect() {
        counts.videoRects++;
        return { left: 0, top: index * 100, right: 640, bottom: 360 + index * 100 };
      },
    });
  }
  document.querySelectorAll = () => { counts.queries++; counts.visited += nodes.length; return nodes; };
  return { actor, counts };
}

async function run(name, videoCount, status = false) {
  const { actor, counts } = fixture(videoCount);
  const data = status ? { target: { ...actor.getNativeVideo() } } : { select: true };
  const warmupIterations = 30;
  const iterations = 500;
  for (let index = 0; index < warmupIterations; index++) await actor.nativeVideoSnapshot(data);
  for (const key in counts) counts[key] = 0;
  const start = performance.now();
  for (let index = 0; index < iterations; index++) await actor.nativeVideoSnapshot(data);
  return { name, iterations, elapsedMs: Math.round((performance.now() - start) * 100) / 100,
    perSnapshot: Object.fromEntries(Object.entries(counts).map(([key, value]) => [key, value / iterations])) };
}

console.log(JSON.stringify({
  fixture: 'Synthetic Node host fixture; not Gecko layout or iPhone FPS',
  nodeVersion: process.version, patchPath,
  nodesPerDocument: 12000, nonClippingAncestorsPerVideo: 8,
  cases: [await run('no-video', 0), await run('discovery-3-videos', 3), await run('status-1-video', 1, true)],
}, null, 2));
