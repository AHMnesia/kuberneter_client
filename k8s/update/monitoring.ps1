# monitoring.ps1

param(
    [switch]$All,
    [string[]]$Components,
    [string]$DashboardSource,
    [switch]$NonInteractive
)

Write-Host "=== Monitoring Maintenance ===" -ForegroundColor Green

function Test-KubeAccess {
    try {
        kubectl cluster-info | Out-Null
        return $true
    } catch {
        Write-Host "Error: Kubernetes cluster not accessible." -ForegroundColor Red
        return $false
    }
}

function Ensure-NamespaceMonitoring {
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - | Out-Null
}

function Restart-Workload {
    param(
        [Parameter(Mandatory)] [ValidateSet('deployment','daemonset','statefulset')] [string]$Kind,
        [Parameter(Mandatory)] [string]$Name,
        [string]$Namespace = 'monitoring'
    )
    Write-Host "- Restarting $Kind/$Name in namespace $Namespace" -ForegroundColor Yellow
    kubectl rollout restart $Kind/$Name -n $Namespace
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Warning: Failed to trigger restart for $Kind/$Name" -ForegroundColor Yellow
        return
    }
    $statusKind = $Kind
    $rolloutResult = kubectl rollout status $statusKind/$Name -n $Namespace --timeout=180s
    if ($LASTEXITCODE -ne 0 -and $Name -eq 'prometheus') {
        Write-Host "  Rollout timeout pada Prometheus. Melakukan scale down ke 0 dan up ke 1 untuk recovery PVC..." -ForegroundColor Red
        kubectl scale deployment/prometheus -n $Namespace --replicas=0
        Write-Host "  Deployment Prometheus di-scale down ke 0. Menunggu sampai semua pod hilang (maks 60 detik)..." -ForegroundColor Yellow
        $timeout = 60
        $elapsed = 0
        while ($true) {
            $podsLeft = kubectl get pods -n $Namespace -l app=prometheus -o jsonpath='{.items[*].metadata.name}'
            if (-not $podsLeft) { break }
            if ($elapsed -ge $timeout) {
                Write-Host "  Timeout: Masih ada pod Prometheus setelah 60 detik." -ForegroundColor Red
                break
            }
            Write-Host "    Menunggu pod Prometheus hilang... ($elapsed detik)" -ForegroundColor Gray
            Start-Sleep -Seconds 5
            $elapsed += 5
        }
        kubectl scale deployment/prometheus -n $Namespace --replicas=1
        Write-Host "  Deployment Prometheus di-scale up ke 1. Menunggu sampai pod Running (maks 20 detik)..." -ForegroundColor Yellow
        $timeoutUp = 20
        $elapsedUp = 0
        while ($true) {
            $newPod = kubectl get pods -n $Namespace -l app=prometheus -o jsonpath='{.items[0].metadata.name}'
            if ($newPod) {
                $phase = kubectl get pod $newPod -n $Namespace -o jsonpath='{.status.phase}'
                if ($phase -eq 'Running') { break }
            }
            if ($elapsedUp -ge $timeoutUp) {
                Write-Host "  Timeout: Pod Prometheus belum Running setelah 20 detik." -ForegroundColor Red
                break
            }
            Write-Host "    Menunggu pod Prometheus Running... ($elapsedUp detik)" -ForegroundColor Gray
            Start-Sleep -Seconds 5
            $elapsedUp += 5
        }
        $status = kubectl get pod $newPod -n $Namespace
        Write-Host "  Status pod Prometheus setelah scale up:" -ForegroundColor Cyan
        Write-Host $status
        $logs = kubectl logs $newPod -n $Namespace --tail=30
        Write-Host "  Log pod Prometheus (tail 30):" -ForegroundColor Gray
        Write-Host $logs
    }
}

function Apply-MonitoringStack {
    $root = Split-Path $PSScriptRoot -Parent
    $mon = Join-Path $root 'monitoring'
    Ensure-NamespaceMonitoring
    Write-Host "Applying monitoring manifests..." -ForegroundColor Yellow
    @(
        'rbac.yaml',
        'pvc.yaml',
        'configmap.yaml',
        'deployment.yaml',
        'service.yaml'
    ) | ForEach-Object {
        $f = Join-Path $mon $_
        if (Test-Path $f) {
            kubectl apply -f $f
        }
    }
    Update-GrafanaDashboards -SourcePath $null
}

function Update-GrafanaDashboards {
    param([string]$SourcePath)
    $root = Split-Path $PSScriptRoot -Parent
    $dashDir = Join-Path (Join-Path $root 'monitoring') 'dashboards'

    if (Test-Path $dashDir) {
        Write-Host "Recreating grafana-dashboards ConfigMap from repository folder: monitoring/dashboards (recursive)" -ForegroundColor Yellow
        kubectl delete configmap grafana-dashboards -n monitoring --ignore-not-found | Out-Null
        $files = Get-ChildItem -Path $dashDir -Recurse -File -Include *.json
        $fromFileArgs = $files | ForEach-Object { "--from-file=$($_.FullName)" }
        $cmd = "kubectl create configmap grafana-dashboards -n monitoring $($fromFileArgs -join ' ')"
        Invoke-Expression $cmd
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Error: Failed creating grafana-dashboards ConfigMap." -ForegroundColor Red
        } else {
            Write-Host "ConfigMap grafana-dashboards berhasil dibuat dari folder dashboards (termasuk subfolder)." -ForegroundColor Green
        }
        Restart-Workload -Kind 'deployment' -Name 'grafana' -Namespace 'monitoring'
    } else {
        Write-Host "Warning: Folder dashboards tidak ditemukan pada: $dashDir" -ForegroundColor Yellow
    }
}

