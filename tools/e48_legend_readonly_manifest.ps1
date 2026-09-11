$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Fixed, read-only inventory for the authorized source root. This script never
# writes to the remote host and rejects any path other than the literal root.
$root = "E:\传奇世界"
$expectedRoot = [System.IO.Path]::GetFullPath($root).TrimEnd("\")
$resolvedRoot = (Resolve-Path -LiteralPath $root).Path.TrimEnd("\")
if (-not [string]::Equals(
    $expectedRoot,
    $resolvedRoot,
    [System.StringComparison]::OrdinalIgnoreCase
)) {
    throw "source_root_mismatch"
}

[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$copyExtensions = @(".lua", ".json", ".ini", ".cfg", ".conf", ".xml", ".png", ".jpg", ".jpeg", ".bmp")
$textExtensions = @(".lua", ".json", ".ini", ".cfg", ".conf", ".xml", ".txt")
$sensitivePath = [regex]::new(
    "(?i)(cookie|credential|password|passwd|token|account|账号|密码|验证码|verify|captcha|payment|支付|wallet|chat|聊天|cache|缓存|history|profile|session|save|log|日志)"
)
$sensitiveContent = [regex]::new(
    "(?i)(password|passwd|token|cookie|credential|captcha|verification|account|username|openid|unionid|payment|recharge|order|wallet|账号|用户名|密码|验证码|支付|充值|订单|钱包|聊天|用户资料)"
)
$touchSpriteApiNames = @(
    "mSleep", "tap", "touchDown", "touchMove", "touchUp", "swipe",
    "findImageInRegionFuzzy", "findImage", "ocr", "getColor", "keepScreen",
    "releaseScreen", "longTap", "keyDown", "keyUp", "pressHomeKey",
    "frontAppBid", "MemoryFind", "FtpIsUpdate", "appRun", "appKill",
    "runApp", "closeApp", "getScreenSize", "snapshot", "writePasteboard",
    "readPasteboard", "inputText", "inputKey", "isFrontApp"
)
$apiPattern = [regex]::new(
    "(?i)\b(" + (($touchSpriteApiNames | ForEach-Object { [regex]::Escape($_) }) -join "|") + ")\b"
)

function Get-RelativePath([string]$FullName) {
    return $FullName.Substring($resolvedRoot.Length).TrimStart("\").Replace("\", "/")
}

function Get-TextEncoding([string]$Path, [string]$Extension) {
    if ($textExtensions -notcontains $Extension) {
        return "binary_or_not_applicable"
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return "utf-8-bom"
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return "utf-16le"
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        return "utf-16be"
    }
    try {
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        [void]$strictUtf8.GetString($bytes)
        return "utf-8"
    } catch {
        return "legacy_or_unknown"
    }
}

function Get-LuaFacts([string]$Body) {
    $modules = [regex]::Matches($body, "(?m)\brequire\s*\(?\s*['`"]([^'`"]+)['`"]")
    $fileDependencies = [regex]::Matches(
        $body,
        "(?m)\b(?:dofile|loadfile)\s*\(?\s*['`"]([^'`"]+)['`"]"
    )
    $resources = [regex]::Matches($body, "(?i)['`"]([^'`"]+\.(?:png|jpe?g|bmp))['`"]")
    $apiCalls = [regex]::Matches($body, $apiPattern)
    $apiNames = @($apiCalls | ForEach-Object { $_.Groups[1].Value })
    $apiUsage = @()
    if ($apiNames.Count -gt 0) {
        $apiUsage = @($apiNames | Group-Object | Sort-Object Name | ForEach-Object {
            [pscustomobject]@{
                name = $_.Name
                count = $_.Count
            }
        })
    }
    return [pscustomobject]@{
        sensitive = $sensitiveContent.IsMatch($body)
        modules = @($modules | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        fileDependencies = @($fileDependencies | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        resources = @($resources | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        touchSpriteApiCalls = $apiUsage
    }
}

$allowed = @()
$excluded = @()
$allFiles = Get-ChildItem -LiteralPath $resolvedRoot -Recurse -Force -File | Sort-Object FullName

foreach ($file in $allFiles) {
    $relativePath = Get-RelativePath $file.FullName
    $extension = $file.Extension.ToLowerInvariant()
    if ($sensitivePath.IsMatch($relativePath)) {
        $excluded += [pscustomobject]@{
            reason = "sensitive_path_pattern"
            extension = $extension
        }
        continue
    }

    $textBody = $null
    if ($textExtensions -contains $extension) {
        $textBody = [System.IO.File]::ReadAllText($file.FullName)
        if ($sensitiveContent.IsMatch($textBody)) {
            $excluded += [pscustomobject]@{
                reason = "sensitive_content_pattern"
                extension = $extension
            }
            continue
        }
    }
    $luaFacts = $null
    if ($extension -eq ".lua") {
        $luaFacts = Get-LuaFacts $textBody
    }

    $kind = if ($copyExtensions -contains $extension) { "migration_candidate" } else { "inventory_only" }
    $entry = $extension -eq ".lua" -and $file.Name -match "^(main|init|startup|start|run)\.lua$"
    $allowed += [pscustomobject]@{
        relativePath = $relativePath
        size = [int64]$file.Length
        mtimeUtc = $file.LastWriteTimeUtc.ToString("o")
        extension = $extension
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        textEncoding = Get-TextEncoding $file.FullName $extension
        classification = $kind
        entryFile = $entry
        modules = if ($null -eq $luaFacts) { [object[]]@() } else { [object[]]$luaFacts.modules }
        fileDependencies = if ($null -eq $luaFacts) { [object[]]@() } else { [object[]]$luaFacts.fileDependencies }
        resources = if ($null -eq $luaFacts) { [object[]]@() } else { [object[]]$luaFacts.resources }
        touchSpriteApiCalls = if ($null -eq $luaFacts) { [object[]]@() } else { [object[]]$luaFacts.touchSpriteApiCalls }
    }
}

$result = [pscustomobject]@{
    schemaVersion = 1
    collector = "e48_legend_readonly_manifest.ps1"
    sourceRoot = "E:\传奇世界"
    accessMode = "read_only"
    collectedAtUtc = [DateTime]::UtcNow.ToString("o")
    files = $allowed
    exclusions = [pscustomobject]@{
        count = $excluded.Count
        records = $excluded
        policy = "Sensitive paths and Lua files containing credential, account, payment, verification, cookie, or token markers are excluded without recording their path or hash."
    }
}

$result | ConvertTo-Json -Depth 8 -Compress
