const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '..', 'wallpaperengine-cli.swift'), 'utf8');
const renderScaleMatch = source.match(/private static func liveRenderScaleScript\(percent: Int\)[\s\S]*?source: """([\s\S]*?)"""/);
assert.ok(renderScaleMatch, 'live Web render-scale script exists');
const scaleScript = renderScaleMatch[1].replaceAll('\\(scale)', '75');
const scaledWindow = { devicePixelRatio: 2 };
vm.runInNewContext(scaleScript, { window: scaledWindow, Object });
assert.equal(scaledWindow.devicePixelRatio, 1.5, '75% scale must reduce a 2x canvas to 1.5x');

const match = source.match(/private static func liveFrameRateScript\(fps: Int\)[\s\S]*?source: """([\s\S]*?)"""/);
assert.ok(match, 'live Web frame-rate script exists');
const script = match[1].replaceAll('\\(limit)', '60');

let nativeQueue = [];
let nextNativeId = 1;
const window = {
  requestAnimationFrame(callback) {
    nativeQueue.push(callback);
    return nextNativeId++;
  }
};
vm.runInNewContext(script, { window, Map, Array, TypeError, setTimeout });

function tick(timestamp) {
  const callbacks = nativeQueue;
  nativeQueue = [];
  for (const callback of callbacks) callback(timestamp);
}

let canceledRan = false;
const canceledId = window.requestAnimationFrame(() => { canceledRan = true; });
window.cancelAnimationFrame(canceledId);
tick(0);
assert.equal(canceledRan, false, 'cancelAnimationFrame must cancel a queued callback');

let delivered = 0;
let lastTimestamp = -1;
function animate(timestamp) {
  assert.ok(timestamp >= lastTimestamp, 'timestamps must stay monotonic');
  lastTimestamp = timestamp;
  delivered++;
  window.requestAnimationFrame(animate);
}
window.requestAnimationFrame(animate);
for (let frame = 1; frame <= 144; frame++) tick(frame * 1000 / 144);
assert.ok(delivered >= 58 && delivered <= 62, `expected about 60 frames, got ${delivered}`);

const beforeStall = delivered;
tick(2000);
assert.equal(delivered, beforeStall + 1, 'a long stall must not burst queued frames');

let canceledInSameFrame = false;
let secondId;
window.requestAnimationFrame(() => window.cancelAnimationFrame(secondId));
secondId = window.requestAnimationFrame(() => { canceledInSameFrame = true; });
tick(2000 + 1000 / 60);
assert.equal(canceledInSameFrame, false, 'cancel during a frame must remove a later callback');

console.log(`Web frame-rate shim passed: ${beforeStall} callbacks from 144 display frames`);
