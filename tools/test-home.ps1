$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = Join-Path $root ('.local-editor\test-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
foreach ($name in @('index.html','about.html','assets','editor','tools','image','projects')) { Copy-Item -LiteralPath (Join-Path $root $name) -Destination $testRoot -Recurse }
$server = $null
$browser = $null
$socket = $null
$script:messageId = 0
$utf8 = New-Object Text.UTF8Encoding($false)
function Assert($condition, $message) { if (-not $condition) { throw $message }; Write-Host "PASS $message" }
function Cdp([string]$method, $params) {
    $script:messageId++
    $payload = @{id=$script:messageId;method=$method;params=$params} | ConvertTo-Json -Depth 30 -Compress
    $bytes = $utf8.GetBytes($payload)
    $socket.SendAsync((New-Object 'ArraySegment[byte]' -ArgumentList (,$bytes)), [Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
    do {
        $stream = New-Object IO.MemoryStream
        do {
            $buffer = New-Object byte[] 65536
            $segment = New-Object 'ArraySegment[byte]' -ArgumentList (,$buffer)
            $received = $socket.ReceiveAsync($segment,[Threading.CancellationToken]::None).GetAwaiter().GetResult()
            $stream.Write($buffer,0,$received.Count)
        } while (-not $received.EndOfMessage)
        $response = $utf8.GetString($stream.ToArray()) | ConvertFrom-Json
        $stream.Dispose()
    } while ($response.id -ne $script:messageId)
    if ($response.error) { throw ($response.error | ConvertTo-Json) }
    return $response.result
}
function Evaluate([string]$js) {
    $result = Cdp 'Runtime.evaluate' @{expression=$js;awaitPromise=$true;returnByValue=$true}
    if ($result.exceptionDetails) { throw ($result.exceptionDetails | ConvertTo-Json -Depth 10) }
    return $result.result.value
}
function Wait-Js([string]$js) {
    for ($attempt=0; $attempt -lt 60; $attempt++) {
        if (Evaluate $js) { return }
        Start-Sleep -Milliseconds 200
    }
    throw "Timed out: $js"
}

try {
    $server = Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $testRoot 'tools\media-editor.ps1')+'"'),'-Port','8766') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $testRoot 'server.log') -RedirectStandardError (Join-Path $testRoot 'server-error.log')
    Start-Sleep -Milliseconds 800
    $browser = Start-Process 'C:\Program Files\Google\Chrome\Application\chrome.exe' -ArgumentList @('--headless=new','--remote-debugging-port=9227',('--user-data-dir="'+(Join-Path $testRoot 'browser')+'"'),'--no-first-run','--no-default-browser-check','about:blank') -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $testRoot 'browser.log')
    Start-Sleep -Milliseconds 1200
    $target = Invoke-RestMethod 'http://localhost:9227/json/new?about:blank' -Method Put
    $socket = New-Object Net.WebSockets.ClientWebSocket
    $socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl,[Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
    Cdp 'Page.enable' @{} | Out-Null
    Cdp 'Page.addScriptToEvaluateOnNewDocument' @{source='window.__errors=[];addEventListener("error",e=>__errors.push(e.message));addEventListener("unhandledrejection",e=>__errors.push(String(e.reason)));'} | Out-Null
    Cdp 'Emulation.setDeviceMetricsOverride' @{width=1440;height=1000;deviceScaleFactor=1;mobile=$false} | Out-Null
    Cdp 'Page.navigate' @{url='http://localhost:8766/'} | Out-Null
    Wait-Js 'document.querySelector(".hero-work img")?.naturalWidth>0 && typeof applyMode==="function"'
    Evaluate 'document.fonts.ready.then(()=>true)' | Out-Null
    Assert (Evaluate 'document.querySelectorAll(".archive-card").length===5 && document.querySelectorAll(".featured-card").length===2') 'Selected work and complete archive present'
    Assert (Evaluate 'document.querySelectorAll("[data-project-link]").length>=5 && !document.querySelector(".proj-modal")') 'Homepage links to standalone projects'
    Assert (Evaluate '!document.getElementById("biography") && document.querySelector(''.hero-links a[href="./about.html"]'')') 'Homepage offers a direct link to separate About'
    Assert (Evaluate 'getComputedStyle(document.querySelector(".hero-work img")).filter==="none"') 'Original image colors preserved'
    Assert (Evaluate '!document.getElementById("loader") && !document.querySelector(".parallax")') 'No loading screen or passive parallax'
    Assert (Evaluate '[...document.querySelectorAll(".site-nav a")].filter(a=>a.hash).every(a=>document.querySelector(a.hash))') 'All main navigation destinations exist'
    foreach($width in @(320,390,768,1024,1440,1920)){
        Cdp 'Emulation.setDeviceMetricsOverride' @{width=$width;height=1000;deviceScaleFactor=1;mobile=$false} | Out-Null
        Assert (Evaluate 'document.documentElement.scrollWidth<=innerWidth') "No page overflow at $width px"
        Assert (Evaluate '[...document.querySelectorAll(".site-header a,.site-header button")].every(el=>{const r=el.getBoundingClientRect();return r.left>=0&&r.right<=innerWidth})') "Navigation fits at $width px"
    }
    Cdp 'Emulation.setDeviceMetricsOverride' @{width=1440;height=1000;deviceScaleFactor=1;mobile=$false} | Out-Null

    foreach($id in @('project-01','project-02','project-03','project-05','project-06')){
        Evaluate ('document.querySelector(''[data-project-link="'+$id+'"]'').click()') | Out-Null
        Wait-Js ('document.body.dataset.projectId==="'+$id+'" && document.querySelector(".plate-section")')
        Assert (Evaluate 'document.querySelector("h1").textContent.length>0 && document.querySelectorAll(".project-facts dt").length===5') "$id has standalone overview and credits"
        Assert (Evaluate '[...document.querySelectorAll(".project-toc a")].every(a=>document.querySelector(a.hash))') 'Project section navigation targets exist'
        Assert (Evaluate 'document.querySelectorAll(".plate").length===window.PORTFOLIO_MEDIA.projects.find(p=>p.id===document.body.dataset.projectId).sections.reduce((n,s)=>n+s.images.length,0)') 'All saved gallery frames retained'
        foreach($width in @(320,390,768,1024,1440)){
            Cdp 'Emulation.setDeviceMetricsOverride' @{width=$width;height=1000;deviceScaleFactor=1;mobile=$false} | Out-Null
            Assert (Evaluate 'document.documentElement.scrollWidth<=innerWidth') "$id fits $width px"
        }
        if($id -eq 'project-01'){
            Wait-Js 'document.querySelector(".project-hero-image").naturalWidth>0'
            Evaluate 'document.fonts.ready.then(()=>true)' | Out-Null
            Start-Sleep -Milliseconds 350
            $shot=Cdp 'Page.captureScreenshot' @{format='jpeg';quality=80}
            [IO.File]::WriteAllBytes((Join-Path $root '.local-editor/project-desktop.jpg'),[Convert]::FromBase64String($shot.data))
            Cdp 'Emulation.setDeviceMetricsOverride' @{width=390;height=844;deviceScaleFactor=1;mobile=$true} | Out-Null
            $shot=Cdp 'Page.captureScreenshot' @{format='jpeg';quality=80}
            [IO.File]::WriteAllBytes((Join-Path $root '.local-editor/project-mobile.jpg'),[Convert]::FromBase64String($shot.data))
            Cdp 'Emulation.setDeviceMetricsOverride' @{width=1440;height=1000;deviceScaleFactor=1;mobile=$false} | Out-Null
        }
        Cdp 'Page.reload' @{} | Out-Null
        Wait-Js ('document.body.dataset.projectId==="'+$id+'" && document.querySelector(".plate-section")')
        Assert (Evaluate 'window.__errors.length===0') 'Direct project reload has no JavaScript errors'
        Evaluate 'history.back()' | Out-Null
        Wait-Js 'document.querySelector(".hero-work")'
        Assert $true 'Browser back returns to homepage'
    }
    Evaluate 'document.getElementById("selected-work").scrollIntoView({behavior:"instant"})' | Out-Null
    Start-Sleep -Milliseconds 500
    $shot = Cdp 'Page.captureScreenshot' @{format='jpeg';quality=80}
    [IO.File]::WriteAllBytes((Join-Path $root '.local-editor\home-selected.jpg'),[Convert]::FromBase64String($shot.data))

    Evaluate 'document.querySelector(''.site-nav a[href="./about.html"]'').click()' | Out-Null
    Wait-Js 'document.body.classList.contains("about-page") && typeof applyMode==="function"'
    Assert (Evaluate 'document.querySelectorAll("#biography .trajectory-row").length===8 && document.querySelector(".t-inst").textContent.length>0') 'Full biography and timeline retained on About'
    Assert (Evaluate '[...document.querySelectorAll(".about-contents a")].every(a=>document.querySelector(a.hash))') 'About section destinations exist'
    Assert (Evaluate 'document.querySelector(''.site-nav a[aria-current="page"]'').textContent==="About"') 'About navigation identifies current page'
    Evaluate 'document.fonts.ready.then(()=>true)' | Out-Null
    foreach($width in @(320,390,768,1024,1440,1920)){
        Cdp 'Emulation.setDeviceMetricsOverride' @{width=$width;height=1000;deviceScaleFactor=1;mobile=$false} | Out-Null
        Assert (Evaluate 'document.documentElement.scrollWidth<=innerWidth') "About fits $width px"
        Assert (Evaluate 'document.querySelector(".about-contents").scrollWidth<=document.querySelector(".about-contents").clientWidth') "All About section links visible at $width px"
        Assert (Evaluate '[...document.querySelectorAll(".site-header a,.site-header button")].every(el=>{const r=el.getBoundingClientRect();return r.left>=0&&r.right<=innerWidth})') "About navigation fits $width px"
    }
    Cdp 'Emulation.setDeviceMetricsOverride' @{width=1440;height=1000;deviceScaleFactor=1;mobile=$false} | Out-Null
    Evaluate 'window.scrollTo({top:0,behavior:"instant"})' | Out-Null
    Start-Sleep -Milliseconds 300
    $shot=Cdp 'Page.captureScreenshot' @{format='jpeg';quality=80}
    [IO.File]::WriteAllBytes((Join-Path $root '.local-editor/about-desktop.jpg'),[Convert]::FromBase64String($shot.data))
    Cdp 'Emulation.setDeviceMetricsOverride' @{width=390;height=844;deviceScaleFactor=1;mobile=$true} | Out-Null
    $shot=Cdp 'Page.captureScreenshot' @{format='jpeg';quality=80}
    [IO.File]::WriteAllBytes((Join-Path $root '.local-editor/about-mobile.jpg'),[Convert]::FromBase64String($shot.data))
    Evaluate 'document.querySelector(''.about-contents a[href="#about-timeline"]'').click()' | Out-Null
    Wait-Js 'document.getElementById("about-timeline").open'
    Assert (Evaluate 'document.documentElement.scrollWidth<=innerWidth') 'Expanded timeline fits mobile'
    Evaluate 'document.getElementById("mode-toggle").click();document.querySelector(".brand").click()' | Out-Null
    Wait-Js 'document.querySelector(".hero-work") && typeof applyMode==="function"'
    Assert (Evaluate 'document.documentElement.classList.contains("dark") && document.getElementById("mode-toggle").getAttribute("aria-pressed")==="true"') 'Theme persists between About and homepage'
    Evaluate 'document.getElementById("mode-toggle").click()' | Out-Null
    Cdp 'Page.navigate' @{url='http://localhost:8766/index.html#biography'} | Out-Null
    Wait-Js 'location.pathname==="/about.html" && document.getElementById("biography")'
    Assert $true 'Old biography links reach About'
    Assert (Evaluate 'window.__errors.length===0') 'About has no JavaScript errors'
    Cdp 'Page.navigate' @{url='http://localhost:8766/'} | Out-Null
    Wait-Js 'document.querySelector(".hero-work img")?.naturalWidth>0 && typeof applyMode==="function"'
    Cdp 'Emulation.setDeviceMetricsOverride' @{width=1440;height=1000;deviceScaleFactor=1;mobile=$false} | Out-Null
    Evaluate 'window.scrollTo(0,0)' | Out-Null
    Start-Sleep -Milliseconds 300
    $shot = Cdp 'Page.captureScreenshot' @{format='jpeg';quality=80}
    [IO.File]::WriteAllBytes((Join-Path $root '.local-editor\home-desktop.jpg'),[Convert]::FromBase64String($shot.data))
    Evaluate 'document.getElementById("mode-toggle").click()' | Out-Null
    Assert (Evaluate 'document.documentElement.classList.contains("dark")') 'Night theme toggle works'
    Start-Sleep -Milliseconds 450
    $shot = Cdp 'Page.captureScreenshot' @{format='jpeg';quality=80}
    [IO.File]::WriteAllBytes((Join-Path $root '.local-editor\home-dark.jpg'),[Convert]::FromBase64String($shot.data))
    Evaluate 'document.getElementById("mode-toggle").click()' | Out-Null
    Cdp 'Emulation.setDeviceMetricsOverride' @{width=390;height=844;deviceScaleFactor=1;mobile=$true} | Out-Null
    Start-Sleep -Milliseconds 450
    $shot = Cdp 'Page.captureScreenshot' @{format='jpeg';quality=80}
    [IO.File]::WriteAllBytes((Join-Path $root '.local-editor\home-mobile.jpg'),[Convert]::FromBase64String($shot.data))
    Cdp 'Emulation.setEmulatedMedia' @{features=@(@{name='prefers-reduced-motion';value='reduce'})} | Out-Null
    Assert (Evaluate 'getComputedStyle(document.querySelector(".image-open")).transitionDuration==="0s"') 'Reduced motion preference respected'
    Assert (Evaluate 'window.__errors.length===0') 'No JavaScript errors'
    $badLinks=Evaluate '(async()=>{const paths=[''index.html'',''about.html'',...Object.values(PORTFOLIO_ROUTES)],bad=[],cache=new Map();async function doc(url){const u=new URL(url,location.href);u.hash='''';if(!cache.has(u.href))cache.set(u.href,fetch(u).then(async r=>({ok:r.ok,doc:new DOMParser().parseFromString(await r.text(),''text/html'')})));return cache.get(u.href)}for(const path of paths){const url=new URL(path,location.href),page=await doc(url);if(!page.ok){bad.push(path);continue}for(const el of page.doc.querySelectorAll(''a[href],script[src],link[rel="stylesheet"]'')){const u=new URL(el.getAttribute(''href'')||el.getAttribute(''src''),url);if(u.origin!==location.origin)continue;const target=await doc(u);if(!target.ok||u.hash&&!target.doc.getElementById(decodeURIComponent(u.hash.slice(1))))bad.push(path+'' -> ''+u.pathname+u.hash)}}return bad})()'
    Assert ($badLinks.Count -eq 0) ("All seven pages: local links, anchors, scripts and styles resolve. " + ($badLinks -join ', '))
    Write-Host 'Homepage and About checks passed.'
} finally {
    if ($socket) { $socket.Dispose() }
    if ($browser -and -not $browser.HasExited) { Stop-Process -Id $browser.Id -ErrorAction SilentlyContinue }
    if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id -ErrorAction SilentlyContinue }
}
