<#
  補助金ウォッチ 静的サイト生成器
  - データ源: Jグランツ公開API（デジタル庁）  https://developers.digital.go.jp/documents/jgrants/api/
  - 利用条件: Jグランツ利用規約（政府標準利用規約2.0準拠・CC BY 4.0互換）。出典と編集・加工の旨を全ページに表示する。
  - Windows PowerShell 5.1 / PowerShell 7 の両方で動作させる（GitHub Actions では pwsh で実行）。
  - 注意: PowerShell 5.1 で日本語を正しく読むため、このファイルはBOM付きUTF-8で保存する。
          文字列中で "$変数日" のように変数の直後に日本語を続けると変数名の一部とみなされるため、必ず $() で囲む。

  使い方:
    ./site/build.ps1                 # APIから取得してキャッシュ更新 → サイト生成
    ./site/build.ps1 -SkipFetch      # キャッシュだけでサイト生成
    ./site/build.ps1 -MaxDetail 20   # 1回の実行で取得する詳細の上限（API負荷対策）
  環境変数:
    SITE_URL       公開URL（例 https://example.com/path）。canonical・OGP・sitemap に使う
    CONTACT_EMAIL  運営者情報ページに表示する連絡先（未設定なら表示しない）
    REPORT_URL     掲載内容の誤りを報告する窓口のURL
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
$RootDir = Join-Path $PSScriptRoot 'root'
$SiteName = '補助金ウォッチ'
$SiteUrl = "$env:SITE_URL".TrimEnd('/')
$ContactEmail = "$env:CONTACT_EMAIL"
$ReportUrl = "$env:REPORT_URL"
$CfToken = "$env:CF_BEACON_TOKEN"   # Cloudflare Web Analytics のサイト用トークン（公開される値。未設定なら計測タグを出さない）
$TokyoCache = Join-Path $Root 'data/tokyo.json'
$EmploymentPath = Join-Path $Root 'data/employment_subsidies.json'
$MajorPath = Join-Path $Root 'data/major_subsidies.json'
if (-not $ReportUrl) { $ReportUrl = 'https://github.com/gyomu-ai-sekkei/hojokin-watch/issues' }
$BasePath = '/'
if ($SiteUrl) { $BasePath = ([uri]$SiteUrl).AbsolutePath.TrimEnd('/') + '/' }
$Api = 'https://api.jgrants-portal.go.jp/exp'
$Jst = [TimeSpan]::FromHours(9)
$Now = [DateTimeOffset]::UtcNow.ToOffset($Jst)
$Ja = [Globalization.CultureInfo]::GetCultureInfo('ja-JP')
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$LaunchDate = '2026-10-21'   # サイト公開日。これより後に初めて見つけた案件を「新着」とみなす

$Prefectures = @('全国','北海道','青森県','岩手県','宮城県','秋田県','山形県','福島県','茨城県','栃木県','群馬県','埼玉県','千葉県','東京都','神奈川県',
  '新潟県','富山県','石川県','福井県','山梨県','長野県','岐阜県','静岡県','愛知県','三重県','滋賀県','京都府','大阪府','兵庫県','奈良県','和歌山県',
  '鳥取県','島根県','岡山県','広島県','山口県','徳島県','香川県','愛媛県','高知県','福岡県','佐賀県','長崎県','熊本県','大分県','宮崎県','鹿児島県','沖縄県')
$PrefSlug = @{}
for ($i = 0; $i -lt $Prefectures.Count; $i++) { $PrefSlug[$Prefectures[$i]] = '{0:D2}' -f $i }
$Regions = [ordered]@{
  '北海道・東北' = @('北海道','青森県','岩手県','宮城県','秋田県','山形県','福島県')
  '関東' = @('茨城県','栃木県','群馬県','埼玉県','千葉県','東京都','神奈川県')
  '中部' = @('新潟県','富山県','石川県','福井県','山梨県','長野県','岐阜県','静岡県','愛知県')
  '近畿' = @('三重県','滋賀県','京都府','大阪府','兵庫県','奈良県','和歌山県')
  '中国・四国' = @('鳥取県','島根県','岡山県','広島県','山口県','徳島県','香川県','愛媛県','高知県')
  '九州・沖縄' = @('福岡県','佐賀県','長崎県','熊本県','大分県','宮崎県','鹿児島県','沖縄県')
}

# Ｊグランツの「利用目的」→ 表示名・URL・説明
$Purposes = [ordered]@{
  '設備整備・IT導入をしたい' = @('equipment-it', '設備投資・IT導入', '機械装置やITツール、業務システムの導入など')
  '新たな事業を行いたい' = @('new-business', '新事業・創業', '新分野への進出、新商品・サービスの開発、創業など')
  '雇用・職場環境を改善したい' = @('employment', '雇用・職場環境', '採用、賃上げ、働きやすい職場づくりなど')
  '販路拡大・海外展開をしたい' = @('sales-overseas', '販路拡大・海外展開', '展示会への出展、ECサイト、輸出、海外での出願など')
  'エコ・SDGs活動支援がほしい' = @('eco-sdgs', '省エネ・脱炭素', '省エネ設備、再生可能エネルギー、環境対策など')
  '安全・防災対策支援がほしい' = @('safety', '安全・防災', '防災設備、BCP（事業継続計画）、防犯対策など')
  '人材育成を行いたい' = @('training', '人材育成', '研修、資格取得、リスキリングなど')
  '研究開発・実証事業を行いたい' = @('rnd', '研究開発・実証', '技術開発、実証実験、産学連携など')
  '資金繰りを改善したい' = @('cash-flow', '資金繰り', '経営の安定化、資金面の支援など')
  'まちづくり・地域振興支援がほしい' = @('community', 'まちづくり・地域振興', '商店街、観光、地域の活性化など')
  'イベント・事業運営支援がほしい' = @('events', 'イベント・事業運営', 'イベントの開催、団体の運営支援など')
  '事業を引き継ぎたい' = @('succession', '事業承継・M&A', '後継者への引き継ぎ、M&Aなど')
  '災害（自然災害、感染症等）支援がほしい' = @('disaster', '災害からの復旧', '被災した事業者の復旧・再建など')
  '教育・子育て・少子化支援がほしい' = @('childcare', '教育・子育て', '子育て支援、教育に関する取り組みなど')
  'スポーツ・文化支援がほしい' = @('sports-culture', 'スポーツ・文化', 'スポーツの振興、文化・芸術活動など')
}
# 日本標準産業分類（大分類）→ URL
$Industries = [ordered]@{
  '農業、林業' = 'agriculture'; '漁業' = 'fishery'; '鉱業、採石業、砂利採取業' = 'mining'; '建設業' = 'construction'; '製造業' = 'manufacturing'
  '電気・ガス・熱供給・水道業' = 'utilities'; '情報通信業' = 'ict'; '運輸業、郵便業' = 'transport'; '卸売業、小売業' = 'wholesale-retail'
  '金融業、保険業' = 'finance'; '不動産業、物品賃貸業' = 'real-estate'; '学術研究、専門・技術サービス業' = 'professional'
  '宿泊業、飲食サービス業' = 'hospitality'; '生活関連サービス業、娯楽業' = 'lifestyle'; '教育、学習支援業' = 'education'
  '医療、福祉' = 'medical-welfare'; '複合サービス事業' = 'compound'; 'サービス業（他に分類されないもの）' = 'other-services'
}

# ---------- HTTP ----------
Add-Type -AssemblyName System.Net.Http
$Http = New-Object System.Net.Http.HttpClient
$Http.Timeout = [TimeSpan]::FromSeconds(90)
$Http.DefaultRequestHeaders.UserAgent.ParseAdd('HojokinWatch/0.2')

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

function Format-Date($d) { if ($d) { $d.ToString('yyyy年M月d日(ddd) HH:mm', $Ja) } else { '—' } }
function Format-Day($d) { if ($d) { $d.ToString('yyyy年M月d日(ddd)', $Ja) } else { '—' } }

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

function Split-List([string]$s) {
  if (-not $s) { return ,@() }
  ,@($s -split '\s*/\s*' | Where-Object { $_ })
}

function Split-Areas([string]$s) {
  if (-not $s) { return ,@('全国') }
  Split-List $s
}

