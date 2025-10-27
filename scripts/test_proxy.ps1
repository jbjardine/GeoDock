Param(
  [string]$HostOrIp,
  [string]$RemoteBase = 'https://api-adresse.data.gouv.fr',
  [int]$Runs = 5,
  [int]$RemoteRuns = 3,
  [switch]$Insecure,
  [switch]$UseHttpsLocal,
  [switch]$UseCapabilities,
  [string]$CapabilitiesUrl = 'https://api-adresse.data.gouv.fr/getCapabilities',
  [int]$MaxAutoTests = 20,
  [switch]$Exhaustive,
  [int]$MaxEnum = 5,
  [int]$TopN = 3,
  [switch]$IncludeOptions,
  [switch]$StopOnFail,
  [switch]$Strict
)
$ErrorActionPreference = 'Stop'

# Force TLS 1.2 for Invoke-WebRequest on older Windows
try { [System.Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

function Read-Host-IfEmpty($prompt, $value){ if ([string]::IsNullOrWhiteSpace($value)) { return Read-Host $prompt } else { return $value } }

$HostOrIp = Read-Host-IfEmpty 'Server (IP or hostname)' $HostOrIp
if (-not $HostOrIp) { Write-Error 'No host provided'; exit 1 }

# Strict mode compares all features (no truncation)
if ($Strict) { $TopN = 0 }

# Bases
$httpBase  = if ($HostOrIp -match '^https?://') { $HostOrIp -replace '^https?://','http://' } else { "http://$HostOrIp" }
$httpsBase = if ($HostOrIp -match '^https?://') { $HostOrIp -replace '^https?://','https://' } else { "https://$HostOrIp" }
$localBase = if ($UseHttpsLocal) { $httpsBase } else { $httpBase }

# Option: ignore self-signed certificate for Invoke-WebRequest (PS5 compat)
$restoreCallback = $null
if ($Insecure -and -not (Get-Command Invoke-WebRequest).Parameters.ContainsKey('SkipCertificateCheck')) {
  $restoreCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
  [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}

function Invoke-Json($url){
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $common = @{ Uri = $url; Method = 'GET'; Headers = @{ 'User-Agent' = 'geodock-test' }; TimeoutSec = 10 }
    if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey('SkipCertificateCheck')) { $common['SkipCertificateCheck'] = [bool]$Insecure }
    $resp = Invoke-WebRequest @common
    $sw.Stop()
    $obj = $null
    try { $obj = $resp.Content | ConvertFrom-Json -ErrorAction Stop } catch {}
    return [pscustomobject]@{ Ok = $true; Ms = [int]$sw.Elapsed.TotalMilliseconds; Status = $resp.StatusCode; Headers = $resp.Headers; Json = $obj; Raw = $resp.Content }
  } catch {
    $sw.Stop()
    return [pscustomobject]@{ Ok = $false; Ms = [int]$sw.Elapsed.TotalMilliseconds; Error = $_.Exception.Message }
  }
}

function Invoke-JsonHttp($url){
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $skip = ($Insecure -and $url.StartsWith('https://'))
    $handler = New-Object System.Net.Http.HttpClientHandler
    if ($skip) {
      $cb = [System.Net.Http.HttpClientHandler]::DangerousAcceptAnyServerCertificateValidator
      $handler.ServerCertificateCustomValidationCallback = $cb
    }
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(10)
    $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $url)
    $req.Headers.TryAddWithoutValidation('User-Agent','geodock-test') | Out-Null
    $null = $req.Headers.Accept.Add([System.Net.Http.Headers.MediaTypeWithQualityHeaderValue]::new('application/json'))
    $resp = $client.SendAsync($req).GetAwaiter().GetResult()
    $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $sw.Stop()
    $obj = $null
    try { $obj = $text | ConvertFrom-Json -ErrorAction Stop } catch {}
    $ok = ($obj -ne $null)
    return [pscustomobject]@{ Ok = $ok; Ms = [int]$sw.Elapsed.TotalMilliseconds; Status = [int]$resp.StatusCode; Headers = @{}; Json = $obj; Raw = $text; Error = if ($ok) { $null } else { 'invalid json' } }
  } catch {
    $sw.Stop()
    return [pscustomobject]@{ Ok = $false; Ms = [int]$sw.Elapsed.TotalMilliseconds; Error = $_.Exception.Message }
  }
}

