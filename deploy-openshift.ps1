<#
.SYNOPSIS
    Deploys a container image archive (.tar / .tar.gz) and its Helm chart to OpenShift from Windows,
    without Docker, Podman or WSL.

.DESCRIPTION
    The script runs these steps:
      1. Checks for oc and helm, and installs helm with winget if it is missing.
      2. Reads the image name and tag from the archive.
      3. Logs in to OpenShift if you are not logged in, and creates the project if it doesn't exist.
      4. Pushes the image to OpenShift's internal registry:
           - Crane:     downloads crane.exe and pushes through the registry's external route
           - InCluster: starts a temporary skopeo pod and pushes from inside the cluster
           - Auto:      tries Crane first and falls back to InCluster (default)
      5. Runs "helm upgrade --install" with the image settings pointed at the pushed image.
      6. Creates an HTTPS route for the app if it doesn't have one, and prints the URL.

    Any required value you don't pass as a parameter is asked for interactively.

.EXAMPLE
    .\deploy-openshift.ps1
    Asks for everything it needs.

.EXAMPLE
    .\deploy-openshift.ps1 -ImageArchive .\myapp.tar.gz -ChartPath .\mychart -Project myproj `
        -Server https://api.mycluster.example.com:6443 -NonInteractive

.NOTES
    If scripts are blocked on your machine, run it like this:
        powershell -ExecutionPolicy Bypass -File .\deploy-openshift.ps1
    Works in Windows PowerShell 5.1 and PowerShell 7.
#>
[CmdletBinding()]
param(
    # Path to the image archive made by "docker save" or "podman save" (.tar or .tar.gz)
    [string]$ImageArchive,
    # Path to the Helm chart folder or packaged .tgz
    [string]$ChartPath,
    # OpenShift project (namespace) to deploy into. Created if it doesn't exist.
    [string]$Project,
    # Image name in the registry. Defaults to the name stored in the archive.
    [string]$AppName,
    # Image tag. Defaults to the tag stored in the archive.
    [string]$ImageTag,
    # Helm release name. Defaults to AppName.
    [string]$ReleaseName,
    # OpenShift API URL, e.g. https://api.mycluster.example.com:6443. Only needed if not logged in.
    [string]$Server,
    # OpenShift login token (from "Copy login command" in the web console). Optional.
    [string]$Token,
    [ValidateSet('Auto', 'Crane', 'InCluster')]
    [string]$PushMethod = 'Auto',
    # Extra Helm values file to apply on top of the chart's defaults. Optional.
    [string]$ValuesFile,
    # Chart value keys for the image. Change these if the chart uses a different layout.
    [string]$ImageRepositoryKey = 'image.repository',
    [string]$ImageTagKey = 'image.tag',
    [string]$ImagePullPolicyKey = 'image.pullPolicy',
    # Skip TLS verification when pushing through the registry route (self-signed cluster certs).
    [bool]$InsecureRegistry = $true,
    # Create an HTTPS route if the release has none.
    [bool]$ExposeRoute = $true,
    # Service to expose. Defaults to the first service in the release.
    [string]$ServiceToExpose,
    # Keep the chart's runAsUser/fsGroup settings instead of clearing them for OpenShift.
    [switch]$KeepChartSecurityContext,
    [string]$SkopeoImage = 'quay.io/skopeo/stable:latest',
    [string]$HelmTimeout = '10m',
    # Fail instead of prompting when a value is missing.
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$InternalRegistry = 'image-registry.openshift-image-registry.svc:5000'
$ToolsDir = Join-Path $PSScriptRoot 'tools'
$TempFiles = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------- helpers

function Write-Step([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Write-Info([string]$Text) { Write-Host "    $Text" }
function Write-Warn([string]$Text) { Write-Host "    WARNING: $Text" -ForegroundColor Yellow }

# Runs a native command, captures its output, and throws on a non-zero exit code.
# -Label is used in error messages so tokens in the arguments are never printed.
function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$ArgList = @(),
        [string]$Label,
        [switch]$AllowFail
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $Exe @ArgList 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    $text = (@($output) | ForEach-Object { "$_" }) -join "`n"
    if ($code -ne 0 -and -not $AllowFail) {
        if (-not $Label) { $Label = "$Exe $($ArgList | Select-Object -First 2)" }
        throw "$Label failed (exit code $code):`n$text"
    }
    return [pscustomobject]@{ Code = $code; Output = $text.Trim() }
}

