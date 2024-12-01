#Requires -Modules PSWriteColor
# scoopf - Scoop search with extra features
param (
    [Parameter(Mandatory = $false)]
    [int] $Page = 1,
    [Parameter(Mandatory = $false)]
    [int] $PageSize = 16,
    [Parameter(Mandatory = $false)]
    [switch] $Short = $false,
    [Parameter(ValueFromRemainingArguments = $true, Position = 0)]
    [string] $Query
)


# Settings
$url = "https://scoopsearch.search.windows.net/indexes/apps/docs/search?api-version=2020-06-30"
$apiKey = "DC6D2BBE65FC7313F2C52BBD2B0286ED"

$appColor = "Yellow"
$commandColor = "DarkMagenta"
$infoColor = "Gray"

$scoopDir = if ($null -eq $env:SCOOP) { "$env:USERPROFILE\scoop" } else { $env:SCOOP }
$cacheDir = "$HOME\.cache\scoopf"


function Find-Query ($query, $page) {
    $headers = @{
        "Api-Key" = $apiKey
    }
    $body = @{
        "search" = "$query"
        "searchMode" = "all"
        "filter" = "Metadata/DuplicateOf eq null"
        "orderby" = "search.score() desc, Metadata/OfficialRepositoryNumber desc, NameSortable asc"
        "count" = $true
        "top" = $PageSize
        "skip" = $PageSize * ($page - 1)
    }

    $response = Invoke-WebRequest $url -Method POST -Headers $headers -Body (ConvertTo-Json $body) -ContentType "application/json"

    if ($response.StatusCode -ne 200) {
        $response
        exit 1
    }

    return ConvertFrom-Json $response.Content
}

function Get-AvailableBucket {
    $dirs = Get-ChildItem "$scoopDir\buckets" -Directory
    $cachedBucketsPath = "$cacheDir\buckets.json"
    if (Test-Path $cachedBucketsPath) {
        $cachedBuckets = ConvertFrom-Json (Get-Content $cachedBucketsPath -Raw)
    } else {
        $cachedBuckets = @()
    }
    $buckets = $dirs | ForEach-Object {
        $dir = $_
        $cachedBucket = $cachedBuckets | Where-Object { $_.name -eq $dir.Name } | Select-Object -First 1
        if ($null -ne $cachedBucket) {
            return $cachedBucket
        }
        $url = (git -C $_.FullName config --get remote.origin.url) -replace ".git$", ""
        @{
            "name" = $_.Name
            "url" = $url
        }
    }
    if (!(Test-Path $cacheDir)) {
        New-Item -ItemType Directory -Path $cacheDir
    }
    ConvertTo-Json $buckets | Out-File "$cacheDir\buckets.json"
    return $buckets
}

function Get-InstalledApp {
    return Get-ChildItem "$scoopDir\apps" -Directory
}

function Write-AppShort ($app, $bucketName, $indent = "") {
    $name = $app.Name

    Write-Color "$indent", "$name", " ", "@$($app.Version)", "" -Color White, $appColor, White, DarkCyan, White -NoNewline
    Write-Color "  `tscoop install $bucketName/$name" -Color $commandColor

    Write-Color "$indent  " -NoNewline
    if ($null -ne $app.Description) {
        Write-Color "$($app.Description)" -Color $infoColor -NoNewline
        if ($null -ne $app.Homepage) {
            Write-Color " [$($app.Homepage)]" -Color $infoColor -NoNewline
        }
    } elseif ($null -ne $app.Homepage) {
        Write-Color "$($app.Homepage)" -Color $infoColor -NoNewline
    }
    Write-Color ""
}

