# macOS で会議音声をローカル録音・文字起こしする手法の調査

2026-10-04 時点の調査。このあとに作ったアプリの説明は [README.md](README.md)。

実装で採ったのは、自分と相手を別トラックで録り、会議中に字幕を出すところまで。取り込みは Core Audio の Process Tap ではなく ScreenCaptureKit、文字起こしは SpeechTranscriber だけ。会議後の kotoba-whisper による清書、相手同士の話者分離、meeting-transcriber の検証結果は、このリポジトリにはない。6章は当時の案で、そのまま実装した手順ではない。

- 調査日: 2026-10-04
- 前提: macOS（Apple Silicon）、音声は外部に送らない、OSS・無料を優先し自作も検討する
- ゴール: 「相手の声（PC の再生音）」と「自分の声（マイク）」を録り、ローカルで **文字起こし＋話者分離**、さらに **リアルタイム文字起こし** まで行う
- **使う会議ツールは Teams と Google Meet、相手は複数人（2〜8人程度）** の前提。おすすめの構成は6章。**第一案は「自分／相手」だけを見分け、相手同士の区別は後から足せるようにする構成**（6.0）。相手同士の見分け方は4章

> 「未確認」と書いた箇所は、一次情報で確かめられなかった内容です。

---

## 1. 全体像

処理は次の3段に分かれます。段ごとに手段を選んで組み合わせます。

```
[① 音を取り込む]             [② 文字にする]                [③ 誰が話したか]
 相手の声 (システム音声) ─┐
                         ├─▶ 音声認識 (ASR) ─────────▶ 話者分離 ─▶ 議事録
 自分の声 (マイク) ──────┘   ・まとめて処理 (バッチ)
                             ・逐次処理 (リアルタイム)
```

**大事なポイント:** ①で「マイク」と「システム音声」を **別トラック** で録っておくと、③の「自分か相手か」の判定はトラックを見るだけで済みます。相手が複数人いる場合は、PC の再生音が全員分を1本に混ぜた音になるため、**相手同士を見分けるには話者分離モデルか、会議ツール側で参加者ごとに分けた音声** が必要になります（4章）。

---

## 2. ① 音を取り込む方法

### 2.1 比較表

| 手法 | 必要な macOS | 権限 | マイクと別トラック | 費用 | 向いている用途 |
|---|---|---|---|---|---|
| **Core Audio Process Tap** | 14.2+（サンプルの AudioCap は 14.4+） | 「システムオーディオ録音のみ」（`NSAudioCaptureUsageDescription`） | ○（マイクは別に取得） | 無料（OS 標準 API） | **自作するならこれが第一候補** |
| **ScreenCaptureKit** | 13+（マイク取得は 15+） | 画面収録 | ○（出力の種類が別） | 無料（OS 標準 API） | 画面も録りたいとき・既存アプリ |
| **BlackHole（仮想オーディオデバイス）＋ ffmpeg など** | 古い版でも可 | マイク | ○ | 無料（GPL-3.0） | コードを書かずにすぐ試したいとき |
| Loopback / Audio Hijack（Rogue Amoeba） | — | — | ○ | 有料 | GUI で細かく音を振り分けたいとき |
| Zoom のローカル録画 | — | — | ○（**参加者ごと**に別ファイル） | 無料 | Zoom だけで済むとき |
| QuickTime / Cmd+Shift+5 | — | — | ×（システム音声は録れない） | 無料 | 使えない |

### 2.2 Core Audio Process Tap（自作するなら第一候補）

