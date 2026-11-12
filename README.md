# 記録音

Mac の再生音とマイクを、別々の字幕としてその場で文字にするアプリ。文字と音声は自分の Mac に残る。

動作の詳細は [docs/README.md](docs/README.md)。

## 必要なもの

- Apple Silicon の Mac
- macOS 26
- Command Line Tools（`swiftc` と `codesign`。未導入なら `xcode-select --install`）
- 画面収録の許可まで通す場合は Xcode と Apple ID（無料のアカウントでよい）

## 署名の証明書を作る

画面収録の許可は、Team ID のある証明書で署名したアプリに付く。アドホック署名のままでは、システム設定でオンにしてもアプリ側は未許可のままになる。

Xcode があるときは、次で Apple Development を作る。

1. Xcode を開き、Settings → Accounts で Apple ID を追加する。
2. 追加したアカウントを選び、Manage Certificates… から Apple Development を作る。

Xcode が無いときは、この Mac の中に自己署名の証明書を作る。確認のダイアログが出ることがある。

```bash
./scripts/make-signing-identity.sh
```

この証明書には Team ID が無い。画面収録が拒否されたままになることがある。録音まで通すには、上の Apple Development でビルドし直す。

証明書ができているかは、次で確認できる。`Apple Development:` または `local-transcription-dev` の行が出ればよい。

```bash
security find-identity -v -p codesigning
```

## ビルドして開く

clone したディレクトリで実行する。`~/Applications/記録音.app` に入り、同じ場所を置き換える。

```bash
./build.sh
open "$HOME/Applications/記録音.app"
```

## ソースが更新されたとき

録音中なら止めてから、記録音を終了する。clone したディレクトリで、次を実行する。

```bash
git pull
./build.sh
open "$HOME/Applications/記録音.app"
```

`./build.sh` は `~/Applications/記録音.app` を同じ証明書で置き換える。マイクと画面収録の許可は残る。録音と頻出ワードは `~/Library/Application Support/LocalTranscription/` にあり、置き換えても残る。

証明書を変えて署名し直したときは、画面収録の許可を付け直す。

## 初回に許可すること

開始を押すと、マイクと画面収録を求める。

1. システム設定の「プライバシーとセキュリティ」→「マイク」で記録音をオンにする。
2. 同じ場所の「画面収録とシステムオーディオ録音」で記録音をオンにする。オンにしたあとはアプリを終了し、開き直す。
3. もう一度開始する。日本語の認識モデルが無ければ、その場でダウンロードする。アプリが通信するのは、このダウンロードだけ。

どちらかが拒否されているあいだ、ウィンドウのボタンは「設定」になり、該当するシステム設定を開く。署名を変えてビルドし直したあとは、画面収録の許可を付け直す。

## 録音する

ヘッドホンを付ける。スピーカーだと相手の声がマイクに入り、「自分」の行にも出る。

開始と停止のショートカットは ⌘⇧R。再生音は「相手」、マイクは「自分」になる。停止すると保存され、名前を聞きます。空欄のまま閉じても残ります。

文字と音声は `~/Library/Application Support/LocalTranscription/sessions/` に残る。フォルダの中は `transcript.txt`、`audio-system.wav`（相手）、`audio-mic.wav`（自分）。