function Invoke-JsonCurl($url){
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $tmp = [System.IO.Path]::GetTempFileName()
    $args = @('-sS','--connect-timeout','5','--max-time','10','-H','Accept: application/json','-o', $tmp)
    if ($Insecure) { $args += '-k' }
    $args += $url
    & curl.exe @args | Out-Null
    $sw.Stop()
    $bytes = [System.IO.File]::ReadAllBytes($tmp)
    $raw = [System.Text.Encoding]::UTF8.GetString($bytes)
    Remove-Item -Force $tmp -ErrorAction SilentlyContinue
    $obj = $null
    try { $obj = $raw | ConvertFrom-Json -ErrorAction Stop } catch {}
    $ok = ($null -ne $obj)
    return [pscustomobject]@{ Ok = $ok; Ms = [int]$sw.Elapsed.TotalMilliseconds; Status = if ($ok) { 200 } else { $null }; Headers = @{}; Json = $obj; Raw = $raw; Error = if ($ok) { $null } else { 'curl: invalid JSON or empty' } }
  } catch {
    $sw.Stop()
    return [pscustomobject]@{ Ok = $false; Ms = [int]$sw.Elapsed.TotalMilliseconds; Error = $_.Exception.Message }
  }
}

function Invoke-JsonRobust($url){
  $r = Invoke-JsonHttp $url
  if ($r.Ok) { return $r }
  $r2 = Invoke-Json $url
  if ($r2.Ok) { return $r2 }
  $r3 = Invoke-JsonCurl $url
  if ($r3.Ok) { return $r3 } else { return $r }
}

function Fetch-Capabilities($url){
  try {
    $r = Invoke-JsonRobust $url
    if ($r.Ok -and $r.Json) { return $r.Json }
  } catch {}
  return $null
}

function Escape-Val($v){
  try { return [System.Uri]::EscapeDataString([string]$v) } catch { return [string]$v }
}

function Build-Query($map){
  $parts = @()
  foreach ($k in $map.Keys) { $parts += ("{0}={1}" -f $k, (Escape-Val $map[$k])) }
  return ($parts -join '&')
}

