import { describe, it, expect, afterEach } from '@ohos/hypium';
import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { AgentTaskStatus } from '@harmony_agent/agent-contracts';
import {
  AgentFrontendAuthorizationPrompt, AgentFrontendCommandReceipt, AgentFrontendEventListener,
  AgentFrontendSubscription, AgentFrontendTaskHandle, AgentFrontendTaskRequest, AgentFrontendTaskState
} from '@harmony_agent/agent-runtime';
import { VisionImagePreparer } from '../../../main/ets/services/model/VisionImagePreparer';
import { VisionImageFailure, VisionPreparedImage } from '../../../main/ets/services/model/VisionImagePorts';
import { RuntimeVisionSession } from '../../../main/ets/services/model/RuntimeVisionSession';
import { ShuviRuntimeState } from '../../../main/ets/services/model/ShuviRuntimeController';
import { ShuviRuntimeSessionFactory, ShuviRuntimeSessionPort } from '../../../main/ets/services/model/ShuviRuntimeSession';

// 1x1 PNG, synthetic fixture; no user content.
const PNG_BYTES: Uint8Array = new Uint8Array([
  137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1,
  8, 4, 0, 0, 0, 181, 28, 12, 2, 0, 0, 0, 11, 73, 68, 65, 84, 120, 218, 99, 252, 255, 31,
  0, 3, 3, 2, 0, 239, 163, 87, 89, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130
]);
const FIXTURES: string[] = ['vision-device-1x1.png', 'vision-device-invalid.png', 'vision-device-solid.jpg',
  'vision-device-solid.webp', 'vision-device-transparent.png', 'vision-device-exif6.jpg',
  'vision-device-2048-solid.png', 'vision-device-2048-noise.png'];

function filesDir(): string {
  return abilityDelegatorRegistry.getAbilityDelegator().getAppContext().filesDir;
}
function testContext() {
  return abilityDelegatorRegistry.getAbilityDelegator().getAppContext()
    .getApplicationContext().createModuleContext('entry_test');
}
function rawFixture(name: string): Uint8Array {
  return testContext().resourceManager.getRawFileContentSync('vision/' + name);
}
async function writeFixture(name: string, bytes: Uint8Array): Promise<string> {
  const path: string = filesDir() + '/' + name;
  try { await fileIo.unlink(path); } catch { /* first run */ }
  const file: fileIo.File = await fileIo.open(path,
    fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.NOFOLLOW);
  try {
    const written: number = await fileIo.write(file.fd, bytes.buffer);
    if (written !== bytes.length) { throw new Error('fixture write incomplete'); }
    await fileIo.fsync(file.fd);
  } finally { await fileIo.close(file); }
  return path;
}
async function cleanup(name: string): Promise<void> {
  try { await fileIo.unlink(filesDir() + '/' + name); } catch { /* absent */ }
}
async function decodePixels(bytes: Uint8Array): Promise<image.PixelMap> {
  const source: image.ImageSource = image.createImageSource(bytes.slice().buffer);
  try {
    const options: image.DecodingOptions = {
      desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
      desiredDynamicRange: image.DecodingDynamicRange.SDR, index: 0, sampleSize: 1, rotate: 0, editable: false
    };
    return await source.createPixelMap(options);
  } finally { await source.release(); }
}
async function rgba(pixel: image.PixelMap): Promise<Uint8Array> {
  const info: image.ImageInfo = await pixel.getImageInfo();
  const buffer: ArrayBuffer = new ArrayBuffer(info.size.width * info.size.height * 4);
  await pixel.readPixelsToBuffer(buffer);
  return new Uint8Array(buffer);
}
function sample(data: Uint8Array, width: number, x: number, y: number): number[] {
  const at: number = (y * width + x) * 4;
  return [data[at], data[at + 1], data[at + 2], data[at + 3]];
}
async function packPixels(width: number, height: number, noise: boolean): Promise<Uint8Array> {
  const pixels: ArrayBuffer = new ArrayBuffer(width * height * 4);
  const data: Uint8Array = new Uint8Array(pixels);
  let seed: number = 17;
  for (let at: number = 0; at < data.length; at += 4) {
    if (noise) {
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      data[at] = seed >>> 24; seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      data[at + 1] = seed >>> 24; seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      data[at + 2] = seed >>> 24;
    } else {
      data[at] = 10; data[at + 1] = 20; data[at + 2] = 30;
    }
    data[at + 3] = 255;
  }
  const size: image.Size = { width: width, height: height };
  const init: image.InitializationOptions = {
    size: size, pixelFormat: image.PixelMapFormat.RGBA_8888, editable: false
  };
  const pixel: image.PixelMap = await image.createPixelMapFromPixels(pixels, init);
  const packer: image.ImagePacker = image.createImagePacker();
  try {
    const options: image.PackingOption = { format: 'image/png', quality: 100 };
    return new Uint8Array(await packer.packToData(pixel, options));
  } finally {
    try { await pixel.release(); } finally { await packer.release(); }
  }
}