function Read-Value {
    param([string]$Name, [string]$Current, [string]$Prompt, [string]$Default)
    if ($Current) { return $Current.Trim().Trim('"') }
    if ($NonInteractive) {
        if ($Default) { return $Default }
        throw "Missing required value: -$Name"
    }
    $suffix = ''
    if ($Default) { $suffix = " [$Default]" }
    do {
        $value = Read-Host "$Prompt$suffix"
        if (-not $value) { $value = $Default }
    } while (-not $value)
    return $value.Trim().Trim('"')
}

function Test-Gzip([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $bytes = New-Object byte[] 2
        $read = $stream.Read($bytes, 0, 2)
        return ($read -eq 2 -and $bytes[0] -eq 0x1f -and $bytes[1] -eq 0x8b)
    } finally { $stream.Close() }
}

function Expand-Gzip([string]$Source, [string]$Destination) {
    $in = [IO.File]::OpenRead($Source)
    $out = [IO.File]::Create($Destination)
    $gz = New-Object IO.Compression.GZipStream($in, [IO.Compression.CompressionMode]::Decompress)
    try { $gz.CopyTo($out) } finally { $gz.Close(); $out.Close(); $in.Close() }
}

function Get-OcJson([string[]]$ArgList) {
    $result = Invoke-Native oc ($ArgList + @('-o', 'json')) -AllowFail
    if ($result.Code -ne 0) { return $null }
    return ($result.Output | ConvertFrom-Json)
}

# ---------------------------------------------------------------- 1. tools

function Assert-Tools {
    Write-Step 'Checking tools'
    if (-not (Get-Command oc -ErrorAction SilentlyContinue)) {
        throw "oc was not found on PATH. Download the oc CLI for Windows from your cluster's web console (? menu > Command Line Tools) and add it to PATH."
    }
    Write-Info "oc:   $((Get-Command oc).Source)"

    if (-not (Get-Command helm -ErrorAction SilentlyContinue)) {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Write-Info 'helm not found, installing it with winget...'
            Invoke-Native winget @('install', '--id', 'Helm.Helm', '-e', '--accept-source-agreements', '--accept-package-agreements') -AllowFail | Out-Null
            $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
        }
        if (-not (Get-Command helm -ErrorAction SilentlyContinue)) {
            throw 'helm was not found and could not be installed. Download helm.exe from the Helm releases page on GitHub and add it to PATH.'
        }
    }
    Write-Info "helm: $((Get-Command helm).Source)"
}

# ---------------------------------------------------------------- 2. archive

function Get-ArchiveInfo([string]$Path) {
    # Windows tar (bsdtar) reads .tar and .tar.gz directly.
    $manifest = Invoke-Native tar @('-xOf', $Path, 'manifest.json') -AllowFail
    if ($manifest.Code -eq 0 -and $manifest.Output) {
        $entries = @($manifest.Output | ConvertFrom-Json)
        if ($entries.Count -gt 1) { Write-Warn "The archive holds $($entries.Count) images. Only the first one is deployed." }
        $repoTag = $null
        if ($entries[0].RepoTags) { $repoTag = @($entries[0].RepoTags)[0] }
        return [pscustomobject]@{ Format = 'docker-archive'; RepoTag = $repoTag }
    }
    $index = Invoke-Native tar @('-tf', $Path, 'index.json') -AllowFail
    if ($index.Code -eq 0) {
        return [pscustomobject]@{ Format = 'oci-archive'; RepoTag = $null }
    }
    throw "$Path is not an image archive (no manifest.json or index.json inside). If it was made with 'docker export', it holds a container filesystem, not an image, and must be rebuilt with 'docker save'."
}

