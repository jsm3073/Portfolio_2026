param([int]$Port = 8765, [switch]$OpenBrowser)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$dataPath = Join-Path $root 'assets\portfolio-media.js'
$utf8 = New-Object Text.UTF8Encoding($false)
$origin = "http://localhost:$Port"
$token = [Guid]::NewGuid().ToString('N')

function Read-Data {
    $raw = [IO.File]::ReadAllText($dataPath, $utf8)
    return ($raw -replace '^window.PORTFOLIO_MEDIA\s*=\s*', '' -replace ';\s*$', '' | ConvertFrom-Json)
}
function Get-Version {
    return (Get-FileHash -LiteralPath $dataPath -Algorithm SHA256).Hash
}
function Check-Source($src) {
    if ($src -eq '') { return }
    if ($src -isnot [string] -or $src -notmatch '^\.?/?image/[a-zA-Z0-9_./-]+\.(jpg|jpeg|png|webp)$' -or $src.Contains('..')) { throw 'Invalid image path.' }
    $path = Join-Path $root ($src -replace '^\./', '')
    if (-not [IO.File]::Exists($path)) { throw 'Image file does not exist.' }
}
function Check-Text($value, $limit) {
    if ($value -isnot [string] -or $value.Length -gt $limit) { throw 'Invalid text field.' }
}
function Check-Data($data) {
    $baseline = Read-Data
    if ($data.schemaVersion -ne 1 -or @($data.projects).Count -ne @($baseline.projects).Count) { throw 'Invalid project data.' }
    $seen = @{}
    foreach ($project in $data.projects) {
        $original = @($baseline.projects | Where-Object { $_.id -eq $project.id })
        if ($original.Count -ne 1 -or $seen.ContainsKey($project.id)) { throw 'Unknown or duplicate project.' }
        $seen[$project.id] = $true
        if ($project.modalId -ne $original[0].modalId -or $project.sectionId -ne $original[0].sectionId) { throw 'Invalid project target.' }
        Check-Text $project.title 200
        Check-Source $project.cover.src
        Check-Text $project.cover.alt 500
        if (@($project.additionalCovers).Count -gt 10) { throw 'Too many main images.' }
        foreach ($cover in $project.additionalCovers) { Check-Source $cover.src; Check-Text $cover.alt 500 }
        if (@($project.sections).Count -lt 1 -or @($project.sections).Count -gt 30) { throw 'Invalid sections.' }
        $imageIds = @{}
        foreach ($section in $project.sections) {
            Check-Text $section.title 200
            Check-Text $section.label 200
            if (@($section.images).Count -gt 300) { throw 'Too many images.' }
            foreach ($item in $section.images) {
                if ($item.id -notmatch '^[a-zA-Z0-9_-]{1,80}$' -or $imageIds.ContainsKey($item.id)) { throw 'Invalid or duplicate image ID.' }
                $imageIds[$item.id] = $true
                if ($item.type -eq 'video') {
                    Check-Text $item.videoUrl 2000
                    if ($item.src -ne '' -or $item.videoUrl -cnotmatch '^https://(www\.youtube\.com/watch\?v=[a-zA-Z0-9_-]{11}|vimeo\.com/[0-9]+(/[a-zA-Z0-9]+)?)$') { throw 'Use a valid YouTube or Vimeo video link.' }
                } elseif ($item.type -and $item.type -ne 'image') { throw 'Invalid media type.' }
                Check-Source $item.src
                Check-Text $item.caption 2000
                Check-Text $item.alt 500
                if ($item.layout -notin @('wide','half') -or $item.fit -notin @('contain','cover')) { throw 'Invalid image layout.' }
            }
        }
    }
}
function Reply($context, [int]$status, [string]$type, [byte[]]$bytes) {
    $response = $context.Response
    $response.StatusCode = $status
    $response.ContentType = $type
    $response.Headers['Cache-Control'] = 'no-store'
    $response.Headers['X-Content-Type-Options'] = 'nosniff'
    $response.Headers['Content-Security-Policy'] = "frame-ancestors 'self'"
    $response.ContentLength64 = $bytes.Length
    $response.OutputStream.Write($bytes, 0, $bytes.Length)
    $response.Close()
}
function Json-Reply($context, [int]$status, $value) {
    Reply $context $status 'application/json; charset=utf-8' ($utf8.GetBytes(($value | ConvertTo-Json -Depth 30 -Compress)))
}

