# このフォルダについて

`README.md` は作業機のローカルの Downloads フォルダ配下
(`design_handoff_ios_mail/`) からそのまま取り込んだハンドオフ本体
(Claude Design 作成、2026-07 時点)。

## `wireframes-standalone.html` を意図的に含めていない

元フォルダには全ワイヤーフレームをまとめた `wireframes-standalone.html`
(約 2.9MB) が同梱されているが、このリポジトリには取り込んでいない。理由:

- otegami は public リポジトリ。3MB のロービジュアルなプロトタイプ HTML を
  git 履歴に永久に残す価値と比べ、`README.md` のテキストで意思決定 (構造
  1a / 一覧 1d / 操作 1g+1h+1i) は既に確定・記録済みで、実装の参照として
  必要な情報は `README.md` だけでほぼ足りる。
- ワイヤーは low-fidelity (灰色バー＝テキスト、破線＝区切り) の**意思決定
  用**プロトタイプであり、実装仕様そのものではない (`README.md` 冒頭に
  明記)。決定が済んだ後の実装フェーズでは、レイアウト/動線の参照は
  `README.md` の各画面の説明文で足り、HTML を都度開く必要性は薄い。
- 万一 HTML 側の細部 (例: 1e/1f のような不採用案の詳細) を見返したくなった
  場合は、作業機のローカルの Downloads フォルダ配下にある
  `design_handoff_ios_mail/wireframes-standalone.html` を参照するか、
  元データが失われていれば再度ハンドオフを生成すればよい。

必要と判断されれば、後続フェーズで改めて取り込むことを妨げない。