function Tests-FromCapabilities($cap){
  $out = @()
  if ($null -eq $cap) { return $out }
  $ops = $cap.operations
  if ($null -eq $ops) { return $out }
  $add = {
    param([hashtable]$item)
    if ($out.Count -lt $MaxAutoTests) { $script:out += ,$item }
  }
  foreach ($op in $ops) {
    $id = $op.id; $url = $op.url
    if ($id -eq 'search') {
      $ex = @{}
      foreach ($p in $op.parameters) { if ($p.schema -and $p.schema.example) { $ex[$p.name] = $p.schema.example } }
      # Test 1: q + limit=1
      $q1 = @{}
      $q1['q'] = ($ex['q'] | ForEach-Object { $_ })
      if (-not $q1['q']) { $q1['q'] = '8 bd du port, nanterre' }
      $q1['limit'] = 1
      & $add @{ path = '/search/'; params = (Build-Query $q1) }
      # Test 2: q + limit=5
      $q2 = @{}
      $q2['q'] = ($ex['q'] | ForEach-Object { $_ })
      if (-not $q2['q']) { $q2['q'] = 'rue de rivoli paris' }
      $q2['limit'] = 5
      & $add @{ path = '/search/'; params = (Build-Query $q2) }
      # Test 3: bias lat/lon if provided
      $lat = $ex['lat']; $lon = $ex['lon']
      if ($lat -and $lon) {
        $q3 = @{}
        $q3['q'] = 'lyon'
        $q3['limit'] = 10
        $q3['lat'] = $lat; $q3['lon'] = $lon
        & $add @{ path = '/search/'; params = (Build-Query $q3) }
      }
      # Index variations (address, poi, parcel)
      $indexParam = ($op.parameters | Where-Object { $_.name -eq 'index' })
      $indexEnums = @()
      if ($indexParam -and $indexParam.schema -and $indexParam.schema.enum) { $indexEnums = $indexParam.schema.enum }
      if ($indexEnums.Count -eq 0 -and $Exhaustive) { $indexEnums = @('address','poi','parcel') }
      foreach ($ix in $indexEnums) {
        & $add @{ path = '/search/'; params = (Build-Query @{ q = 'paris'; limit = 3; index = $ix }) }
      }
      # Type filter variations (for address)
      $typeParam = ($op.parameters | Where-Object { $_.name -eq 'type' })
      $typeEnums = @()
      if ($typeParam -and $typeParam.schema -and $typeParam.schema.enum) { $typeEnums = $typeParam.schema.enum }
      if ($typeEnums.Count -eq 0 -and $Exhaustive) { $typeEnums = @('housenumber','street','locality','municipality') }
      foreach ($tp in ($typeEnums | Select-Object -First $MaxEnum)) {
        & $add @{ path = '/search/'; params = (Build-Query @{ q = 'paris'; limit = 3; type = $tp }) }
      }
      # Autocomplete modes
      & $add @{ path = '/search/'; params = (Build-Query @{ q = 'aven'; limit = 5; autocomplete = 'true' }) }
      & $add @{ path = '/search/'; params = (Build-Query @{ q = 'aven'; limit = 5; autocomplete = 'false' }) }
      # returntruegeometry
      & $add @{ path = '/search/'; params = (Build-Query @{ q = 'rue de la paix'; limit = 1; returntruegeometry = 'true' }) }
      # Simple filters if examples exist
      if ($ex['postcode']) { & $add @{ path = '/search/'; params = (Build-Query @{ q = 'paris'; postcode = $ex['postcode']; limit = 5 }) } } elseif ($Exhaustive) { & $add @{ path = '/search/'; params = (Build-Query @{ q='paris'; postcode='75004'; limit=5 }) } }
      if ($ex['citycode']) { & $add @{ path = '/search/'; params = (Build-Query @{ q = 'paris'; citycode = $ex['citycode']; limit = 5 }) } } elseif ($Exhaustive) { & $add @{ path = '/search/'; params = (Build-Query @{ q='paris'; citycode='75056'; limit=5 }) } }
      if ($ex['city'])     { & $add @{ path = '/search/'; params = (Build-Query @{ q = $ex['city']; limit = 5 }) } } elseif ($Exhaustive) { & $add @{ path = '/search/'; params = (Build-Query @{ q='paris'; limit=5 }) } }
      # Parcel index combined filters if provided
      $parcelKeys = @('departmentcode','municipalitycode','oldmunicipalitycode','districtcode','section','number','sheet')
      $hasAnyParcel = $false
      foreach ($k in $parcelKeys) { if ($ex[$k]) { $hasAnyParcel = $true } }
      if ($hasAnyParcel) {
        $pq = @{}
        $pq['index'] = 'parcel'; $pq['limit'] = 3
        foreach ($k in $parcelKeys) { if ($ex[$k]) { $pq[$k] = $ex[$k] } }
        & $add @{ path = '/search/'; params = (Build-Query $pq) }
      }
    } elseif ($id -eq 'reverse') {
      # Prefer lat/lon if present in schema examples (BAN reverse)
      $ex = @{}
      foreach ($p in $op.parameters) { if ($p.schema -and $p.schema.example) { $ex[$p.name] = $p.schema.example } }
      $lat = $ex['lat']; $lon = $ex['lon']
      if (-not $lat -or -not $lon) { $lat = '48.8566'; $lon = '2.3522' }
      $rv1 = @{}; $rv1['lat'] = $lat; $rv1['lon'] = $lon
      & $add @{ path = '/reverse/'; params = (Build-Query $rv1) }
      # Additional reverse points
      & $add @{ path = '/reverse/'; params = 'lat=43.2965&lon=5.3698' }
      & $add @{ path = '/reverse/'; params = 'lat=43.6045&lon=1.4442' }
      # Index variations for reverse if enums provided
      $indexParam = ($op.parameters | Where-Object { $_.name -eq 'index' })
      $indexEnums = @()
      if ($indexParam -and $indexParam.schema -and $indexParam.schema.enum) { $indexEnums = $indexParam.schema.enum }
      foreach ($ix in $indexEnums) { & $add @{ path = '/reverse/'; params = (Build-Query @{ lat = $lat; lon = $lon; index = $ix }) } }
      # searchgeom example
      if ($ex['searchgeom']) { & $add @{ path = '/reverse/'; params = (Build-Query @{ searchgeom = $ex['searchgeom']; limit = 5 }) } }
    }
  }
  return $out
}

