param(
    [switch]$RestartNginx,
    [switch]$UpdateSSL,
    [string[]]$Domains,
    [switch]$RestartAfterUpdate,
    [string]$Namespace = 'nginx-system',
    [string]$DeploymentName = 'nginx-proxy',
    [switch]$NonInteractive
)

Write-Host "=== NGINX Maintenance ===" -ForegroundColor Green

function Test-KubeAccess {
    try {
        kubectl cluster-info | Out-Null
        return $true
    } catch {
        Write-Host "Error: Kubernetes cluster not accessible." -ForegroundColor Red
        return $false
    }
}

function Ensure-Namespace {
    param([string]$Name)
    kubectl create namespace $Name --dry-run=client -o yaml | kubectl apply -f - | Out-Null
}

function Restart-NginxDeployment {
    param([string]$Ns, [string]$Name)
    Write-Host "- Restarting deployment/$Name in namespace $Ns" -ForegroundColor Yellow
    kubectl rollout restart deployment/$Name -n $Ns
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Warning: Failed to trigger restart for deployment/$Name" -ForegroundColor Yellow
        return
    }
    kubectl rollout status deployment/$Name -n $Ns --timeout=180s
}

function Apply-NginxStack {
    param([string]$Ns)
    Ensure-Namespace -Name $Ns
    $k8sRoot = Split-Path $PSScriptRoot -Parent
    $nginxDir = Join-Path $k8sRoot 'nginx'
    if (-not (Test-Path $nginxDir)) {
        Write-Host "Warning: Folder NGINX tidak ditemukan: $nginxDir" -ForegroundColor Yellow
        return
    }
    Write-Host "Applying NGINX manifests..." -ForegroundColor Yellow
    @('namespace.yaml','rbac.yaml','configmap.yaml','service.yaml','deployment.yaml') | ForEach-Object {
        $f = Join-Path $nginxDir $_
        if (Test-Path $f) { kubectl apply -f $f }
    }
}

function Get-WorkspaceAndSslPath {
    $k8sRoot = Split-Path $PSScriptRoot -Parent
    $workspaceRoot = Split-Path $k8sRoot -Parent
    $sslRoot = Join-Path $workspaceRoot 'ssl'
    return @{
        Workspace=$workspaceRoot; K8s=$k8sRoot; Ssl=$sslRoot
    }
}

function Get-SecretNameFromDomainFolder {
    param([string]$FolderName)
    $lower = $FolderName.ToLower()
    if ($lower -eq 'localhost') { return 'localhost-ssl' }
    $dash = $lower -replace '\.', '-' -replace '[^a-z0-9-]', '-'
    return "$dash-ssl"
}

function Update-SSLSecrets {
    param(
        [string]$Ns,
        [string[]]$DomainFolders,
        [string]$CertFileName = 'certificate.crt',
        [string]$KeyFileName = 'certificate.key'
    )
    $paths = Get-WorkspaceAndSslPath
    $sslRoot = $paths.Ssl

    if (-not (Test-Path $sslRoot)) {
        Write-Host "Error: Folder SSL tidak ditemukan: $sslRoot" -ForegroundColor Red
        return
    }

    $targets = @()
    if ($DomainFolders -and $DomainFolders.Count -gt 0) {
        $targets = $DomainFolders
    } else {
        $targets = Get-ChildItem -Path $sslRoot -Directory | Select-Object -ExpandProperty Name
    }

    if (-not $targets -or $targets.Count -eq 0) {
        Write-Host "Tidak ada folder domain SSL yang ditemukan di: $sslRoot" -ForegroundColor Yellow
        return
    }

    foreach ($domain in $targets) {
        $domainPath = Join-Path $sslRoot $domain
        $crt = Join-Path $domainPath $CertFileName
        $key = Join-Path $domainPath $KeyFileName
        if (-not (Test-Path $crt) -or -not (Test-Path $key)) {
            Write-Host "Lewati: $domain (file $CertFileName / $KeyFileName tidak ditemukan)" -ForegroundColor DarkYellow
            continue
        }
        $secretName = Get-SecretNameFromDomainFolder -FolderName $domain
        Write-Host "- Update TLS secret: $secretName (domain: $domain)" -ForegroundColor Cyan
        kubectl delete secret $secretName -n $Ns --ignore-not-found | Out-Null
        kubectl create secret tls $secretName --cert="$crt" --key="$key" -n $Ns
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  Error: Gagal membuat secret $secretName" -ForegroundColor Red
        } else {
            Write-Host "  OK: Secret $secretName diperbarui." -ForegroundColor Green
        }
    }
}

if (-not (Test-KubeAccess)) { return }
Ensure-Namespace -Name $Namespace

Write-Host "Mode: Full update NGINX (Apply manifests + Update SSL + Restart)" -ForegroundColor Green
Apply-NginxStack -Ns $Namespace
Update-SSLSecrets -Ns $Namespace -DomainFolders $Domains
Write-Host ("Restarting NGINX... (deployment/{0}, ns: {1})" -f $DeploymentName, $Namespace) -ForegroundColor Yellow
Restart-NginxDeployment -Ns $Namespace -Name $DeploymentName

Write-Host "=== Done ===" -ForegroundColor Green