function Convert-HtmlToLines([string]$html) {
  if (-not $html) { return ,@() }
  $s = $html -replace '(?i)<br\s*/?>', "`n" -replace '(?i)</(p|div|li|h[1-6]|tr|ul|ol)>', "`n" -replace '(?i)<li[^>]*>', '・'
  $s = $s -replace '<[^>]+>', ''
  $s = [System.Net.WebUtility]::HtmlDecode($s) -replace [char]0xA0, ' '
  $lines = @($s -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
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

function ConvertTo-JsonText($o) { ConvertTo-Json -InputObject $o -Depth 8 -Compress }

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

# ---------- 東京都「TOKYO補助金サーチ見える化ボード」データ一覧（CC BY） ----------
# 年度ごとのCSV（Shift_JIS）。締切は含まれない制度一覧なので、Ｊグランツの案件とは別のページで扱う。
$TokyoTargets = @('民間団体', '一般都民', 'その他団体')
if (-not $SkipFetch) {
  try { [Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance) } catch { }
  $fy = $Now.Year; if ($Now.Month -lt 4) { $fy-- }
  foreach ($y in @($fy, ($fy - 1))) {
    try {
      $bytes = $Http.GetByteArrayAsync("https://www.opendata.metro.tokyo.lg.jp/zaimu/hojokin$y.csv").GetAwaiter().GetResult()
      $text = [Text.Encoding]::GetEncoding(932).GetString($bytes)
      if ($text -notmatch '補助金名') { $text = [Text.Encoding]::UTF8.GetString($bytes) }
      $rows = @($text | ConvertFrom-Csv | Where-Object { $TokyoTargets -contains $_.'補助対象者' })
      if ($rows.Count -lt 10) { throw "too few rows: $($rows.Count)" }
      $items = @($rows | ForEach-Object {
          [ordered]@{ year = $_.'年度'; bureau = $_.'所管局'; field = $_.'施策分野'; project = $_.'事業名'; name = $_.'補助金名'; summary = $_.'補助金の概要'
            target = $_.'補助対象者'; budget = $_.'予算額（千円）'; dept = $_.'所管部署'; contact = $_.'問い合わせ先'; url = $_.'各局HPリンク' }
        })
      Write-File $TokyoCache (ConvertTo-Json -InputObject ([ordered]@{ year = $y; fetched = $Now.ToString('yyyy-MM-dd'); items = $items }) -Depth 4)
      Write-Host "tokyo: $y $($items.Count) items"
      break
    } catch { Write-Warning "tokyo $y failed: $_" }
  }
}
$Tokyo = $null
if (Test-Path $TokyoCache) { $Tokyo = [IO.File]::ReadAllText($TokyoCache, $Utf8) | ConvertFrom-Json }
$tokyoCount = 0
if ($Tokyo -and $Tokyo.items) { $tokyoCount = @($Tokyo.items).Count }
$Employment = $null
if (Test-Path $EmploymentPath) { $Employment = [IO.File]::ReadAllText($EmploymentPath, $Utf8) | ConvertFrom-Json }
$Major = $null
if (Test-Path $MajorPath) { $Major = [IO.File]::ReadAllText($MajorPath, $Utf8) | ConvertFrom-Json }

# ---------- 表示用の派生情報 ----------
function Get-Status($rec) {
  $end = ConvertTo-Jst $rec.end
  $start = ConvertTo-Jst $rec.start
  if ($end -and $end -lt $Now) { return 'closed' }
  if ($start -and $start -gt $Now) { return 'upcoming' }
  'open'
}

function Get-PurposeLabels($rec) {
  ,@((Split-List $rec.purpose) | ForEach-Object { if ($Purposes.Contains($_)) { $Purposes[$_][1] } else { $_ } })
}

function Test-New($rec) {
  if ($rec.firstSeen -and $rec.firstSeen -gt $LaunchDate) { return $true }
  $start = ConvertTo-Jst $rec.start
  ($start -and ($Now - $start).TotalDays -le 14 -and ($Now - $start).TotalDays -ge 0)
}

function Get-Badge($rec) {
  $status = Get-Status $rec
  $days = Get-DaysLeft (ConvertTo-Jst $rec.end)
  if ($status -eq 'closed') { return '<span class="badge closed">受付終了</span>' }
  if ($status -eq 'upcoming') { return '<span class="badge soon">受付開始前</span>' }
  if ($null -ne $days -and $days -le 0) { return '<span class="badge urgent">本日締切</span>' }
  if ($null -ne $days -and $days -le 7) { return "<span class=""badge urgent"">締切まであと$($days)日</span>" }
  if ($null -ne $days) { return "<span class=""badge"">締切まであと$($days)日</span>" }
  ''
}

# ---------- レイアウト ----------
$LogoSvg = '<svg viewBox="0 0 32 32" width="32" height="32" aria-hidden="true"><rect width="32" height="32" rx="7" fill="#1d4f91"/><path d="M8 9h16v3H8zM8 15h16v3H8zM8 21h10v3H8z" fill="#fff" opacity=".9"/><circle cx="24" cy="23" r="4.5" fill="#f5a623"/></svg>'
$Favicon = 'data:image/svg+xml,' + [uri]::EscapeDataString('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="7" fill="#1d4f91"/><path d="M8 9h16v3H8zM8 15h16v3H8zM8 21h10v3H8z" fill="#fff"/><circle cx="24" cy="23" r="4.5" fill="#f5a623"/></svg>')
$Built = $Now.ToString('yyyy年M月d日 HH:mm', $Ja)

function Get-Layout {
  param([string]$Title, [string]$Desc, [string]$Body, [string]$Path, [int]$Depth = 0, [switch]$NoIndex, [object[]]$Crumbs = @(), [string]$JsonLd = '', [switch]$Is404)
  $p = ''; for ($i = 0; $i -lt $Depth; $i++) { $p += '../' }
  $head = New-Object System.Collections.ArrayList
  if ($Is404) { [void]$head.Add("<base href=""$BasePath"">") }
  if ($SiteUrl -and -not $Is404) {
    [void]$head.Add("<link rel=""canonical"" href=""$SiteUrl/$Path"">")
    [void]$head.Add("<meta property=""og:url"" content=""$SiteUrl/$Path"">")
  }
  if ($NoIndex) { [void]$head.Add('<meta name="robots" content="noindex">') }
  $crumbHtml = ''
  if ($Crumbs.Count -gt 0) {
    $items = @("<a href=""${p}index.html"">ホーム</a>")
    $ld = @([ordered]@{ '@type' = 'ListItem'; position = 1; name = 'ホーム'; item = "$SiteUrl/" })
    $pos = 2
    foreach ($c in $Crumbs) {
      if ($c[1]) { $items += "<a href=""$($c[1])"">$(Esc $c[0])</a>" } else { $items += "<span aria-current=""page"">$(Esc $c[0])</span>" }
      $item = [ordered]@{ '@type' = 'ListItem'; position = $pos; name = $c[0] }
      if ($SiteUrl) { if ($c[2]) { $item.item = "$SiteUrl/$($c[2])" } else { $item.item = "$SiteUrl/$Path" } }
      $ld += $item; $pos++
    }
    $crumbHtml = '<nav class="crumbs" aria-label="パンくずリスト">' + ($items -join '<span class="sep">›</span>') + '</nav>'
    if ($SiteUrl) { [void]$head.Add('<script type="application/ld+json">' + (ConvertTo-JsonText ([ordered]@{ '@context' = 'https://schema.org'; '@type' = 'BreadcrumbList'; itemListElement = $ld })) + '</script>') }
  }
  if ($JsonLd) { [void]$head.Add("<script type=""application/ld+json"">$JsonLd</script>") }
  $headExtra = $head -join "`n"
  $beacon = ''
  if ($CfToken) { $beacon = "<script defer src=""https://static.cloudflareinsights.com/beacon.min.js"" data-cf-beacon='{""token"": ""$(Esc $CfToken)""}'></script>" }
  @"
<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$(Esc $Title)</title>
<meta name="description" content="$(Esc $Desc)">
<meta property="og:title" content="$(Esc $Title)">
<meta property="og:description" content="$(Esc $Desc)">
<meta property="og:type" content="website">
<meta property="og:site_name" content="$SiteName">
<meta property="og:locale" content="ja_JP">
<meta name="twitter:card" content="summary">
$headExtra
<link rel="icon" href="$Favicon">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Noto+Sans+JP:wght@400;500;700&display=swap">
<link rel="stylesheet" href="${p}assets/style.css">
</head>
<body>
<a class="skip" href="#main">本文へ移動</a>
<div class="notice"><div class="wrap">当サイトは、補助金の公開情報を整理して紹介する<strong>民間の情報サイト</strong>です。申請はＪグランツなどの公式窓口で行ってください。当サイトが申請代行・手数料・個人情報を求めることはありません。</div></div>
<header class="site-header">
  <div class="wrap header-inner">
    <a class="brand" href="${p}index.html">$LogoSvg<span class="brand-text"><span class="brand-name">$SiteName</span><span class="brand-sub">受付中の補助金・助成金を毎日更新</span></span></a>
    <form class="hsearch" action="${p}index.html" method="get" role="search">
      <input name="q" type="search" placeholder="キーワードで補助金を探す" aria-label="キーワード">
      <button type="submit">検索</button>
    </form>
  </div>
  <nav class="gnav" aria-label="メインメニュー"><div class="wrap">
    <a href="${p}index.html#search">補助金を探す</a><a href="${p}shindan.html">補助金診断</a><a href="${p}major/index.html">主要な補助金</a><a href="${p}deadline.html">締切間近</a><a href="${p}area/index.html">地域から探す</a><a href="${p}purpose/index.html">目的から探す</a><a href="${p}employment.html">雇用の助成金</a><a href="${p}tokyo/index.html">東京都の制度</a><a href="${p}guide.html">はじめての方へ</a>
  </div></nav>
</header>
<div class="updated"><div class="wrap">最終更新：$Built（毎朝5時30分ごろに自動更新）／ データ出典：Ｊグランツ（デジタル庁）</div></div>
<main id="main" class="wrap">
$crumbHtml
$Body
</main>
<footer class="site-footer">
  <div class="wrap footer-grid">
    <div>
      <p class="f-brand">$SiteName</p>
      <p>国や自治体の補助金のうち、Ｊグランツで受付中のものを、締切・地域・目的で探しやすく整理しています。</p>
    </div>
    <div>
      <p class="f-head">補助金を探す</p>
      <ul><li><a href="${p}shindan.html">補助金診断</a></li><li><a href="${p}major/index.html">主要な補助金の解説</a></li><li><a href="${p}deadline.html">締切間近の補助金</a></li><li><a href="${p}new.html">新着の補助金</a></li><li><a href="${p}area/index.html">地域から探す</a></li><li><a href="${p}purpose/index.html">目的から探す</a></li><li><a href="${p}industry/index.html">業種から探す</a></li></ul>
    </div>
    <div>
      <p class="f-head">ご利用案内</p>
      <ul><li><a href="${p}guide.html">はじめての方へ（探し方と申請の流れ）</a></li><li><a href="${p}employment.html">国の雇用関係助成金</a></li><li><a href="${p}tokyo/index.html">東京都の補助金制度一覧</a></li><li><a href="${p}childbirth.html">妊娠・出産で使える国の制度</a></li><li><a href="${p}faq.html">よくある質問</a></li><li><a href="${p}about.html">運営者情報・運営方針</a></li><li><a href="${p}privacy.html">プライバシーポリシー</a></li><li><a href="$(Esc $ReportUrl)" rel="nofollow noopener" target="_blank">掲載内容の誤りを報告する</a></li></ul>
    </div>
  </div>
  <div class="wrap f-legal">
    <p>出典：「Ｊグランツ」（<a href="https://www.jgrants-portal.go.jp" rel="nofollow noopener" target="_blank">https://www.jgrants-portal.go.jp</a>）をもとに$SiteName 運営者が編集・加工して作成しています。本サイトは国・自治体・デジタル庁の公式サイトではなく、これらの機関とは関係ありません。掲載情報は自動取得のため、誤りや変更がある場合があります。申請前に必ず公式の公募要領をご確認ください。</p>
    <p>&copy; $($Now.Year) $SiteName</p>
  </div>
</footer>
$beacon
</body>
</html>
"@
}

function Get-Card($rec, [string]$p) {
  $end = ConvertTo-Jst $rec.end
  $areas = (Split-Areas $rec.area) -join '・'
  $newChip = ''
  if (Test-New $rec) { $newChip = '<span class="chip new">新着</span>' }
  $rate = '公募要領を参照'
  if ($rec.rate) { $rate = $rec.rate }
  $tags = ''
  $labels = Get-PurposeLabels $rec
  if ($labels.Count -gt 0) { $tags = '<div class="tags">' + (($labels | Select-Object -First 3 | ForEach-Object { "<span class=""tag"">$(Esc $_)</span>" }) -join '') + '</div>' }
  @"
<li class="card"><a href="${p}s/$($rec.id).html">
  <div class="card-head">$(Get-Badge $rec)<span class="chip">$(Esc $areas)</span>$newChip</div>
  <h3>$(Esc $rec.title)</h3>
  <dl class="kv"><div><dt>上限額</dt><dd>$(Esc (Format-Yen $rec.maxLimit))</dd></div><div><dt>補助率</dt><dd>$(Esc $rate)</dd></div><div><dt>締切</dt><dd>$(Esc (Format-Date $end))</dd></div></dl>
  $tags
</a></li>
"@
}

function Get-CardList($items, [string]$p, [string]$empty = '該当する補助金は現在ありません。') {
  $arr = @($items)
  if ($arr.Count -eq 0) { return "<p class=""empty"">$empty</p>" }
  '<ul class="cards">' + (($arr | ForEach-Object { Get-Card $_ $p }) -join '') + '</ul>'
}

if (Test-Path $Dist) { Remove-Item -Recurse -Force $Dist }
New-Item -ItemType Directory -Force (Join-Path $Dist 'assets') | Out-Null
Copy-Item (Join-Path $StaticDir '*') (Join-Path $Dist 'assets') -Recurse
# サイト直下に置くファイル（Search Consoleの所有権確認ファイルなど）
if (Test-Path $RootDir) { Copy-Item (Join-Path $RootDir '*') $Dist -Recurse }

$open = @($all | Where-Object { (Get-Status $_) -ne 'closed' })
$accepting = @($open | Where-Object { (Get-Status $_) -eq 'open' })
$soon = @($accepting | Where-Object { $d = Get-DaysLeft (ConvertTo-Jst $_.end); $null -ne $d -and $d -le 14 })
$soon7 = @($soon | Where-Object { (Get-DaysLeft (ConvertTo-Jst $_.end)) -le 7 })
$newOnes = @($open | Where-Object { Test-New $_ } | Sort-Object { $_.start } -Descending)
$sitemap = New-Object System.Collections.ArrayList
$checklist = @'
<section class="box checklist">
  <h2>申請前に確認したいこと</h2>
  <ul>
    <li>公募要領で、対象者・対象経費・補助率を確認しましたか</li>
    <li>Ｊグランツでの申請には「GビズIDプライム」が必要です。取得には日数がかかる場合があります</li>
    <li>多くの補助金は、交付決定の前に発注・契約した経費を対象外としています</li>
    <li>締切は日付だけでなく時刻まで確認しましょう</li>
  </ul>
</section>
'@

# ---------- 詳細ページ ----------
foreach ($rec in $all) {
  $end = ConvertTo-Jst $rec.end
  $start = ConvertTo-Jst $rec.start
  $days = Get-DaysLeft $end
  $status = Get-Status $rec
  $areas = Split-Areas $rec.area
  $labels = Get-PurposeLabels $rec
  $statusText = '受付中'
  if ($status -eq 'closed') { $statusText = '受付終了' }
  elseif ($status -eq 'upcoming') { $statusText = "受付開始前（$(Format-Date $start)から）" }
  elseif ($null -ne $days -and $days -le 0) { $statusText = '受付中（本日締切）' }
  elseif ($null -ne $days) { $statusText = "受付中（締切まであと$($days)日）" }

  # 要点の文章（構造化データから組み立てる）
  $sum = "「$($rec.title)」は、$($areas -join '・')を対象とした補助金です。"
  if ($labels.Count -gt 0) { $sum += "主な利用目的は「$($labels -join '」「')」です。" }
  $sum += "補助上限額は$(Format-Yen $rec.maxLimit)"
  if ($rec.rate) { $sum += "、補助率は$($rec.rate)" }
  $sum += 'です。'
  if ($status -eq 'closed') { $sum += "受付は$(Format-Date $end)に終了しました。" }
  else { $sum += "受付期間は$(Format-Date $start)から$(Format-Date $end)までです。" }

  $rows = New-Object System.Collections.ArrayList
  [void]$rows.Add(@('受付状況', $statusText))
  [void]$rows.Add(@('対象地域', ($areas -join '、')))
  [void]$rows.Add(@('補助上限額', (Format-Yen $rec.maxLimit)))
  if ($rec.rate) { [void]$rows.Add(@('補助率', $rec.rate)) }
  [void]$rows.Add(@('受付期間', "$(Format-Date $start) 〜 $(Format-Date $end)"))
  if ($rec.employees) { [void]$rows.Add(@('従業員数', $rec.employees)) }
  if ($labels.Count -gt 0) { [void]$rows.Add(@('利用目的', ($labels -join '、'))) }
  if ($rec.industry) { [void]$rows.Add(@('対象業種', ($rec.industry -replace '\s*/\s*', '、'))) }
  if ($rec.institution) { [void]$rows.Add(@('実施機関・事業名', $rec.institution)) }
  $table = ($rows | ForEach-Object { "<tr><th scope=""row"">$(Esc $_[0])</th><td>$(Esc $_[1])</td></tr>" }) -join "`n"

  $bodyLines = '<p class="empty">概要は準備中です。公式ページで内容をご確認ください。</p>'
  if ($rec.lines) {
    $bodyLines = ($rec.lines | ForEach-Object {
        if ($_ -match '^[■◆●【]') { "<h3>$(Esc $_)</h3>" } else { "<p>$(Convert-Links (Esc $_))</p>" }
      }) -join "`n"
  }
  $docs = ''
  if ($rec.docs -and @($rec.docs).Count -gt 0) {
    $docs = '<section><h2>公式に掲載されている書類</h2><ul class="docs">' + ((@($rec.docs) | ForEach-Object { "<li>$(Esc $_)</li>" }) -join '') + '</ul><p class="note">書類は公式ページ（Ｊグランツ）からダウンロードしてください。</p></section>'
  }
  $official = $rec.officialUrl
  if (-not $official) { $official = "https://www.jgrants-portal.go.jp/subsidy/$($rec.id)" }
  $catch = ''
  if ($rec.catch) { $catch = "<p class=""lead"">$(Esc $rec.catch)</p>" }

  # 関連する補助金（同じ目的 → 同じ地域）
  $myPurposes = Split-List $rec.purpose
  $related = @($accepting | Where-Object { $_.id -ne $rec.id -and (@((Split-List $_.purpose) | Where-Object { $myPurposes -contains $_ }).Count -gt 0) } | Select-Object -First 4)
  $sameArea = @($accepting | Where-Object { $_.id -ne $rec.id -and (@((Split-Areas $_.area) | Where-Object { $areas -contains $_ }).Count -gt 0) } | Select-Object -First 4)
  $relHtml = ''
  if ($related.Count -gt 0) { $relHtml += '<section><h2>同じ目的の補助金</h2>' + (Get-CardList $related '../') + '</section>' }
  if ($sameArea.Count -gt 0) { $relHtml += "<section><h2>$(Esc ($areas -join '・'))の補助金</h2>" + (Get-CardList $sameArea '../') + '</section>' }
  $links = @()
  foreach ($a in $areas) { if ($PrefSlug.ContainsKey($a)) { $links += "<a href=""../area/$($PrefSlug[$a]).html"">$(Esc $a)の補助金一覧</a>" } }
  foreach ($pp in $myPurposes) { if ($Purposes.Contains($pp)) { $links += "<a href=""../purpose/$($Purposes[$pp][0]).html"">「$(Esc $Purposes[$pp][1])」の補助金一覧</a>" } }

  # 締切をカレンダーに登録する（Googleカレンダーのリンクと、iPhone・Outlook向けの .ics ファイル）
  $calHtml = ''
  if ($status -ne 'closed' -and $end) {
    $d1 = $end.ToString('yyyyMMdd'); $d2 = $end.AddDays(1).ToString('yyyyMMdd')
    $pageUrl = "$SiteUrl/s/$($rec.id).html"
    $calText = "【締切】$($rec.title)"
    $calDetails = "受付締切：$(Format-Date $end)`n詳細：$pageUrl"
    $gcal = 'https://calendar.google.com/calendar/render?action=TEMPLATE&text=' + [uri]::EscapeDataString($calText) + "&dates=$d1/$d2&details=" + [uri]::EscapeDataString($calDetails)
    $icsEsc = { param($s) ("$s" -replace '\\', '\\' -replace ';', '\;' -replace ',', '\,' -replace "`n", '\n') }
    $stamp = [DateTime]::UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'")
    $ics = "BEGIN:VCALENDAR`r`nVERSION:2.0`r`nPRODID:-//hojokin-watch//JA`r`nCALSCALE:GREGORIAN`r`nBEGIN:VEVENT`r`nUID:$($rec.id)@hojokin-watch`r`nDTSTAMP:$stamp`r`nDTSTART;VALUE=DATE:$d1`r`nDTEND;VALUE=DATE:$d2`r`nSUMMARY:$(& $icsEsc $calText)`r`nDESCRIPTION:$(& $icsEsc $calDetails)`r`nURL:$pageUrl`r`nBEGIN:VALARM`r`nTRIGGER:-P7D`r`nACTION:DISPLAY`r`nDESCRIPTION:$(& $icsEsc ('締切まであと7日：' + $rec.title))`r`nEND:VALARM`r`nEND:VEVENT`r`nEND:VCALENDAR`r`n"
    Write-File (Join-Path $Dist "s/$($rec.id).ics") $ics
    $calHtml = "<p class=""cal"">締切をカレンダーに登録する：<a href=""$(Esc $gcal)"" rel=""nofollow noopener"" target=""_blank"">Googleカレンダー</a>／<a href=""$($rec.id).ics"" download>iPhone・Outlookなど（.ics）</a><br><span class=""note"">締切日の予定と、7日前の通知が登録されます。</span></p>"
  }

  $fetched = $rec.detailFetched
  if (-not $fetched) { $fetched = $rec.lastSeen }
  $body = @"
<article class="detail">
<div class="detail-head">$(Get-Badge $rec)<span class="chip">$(Esc ($areas -join '・'))</span></div>
<h1>$(Esc $rec.title)</h1>
$catch
<section class="box summary"><h2>この補助金の要点</h2><p>$(Esc $sum)</p></section>
<table class="facts">$table</table>
<div class="cta"><a class="btn" href="$(Esc $official)" rel="nofollow noopener" target="_blank">公式ページ（Ｊグランツ）で詳細を確認する</a><p class="note">申請はＪグランツから行います。当サイトでは申請の受付・代行は行っていません。</p>$calHtml</div>
<section><h2>概要（公式の掲載内容より）</h2><div class="body">$bodyLines</div></section>
$docs
$checklist
<p class="source">情報の取得日：$(Esc $fetched)／出典：<a href="$(Esc $official)" rel="nofollow noopener" target="_blank">Ｊグランツの掲載ページ</a>（掲載内容を編集・加工しています）</p>
<p class="related-links">$($links -join ' ')</p>
$relHtml
</article>
"@
  $desc = "$($rec.title)｜対象地域：$($areas -join '・')、上限：$(Format-Yen $rec.maxLimit)、締切：$(Format-Date $end)。受付状況、補助率、対象者、概要をまとめています。"
  $crumbs = @(, @('地域から探す', '../area/index.html', 'area/index.html'))
  if ($areas.Count -gt 0 -and $PrefSlug.ContainsKey($areas[0])) { $crumbs += , @($areas[0], "../area/$($PrefSlug[$areas[0]]).html", "area/$($PrefSlug[$areas[0]]).html") }
  $crumbs += , @($rec.title, '', '')
  $html = Get-Layout -Title "$($rec.title)｜$SiteName" -Desc $desc -Body $body -Path "s/$($rec.id).html" -Depth 1 -NoIndex:($status -eq 'closed') -Crumbs $crumbs
  Write-File (Join-Path $Dist "s/$($rec.id).html") $html
  if ($status -ne 'closed') { [void]$sitemap.Add("s/$($rec.id).html") }
}

# ---------- 地域別 ----------
$national = @($open | Where-Object { (Split-Areas $_.area) -contains '全国' })
$prefCount = @{}
foreach ($pref in $Prefectures) {
  $local = @($open | Where-Object { (Split-Areas $_.area) -contains $pref })
  $prefCount[$pref] = $local.Count
  if ($local.Count -eq 0 -and $pref -ne '全国') { continue }
  $slug = $PrefSlug[$pref]
  if ($pref -eq '全国') {
    $body = "<h1>全国を対象とした補助金・助成金（受付中 $($local.Count)件）</h1><p class=""lead"">地域を問わず申請できる補助金を、締切が近い順に並べています。</p>" + (Get-CardList $local '../')
  } else {
    $body = "<h1>$(Esc $pref)の補助金・助成金（受付中 $($local.Count)件）</h1><p class=""lead"">Ｊグランツに掲載されている$(Esc $pref)対象の補助金を、締切が近い順に並べています。全国を対象とした補助金も申請できる場合があります。</p>"
    if ($pref -eq '東京都' -and $tokyoCount -gt 0) {
      $body += "<p class=""box summary"">Ｊグランツに載っていない東京都独自の補助金も、<a href=""../tokyo/index.html"">東京都の補助金制度一覧（$($tokyoCount)件）</a>で確認できます。</p>"
    }
    $body += Get-CardList $local '../'
    if ($national.Count -gt 0) {
      $body += "<section><h2>全国を対象とした補助金（締切が近い10件）</h2>" + (Get-CardList ($national | Select-Object -First 10) '../') + "<p class=""more""><a href=""00.html"">全国対象の補助金をすべて見る（$($national.Count)件）</a></p></section>"
    }
  }
  $html = Get-Layout -Title "$pref の補助金・助成金一覧（受付中$($local.Count)件）｜$SiteName" -Desc "$pref で申請できる受付中の補助金・助成金 $($local.Count) 件を締切順に掲載。上限額・補助率・締切がひと目でわかります。毎日自動更新。" -Body $body -Path "area/$slug.html" -Depth 1 -Crumbs @(@('地域から探す', 'index.html', 'area/index.html'), @($pref, '', ''))
  Write-File (Join-Path $Dist "area/$slug.html") $html
  [void]$sitemap.Add("area/$slug.html")
}
# 地域 → 都道府県の2段階で選ぶ（JavaScriptなしで開閉できる details を使う）
function Get-PrefGrid([string]$p) {
  $html = "<p class=""nat-link""><a href=""${p}00.html"">全国を対象とした補助金（$($prefCount['全国'])件）</a></p><div class=""regions"">"
  foreach ($r in $Regions.Keys) {
    $sum = 0
    foreach ($pref in $Regions[$r]) { $sum += $prefCount[$pref] }
    $lis = ($Regions[$r] | ForEach-Object {
        if ($prefCount[$_] -gt 0) { "<li><a href=""${p}$($PrefSlug[$_]).html"">$(Esc $_)<span>$($prefCount[$_])件</span></a></li>" }
        else { "<li class=""empty"">$(Esc $_)<span>0件</span></li>" }
      }) -join ''
    $html += "<details class=""region""><summary><span class=""r-name"">$(Esc $r)</span><span class=""r-count"">$($sum)件</span></summary><ul class=""prefs"">$lis</ul></details>"
  }
  $html + '</div><p class="note">地域を選ぶと都道府県が表示されます。件数には、複数の都道府県を対象とする補助金を重複して数えています。</p>'
}
$body = '<h1>地域から補助金を探す</h1><p class="lead">都道府県を選ぶと、その地域を対象とした受付中の補助金と、全国を対象とした補助金を確認できます。</p>' + (Get-PrefGrid '')
Write-File (Join-Path $Dist 'area/index.html') (Get-Layout -Title "地域から探す｜都道府県別の補助金・助成金一覧｜$SiteName" -Desc '都道府県ごとに受付中の補助金・助成金を一覧できます。毎日自動更新。' -Body $body -Path 'area/index.html' -Depth 1 -Crumbs @(, @('地域から探す', '', '')))
[void]$sitemap.Add('area/index.html')

# ---------- 目的別 ----------
$purposeCount = @{}
foreach ($key in $Purposes.Keys) {
  $info = $Purposes[$key]
  $items = @($open | Where-Object { (Split-List $_.purpose) -contains $key })
  $purposeCount[$key] = $items.Count
  if ($items.Count -eq 0) { continue }
  $body = "<h1>「$(Esc $info[1])」に使える補助金（受付中 $($items.Count)件）</h1><p class=""lead"">$(Esc $info[2])に使える補助金を、締切が近い順に並べています。対象地域や対象経費は補助金ごとに異なるため、公募要領で必ずご確認ください。</p>"
  if (@('employment', 'training', 'childcare') -contains $info[0]) { $body += '<p class="box summary">雇用・人材育成・育児との両立に取り組む事業主は、Ｊグランツ以外で申請する厚生労働省の助成金も利用できる場合があります。<a href="../employment.html">国の雇用関係助成金の一覧を見る ›</a></p>' }
  $body += (Get-CardList $items '../')
  $html = Get-Layout -Title "$($info[1])の補助金・助成金一覧（受付中$($items.Count)件）｜$SiteName" -Desc "$($info[1])（$($info[2])）に使える受付中の補助金 $($items.Count) 件を締切順に掲載。毎日自動更新。" -Body $body -Path "purpose/$($info[0]).html" -Depth 1 -Crumbs @(@('目的から探す', 'index.html', 'purpose/index.html'), @($info[1], '', ''))
  Write-File (Join-Path $Dist "purpose/$($info[0]).html") $html
  [void]$sitemap.Add("purpose/$($info[0]).html")
}
function Get-PurposeTiles([string]$p) {
  $tiles = foreach ($key in $Purposes.Keys) {
    $info = $Purposes[$key]
    if ($purposeCount[$key] -gt 0) { "<li><a href=""${p}$($info[0]).html""><span class=""t-name"">$(Esc $info[1])</span><span class=""t-desc"">$(Esc $info[2])</span><span class=""t-count"">$($purposeCount[$key])件</span></a></li>" }
  }
  '<ul class="tiles">' + ($tiles -join '') + '</ul>'
}
$body = '<h1>目的から補助金を探す</h1><p class="lead">「何に使いたいか」から補助金を探せます。件数は受付中・受付開始前のものです。</p>' + (Get-PurposeTiles '')
Write-File (Join-Path $Dist 'purpose/index.html') (Get-Layout -Title "目的から探す｜設備投資・IT導入・創業などの補助金一覧｜$SiteName" -Desc '設備投資、IT導入、新事業、雇用、省エネなど、目的別に受付中の補助金を一覧できます。' -Body $body -Path 'purpose/index.html' -Depth 1 -Crumbs @(, @('目的から探す', '', '')))
[void]$sitemap.Add('purpose/index.html')

# ---------- 業種別（対象業種を絞っている補助金のみ。全業種対象のものは重複になるため載せない） ----------
$indLinks = @()
foreach ($ind in $Industries.Keys) {
  $items = @($open | Where-Object { $l = Split-List $_.industry; $l.Count -le 5 -and $l -contains $ind })
  if ($items.Count -lt 2) { continue }
  $slug = $Industries[$ind]
  $indLinks += "<li><a href=""$slug.html"">$(Esc $ind)<span>$($items.Count)件</span></a></li>"
  $body = "<h1>$(Esc $ind)向けの補助金（受付中 $($items.Count)件）</h1><p class=""lead"">対象業種を「$(Esc $ind)」などに絞っている補助金を並べています。業種を問わない補助金は<a href=""../index.html#search"">補助金を探す</a>から検索できます。</p>" + (Get-CardList $items '../')
  $html = Get-Layout -Title "$ind 向けの補助金・助成金一覧（受付中$($items.Count)件）｜$SiteName" -Desc "$ind を対象とした受付中の補助金 $($items.Count) 件を締切順に掲載。毎日自動更新。" -Body $body -Path "industry/$slug.html" -Depth 1 -Crumbs @(@('業種から探す', 'index.html', 'industry/index.html'), @($ind, '', ''))
  Write-File (Join-Path $Dist "industry/$slug.html") $html
  [void]$sitemap.Add("industry/$slug.html")
}
$body = '<h1>業種から補助金を探す</h1><p class="lead">対象業種を絞っている補助金を、業種ごとにまとめています。多くの補助金は業種を問わず申請できるため、あわせて<a href="../index.html#search">キーワード検索</a>もご利用ください。</p><ul class="prefs wide">' + ($indLinks -join '') + '</ul>'
Write-File (Join-Path $Dist 'industry/index.html') (Get-Layout -Title "業種から探す｜業種別の補助金・助成金一覧｜$SiteName" -Desc '製造業、建設業、飲食業など、業種を絞った受付中の補助金を一覧できます。' -Body $body -Path 'industry/index.html' -Depth 1 -Crumbs @(, @('業種から探す', '', '')))
[void]$sitemap.Add('industry/index.html')

# ---------- 締切間近・新着 ----------
$body = "<h1>締切間近の補助金（14日以内・$($soon.Count)件）</h1><p class=""lead"">受付締切まで14日以内の補助金です。申請には事業計画の作成やGビズIDの取得など準備に時間がかかるものが多いため、早めに公募要領を確認してください。</p>" + (Get-CardList $soon '')
Write-File (Join-Path $Dist 'deadline.html') (Get-Layout -Title "締切間近の補助金・助成金（14日以内）｜$SiteName" -Desc "受付締切まで14日以内の補助金・助成金 $($soon.Count) 件。毎日自動更新。" -Body $body -Path 'deadline.html' -Crumbs @(, @('締切間近', '', '')))
[void]$sitemap.Add('deadline.html')
$body = "<h1>新着の補助金（$($newOnes.Count)件）</h1><p class=""lead"">最近受付が始まった補助金と、当サイトで新しく見つかった補助金です。受付開始日の新しい順に並べています。</p>" + (Get-CardList $newOnes '' '新着の補助金は現在ありません。')
Write-File (Join-Path $Dist 'new.html') (Get-Layout -Title "新着の補助金・助成金｜$SiteName" -Desc "最近受付が始まった補助金・助成金 $($newOnes.Count) 件。毎日自動更新。" -Body $body -Path 'new.html' -Crumbs @(, @('新着', '', '')))
[void]$sitemap.Add('new.html')

# ---------- 主要な補助金の解説（中小企業庁・ミラサポplusの掲載をもとに要約） ----------
function Get-FrameStatus($fr) {
  if (-not $fr.end) { if ($fr.note -match '随時') { return @('open', $fr.note) } else { return @('closed', $fr.note) } }
  $s = [DateTime]::Parse($fr.start); $e = [DateTime]::Parse($fr.end)
  $today = $Now.DateTime.Date
  if ($today -lt $s) { return @('soon', "受付開始前（$($s.ToString('M月d日(ddd)', $Ja))から）") }
  if ($today -le $e) { $left = ($e - $today).Days; return @('open', "受付中（$($e.ToString('M月d日(ddd)', $Ja))まで・あと$($left)日）") }
  @('closed', '受付終了（次回の公募は公式サイトで確認）')
}
function Get-MajorStatus($m) {
  # 枠の中でいちばん「受付中」に近い状態を代表として返す
  $st = @($m.frames | ForEach-Object { , (Get-FrameStatus $_) })
  foreach ($k in 'open', 'soon', 'closed') { $hit = @($st | Where-Object { $_[0] -eq $k }); if ($hit.Count) { return $hit[0] } }
  @('closed', '')
}
$majorCards = ''
if ($Major) {
  $mSource = "<p class=""source"">出典：中小企業庁「ミラサポplus（人気の補助金）」および各補助金の公式サイトの掲載内容をもとに、$SiteName 運営者が要約して作成。確認日：$(Esc $Major.checked)。最新の要件・スケジュールは必ず公式サイトでご確認ください。</p>"
  foreach ($m in $Major.items) {
    $rows = ($m.frames | ForEach-Object {
        $fs = Get-FrameStatus $_
        $period = $_.note
        if ($_.end) { $period = "$([DateTime]::Parse($_.start).ToString('yyyy年M月d日(ddd)', $Ja)) 〜 $([DateTime]::Parse($_.end).ToString('M月d日(ddd)', $Ja))" }
        "<tr><th scope=""row"">$(Esc $_.name)</th><td>$(Esc $_.use)</td><td>$(Esc $period)</td><td><span class=""badge $($fs[0])"">$(Esc $fs[1])</span></td></tr>"
      }) -join ''
    $kw = @($m.keywords)
    $live = @($accepting | Where-Object { $t = $_.title; @($kw | Where-Object { $t -like "*$_*" }).Count -gt 0 } | Select-Object -First 8)
    $liveHtml = ''
    if ($live.Count -gt 0) { $liveHtml = "<section><h2>Ｊグランツで受付中の関連する公募（$($live.Count)件）</h2>" + (Get-CardList $live '../') + '</section>' }
    $officialHtml = ($m.official | ForEach-Object { "<a class=""btn"" href=""$(Esc $_.url)"" rel=""nofollow noopener"" target=""_blank"">$(Esc $_.label)</a>" }) -join ' '
    $pLinks = (@($m.purposes) | ForEach-Object { $slug = $_; foreach ($k in $Purposes.Keys) { if ($Purposes[$k][0] -eq $slug) { "<a href=""../purpose/$slug.html"">「$(Esc $Purposes[$k][1])」の補助金一覧</a>" } } }) -join ' '
    $others = ($Major.items | Where-Object { $_.slug -ne $m.slug } | ForEach-Object { "<li><a href=""$($_.slug).html"">$(Esc $_.name)</a></li>" }) -join ''
    $body = @"
<article class="detail">
<h1>$(Esc $m.name)とは？対象者・補助率・上限額・受付スケジュール</h1>
<p class="lead">$(Esc $m.lead)</p>
<table class="facts">
<tr><th scope="row">主な対象者</th><td>$(Esc $m.who)</td></tr>
<tr><th scope="row">補助率</th><td>$(Esc $m.rate)</td></tr>
<tr><th scope="row">補助上限額</th><td>$(Esc $m.max)</td></tr>
</table>
<section><h2>受付スケジュール（枠ごと）</h2>
<div class="table-wrap"><table class="facts sched"><thead><tr><th>枠</th><th>主な使い道</th><th>受付期間</th><th>状況</th></tr></thead><tbody>$rows</tbody></table></div>
<p class="note">状況はこのページの最終更新時点のものです。公募の回や期間は変更されることがあります。</p></section>
<section><h2>ポイント</h2><ul class="points">$(($m.points | ForEach-Object { "<li>$(Esc $_)</li>" }) -join '')</ul></section>
<section><h2>活用のイメージ</h2><ul class="points">$(($m.examples | ForEach-Object { "<li>$(Esc $_)</li>" }) -join '')</ul></section>
<div class="cta">$officialHtml<p class="note">申請は公式サイトの案内に沿って行ってください。当サイトは申請の受付・代行は行っていません。</p></div>
$liveHtml
$checklist
<p class="related-links">$pLinks <a href="../shindan.html">補助金診断で、ほかに使える補助金を探す</a></p>
<section><h2>ほかの主要な補助金</h2><ul class="docs">$others</ul></section>
$mSource
</article>
"@
    Write-File (Join-Path $Dist "major/$($m.slug).html") (Get-Layout -Title "$($m.name)とは？補助率・上限額・2026年度の受付スケジュール｜$SiteName" -Desc "$($m.short)の対象者、補助率（$($m.rate)）、上限額（$($m.max)）、枠ごとの受付スケジュール、活用例をわかりやすくまとめました。公式サイトへのリンクつき。" -Body $body -Path "major/$($m.slug).html" -Depth 1 -Crumbs @(@('主要な補助金', 'index.html', 'major/index.html'), @($m.short, '', '')))
    [void]$sitemap.Add("major/$($m.slug).html")
    $ms = Get-MajorStatus $m
    $majorCards += "<li><a href=""$($m.slug).html""><span class=""t-name"">$(Esc $m.short)</span><span class=""t-desc"">補助率 $(Esc $m.rate)／$(Esc $m.max)</span><span class=""t-count""><span class=""badge $($ms[0])"">$(Esc ($ms[1] -replace '（.*', ''))</span></span></a></li>"
  }
  $idxBody = "<h1>主要な補助金の解説（2026年度）</h1><p class=""lead"">中小企業がよく利用する国の主要な補助金について、対象者、補助率、上限額、枠ごとの受付スケジュールをまとめました。</p><ul class=""tiles"">$majorCards</ul><p class=""more""><a href=""../shindan.html"">質問に答えて、使える補助金を探す（補助金診断） ›</a></p>$mSource"
  Write-File (Join-Path $Dist 'major/index.html') (Get-Layout -Title "主要な補助金の解説（持続化・デジタル化・AI導入・省力化・新事業進出・事業承継）｜$SiteName" -Desc '持続化補助金、デジタル化・AI導入補助金、省力化投資補助金、新事業進出・ものづくり補助金、事業承継・M&A補助金の対象者・補助率・上限額・受付スケジュールを解説。' -Body $idxBody -Path 'major/index.html' -Depth 1 -Crumbs @(, @('主要な補助金', '', '')))
  [void]$sitemap.Add('major/index.html')
}

# ---------- 補助金診断（質問に答えると使える補助金を表示。処理はブラウザ内のJavaScriptで行う） ----------
$diagMajor = @()
if ($Major) { $diagMajor = @($Major.items | ForEach-Object { $ms = Get-MajorStatus $_; [ordered]@{ slug = $_.slug; name = $_.short; rate = $_.rate; max = $_.max; purposes = @($_.purposes); status = $ms[1]; st = $ms[0] } }) }
$purposeMap = [ordered]@{}
foreach ($k in $Purposes.Keys) { $purposeMap[$Purposes[$k][1]] = $Purposes[$k][0] }
$diagData = ConvertTo-JsonText ([ordered]@{ major = $diagMajor; purposeSlug = $purposeMap; tokyoCount = $tokyoCount })
$diagPrefOptions = '<option value="">選んでください</option><option>全国（地域を問わない）</option>'
foreach ($r in $Regions.Keys) { $diagPrefOptions += "<optgroup label=""$(Esc $r)"">" + (($Regions[$r] | ForEach-Object { "<option>$(Esc $_)</option>" }) -join '') + '</optgroup>' }
$diagPurposeOptions = ($Purposes.Keys | ForEach-Object { "<label class=""opt""><input type=""checkbox"" name=""purpose"" value=""$(Esc $Purposes[$_][1])""> $(Esc $Purposes[$_][1])</label>" }) -join ''
$body = @"
<h1>補助金診断：3つの質問で、使える補助金を探す</h1>
<p class="lead">事業所の場所、従業員数、やりたいことを選ぶと、Ｊグランツで受付中の補助金、国の主要な補助金、雇用関係の助成金の中から、条件に合いそうなものを表示します。入力した内容はこのブラウザの中だけで処理し、どこにも送信しません。</p>
<form id="diag" class="search-box diag" onsubmit="return false">
  <div class="q"><p class="q-title">Q1. 事業所はどこにありますか？</p><select id="d-pref">$diagPrefOptions</select></div>
  <div class="q"><p class="q-title">Q2. 従業員数（パート・アルバイトを含む目安）は？</p>
    <div class="opts">
      <label class="opt"><input type="radio" name="size" value="5"> 5人以下</label>
      <label class="opt"><input type="radio" name="size" value="20"> 6〜20人</label>
      <label class="opt"><input type="radio" name="size" value="100"> 21〜100人</label>
      <label class="opt"><input type="radio" name="size" value="300"> 101〜300人</label>
      <label class="opt"><input type="radio" name="size" value="1000"> 301人以上</label>
    </div></div>
  <div class="q"><p class="q-title">Q3. 補助金を使ってやりたいことは？（複数選べます）</p><div class="opts">$diagPurposeOptions</div></div>
  <p><button id="d-run" class="btn" type="button">診断する</button></p>
</form>
<div id="d-result" class="d-result" hidden></div>
<p class="note">診断結果は、掲載データの対象地域・利用目的・従業員数の条件をもとに機械的に絞り込んだ目安です。実際に申請できるかどうかは、必ず各補助金の公募要領でご確認ください。</p>
<script type="application/json" id="diag-data">$diagData</script>
<script src="assets/shindan.js" defer></script>
"@
Write-File (Join-Path $Dist 'shindan.html') (Get-Layout -Title "補助金診断｜3つの質問で使える補助金・助成金がわかる（無料・登録不要）｜$SiteName" -Desc '事業所の場所、従業員数、やりたいことを選ぶだけで、受付中の補助金、国の主要な補助金、雇用関係の助成金から条件に合いそうなものを表示します。無料・登録不要。' -Body $body -Path 'shindan.html' -Crumbs @(, @('補助金診断', '', '')))
[void]$sitemap.Add('shindan.html')

# ---------- 東京都の補助金制度一覧 ----------
$TokyoFieldSlug = [ordered]@{
  '中小企業支援' = 'sme'; '雇用就業' = 'employment'; '観光' = 'tourism'; '農林水産' = 'agriculture'; '環境' = 'environment'; '都市の整備' = 'urban'
  '子供家庭' = 'children'; '教育' = 'education'; '保健、医療' = 'health'; '高齢者' = 'elderly'; '障害者' = 'disability'; '生活福祉' = 'welfare'
  '生活文化・スポーツ' = 'culture-sports'; '健康安全、感染症' = 'health-safety'; '国際金融都市、特区・外国企業誘致' = 'international'; '警察と消防' = 'safety'; 'その他' = 'other'
}
if ($Tokyo -and $Tokyo.items) {
  $titems = @($Tokyo.items)
  $tAttr = "<p class=""source"">出典：東京都財務局「TOKYO補助金サーチ見える化ボード データ一覧（$($Tokyo.year)年度）」（CC BY）をもとに$SiteName 運営者が編集・加工して作成。取得日：$(Esc $Tokyo.fetched)</p>"
  function Get-TokyoItem($t) {
    $sumLines = (("$($t.summary)" -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { "<p>$(Esc ($_ -replace '^[・\s]+', '・'))</p>" }) -join ''
    $budget = '—'
    $n = 0.0
    if ([double]::TryParse(("$($t.budget)" -replace ',', ''), [ref]$n) -and $n -gt 0) { $budget = Format-Yen ($n * 1000) }
    $link = ''
    if ("$($t.url)" -match '^https?://') { $link = "<a class=""btn-sub small"" href=""$(Esc $t.url)"" rel=""nofollow noopener"" target=""_blank"">所管局のページで確認する</a>" }
    @"
<li class="titem"><h3>$(Esc $t.name)</h3>
<div class="card-head"><span class="chip">$(Esc $t.target)</span><span class="tag">$(Esc $t.bureau)</span></div>
<div class="tsum">$sumLines</div>
<dl class="kv"><div><dt>事業名</dt><dd>$(Esc $t.project)</dd></div><div><dt>予算額（年度）</dt><dd>$(Esc $budget)</dd></div><div><dt>問い合わせ先</dt><dd>$(Esc $t.dept) $(Esc $t.contact)</dd></div></dl>
$link</li>
"@
  }
  $tokyoNote = '<p class="note">この一覧は、東京都の年度予算に計上されている補助金の制度一覧です（募集期間や締切は含まれていません）。募集の有無や時期、申請方法は、所管局のページで必ずご確認ください。区市町村や政策連携団体だけを対象とした補助金は除いています。</p>'
  $fieldRows = foreach ($f in $TokyoFieldSlug.Keys) {
    $fi = @($titems | Where-Object { $_.field -eq $f })
    if ($fi.Count -eq 0) { continue }
    $slug = $TokyoFieldSlug[$f]
    $byTarget = ($TokyoTargets | ForEach-Object { $tg = $_; $c = @($fi | Where-Object { $_.target -eq $tg }).Count; if ($c) { "$($tg) $($c)件" } }) -join '・'
    # 特定の団体（協会・公社・財団など）向けの補助金は後ろに回し、広く募集されていそうなものを先に表示する
    $sorted = @($fi | Sort-Object @{ Expression = { if (("$($_.summary)" -split "`n" | Where-Object { $_ -match '補助対象者' }) -match '協会|公社|財団|機構|センター|大学|研究所|基金|連合会|交付金') { 1 } else { 0 } } },
      @{ Expression = { $v = 0.0; [void][double]::TryParse(("$($_.budget)" -replace ',', ''), [ref]$v); $v }; Descending = $true })
    $body = "<h1>東京都の補助金制度：$(Esc $f)（$($fi.Count)件）</h1>$tokyoNote<p class=""lead"">対象者の内訳：$(Esc $byTarget)。特定の団体だけを対象とした補助金は後ろに並べています。</p><ul class=""titems"">" + (($sorted | ForEach-Object { Get-TokyoItem $_ }) -join '') + "</ul>$tAttr"
    Write-File (Join-Path $Dist "tokyo/$slug.html") (Get-Layout -Title "東京都の補助金制度一覧：$f（$($fi.Count)件）｜$SiteName" -Desc "東京都が予算に計上している「$f」分野の補助金 $($fi.Count) 件。対象者、概要、予算額、問い合わせ先、所管局のページへのリンクをまとめています。" -Body $body -Path "tokyo/$slug.html" -Depth 1 -Crumbs @(@('東京都の補助金制度', 'index.html', 'tokyo/index.html'), @($f, '', '')))
    [void]$sitemap.Add("tokyo/$slug.html")
    "<li><a href=""$slug.html""><span class=""t-name"">$(Esc $f)</span><span class=""t-desc"">$(Esc $byTarget)</span><span class=""t-count"">$($fi.Count)件</span></a></li>"
  }
  $residents = @($titems | Where-Object { $_.target -eq '一般都民' })
  $body = "<h1>東京都の補助金制度一覧（$($Tokyo.year)年度・$($tokyoCount)件）</h1><p class=""lead"">東京都が公開しているオープンデータから、事業者・団体・都民が対象となる補助金を分野別にまとめました。Ｊグランツに掲載されていない東京都独自の制度も確認できます。</p>$tokyoNote<section><h2>分野から探す</h2><ul class=""tiles"">$($fieldRows -join '')</ul></section>"
  if ($residents.Count -gt 0) { $body += "<section><h2>都民（個人）が対象の補助金（$($residents.Count)件）</h2><ul class=""titems"">" + (($residents | ForEach-Object { Get-TokyoItem $_ }) -join '') + '</ul></section>' }
  $body += "<section><h2>受付中の補助金も確認する</h2><p><a href=""../area/13.html"">東京都で受付中の補助金（Ｊグランツ掲載・締切つき）を見る ›</a></p></section>$tAttr"
  Write-File (Join-Path $Dist 'tokyo/index.html') (Get-Layout -Title "東京都の補助金制度一覧（$($Tokyo.year)年度・$($tokyoCount)件）｜分野別｜$SiteName" -Desc "東京都の補助金 $tokyoCount 件を分野別に一覧。中小企業支援、雇用、観光、環境、子育てなど。対象者、概要、予算額、問い合わせ先を掲載。" -Body $body -Path 'tokyo/index.html' -Depth 1 -Crumbs @(, @('東京都の補助金制度', '', '')))
  [void]$sitemap.Add('tokyo/index.html')
}

# ---------- 国の雇用関係助成金（厚生労働省） ----------
if ($Employment) {
  $toc = ($Employment.categories | ForEach-Object { "<li><a href=""#$($_.slug)"">$(Esc $_.name)</a></li>" }) -join ''
  $secs = ($Employment.categories | ForEach-Object {
      $lis = ($_.items | ForEach-Object { "<li class=""titem""><h3>$(Esc $_.name)</h3><p>$(Esc $_.desc)</p><a class=""btn-sub small"" href=""$(Esc $_.url)"" rel=""nofollow noopener"" target=""_blank"">厚生労働省のページで要件・支給額を確認する</a></li>" }) -join ''
      "<section id=""$($_.slug)""><h2>$(Esc $_.name)</h2><ul class=""titems"">$lis</ul></section>"
    }) -join ''
  $body = @"
<h1>国の雇用関係助成金（厚生労働省）の主な一覧</h1>
<p class="lead">従業員の雇用、待遇の改善、出産・育児との両立、人材育成などに取り組む事業主が利用できる、厚生労働省の主な助成金をまとめました。これらの多くはＪグランツではなく、都道府県労働局やハローワークで申請します。</p>
<section class="box summary"><h2>補助金との違い</h2><p>雇用関係の助成金は、一般に、要件を満たせば受給できるものが多いのが特徴です（予算の範囲内）。一方で、就業規則の整備や計画の届出など、取り組みの前に必要な手続きがあるコースも多いため、取り組みを始める前に要件を確認することが大切です。</p></section>
<nav class="box toc"><h2>目的から選ぶ</h2><ul>$toc</ul></nav>
$secs
<section class="box warn"><h2>ご注意ください</h2><ul><li>支給額や要件は年度ごとに改正されます。必ず厚生労働省の最新の支給要領・パンフレットをご確認ください。</li><li>厚生労働省は、助成金の申請代行や「無料査定」をうたう勧誘への注意を呼びかけています。</li></ul></section>
<p class="source">出典：厚生労働省「取組内容別雇用関係助成金一覧」をもとに$SiteName 運営者が要約して作成。確認日：$(Esc $Employment.checked)</p>
"@
  Write-File (Join-Path $Dist 'employment.html') (Get-Layout -Title "国の雇用関係助成金の一覧（キャリアアップ・両立支援・人材開発など）｜$SiteName" -Desc '厚生労働省の主な雇用関係助成金を目的別に一覧。キャリアアップ助成金、両立支援等助成金（出産・育児）、人材開発支援助成金、トライアル雇用助成金など。' -Body $body -Path 'employment.html' -Crumbs @(, @('国の雇用関係助成金', '', '')))
  [void]$sitemap.Add('employment.html')
}

# ---------- 妊娠・出産で使える国の制度（個人向けガイド） ----------
$childbirth = @"
<h1>妊娠・出産で使える国の制度まとめ</h1>
<p class="lead">妊娠から出産、育児休業までの間に利用できる、主な国の制度をまとめました。金額や条件は、加入している健康保険・雇用保険やお住まいの市区町村によって異なる場合があります。必ずリンク先の公式情報をご確認ください。</p>
<p class="note">確認日：2026年10月22日。当サイトは主に事業者向けの補助金情報サイトのため、このページでは国の代表的な制度だけを紹介しています。市区町村独自の助成は、お住まいの自治体の窓口・ホームページでご確認ください。</p>

<section><h2>妊娠中</h2>
<ul class="titems">
<li class="titem"><h3>妊婦のための支援給付</h3><p>妊娠届出の後の面談などとあわせて、市区町村から給付金が支給される制度です（妊娠届出時に5万円、妊娠後期以降にお子さんの数×5万円）。申請方法は市区町村によって異なります。</p><a class="btn-sub small" href="https://www.cfa.go.jp/policies/shussan-kosodate" rel="nofollow noopener" target="_blank">こども家庭庁のページ</a></li>
<li class="titem"><h3>妊婦健康診査の公費負担</h3><p>妊婦健診の費用は、市区町村が交付する受診票によって公費で助成されます。助成の回数や金額は市区町村によって異なります。</p></li>
</ul></section>

<section><h2>出産のとき</h2>
<ul class="titems">
<li class="titem"><h3>出産育児一時金</h3><p>健康保険に加入している方が出産したとき、子ども1人につき原則50万円が支給されます。医療機関に直接支払われる「直接支払制度」を使えば、窓口での負担を抑えられます。</p><p class="note">出産費用の自己負担をなくす新しい制度を定めた法律が2026年6月に公布されましたが、施行日は2026年10月22日時点で決まっていません。当面は出産育児一時金と併存する見込みと報じられています。</p><a class="btn-sub small" href="https://www.mhlw.go.jp/stf/seisakunitsuite/bunya/kenkou_iryou/iryouhoken/shussan/index.html" rel="nofollow noopener" target="_blank">厚生労働省のページ</a></li>
</ul></section>

<section><h2>産休・育休中</h2>
<ul class="titems">
<li class="titem"><h3>出産手当金（健康保険）</h3><p>会社員などが出産のために仕事を休み、給与が支払われないときに支給されます。出産日（予定日）以前42日（多胎の場合は98日）から出産の翌日以後56日までの期間が対象で、1日あたりの金額は標準報酬日額のおおむね3分の2です。国民健康保険には原則ありません。</p><a class="btn-sub small" href="https://www.kyoukaikenpo.or.jp/benefit/childbirth/001/index.html" rel="nofollow noopener" target="_blank">協会けんぽのページ</a></li>
<li class="titem"><h3>育児休業給付・出生後休業支援給付・育児時短就業給付（雇用保険）</h3><p>雇用保険に加入している方が育児休業を取ったときに支給されます。両親がともに一定期間育児休業を取った場合の上乗せ（出生後休業支援給付）や、2歳未満の子を育てるための時短勤務中の給付（育児時短就業給付）もあります。</p><a class="btn-sub small" href="https://www.mhlw.go.jp/stf/seisakunitsuite/bunya/0000135090_00001.html" rel="nofollow noopener" target="_blank">厚生労働省のページ</a></li>
<li class="titem"><h3>国民年金保険料の産前産後期間の免除</h3><p>国民年金の第1号被保険者（自営業の方など）は、出産予定日の前月から4か月間（多胎の場合は6か月間）の保険料が免除されます。届出が必要です。</p><a class="btn-sub small" href="https://www.nenkin.go.jp/service/kokunen/menjo/20180810.html" rel="nofollow noopener" target="_blank">日本年金機構のページ</a></li>
</ul></section>

<section class="box summary"><h2>事業者の方へ：従業員の出産・育児を支援すると使える助成金</h2><p>従業員の育児休業の取得や職場復帰、業務の代替体制づくりに取り組む中小企業は、厚生労働省の「両立支援等助成金」を利用できる場合があります。</p><p><a href="employment.html#family">仕事と出産・育児の両立を支援する助成金を見る ›</a></p></section>
"@
Write-File (Join-Path $Dist 'childbirth.html') (Get-Layout -Title "妊娠・出産で使える国の制度まとめ（出産育児一時金・出産手当金・育児休業給付など）｜$SiteName" -Desc '妊娠・出産・育休で使える国の主な制度（妊婦のための支援給付、出産育児一時金、出産手当金、育児休業給付、国民年金保険料の免除）を公式情報へのリンクつきでまとめました。' -Body $childbirth -Path 'childbirth.html' -Crumbs @(, @('妊娠・出産で使える国の制度', '', '')))
[void]$sitemap.Add('childbirth.html')

# ---------- 検索用データ ----------
$data = @($open | ForEach-Object {
    $o = [ordered]@{ id = $_.id; t = $_.title; a = (Split-Areas $_.area); m = $_.maxLimit; s = $_.start; e = $_.end; r = $_.rate; emp = $_.employees; p = (Get-PurposeLabels $_); ind = $_.industry }
    if (Test-New $_) { $o.n = 1 }
    $o
  })
Write-File (Join-Path $Dist 'data.json') (ConvertTo-JsonText $data)

# ---------- トップ ----------
$prefOptions = '<option>全国</option>'
foreach ($r in $Regions.Keys) { $prefOptions += "<optgroup label=""$(Esc $r)"">" + (($Regions[$r] | ForEach-Object { "<option>$(Esc $_)</option>" }) -join '') + '</optgroup>' }
$purposeOptions = ($Purposes.Keys | Where-Object { $purposeCount[$_] -gt 0 } | ForEach-Object { "<option>$(Esc $Purposes[$_][1])</option>" }) -join ''
$prefsWithItems = @($Prefectures | Where-Object { $_ -ne '全国' -and $prefCount[$_] -gt 0 }).Count
$initial = @($accepting | Select-Object -First 20)
$siteLd = ''
if ($SiteUrl) {
  $siteLd = ConvertTo-JsonText ([ordered]@{ '@context' = 'https://schema.org'; '@type' = 'WebSite'; name = $SiteName; url = "$SiteUrl/"; inLanguage = 'ja'
      potentialAction = [ordered]@{ '@type' = 'SearchAction'; target = "$SiteUrl/index.html?q={search_term_string}"; 'query-input' = 'required name=search_term_string' } })
}
$body = @"
<section class="hero">
  <h1>受付中の補助金・助成金を、<br class="sp">締切が近い順に探せます</h1>
  <p>国や自治体の補助金電子申請システム「Ｊグランツ」に掲載されている補助金を毎朝自動で取得し、地域・目的・金額・締切で探しやすく整理しています。</p>
  <ul class="stats">
    <li><span class="s-num">$($open.Count)</span><span class="s-label">掲載中の補助金</span></li>
    <li><span class="s-num">$($soon7.Count)</span><span class="s-label">7日以内に締切</span></li>
    <li><span class="s-num">$($newOnes.Count)</span><span class="s-label">新着</span></li>
    <li><span class="s-num">$prefsWithItems</span><span class="s-label">対象の都道府県</span></li>
  </ul>
</section>

<section class="diag-cta">
  <div><p class="dc-title">どの補助金が使えるかわからない方へ</p><p>事業所の場所・従業員数・やりたいことを選ぶだけで、使えそうな補助金がわかります（無料・登録不要）。</p></div>
  <a class="btn" href="shindan.html">補助金診断をはじめる</a>
</section>

<section>
  <div class="sec-head"><h2>主要な補助金の受付状況</h2><a href="major/index.html">主要な補助金の解説を見る ›</a></div>
  <ul class="tiles">$($majorCards -replace 'href="', 'href="major/')</ul>
</section>

<section id="search" class="search-box">
  <h2>条件で絞り込む</h2>
  <form id="filters" class="filters" onsubmit="return false">
    <label class="f-q"><span>キーワード</span><input id="q" type="search" placeholder="例：省エネ、IT導入、創業、賃上げ"></label>
    <label><span>地域</span><select id="pref"><option value="">すべての地域</option>$prefOptions</select></label>
    <label><span>目的</span><select id="purpose"><option value="">すべての目的</option>$purposeOptions</select></label>
    <label><span>上限額</span><select id="min"><option value="0">指定しない</option><option value="1000000">100万円以上</option><option value="5000000">500万円以上</option><option value="10000000">1,000万円以上</option></select></label>
    <label class="chk"><input id="nat" type="checkbox" checked> 地域を選んだとき、全国対象の補助金も含める</label>
  </form>
  <p id="count" class="count">受付中の補助金を締切が近い順に表示しています</p>
  <ul id="results" class="cards">
$(($initial | ForEach-Object { Get-Card $_ '' }) -join '')
  </ul>
  <p class="more"><button id="more" type="button" class="btn-sub" hidden>さらに表示する</button></p>
</section>

<section>
  <div class="sec-head"><h2>目的から探す</h2><a href="purpose/index.html">すべての目的を見る ›</a></div>
  $(Get-PurposeTiles 'purpose/')
</section>

<section>
  <div class="sec-head"><h2>地域から探す</h2><a href="area/index.html">地域の一覧を見る ›</a></div>
  $(Get-PrefGrid 'area/')
</section>

<section>
  <h2>Ｊグランツ以外の制度も探す</h2>
  <ul class="tiles">
    <li><a href="employment.html"><span class="t-name">国の雇用関係助成金</span><span class="t-desc">キャリアアップ助成金、両立支援等助成金、人材開発支援助成金など（厚生労働省）</span><span class="t-count">目的別</span></a></li>
    <li><a href="tokyo/index.html"><span class="t-name">東京都の補助金制度一覧</span><span class="t-desc">東京都のオープンデータから、事業者・団体・都民向けの補助金を分野別に掲載</span><span class="t-count">$($tokyoCount)件</span></a></li>
    <li><a href="childbirth.html"><span class="t-name">妊娠・出産で使える国の制度</span><span class="t-desc">出産育児一時金、出産手当金、育児休業給付など（個人向け）</span><span class="t-count">ガイド</span></a></li>
  </ul>
</section>

<section>
  <div class="sec-head"><h2>新着の補助金</h2><a href="new.html">新着をすべて見る ›</a></div>
  $(Get-CardList ($newOnes | Select-Object -First 6) '' '新着の補助金は現在ありません。')
</section>

<section class="box steps">
  <h2>はじめての方へ：補助金申請の流れ</h2>
  <ol>
    <li><strong>探す</strong><span>地域・目的・締切から、使えそうな補助金を探します。</span></li>
    <li><strong>公募要領を読む</strong><span>対象者、対象経費、補助率、締切を公式の資料で確認します。</span></li>
    <li><strong>準備して申請する</strong><span>GビズIDプライムを取得し、事業計画などを作成してＪグランツから申請します。</span></li>
  </ol>
  <p><a href="guide.html">探し方と申請の流れを詳しく見る ›</a></p>
</section>

<section class="box about-mini">
  <h2>このサイトについて</h2>
  <p>$SiteName は、デジタル庁が公開している「Ｊグランツ」のAPIから補助金の情報を毎朝自動で取得し、整理して掲載している民間の情報サイトです。掲載している補助金は、Ｊグランツで電子申請を受け付けているものが中心で、自治体が独自に募集している補助金の多くは含まれません。</p>
  <p><a href="about.html">運営者情報・運営方針を見る ›</a></p>
</section>
<script src="assets/app.js" defer></script>
"@
Write-File (Join-Path $Dist 'index.html') (Get-Layout -Title "$SiteName｜受付中の補助金・助成金を締切順に検索（毎日更新）" -Desc "受付中の補助金・助成金 $($open.Count) 件を地域・目的・上限額・締切で検索できます。Ｊグランツの掲載情報を毎朝自動更新。設備投資、IT導入、創業、省エネ、雇用などの補助金を探せます。" -Body $body -Path '' -JsonLd $siteLd)
[void]$sitemap.Insert(0, '')

# ---------- 固定ページ ----------
$guide = @"
<h1>はじめての方へ：補助金の探し方と申請の流れ</h1>
<p class="lead">補助金を初めて利用する方向けに、探し方と、Ｊグランツで申請する場合の一般的な流れをまとめました。実際の手続きは補助金ごとに異なるため、必ず公式の公募要領をご確認ください。</p>

<section><h2>補助金と助成金の違い</h2>
<p>どちらも国や自治体から支給され、原則として返済の必要がないお金です。一般的に、<strong>補助金</strong>は予算や採択件数に上限があり、申請内容の審査を経て採択されたものだけが受け取れます。<strong>助成金</strong>（雇用関係のものなど）は、要件を満たせば受け取れるものが多いとされています。ただし、名称だけで区別できない場合もあるため、個別の要件を確認してください。</p></section>

<section><h2>補助金の探し方</h2>
<ol class="numbered">
  <li><strong>地域で絞る</strong>：事業所がある都道府県の補助金と、全国対象の補助金を確認します。<a href="area/index.html">地域から探す</a></li>
  <li><strong>目的で絞る</strong>：設備投資、IT導入、販路拡大など、使いたい目的から探します。<a href="purpose/index.html">目的から探す</a></li>
  <li><strong>締切を確認する</strong>：準備には時間がかかるため、締切まで余裕があるものを優先して検討します。<a href="deadline.html">締切間近の補助金</a></li>
</ol></section>

<section><h2>Ｊグランツで申請する場合の一般的な流れ</h2>
<ol class="numbered">
  <li><strong>GビズIDプライムを取得する</strong>：Ｊグランツへのログインに必要な法人・個人事業主向けのアカウントです。取得までに日数がかかる場合があるため、早めに準備しましょう。</li>
  <li><strong>公募要領を確認する</strong>：対象者、対象経費、補助率、上限額、必要書類、締切を確認します。</li>
  <li><strong>事業計画などを作成する</strong>：補助金で何を行い、どのような効果が見込めるかをまとめます。</li>
  <li><strong>Ｊグランツから電子申請する</strong>：締切の日時までに申請します。</li>
  <li><strong>審査・採択（交付決定）</strong>：採択されたら、交付決定の内容に沿って事業を実施します。</li>
  <li><strong>実績報告・補助金の受け取り</strong>：事業の完了後に実績を報告し、確定した金額が支払われます。多くの補助金は<strong>後払い</strong>のため、いったん自己資金などで支払う必要があります。</li>
</ol></section>

<section class="box warn"><h2>ご注意ください</h2>
<ul>
  <li>多くの補助金では、交付決定の前に発注・契約した経費は対象になりません。</li>
  <li>虚偽の申請や不正受給には、返還や加算金、刑事罰などの厳しい処分があります。</li>
  <li>「必ず採択される」「手数料を払えば受け取れる」などと勧誘する業者にはご注意ください。当サイトが申請代行や手数料を求めることはありません。</li>
</ul></section>
"@
Write-File (Join-Path $Dist 'guide.html') (Get-Layout -Title "はじめての方へ：補助金の探し方とＪグランツ申請の流れ｜$SiteName" -Desc '補助金と助成金の違い、補助金の探し方、Ｊグランツで申請する場合の一般的な流れ（GビズID、公募要領、交付決定、実績報告）と注意点をまとめています。' -Body $guide -Path 'guide.html' -Crumbs @(, @('はじめての方へ', '', '')))
[void]$sitemap.Add('guide.html')

$faqs = @(
  @('このサイトは公式のサイトですか？', 'いいえ。当サイトは、デジタル庁が公開しているＪグランツのAPIから補助金の情報を取得して整理している民間の情報サイトです。国・自治体・デジタル庁とは関係ありません。'),
  @('このサイトから補助金に申請できますか？', 'いいえ。申請は各補助金の公式窓口（多くはＪグランツ）で行ってください。当サイトは申請の受付や代行を行っておらず、手数料や個人情報を求めることもありません。'),
  @('情報はいつ更新されますか？', '毎朝5時30分ごろに自動で更新しています。各ページの上部に最終更新日時を表示しています。'),
  @('すべての補助金が載っていますか？', 'いいえ。Ｊグランツに掲載されている補助金が対象です。自治体が独自に募集している補助金など、Ｊグランツに掲載されていない制度は含まれません。'),
  @('掲載内容が公式の情報と違う場合は？', '公式の公募要領の内容が優先されます。自動で取得・整形しているため、誤りや反映の遅れがある場合があります。お気づきの点は、ページ下部の「掲載内容の誤りを報告する」からお知らせください。'),
  @('個人でも使える補助金はありますか？', '当サイトに掲載しているのは、主に事業者（法人・個人事業主）向けの補助金です。個人向けの補助金（住宅、自動車など）は、お住まいの自治体の情報をご確認ください。'),
  @('GビズIDとは何ですか？', '法人や個人事業主が、1つのIDで複数の行政サービスにログインできるアカウントです。Ｊグランツでの申請には「GビズIDプライム」が必要です。'),
  @('補助金はいつ受け取れますか？', '多くの補助金は、事業を実施して実績を報告した後に支払われる後払いです。具体的な時期は補助金ごとに異なります。')
)
$faqHtml = '<h1>よくある質問</h1>' + (($faqs | ForEach-Object { "<section class=""faq""><h2>$(Esc $_[0])</h2><p>$(Esc $_[1])</p></section>" }) -join '')
$faqLd = ConvertTo-JsonText ([ordered]@{ '@context' = 'https://schema.org'; '@type' = 'FAQPage'; mainEntity = @($faqs | ForEach-Object { [ordered]@{ '@type' = 'Question'; name = $_[0]; acceptedAnswer = [ordered]@{ '@type' = 'Answer'; text = $_[1] } } }) })
Write-File (Join-Path $Dist 'faq.html') (Get-Layout -Title "よくある質問｜$SiteName" -Desc '補助金ウォッチの使い方、情報の更新頻度、掲載範囲、申請方法などについてのよくある質問。' -Body $faqHtml -Path 'faq.html' -Crumbs @(, @('よくある質問', '', '')) -JsonLd $faqLd)
[void]$sitemap.Add('faq.html')

$contact = ''
if ($ContactEmail) { $contact = "<tr><th scope=""row"">お問い合わせ</th><td><a href=""mailto:$(Esc $ContactEmail)"">$(Esc $ContactEmail)</a></td></tr>" }
$about = @"
<h1>運営者情報・運営方針</h1>
<section><h2>運営者情報</h2>
<table class="facts">
<tr><th scope="row">サイト名</th><td>$SiteName</td></tr>
<tr><th scope="row">運営</th><td>$SiteName 運営者（個人運営）</td></tr>
<tr><th scope="row">開設</th><td>2026年10月</td></tr>
<tr><th scope="row">掲載内容の誤りの報告</th><td><a href="$(Esc $ReportUrl)" rel="nofollow noopener" target="_blank">報告窓口（GitHub）</a></td></tr>
$contact
</table></section>

<section><h2>このサイトの目的</h2>
<p>補助金の情報は、省庁や自治体ごとに分かれていて探しにくいという課題があります。$SiteName は、Ｊグランツに掲載されている補助金を締切・地域・目的で横断的に探せるようにし、事業者の方が使える制度を見落とさないようにすることを目的としています。</p></section>

<section><h2>運営方針</h2>
<ul>
  <li><strong>データの取得方法</strong>：デジタル庁が公開している「Ｊグランツ」のAPIから、受付中の補助金の情報を毎朝自動で取得しています。</li>
  <li><strong>掲載内容</strong>：取得した情報をプログラムで整形し、地域・目的・締切ごとに整理して掲載しています。各ページの「要点」は、取得したデータをもとに自動で作成しています。</li>
  <li><strong>正確性</strong>：公式の公募要領の内容が常に優先されます。誤りに気づいた場合や報告を受けた場合は、確認のうえ速やかに修正します。</li>
  <li><strong>中立性</strong>：特定の補助金や事業者を有利に扱うことはありません。今後、広告や紹介リンクを掲載する場合は、広告であることを明示します。</li>
  <li><strong>申請について</strong>：当サイトは申請の受付・代行を行っておらず、手数料や個人情報を求めることはありません。</li>
</ul></section>

<section><h2>出典と利用条件</h2>
<p>出典：「Ｊグランツ」（https://www.jgrants-portal.go.jp）をもとに$SiteName 運営者が編集・加工して作成しています。掲載内容はＪグランツ利用規約（政府標準利用規約に準拠）に従って利用しています。</p></section>

<section><h2>免責事項</h2>
<p>掲載情報は自動で取得・整形しているため、誤り、遅れ、欠落が含まれる場合があります。補助金の要件・締切・金額は、必ず公式の公募要領でご確認ください。本サイトの情報を利用したことによって生じた損害について、運営者は責任を負いません。</p></section>
"@
Write-File (Join-Path $Dist 'about.html') (Get-Layout -Title "運営者情報・運営方針｜$SiteName" -Desc "$SiteName の運営者情報、運営方針、データの取得方法、出典、免責事項。" -Body $about -Path 'about.html' -Crumbs @(, @('運営者情報・運営方針', '', '')))
[void]$sitemap.Add('about.html')

$analyticsPolicy = '<section><h2>アクセス解析について</h2><p>現在、アクセス解析ツールは利用していません。</p></section>'
if ($CfToken) {
  $analyticsPolicy = '<section><h2>アクセス解析について</h2><p>本サイトは、サイトの改善のためにCloudflare社のアクセス解析サービス「Cloudflare Web Analytics」を利用しています。このサービスはCookieを使用せず、閲覧したページ、参照元、国・地域、ブラウザや端末の種類などの情報を、個人を特定しない形で集計します。詳しくは<a href="https://www.cloudflare.com/ja-jp/privacypolicy/" rel="nofollow noopener" target="_blank">Cloudflare社のプライバシーポリシー</a>をご確認ください。</p></section>'
}
$privacy = @"
<h1>プライバシーポリシー</h1>
<section><h2>個人情報の取得について</h2><p>本サイトは現在、氏名・メールアドレスなどの個人情報を取得していません。お問い合わせフォームや会員登録の機能もありません。</p></section>
<section><h2>広告・メール配信について</h2><p>現在、広告配信サービスやメールでの情報配信は利用していません。今後これらを始める場合は、取得する情報、利用目的、第三者提供の有無を本ページに掲載したうえで開始します。</p></section>
<section><h2>外部サービスについて</h2><p>本サイトは、表示のためにGoogle Fontsを利用しています。また、ホスティングにGitHub Pagesを利用しています。これらのサービスの提供元には、ページを表示する際に通常のアクセス情報（IPアドレスなど）が送信されます。</p></section>
$analyticsPolicy
<p>制定：2026年10月21日／改定：2026年10月22日</p>
"@
Write-File (Join-Path $Dist 'privacy.html') (Get-Layout -Title "プライバシーポリシー｜$SiteName" -Desc "$SiteName のプライバシーポリシー。" -Body $privacy -Path 'privacy.html' -Crumbs @(, @('プライバシーポリシー', '', '')))

# ---------- sitemap / robots / 404 ----------
if ($SiteUrl) {
  $lastmod = $Now.ToString('yyyy-MM-dd')
  $urls = ($sitemap | ForEach-Object { "<url><loc>$SiteUrl/$_</loc><lastmod>$lastmod</lastmod></url>" }) -join "`n"
  Write-File (Join-Path $Dist 'sitemap.xml') "<?xml version=""1.0"" encoding=""UTF-8""?>`n<urlset xmlns=""http://www.sitemaps.org/schemas/sitemap/0.9"">`n$urls`n</urlset>`n"
  # robots.txt はドメインの最上位に置いたときだけ検索エンジンに読まれる（独自ドメインで公開している場合のみ出力）
  if ($BasePath -eq '/') { Write-File (Join-Path $Dist 'robots.txt') "User-agent: *`nAllow: /`n`nSitemap: $SiteUrl/sitemap.xml`n" }
}
$notFound = '<h1>ページが見つかりません</h1><p>お探しのページは移動または削除された可能性があります。受付が終了した補助金のページは、一定期間が過ぎると削除されます。</p><p><a class="btn" href="index.html">トップページから補助金を探す</a></p>'
Write-File (Join-Path $Dist '404.html') (Get-Layout -Title "ページが見つかりません｜$SiteName" -Desc '' -Body $notFound -Path '404.html' -NoIndex -Is404)
Write-File (Join-Path $Dist '.nojekyll') ''

Write-Host "built: $($all.Count) detail pages, $($open.Count) open, $($soon.Count) closing soon, $($newOnes.Count) new, $($sitemap.Count) sitemap urls -> $Dist"