if ($OpenBrowser) {
    try {
        $existing = Invoke-RestMethod "$origin/api/data" -TimeoutSec 2
        if ($existing.data.schemaVersion -eq 1) { Start-Process "$origin/editor/"; return }
    } catch {}
}
$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("$origin/")
$listener.Start()
if ($OpenBrowser) { Start-Process "$origin/editor/" }
Write-Host "Media editor: $origin/editor/"
Write-Host 'Keep this window open while editing. Press Ctrl+C to stop.'
try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        try {
            $request = $context.Request
            if ($request.Headers['Host'] -ne "localhost:$Port") { Json-Reply $context 403 @{error='Invalid host.'}; continue }
            if ($request.Headers['Origin'] -and $request.Headers['Origin'] -ne $origin) { Json-Reply $context 403 @{error='Invalid origin.'}; continue }
            $route = [Uri]::UnescapeDataString($request.Url.AbsolutePath)
            if ($request.HttpMethod -eq 'GET' -and $route -eq '/api/data') {
                Json-Reply $context 200 @{data=(Read-Data); version=(Get-Version); token=$token}; continue
            }
            if ($request.HttpMethod -eq 'POST' -and $route -in @('/api/save','/api/upload')) {
                if ($request.Headers['X-Editor-Token'] -ne $token) { Json-Reply $context 403 @{error='Reload the local editor.'}; continue }
                if ($request.ContentType -notlike 'application/json*') { Json-Reply $context 415 @{error='JSON required.'}; continue }
                if ($request.ContentLength64 -lt 0 -or $request.ContentLength64 -gt 30000000) { Json-Reply $context 413 @{error='Request too large.'}; continue }
                $reader = New-Object IO.StreamReader($request.InputStream, $utf8)
                try { $body = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
                if ($route -eq '/api/save') {
                    if ($body.version -ne (Get-Version)) { Json-Reply $context 409 @{error='Another window or program changed the data. Reload before saving.'}; continue }
                    Check-Data $body.data
                    $backupDir = Join-Path $root '.local-editor'
                    [IO.Directory]::CreateDirectory($backupDir) | Out-Null
                    $temporary = Join-Path $root 'assets\portfolio-media.pending'
                    $json = $body.data | ConvertTo-Json -Depth 30
                    [IO.File]::WriteAllText($temporary, "window.PORTFOLIO_MEDIA = $json;`n", $utf8)
                    [IO.File]::Replace($temporary, $dataPath, (Join-Path $backupDir 'portfolio-media.previous.js'))
                    Json-Reply $context 200 @{version=(Get-Version)}; continue
                }
                if ($body.projectId -notin @((Read-Data).projects.id)) { throw 'Unknown project.' }
                $extension = [IO.Path]::GetExtension([string]$body.name).ToLowerInvariant()
                if ($extension -notin @('.jpg','.jpeg','.png','.webp')) { throw 'Use JPG, PNG or WebP images.' }
                $bytes = [Convert]::FromBase64String([string]$body.base64)
                if ($bytes.Length -lt 12 -or $bytes.Length -gt 20000000) { throw 'Image must be smaller than 20 MB.' }
                $valid = $false
                if ($extension -in @('.jpg','.jpeg')) { $valid = $bytes[0] -eq 255 -and $bytes[1] -eq 216 -and $bytes[2] -eq 255 }
                if ($extension -eq '.png') { $valid = [BitConverter]::ToString($bytes,0,8) -eq '89-50-4E-47-0D-0A-1A-0A' }
                if ($extension -eq '.webp') { $valid = [Text.Encoding]::ASCII.GetString($bytes,0,4) -eq 'RIFF' -and [Text.Encoding]::ASCII.GetString($bytes,8,4) -eq 'WEBP' }
                if (-not $valid) { throw 'Image contents do not match the file type.' }
                $relative = 'image/uploads/' + $body.projectId + '/' + [Guid]::NewGuid().ToString('N') + $extension
                $destination = Join-Path $root $relative
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
                [IO.File]::WriteAllBytes($destination, $bytes)
                Json-Reply $context 200 @{src=$relative}; continue
            }
            if ($request.HttpMethod -ne 'GET') { Json-Reply $context 405 @{error='Method not allowed.'}; continue }
            if ($route -eq '/') { $route = '/index.html' }
            if ($route -in @('/editor','/editor/')) { $route = '/editor/index.html' }
            if ($route.Contains('..') -or $route.Contains('\') -or $route.Contains(':') -or $route -notmatch '^/(index\.html|about\.html|projects/[a-z0-9-]+\.html|assets/[a-zA-Z0-9_-]+\.(js|css)|editor/(index\.html|editor\.(js|css))|image/[a-zA-Z0-9_./-]+\.(jpg|jpeg|png|webp))$') {
                Json-Reply $context 404 @{error='Not found.'}; continue
            }
            $file = Join-Path $root $route.TrimStart('/')
            if (-not [IO.File]::Exists($file)) { Json-Reply $context 404 @{error='Not found.'}; continue }
            $mime = @{'.html'='text/html; charset=utf-8'; '.js'='text/javascript; charset=utf-8'; '.css'='text/css; charset=utf-8'; '.jpg'='image/jpeg'; '.jpeg'='image/jpeg'; '.png'='image/png'; '.webp'='image/webp'}
            Reply $context 200 $mime[[IO.Path]::GetExtension($file).ToLowerInvariant()] ([IO.File]::ReadAllBytes($file))
        } catch {
            try { Json-Reply $context 400 @{error=$_.Exception.Message} } catch { Write-Warning $_ }
        }
    }
} finally { $listener.Close() }