function Order-Json($obj){
  if ($null -eq $obj) { return $null }
  if ($obj -is [System.Collections.IEnumerable] -and $obj.GetType().Name -eq 'Object[]') {
    $arr = @()
    foreach ($e in $obj) { $arr += ,(Order-Json $e) }
    return ,$arr
  }
  # Handle PSCustomObject/hashtables by sorting keys for stable order
  $t = $obj.GetType().FullName
  if ($obj -is [hashtable]) {
    $ord = [ordered]@{}
    foreach ($k in ($obj.Keys | Sort-Object)) { $ord[$k] = Order-Json $obj[$k] }
    return $ord
  }
  if ($t -eq 'System.Management.Automation.PSCustomObject') {
    $ord = [ordered]@{}
    $names = $obj.PSObject.Properties.Name | Sort-Object
    foreach ($n in $names) { $ord[$n] = Order-Json ($obj.$n) }
    return $ord
  }
  return $obj
}

function Get-JsonHash($jsonObj){
  try {
    $ordered = Order-Json $jsonObj
    $s = $ordered | ConvertTo-Json -Depth 64 -Compress
  } catch {
    try { $s = ($jsonObj | ConvertTo-Json -Depth 64 -Compress) } catch { $s = '' }
  }
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($s)
  $hash = $sha.ComputeHash($bytes)
  ($hash | ForEach-Object { $_.ToString('x2') }) -join ''
}

function Round-Val($v, $digits){
  try { return [Math]::Round([double]$v, $digits) } catch { return $v }
}

function Project-Feature($f){
  if ($null -eq $f) { return $null }
  $p = $f.properties
  $g = $f.geometry
  $lon = $null; $lat = $null
  try { $lon = Round-Val $g.coordinates[0] 5; $lat = Round-Val $g.coordinates[1] 5 } catch {}
  $out = [ordered]@{}
  $out.id       = try { $p.id } catch { $null }
  $out.label    = try { $p.label } catch { $null }
  $out.type     = try { $p.type } catch { $null }
  $out.city     = try { $p.city } catch { $null }
  $out.postcode = try { $p.postcode } catch { $null }
  $out.geotype  = try { $g.type } catch { $null }
  $out.lon      = $lon
  $out.lat      = $lat
  return $out
}

function Project-Json($obj){
  if ($null -eq $obj) { return $null }
  if ($obj.PSObject.Properties.Name -contains 'type' -and $obj.type -eq 'FeatureCollection') {
    $pf = @()
    try {
      foreach ($f in $obj.features) { $pf += ,(Project-Feature $f) }
      $pf = $pf | Sort-Object id, label
      if ($TopN -gt 0 -and $pf.Count -gt $TopN) { $pf = $pf | Select-Object -First $TopN }
      return [pscustomobject]@{ type = 'FeatureCollection'; features = $pf }
    } catch { return $obj }
  }
  return $obj
}

function Get-ProjectedHash($jsonObj){
  $proj = Project-Json $jsonObj
  Get-JsonHash $proj
}

# Defaults for all-in-one mode: use capabilities, strict compare, include OPTIONS by default
if (-not $PSBoundParameters.ContainsKey('UseCapabilities')) { $UseCapabilities = $true }
if (-not $PSBoundParameters.ContainsKey('Strict')) { $Strict = $true; $TopN = 0 }
if (-not $PSBoundParameters.ContainsKey('IncludeOptions')) { $IncludeOptions = $true }

# Simple OPTIONS tester
function Test-Options($base, $path){
  try {
    $url = "$base$path"
    $args = @('-s','-o','NUL','-w','%{http_code}','-X','OPTIONS')
    if ($Insecure -and $url.StartsWith('https://')) { $args += '-k' }
    $args += $url
    $code = & curl.exe @args
    $code = [int]$code
    return [pscustomobject]@{ Ok = $true; Status = $code }
  } catch { return [pscustomobject]@{ Ok = $false; Error = $_.Exception.Message } }
}

# CSV POST tester
function Post-Csv($base, $relPath, $qs, $csvText){
  $url = if ($qs) { "$base$relPath`?$qs" } else { "$base$relPath" }
  return Post-CsvCurl $url $csvText $Insecure
}

