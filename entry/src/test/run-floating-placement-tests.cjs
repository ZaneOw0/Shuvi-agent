// Tests the production placement model on the host; does not simulate ArkUI gestures.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { test } = require('node:test');

if (!process.env.DEVECO_SDK_HOME) {
  throw new Error('Set DEVECO_SDK_HOME to the DevEco Studio sdk directory.');
}
const ts = require(path.join(process.env.DEVECO_SDK_HOME,
  'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const project = path.resolve(__dirname, '../../..');
const output = path.join(project, '.cache/floating-placement/FloatingAssistantPlacement.js');
const source = fs.readFileSync(path.join(project,
  'entry/src/main/ets/model/FloatingAssistantPlacement.ets'), 'utf8');
const result = ts.transpileModule(source, {
  fileName: 'FloatingAssistantPlacement.ts',
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
});
fs.mkdirSync(path.dirname(output), { recursive: true });
fs.writeFileSync(output, result.outputText);
const { FloatingAssistantPlacement } = require(output);

function placement() {
  const p = new FloatingAssistantPlacement();
  p.resize(400, 800, 68);
  return p;
}

test('初次测量后默认停在右下角，测量前不显示', () => {
  const p = new FloatingAssistantPlacement();
  assert.equal(p.canPlace, false);
  p.resize(400, 800, 68);
  assert.equal(p.canPlace, true);
  assert.deepEqual([p.x, p.y], [320, 720]);
});

test('连续位移以起点为基准，左右分别吸边，松手保留高度', () => {
  const p = placement();
  p.beginDrag();
  p.moveDrag(-100, -100);
  p.moveDrag(-260, -320);
  assert.deepEqual([p.x, p.y], [60, 400]);
  p.finishDrag();
  assert.deepEqual([p.x, p.y], [20, 400]);
  p.beginDrag();
  p.moveDrag(250, 0);
  p.finishDrag();
  assert.deepEqual([p.x, p.y], [320, 400]);
});

test('越界拖动被限制在导航下方与四周边距内', () => {
  const p = placement();
  p.beginDrag();
  p.moveDrag(-10000, -10000);
  assert.deepEqual([p.x, p.y], [20, 80]);
  p.moveDrag(10000, 10000);
  assert.deepEqual([p.x, p.y], [320, 720]);
});

test('窗口缩放、导航高度变化后保留吸附侧和纵向比例', () => {
  const p = placement();
  p.beginDrag();
  p.moveDrag(-260, -320);
  p.finishDrag();
  p.resize(800, 400, 68);
  assert.deepEqual([p.x, p.y], [20, 200]);
  p.resize(400, 800, 148);
  assert.deepEqual([p.x, p.y], [20, 440]);
});

test('拖动取消恢复之前的位置，迟到的更新与松手无效', () => {
  const p = placement();
  p.beginDrag();
  p.moveDrag(-260, -320);
  p.finishDrag();
  p.beginDrag();
  p.moveDrag(300, 100);
  p.cancelDrag();
  p.moveDrag(300, 200);
  p.finishDrag();
  assert.deepEqual([p.x, p.y], [20, 400]);
  assert.equal(p.dragging, false);
});

test('拖动中窗口改变会取消旧手势，同尺寸通知不取消手势', () => {
  const p = placement();
  p.beginDrag();
  p.resize(400, 800, 68);
  assert.equal(p.dragging, true);
  p.moveDrag(-260, -320);
  p.resize(800, 400, 68);
  assert.equal(p.dragging, false);
  p.moveDrag(-500, -500);
  p.finishDrag();
  assert.deepEqual([p.x, p.y], [720, 320]);
});

test('空间不足隐藏，恢复窗口后找回位置；零纵向空间不会丢失比例', () => {
  const p = placement();
  p.beginDrag();
  p.moveDrag(-260, -320);
  p.finishDrag();
  p.resize(90, 120, 68);
  assert.equal(p.canPlace, false);
  p.beginDrag();
  assert.equal(p.dragging, false);
  p.resize(100, 160, 68);
  assert.equal(p.canPlace, true);
  p.beginDrag();
  p.finishDrag();
  p.resize(400, 800, 68);
  assert.deepEqual([p.x, p.y], [20, 400]);
});

test('非法测量与位移不会产生非有限坐标', () => {
  const p = placement();
  p.resize(NaN, 0, 0);
  p.resize(400, -1, 68);
  p.beginDrag();
  p.moveDrag(Infinity, NaN);
  assert.deepEqual([p.x, p.y], [320, 720]);
  p.finishDrag();
});

test('多组窗口与拖动方向均不越界，松手一定落在左右边缘', () => {
  for (const width of [100, 320, 400, 800]) {
    for (const height of [200, 400, 800]) {
      for (const dx of [-1000, -80, 0, 160, 1000]) {
        for (const dy of [-1000, -100, 0, 200, 1000]) {
          const p = new FloatingAssistantPlacement();
          p.resize(width, height, 68);
          p.beginDrag();
          p.moveDrag(dx, dy);
          assert.ok(p.x >= 20 && p.x <= width - 80);
          assert.ok(p.y >= 80 && p.y <= height - 80);
          p.finishDrag();
          assert.ok(p.x === 20 || p.x === width - 80);
          assert.ok(p.y >= 80 && p.y <= height - 80);
        }
      }
    }
  }
});
