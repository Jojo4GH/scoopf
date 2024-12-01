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


class SearchResults {
    [string] ${@odata.context}
    [int] ${@odata.count}
    [SearchResult[]] $value
}

class SearchResult {
    [float] ${@search.score}
    [SearchHighlights] ${@search.highlights}
    [string] $Id
    [string] $Name
    [string] $NamePartial
    [string] $NameSuffix
    [string] $Description
    [string] $Notes
    [string] $Homepage
    [string] $License
    [string] $Version
    [SearchResultMetadata] $Metadata
}

class SearchHighlights {
    [string[]] $Description
    [string[]] $Name
    [string[]] $NamePartial
    [string[]] $NameSuffix
}

class SearchResultMetadata {
    [string] $Repository
    [bool] $OfficialRepository
    [int] $RepositoryStars
    [string] $BranchName
    [string] $FilePath
    [string] $Committed
    [string] $Sha
}


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
        "top" = 100000
        "skip" = 0
    }

    $response = Invoke-WebRequest $url -Method POST -Headers $headers -Body (ConvertTo-Json $body) -ContentType "application/json"

    if ($response.StatusCode -ne 200) {
        $response
        exit 1
    }

    $json = ConvertFrom-Json $response.Content
    return [SearchResults]@{
        '@odata.context' = $json.'@odata.context'
        '@odata.count' = $json.'@odata.count'
        value = $json.value | ForEach-Object {
            [SearchResult]@{
                '@search.score' = $_.'@search.score'
                Id = $_.Id
                Name = $_.Name
                NamePartial = $_.NamePartial
                NameSuffix = $_.NameSuffix
                Description = $_.Description
                Notes = $_.Notes
                Homepage = $_.Homepage
                License = $_.License
                Version = $_.Version
                Metadata = [SearchResultMetadata]@{
                    Repository = $_.Metadata.Repository
                    OfficialRepository = $_.Metadata.OfficialRepository
                    RepositoryStars = $_.Metadata.RepositoryStars
                    BranchName = $_.Metadata.BranchName
                    FilePath = $_.Metadata.FilePath
                    Committed = $_.Metadata.Committed
                    Sha = $_.Metadata.Sha
                }
            }
        }
    }
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