function Post-CsvCurl($url, $csvText, $insec){
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    # Write UTF-8 without BOM to avoid BOM-prefixed header names (eg. \uFEFFq)
    $inFile = [System.IO.Path]::GetTempFileName()
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($inFile, $csvText, $utf8NoBom)

    $outFile = [System.IO.Path]::GetTempFileName()
    $args = @('-sS','--connect-timeout','5','--max-time','20','-H','Accept: text/csv','-H','Expect:','-F',('data=@'+$inFile+';type=text/csv'),'-o',"$outFile",'-w','%{http_code}')
    if ($insec -and $url.StartsWith('https://')) { $args += '-k' }
    $args += $url
    $code = & curl.exe @args
    $sw.Stop()
    $bytes = [System.IO.File]::ReadAllBytes($outFile)
    Remove-Item -Force $inFile,$outFile -ErrorAction SilentlyContinue
    $ok = ($bytes.Length -gt 0 -and [int]$code -ge 200 -and [int]$code -lt 300)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = if ($bytes.Length -gt 0) { ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '' } else { '' }
    return [pscustomobject]@{ Ok = $ok; Ms = [int]$sw.Elapsed.TotalMilliseconds; Status = [int]$code; Bytes = $bytes; Hash = $hash }
  } catch {
    $sw.Stop(); return [pscustomobject]@{ Ok = $false; Ms = [int]$sw.Elapsed.TotalMilliseconds; Error = $_.Exception.Message }
  }
}

# Parse CSV bytes and return @(rows,totalSuccess)
function CsvCounts($bytes){
  try {
    if ($bytes.Length -eq 0) { return @(0,0) }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    # Normalize line endings and count non-empty lines
    $lines = [Regex]::Split($text, "\r?\n") | Where-Object { $_ -and $_.Trim().Length -gt 0 }
    $rowCount = [Math]::Max(0, $lines.Length - 1)
    return @($rowCount, $rowCount)
  } catch { return @(0,0) }
}

function Show-Diff($path, $localJson, $remoteJson){
  try {
    $pl = Project-Json $localJson
    $pr = Project-Json $remoteJson
    $cntL = try { $pl.features.Count } catch { $null }
    $cntR = try { $pr.features.Count } catch { $null }
    if ($cntL -ne $cntR) {
      Write-Host ("    diff: count L/R={0}/{1}" -f $cntL,$cntR) -ForegroundColor DarkYellow
    }
    $max = 3
    $limit = [int]([Math]::Min($max, [Math]::Min([int]$cntL, [int]$cntR)))
    for ($i=0; $i -lt $limit; $i++) {
      $fl = $pl.features[$i]
      $fr = $pr.features[$i]
      $same = ($fl.id -eq $fr.id) -and ($fl.label -eq $fr.label)
      $mark = '='
      if (-not $same) { $mark = '!=' }
      $color = 'DarkGray'
      if (-not $same) { $color = 'Yellow' }
      Write-Host ("    {0} L: {1} | {2} ({3},{4})" -f $mark,$fl.label,$fl.city,$fl.lat,$fl.lon) -ForegroundColor $color
      Write-Host ("      R: {0} | {1} ({2},{3})" -f $fr.label,$fr.city,$fr.lat,$fr.lon) -ForegroundColor $color
      if (-not $same) { break }
    }
  } catch {
    Write-Host ("    diff: unable to project ({0})" -f $_.Exception.Message) -ForegroundColor DarkYellow
  }
}

function Shape-Check($json){
  if ($null -eq $json) { return $false }
  if ($json.PSObject.Properties.Name -contains 'type' -and $json.type -eq 'FeatureCollection') { return $true }
  if ($json.PSObject.Properties.Name -contains 'status' -and $json.PSObject.Properties.Name -contains 'mode') { return $true }
  return $false
}

function First-Label($json){
  try { return $json.features[0].properties.label } catch { return $null }
}

Write-Host "[1/4] HTTP mode and TLS bridge" -ForegroundColor Cyan
$redirUrl = "$httpBase/search/?q=8%20bd%20du%20port,%20nanterre&limit=1"
try {
  $hdr = & curl.exe -s -o NUL -D - "$redirUrl"
  $status = ($hdr -split "`n")[0]
  $loc = ($hdr -split "`n") | Where-Object { $_ -match '^Location:' }
  if ($status -match ' 301 ' -and $loc -match '^Location:\s+https://') {
    Write-Host "  OK redirect HTTP->HTTPS active" -ForegroundColor Green
  } elseif ($status -match ' 200 ') {
    Write-Host "  OK HTTP accepted (TLS bridge mode)" -ForegroundColor Green
  } else {
    Write-Warning "  Unexpected HTTP status: $status"
  }
  # Bridge parity: local HTTP vs remote HTTPS
  $lp = Invoke-JsonRobust "$httpBase/search/?q=rue%20de%20rivoli%20paris&limit=1"
  $rp = Invoke-JsonRobust "$RemoteBase/search/?q=rue%20de%20rivoli%20paris&limit=1"
  $hL = if ($lp.Json) { Get-ProjectedHash $lp.Json } else { '' }
  $hR = if ($rp.Json) { Get-ProjectedHash $rp.Json } else { '' }
  if ($hL -ne '' -and $hL -eq $hR) { Write-Host "  OK TLS bridge parity (HTTP local == HTTPS remote)" -ForegroundColor Green } else { Write-Warning "  TLS bridge parity FAIL" }
} catch { Write-Warning "  curl.exe not available, skipping HTTP mode check" }