class FakeCalls {
  start: number = 0; stop: number = 0; submit: number = 0;
  authorize: number = 0; cancel: number = 0; getTask: number = 0; subscribe: number = 0;
}
class FakeSubscription implements AgentFrontendSubscription {
  private closed: boolean = false;
  close(): void { this.closed = true; }
  isClosed(): boolean { return this.closed; }
}
class FakeVisionRuntimeSession implements ShuviRuntimeSessionPort {
  readonly calls: FakeCalls = new FakeCalls();
  private readonly status: AgentTaskStatus;
  constructor(status: AgentTaskStatus) { this.status = status; }
  async start(key: Uint8Array): Promise<void> { this.calls.start++; key.fill(0); }
  async stop(): Promise<void> { this.calls.stop++; }
  async submit(_request: AgentFrontendTaskRequest): Promise<AgentFrontendTaskHandle> {
    this.calls.submit++;
    const handle: AgentFrontendTaskHandle = new AgentFrontendTaskHandle();
    handle.taskId = 'vision-task-' + this.calls.submit; return handle;
  }
  async authorize(_prompt: AgentFrontendAuthorizationPrompt, _approved: boolean): Promise<AgentFrontendCommandReceipt> {
    this.calls.authorize++;
    const receipt: AgentFrontendCommandReceipt = new AgentFrontendCommandReceipt(); receipt.accepted = true; return receipt;
  }
  async cancel(_taskId: string): Promise<AgentFrontendCommandReceipt> {
    this.calls.cancel++;
    const receipt: AgentFrontendCommandReceipt = new AgentFrontendCommandReceipt(); receipt.accepted = true; return receipt;
  }
  async getTask(taskId: string): Promise<AgentFrontendTaskState> {
    this.calls.getTask++;
    const state: AgentFrontendTaskState = new AgentFrontendTaskState();
    state.taskId = taskId; state.status = this.status;
    state.resultJson = this.status === AgentTaskStatus.COMPLETED ?
      '{"schemaVersion":"1.0","kind":"knowledgeAnswer","text":"图中写着 Runtime [1]",' +
        '"citationIds":[1],"inputTokens":1,"outputTokens":1}' : '{}';
    return state;
  }
  async subscribe(_taskId: string, _listener: AgentFrontendEventListener,
    _afterSequence: number): Promise<AgentFrontendSubscription> {
    this.calls.subscribe++; return new FakeSubscription();
  }
}
class FakeVisionRuntimeFactory implements ShuviRuntimeSessionFactory {
  private readonly session: ShuviRuntimeSessionPort;
  constructor(session: ShuviRuntimeSessionPort) { this.session = session; }
  create(): ShuviRuntimeSessionPort { return this.session; }
}

class StartedFakeSession {
  ui: RuntimeVisionSession;
  fake: FakeVisionRuntimeSession;
  path: string;
  constructor(ui: RuntimeVisionSession, fake: FakeVisionRuntimeSession, path: string) {
    this.ui = ui; this.fake = fake; this.path = path;
  }
}
async function startedFakeSession(status: AgentTaskStatus): Promise<StartedFakeSession> {
  const fake: FakeVisionRuntimeSession = new FakeVisionRuntimeSession(status);
  const ui: RuntimeVisionSession = new RuntimeVisionSession(new VisionImagePreparer());
  ui.onForeground();
  const path: string = await writeFixture('vision-device-1x1.png', PNG_BYTES);
  expect(await ui.attachImage('file://' + path, 'vision-device-1x1.png')).assertTrue();
  const key: Uint8Array = new Uint8Array([116, 101, 115, 116, 45, 107, 101, 121]);
  await ui.start(new FakeVisionRuntimeFactory(fake), key, true);
  expect(ui.snapshot().lifecycle).assertEqual(ShuviRuntimeState.READY);
  expect(key.every((value: number): boolean => value === 0)).assertTrue();
  return new StartedFakeSession(ui, fake, path);
}

