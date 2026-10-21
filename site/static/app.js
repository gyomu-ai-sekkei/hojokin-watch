// トップページの絞り込み。data.json（受付中の案件）を読み、条件に合うものを締切順に表示する。
(function () {
  var $ = function (id) { return document.getElementById(id); };
  var list = $('results'), count = $('count');
  var items = [];

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
    return d.toLocaleString('ja-JP', { timeZone: 'Asia/Tokyo', year: 'numeric', month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' });
  }
  function card(it) {
    var end = new Date(it.e), start = new Date(it.s), now = new Date();
    var days = Math.floor((end - now) / 864e5), badge;
    if (start > now) badge = '<span class="badge soon">受付前</span>';
    else badge = '<span class="badge' + (days <= 7 ? ' urgent' : '') + '">' + (days <= 0 ? '本日締切' : 'あと' + days + '日') + '</span>';
    return '<li class="card"><a href="s/' + esc(it.id) + '.html"><div class="card-top">' + badge +
      '<span class="area">' + esc(it.a.join('・')) + '</span></div><h3>' + esc(it.t) + '</h3>' +
      '<div class="meta"><span>上限 ' + yen(it.m) + '</span><span>締切 ' + fmt(end) + '</span></div></a></li>';
  }
  function render() {
    var q = $('q').value.trim().toLowerCase().split(/\s+/).filter(Boolean);
    var pref = $('pref').value, min = Number($('min').value), nat = $('nat').checked;
    var now = new Date();
    var hits = items.filter(function (it) {
      if (new Date(it.e) < now) return false;
      if (pref && it.a.indexOf(pref) < 0 && !(nat && it.a.indexOf('全国') >= 0)) return false;
      if (!pref && !nat && it.a.indexOf('全国') >= 0) return false;
      if (min && !(Number(it.m) >= min)) return false;
      var hay = (it.t + ' ' + (it.p || '') + ' ' + (it.ind || '') + ' ' + it.a.join(' ')).toLowerCase();
      return q.every(function (w) { return hay.indexOf(w) >= 0; });
    });
    count.textContent = hits.length + '件が該当（締切が近い順）';
    list.innerHTML = hits.slice(0, 200).map(card).join('');
  }
  fetch('data.json').then(function (r) { return r.json(); }).then(function (d) {
    items = d.sort(function (x, y) { return new Date(x.e) - new Date(y.e); });
    ['q', 'pref', 'min', 'nat'].forEach(function (id) { $(id).addEventListener('input', render); });
    render();
  }).catch(function () { count.textContent = ''; });
})();