function Write-AppLong ([SearchResult]$app, $bucketName, $indent = "") {
    function FormatLabel ($label) {
        return $label.PadRight(12, ' ')
    }

    $name = $app.Name

    $manifest = "$($app.Metadata.Repository)/blob/$($app.Metadata.BranchName)/$($app.Metadata.FilePath)"

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

function Write-BucketRating ([SearchResultMetadata] $metadata) {
    if ($metadata.OfficialRepository) {
        Write-Color "✓" -Color $infoColor -NoNewline
    } else {
        Write-Color "⭐$($metadata.RepositoryStars)" -Color $infoColor -NoNewline
    }
}

class Bucket {
    [string] $Name
    [string] $url
    [bool] $isAvailable
    Bucket ($Name, $url, $isAvailable) {
        $this.Name = $Name
        $this.url = $url
        $this.isAvailable = $isAvailable
    }
}

function Write-Bucket ([Bucket] $bucket, [SearchResult[]] $apps, $long, $indent = "") {
    if ($bucket.isAvailable) {
        $bucketString = $bucket.Name
        $bucketColor = "Green"
    } else {
        $bucketString = $bucket.Url
        $bucketColor = "Red"
    }

    Write-Color "$indent", $bucketString, " " -Color White, $bucketColor, White -NoNewline
    Write-BucketRating $apps[0].Metadata
    if (!$long -and !$bucket.isAvailable) {
        Write-Color "  `tscoop bucket add $($bucket.Name) $($bucket.url)" -Color $commandColor -NoNewline
    }
    Write-Color ""
    if ($long -and !$bucket.isAvailable) {
        Write-Color "$indent", "→ ", "scoop bucket add $($bucket.Name) $($bucket.url)" -Color White, DarkGray, $commandColor
    }
    foreach ($app in $apps) {
        if ($long) {
            Write-AppLong $app $bucket.Name -indent "$indent"
        } else {
            Write-AppShort $app $bucket.Name -indent "$indent  "
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
[SearchResults] $results = Find-Query $Query $Page


$bucketsByUrl = @{}
Get-AvailableBucket | ForEach-Object {
    $bucketsByUrl[$_.url] = [Bucket]::new($_.name, $_.url, $true)
}


function Get-Bucket ($url) {
    if ($bucketsByUrl.ContainsKey($url)) {
        return $bucketsByUrl[$url]
    }
    $bucketName = $url.Split("/")[-1] -replace "scoop-", "" -replace "Scoop-", ""
    $bucketName = "$($url.Split("/")[-2])_$bucketName"
    $bucketsByUrl[$url] = [Bucket]::new($bucketName, $url, $false)
    return $bucketsByUrl[$url]
}

class BucketAndApps {
    [Bucket] $Bucket
    [SearchResult[]] $Apps
}

[BucketAndApps[]] $appsByBucket = @()
$results.value | Group-Object -Property { $_.Metadata.Repository } | ForEach-Object {
    $appsByBucket += [BucketAndApps]@{
        "Bucket" = Get-Bucket $_.Name
        "Apps" = $_.Group
    }
}

$appsByBucket = $appsByBucket
    | Sort-Object -Stable { $_.Bucket.Name }
    | Sort-Object -Stable { $_.Bucket.isAvailable } -Descending
    | Sort-Object -Stable { $_.Apps[0].Metadata.OfficialRepository } -Descending

function Get-Page([BucketAndApps[]] $appsByBucket, $Page, $PageSize) {
    if ($null -eq $appsByBucket) {
        return @{
            "PageCount" = 0
            "AppsByBucket" = @()
        }
    }
    $enumerator = $appsByBucket.GetEnumerator()
    $toSkip = ($Page - 1) * $PageSize
    $pageCounter = 0
    $pageCollected = @()
    while ($enumerator.MoveNext()) {
        $current = $enumerator.Current
        if ($current.Apps.Count -le $toSkip) {
            # Skip this bucket
            $toSkip -= $current.Apps.Count
            continue
        }
        if ($toSkip -gt 0) {
            # Skip some apps in this bucket
            $current = [BucketAndApps]@{
                "Bucket" = $current.Bucket
                "Apps" = $current.Apps[$toSkip..($current.Apps.Count - 1)]
            }
            $toSkip = 0
        }
        if ($pageCounter + $current.Apps.Count -lt $PageSize) {
            # Collect all apps in this bucket
            $pageCounter += $current.Apps.Count
            $pageCollected += $current
            continue
        }
        if ($pageCounter + $current.Apps.Count -eq $PageSize) {
            # Collect all apps in this bucket and break
            $pageCounter += $current.Apps.Count
            $pageCollected += $current
            break
        }
        # Collect some apps in this bucket
        $new = [BucketAndApps]@{
            "Bucket" = $current.Bucket
            "Apps" = $current.Apps[0..($PageSize - $pageCounter - 1)]
        }
        $pageCounter += $new.Apps.Count
        $pageCollected += $new
        break
    }
    return @{
        "PageCount" = $pageCounter
        "AppsByBucket" = $pageCollected
    }
}

$pageAppsByBucket = Get-Page $appsByBucket -Page $Page -PageSize $PageSize

# Result processing
$totalCount = $results.'@odata.count'
$pageCount = $pageAppsByBucket.PageCount
if ($pageCount -eq 0) {
    Write-Color "No results found" -Color Red
    exit 1
}
$remainingCount = $totalCount - $PageSize * $Page

# Output
Write-Color "Found $totalCount result(s) in $($appsByBucket.Count) bucket(s)" -NoNewline
if ($totalCount -gt $pageCount) {
    $start = ($Page - 1) * $PageSize + 1
    $end = $start + $pageCount - 1
    Write-Color " (showing $start-$end)" -NoNewline
}
Write-Color ":"
Write-Color ""


foreach ($bucketAndApps in $pageAppsByBucket.AppsByBucket) {
    Write-Bucket $bucketAndApps.Bucket $bucketAndApps.Apps -long (!$Short) -indent ""
    Write-Color ""
}

if ($remainingCount -gt 0) {
    Write-Color "There are $remainingCount more results available." -Color White
    Write-Color "Use   ", "$($MyInvocation.MyCommand) $Query -Page $($Page + 1)", "   to show $([Math]::Min($PageSize, $remainingCount)) more" -Color White, $commandColor, White
}