function Split-RepoTag([string]$RepoTag) {
    if (-not $RepoTag) { return @($null, $null) }
    $last = $RepoTag.Split('/')[-1]
    $parts = $last.Split(':')
    $tag = $null
    if ($parts.Count -gt 1) { $tag = $parts[-1] }
    return @($parts[0], $tag)
}

# ---------------------------------------------------------------- 3. login / project

function Connect-Cluster {
    Write-Step 'Checking OpenShift login'
    $who = Invoke-Native oc @('whoami') -AllowFail
    if ($who.Code -eq 0 -and -not $Server) {
        Write-Info "Logged in as $($who.Output) to $((Invoke-Native oc @('whoami', '--show-server')).Output)"
        return
    }
    $script:Server = Read-Value 'Server' $Server 'OpenShift API URL (e.g. https://api.mycluster.example.com:6443)'
    if ($Token) {
        Invoke-Native oc @('login', $Server, "--token=$Token") -Label 'oc login' | Out-Null
    } else {
        Write-Info 'Log in with your OpenShift username and password:'
        & oc login $Server
        if ($LASTEXITCODE -ne 0) { throw 'oc login failed.' }
    }
    Write-Info "Logged in as $((Invoke-Native oc @('whoami')).Output)"
}

function Select-Project([string]$Name) {
    Write-Step "Using project $Name"
    $exists = Invoke-Native oc @('get', 'project', $Name) -AllowFail
    if ($exists.Code -ne 0) {
        Write-Info 'Project not found, creating it...'
        Invoke-Native oc @('new-project', $Name, '--skip-config-write') -Label 'oc new-project' | Out-Null
    }
    Invoke-Native oc @('project', $Name) | Out-Null
}

function Get-OcToken {
    $t = Invoke-Native oc @('whoami', '-t') -AllowFail
    if ($t.Code -ne 0 -or -not $t.Output) {
        throw "Couldn't get a login token ('oc whoami -t' failed). Log in with a username/password or token instead of a certificate-based kubeconfig."
    }
    return $t.Output
}

# ---------------------------------------------------------------- 4a. push with crane

function Get-Crane {
    $existing = Get-Command crane -ErrorAction SilentlyContinue
    if ($existing) { return $existing.Source }
    $local = Join-Path $ToolsDir 'crane.exe'
    if (Test-Path $local) { return $local }

    Write-Info 'Downloading crane...'
    New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null
    $download = Join-Path $ToolsDir 'crane.tar.gz'
    $url = 'https://github.com/google/go-containerregistry/releases/latest/download/go-containerregistry_Windows_x86_64.tar.gz'
    $previous = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try { Invoke-WebRequest -Uri $url -OutFile $download -UseBasicParsing }
    finally { $ProgressPreference = $previous }
    Invoke-Native tar @('-xzf', $download, '-C', $ToolsDir, 'crane.exe') -Label 'Extracting crane' | Out-Null
    Remove-Item $download -Force
    return $local
}

function Get-RegistryRoute {
    $route = Get-OcJson @('get', 'route', 'default-route', '-n', 'openshift-image-registry')
    if ($route) { return $route.spec.host }

    Write-Info 'The registry route is not exposed. Trying to expose it (needs cluster-admin)...'
    $patchFile = Join-Path $env:TEMP "registry-route-patch-$PID.json"
    Set-Content -Path $patchFile -Value '{"spec":{"defaultRoute":true}}' -Encoding ASCII
    $TempFiles.Add($patchFile)
    $patch = Invoke-Native oc @('patch', 'configs.imageregistry.operator.openshift.io/cluster', '--type=merge', "--patch-file=$patchFile") -AllowFail
    if ($patch.Code -ne 0) { throw "Couldn't expose the registry route: $($patch.Output)" }

    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 2
        $route = Get-OcJson @('get', 'route', 'default-route', '-n', 'openshift-image-registry')
        if ($route) { return $route.spec.host }
    }
    throw 'The registry route did not appear within 60 seconds.'
}