Write-Host "[2/4] HTTPS health" -ForegroundColor Cyan
$h = Invoke-Json "$httpsBase/_health"
if ($h.Ok -and (Shape-Check $h.Json)) {
  Write-Host "  OK ($($h.Ms) ms) mode=$($h.Json.mode)" -ForegroundColor Green
} else {
  # Fallback to curl.exe for better TLS tolerance
  try {
    $hdr = & curl.exe -s -k -o NUL -w '%{http_code}' "$httpsBase/_health"
    if ($hdr -eq '200') { Write-Host "  OK (curl.exe)" -ForegroundColor Green } else { Write-Warning "  Health FAIL: $($h.Error) (curl status: $hdr)" }
  } catch { Write-Warning "  Health FAIL: $($h.Error)" }
}

Write-Host "[3/4] Endpoints parity (avg latency over $Runs, remote $RemoteRuns)" -ForegroundColor Cyan
# Build tests either from capabilities or fallback list
$tests = @()
if ($UseCapabilities) {
  $cap = Fetch-Capabilities $CapabilitiesUrl
  $tests = Tests-FromCapabilities $cap
}
if (-not $tests.Count) {
  $tests = @(
    @{ path='/search/';        params='q=8%20bd%20du%20port,%20nanterre&limit=1' },
    @{ path='/search/';        params='q=rue%20de%20rivoli%20paris&limit=5' },
    @{ path='/search/';        params='q=lyon&limit=10' },
    @{ path='/reverse/';       params='lat=48.8566&lon=2.3522' },
    @{ path='/reverse/';       params='lat=43.2965&lon=5.3698' },
    @{ path='/reverse/';       params='lat=43.6045&lon=1.4442' }
  )
}

function Print-Row($row){
  $status = $row.Status
  $color = if ($status -eq 'OK') { 'Green' } else { 'Yellow' }
  if ($row.Path -match '/csv$') {
    $fmt = "  [{0}] {1,-15}  avg_local={2,4}ms  avg_remote={3,4}ms  rows L/R={4}/{5}  success L/R={6}/{7}  checksum={8}"
    Write-Host ($fmt -f $status, $row.Path, $row.AvgLocal, $row.AvgRemote, $row.CountL, $row.CountR, $row.SuccessL, $row.SuccessR, $row.SumEq) -ForegroundColor $color
  } else {
    $fmt = "  [{0}] {1,-15}  avg_local={2,4}ms  avg_remote={3,4}ms  count L/R={4}/{5}  label={6}  checksum={7}"
    Write-Host ($fmt -f $status, $row.Path, $row.AvgLocal, $row.AvgRemote, $row.CountL, $row.CountR, $row.LabelEq, $row.SumEq) -ForegroundColor $color
  }
}

function Avg($arr){ if ($arr.Count) { [int]([Math]::Round(($arr | Measure-Object -Average | Select-Object -ExpandProperty Average),0)) } else { 0 } }

$results = @()
$localAvgBag = @()
$remoteAvgBag = @()
foreach ($t in $tests) {
  $localSamples = @()
  $first = $null
  for ($i=0; $i -lt $Runs; $i++) {
    $r = Invoke-JsonRobust "$localBase$($t.path)?$($t.params)"
    if ($i -eq 0) { $first = $r }
    if ($r.Ok) { $localSamples += $r.Ms }
  }
  $avgL = Avg $localSamples
  # Remote N runs
  $remoteSamples = @()
  $firstRemote = $null
  for ($j=0; $j -lt $RemoteRuns; $j++) {
    $rr = Invoke-JsonRobust "$RemoteBase$($t.path)?$($t.params)"
    if ($j -eq 0) { $firstRemote = $rr }
    if ($rr.Ok) { $remoteSamples += $rr.Ms }
  }
  $avgR = Avg $remoteSamples
  $okShape = ($first.Ok -and (Shape-Check $first.Json) -and $firstRemote.Ok -and (Shape-Check $firstRemote.Json))
  $lblL = if ($first.Json) { First-Label $first.Json } else { $null }
  $lblR = if ($firstRemote.Json){ First-Label $firstRemote.Json } else { $null }
  $countL = try { $first.Json.features.Count } catch { $null }
  $countR = try { $firstRemote.Json.features.Count } catch { $null }
  # Stable projection checksums (ignore volatile fields)
  $hashL = if ($first.Json) { Get-ProjectedHash $first.Json } else { '' }
  $hashR = if ($firstRemote.Json){ Get-ProjectedHash $firstRemote.Json } else { '' }
  $sameHash = ($hashL -eq $hashR)
  $row = [pscustomobject]@{
    Path = $t.path; AvgLocal = $avgL; AvgRemote = $avgR; CountL = $countL; CountR = $countR; LabelEq = ($lblL -eq $lblR); SumEq = $sameHash; Status = $(if ($sameHash) { 'OK' } else { '!!' })
  }
  $results += ,$row
  if ($avgL -gt 0) { $localAvgBag += $avgL }
  if ($avgR -gt 0) { $remoteAvgBag += $avgR }
  Print-Row $row
  if ($row.Status -ne 'OK' -and $first.Json -and $firstRemote.Json) { Show-Diff $t.path $first.Json $firstRemote.Json }
}

