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
    $initial = Invoke-RestMethod 'http://localhost:8766/api/data'
    Assert ($initial.data.projects.Count -eq 5) 'All projects imported'
    $rejected = $false
    try { Invoke-RestMethod 'http://localhost:8766/api/save' -Method Post -ContentType 'application/json' -Body '{}' | Out-Null } catch { $rejected = [int]$_.Exception.Response.StatusCode -eq 403 }
    Assert $rejected 'Write requests require editor token'
    $rejected = $false
    try { Invoke-RestMethod 'http://localhost:8766/api/data' -Headers @{Origin='http://untrusted.example'} | Out-Null } catch { $rejected = [int]$_.Exception.Response.StatusCode -eq 403 }
    Assert $rejected 'Cross-origin access rejected'
    $chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
    $browser = Start-Process $chrome -ArgumentList @('--headless=new','--remote-debugging-port=9227',('--user-data-dir="'+(Join-Path $testRoot 'browser')+'"'),'--no-first-run','--no-default-browser-check','about:blank') -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $testRoot 'browser.log')
    Start-Sleep -Milliseconds 1500
    $target = Invoke-RestMethod 'http://localhost:9227/json/new?about:blank' -Method Put
    $socket = New-Object Net.WebSockets.ClientWebSocket
    $socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl,[Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
    Cdp 'Page.enable' @{} | Out-Null
    Cdp 'Page.addScriptToEvaluateOnNewDocument' @{source='window.__errors=[];addEventListener("error",e=>__errors.push(e.message));addEventListener("unhandledrejection",e=>__errors.push(String(e.reason)));'} | Out-Null
    Cdp 'Emulation.setDeviceMetricsOverride' @{width=1440;height=1000;deviceScaleFactor=1;mobile=$false} | Out-Null
    Cdp 'Page.navigate' @{url='http://localhost:8766/editor/'} | Out-Null
    Wait-Js 'document.querySelectorAll(".card").length===4'
    Assert (Evaluate 'document.querySelectorAll("#project option").length===5') 'Editor loads five projects and existing frames'
    Evaluate 'document.querySelector(".card .card-actions button").click()' | Out-Null
    Evaluate '(async()=>{const blob=await(await fetch("/image/01_the_last_archive/01_thurmnail.jpg")).blob();const transfer=new DataTransfer();transfer.items.add(new File([blob],"test.jpg",{type:"image/jpeg"}));const input=document.getElementById("replace-file");input.files=transfer.files;input.dispatchEvent(new Event("change"));})()' | Out-Null
    Wait-Js 'document.querySelector(".card-image img") && !document.getElementById("project").disabled'
    Assert (Evaluate 'document.querySelector(".card-image img").getAttribute("src").includes("/image/uploads/")') 'Upload replaces selected empty frame'
    Evaluate 'document.querySelectorAll(".card .card-actions button")[1].click(); const input=document.querySelector(".card-fields input");input.value="한글 caption <script>safe</script>";input.dispatchEvent(new Event("input"));' | Out-Null
    Evaluate 'document.querySelectorAll(".card-top button")[2].click()' | Out-Null
    Assert (Evaluate 'document.querySelectorAll(".card")[1].querySelector("input").value.includes("한글")') 'Reorder preserves edited caption'
    Evaluate 'document.querySelectorAll(".card")[1].querySelector(".danger").click();document.getElementById("undo-remove").click()' | Out-Null
    Assert (Evaluate 'document.querySelectorAll(".card").length===4 && document.querySelectorAll(".card")[1].querySelector("input").value.includes("한글")') 'Remove and undo preserve image data'

    Evaluate '(async()=>{const blob=await(await fetch("/image/01_the_last_archive/01_thurmnail.jpg")).blob();const transfer=new DataTransfer();transfer.items.add(new File([blob],"one.jpg",{type:"image/jpeg"}));transfer.items.add(new File([blob],"two.jpg",{type:"image/jpeg"}));document.getElementById("dropzone").dispatchEvent(new DragEvent("drop",{dataTransfer:transfer,bubbles:true,cancelable:true}));})()' | Out-Null
    Wait-Js 'document.querySelectorAll(".card").length===6 && !document.getElementById("project").disabled'
    Assert $true 'Multiple file drop creates new frames'
    Evaluate 'const cards=document.querySelectorAll(".card");const first=cards[4].querySelector("input");first.value="First new";first.dispatchEvent(new Event("input"));const second=cards[5].querySelector("input");second.value="Second new";second.dispatchEvent(new Event("input"));const transfer=new DataTransfer();cards[5].querySelector(".handle").dispatchEvent(new DragEvent("dragstart",{dataTransfer:transfer}));cards[4].dispatchEvent(new DragEvent("drop",{dataTransfer:transfer,cancelable:true}));' | Out-Null
    Assert (Evaluate 'document.querySelectorAll(".card")[4].querySelector("input").value==="Second new"') 'Drag reorder moves image and caption together'
    Evaluate 'const select=document.getElementById("project");select.value="4";select.dispatchEvent(new Event("change"));' | Out-Null
    Assert (Evaluate 'document.querySelectorAll("#cover-slot option").length===2') 'Two-image project exposes separate main image slots'
    Evaluate 'document.getElementById("project").value="0";document.getElementById("project").dispatchEvent(new Event("change"));' | Out-Null
    Evaluate 'document.getElementById("preview").click()' | Out-Null
    Wait-Js 'document.getElementById("preview-frame").contentDocument?.querySelector(".project-gallery .plate-img")'
    Assert (Evaluate 'document.getElementById("preview-frame").contentDocument.querySelector(".project-gallery .plate-caption").textContent !== undefined') 'Unsaved preview renders project gallery'
    Evaluate 'document.getElementById("preview-close").click();document.getElementById("save").click()' | Out-Null
    Wait-Js 'document.getElementById("status").textContent.startsWith("저장했습니다")'
    $saved = Invoke-RestMethod 'http://localhost:8766/api/data'
    Assert ($saved.data.projects[0].sections[0].images[1].caption -like '*caption*') 'Saved data keeps order and Unicode captions'
    Assert ($saved.data.projects[0].cover.src -eq $saved.data.projects[0].sections[0].images[1].src) 'Cover shares the gallery image reference'
    Assert (Test-Path -LiteralPath (Join-Path $testRoot '.local-editor\portfolio-media.previous.js')) 'Previous save backup created'
    $rejected = $false
    try { Invoke-RestMethod 'http://localhost:8766/api/save' -Method Post -Headers @{'X-Editor-Token'=$initial.token} -ContentType 'application/json' -Body (@{data=$initial.data;version=$initial.version}|ConvertTo-Json -Depth 30) | Out-Null } catch { $rejected = [int]$_.Exception.Response.StatusCode -eq 409 }
    Assert $rejected 'Stale save rejected without overwriting'
    Assert (Evaluate 'window.__errors.length===0') 'No editor JavaScript errors'
    Cdp 'Page.reload' @{} | Out-Null
    Wait-Js 'document.querySelectorAll(".card")[1]?.querySelector("input").value.includes("한글")'
    Assert $true 'Saved edit survives browser reload'
    $shot = Cdp 'Page.captureScreenshot' @{format='png'}
    [IO.File]::WriteAllBytes((Join-Path $root '.local-editor\editor-preview.png'),[Convert]::FromBase64String($shot.data))
    Cdp 'Page.navigate' @{url='http://localhost:8766/'} | Out-Null
    Wait-Js 'document.querySelector("#proj-1 .lens img")?.naturalWidth>0'
    Assert (Evaluate 'document.querySelector("#proj-1 .lens img").src===document.querySelector("#index-archive [data-cover-project=\"project-01\"]").src') 'Cover synchronized with archive thumbnail'
    Cdp 'Page.navigate' @{url='http://localhost:8766/projects/the-last-archive.html'} | Out-Null
    Wait-Js 'document.querySelector(".project-gallery .plate-img")'
    Evaluate 'document.querySelector(".image-zoom").scrollIntoView({behavior:"instant"})' | Out-Null
    Wait-Js 'document.querySelector(".project-gallery .plate-img")?.naturalWidth>0'
    Assert (Evaluate 'document.querySelector(".project-gallery .plate-img").naturalWidth>0') 'Standalone project loads saved image'
    Assert (Evaluate '[...document.querySelectorAll(".project-gallery .plate-caption")].some(el=>el.textContent.includes("<script>safe</script>"))') 'Captions rendered as text, never HTML'
    Evaluate 'document.querySelector(".image-zoom").click()' | Out-Null
    Assert (Evaluate 'document.querySelector(".image-viewer").open') 'Image detail opens from gallery'
    Cdp 'Input.dispatchKeyEvent' @{type='keyDown';key='ArrowRight';code='ArrowRight';windowsVirtualKeyCode=39} | Out-Null
    Assert (Evaluate 'document.querySelector(".viewer-count").textContent.startsWith("2 /")') 'Image detail supports keyboard navigation'
    Cdp 'Input.dispatchKeyEvent' @{type='keyDown';key='Escape';code='Escape';windowsVirtualKeyCode=27} | Out-Null
    Wait-Js '!document.querySelector(".image-viewer").open && document.activeElement.classList.contains("image-zoom")'
    Assert $true 'Escape closes image and restores focus'
    Assert (Evaluate 'window.__errors.length===0') 'No public gallery JavaScript errors'
    Write-Host "All checks passed. Test workspace: $testRoot"
} finally {
    if ($socket) { $socket.Dispose() }
    if ($browser -and -not $browser.HasExited) { Stop-Process -Id $browser.Id -ErrorAction SilentlyContinue }
    if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id -ErrorAction SilentlyContinue }
}
