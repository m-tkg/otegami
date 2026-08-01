(function () {
  /* Task #205 (実機報告: 壊れた画像アイコン — 枠線付きの箱に青い「?」
     — がそのまま出るのは分かりにくい): 読み込みに失敗した `<img>` を、
     WebKit 既定の壊れたアイコンのままにせず、意図の分かる中立な
     プレースホルダ (画像アイコンに斜線を引いたもの、灰色) へ差し替える
     — ATS/ネットワーク不調/リンク切れなど、失敗理由を問わず同じ扱い。
     `#otegami-fit-inner img { ... }` (下の `<style>`) が
     `.otegami-image-load-failed` に薄い背景・破線枠を敷き、「元々ここは
     画像だった (けれど今は表示できない)」ことが伝わる見た目にする —
     `alt` 属性はそのまま残すので、ホバー/VoiceOver 等の代替テキストは
     従来どおり機能する。 */
  var otegamiImagePlaceholderDataURL = (function () {
    var svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">'
      + '<circle cx="17" cy="17" r="4" fill="#9a9a9a"/>'
      + '<path d="M6 34l11-11 8 8 6-6 11 11" fill="none" stroke="#9a9a9a" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/>'
      + '<line x1="4" y1="44" x2="44" y2="4" stroke="#9a9a9a" stroke-width="2.5" stroke-linecap="round"/>'
      + '</svg>';
    return 'data:image/svg+xml,' + encodeURIComponent(svg);
  })();
  function handleImageLoadFailure(img) {
    if (img.dataset.otegamiImageFailed) { return; }
    img.dataset.otegamiImageFailed = '1';
    img.classList.add('otegami-image-load-failed');
    img.src = otegamiImagePlaceholderDataURL;
  }
  // HTMLメールでも、送信者が`<a>`を付けず本文へ直接書いたhttp/https URLは
  // タップ可能にする。HTML文字列への正規表現置換はタグ属性や既存リンクを
  // 壊すため、パース済みDOMのテキストノードだけを対象にする。既存`a`と、
  // URLをコード例として見せる`code`/`pre`等はそのまま維持する。
  function linkifyBareHTTPURLs(root) {
    if (!root || root.hasAttribute('data-otegami-auto-links-applied')) { return; }
    root.setAttribute('data-otegami-auto-links-applied', '1');
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
    var nodes = [];
    var node;
    while ((node = walker.nextNode())) {
      var parent = node.parentElement;
      if (!parent || parent.closest('a, script, style, textarea, code, pre, noscript')) { continue; }
      if (/https?:\/\//i.test(node.nodeValue || '')) { nodes.push(node); }
    }

    nodes.forEach(function (textNode) {
      var text = textNode.nodeValue || '';
      var pattern = /https?:\/\/[^\s<>"']+/gi;
      var fragment = document.createDocumentFragment();
      var cursor = 0;
      var changed = false;
      var match;
      while ((match = pattern.exec(text))) {
        var candidate = trimURLTerminalPunctuation(match[0]);
        if (!candidate || !isHTTPURL(candidate)) { continue; }
        fragment.appendChild(document.createTextNode(text.slice(cursor, match.index)));
        var link = document.createElement('a');
        link.href = candidate;
        link.textContent = candidate;
        link.setAttribute('data-otegami-auto-link', '1');
        link.setAttribute('rel', 'noopener noreferrer');
        fragment.appendChild(link);
        cursor = match.index + candidate.length;
        changed = true;
      }
      if (!changed) { return; }
      fragment.appendChild(document.createTextNode(text.slice(cursor)));
      textNode.parentNode.replaceChild(fragment, textNode);
    });
  }
  function isHTTPURL(value) {
    try {
      var url = new URL(value);
      return url.protocol === 'http:' || url.protocol === 'https:';
    } catch (e) {
      return false;
    }
  }
  function trimURLTerminalPunctuation(value) {
    var result = value.replace(/[.,!?;:\u3001\u3002\uff01\uff1f\uff1b\uff1a]+$/g, '');
    var pairs = [['(', ')'], ['[', ']'], ['{', '}'], ['\uff08', '\uff09'], ['\uff3b', '\uff3d'], ['\uff5b', '\uff5d']];
    var changed = true;
    while (changed && result.length > 0) {
      changed = false;
      for (var i = 0; i < pairs.length; i++) {
        var openerCount = result.split(pairs[i][0]).length - 1;
        var closerCount = result.split(pairs[i][1]).length - 1;
        if (result.endsWith(pairs[i][1]) && closerCount > openerCount) {
          result = result.slice(0, -1);
          changed = true;
        }
      }
    }
    return result;
  }
  function waitForImages() {
    var all = Array.prototype.slice.call(document.images);
    // Task #205: an image that already finished (`complete === true`)
    // *before* this script ever runs but never actually decoded any
    // pixels (`naturalWidth === 0` — WebKit's own signal for "this URL
    // failed", distinct from a same-size 0x0 image, which essentially
    // never occurs in real mail) needs the same placeholder treatment —
    // it's excluded from `pending` below (nothing to wait for), so it
    // never reaches the `error` handler attached there.
    all.forEach(function (img) {
      if (img.complete && img.naturalWidth === 0) { handleImageLoadFailure(img); }
    });
    var pending = all.filter(function (img) { return !img.complete; });
    if (pending.length === 0) { return Promise.resolve(); }
    return Promise.all(pending.map(function (img) {
      return new Promise(function (resolve) {
        var settled = false;
        function finish() { if (!settled) { settled = true; resolve(); } }
        img.addEventListener('load', finish, { once: true });
        img.addEventListener('error', function () { handleImageLoadFailure(img); finish(); }, { once: true });
        setTimeout(finish, 4000);
      });
    }));
  }
  function relativeLuminance(rgb) {
    function channel(c) {
      var normalized = c / 255;
      return normalized <= 0.03928 ? normalized / 12.92 : Math.pow((normalized + 0.055) / 1.055, 2.4);
    }
    return 0.2126 * channel(rgb.r) + 0.7152 * channel(rgb.g) + 0.0722 * channel(rgb.b);
  }
  // Task #112 (実機報告 — ダークモードで実メール本文の暗色文字が沈む
  // 再現続報): `getComputedStyle(...).color`/`.backgroundColor` は
  // ソースが `#333333` (16進) でも `rgb(51, 51, 51)` (関数記法) でも
  // ブラウザ側で常にこの `rgb()`/`rgba()` 直列化に正規化されるため、
  // このパース自体はどちらの記法で著者が書いていても元々同じ結果になる
  // — 「16進しか対応していないのでは」という当初の疑いはここでは
  // 再現しなかった。とはいえ CSS Color 4 のスペース区切り記法
  // (`rgb(51 51 51 / 0.5)`、カンマなし・任意でスラッシュの後にアルファ)
  // をこの正規表現の`split(',')`一本槍では拾えなかった (パース失敗)
  // ため、カンマ区切り・スペース区切りのどちらも受け付けるよう
  // 頑健化しておく。
  function parseOpaqueColor(cssColor) {
    if (!cssColor) { return null; }
    var match = cssColor.match(/rgba?\(([^)]+)\)/);
    if (!match) { return null; }
    var alphaSplit = match[1].split('/');
    var parts = alphaSplit[0].split(/[\s,]+/).filter(function (part) { return part.length > 0; }).map(function (part) { return parseFloat(part); });
    var alpha = alphaSplit.length > 1 ? parseFloat(alphaSplit[1]) : (parts.length > 3 ? parts[3] : 1);
    if (!(alpha > 0)) { return null; }
    return { r: parts[0], g: parts[1], b: parts[2] };
  }
  function opaqueBackgroundOf(el) {
    if (!el) { return null; }
    return parseOpaqueColor(getComputedStyle(el).backgroundColor);
  }
  function findEffectiveBackground(inner) {
    var bodyColor = opaqueBackgroundOf(document.body);
    if (bodyColor) { return bodyColor; }
    var wrapperColor = opaqueBackgroundOf(inner);
    if (wrapperColor) { return wrapperColor; }
    var elements = inner.querySelectorAll('*');
    var limit = Math.min(elements.length, 800);
    var best = null;
    var bestArea = 0;
    for (var i = 0; i < limit; i++) {
      var el = elements[i];
      var color = opaqueBackgroundOf(el);
      if (!color) { continue; }
      var area = el.offsetWidth * el.offsetHeight;
      if (area > bestArea) { bestArea = area; best = color; }
    }
    // Task #84 (real-device report: a Google Calendar invite's HTML —
    // no `body`/wrapper background at all, just a small blue "Google
    // Meet に参加する" CTA button — rendered as washed-out gray-on-black
    // in dark mode instead of getting either remedy). Root cause: that
    // button was the *only* element in the whole document with any
    // background-color at all, so it trivially "won" the loop above as
    // the largest (only) candidate — `findEffectiveBackground` returned
    // its color, `decideDarkInversion` treated that as "the message's
    // real canvas color", and since a button's blue isn't `> 0.5`
    // luminance, concluded "already fine in dark mode" without ever
    // reaching the text-luminance fallback (this function's own doc
    // comment, `representativeTextLuminance`) that would have caught
    // the actually-dark, actually-unreadable gray label text. A CTA
    // button covering a sliver of the message isn't a credible stand-in
    // for its overall page background the way a `body`-level color or a
    // full-width "card" `<div>` is — requiring the candidate to cover a
    // real share of the rendered content (30% of `inner`'s own area)
    // before trusting it fixes this without touching the `body`/wrapper
    // tiers above (those are explicit, unambiguous page-level
    // declarations regardless of size).
    if (best && inner.offsetWidth > 0 && inner.offsetHeight > 0) {
      var innerArea = inner.offsetWidth * inner.offsetHeight;
      if (bestArea < innerArea * 0.3) { return null; }
    }
    return best;
  }
  function representativeTextLuminance(inner) {
    var walker = document.createTreeWalker(inner, NodeFilter.SHOW_TEXT, null);
    var node;
    var total = 0;
    var count = 0;
    while (count < 6 && (node = walker.nextNode())) {
      var text = node.nodeValue;
      if (!text || text.trim().length < 3) { continue; }
      var parentEl = node.parentElement;
      if (!parentEl) { continue; }
      var color = parseOpaqueColor(getComputedStyle(parentEl).color);
      if (!color) { continue; }
      total += relativeLuminance(color);
      count += 1;
    }
    return count > 0 ? total / count : null;
  }
  // Task #98: see `representativeTextLuminance`'s doc comment above
  // `fitToWidthScript` for why the 6-sample average above isn't always
  // enough. `nearestExplicitColorAncestor` walks up from a text node's
  // parent looking for the nearest ancestor (up to and including
  // `boundary`, normally `#otegami-fit-inner`) that declares `color`
  // explicitly — a literal declaration check, not `getComputedStyle`
  // (which always resolves to *some* color, explicit or inherited, and
  // so can't tell the two apart on its own).
  //
  // Task #104 (実機フィードバック: Readdle Documents のニュースレター等、
  // `<style>` ブロックの CSS クラスで文字色を指定するメールが検出漏れし
  // ダークネイティブのまま読めなかった): Task #98 版はインライン `style`
  // の `color` しか見ておらず、`<style>` ブロックのクラスセレクタ経由の
  // 明示指定を見落としていた。`selectors` (`collectExplicitColorSelectors`
  // が集めた、`color` 宣言を持つセレクタ文字列の配列) が渡されたときは
  // それも見る — `Element.matches()` でどのセレクタにもマッチしなければ
  // インライン判定のみだった従来の挙動のまま。
  function nearestExplicitColorAncestor(el, boundary, selectors) {
    var node = el;
    while (node) {
      if (node.style && node.style.color) { return node; }
      if (selectors && selectors.length && elementMatchesAnySelector(node, selectors)) { return node; }
      if (node === boundary) { return null; }
      node = node.parentElement;
    }
    return null;
  }
  // Task #104: `el.matches(selector)` throws on a selector this
  // WebKit build doesn't understand (e.g. a vendor-prefixed pseudo-class
  // some ESP template generator emits) — caught and skipped per-selector
  // so one unsupported selector in a message's `<style>` block doesn't
  // abort the whole scan, consistent with this file's other "don't let
  // one weird input wreck the whole heuristic" choices (e.g.
  // `stripHTMLComments`'s regex-compile fallback).
  function elementMatchesAnySelector(el, selectors) {
    for (var i = 0; i < selectors.length; i++) {
      try {
        if (el.matches(selectors[i])) { return true; }
      } catch (e) { /* unsupported selector syntax — skip it */ }
    }
    return false;
  }
  // Task #104: walks `document.styleSheets` to collect every selector
  // whose rule declares a `color` — this is what lets
  // `nearestExplicitColorAncestor` recognize "explicit color" set via a
  // CSS class in a `<style>` block, not just an inline `style="color:
  // ..."` attribute. Skips any sheet whose owning `<style>`/`<link>`
  // element carries `data-otegami-base-style` (`HTMLDocumentBuilder
  // .wrap`'s own injected `<style>` tags — the base reset, the dark-
  // invert/keep-light styles, `forceLightBackgroundStyle`) so this
  // file's own rules (e.g. `a { color: LinkText; }`) never get mistaken
  // for the *message author's* explicit color intent — only
  // `originalHeadStyles` (the message's own extracted `<style>` blocks,
  // left unmarked) is scanned. External stylesheets can't appear here at
  // all (this app strips remote resources via `WKContentRuleList`
  // before the page ever loads one), so a same-document walk is
  // complete on its own — no CORS-blocked `cssRules` access to worry
  // about for *message* stylesheets (a `try`/`catch` around the access
  // is still cheap insurance). `collectRulesInto` recurses into grouping
  // rules (`@media`/`@supports`/etc, anything exposing its own
  // `.cssRules`) regardless of whether the rule's own condition matches
  // the current environment — a `@media (prefers-color-scheme: dark)`
  // block a newsletter ships alongside its light-mode default still
  // reflects the author's intent to color that text explicitly, so it
  // counts too (deliberately erring toward *more* explicit-color
  // detections here, matching this whole heuristic's existing bias per
  // its Task #98 doc comment above `fitToWidthScript`).
  function collectExplicitColorSelectors() {
    var selectors = [];
    var sheets = document.styleSheets;
    for (var s = 0; s < sheets.length; s++) {
      var sheet = sheets[s];
      var ownerNode = sheet.ownerNode;
      if (ownerNode && ownerNode.hasAttribute && ownerNode.hasAttribute('data-otegami-base-style')) { continue; }
      var rules;
      try { rules = sheet.cssRules; } catch (e) { continue; }
      if (rules) { collectRulesInto(rules, selectors); }
    }
    return selectors;
  }
  function collectRulesInto(rules, selectors) {
    for (var i = 0; i < rules.length; i++) {
      var rule = rules[i];
      if (typeof rule.selectorText === 'string' && rule.style && rule.style.color) {
        selectors.push(rule.selectorText);
      } else if (rule.cssRules) {
        collectRulesInto(rule.cssRules, selectors);
      }
    }
  }
  // Task #98: character-count based (not a fixed sample of 6 nodes) —
  // walks every text node under `inner`, and for each one that falls
  // under an explicitly `color`-declared ancestor, measures that
  // ancestor's actual rendered color (`getComputedStyle` *is* used here,
  // just to resolve the real rgb() value once a node has already
  // qualified as "explicitly colored" — this is the "measuring" half,
  // separate from the "is it explicit" question `nearestExplicit
  // ColorAncestor` answers on its own). Text with no explicitly colored
  // ancestor at all (pure inheritance — e.g. a color-less heading, or a
  // hidden preheader line) is counted toward the visible-text total but
  // never toward the "explicit dark" bucket, which is exactly what keeps
  // a genuinely colorless plain-text-style message from tripping this
  // (its explicit-dark share stays at 0%, never a majority). Capped at
  // 4000 visited text nodes purely as a cheap safety net against a
  // pathological document, matching this file's other such caps (`findEffectiveBackground`'s 800-element cap).
  //
  // Task #104: `selectors` is computed once per call (not per text
  // node) via `collectExplicitColorSelectors` and threaded through to
  // `nearestExplicitColorAncestor` — cheap relative to the 4000-node cap
  // above it, and keeps the stylesheet walk out of the hot per-node loop.
  // Task #112 (実機報告続報 — 実メールで再現): プリヘッダの隠しダミー
  // テキスト (`color:transparent; visibility:hidden; font-size:0px`
  // 等、メール配信ツールが受信箱プレビュー文言を制御するために埋め込む
  // 定番パターン — 実際の readdle.eml の例では不可視の結合文字を
  // 大量に含む数百文字級のダミー行だった) が、可視本文と区別なく
  // `explicitDarkTextIsMajority` の分母 (`totalLength`) に算入されて
  // いた。可視本文がどれだけ暗色主体でも、この巨大な不可視テキストが
  // 分母を水増しして過半数判定 (`> totalLength / 2`) を割ってしまい
  // うる — 実機で再現した「本文が沈む」の一因。`display:none` は
  // 継承されないため祖先チェーンを歩いて確認し、`visibility`/
  // `font-size`/文字色の不透明度は継承されるので直近の親だけで判定
  // すれば十分 (`opacity` は継承されないので同じ祖先チェーンで見る)。
  function isVisuallyHiddenText(parentEl, boundary) {
    var node = parentEl;
    while (node) {
      var ancestorStyle = getComputedStyle(node);
      if (ancestorStyle.display === 'none') { return true; }
      var opacity = parseFloat(ancestorStyle.opacity);
      if (!isNaN(opacity) && opacity <= 0) { return true; }
      if (node === boundary) { break; }
      node = node.parentElement;
    }
    var style = getComputedStyle(parentEl);
    if (style.visibility === 'hidden') { return true; }
    var fontSize = parseFloat(style.fontSize);
    if (!isNaN(fontSize) && fontSize <= 0) { return true; }
    if (parseOpaqueColor(style.color) === null) { return true; }
    return false;
  }
  function explicitDarkTextIsMajority(inner) {
    var selectors = collectExplicitColorSelectors();
    var walker = document.createTreeWalker(inner, NodeFilter.SHOW_TEXT, null);
    var node;
    var visited = 0;
    var totalLength = 0;
    var explicitDarkLength = 0;
    while (visited < 4000 && (node = walker.nextNode())) {
      visited += 1;
      var text = node.nodeValue;
      if (!text) { continue; }
      var trimmed = text.trim();
      if (trimmed.length === 0) { continue; }
      var parentEl = node.parentElement;
      if (!parentEl) { continue; }
      if (isVisuallyHiddenText(parentEl, inner)) { continue; }
      totalLength += trimmed.length;
      var colorEl = nearestExplicitColorAncestor(parentEl, inner, selectors);
      if (!colorEl) { continue; }
      var color = parseOpaqueColor(getComputedStyle(parentEl).color);
      if (!color) { continue; }
      // 0.55: slightly looser than `representativeTextLuminance`'s 0.5
      // — this is meant to also catch white-background-assuming
      // mid-grays (`#5f6368`前後、Google 系テンプレート頻出) that read
      // fine on white but wash out on a dark canvas, not just clearly
      // "dark" text. Starting point per Task #98's spec; adjust here if
      // real-world verification (`docs/design-system.md`のTask #98節)
      // finds it too aggressive or not aggressive enough.
      if (relativeLuminance(color) < 0.55) {
        explicitDarkLength += trimmed.length;
      }
    }
    return totalLength > 0 && explicitDarkLength > totalLength / 2;
  }
  // 古いテーブル型メールには、ページ全体の背景を持たず、見出し行だけ
  // `background-color:#e1edf3` のような明色を固定し、その中の文字色は
  // ブラウザ既定に任せるものがある。Otegami の `CanvasText` はダーク時に
  // 白へ適応するため、この組み合わせだけ「明背景に白文字」になる。
  // `findEffectiveBackground` の30%面積条件では意図的に小さい局所背景を
  // 無視するため、ページ全体判定とは別に局所的な配色不整合を調べる。
  //
  // 著者が色を明示した文字はライト固定にしても変化しないため対象外。
  // また、明背景要素の内側に暗背景のヒーロー等がネストしている場合は、
  // テキストから最も近い不透明背景が検査中の明背景自身であるときだけ
  // 数える。これにより「白いbody内の暗いヒーロー＋白文字」を誤検出しない。
  function nearestOpaqueBackgroundElement(el, boundary) {
    var node = el;
    while (node) {
      if (opaqueBackgroundOf(node)) { return node; }
      if (node === boundary) { break; }
      node = node.parentElement;
    }
    return null;
  }
  function hasAdaptiveLightTextOnLightBackground(inner) {
    var selectors = collectExplicitColorSelectors();
    var elements = inner.querySelectorAll('*');
    var limit = Math.min(elements.length, 800);
    for (var i = 0; i < limit; i++) {
      var backgroundElement = elements[i];
      var background = opaqueBackgroundOf(backgroundElement);
      if (!background || relativeLuminance(background) <= 0.5) { continue; }

      var walker = document.createTreeWalker(backgroundElement, NodeFilter.SHOW_TEXT, null);
      var node;
      var visited = 0;
      var adaptiveLightLength = 0;
      while (visited < 200 && (node = walker.nextNode())) {
        visited += 1;
        var text = node.nodeValue;
        if (!text) { continue; }
        var trimmed = text.trim();
        if (trimmed.length === 0) { continue; }
        var parentEl = node.parentElement;
        if (!parentEl || isVisuallyHiddenText(parentEl, inner)) { continue; }
        if (nearestOpaqueBackgroundElement(parentEl, backgroundElement) !== backgroundElement) { continue; }
        if (nearestExplicitColorAncestor(parentEl, inner, selectors)) { continue; }
        var color = parseOpaqueColor(getComputedStyle(parentEl).color);
        if (!color || relativeLuminance(color) <= 0.55) { continue; }
        adaptiveLightLength += trimmed.length;
        // 単独の記号・短いバッジではなく、実際の見出し行相当だけを拾う。
        if (adaptiveLightLength >= 8) { return true; }
      }
    }
    return false;
  }
  function decideDarkInversion() {
    var outer = document.getElementById('otegami-fit-outer');
    var inner = document.getElementById('otegami-fit-inner');
    if (!outer || !inner || !outer.hasAttribute('data-otegami-invert-check')) { return; }
    if (!window.matchMedia || !window.matchMedia('(prefers-color-scheme: dark)').matches) { return; }
    // Task #80: whether this document, if left untouched, would look
    // broken in dark mode — the measurement itself is unchanged from
    // Task #51/#56 (see this function's doc comment above `fitToWidthScript`
    // for the full history). What's new is `preferInvert`: which of the
    // two remedies below actually gets applied once `shouldIntervene`
    // is true.
    var preferInvert = outer.hasAttribute('data-otegami-prefer-invert');
    var background = findEffectiveBackground(inner);
    var shouldIntervene = false;
    if (background) {
      var backgroundLuminance = relativeLuminance(background);
      if (backgroundLuminance > 0.5) {
        var textLuminance = representativeTextLuminance(inner);
        shouldIntervene = textLuminance === null || textLuminance < backgroundLuminance;
        // Task #112 (実機報告続報 — 明るい背景を持つ実メールでも本文が
        // 沈む再現): `representativeTextLuminance` は文書順で最初に
        // 見つかった非空白テキストノード最大6件の平均でしかない。
        // readdle.eml のような「上部にヒーロー見出し (白文字・写真背景)
        // → その後に本文段落 (#333333 系の暗色文字)」という構成の
        // メールでは、その6件の大半または全部がヒーロー側の明るい文字
        // に偏り、後続の暗色本文が一度もサンプリングされないまま
        // 「介入不要」に確定してしまっていた — Task #98/#104 で追加した
        // `explicitDarkTextIsMajority` (可視テキスト全体を文字数ベースで
        // 走査する、こちらの方が頑健) はこれまで背景が見つからない
        // (`else`側) ケースのフォールバックとしてしか呼ばれておらず、
        // 背景ありのこの分岐には一度も届いていなかった — Task #104 の
        // 修正が実際には多くの実メール (背景色を持つのが普通) で
        // 効いていなかった根本原因。6サンプル平均が「介入不要」と
        // 出た場合のみ、同じ全文走査をここでもフォールバックとして
        // 試す。
        if (!shouldIntervene) {
          shouldIntervene = explicitDarkTextIsMajority(inner);
        }
      }
    } else {
      // Task #56 (実機フィードバック: TestFlight通知メール — 背景色を
      // 一切指定せず、文字色だけ #444 系の濃色で明示指定しているメール
      // がダークモードで暗地に暗文字になり読めなかった): 背景が最後まで
      // 解決しない (=`findEffectiveBackground`がnullを返す) からといって
      // 「介入不要」で確定させず、実測した代表的な文字色の輝度が低い
      // (暗い) ときだけ追加で介入する。判定の鍵は「文字色を明示指定して
      // いないメール (32番フィクスチャ) では `color: CanvasText`
      // (このファイル自身のCSSリセット) がダークモード中は既に明るい色
      // へ自動解決されている」という事実 — `getComputedStyle(...).color`
      // で実測すれば、CanvasText由来の明るい文字色と、著者が明示指定した
      // 暗い文字色は輝度の実測値だけで区別でき、どちらのケースかを別途
      // 覚えておく仕組みは要らない (32番フィクスチャがこの分岐に入って
      // しまわないことは、WKWebViewでの実測で確認済み — ダークモード中の
      // CanvasTextの輝度は1.0、著者明示の#444は0.058)。背景がそもそも
      // 無い (透明) メールを反転しても、透明ピクセルはCSS `filter:
      // invert()`でもアルファ非対象のため透明のまま (アプリのダーク
      // 背景がそのまま透けて見える) — 効果は文字色 (と、img/videoは
      // 二重反転で打ち消し済みの通り) にしか出ない。ライト維持
      // (Task #80 の新既定) の側は、このケースでも`html`/`body`の
      // 背景を白へ強制するCSSが効くので、透明のままにはならない。
      var textLuminance = representativeTextLuminance(inner);
      shouldIntervene = textLuminance !== null && textLuminance < 0.5;
      // Task #98: only tried as a second-pass fallback when the 6-sample
      // average above didn't already call for intervention — see
      // `explicitDarkTextIsMajority`'s doc comment for why that average
      // can miss a message whose readable-on-white body text doesn't
      // happen to be among the first 6 text nodes in document order.
      if (!shouldIntervene) {
        shouldIntervene = explicitDarkTextIsMajority(inner);
      }
    }
    if (!shouldIntervene) {
      shouldIntervene = hasAdaptiveLightTextOnLightBackground(inner);
    }
    var shouldInvert = shouldIntervene && preferInvert;
    var shouldKeepLight = shouldIntervene && !preferInvert;
    inner.classList.toggle('otegami-invert-for-dark', shouldInvert);
    // 実機フィードバック (MakerWorld比較 — 右端の白帯・セクション間の
    // 色ムラ): `html.otegami-invert-active`は反転を実際に決めたときだけ
    // 付き、`body`/`html`自身の背景を強制的に透明化するCSS (上の
    // `<style>`) を有効にする。`document.body`自身の背景が「有効な
    // 背景」の発見源だった場合、その色を`#otegami-fit-inner`自身に
    // 移し替える — こうしておかないと、`body`側を透明化した途端に
    // ページ全体の「キャンバス色」そのものが消えてアプリの暗い背景が
    // そのまま透けるだけになり、`#otegami-fit-inner`が変わらず反転
    // フィルタを持っていても対象の色そのものが無くなってしまう。
    // 反転しないと決まった場合は、以前の呼び出し (1iの翻訳後再適用等)
    // で移し替えた値が残っていれば元に戻す。
    document.documentElement.classList.toggle('otegami-invert-active', shouldInvert);
    if (shouldInvert) {
      var bodyOwnBackground = opaqueBackgroundOf(document.body);
      if (bodyOwnBackground && !inner.style.backgroundColor) {
        inner.style.backgroundColor = getComputedStyle(document.body).backgroundColor;
      }
    } else {
      inner.style.backgroundColor = '';
    }
    // Task #80 (新既定): ライト維持は画像・ロゴに一切手を加えない
    // (反転していないので、色を打ち消す必要も白チップを敷く必要も
    // ない) — `html`自身のクラス切り替えだけで済む。
    document.documentElement.classList.toggle('otegami-keep-light-active', shouldKeepLight);
    decideLogoChips(inner, shouldInvert);
  }
  /* 実機フィードバック (MakerWorldロゴが暗背景に沈む): 反転対象の画像の
     うち、内在サイズが小さい (ロゴ/アイコン相当) ものにだけ、読める
     ようにするための白系チップ背景を敷くクラスを付け外しする —
     付与条件のCSS本体は`HTMLDocumentBuilder.wrap`側の`<style>`コメント
     参照。写真本体は大抵もっと大きいサイズで来るため、この閾値
     (200px以下) だけでも実用上ほとんど誤爆しない、という現実的な
     割り切り。 */
  function decideLogoChips(inner, shouldInvert) {
    var images = inner.querySelectorAll('img');
    for (var i = 0; i < images.length; i++) {
      var img = images[i];
      var isLogoSized = shouldInvert && img.naturalWidth > 0 && img.naturalWidth <= 200 && img.naturalHeight > 0 && img.naturalHeight <= 200;
      img.classList.toggle('otegami-invert-logo-chip', isLogoSized);
    }
  }
  function fit() {
    var outer = document.getElementById('otegami-fit-outer');
    var inner = document.getElementById('otegami-fit-inner');
    if (!outer || !inner) { return { otegamiDiagError: 'missing-outer-or-inner' }; }
    inner.style.transform = 'none';
    inner.style.transformOrigin = '';
    inner.style.width = '';
    outer.style.width = '';
    outer.style.height = '';
    var viewportWidth = outer.clientWidth;
    var naturalWidth = Math.max(inner.scrollWidth, inner.offsetWidth);
    var naturalHeight = Math.max(inner.scrollHeight, inner.offsetHeight);
    // Task #58 diagnostic instrumentation (temporary — removed once the
    // root cause is found): every candidate height signal at the moment
    // `fit()` runs, so a real-device repro can be told apart from "scale
    // path never even ran" vs. "scale path ran and picked a too-small
    // height" vs. "no scale needed but something *else* clips the
    // WKWebView's own frame".
    var diag = {
      otegamiDiagViewportWidth: viewportWidth,
      otegamiDiagNaturalWidth: naturalWidth,
      otegamiDiagNaturalHeight: naturalHeight,
      otegamiDiagInnerScrollHeight: inner.scrollHeight,
      otegamiDiagInnerOffsetHeight: inner.offsetHeight,
      otegamiDiagOuterScrollHeight: outer.scrollHeight,
      otegamiDiagOuterClientHeight: outer.clientHeight,
      otegamiDiagBodyScrollHeight: document.body.scrollHeight,
      otegamiDiagDocElScrollHeight: document.documentElement.scrollHeight,
      otegamiDiagWindowInnerHeight: window.innerHeight,
      otegamiDiagWindowInnerWidth: window.innerWidth,
      otegamiDiagScaled: false
    };
    if (!viewportWidth || naturalWidth <= viewportWidth + 1) { return diag; }
    var scale = viewportWidth / naturalWidth;
    inner.style.width = naturalWidth + 'px';
    inner.style.transformOrigin = 'top left';
    inner.style.transform = 'scale(' + scale + ')';
    outer.style.width = viewportWidth + 'px';
    outer.style.height = Math.ceil(naturalHeight * scale) + 'px';
    diag.otegamiDiagScaled = true;
    diag.otegamiDiagScale = scale;
    diag.otegamiDiagOuterHeightSet = Math.ceil(naturalHeight * scale);
    return diag;
  }
  // Task #58 (根治): the actual fix — report this document's real
  // content height back to Swift via the `otegamiHeight` message
  // handler, every time it might have changed. `postHeight` alone
  // (called once, right after `fit()`) covers the common case; the
  // `ResizeObserver` below additionally catches later changes this same
  // script doesn't otherwise revisit — 1i's translation overlay
  // rewriting text nodes (rarely the same pixel height as the original)
  // is the realistic one, but this is deliberately general rather than
  // re-deriving the exact set of callers that might change layout.
  // `data-otegami-height-observer` guards against attaching a second
  // observer on a later `applyFitToWidth` call against the same
  // still-alive document (the 1.5s safety net, or 1i's post-mutation
  // reapply) — `WKWebView.loadHTMLString` always produces a brand-new
  // `document`, so a fresh load never sees this attribute already set.
  //
  // Task #59 (「本文下の空白が過剰」): this used to report
  // `Math.max(document.documentElement.scrollHeight,
  // document.body.scrollHeight)` — the *whole document's* height,
  // which includes `#otegami-bottom-inset-spacer` (`body`'s sibling to
  // `#otegami-fit-outer`, injected only when `bottomContentInset > 0` —
  // see `HTMLDocumentBuilder.wrap`'s doc comment). That was deliberate
  // at the time (Task #58's doc comment above, now superseded):
  // Swift's frame budget had no other way to know the spacer existed.
  // But `HTMLMessageView`'s `bottomContentInset` is always `0` now
  // (Task #59 moved the "leave room for the floating buttons"
  // reservation to `ThreadDetailView`'s own outer `ScrollView`, applied
  // exactly once instead of once per message body — see
  // `MessageView.content`'s doc comment on its HTML branch), so in
  // practice this rarely differs today — but reporting the *whole
  // document* was always measuring the wrong thing conceptually, and
  // silently reintroduces a double-counted blank space the moment any
  // future caller passes a non-zero `bottomContentInset` again. Measure
  // `#otegami-fit-outer` itself instead — the fit-to-width scaffold
  // `fit()` (above) already sizes explicitly to the real, post-scale
  // content box (`outer.style.height`/`outer.style.width` when scaled;
  // its natural laid-out size otherwise) and is a strict sibling of the
  // spacer, never a container for it — so its own
  // `getBoundingClientRect().height` is exactly the core content height,
  // with no spacer (or anything else `body` might ever grow to include)
  // mixed in. Falls back to the old whole-document measurement only if
  // `#otegami-fit-outer` is somehow missing (shouldn't happen — `fit()`
  // above already returns early with a diagnostic error in that case —
  // but this function has no reason to crash over it).
  // Task #64 (根治: 実機報告「HTML本文の最終行が半分欠ける」): walks the
  // "last child" chain from `root` (normally `#otegami-fit-inner`),
  // comparing each level's own rendered bottom edge and keeping the
  // largest one seen. `outer.getBoundingClientRect().height` alone (the
  // previous, Task #58 measurement) trusts `outer`'s own laid-out box —
  // which on this toolchain was observed to sometimes come up a few
  // dozen points short of where the *last line of real content* actually
  // paints (a trailing child's own bottom margin not fully reflected in
  // its ancestor's auto height is the leading suspect, though a WebKit-
  // level layout/paint discrepancy on this specific toolchain can't be
  // ruled out either — this fix doesn't depend on pinning down which).
  // Walking `lastElementChild` is cheap (bounded by DOM depth, not
  // breadth) and `Math.max` at each step is a defensive measure against
  // a last-in-markup child that isn't also the visually lowest one
  // (e.g. an absolutely-positioned or floated element later in the
  // document) — this only ever *increases* the reported height,
  // matching the reported symptom (content cut short), never decreases
  // it below what a correct measurement would already have given.
  function deepestLastBottom(root) {
    var bottom = root.getBoundingClientRect().bottom;
    var el = root.lastElementChild;
    while (el) {
      var rect = el.getBoundingClientRect();
      if (rect.bottom > bottom) { bottom = rect.bottom; }
      el = el.lastElementChild;
    }
    return bottom;
  }
  function postHeight() {
    var outer = document.getElementById('otegami-fit-outer');
    var height;
    if (outer) {
      var outerRect = outer.getBoundingClientRect();
      var inner = document.getElementById('otegami-fit-inner');
      // Task #64: the larger of (a) `outer`'s own measured bottom edge
      // (the previous, sole signal) and (b) the deepest-last-child walk
      // from `inner` — see `deepestLastBottom`'s doc comment. `+ 4`
      // (beyond the `Math.ceil` rounding this already had) is a small,
      // fixed safety margin for exactly this kind of sub-pixel/rounding
      // shortfall — cheap insurance against a one- or two-point clip
      // that would otherwise still shave the very bottom of the last
      // line, and small enough that it reads as "a hair of breathing
      // room", not a new "空き帯が出る" regression of its own (the
      // `reservedBottomInset` fix right above this file's own doc
      // comment is what actually matters for that report; this `+4` is
      // two orders of magnitude smaller).
      var contentBottom = inner ? deepestLastBottom(inner) : outerRect.bottom;
      var bottom = Math.max(outerRect.bottom, contentBottom);
      height = Math.ceil(bottom - outerRect.top) + 4;
    } else {
      height = Math.max(document.documentElement.scrollHeight, document.body.scrollHeight);
    }
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.otegamiHeight) {
      window.webkit.messageHandlers.otegamiHeight.postMessage(height);
    }
  }
  function ensureHeightObserver() {
    if (document.documentElement.hasAttribute('data-otegami-height-observer')) { return; }
    document.documentElement.setAttribute('data-otegami-height-observer', '1');
    if (typeof ResizeObserver === 'undefined') { return; }
    var scheduled = false;
    var observer = new ResizeObserver(function () {
      if (scheduled) { return; }
      scheduled = true;
      requestAnimationFrame(function () { scheduled = false; postHeight(); });
    });
    observer.observe(document.documentElement);
  }
  return waitForImages().then(function () {
    linkifyBareHTTPURLs(document.getElementById('otegami-fit-inner'));
    decideDarkInversion();
    // Task #58 diagnostic instrumentation (temporary): stash the
    // measurement into a DOM attribute instead of returning it —
    // `evaluateJavaScript` (both the closure-completion-handler overload
    // *and* the `async` one) fails with WKErrorDomain Code=5
    // "JavaScript execution returned a result of an unsupported type"
    // for *any* value resolved via this script's Promise chain, on this
    // toolchain/simulator — confirmed with both overloads, and even for
    // a trivial JSON string. A later, wholly separate, plain synchronous
    // `evaluateJavaScript` call (no Promise involved) reads this
    // attribute back and *does* bridge successfully — the same shape
    // `HTMLTranslationController.extractTranslatableTexts()`'s working
    // synchronous IIFE already relies on elsewhere in this file — so the
    // bug is specific to bridging a Promise-resolved value, not to
    // complex values in general.
    document.documentElement.setAttribute('data-otegami-diag', JSON.stringify(fit()));
    postHeight();
    ensureHeightObserver();
  });
})();