Write-Host "[4/6] Upstream headers" -ForegroundColor Cyan
$hdrs = & curl.exe -s -o NUL -D - "$httpsBase/search/?q=rue%20de%20la%20paix&limit=1"
$sel = ($hdrs -split "`n") | Where-Object { $_ -match '^X-Geodock-' -or $_ -match '^Location:' }
if (-not $sel -or $sel.Count -eq 0) {
  Write-Host "  (none)" -ForegroundColor DarkGray
} else {
  foreach ($h in $sel) { Write-Host ('  ' + $h.Trim()) }
}

if ($IncludeOptions) {
  Write-Host "[5/6] OPTIONS preflight (local/remote)" -ForegroundColor Cyan
  $uniq = $tests | ForEach-Object { if ($_ -is [hashtable]) { $_['path'] } else { $_.path } } | Where-Object { $_ } | Sort-Object -Unique
  foreach ($p in $uniq) {
    $ol = Test-Options $localBase $p ; $or = Test-Options $RemoteBase $p
    if ($ol.Ok) { $sl = $ol.Status } else { $sl = 'ERR' }
    if ($or.Ok) { $sr = $or.Status } else { $sr = 'ERR' }
    $col = 'Yellow'; if ($sl -eq 204 -and $sr -eq 204) { $col = 'Green' }
    Write-Host ("  {0,-12} local={1} remote={2}" -f $p,$sl,$sr) -ForegroundColor $col
  }
}

# CSV batch parity with fallbacks
Write-Host "[6/6] Batch CSV parity" -ForegroundColor Cyan

function Run-SearchCsv($localBase, $remoteBase){
  $scenarios = @(
    @{ qs = 'columns=q&limit=1'; csv = ( @('q','"8 bd du port, nanterre"','"rue de rivoli, paris"') -join "`n" ) },
    @{ qs = 'columns=adresse&limit=1'; csv = ( @('adresse','"8 bd du port, nanterre"','"rue de rivoli, paris"') -join "`n" ) }
  )
  $chosen = $null; $ls=$null; $rs=$null; $cL=$null; $cR=$null
  foreach ($s in $scenarios) {
    $ls = Post-Csv $localBase '/search/csv/' $s.qs $s.csv
    $rs = Post-Csv $remoteBase '/search/csv/' $s.qs $s.csv
    $cL = CsvCounts $ls.Bytes; $cR = CsvCounts $rs.Bytes
    if ($cL[0] -gt 0 -and $cR[0] -gt 0) { $chosen = $s; break }
    if ($cL[0] -eq 0 -or $cR[0] -eq 0) {
      try {
        $lfirst = [System.Text.Encoding]::UTF8.GetString($ls.Bytes).Split("`n")[0]
        $rfirst = [System.Text.Encoding]::UTF8.GetString($rs.Bytes).Split("`n")[0]
        Write-Host ("  debug search/csv: localStatus={0} remoteStatus={1} localFirst='{2}' remoteFirst='{3}'" -f $ls.Status,$rs.Status,$lfirst,$rfirst) -ForegroundColor DarkGray
      } catch {}
    }
  }
  if (-not $chosen) { $chosen = $scenarios[-1] }
  $ok = (($ls.Hash -eq $rs.Hash) -and ($cL[0] -gt 0) -and ($cR[0] -gt 0))
  return [pscustomobject]@{ Path='/search/csv'; AvgLocal=$ls.Ms; AvgRemote=$rs.Ms; CountL=$cL[0]; CountR=$cR[0]; SuccessL=$cL[1]; SuccessR=$cR[1]; LabelEq=$null; SumEq=($ls.Hash -eq $rs.Hash); Status = $(if ($ok) { 'OK' } else { '!!' }); Note = $chosen.qs }
}

