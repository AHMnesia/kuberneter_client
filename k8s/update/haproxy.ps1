# haproxy.ps1

param(
    [string]$Namespace = 'haproxy',
    [string]$DeploymentName = 'haproxy',
    [switch]$NonInteractive
)

Write-Host "=== HAProxy Maintenance ===" -ForegroundColor Green

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
    try {
        kubectl create namespace $Name --dry-run=client -o yaml | kubectl apply -f - | Out-Null
    } catch {
        Write-Host "Error: Gagal membuat namespace $Name." -ForegroundColor Red
        exit 1
    }
}

function Apply-HaproxyStack {
    param([string]$Ns)
    Ensure-Namespace -Name $Ns
    $k8sRoot = Split-Path $PSScriptRoot -Parent
    $haproxyDir = Join-Path $k8sRoot 'haproxy'
    if (-not (Test-Path $haproxyDir)) {
        Write-Host "Warning: Folder HAProxy tidak ditemukan: $haproxyDir" -ForegroundColor Yellow
        return
    }
    Write-Host "Applying HAProxy manifests..." -ForegroundColor Yellow
    @('namespace.yaml','configmap.yaml','service.yaml','deployment.yaml') | ForEach-Object {
        $f = Join-Path $haproxyDir $_
        if (Test-Path $f) { kubectl apply -f $f }
    }
}

function Restart-HaproxyDeployment {
    param([string]$Ns, [string]$Name)
    $exists = kubectl get deployment $Name -n $Ns --ignore-not-found
    if (-not $exists) {
        Write-Host "Deployment/$Name belum ada di namespace $Ns, skip restart." -ForegroundColor Yellow
        return
    }
    Write-Host "- Restarting deployment/$Name in namespace $Ns" -ForegroundColor Yellow
    kubectl rollout restart deployment/$Name -n $Ns
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Warning: Failed to trigger restart for deployment/$Name" -ForegroundColor Yellow
        return
    }
    kubectl rollout status deployment/$Name -n $Ns --timeout=180s
}

if (-not (Test-KubeAccess)) { return }
Ensure-Namespace -Name $Namespace

Write-Host "Mode: Full update HAProxy (Apply manifests + Restart)" -ForegroundColor Green
Apply-HaproxyStack -Ns $Namespace
Restart-HaproxyDeployment -Ns $Namespace -Name $DeploymentName

Write-Host "=== Done ===" -ForegroundColor Green