function Push-WithCrane([string]$Archive, [string]$Format, [string]$Target) {
    if ($Format -ne 'docker-archive') { throw 'crane can only push docker-archive files. This archive is OCI format.' }
    $crane = Get-Crane
    $registry = Get-RegistryRoute
    Write-Info "Registry route: $registry"

    $tarPath = $Archive
    if (Test-Gzip $Archive) {
        $tarPath = Join-Path $env:TEMP ("image-$PID-" + [IO.Path]::GetRandomFileName() + '.tar')
        Write-Info 'Decompressing the archive...'
        Expand-Gzip $Archive $tarPath
        $TempFiles.Add($tarPath)
    }

    $token = Get-OcToken
    Invoke-Native $crane @('auth', 'login', $registry, '-u', 'openshift', '-p', $token) -Label 'crane auth login' | Out-Null

    $pushArgs = @('push', $tarPath, "$registry/$Target")
    if ($InsecureRegistry) { $pushArgs += '--insecure' }
    Write-Info "Pushing to $registry/$Target (this can take a while)..."
    Invoke-Native $crane $pushArgs -Label 'crane push' | Out-Null
}

# ---------------------------------------------------------------- 4b. push from inside the cluster

function Push-InCluster([string]$Archive, [string]$Format, [string]$Target, [string]$Namespace) {
    $pod = 'image-push-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
    Write-Info "Starting temporary pod $pod ($SkopeoImage)..."
    Invoke-Native oc @('run', $pod, '-n', $Namespace, "--image=$SkopeoImage", '--restart=Never', '--command', '--', 'sleep', '3600') -Label 'oc run' | Out-Null
    try {
        $ready = Invoke-Native oc @('wait', "pod/$pod", '-n', $Namespace, '--for=condition=Ready', '--timeout=300s') -AllowFail
        if ($ready.Code -ne 0) {
            $status = (Invoke-Native oc @('get', 'pod', $pod, '-n', $Namespace) -AllowFail).Output
            throw "The skopeo pod did not start. Can the cluster pull $SkopeoImage?`n$status"
        }

        # Stream the file into the pod through stdin (binary-safe, no tar needed in the pod).
        $fullPath = (Resolve-Path $Archive).Path
        $size = (Get-Item $fullPath).Length
        Write-Info ("Uploading {0:N0} MB to the pod..." -f ($size / 1MB))
        $proc = Start-Process -FilePath (Get-Command oc).Source -NoNewWindow -Wait -PassThru `
            -RedirectStandardInput $fullPath `
            -ArgumentList @('exec', '-i', $pod, '-n', $Namespace, '--', 'sh', '-c', '"cat > /tmp/image.tar"')
        if ($proc.ExitCode -ne 0) { throw "Uploading the archive to the pod failed (exit code $($proc.ExitCode))." }

        $remoteSize = (Invoke-Native oc @('exec', $pod, '-n', $Namespace, '--', 'stat', '-c', '%s', '/tmp/image.tar')).Output
        if ([int64]$remoteSize -ne $size) { throw "Upload incomplete: $remoteSize of $size bytes arrived." }

        $token = Get-OcToken
        Write-Info "Pushing to $InternalRegistry/$Target..."
        Invoke-Native oc @('exec', $pod, '-n', $Namespace, '--',
            'env', 'HOME=/tmp', 'TMPDIR=/tmp',
            'skopeo', 'copy', "${Format}:/tmp/image.tar", "docker://$InternalRegistry/$Target",
            '--dest-creds', "openshift:$token", '--dest-tls-verify=false') -Label 'skopeo copy' | Out-Null
    } finally {
        Invoke-Native oc @('delete', 'pod', $pod, '-n', $Namespace, '--wait=false') -AllowFail | Out-Null
    }
}

# ---------------------------------------------------------------- 5. helm

