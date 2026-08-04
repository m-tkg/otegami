import Testing

/// MailCore2 の内部 thread-unsafety 対策の共通親スイート。
///
/// `MCOMessageParser`/`MCOAttachment` 等を並行に使うと、無関係なテストの
/// `plainTextBodyRendering()` 出力が壊れることがある (MessageBuilderTests が
/// M8 で経験的に確認 — `--no-parallel` では一度も再現せず)。当初は
/// `MessageBuilderTests` 単体への `.serialized` で足りていたが、
/// `.serialized` は**そのスイート内**しか直列化しないため、同一プロセスで
/// 並行実行される他のローカル系スイート (quoted-printable 抽出、
/// text/plain 抽出、カレンダー招待 MIME、envelope マッピング) との間で
/// 同じ破損が再発した (2026-08-04 の `make test` flake:
/// 日本語本文 round-trip の `renderedBody` が空相当になる)。
///
/// 対策: mailstack 不要で無条件実行される MailCore2 使用スイートを
/// すべてこの親スイートの extension としてぶら下げる — `.serialized` は
/// 再帰適用されるため、子スイート同士も相互に直列化される。これらは
/// すべて高速なローカルテストなので、直列化のコストは実質ゼロ。
/// `OTEGAMI_TEST_IMAP_HOST` でゲートされる統合テスト群は対象外
/// (無効時はボディが実行されず MailCore2 に触れないため)。
@Suite(.serialized)
enum MailCoreLocalSuite {}
