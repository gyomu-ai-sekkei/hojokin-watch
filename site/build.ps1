<#
  補助金ウォッチ 静的サイト生成器
  - データ源: Jグランツ公開API（デジタル庁）  https://developers.digital.go.jp/documents/jgrants/api/
  - 利用条件: Jグランツ利用規約（政府標準利用規約2.0準拠・CC BY 4.0互換）。出典と編集・加工の旨を全ページに表示する。
  - Windows PowerShell 5.1 / PowerShell 7 の両方で動作させる（GitHub Actions では pwsh で実行）。

  使い方:
    ./site/build.ps1                 # APIから取得してキャッシュ更新 → サイト生成
    ./site/build.ps1 -SkipFetch      # キャッシュだけでサイト生成
    ./site/build.ps1 -MaxDetail 20   # 1回の実行で取得する詳細の上限（API負荷対策）
  環境変数:
    SITE_URL       公開URL（例 https://example.com）。canonical と sitemap に使う
    CONTACT_EMAIL  運営者情報ページに表示する連絡先
#>
param(
  [switch]$SkipFetch,
  [int]$MaxDetail = 80,
  [int]$DetailRefreshDays = 14,
  [int]$KeepClosedDays = 90
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$CachePath = Join-Path $Root 'data/subsidies.json'
$Dist = Join-Path $PSScriptRoot 'dist'
$StaticDir = Join-Path $PSScriptRoot 'static'
$SiteName = '補助金ウォッチ'
$SiteUrl = "$env:SITE_URL".TrimEnd('/')
$ContactEmail = "$env:CONTACT_EMAIL"
$Api = 'https://api.jgrants-portal.go.jp/exp'
$Jst = [TimeSpan]::FromHours(9)
$Now = [DateTimeOffset]::UtcNow.ToOffset($Jst)
$Utf8 = New-Object System.Text.UTF8Encoding($false)

$Prefectures = @('全国','北海道','青森県','岩手県','宮城県','秋田県','山形県','福島県','茨城県','栃木県','群馬県','埼玉県','千葉県','東京都','神奈川県',
  '新潟県','富山県','石川県','福井県','山梨県','長野県','岐阜県','静岡県','愛知県','三重県','滋賀県','京都府','大阪府','兵庫県','奈良県','和歌山県',
  '鳥取県','島根県','岡山県','広島県','山口県','徳島県','香川県','愛媛県','高知県','福岡県','佐賀県','長崎県','熊本県','大分県','宮崎県','鹿児島県','沖縄県')
$PrefSlug = @{}
for ($i = 0; $i -lt $Prefectures.Count; $i++) { $PrefSlug[$Prefectures[$i]] = '{0:D2}' -f $i }

# ---------- HTTP ----------
Add-Type -AssemblyName System.Net.Http
$Http = New-Object System.Net.Http.HttpClient
$Http.Timeout = [TimeSpan]::FromSeconds(90)
$Http.DefaultRequestHeaders.UserAgent.ParseAdd('HojokinWatch/0.1')

function Get-Json([string]$Url) {
  for ($try = 1; $try -le 3; $try++) {
    try {
      $bytes = $Http.GetByteArrayAsync($Url).GetAwaiter().GetResult()
      return ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
    } catch {
      if ($try -eq 3) { throw }
      Start-Sleep -Seconds (5 * $try)
    }
  }
}

# ---------- 小物 ----------
function Esc([object]$s) { [System.Net.WebUtility]::HtmlEncode("$s") }

function Convert-Links([string]$s) {
  [regex]::Replace($s, 'https?://(?:[^\s<>&"]|&amp;)+', { param($m) "<a href=`"$($m.Value)`" rel=`"nofollow noopener`" target=`"_blank`">$($m.Value)</a>" })
}

function ConvertTo-Hash($o) {
  $h = [ordered]@{}
  foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value }
  $h
}