function Install-Chart {
    param([string]$Chart, [string]$Release, [string]$Namespace, [string]$Repository, [string]$Tag)
    Write-Step "Installing Helm release $Release"

    $values = (Invoke-Native helm @('show', 'values', $Chart) -Label 'helm show values').Output
    $repoLeaf = $ImageRepositoryKey.Split('.')[-1]
    if ($values -notmatch "(?m)^\s*${repoLeaf}:") {
        Write-Warn "The chart's values don't contain '${repoLeaf}:'. Check its image keys with 'helm show values' and pass -ImageRepositoryKey / -ImageTagKey."
    }

    $helmArgs = @('upgrade', '--install', $Release, $Chart, '-n', $Namespace,
        '--wait', '--timeout', $HelmTimeout,
        '--set', "$ImageRepositoryKey=$Repository",
        '--set-string', "$ImageTagKey=$Tag",
        '--set', "$ImagePullPolicyKey=Always")
    if ($ValuesFile) { $helmArgs += @('-f', (Resolve-Path $ValuesFile).Path) }
    if (-not $KeepChartSecurityContext) {
        # OpenShift assigns a random non-root UID; fixed IDs from the chart get rejected.
        foreach ($key in 'podSecurityContext.runAsUser', 'podSecurityContext.runAsGroup', 'podSecurityContext.fsGroup',
                         'securityContext.runAsUser', 'securityContext.runAsGroup') {
            $helmArgs += @('--set', "$key=null")
        }
    }

    Write-Info 'Waiting for the pods to become ready...'
    $result = Invoke-Native helm $helmArgs -AllowFail
    if ($result.Code -ne 0) {
        Write-Host $result.Output -ForegroundColor Red
        Write-Host "`nPods:" -ForegroundColor Yellow
        Write-Host (Invoke-Native oc @('get', 'pods', '-n', $Namespace) -AllowFail).Output
        Write-Host "`nRecent warnings:" -ForegroundColor Yellow
        Write-Host (Invoke-Native oc @('get', 'events', '-n', $Namespace, '--field-selector', 'type=Warning', '--sort-by=.lastTimestamp') -AllowFail).Output
        throw 'Helm install failed. See the pod status and events above (common causes are listed in README.md).'
    }
    Write-Info 'Release is deployed and ready.'
}

# ---------------------------------------------------------------- 6. route

function Get-ReleaseServices([string]$Release, [string]$Namespace) {
    $manifest = (Invoke-Native helm @('get', 'manifest', $Release, '-n', $Namespace)).Output
    $names = @()
    foreach ($doc in ($manifest -split '(?m)^---\s*$')) {
        if ($doc -match '(?m)^kind:\s*Service\s*$' -and $doc -match '(?m)^metadata:\s*\r?\n(?:[ \t]+.*\r?\n)*?[ \t]{2}name:\s*["'']?([^"''\s]+)') {
            $names += $Matches[1]
        }
    }
    return $names
}

function Publish-Route([string]$Release, [string]$Namespace) {
    Write-Step 'Checking routes'
    $services = @(Get-ReleaseServices $Release $Namespace)
    if ($services.Count -eq 0) { Write-Info 'The release has no services, so no route is needed.'; return @() }

    $routes = Get-OcJson @('get', 'route', '-n', $Namespace)
    $matching = @()
    if ($routes) { $matching = @($routes.items | Where-Object { $services -contains $_.spec.to.name }) }

    if ($matching.Count -eq 0 -and $ExposeRoute) {
        $svc = $ServiceToExpose
        if (-not $svc) { $svc = $services[0] }
        Write-Info "Creating an HTTPS route for service $svc..."
        Invoke-Native oc @('create', 'route', 'edge', $svc, "--service=$svc", '--insecure-policy=Redirect', '-n', $Namespace) -Label 'oc create route' | Out-Null
        $matching = @(Get-OcJson @('get', 'route', $svc, '-n', $Namespace))
    }

    $urls = @()
    foreach ($r in $matching) {
        $scheme = 'http'
        if ($r.spec.tls) { $scheme = 'https' }
        $urls += "${scheme}://$($r.spec.host)$($r.spec.path)"
    }
    return $urls
}

# ---------------------------------------------------------------- main

