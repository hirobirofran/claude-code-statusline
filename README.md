# claude-code-statusline

Claude Code のステータスラインに、モデル名と使用率を表示するスクリプトです。使用率が閾値を跨ぐと、Windows のトースト通知を一度だけ出します。ネットワークアクセスも LLM 呼び出しも行いません。

```
[Sonnet 5] | ctx 42% | 5h 63% | 7d 18%
```

## 表示内容

- `[モデル名]`：`model.display_name`。高額モデルの正規表現に一致すると `[!! モデル名 !!]` と赤の太字になる
- `ctx`：コンテキストウィンドウの使用率
- `5h`：5時間枠のレート制限使用率
- `7d`：7日枠のレート制限使用率

使用率は 50% 以上で黄色、80% 以上で赤になります。

## 構成

```
windows/claude-statusline.ps1   Windows PowerShell 用
macos/                          追加予定
```

## インストール（Windows）

リポジトリをクローンし、`~/.claude/settings.json` の `statusLine` からクローン先のスクリプトを直接指します。`~/.claude/` へはコピーしません。コピーすると実ファイルとリポジトリの二重管理になるためです。

```json
{
  "statusLine": {
    "type": "command",
    "command": "powershell -NoProfile -File \"C:/<クローン先>/claude-code-statusline/windows/claude-statusline.ps1\""
  }
}
```

パスは自分のクローン先に合わせてください。この方式なら、`git pull` やスクリプトの編集がそのままステータスラインに反映されます。

### Unblock-File の注意

ブラウザ経由（ZIP や Raw の保存）で入手したファイルには、Windows が「インターネットから取得した」印を付けます。実行ポリシーが `RemoteSigned` だと、この印が付いたスクリプトは実行されず、ステータスラインに何も出ません。その場合はブロックを解除します。

```powershell
Unblock-File windows\claude-statusline.ps1
```

`git clone` で取得したファイルには印が付かないため、この手順は不要です。

## カスタマイズ

設定はスクリプト冒頭の `# ---- settings ----` にまとまっています。編集内容は次の描画から反映されます。

### 通知の閾値

`$Thresholds` の配列を書き換えます。単位はパーセントです。

```powershell
$Thresholds   = @(50, 80, 95)          # percent
```

再武装に必要な下げ幅は `$Hysteresis` で変えられます。既定は 5 ポイントです。

```powershell
$Hysteresis   = 5                      # percent points a value must drop below the last threshold to re-arm
```

文字色の境目（50% で黄、80% で赤）は通知の閾値と連動しません。変える場合は `Paint` 関数内の数値を直接編集します。

### 強調するモデル名

`$ExpensiveRe` は `model.display_name` に対する正規表現で、大文字小文字を区別しません。複数のモデルを対象にするなら `|` でつなぎます。

```powershell
$ExpensiveRe  = 'fable|opus'
```

## 仕様

### 通知

通知の対象は `5h` と `7d` です。`ctx` は通知しません。

- 使用率が閾値を跨いだら、一度だけ通知する。同じ閾値では再通知しない
- 複数の閾値を一度に跨いだ場合は、最も高い閾値の通知を 1 回だけ出す
- 使用率が最後に通知した閾値から 5 ポイント超下がったら、通知せずに再武装する。再武装後の基準は、その時点で通過済みの最大の閾値になる
- 5 ポイント以内の下振れは無視する。状態は変わらず、通知も出ない

小さな下振れを無視するのは、複数のターミナルを開いていると、セッションごとに古い使用率が渡されることがあるためです。状態ファイルは全セッションで共有なので、無視しないと閾値付近で通知が鳴り直します。

最後に通知した閾値は `~/.claude/statusline-alert-state.json` に保存します。通知を最初からやり直したいときは、このファイルを削除してください。

通知は Windows 標準のトースト通知で、「Windows PowerShell」の名義で表示されます。通知センターに残るので、見逃してもあとから確認できます。トレイアイコンのバルーン通知を使わないのは、アイコンを破棄した時点で通知センターからも消えるためです。

通知は、スクリプトが自分自身を `-Notify` 付きの別プロセスで起動して送ります。ステータスラインの描画は通知を待ちません。送信には Windows PowerShell 5.1 が必要です。PowerShell 7 では、トーストに使う WinRT の型を読み込めません。

### rate_limits が無いとき

入力 JSON に `rate_limits` が無い場合、`5h` と `7d` は `--` と表示します。通知は行わず、状態ファイルも更新しません。`rate_limits` は Claude.ai のサブスクリプション利用時に、セッション最初の API 応答以降で渡されます。

入力が JSON として読めなかった場合は `[statusline: bad input]` と表示します。

## 開発時の注意

`windows/claude-statusline.ps1` は ASCII のみで書きます。PowerShell 5.1 は BOM なしの UTF-8 を ANSI（日本語環境では CP932）として読むため、非 ASCII 文字が混ざると文字化けや構文エラーの原因になります。コメントも英語で書いてください。