function Write-AppLong ($app, $bucketName, $indent = "") {
    function FormatLabel ($label) {
        return $label.PadRight(12, ' ')
    }

    $name = $app.Name

    $manifest = "$($app.Metadata.Repository)/blob/master/$($app.Metadata.FilePath)"

    Write-Color "$indent┌ ", "$name", " ", "@$($app.Version)", " ", "$manifest" -Color White, $appColor, White, DarkCyan, White, DarkGray
    Write-Color "$indent│ ", (FormatLabel "To install:"), " scoop install $bucketName/$name" -Color White, DarkGray, $commandColor

    $info = "$($app.Homepage)"
    if ($null -ne $app.Description) {
        $info += "`n$($app.Description)"
    }
    $lines = $info -split "`n"

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $prefix = if ($i -eq $lines.Count - 1) { "└ " } else { "│ " }
        $label = if ($i -eq 0) { "Info:" } else { "" }
        $line = $lines[$i]
        Write-Color "$indent$prefix", (FormatLabel $label), " $line" -Color White, DarkGray, White
    }
}

function Write-BucketRating ($metadata) {
    if ($metadata.OfficialRepository) {
        Write-Color "✓" -Color $infoColor -NoNewline
    } else {
        Write-Color "⭐$($metadata.RepositoryStars)" -Color $infoColor -NoNewline
    }
}

function Write-Bucket ($apps, $availableBuckets, $long, $indent = "") {
    $metadata = $apps[0].Metadata
    $bucket = $metadata.Repository
    $bucketName = $bucket.Split("/")[-1] -replace "scoop-", "" -replace "Scoop-", ""
    $bucketName = "$($bucket.Split("/")[-2])_$bucketName"
    $bucketColor = "Red"
    $installedBucket = $availableBuckets | Where-Object { $_.url -eq $bucket }
    if ($null -ne $installedBucket) {
        $bucket = $installedBucket.name
        $bucketName = $installedBucket.name
        $bucketColor = "Green"
    } elseif ($metadata.OfficialRepository) {
        # $bucketColor = "DarkGreen"
    }

    Write-Color "$indent", "$bucket", " " -Color White, $bucketColor, White -NoNewline
    Write-BucketRating $metadata
    if (!$long -and $null -eq $installedBucket) {
        Write-Color "  `tscoop bucket add $bucketName $bucket" -Color $commandColor -NoNewline
    } else {
        # Write-Color " [available]" -Color DarkGray -NoNewline
    }
    Write-Color ""
    if ($long -and $null -eq $installedBucket) {
        Write-Color "$indent", "→ ", "scoop bucket add $bucketName $bucket" -Color White, DarkGray, $commandColor
    }
    foreach ($app in $apps) {
        if ($long) {
            Write-AppLong $app $bucketName -indent "$indent"
        } else {
            Write-AppShort $app $bucketName -indent "$indent  "
        }
    }
}


# Input parsing
if ($null -eq $Query) {
    Write-Color "Please provide a search query" -Color Red
    exit 1
}
if ($Page -lt 1) {
    $Page = 1
}


# Request
Write-Color "Searching for `"$Query`"" -NoNewline
if ($Page -gt 1) {
    Write-Color " on page $Page" -NoNewline
}
Write-Color " ..."
$result = Find-Query $Query $Page


# Result processing
$totalCount = $result.'@odata.count'
$count = $result.value.Count
if ($count -eq 0) {
    Write-Color "No results found" -Color Red
    exit 1
}
$remainingCount = $totalCount - $PageSize * $Page
$appsByBucket = $result.value | Group-Object -Property { $_.Metadata.Repository } | Sort-Object -Property { $_.Name } | Sort-Object -Property { $_.Group[0].Metadata.OfficialRepositoryNumber } -Descending


# Output
Write-Color "Found $totalCount result(s) in $($appsByBucket.Count) bucket(s)" -NoNewline
if ($totalCount -gt $count) {
    $start = ($Page - 1) * $PageSize + 1
    $end = $start + $count - 1
    Write-Color " (showing $start-$end)" -NoNewline
}
Write-Color ":"
Write-Color ""

$availableBuckets = Get-AvailableBucket

foreach ($apps in $appsByBucket) {
    Write-Bucket -apps $apps.Group -availableBuckets $availableBuckets -long (!$Short) -indent ""
    Write-Color ""
}

if ($remainingCount -gt 0) {
    Write-Color "There are $remainingCount more results available." -Color White
    Write-Color "Use   ", "$($MyInvocation.MyCommand) $Query -Page $($Page + 1)", "   to show $([Math]::Min($PageSize, $remainingCount)) more" -Color White, $commandColor, White
}
