// 補助金診断。data.json（Ｊグランツの受付中案件）と、ページに埋め込んだ主要補助金の情報から、条件に合うものを表示する。
// 入力内容はブラウザの中だけで処理し、外部には送信しない。
(function () {
  var $ = function (id) { return document.getElementById(id); };
  var conf = JSON.parse($('diag-data').textContent);
  var items = [];
  var EMP_PURPOSES = ['雇用・職場環境', '人材育成', '教育・子育て'];

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function yen(v) {
    var n = Number(v);
    if (!n || n <= 0) return '公募要領を参照';
    if (n >= 1e8) return (Math.round(n / 1e6) / 100) + '億円';
    if (n >= 1e4) return (Math.round(n / 100) / 100).toLocaleString('ja-JP') + '万円';
    return n.toLocaleString('ja-JP') + '円';
  }
  // 「300名以下」「従業員数の制約なし」などの条件を、選んだ従業員数で判定する
  function empOk(cond, n) {
    if (!cond || /制約なし/.test(cond)) return true;
    var m = cond.match(/(\d+)\s*名以下/);
    if (m) return n <= Number(m[1]);
    m = cond.match(/(\d+)\s*名以上/);
    if (m) return n >= Number(m[1]);
    return true;
  }
  function card(it) {
    var end = new Date(it.e), days = Math.floor((end - new Date()) / 864e5);
    var badge = days <= 0 ? '<span class="badge urgent">本日締切</span>' : '<span class="badge' + (days <= 7 ? ' urgent' : '') + '">締切まであと' + days + '日</span>';
    return '<li class="card"><a href="s/' + esc(it.id) + '.html"><div class="card-head">' + badge + '<span class="chip">' + esc(it.a.join('・')) + '</span></div>' +
      '<h3>' + esc(it.t) + '</h3><dl class="kv"><div><dt>上限額</dt><dd>' + yen(it.m) + '</dd></div><div><dt>補助率</dt><dd>' + esc(it.r || '公募要領を参照') + '</dd></div></dl></a></li>';
  }
  function run() {
    var pref = $('d-pref').value;
    var sizeEl = document.querySelector('input[name=size]:checked');
    var purposes = [].slice.call(document.querySelectorAll('input[name=purpose]:checked')).map(function (x) { return x.value; });
    var out = $('d-result');
    if (!pref || !sizeEl) {
      out.hidden = false;
      out.innerHTML = '<p class="empty">Q1（事業所の場所）とQ2（従業員数）を選んでください。</p>';
      return;
    }
    var size = Number(sizeEl.value), now = new Date();
    var anyArea = pref.indexOf('全国') === 0;
    var hits = items.filter(function (it) {
      if (new Date(it.e) < now || new Date(it.s) > now) return false;
      if (!anyArea && it.a.indexOf(pref) < 0 && it.a.indexOf('全国') < 0) return false;
      if (anyArea && it.a.indexOf('全国') < 0) return false;
      if (!empOk(it.emp, size)) return false;
      if (purposes.length && !(it.p || []).some(function (p) { return purposes.indexOf(p) >= 0; })) return false;
      return true;
    });
    var slugs = purposes.map(function (p) { return conf.purposeSlug[p]; });
    var majors = conf.major.filter(function (m) { return !slugs.length || m.purposes.some(function (s) { return slugs.indexOf(s) >= 0; }); });
    var html = '<h2>診断結果</h2>';
    html += '<section><h3 class="r-head">Ｊグランツで受付中の補助金：' + hits.length + '件</h3>';
    html += hits.length ? '<ul class="cards">' + hits.slice(0, 20).map(card).join('') + '</ul>' + (hits.length > 20 ? '<p class="note">締切が近い順に20件を表示しています。</p>' : '')
      : '<p class="empty">条件に合う受付中の補助金は見つかりませんでした。目的を減らすか、下の主要な補助金もご確認ください。</p>';
    html += '</section>';
    if (majors.length) {
      html += '<section><h3 class="r-head">検討したい国の主要な補助金</h3><ul class="tiles">' + majors.map(function (m) {
        return '<li><a href="major/' + esc(m.slug) + '.html"><span class="t-name">' + esc(m.name) + '</span><span class="t-desc">補助率 ' + esc(m.rate) + '／' + esc(m.max) + '</span><span class="t-count"><span class="badge ' + esc(m.st) + '">' + esc(m.status.replace(/（.*/, '')) + '</span></span></a></li>';
      }).join('') + '</ul></section>';
    }
    if (!purposes.length || purposes.some(function (p) { return EMP_PURPOSES.indexOf(p) >= 0; })) {
      html += '<section class="box summary"><h3>従業員を雇っている事業主の方へ</h3><p>雇用・待遇改善・人材育成・育児との両立に取り組むと、厚生労働省の雇用関係助成金を利用できる場合があります。<a href="employment.html">雇用関係助成金の一覧を見る ›</a></p></section>';
    }
    if (pref === '東京都' && conf.tokyoCount) {
      html += '<section class="box summary"><h3>東京都の事業者の方へ</h3><p>Ｊグランツに載っていない東京都独自の補助金も確認できます。<a href="tokyo/index.html">東京都の補助金制度一覧（' + conf.tokyoCount + '件） ›</a></p></section>';
    }
    out.hidden = false;
    out.innerHTML = html;
    out.scrollIntoView({ behavior: 'smooth' });
  }
  fetch('data.json').then(function (r) { return r.json(); }).then(function (d) {
    items = d.sort(function (x, y) { return new Date(x.e) - new Date(y.e); });
    $('d-run').addEventListener('click', run);
  }).catch(function () {
    $('d-result').hidden = false;
    $('d-result').innerHTML = '<p class="empty">データを読み込めませんでした。時間をおいて再度お試しください。</p>';
  });
})();