try {
    Write-Host 'OpenShift image + Helm deploy' -ForegroundColor Green
    Assert-Tools

    $ImageArchive = Read-Value 'ImageArchive' $ImageArchive 'Path to the image archive (.tar or .tar.gz)'
    if (-not (Test-Path $ImageArchive -PathType Leaf)) { throw "Image archive not found: $ImageArchive" }
    $ImageArchive = (Resolve-Path $ImageArchive).Path

    $ChartPath = Read-Value 'ChartPath' $ChartPath 'Path to the Helm chart (folder or .tgz)'
    if (-not (Test-Path $ChartPath)) { throw "Helm chart not found: $ChartPath" }
    $ChartPath = (Resolve-Path $ChartPath).Path
    if ($ValuesFile -and -not (Test-Path $ValuesFile)) { throw "Values file not found: $ValuesFile" }

    Write-Step 'Reading the image archive'
    $archive = Get-ArchiveInfo $ImageArchive
    $nameFromArchive, $tagFromArchive = Split-RepoTag $archive.RepoTag
    Write-Info "Format: $($archive.Format)$(if ($archive.RepoTag) { ", image: $($archive.RepoTag)" })"
    if ($archive.Format -eq 'oci-archive' -and $PushMethod -eq 'Crane') {
        Write-Warn 'OCI archives need the InCluster push method. Switching to it.'
        $PushMethod = 'InCluster'
    }

    Connect-Cluster
    $currentProject = $null
    $projectCheck = Invoke-Native oc @('project', '-q') -AllowFail
    if ($projectCheck.Code -eq 0) { $currentProject = $projectCheck.Output }
    $Project = Read-Value 'Project' $Project 'OpenShift project' $currentProject
    Select-Project $Project

    $defaultName = $nameFromArchive
    if (-not $defaultName) { $defaultName = ([IO.Path]::GetFileName($ImageArchive) -replace '\.(tar\.gz|tgz|tar)$', '').ToLower() }
    $defaultTag = $tagFromArchive
    if (-not $defaultTag) { $defaultTag = 'latest' }
    $AppName = Read-Value 'AppName' $AppName 'Image name in OpenShift' $defaultName
    $ImageTag = Read-Value 'ImageTag' $ImageTag 'Image tag' $defaultTag
    if (-not $ReleaseName) { $ReleaseName = $AppName }
    $target = "$Project/${AppName}:$ImageTag"

    Write-Step "Pushing the image as $target ($PushMethod)"
    switch ($PushMethod) {
        'Crane'     { Push-WithCrane $ImageArchive $archive.Format $target }
        'InCluster' { Push-InCluster $ImageArchive $archive.Format $target $Project }
        'Auto' {
            $pushed = $false
            if ($archive.Format -eq 'docker-archive') {
                try { Push-WithCrane $ImageArchive $archive.Format $target; $pushed = $true }
                catch { Write-Warn "crane push failed: $($_.Exception.Message)"; Write-Info 'Falling back to pushing from inside the cluster...' }
            }
            if (-not $pushed) { Push-InCluster $ImageArchive $archive.Format $target $Project }
        }
    }

    $istag = Invoke-Native oc @('get', 'istag', "${AppName}:$ImageTag", '-n', $Project) -AllowFail
    if ($istag.Code -ne 0) { throw "The push finished but image stream tag ${AppName}:$ImageTag was not found in $Project." }
    Write-Info "Image is in the registry: $InternalRegistry/$target"

    Install-Chart -Chart $ChartPath -Release $ReleaseName -Namespace $Project -Repository "$InternalRegistry/$Project/$AppName" -Tag $ImageTag
    $urls = @(Publish-Route $ReleaseName $Project)

    Write-Host "`nDone." -ForegroundColor Green
    Write-Info "Project: $Project"
    Write-Info "Release: $ReleaseName"
    Write-Info "Image:   $InternalRegistry/$target"
    foreach ($u in $urls) { Write-Info "URL:     $u" }
    exit 0
}
catch {
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    foreach ($f in $TempFiles) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
}
