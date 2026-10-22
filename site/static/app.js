// トップページの絞り込み。data.json（受付中・受付前の案件）を読み、条件に合うものを締切順に表示する。
// URLの ?q=（ヘッダーの検索窓）、?pref=、?purpose= にも対応する。
(function () {
  var $ = function (id) { return document.getElementById(id); };
  var list = $('results'), count = $('count'), more = $('more');
  var items = [], hits = [], shown = 0, PAGE = 30;

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
  function fmt(d) {
    var w = '日月火水木金土'.charAt(new Date(d.toLocaleString('en-US', { timeZone: 'Asia/Tokyo' })).getDay());
    return d.toLocaleDateString('ja-JP', { timeZone: 'Asia/Tokyo', year: 'numeric', month: 'long', day: 'numeric' }) + '(' + w + ') ' +
      d.toLocaleTimeString('ja-JP', { timeZone: 'Asia/Tokyo', hour: '2-digit', minute: '2-digit' });
  }
  function card(it) {
    var end = new Date(it.e), start = new Date(it.s), now = new Date();
    var days = Math.floor((end - now) / 864e5), badge;
    if (start > now) badge = '<span class="badge soon">受付開始前</span>';
    else if (days <= 0) badge = '<span class="badge urgent">本日締切</span>';
    else badge = '<span class="badge' + (days <= 7 ? ' urgent' : '') + '">締切まであと' + days + '日</span>';
    var tags = (it.p || []).slice(0, 3).map(function (t) { return '<span class="tag">' + esc(t) + '</span>'; }).join('');
    return '<li class="card"><a href="s/' + esc(it.id) + '.html"><div class="card-head">' + badge +
      '<span class="chip">' + esc(it.a.join('・')) + '</span>' + (it.n ? '<span class="chip new">新着</span>' : '') + '</div>' +
      '<h3>' + esc(it.t) + '</h3><dl class="kv"><div><dt>上限額</dt><dd>' + yen(it.m) + '</dd></div>' +
      '<div><dt>補助率</dt><dd>' + esc(it.r || '公募要領を参照') + '</dd></div>' +
      '<div><dt>締切</dt><dd>' + fmt(end) + '</dd></div></dl>' + (tags ? '<div class="tags">' + tags + '</div>' : '') + '</a></li>';
  }
  function renderMore() {
    list.insertAdjacentHTML('beforeend', hits.slice(shown, shown + PAGE).map(card).join(''));
    shown = Math.min(hits.length, shown + PAGE);
    more.hidden = shown >= hits.length;
  }
  function render() {
    var q = $('q').value.trim().toLowerCase().split(/\s+/).filter(Boolean);
    var pref = $('pref').value, purpose = $('purpose').value, min = Number($('min').value), nat = $('nat').checked;
    var now = new Date();
    hits = items.filter(function (it) {
      if (new Date(it.e) < now) return false;
      if (pref && it.a.indexOf(pref) < 0 && !(nat && it.a.indexOf('全国') >= 0)) return false;
      if (purpose && (it.p || []).indexOf(purpose) < 0) return false;
      if (min && !(Number(it.m) >= min)) return false;
      var hay = (it.t + ' ' + (it.p || []).join(' ') + ' ' + (it.ind || '') + ' ' + it.a.join(' ')).toLowerCase();
      return q.every(function (w) { return hay.indexOf(w) >= 0; });
    });
    count.textContent = hits.length + '件の補助金が見つかりました（締切が近い順）';
    list.innerHTML = '';
    shown = 0;
    renderMore();
  }
  var params = new URLSearchParams(location.search);
  if (params.get('q')) $('q').value = params.get('q');
  fetch('data.json').then(function (r) { return r.json(); }).then(function (d) {
    items = d.sort(function (x, y) { return new Date(x.e) - new Date(y.e); });
    if (params.get('pref')) $('pref').value = params.get('pref');
    if (params.get('purpose')) $('purpose').value = params.get('purpose');
    ['q', 'pref', 'purpose', 'min', 'nat'].forEach(function (id) { $(id).addEventListener('input', render); $(id).addEventListener('change', render); });
    more.addEventListener('click', renderMore);
    render();
    if (params.get('q') || params.get('pref') || params.get('purpose')) $('search').scrollIntoView();
  }).catch(function () { count.textContent = '絞り込み機能を読み込めませんでした。地域別・目的別の一覧をご利用ください。'; });
})();