function ConvertTo-Jst([string]$iso) {
  if (-not $iso) { return $null }
  [DateTimeOffset]::Parse($iso, [Globalization.CultureInfo]::InvariantCulture).ToOffset($Jst)
}

function Format-Date($d) { if ($d) { $d.ToString('yyyy年M月d日 HH:mm') } else { '—' } }

function Format-Yen($v) {
  $n = 0.0
  if (-not [double]::TryParse("$v", [ref]$n) -or $n -le 0) { return '公募要領を参照' }
  if ($n -ge 100000000) { return ('{0:0.##}億円' -f ($n / 100000000)) }
  if ($n -ge 10000) { return ('{0:#,0.##}万円' -f ($n / 10000)) }
  '{0:#,0}円' -f $n
}

function Get-DaysLeft($end) {
  if (-not $end) { return $null }
  [int][Math]::Floor(($end - $Now).TotalDays)
}

function Split-Areas([string]$s) {
  if (-not $s) { return ,@('全国') }
  ,@($s -split '\s*/\s*' | Where-Object { $_ })
}

function Convert-HtmlToLines([string]$html) {
  if (-not $html) { return ,@() }
  $s = $html -replace '(?i)<br\s*/?>', "`n" -replace '(?i)</(p|div|li|h[1-6]|tr|ul|ol)>', "`n" -replace '(?i)<li[^>]*>', '・'
  $s = $s -replace '<[^>]+>', ''
  $s = [System.Net.WebUtility]::HtmlDecode($s) -replace [char]0xA0, ' '
  $lines = @($s -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
  # 長すぎる本文は切り詰める（詳細は公式ページへ誘導）
  $out = New-Object System.Collections.ArrayList
  $len = 0
  foreach ($l in $lines) { if ($len -gt 6000) { break }; [void]$out.Add($l); $len += $l.Length }
  ,@($out)
}

function Write-File([string]$Path, [string]$Text) {
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
  [IO.File]::WriteAllText($Path, $Text, $Utf8)
}

# ---------- キャッシュ ----------
$Cache = @{}
if (Test-Path $CachePath) {
  $raw = [IO.File]::ReadAllText($CachePath, $Utf8)
  if ($raw.Trim()) { foreach ($o in ($raw | ConvertFrom-Json)) { $Cache[$o.id] = ConvertTo-Hash $o } }
}
Write-Host "cache: $($Cache.Count) records"

# ---------- 取得 ----------
if (-not $SkipFetch) {
  # 一覧APIはキーワード必須（2文字以上）。広いキーワード×2通りの並び順で和集合を取り、受付中の案件を網羅する。
  $keywords = @('補助', '助成', '支援', '事業', '交付', '給付', '奨励', '促進', '推進', '導入', '対策', '補助金')
  $sorts = @('created_date', 'acceptance_end_datetime')
  $seen = @{}
  foreach ($k in $keywords) {
    foreach ($sort in $sorts) {
      $url = "$Api/v1/public/subsidies?keyword=$([uri]::EscapeDataString($k))&sort=$sort&order=DESC&acceptance=1"
      $j = Get-Json $url
      foreach ($r in $j.result) { $seen[$r.id] = $r }
      Start-Sleep -Milliseconds 700
    }
  }
  Write-Host "open (list api): $($seen.Count)"
  $today = $Now.ToString('yyyy-MM-dd')

  foreach ($r in $seen.Values) {
    $rec = $Cache[$r.id]
    if (-not $rec) { $rec = [ordered]@{ id = $r.id; firstSeen = $today }; $Cache[$r.id] = $rec }
    $rec.title = $r.title
    $rec.name = $r.name
    $rec.area = $r.target_area_search
    $rec.employees = $r.target_number_of_employees
    $rec.maxLimit = $r.subsidy_max_limit
    $rec.start = $r.acceptance_start_datetime
    $rec.end = $r.acceptance_end_datetime
    $rec.institution = $r.institution_name
    $rec.lastSeen = $today
  }

  # 詳細APIは募集要領PDFを含み1件あたり数MBあるため、新規・古いものだけを1回の上限付きで取得する
  $queue = @($Cache.Values | Where-Object {
      $_.lastSeen -eq $today -and (-not $_.detailFetched -or ([DateTime]::Parse($_.detailFetched) -lt $Now.DateTime.AddDays(-$DetailRefreshDays)))
    } | Sort-Object { if ($_.detailFetched) { $_.detailFetched } else { '0000' } } | Select-Object -First $MaxDetail)
  Write-Host "detail queue: $($queue.Count)"
  foreach ($rec in $queue) {
    try {
      $d = (Get-Json "$Api/v2/public/subsidies/id/$($rec.id)").result[0]
      $rec.catch = $d.subsidy_catch_phrase
      $rec.purpose = $d.use_purpose
      $rec.industry = $d.industry
      $rec.rate = $d.subsidy_rate
      $rec.lines = Convert-HtmlToLines $d.detail
      $rec.officialUrl = $d.front_subsidy_detail_page_url
      $docs = @()
      foreach ($f in @($d.application_guidelines) + @($d.outline_of_grant) + @($d.application_form)) { if ($f -and $f.name) { $docs += $f.name } }
      $rec.docs = $docs
      $rec.detailFetched = $Now.ToString('yyyy-MM-dd')
    } catch {
      Write-Warning "detail failed $($rec.id): $_"
    }
    Start-Sleep -Milliseconds 1500
  }
}

# 受付終了から一定期間を過ぎたものはキャッシュから外す
foreach ($id in @($Cache.Keys)) {
  $end = ConvertTo-Jst $Cache[$id].end
  if ($end -and ($Now - $end).TotalDays -gt $KeepClosedDays) { $Cache.Remove($id) }
}

$all = @($Cache.Values | Sort-Object { $_.end })
Write-File $CachePath (ConvertTo-Json -InputObject $all -Depth 6)

# ---------- 描画 ----------
function Get-Status($rec) {
  $end = ConvertTo-Jst $rec.end
  $start = ConvertTo-Jst $rec.start
  if ($end -and $end -lt $Now) { return 'closed' }
  if ($start -and $start -gt $Now) { return 'upcoming' }
  'open'
}

function Get-Layout {
  param([string]$Title, [string]$Desc, [string]$Body, [string]$Path, [int]$Depth = 0, [switch]$NoIndex)
  $p = ''; for ($i = 0; $i -lt $Depth; $i++) { $p += '../' }
  $canon = ''
  if ($SiteUrl) { $canon = "<link rel=""canonical"" href=""$SiteUrl/$Path"">" }
  $robots = ''
  if ($NoIndex) { $robots = '<meta name="robots" content="noindex">' }
  $built = $Now.ToString('yyyy年M月d日 HH:mm')
  @"
<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$(Esc $Title)</title>
<meta name="description" content="$(Esc $Desc)">
$canon
$robots
<link rel="stylesheet" href="${p}assets/style.css">
</head>
<body>
<header class="site-header"><div class="wrap">
  <a class="brand" href="${p}index.html">$SiteName</a>
  <nav><a href="${p}deadline.html">締切間近</a><a href="${p}area/index.html">地域別</a><a href="${p}about.html">このサイトについて</a></nav>
</div></header>
<main class="wrap">
$Body
</main>
<footer class="site-footer"><div class="wrap">
  <p>出典：「Ｊグランツ」（<a href="https://www.jgrants-portal.go.jp" rel="nofollow">https://www.jgrants-portal.go.jp</a>）をもとに$SiteName 運営者が編集・加工して作成。本サイトは国・自治体の公式サイトではありません。</p>
  <p>掲載情報は自動取得のため誤り・変更がある場合があります。申請前に必ず公式の公募要領をご確認ください。最終更新：$built</p>
  <p><a href="${p}about.html">運営者情報・免責事項</a> ／ <a href="${p}privacy.html">プライバシーポリシー</a></p>
</div></footer>
</body>
</html>
"@
}

function Get-Card($rec, [string]$p) {
  $end = ConvertTo-Jst $rec.end
  $days = Get-DaysLeft $end
  $badge = ''
  $status = Get-Status $rec
  if ($status -eq 'closed') { $badge = '<span class="badge closed">受付終了</span>' }
  elseif ($status -eq 'upcoming') { $badge = '<span class="badge soon">受付前</span>' }
  elseif ($null -ne $days -and $days -le 0) { $badge = '<span class="badge urgent">本日締切</span>' }
  elseif ($null -ne $days -and $days -le 7) { $badge = "<span class=""badge urgent"">あと$($days)日</span>" }
  elseif ($null -ne $days) { $badge = "<span class=""badge"">あと$($days)日</span>" }
  $areas = (Split-Areas $rec.area) -join '・'
  @"
<li class="card"><a href="${p}s/$($rec.id).html">
  <div class="card-top">$badge<span class="area">$(Esc $areas)</span></div>
  <h3>$(Esc $rec.title)</h3>
  <div class="meta"><span>上限 $(Esc (Format-Yen $rec.maxLimit))</span><span>締切 $(Esc (Format-Date $end))</span></div>
</a></li>
"@
}

if (Test-Path $Dist) { Remove-Item -Recurse -Force $Dist }
New-Item -ItemType Directory -Force (Join-Path $Dist 'assets') | Out-Null
Copy-Item (Join-Path $StaticDir '*') (Join-Path $Dist 'assets') -Recurse
# サイト直下に置くファイル（Search Consoleの所有権確認ファイルなど）
$RootDir = Join-Path $PSScriptRoot 'root'
if (Test-Path $RootDir) { Copy-Item (Join-Path $RootDir '*') $Dist -Recurse }

$open = @($all | Where-Object { (Get-Status $_) -ne 'closed' })
$sitemap = New-Object System.Collections.ArrayList

# 詳細ページ
foreach ($rec in $all) {
  $end = ConvertTo-Jst $rec.end
  $start = ConvertTo-Jst $rec.start
  $days = Get-DaysLeft $end
  $status = Get-Status $rec
  $statusText = '受付中'
  if ($status -eq 'closed') { $statusText = '受付終了' } elseif ($status -eq 'upcoming') { $statusText = '受付開始前' }
  elseif ($null -ne $days -and $days -le 0) { $statusText = '受付中（本日締切）' }
  elseif ($null -ne $days) { $statusText = "受付中（締切まであと$($days)日）" }

  $rows = New-Object System.Collections.ArrayList
  [void]$rows.Add(@('受付状況', $statusText))
  [void]$rows.Add(@('対象地域', ((Split-Areas $rec.area) -join '、')))
  [void]$rows.Add(@('補助上限額', (Format-Yen $rec.maxLimit)))
  if ($rec.rate) { [void]$rows.Add(@('補助率', $rec.rate)) }
  [void]$rows.Add(@('受付期間', "$(Format-Date $start) 〜 $(Format-Date $end)"))
  if ($rec.employees) { [void]$rows.Add(@('従業員数', $rec.employees)) }
  if ($rec.purpose) { [void]$rows.Add(@('利用目的', ($rec.purpose -replace '\s*/\s*', '、'))) }
  if ($rec.industry) { [void]$rows.Add(@('対象業種', ($rec.industry -replace '\s*/\s*', '、'))) }
  if ($rec.institution) { [void]$rows.Add(@('実施機関・事業名', $rec.institution)) }
  $table = ($rows | ForEach-Object { "<tr><th>$(Esc $_[0])</th><td>$(Esc $_[1])</td></tr>" }) -join "`n"

  $bodyLines = ''
  if ($rec.lines) {
    $bodyLines = ($rec.lines | ForEach-Object {
        if ($_ -match '^[■◆●【]') { "<h3>$(Esc $_)</h3>" } else { "<p>$(Convert-Links (Esc $_))</p>" }
      }) -join "`n"
  }
  $docs = ''
  if ($rec.docs -and @($rec.docs).Count -gt 0) {
    $docs = '<h2>公式に掲載されている書類</h2><ul class="docs">' + ((@($rec.docs) | ForEach-Object { "<li>$(Esc $_)</li>" }) -join '') + '</ul><p class="note">書類は公式ページからダウンロードしてください。</p>'
  }
  $official = $rec.officialUrl
  if (-not $official) { $official = "https://www.jgrants-portal.go.jp/subsidy/$($rec.id)" }
  $catch = ''
  if ($rec.catch) { $catch = "<p class=""lead"">$(Esc $rec.catch)</p>" }
  $areaLinks = ((Split-Areas $rec.area) | Where-Object { $PrefSlug.ContainsKey($_) } | ForEach-Object { "<a href=""../area/$($PrefSlug[$_]).html"">$(Esc $_)の補助金一覧</a>" }) -join ' '

  $body = @"
<nav class="crumbs"><a href="../index.html">トップ</a> › <a href="../area/index.html">地域別</a> › 詳細</nav>
<article class="detail">
<h1>$(Esc $rec.title)</h1>
$catch
<table class="facts">$table</table>
<p class="cta"><a class="btn" href="$(Esc $official)" rel="nofollow noopener" target="_blank">公式ページ（Ｊグランツ）で確認・申請する</a></p>
<h2>概要（公式掲載内容より）</h2>
<div class="body">$bodyLines</div>
$docs
<p class="related">$areaLinks</p>
</article>
"@
  $desc = "$($rec.title)｜対象地域：$((Split-Areas $rec.area) -join '・')、上限：$(Format-Yen $rec.maxLimit)、締切：$(Format-Date $end)。受付状況と概要をまとめています。"
  $html = Get-Layout -Title "$($rec.title)｜$SiteName" -Desc $desc -Body $body -Path "s/$($rec.id).html" -Depth 1 -NoIndex:($status -eq 'closed')
  Write-File (Join-Path $Dist "s/$($rec.id).html") $html
  if ($status -ne 'closed') { [void]$sitemap.Add("s/$($rec.id).html") }
}

# 地域別ページ（その都道府県＋全国対象）
$areaIndex = New-Object System.Collections.ArrayList
foreach ($pref in $Prefectures) {
  $local = @($open | Where-Object { (Split-Areas $_.area) -contains $pref })
  $national = @()
  if ($pref -ne '全国') { $national = @($open | Where-Object { (Split-Areas $_.area) -contains '全国' }) }
  [void]$areaIndex.Add(@($pref, $local.Count))
  if ($local.Count -eq 0 -and $pref -ne '全国') { continue }
  $slug = $PrefSlug[$pref]
  $body = "<nav class=""crumbs""><a href=""../index.html"">トップ</a> › <a href=""index.html"">地域別</a> › $(Esc $pref)</nav>"
  $body += "<h1>$(Esc $pref)の補助金・助成金（受付中 $($local.Count)件）</h1>"
  $body += "<p class=""lead"">Ｊグランツに掲載されている$(Esc $pref)対象の補助金を締切が近い順に並べています。毎日自動更新。</p>"
  $body += '<ul class="cards">' + (($local | ForEach-Object { Get-Card $_ '../' }) -join '') + '</ul>'
  if ($national.Count -gt 0) {
    $body += "<h2>全国対象の補助金（$($national.Count)件）</h2><ul class=""cards"">" + (($national | ForEach-Object { Get-Card $_ '../' }) -join '') + '</ul>'
  }
  $html = Get-Layout -Title "$pref の補助金・助成金一覧（受付中）｜$SiteName" -Desc "$pref で申請できる受付中の補助金・助成金 $($local.Count) 件を締切順に掲載。全国対象の制度も確認できます。毎日自動更新。" -Body $body -Path "area/$slug.html" -Depth 1
  Write-File (Join-Path $Dist "area/$slug.html") $html
  [void]$sitemap.Add("area/$slug.html")
}
$areaList = ($areaIndex | ForEach-Object {
    if ($_[1] -gt 0 -or $_[0] -eq '全国') { "<li><a href=""$($PrefSlug[$_[0]]).html"">$(Esc $_[0])<span>$($_[1])件</span></a></li>" }
    else { "<li class=""empty"">$(Esc $_[0])<span>0件</span></li>" }
  }) -join ''
$html = Get-Layout -Title "地域別 補助金・助成金一覧｜$SiteName" -Desc '都道府県ごとに受付中の補助金・助成金を一覧できます。' -Body "<nav class=""crumbs""><a href=""../index.html"">トップ</a> › 地域別</nav><h1>地域別に探す</h1><ul class=""prefs"">$areaList</ul>" -Path 'area/index.html' -Depth 1
Write-File (Join-Path $Dist 'area/index.html') $html
[void]$sitemap.Add('area/index.html')

# 締切間近
$soon = @($open | Where-Object { $d = Get-DaysLeft (ConvertTo-Jst $_.end); (Get-Status $_) -eq 'open' -and $null -ne $d -and $d -le 14 })
$body = "<h1>締切間近の補助金（14日以内・$($soon.Count)件）</h1><p class=""lead"">受付締切まで14日以内の補助金です。申請準備に時間がかかるものも多いため、早めに公募要領を確認してください。</p>"
$body += '<ul class="cards">' + (($soon | ForEach-Object { Get-Card $_ '' }) -join '') + '</ul>'
Write-File (Join-Path $Dist 'deadline.html') (Get-Layout -Title "締切間近の補助金・助成金｜$SiteName" -Desc "受付締切まで14日以内の補助金・助成金 $($soon.Count) 件。毎日自動更新。" -Body $body -Path 'deadline.html')
[void]$sitemap.Add('deadline.html')

# 検索用データ（トップページのJSが読む）
$data = @($open | ForEach-Object {
    [ordered]@{ id = $_.id; t = $_.title; a = (Split-Areas $_.area); m = $_.maxLimit; s = $_.start; e = $_.end; emp = $_.employees; p = $_.purpose; ind = $_.industry }
  })
Write-File (Join-Path $Dist 'data.json') (ConvertTo-Json -InputObject $data -Depth 4 -Compress)

# トップ
$prefOptions = ($Prefectures | ForEach-Object { "<option>$(Esc $_)</option>" }) -join ''
$top = @($open | Where-Object { (Get-Status $_) -eq 'open' } | Select-Object -First 30)
$body = @"
<section class="hero">
  <h1>受付中の補助金・助成金を、締切順にすばやく探す</h1>
  <p>国・自治体の補助金電子申請システム「Ｊグランツ」の掲載情報を毎日自動で取得し、地域・金額・締切で絞り込めるようにしました。現在 <strong>$($open.Count)</strong> 件を掲載中。</p>
</section>
<form id="filters" class="filters" onsubmit="return false">
  <input id="q" type="search" placeholder="キーワード（例：省エネ、IT導入、創業）" aria-label="キーワード">
  <select id="pref" aria-label="地域"><option value="">すべての地域</option>$prefOptions</select>
  <select id="min" aria-label="上限額"><option value="0">上限額を問わない</option><option value="1000000">100万円以上</option><option value="5000000">500万円以上</option><option value="10000000">1,000万円以上</option></select>
  <label class="chk"><input id="nat" type="checkbox" checked> 全国対象も含める</label>
</form>
<p id="count" class="count"></p>
<ul id="results" class="cards">
$(($top | ForEach-Object { Get-Card $_ '' }) -join '')
</ul>
<script src="assets/app.js" defer></script>
"@
Write-File (Join-Path $Dist 'index.html') (Get-Layout -Title "$SiteName｜受付中の補助金・助成金を締切順に検索" -Desc "受付中の補助金・助成金 $($open.Count) 件を地域・上限額・締切で検索。Ｊグランツの掲載情報を毎日自動更新。" -Body $body -Path '')
[void]$sitemap.Insert(0, '')

# 固定ページ
$contact = '現在準備中です。'
if ($ContactEmail) { $contact = "<a href=""mailto:$(Esc $ContactEmail)"">$(Esc $ContactEmail)</a>" }
$about = @"
<h1>このサイトについて</h1>
<h2>概要</h2>
<p>$SiteName は、デジタル庁が運営する補助金の電子申請システム「Ｊグランツ」が公開しているAPIから受付中の補助金情報を毎日自動取得し、締切・地域・金額で探しやすく整理した民間の情報サイトです。国・自治体・デジタル庁の公式サイトではなく、これらの機関とは関係ありません。</p>
<h2>出典</h2>
<p>出典：「Ｊグランツ」（https://www.jgrants-portal.go.jp）をもとに$SiteName 運営者が編集・加工して作成しています。掲載内容はＪグランツ利用規約（政府標準利用規約に準拠）に従って利用しています。</p>
<h2>免責事項</h2>
<p>掲載情報は自動取得・自動整形しているため、誤り、遅れ、欠落が含まれる場合があります。補助金の要件・締切・金額は必ず公式の公募要領でご確認ください。本サイトの情報を利用したことによる損害について、運営者は責任を負いません。本サイトは補助金の申請書類の作成・代行は行っていません。</p>
<h2>掲載範囲</h2>
<p>Ｊグランツに掲載されている補助金のみを対象としています。自治体が独自に募集している補助金など、Ｊグランツに掲載されていない制度は含まれません。</p>
<h2>運営者・お問い合わせ</h2>
<p>運営：$SiteName 運営者<br>連絡先：$contact</p>
"@
Write-File (Join-Path $Dist 'about.html') (Get-Layout -Title "このサイトについて｜$SiteName" -Desc "$SiteName の概要、出典、免責事項、運営者情報。" -Body $about -Path 'about.html')
$privacy = @"
<h1>プライバシーポリシー</h1>
<p>本サイトは現在、氏名・メールアドレス等の個人情報を取得していません。</p>
<p>今後、アクセス解析ツールや広告配信、メール配信を導入する場合は、取得する情報・利用目的・第三者提供の有無を本ページに掲載したうえで開始します。</p>
<p>制定：$($Now.ToString('yyyy年M月d日'))</p>
"@
Write-File (Join-Path $Dist 'privacy.html') (Get-Layout -Title "プライバシーポリシー｜$SiteName" -Desc "$SiteName のプライバシーポリシー。" -Body $privacy -Path 'privacy.html')
[void]$sitemap.Add('about.html')

# sitemap / robots / 404
if ($SiteUrl) {
  $lastmod = $Now.ToString('yyyy-MM-dd')
  $urls = ($sitemap | ForEach-Object { "<url><loc>$SiteUrl/$_</loc><lastmod>$lastmod</lastmod></url>" }) -join "`n"
  Write-File (Join-Path $Dist 'sitemap.xml') "<?xml version=""1.0"" encoding=""UTF-8""?>`n<urlset xmlns=""http://www.sitemaps.org/schemas/sitemap/0.9"">`n$urls`n</urlset>`n"
  Write-File (Join-Path $Dist 'robots.txt') "User-agent: *`nAllow: /`nSitemap: $SiteUrl/sitemap.xml`n"
} else {
  Write-File (Join-Path $Dist 'robots.txt') "User-agent: *`nAllow: /`n"
}
Write-File (Join-Path $Dist '404.html') (Get-Layout -Title "ページが見つかりません｜$SiteName" -Desc '' -Body '<h1>ページが見つかりません</h1><p>受付が終了した補助金のページは一定期間後に削除されます。<a href="index.html">トップから探す</a></p>' -Path '404.html' -NoIndex)
Write-File (Join-Path $Dist '.nojekyll') ''

Write-Host "built: $($all.Count) detail pages, $($open.Count) open, $($soon.Count) closing soon, $($sitemap.Count) sitemap urls -> $Dist"