afterEach(async (): Promise<void> => {
  for (const name of FIXTURES) { await cleanup(name); }
});

export default function visionDeviceTest(): void {
  describe('VisionDeviceTest', () => {
    it('preparesSyntheticPngWithImageKit', 0, async (): Promise<void> => {
      const path: string = await writeFixture('vision-device-1x1.png', PNG_BYTES);
      const prepared: VisionPreparedImage =
        await new VisionImagePreparer().prepare('file://' + path, 'vision-device-1x1.png');
      expect(prepared.image.mime).assertEqual('image/png');
      expect(prepared.image.width).assertEqual(1);
      expect(prepared.image.height).assertEqual(1);
      expect(prepared.image.bytes.length > 0).assertTrue();
      expect(prepared.image.sha256.length).assertEqual(64);
      expect(prepared.displayName).assertEqual('vision-device-1x1.png');
    });

    it('preparesJpegAndWebpFixtures', 0, async (): Promise<void> => {
      const jpeg: Uint8Array = rawFixture('solid.jpg');
      const jpegPath: string = await writeFixture('vision-device-solid.jpg', jpeg);
      const preparedJpeg: VisionPreparedImage =
        await new VisionImagePreparer().prepare('file://' + jpegPath, 'vision-device-solid.jpg');
      expect(preparedJpeg.image.mime).assertEqual('image/jpeg');
      expect(preparedJpeg.image.width).assertEqual(64);
      expect(preparedJpeg.image.height).assertEqual(64);

      const webp: Uint8Array = rawFixture('solid.webp');
      const webpPath: string = await writeFixture('vision-device-solid.webp', webp);
      const preparedWebp: VisionPreparedImage =
        await new VisionImagePreparer().prepare('file://' + webpPath, 'vision-device-solid.webp');
      expect(preparedWebp.image.mime).assertEqual('image/webp');
      expect(preparedWebp.image.width).assertEqual(64);
      expect(preparedWebp.image.height).assertEqual(64);
    });

    it('preservesTransparentPngAlpha', 0, async (): Promise<void> => {
      const source: Uint8Array = rawFixture('transparent.png');
      const path: string = await writeFixture('vision-device-transparent.png', source);
      const prepared: VisionPreparedImage =
        await new VisionImagePreparer().prepare('file://' + path, 'vision-device-transparent.png');
      expect(prepared.image.mime).assertEqual('image/png');
      const pixel: image.PixelMap = await decodePixels(prepared.image.bytes);
      try {
        const info: image.ImageInfo = await pixel.getImageInfo();
        expect(info.size.width).assertEqual(64); expect(info.size.height).assertEqual(64);
        const data: Uint8Array = await rgba(pixel);
        expect(sample(data, info.size.width, 1, 1)[3]).assertEqual(0);
        expect(sample(data, info.size.width, 62, 1)[3]).assertEqual(255);
      } finally { await pixel.release(); }
    });

    it('appliesExifOrientationBeforeEncoding', 0, async (): Promise<void> => {
      const source: Uint8Array = rawFixture('exif6.jpg');
      const path: string = await writeFixture('vision-device-exif6.jpg', source);
      const prepared: VisionPreparedImage =
        await new VisionImagePreparer().prepare('file://' + path, 'vision-device-exif6.jpg');
      const pixel: image.PixelMap = await decodePixels(prepared.image.bytes);
      try {
        const info: image.ImageInfo = await pixel.getImageInfo();
        expect(info.size.width).assertEqual(4); expect(info.size.height).assertEqual(8);
        const data: Uint8Array = await rgba(pixel);
        const top: number[] = sample(data, info.size.width, 1, 1);
        const bottom: number[] = sample(data, info.size.width, 1, 6);
        expect(top[0] > 150 && top[2] < 100).assertTrue();
        expect(bottom[2] > 150 && bottom[0] < 100).assertTrue();
      } finally { await pixel.release(); }
    });

    it('acceptsSolid2048ImageAndBoundsTheLongestSide', 0, async (): Promise<void> => {
      const bytes: Uint8Array = await packPixels(2048, 2048, false);
      const path: string = await writeFixture('vision-device-2048-solid.png', bytes);
      const prepared: VisionPreparedImage =
        await new VisionImagePreparer().prepare('file://' + path, 'vision-device-2048-solid.png');
      expect(prepared.image.width).assertEqual(2048);
      expect(prepared.image.height).assertEqual(2048);
      expect(prepared.image.bytes.length <= 8 * 1024 * 1024).assertTrue();
    });

    it('rejectsNoiseImageThatExceedsSanitizedEightMegabytes', 0, async (): Promise<void> => {
      const bytes: Uint8Array = await packPixels(2048, 2048, true);
      const path: string = await writeFixture('vision-device-2048-noise.png', bytes);
      let code: string = '';
      try { await new VisionImagePreparer().prepare('file://' + path, 'vision-device-2048-noise.png'); }
      catch (error) { code = error instanceof VisionImageFailure ? error.code : 'UNEXPECTED'; }
      expect(code).assertEqual('IMAGE_SANITIZED_BUDGET');
    });

    it('rejectsMalformedImageWithoutSending', 0, async (): Promise<void> => {
      const path: string = await writeFixture('vision-device-invalid.png', new Uint8Array([1, 2, 3, 4]));
      let code: string = '';
      try { await new VisionImagePreparer().prepare('file://' + path, 'vision-device-invalid.png'); }
      catch (error) { code = error instanceof VisionImageFailure ? error.code : 'UNEXPECTED'; }
      expect(code).assertEqual('IMAGE_HEADER_INVALID');
    });

    it('sessionExposesUnverifiedPricingAndClearsImageOnStop', 0, async (): Promise<void> => {
      const path: string = await writeFixture('vision-device-1x1.png', PNG_BYTES);
      const session: RuntimeVisionSession = new RuntimeVisionSession(new VisionImagePreparer());
      session.onForeground();
      expect(await session.attachImage('file://' + path, 'vision-device-1x1.png')).assertTrue();
      const view = session.snapshot();
      expect(view.imageReady).assertTrue();
      expect(view.maxRequests).assertEqual(10);
      expect(view.requestCount).assertEqual(0);
      expect(view.pricingState).assertEqual('unverified');
      await session.stop();
      expect(session.snapshot().imageReady).assertFalse();
    });

    it('fakeRuntimeCancelKeepsImageAndStopsBusyState', 0, async (): Promise<void> => {
      const h = await startedFakeSession(AgentTaskStatus.RUNNING);
      expect(await h.ui.send('问题')).assertTrue();
      expect(h.fake.calls.submit).assertEqual(1);
      await h.ui.cancelCurrent();
      const view = h.ui.snapshot();
      expect(view.stage).assertEqual('answerFailed');
      expect(view.busy).assertFalse();
      expect(view.imageReady).assertTrue();
      expect(h.fake.calls.cancel).assertEqual(1);
      await h.ui.stop();
    });

    it('fakeRuntimeStopClearsImageAndDoesNotRestore', 0, async (): Promise<void> => {
      const h = await startedFakeSession(AgentTaskStatus.RUNNING);
      expect(await h.ui.send('问题')).assertTrue();
      await h.ui.stop();
      const view = h.ui.snapshot();
      expect(view.lifecycle).assertEqual(ShuviRuntimeState.STOPPED);
      expect(view.imageReady).assertFalse();
      expect(view.answer).assertEqual('');
      expect(h.fake.calls.stop >= 1).assertTrue();
      expect(await h.ui.send('再次发送')).assertFalse();
    });

    it('fakeRuntimeEnforcesTenRequestLimitOnDevice', 0, async (): Promise<void> => {
      const h = await startedFakeSession(AgentTaskStatus.COMPLETED);
      for (let index: number = 0; index < 10; index++) {
        expect(await h.ui.send('问题 ' + index.toString())).assertTrue();
        expect(h.ui.snapshot().stage).assertEqual('complete');
        expect(h.ui.snapshot().requestCount).assertEqual(index + 1);
      }
      expect(h.fake.calls.submit).assertEqual(10);
      expect(await h.ui.send('第十一次')).assertFalse();
      expect(h.ui.snapshot().message.indexOf('请求上限') >= 0).assertTrue();
      expect(h.fake.calls.submit).assertEqual(10);
      await h.ui.stop();
    });
  });
}