function Run-ReverseCsv($localBase, $remoteBase){
  $scenarios = @(
    @{ qs = 'columns=lat&columns=lon&limit=1'; csv = "lat,lon`n48.8566,2.3522`n43.6045,1.4442" },
    @{ qs = 'columns=lon&columns=lat&limit=1'; csv = "lon,lat`n2.3522,48.8566`n1.4442,43.6045" }
  )
  $chosen = $null; $lr=$null; $rr=$null; $cL=$null; $cR=$null
  foreach ($s in $scenarios) {
    $lr = Post-Csv $localBase '/reverse/csv/' $s.qs $s.csv
    $rr = Post-Csv $remoteBase '/reverse/csv/' $s.qs $s.csv
    $cL = CsvCounts $lr.Bytes; $cR = CsvCounts $rr.Bytes
    if ($cL[0] -gt 0 -and $cR[0] -gt 0) { $chosen = $s; break }
    if ($cL[0] -eq 0 -or $cR[0] -eq 0) {
      try {
        $lfirst = [System.Text.Encoding]::UTF8.GetString($lr.Bytes).Split("`n")[0]
        $rfirst = [System.Text.Encoding]::UTF8.GetString($rr.Bytes).Split("`n")[0]
        Write-Host ("  debug reverse/csv: localStatus={0} remoteStatus={1} localFirst='{2}' remoteFirst='{3}'" -f $lr.Status,$rr.Status,$lfirst,$rfirst) -ForegroundColor DarkGray
      } catch {}
    }
  }
  if (-not $chosen) { $chosen = $scenarios[-1] }
  $ok = (($lr.Hash -eq $rr.Hash) -and ($cL[0] -gt 0) -and ($cR[0] -gt 0))
  return [pscustomobject]@{ Path='/reverse/csv'; AvgLocal=$lr.Ms; AvgRemote=$rr.Ms; CountL=$cL[0]; CountR=$cR[0]; SuccessL=$cL[1]; SuccessR=$cR[1]; LabelEq=$null; SumEq=($lr.Hash -eq $rr.Hash); Status = $(if ($ok) { 'OK' } else { '!!' }); Note = $chosen.qs }
}

try { $rowS = Run-SearchCsv $localBase $RemoteBase; $results += ,$rowS; Print-Row $rowS } catch { Write-Host "  search/csv: error $_" -ForegroundColor Yellow }
try { $rowR = Run-ReverseCsv $localBase $RemoteBase; $results += ,$rowR; Print-Row $rowR } catch { Write-Host "  reverse/csv: error $_" -ForegroundColor Yellow }

if ($restoreCallback) { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $restoreCallback }

# Summary block
Write-Host "---" -ForegroundColor DarkGray
$okCount = ($results | Where-Object { $_.Status -eq 'OK' }).Count
$failCount = ($results | Where-Object { $_.Status -ne 'OK' }).Count
$avgLocalAll = if ($localAvgBag.Count) { [int]([Math]::Round(($localAvgBag | Measure-Object -Average | Select-Object -ExpandProperty Average),0)) } else { 0 }
$avgRemoteAll = if ($remoteAvgBag.Count) { [int]([Math]::Round(($remoteAvgBag | Measure-Object -Average | Select-Object -ExpandProperty Average),0)) } else { 0 }
$delta = if ($avgLocalAll -gt 0 -and $avgRemoteAll -gt 0) { $avgLocalAll - $avgRemoteAll } else { 0 }
$ratio = if ($avgRemoteAll -gt 0) { [Math]::Round(($avgLocalAll / [double]$avgRemoteAll),2) } else { 0 }
Write-Host ("Summary: OK={0}  FAIL={1}" -f $okCount, $failCount) -ForegroundColor $(if ($failCount -gt 0) { 'Yellow' } else { 'Green' })
Write-Host ("Averages: local={0}ms  remote={1}ms  delta={2}ms  ratio={3}x" -f $avgLocalAll, $avgRemoteAll, $delta, $ratio) -ForegroundColor Cyan
Write-Host "Tests completed" -ForegroundColor Green