- macOS 14.2 で追加された Core Audio の API（`AudioHardwareCreateProcessTap` / `CATapDescription`）です。**仮想ドライバを入れずに**、特定のアプリ（例: Zoom だけ）か、システム全体の出力音を取り込めます
- 権限は「画面収録」ではなく **音声収録専用** のものです。Info.plist に `NSAudioCaptureUsageDescription` を書きます
- 取得したタップを Aggregate Device にまとめて、そこから録音します。マイクは通常の入力デバイスとして別に録ります
- 参考実装: [insidegui/AudioCap](https://github.com/insidegui/AudioCap)（macOS 14.4+、アプリ単位・システム全体の両方に対応）

### 2.3 ScreenCaptureKit

- 画面キャプチャ用のフレームワークですが、`SCStreamConfiguration.capturesAudio` でシステム音声も取れます（macOS 13+）
- macOS 15 で `captureMicrophone` と `microphoneCaptureDeviceID` が追加され、**マイクも同じストリームの別出力（`.microphone`）** として受け取れます（[WWDC24 "Capture HDR content with ScreenCaptureKit"](https://developer.apple.com/videos/play/wwdc2024/10088/)）
- `excludesCurrentProcessAudio` で自分のアプリの音を除けます。アプリ単位で絞ることもできます
- 欠点: **画面収録の権限** が要ります。音声だけが欲しい場合は権限が過剰で、OS の版によっては許可を定期的に確認し直すよう求められます（未確認: 確認の頻度）

### 2.4 BlackHole ＋ Audio MIDI 設定（コードを書かない方法）

1. [BlackHole](https://github.com/ExistentialAudio/BlackHole)（2ch 版）を入れる
2. 「Audio MIDI 設定」で **複数出力装置**（スピーカー/ヘッドホン ＋ BlackHole）を作り、出力先にする → 自分にも聞こえて、BlackHole にも音が流れる
3. 録音側は BlackHole（相手の声）とマイク（自分の声）を入力として扱う。1本にまとめたい場合は **機器セット（Aggregate Device）** を使う（[Apple 公式手順](https://support.apple.com/guide/audio-midi-setup/combine-audio-devices-a-single-aggregate-ams6e21c3f61/mac)）

ffmpeg で2つの入力を別ファイルとして録る例（デバイス番号は環境ごとに違います）:

```bash
ffmpeg -f avfoundation -list_devices true -i ""     # デバイス番号を確認
ffmpeg -f avfoundation -i ":<BlackHoleの番号>" -ac 1 -ar 16000 others.wav \
       -f avfoundation -i ":<マイクの番号>"      -ac 1 -ar 16000 me.wav
```

- 欠点: 複数出力装置を使っている間は **キーボードで音量を変えられない**。Bluetooth（AirPods など）と組み合わせると音ずれや音切れが起きやすい。会議ごとに出力先を切り替える手間がかかる
- Soundflower は更新が止まっているため使わない

### 2.5 Zoom のローカル録画

- 設定 → レコーディング → 「**参加者ごとに個別のオーディオファイルを録音する**」を有効にすると、参加者ごとに別の音声ファイルが保存されます。**話者分離の手間がほぼなくなります**
- 条件: Zoom デスクトップアプリでのローカル録画のみ。録画の許可を得る必要があり、参加者には録画中であることが通知されます（[参考: 大学のサポート記事](https://services.gvsu.edu/TDClient/60/Portal/KB/ArticleDet?ID=4698)）
- Teams・Google Meet には、同じようにローカルへ参加者別ファイルを保存する機能は見つかりませんでした（未確認）

### 2.6 エコー（相手の声がマイクに入る）対策

- スピーカーで聞くと、相手の声がマイクにも入り、**自分のトラックに相手の発言が混ざります**。いちばん確実な対策は **ヘッドホンを使う** ことです
- 自作する場合は `AVAudioEngine` の `setVoiceProcessingEnabled(true)` でエコーキャンセルを有効にできます。ただし音質は通話向けに加工されます

---

## 3. ② 文字にする（ローカル ASR）

### 3.1 エンジンの比較

| エンジン | 種類 | Mac での高速化 | 日本語 | リアルタイム | ライセンス |
|---|---|---|---|---|---|
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp) | Whisper の C++ 実装 | Metal / Core ML | ○（Whisper 準拠） | `stream` サンプルあり | MIT |
| mlx-whisper | Whisper の Apple MLX 版 | MLX（GPU） | ○ | 単体では非対応 | MIT |
| [WhisperKit](https://github.com/argmaxinc/WhisperKit)（Argmax） | Whisper の Core ML 版（Swift） | Neural Engine | ○ | ストリーミング対応 | MIT |
| faster-whisper / [WhisperX](https://github.com/m-bain/whisperX) | CTranslate2 版 ＋ 単語単位の時刻合わせ ＋ 話者分離 | **Mac では CPU のみ**（CUDA 前提） | ○ | × | MIT（faster-whisper）/ BSD-2（WhisperX、未確認） |
| [kotoba-whisper v2.x](https://huggingface.co/kotoba-tech/kotoba-whisper-v2.2) | **日本語向け** に Whisper large-v3 を蒸留したもの | transformers / whisper.cpp 形式 | ◎ | × | Apache-2.0 |
| [ReazonSpeech](https://research.reazon.jp/projects/ReazonSpeech/) | **日本語専用**（NeMo / k2 / ESPnet 版） | sherpa-onnx 経由など | ◎ | k2 版は sherpa-onnx で可 | モデルにより異なる |
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | ASR・VAD・話者分離をまとめた実行基盤 | ONNX Runtime（CPU/CoreML） | ○（ReazonSpeech zipformer、SenseVoice） | ◎（ストリーミング対応モデルあり） | Apache-2.0 |
| Apple **SpeechAnalyzer / SpeechTranscriber** | OS 標準の端末内認識 | OS 任せ | ○（公開時から日本語に対応） | ◎ | OS 標準 API |

補足:

- **kotoba-whisper v2.2** は、モデルカードによると話者分離（diarizers）と句読点付けの後処理を含みます。日本語の議事録には有力な候補です
- **SpeechAnalyzer** は macOS 26 / iOS 26 の新しい API で、端末内で処理されます。日本語に対応しています（[WWDC25 セッション 277](https://developer.apple.com/videos/play/wwdc2025/277/)、[解説記事](https://blog.addpipe.com/apple-speechanalyzer-api/)）。話者分離はありません。日本語の精度を Whisper 系と比べた資料は見つかりませんでした（未確認）
- WhisperX は Mac では `--device cpu --compute_type int8` で動かすことになり、GPU は使えません。長い会議では時間がかかります

### 3.2 リアルタイム文字起こしの方法

Whisper はもともと30秒単位で処理するモデルなので、リアルタイムにするには「音声を細かく区切り、確定した部分から出す」仕組みが必要です。

| 方法 | 概要 | 注意 |
|---|---|---|
| **SpeechTranscriber**（macOS 26+） | OS 標準。途中経過（volatile）と確定結果を順に返す | Swift で書く必要がある |
| **sherpa-onnx の streaming zipformer** | 本物のストリーミング型モデル。遅延が小さく CPU でも軽い | 日本語のストリーミングモデルは種類が限られる（未確認: ReazonSpeech zipformer のストリーミング版の有無） |
| **WhisperKit のストリーミング** | Swift から Whisper を逐次実行 | — |
| **whisper.cpp `stream`** | 一定間隔で直近の音声を繰り返し認識する | 簡易的。同じ文が何度も書き換わる |
| [SimulStreaming](https://github.com/ufal/SimulStreaming) | whisper_streaming の後継（ufal）。Whisper を同時通訳のように逐次処理する | [whisper_streaming](https://github.com/ufal/whisper_streaming) は README で「置き換わりつつある」と明記（論文値で遅延約3.3秒） |
| WhisperLive | 自分の PC 内でサーバーを立て、クライアントから音声を送る構成 | 自分の PC 内で完結させること |

**実用上の定石:** 会議中は軽いエンジンで **字幕を出すだけ** にして、終了後に高精度のエンジン（kotoba-whisper、large-v3 など）と話者分離で **清書し直す** 二段構えにします。リアルタイム処理だけで正確な議事録を作るのは難しいためです。

---

## 4. ③ 話者分離（相手が複数人の場合）

### 4.1 考え方: 分けられるところは録音の段階で分ける

話者分離モデルは、**話者が増えるほど** 誤りが増えます。たとえば NVIDIA Streaming Sortformer のモデルカードでは、CALLHOME（英語中心の電話音声）での誤り率（DER）が次のように上がっています。

| 話者数 | 2 | 3 | 4 | 5 | 6 |
|---|---|---|---|---|---|
| DER | 6.57% | 10.05% | 12.44% | 21.68% | 28.74% |

（出典: [nvidia/diar_streaming_sortformer_4spk-v2](https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2)。このモデルは4人までを想定しているため、5人以上で特に悪くなります）

そのため、次の順に「確実な手段」から使い、残った部分だけをモデルに任せます。

| 段 | 何で分けるか | 確実さ | 使える条件 |
|---|---|---|---|
| 1 | **会議ツールが参加者ごとに分けた音声**（Zoom の参加者別ファイル） | ◎ モデル不要 | Zoom デスクトップアプリ・録画の許可・会議後のみ |
| 2 | **自分のトラック／相手のトラック**（2章） | ◎ モデル不要 | ヘッドホン使用が前提 |
| 3 | **相手トラックに話者分離モデル**をかける | △ 人数・声質・重なりで誤る | どの会議ツールでも使える |
| 4 | **名前を付ける**（参加者一覧・声の登録） | ○ 補助 | 4.5 参照 |

### 4.2 会議ツール側で参加者ごとに分ける

| 会議ツール | 得られるもの | 条件・注意 | 外部への送信 |
|---|---|---|---|
| **Zoom ローカル録画**「参加者ごとに個別のオーディオファイルを録音する」 | 参加者ごとの音声ファイル（ファイル名に参加者名）。保存先の `Audio Record` フォルダに入る | デスクトップアプリのみ。ホストか、ホストに録画を許可された人だけが使える。電話やブラウザで参加した人は分かれない可能性がある（未確認）。ファイル同士の時刻が揃っているかは未確認 | なし（Zoom 本体の通信のみ） |
| Zoom Meeting SDK（参加者ごとの生音声） | 参加者ごとの PCM 音声をリアルタイムで受け取れる | **SDK で作ったアプリが参加者として会議に入る** 必要がある。録音の許可が必要。macOS での実装例は少ない | なし（ただし開発の負担が大きい） |
| Microsoft Teams | 話者名つきの文字起こし（.vtt / .docx） | **Microsoft のクラウドで処理** される。参加者ごとの音声をローカルで受け取る公式の方法は、Windows Server 上で動くメディアボットのみ（[公式要件](https://learn.microsoft.com/en-us/microsoftteams/platform/bots/calls-and-meetings/requirements-considerations-application-hosted-media-bots)） | あり（会社の承認が必要） |
| Google Meet | Meet Media API で参加者の音声を取得 | Developer Preview の段階。参加者全員の音声が個別に届くわけではない（[公式概要](https://developers.google.com/meet/media-api/guides/overview)） | — |
| 会議室で数人が1つのマイクを共有 | — | **会議ツール側ではどうやっても分けられない**。モデルで分けるしかなく、反響もあって精度は下がる | — |

→ **Zoom の会議だけは、会議後なら話者分離モデルを使わずに済みます。** それ以外の会議ツールでは、段3のモデルが必要です。

### 4.3 話者分離エンジン（会議後にまとめて処理）

| エンジン | 概要 | Mac での動作 | ライセンス | 注意 |
|---|---|---|---|---|
| **[pyannote community-1](https://huggingface.co/pyannote/speaker-diarization-community-1)**（pyannote.audio 4.x） | 定番。3.1 より精度が上がっている（下表） | Python / PyTorch。モデルカードは CPU と CUDA のみ記載で、MPS（Apple の GPU）での動作は未確認 | CC-BY-4.0 | `num_speakers` や `min_speakers` / `max_speakers` で人数を指定できる。`exclusive_speaker_diarization` を出力すると、文字起こしとの対応付けが簡単になる |
| **[FluidAudio](https://github.com/FluidInference/FluidAudio)**（オフライン） | community-1 と同じ構成（＋VBx クラスタリング）を **Core ML** で動かす Swift ライブラリ | Neural Engine / GPU で動く | コードは Apache-2.0、モデルは MIT / Apache-2.0 と記載 | Swift で自作する場合の第一候補。HF トークンは不要 |
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | pyannote の分割モデル＋話者特徴量（3D-Speaker など）＋クラスタリング | ONNX で軽い | Apache-2.0 | 人数（`num_clusters`）か閾値を指定する。精度の公表値は見つからなかった（未確認） |
| kotoba-whisper v2.2 | 日本語の文字起こしと一緒に話者分離（diarizers）まで行う | Python | Apache-2.0 | 内部で pyannote のモデルを使うため、HF での利用条件への同意が必要 |
| DiariZen | 研究用の高精度モデル | Python | **モデルは CC BY-NC 4.0（非商用）** | **業務では使えない** |

pyannote のモデルカードにある DER（数字が小さいほど良い）:

| データセット | 3.1 | community-1 | precision-2（クラウド版・対象外） |
|---|---|---|---|
| AISHELL-4（中国語・会議） | 12.2% | 11.7% | 11.4% |
| AliMeeting（中国語・会議） | 24.5% | 20.3% | 15.2% |
| AMI IHM（英語・会議） | 18.8% | 17.0% | 12.9% |
| DIHARD 3 | 21.4% | 20.2% | 14.7% |

- **日本語の会議での公表ベンチマークは見つかりませんでした（未確認）**。実際の会議音声で試して確かめる必要があります
- precision-2 は pyannoteAI のクラウド API なので、今回の条件（外部に送らない）に合いません

### 4.4 リアルタイムの話者分離（会議中）

| エンジン | 人数の上限 | 遅延 | 注意 |
|---|---|---|---|
| **FluidAudio LS-EEND** | 10人 | 100ms ごとに更新 | Swift / Core ML |
| FluidAudio Sortformer / NVIDIA Streaming Sortformer | **4人** | 0.32〜30.4秒（遅延が大きい設定ほど精度が高い） | 主に英語で学習しており、モデルカードに「英語以外では性能が落ちる場合がある」とある。CC-BY-4.0 |
| [diart](https://github.com/juanmc2005/diart) | 制限なし（逐次クラスタリング） | 0.5〜5秒で調整できる | Python。pyannote のモデルを使う。MIT |

- リアルタイムでは「これまでに聞いた音声」だけで判定するため、会議の途中で **ラベルが入れ替わったり、同じ人が別人として扱われたり** します。会議中の話者ラベルは「仮のもの」と割り切り、会議後に4.3の方法で付け直すのが現実的です

### 4.5 話者に名前を付ける

話者分離が出すのは「話者1」「話者2」といったラベルだけです。名前を付けるには次の方法を組み合わせます。

| 方法 | 仕組み | 注意 |
|---|---|---|
| **参加者一覧から人数を指定する** | 会議ツールの参加者数を `num_speakers` に渡す | 人数が分かっているだけで精度が上がる |
| **声の登録（エンロール）** | 同僚の声の特徴量（埋め込みベクトル）を保存しておき、各ラベルの特徴量と似ている度合い（コサイン類似度）で照合する | 声の特徴量は **個人情報（個人識別符号）に当たる可能性** がある。本人の同意と社内確認が必要（7章） |
| **会議ツールの画面から名前を読む** | アクセシビリティ API で、Teams・Zoom の参加者名や「話している人」の表示を読み取る | 画面の作りが変わると動かなくなる。[meeting-transcriber](https://github.com/pasrom/meeting-transcriber) が実装している |

### 4.6 文字起こしと話者ラベルを対応させる

- 文字起こしの **単語や区間の時刻** と、話者分離の **区間** を重ね、いちばん長く重なった話者を割り当てます（WhisperX の `assign_word_speakers` と同じ考え方です）
- 複数人が同時に話す箇所は、どちらか一方に割り当てると誤りになります。pyannote の `exclusive_speaker_diarization`（各時刻に話者を1人だけ割り当てた出力）を使うと、対応付けが単純になります
- 日本語は単語の区切りがはっきりしないため、**文や区間の単位** で対応させるほうが扱いやすいです

---

## 5. 既存アプリ（自作せずに済ませる場合）

| アプリ | ライセンス / 価格 | システム音声 | ローカル文字起こし | 話者分離 | リアルタイム | 備考 |
|---|---|---|---|---|---|---|
| **[meeting-transcriber](https://github.com/pasrom/meeting-transcriber)** | MIT / 無料 | ○（Core Audio Tap でアプリ単位、マイクと別トラック） | WhisperKit / Parakeet（日本語は WhisperKit） | ○（FluidAudio、Teams の参加者名の読み取り、会議をまたいだ声の照合） | ×（会議後に処理） | **相手が複数人の構成にいちばん近い**（6章） |
| [Meetily](https://github.com/Zackriya-Solutions/meeting-minutes) | MIT / 無料 | ○（マイクと同時に録音） | Whisper / Parakeet | 無料版にはない（PRO 版で予定） | ○ | Rust 製。日本語の精度は未確認 |
| [anarlog](https://github.com/fastrepl/hyprnote)（旧 Hyprnote） | MIT（一部商用） | ○（ボット不要） | ○（Apple の音声認識など） | 未確認 | ○ | クラウド機能は使う人が選んだときだけ有効 |
| [Buzz](https://github.com/chidiwilliams/buzz) | MIT / 無料 | △（マイクとファイルが中心） | Whisper / whisper.cpp / faster-whisper | 未確認 | マイクのみ | ファイルの文字起こしに強い |
| MacWhisper | 無料版＋有料版 | ○（会議の録音機能あり） | Whisper / Parakeet など | 有料版 | — | クラウド連携は任意 |
| VoiceInk | GPL-3.0 / 有料版あり | —（音声入力用） | Whisper / Parakeet | — | ○ | 会議の録音ではなく音声入力用 |
| OBS Studio | GPL-2.0 / 無料 | ○（ScreenCaptureKit でアプリの音） | × | × | × | 録音だけに使う |

- 調べていた X の投稿にある「日本語に強い無料の音声入力アプリ」は **音声入力（ディクテーション）用** で、会議の録音用ではありません。アプリ名は特定できませんでした（未確認）
- Granola など **クラウドで処理するもの** は今回の条件に合いません

---

## 6. おすすめの構成（Teams・Google Meet、相手が複数人）

### 6.0 第一案: まず「自分／相手」だけを見分け、相手同士の区別は後から足す

この調査で不確かだった点は、ほとんどが **相手同士を見分ける話者分離** に関わる部分でした。具体的には、日本語の会議での精度が公表されていないこと、人数が増えるほど誤りが増えること、Meet で名前を付けられないこと、声の特徴量を個人情報として扱う必要があることです。そこで最初は相手同士の区別をやめ、**実績のある技術（録音と日本語の文字起こし）だけで作ります**。

```
Core Audio Tap (Teams / Meet専用ブラウザ) ─▶ 相手トラック ─┬─▶ 会議中: 字幕（自分／相手のラベルつき）
AVAudioEngine (マイク, ヘッドホン)       ─▶ 自分トラック ─┴─▶ 会議後: kotoba-whisper 等で清書
                                          （相手トラックは保存しておき、後から話者分離をかけられる）
```

| | 第一案（自分／相手だけ） | 相手同士も見分ける（6.1〜6.4） |
|---|---|---|
| 自分／相手の区別 | トラックで分かる（モデル不要） | 同じ |
| 相手同士の区別 | なし（「相手」とだけ表示） | 話者分離モデル＋名前付け |
| リアルタイム | 字幕だけ（SpeechTranscriber / WhisperKit） | 字幕＋仮の話者ラベル（入れ替わることがある） |
| 不確かな要素 | ほぼ文字起こしの精度だけ | 話者分離の精度・名前付け・個人情報の扱い |
| 失うもの | 相手の中の誰が言ったか。議事録では文脈から判断して手で補う | — |

**守ること:** 相手トラックは **別ファイルのまま保存しておく**。そうすれば、相手同士を見分ける必要が出たときに、保存したトラックへ後から話者分離（4.3）をかけられます。録音し直す必要はありません。

**第一案で確かめること:**

1. Teams・Meet（専用ブラウザ）の音を Core Audio Tap で取り込めるか
2. ヘッドホンを使ったときに、自分のトラックに相手の声が入らないか
3. 会議中の字幕と会議後の清書の、日本語の精度

検証手順は [meeting-transcriber-eval.md](meeting-transcriber-eval.md) にまとめた。

以下の 6.1〜6.4 は、相手同士の区別が必要になったときに足す方法です。

### 6.1 前提として分かったこと

- **Teams・Meet には、参加者ごとの音声をローカルで受け取る方法がありません**（4.2）。相手同士を見分けるには、相手トラックに話者分離モデルをかけるしかありません
- 一方で、両ツールには **話者名つきで日本語の文字起こしをする標準機能** があります。ただし処理するのは各社のクラウドです

| | Teams 標準の文字起こし | Meet 標準の文字起こし | ローカル処理（この調査の本題） |
|---|---|---|---|
| 話者名 | ◎ アカウント名で付く | ◎ アカウント名で付く | △ 話者分離モデル＋名前付けの工夫が必要 |
| 日本語 | ○ | ○（英・仏・独・伊・日・韓・葡・西） | 使うモデル次第 |
| 処理する場所 | Microsoft のクラウド | Google のクラウド | 自分の PC |
| 保存先 | 開催者の OneDrive（チャネル会議は SharePoint） | 開催者の Google ドライブ | 自分の PC |
| 条件 | 管理者が録音・文字起こしのポリシーを有効にしていること | Business Standard 以上などの Workspace エディション | — |
| 出典 | [Microsoft Learn](https://learn.microsoft.com/en-us/microsoftteams/meeting-recording) / [多言語の音声認識](https://support.microsoft.com/en-us/topic/650cb6d2-8a33-40e7-840d-36bb90216aa4) | [Google ヘルプ](https://support.google.com/meet/answer/12849897) | — |

> **会社のルールとの関係:** Teams と Meet の標準の文字起こしは、各社のクラウドで処理されます。業務で使ってよいかは、自分の組織のルールで確認します。「外部に送らない」ことが必須であれば、以下のローカル構成になります。

### 6.2 ローカル構成で気を付ける点

| 項目 | Teams（デスクトップアプリ） | Google Meet（ブラウザ） |
|---|---|---|
| 録音するプロセス | Teams アプリ（`com.microsoft.teams2`）を Core Audio Tap で指定 | **ブラウザ全体** を指定することになる |
| 他の音が混ざるか | 混ざりにくい（Teams の通知音などは入る） | **同じブラウザの他のタブの音（YouTube など）も入る**（タップはプロセス単位で、タブ単位にはできない。仕組みから判断しており、公式の明記は未確認） |
| 対策 | — | **Meet 専用のブラウザを決める**（例: 普段は Safari、Meet は Chrome だけで使う）。会議中は同じブラウザで他の音を出さない |
| 参加者名の読み取り | meeting-transcriber がアクセシビリティ API で対応 | meeting-transcriber は **Meet の会議を検出できるが、参加者名の読み取りは Teams のみ** と記載 |
| マイクの同時利用 | macOS では複数のアプリが同じマイクを同時に使える。meeting-transcriber もこの方式で録音している。自分の環境で問題が出ないかは試して確かめる | 同左 |

### 6.3 進め方

**ステップ1: meeting-transcriber を試す**

[pasrom/meeting-transcriber](https://github.com/pasrom/meeting-transcriber)（MIT、macOS 14.2+、`brew install --cask` で入る）を試します。README で確認できた内容は次のとおりです。

- Teams はウィンドウのタイトルで検出する。Meet は Chromium 系ブラウザで検出する
- Core Audio Tap でアプリの音を、マイクと **別トラック** で録る
- 文字起こしは **会議の後** に行う（リアルタイムではない）。日本語を扱うには WhisperKit を選ぶ（Parakeet は欧州25言語のみ）
- 話者分離は FluidAudio で行う。声の特徴量を保存して、会議をまたいで同じ人を照合する
- 初回だけモデルをダウンロードする（WhisperKit で約1GB）。要約はローカルの LLM を使うか、無効にできる。**要約に外部の LLM を使う設定にはしないこと**

試して確認すること:

1. 日本語の文字起こしの精度（WhisperKit のモデルの大きさごと）
2. 相手が3人以上いるときの話者分離の精度
3. Teams で参加者名が正しく付くか
4. Meet で他のタブの音が混ざらない運用ができるか

**ステップ2: 足りない部分を補う**

| 足りない点 | 補い方 |
|---|---|
| リアルタイムの字幕がない | 会議中だけ動く小さなアプリを自作する。Core Audio Tap → SpeechTranscriber（macOS 26）または WhisperKit で字幕を出し、FluidAudio LS-EEND で仮の話者ラベルを付ける |
| 日本語の精度が足りない | 録音したトラックを kotoba-whisper で文字起こしし直す |
| Meet で名前が付かない | 会議後に「話者1＝○○さん」と手で対応付ける。または、声の照合（4.5）に頼る |
| 話者分離の精度が足りない | 参加者一覧から人数を指定して、pyannote community-1 で分け直す |

**ステップ3: 自分たちの会議で精度を測る**

- 日本語の会議での話者分離の公表値がないため、実際の会議の数分を手でラベル付けして DER を測り、エンジンを選ぶ
- 録音と正解ラベルは PC の外に出さないこと（7章）

### 6.4 コードを書かずに試す場合

BlackHole ＋ ffmpeg で自分／相手を別ファイルに録り、相手側のファイルに pyannote をかける方法も使えます。ただし BlackHole には PC で鳴る音がすべて入るため、会議中は他の音を出さないようにします。

---

## 7. 運用するときの注意

- **録音の同意:** 会議を録音・文字起こしすることは、参加者に事前に伝えて同意を取ってください。社外の会議では先方の方針にも従ってください
- **データの扱い:** 文字起こしの結果には、参加者の氏名・発言・案件情報が含まれます。音声と文字起こしは PC 内で管理し、その内容を会社が承認していない生成 AI やクラウドサービスに入れないでください。業務の会議で使う前に、扱ってよいかを確認してください
- **声の登録（4.5）:** 個人情報保護法では、声の特徴をデータにしたもので本人を識別できるものは「個人識別符号」に当たり得ます。同僚の声を登録する前に本人の同意を取り、社内で扱ってよいかを確認してください（法的な判断は未確認のため、専門部署に確認してください）
- **モデルの入手:** pyannote のように初回のダウンロードで HF トークンが必要なモデルがあります。トークンはコードに直接書かず、ダウンロードが終わったらオフラインで動かせば、実行時の通信は発生しません
- **ライセンス:** BlackHole（GPL-3.0）や VoiceInk（GPL-3.0）を組み込んで配布する場合は、GPL の条件に従う必要があります。pyannote community-1 は CC-BY-4.0 で、利用時に出典の表示が必要です

---

## 8. 参考にした資料の評価

- `docs/note.md` の記事（[WhisperX ＋ pyannote の構築ガイド](https://note.com/yonmas/n/n2854d2c1c75f)）: AI が生成した記事と明記されています。手順（Python の仮想環境、HF トークン、利用条件への同意、Mac では `--device cpu`）は公式の README と大きく食い違っていません。ただし Mac では GPU が使えないため遅く、リアルタイム処理には使えません。また **録音の方法は扱っていません**
- `docs/x-post.md`: 音声入力アプリの紹介です。会議の録音ではありませんが、「ローカルの Whisper で常に文字起こししている」という使い方は、6章の構成と同じ方向です

## 9. 主な情報源

- Core Audio Tap: [insidegui/AudioCap](https://github.com/insidegui/AudioCap)
- ScreenCaptureKit: [WWDC24 10088](https://developer.apple.com/videos/play/wwdc2024/10088/) / [WWDC22 10156](https://developer.apple.com/videos/play/wwdc2022/10156/)
- BlackHole: [ExistentialAudio/BlackHole](https://github.com/ExistentialAudio/BlackHole) / [Audio MIDI 設定（Apple）](https://support.apple.com/guide/audio-midi-setup/combine-audio-devices-a-single-aggregate-ams6e21c3f61/mac)
- ffmpeg: [avfoundation 入力](https://ffmpeg.org/ffmpeg-devices.html#avfoundation)
- whisper.cpp: [CLI README](https://github.com/ggml-org/whisper.cpp/blob/master/examples/cli/README.md)
- kotoba-whisper: [v2.2 モデルカード](https://huggingface.co/kotoba-tech/kotoba-whisper-v2.2)
- sherpa-onnx: [k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)
- whisper_streaming / SimulStreaming: [ufal/whisper_streaming](https://github.com/ufal/whisper_streaming)
- SpeechAnalyzer: [WWDC25 277](https://developer.apple.com/videos/play/wwdc2025/277/) / [解説](https://blog.addpipe.com/apple-speechanalyzer-api/)
- pyannote: [speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1)
- Meetily: [Zackriya-Solutions/meeting-minutes](https://github.com/Zackriya-Solutions/meeting-minutes)
- anarlog（旧 Hyprnote）: [fastrepl/hyprnote](https://github.com/fastrepl/hyprnote)
- Zoom の参加者別録音: [GVSU のサポート記事](https://services.gvsu.edu/TDClient/60/Portal/KB/ArticleDet?ID=4698)
- 複数話者の話者分離: [FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio) / [nvidia/diar_streaming_sortformer_4spk-v2](https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2) / [juanmc2005/diart](https://github.com/juanmc2005/diart) / [BUTSpeechFIT/DiariZen](https://github.com/BUTSpeechFIT/DiariZen)
- 参考実装: [pasrom/meeting-transcriber](https://github.com/pasrom/meeting-transcriber)
- Teams のメディアボット要件: [Microsoft Learn](https://learn.microsoft.com/en-us/microsoftteams/platform/bots/calls-and-meetings/requirements-considerations-application-hosted-media-bots)
- Google Meet Media API: [公式概要](https://developers.google.com/meet/media-api/guides/overview)
- Teams の録音・文字起こし: [Microsoft Learn](https://learn.microsoft.com/en-us/microsoftteams/meeting-recording) / [多言語の音声認識](https://support.microsoft.com/en-us/topic/650cb6d2-8a33-40e7-840d-36bb90216aa4)
- Meet の文字起こし: [Google ヘルプ](https://support.google.com/meet/answer/12849897)
