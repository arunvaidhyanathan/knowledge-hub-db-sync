import type { Disposable, Page, TestInfo } from '@playwright/test';
import { test } from '@playwright/test';

const escapeHtml = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

/** Bottom caption shown in the GIF while a step runs. Light theme to match the app. */
function captionHtml(n: number, title: string): string {
  return `<div style="position:fixed;left:50%;bottom:24px;transform:translateX(-50%);` +
    `font:600 20px system-ui,sans-serif;color:#0b2a4a;background:rgba(255,255,255,0.95);` +
    `border:1px solid #9cc3f5;padding:8px 16px;border-radius:8px;box-shadow:0 2px 8px rgba(11,42,74,0.15)">` +
    `${n}. ${escapeHtml(title)}</div>`;
}

export interface CapturedFrame {
  data: Buffer;
  /** ms since Unix epoch, as reported by the browser */
  ts: number;
}

export interface StepMark {
  title: string;
  /** ms offset from recording start */
  atMs: number;
}

export interface Recording {
  frames: CapturedFrame[];
  steps: StepMark[];
  startTs: number;
  endTs: number;
}

export interface RecorderOptions {
  size: { width: number; height: number };
  jpegQuality: number;
  /** Time to keep the final state on screen so viewers can read the result. */
  holdLastMs: number;
  /** Pause after each step so a human can follow it. */
  beatMs: number;
  maxSeconds: number;
  minSeconds: number;
}

export const RECORDER_DEFAULTS: RecorderOptions = {
  size: { width: 1280, height: 720 },
  jpegQuality: 85,
  holdLastMs: 1500,
  beatMs: 350,
  maxSeconds: 10,
  minSeconds: 3,
};

/**
 * Records only the window inside kh.record(), using page.screencast (Playwright >= 1.59).
 * No WebM is written: JPEG frames are streamed to memory through onFrame.
 */
export class ScenarioRecorder {
  private recording?: Recording;
  private active = false;
  private frames: CapturedFrame[] = [];
  private steps: StepMark[] = [];
  private startTs = 0;
  private caption?: Disposable;

  constructor(
    private readonly page: Page,
    private readonly testInfo: TestInfo,
    private readonly opts: RecorderOptions,
  ) {}

  async record(body: () => Promise<void>): Promise<void> {
    if (this.recording || this.active) throw new Error('kh.record() can be called once per scenario');
    this.active = true;
    const sc = this.page.screencast;
    this.startTs = Date.now();
    await sc.start({
      size: this.opts.size,
      quality: this.opts.jpegQuality,
      onFrame: ({ data, timestamp }) => {
        this.frames.push({ data: Buffer.from(data), ts: timestamp });
      },
    });
    // Cursor + click point + element highlight. `title` is omitted on purpose: Playwright's
    // action title shows locator code, which means nothing to end users. Captions come from kh.step().
    await sc.showActions({
      duration: 700,
      cursor: 'pointer',
      style: {
        point: 'width: 18px; height: 18px; border-radius: 50%; background: rgba(30, 110, 230, 0.55); border: 2px solid #ffffff',
        highlight: 'outline: 3px solid rgba(30, 110, 230, 0.9); border-radius: 4px',
      },
    });
    try {
      await body();
      await this.page.waitForTimeout(this.opts.holdLastMs);
    } finally {
      await this.caption?.dispose();
      await sc.hideActions();
      await sc.stop();
      this.active = false;
    }
    const endTs = Date.now();
    const firstTs = this.frames[0]?.ts ?? this.startTs;
    this.recording = { frames: this.frames, steps: this.steps, startTs: Math.min(firstTs, this.startTs), endTs };
    this.assertBudget();
  }

  /** Wraps test.step so the step title is also captured as a caption for the Knowledge Hub. */
  async step<T>(title: string, body: () => Promise<T>): Promise<T> {
    if (this.active) {
      this.steps.push({ title, atMs: Date.now() - this.startTs });
      await this.caption?.dispose();
      this.caption = await this.page.screencast.showOverlay(captionHtml(this.steps.length, title));
    }
    const result = await test.step(title, body);
    if (this.active) await this.page.waitForTimeout(this.opts.beatMs);
    return result;
  }

  result(): Recording | undefined {
    return this.recording;
  }

  private assertBudget(): void {
    const r = this.recording!;
    const seconds = (r.endTs - r.startTs) / 1000;
    this.testInfo.annotations.push({ type: 'kh-duration-seconds', description: seconds.toFixed(2) });
    if (r.frames.length === 0) throw new Error('kh: no frames captured; is the page rendering?');
    if (seconds > this.opts.maxSeconds) {
      throw new Error(`kh: scenario recording is ${seconds.toFixed(1)}s; budget is ${this.opts.maxSeconds}s. Split the scenario or move setup out of kh.record().`);
    }
    if (seconds < this.opts.minSeconds) {
      throw new Error(`kh: scenario recording is ${seconds.toFixed(1)}s; minimum is ${this.opts.minSeconds}s so viewers can follow it.`);
    }
  }
}
