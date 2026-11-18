import { audio } from '@kit.AudioKit';
import { speechRecognizer } from '@kit.CoreSpeechKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG = 'SpeechAsr';

/**
 * 语音识别封装：
 *  - AudioCapturer 采集麦克风 16k/单声道/16bit PCM
 *  - CoreSpeechKit 离线中文识别（无需联网、无需鉴权）
 *  - 按住开始，松手结束，回调最终文字
 */
export class SpeechAssistant {
  private engine: speechRecognizer.SpeechRecognitionEngine | undefined = undefined;
  private capturer: audio.AudioCapturer | undefined = undefined;
  private sessionId: string = '';
  private listening: boolean = false;
  private finalText: string = '';
  private onResult: (text: string) => void;
  private onError: (msg: string) => void;

  constructor(onResult: (text: string) => void, onError: (msg: string) => void) {
    this.onResult = onResult;
    this.onError = onError;
  }

  isListening(): boolean {
    return this.listening;
  }

  /** 按住语音键：创建引擎 + 采音 + 开始识别 */
  async start(): Promise<void> {
    if (this.listening) {
      return;
    }
    this.finalText = '';
    this.listening = true;
    this.sessionId = 'asr_' + Date.now().toString();

    try {
      if (!this.engine) {
        await this.createEngine();
      }
      this.setListener();

      // 采集器：16kHz / 单声道 / S16LE / 麦克风音源
      const capturerOptions: audio.AudioCapturerOptions = {
        streamInfo: {
          samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
          channels: audio.AudioChannel.CHANNEL_1,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
          encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
        },
        capturerInfo: {
          source: audio.SourceType.SOURCE_TYPE_MIC,
          capturerFlags: 0
        }
      };
      this.capturer = await audio.createAudioCapturer(capturerOptions);
      // 订阅采音数据事件（read 轮询自 API 11 废弃，官方推荐 readData 回调）
      this.capturer.on('readData', (buffer: ArrayBuffer) => {
        if (this.listening && this.engine && buffer.byteLength > 0) {
          this.engine.writeAudio(this.sessionId, new Uint8Array(buffer));
        }
      });
      await this.capturer.start();

      const startParams: speechRecognizer.StartParams = {
        sessionId: this.sessionId,
        audioInfo: {
          audioType: 'pcm',
          sampleRate: 16000,
          soundChannel: 1,
          sampleBit: 16
        },
        extraParams: { 'online': 1 }
      };
      this.engine!.startListening(startParams);
      hilog.info(0x0000, TAG, 'start listening, session=%{public}s', this.sessionId);
    } catch (e) {
      const err = e as BusinessError;
      this.listening = false;
      const msg = '启动失败: ' + (err?.message ?? JSON.stringify(e));
      hilog.error(0x0000, TAG, '%{public}s', msg);
      this.onError(msg);
    }
  }

  /** 松手：停止采音，引擎 finish 后等待最终识别结果回调 */
  async stop(): Promise<void> {
    if (!this.listening) {
      return;
    }
    this.listening = false;
    try {
      if (this.capturer) {
        await this.capturer.stop();
        await this.capturer.release();
        this.capturer = undefined;
      }
      if (this.engine) {
        this.engine.finish(this.sessionId);
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, 'stop error %{public}s', err?.message ?? '');
    }
  }

  /** 释放引擎（页面销毁时调用） */
  release(): void {
    try {
      if (this.capturer) {
        this.capturer.stop();
        this.capturer.release();
        this.capturer = undefined;
      }
      if (this.engine) {
        this.engine.shutdown();
        this.engine = undefined;
      }
    } catch (e) {
      hilog.error(0x0000, TAG, 'release error');
    }
  }

  private createEngine(): Promise<void> {
    const params: speechRecognizer.CreateEngineParams = {
      language: 'zh-CN',
      online: 1,
      extraParams: { 'recognizerMode': 'short' }
    };
    return new Promise<void>((resolve, reject) => {
      speechRecognizer.createEngine(params,
        (err: BusinessError, engine: speechRecognizer.SpeechRecognitionEngine) => {
          if (err) {
            reject(err);
            return;
          }
          this.engine = engine;
          hilog.info(0x0000, TAG, 'engine created');
          resolve();
        });
    });
  }

  private setListener(): void {
    const listener: speechRecognizer.RecognitionListener = {
      onStart: (sessionId: string, eventMessage: string) => {
        hilog.info(0x0000, TAG, 'onStart %{public}s', eventMessage);
      },
      onEvent: (sessionId: string, eventCode: number, eventMessage: string) => {
        hilog.info(0x0000, TAG, 'onEvent %{public}d %{public}s', eventCode, eventMessage);
      },
      onResult: (sessionId: string, result: speechRecognizer.SpeechRecognitionResult) => {
        hilog.info(0x0000, TAG, 'onResult final=%{public}s isLast=%{public}s text=%{public}s',
          String(result.isFinal), String(result.isLast), result.result);
        if (result.result && result.result.length > 0) {
          // 保留最新结果（临时的会被最终的覆盖）
          this.finalText = result.result;
        }
      },
      onComplete: (sessionId: string, eventMessage: string) => {
        hilog.info(0x0000, TAG, 'onComplete %{public}s', eventMessage);
        const text = this.finalText.trim();
        if (text.length > 0) {
          this.onResult(text);
        } else {
          this.onError('没听清，请再说一次');
        }
      },
      onError: (sessionId: string, errorCode: number, errorMessage: string) => {
        hilog.error(0x0000, TAG, 'onError %{public}d %{public}s', errorCode, errorMessage);
        this.onError('识别失败: ' + errorMessage);
      }
    };
    this.engine!.setListener(listener);
  }
}