if (-not (Test-KubeAccess)) { return }
Ensure-NamespaceMonitoring

# Membuat ulang ConfigMap grafana-dashboards dari folder dashboards
if (Test-Path "../monitoring/dashboards") {
    kubectl delete configmap grafana-dashboards -n monitoring --ignore-not-found | Out-Null
    $files = Get-ChildItem -Path "../monitoring/dashboards" -Recurse -File -Include *.json
    $fromFileArgs = $files | ForEach-Object { "--from-file=$($_.FullName)" }
    $cmd = "kubectl create configmap grafana-dashboards -n monitoring $($fromFileArgs -join ' ')"
    Invoke-Expression $cmd
    Write-Host "ConfigMap grafana-dashboards berhasil dibuat dari folder dashboards (termasuk subfolder)." -ForegroundColor Green
}

$available = @(
    @{ Key='prometheus'; Label='Restart Prometheus (deployment/prometheus)'; Kind='deployment'; Name='prometheus' },
    @{ Key='grafana'; Label='Restart Grafana (deployment/grafana)'; Kind='deployment'; Name='grafana' },
    @{ Key='loki'; Label='Restart Loki (deployment/loki)'; Kind='deployment'; Name='loki' },
    @{ Key='promtail'; Label='Restart Promtail (daemonset/promtail)'; Kind='daemonset'; Name='promtail' },
    @{ Key='alertmanager'; Label='Restart Alertmanager (deployment/alertmanager)'; Kind='deployment'; Name='alertmanager' },
    @{ Key='blackbox'; Label='Restart Blackbox Exporter (deployment/blackbox-exporter)'; Kind='deployment'; Name='blackbox-exporter' },
    @{ Key='nginx-exporter'; Label='Restart NGINX Exporter (deployment/nginx-exporter)'; Kind='deployment'; Name='nginx-exporter' },
    @{ Key='dashboards'; Label='Update Dashboards (copy new JSON -> recreate ConfigMap -> restart Grafana)'; Kind='custom'; Name='dashboards' }
)

$doAll = $All.IsPresent
$selectedKeys = @()

if (-not $doAll -and (-not $Components) -and (-not $NonInteractive)) {
    $labels = $available | ForEach-Object { $_.Label }
    Write-Host "Pilih komponen untuk di-restart (pisahkan dengan koma), atau ketik 'all' untuk semua:" -ForegroundColor Yellow
    $i = 1
    foreach ($l in $labels) { Write-Host ("  {0}. {1}" -f $i, $l) -ForegroundColor Gray; $i++ }
    $choice = Read-Host "Masukkan nomor pilihan (contoh: 1,2,8) atau 'all'"
    if ($choice -match '^(all|ALL)$') {
        $doAll = $true
    } else {
        $indexes = $choice -split ',' | ForEach-Object { ($_ -as [int]) } | Where-Object { $_ -ge 1 -and $_ -le $available.Count }
        $selectedKeys = $indexes | ForEach-Object { $available[$_-1].Key }
    }
} elseif ($Components) {
    $selectedKeys = $Components
}

if ($doAll) {
    Write-Host "Mode: All (Redeploy monitoring stack)" -ForegroundColor Green
    $allPods = kubectl get pods -n monitoring -o jsonpath='{.items[*].metadata.name}'
    if ($allPods) {
        Write-Host "Force delete semua pod di namespace monitoring..." -ForegroundColor Red
        $allPodsArr = $allPods -split ' '
        foreach ($p in $allPodsArr) {
            kubectl delete pod $p -n monitoring --force --grace-period=0
            Write-Host "  Pod $p dihapus paksa." -ForegroundColor Yellow
        }
        Write-Host "Menunggu 10 detik setelah force delete semua pod..." -ForegroundColor Yellow
        Start-Sleep -Seconds 10
    }
    Apply-MonitoringStack
} else {
    if (-not $selectedKeys -or $selectedKeys.Count -eq 0) {
        Write-Host "No components selected. Exiting." -ForegroundColor Yellow
        return
    }
    foreach ($key in $selectedKeys) {
        $item = $available | Where-Object { $_.Key -eq $key }
        if (-not $item) { continue }
        if ($item.Kind -eq 'custom' -and $item.Name -eq 'dashboards') {
            Update-GrafanaDashboards -SourcePath $null
        } else {
            Restart-Workload -Kind $item.Kind -Name $item.Name -Namespace 'monitoring'
        }
    }
}

Write-Host "=== Done ===" -ForegroundColor Green