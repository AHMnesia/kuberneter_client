param(
    [string]$VERSION = 'v1.0.0'
)

# ===== Build images (services only) =====
Write-Host "=== Building Docker Images ===" -ForegroundColor Green

$root = Split-Path $PSScriptRoot -Parent
$officeDir = Join-Path $root 'suma-office'
$clientDir = Join-Path $root 'suma-ecommerce-client'
$adminDir = Join-Path $root 'suma-ecommerce-admin'

if (Test-Path $officeDir) {
    Write-Host "1. Building Suma Office..." -ForegroundColor Yellow
    Push-Location $officeDir
    docker build -t "suma-office:${VERSION}" -f dockerfile.web .
    if ($LASTEXITCODE -ne 0) { Write-Host "Error building suma-office" -ForegroundColor Red; Pop-Location; exit 1 }
    docker tag "suma-office:${VERSION}" "suma-office:latest"
    Pop-Location
} else {
    Write-Host "Warning: Folder tidak ditemukan: $officeDir" -ForegroundColor Yellow
}

if (Test-Path $clientDir) {
    Write-Host "2. Building Suma Ecommerce Client..." -ForegroundColor Yellow
    Push-Location $clientDir
    docker build -t "suma-ecommerce-client:${VERSION}" -f dockerfile .
    if ($LASTEXITCODE -ne 0) { Write-Host "Error building suma-ecommerce-client" -ForegroundColor Red; Pop-Location; exit 1 }
    docker tag "suma-ecommerce-client:${VERSION}" "suma-ecommerce-client:latest"
    Pop-Location
} else {
    Write-Host "Warning: Folder tidak ditemukan: $clientDir" -ForegroundColor Yellow
}

if (Test-Path $adminDir) {
    Write-Host "3. Building Suma Ecommerce Admin..." -ForegroundColor Yellow
    Push-Location $adminDir
    docker build -t "suma-ecommerce-admin:${VERSION}" -f dockerfile .
    if ($LASTEXITCODE -ne 0) { Write-Host "Error building suma-ecommerce-admin" -ForegroundColor Red; Pop-Location; exit 1 }
    docker tag "suma-ecommerce-admin:${VERSION}" "suma-ecommerce-admin:latest"
    Pop-Location
} else {
    Write-Host "Warning: Folder tidak ditemukan: $adminDir" -ForegroundColor Yellow
}

Write-Host "=== Build Complete ===" -ForegroundColor Green
Write-Host "Built images:" -ForegroundColor Cyan
Write-Host "  - suma-ecommerce-client:${VERSION}" -ForegroundColor White
Write-Host "  - suma-ecommerce-admin:${VERSION}" -ForegroundColor White
Write-Host "  - suma-office:${VERSION}" -ForegroundColor White

# Ensure we are in k8s folder for relative paths below
Set-Location $PSScriptRoot

# ===== Continue with existing deployment steps =====
Write-Host "Starting Kubernetes Production Deployment..." -ForegroundColor Green
Write-Host "=================================" -ForegroundColor Gray

Write-Host "2. Creating namespaces..." -ForegroundColor Yellow
kubectl create namespace nginx-system --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace suma-office --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace suma-ecommerce-admin --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace suma-ecommerce-client --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace haproxy --dry-run=client -o yaml | kubectl apply -f -

Write-Host "3. Applying PDB, RBAC, and PVC..." -ForegroundColor Yellow
if (Test-Path "monitoring/pdb.yaml") { kubectl apply -f monitoring/pdb.yaml }
if (Test-Path "app-pdb.yaml") { kubectl apply -f app-pdb.yaml }
if (Test-Path "monitoring/rbac.yaml") { kubectl apply -f monitoring/rbac.yaml }
if (Test-Path "monitoring/pvc.yaml") { kubectl apply -f monitoring/pvc.yaml }

Write-Host "4. Creating SSL secrets..." -ForegroundColor Yellow
$sslRoot = Join-Path $PSScriptRoot '../ssl'
$sslFolders = Get-ChildItem -Path $sslRoot -Directory
foreach ($folder in $sslFolders) {
    $crt = Join-Path $folder.FullName 'certificate.crt'
    $key = Join-Path $folder.FullName 'certificate.key'
    $secretName = "$($folder.Name)-ssl"
    if ((Test-Path $crt) -and (Test-Path $key)) {
        kubectl create secret tls $secretName --cert=$crt --key=$key -n nginx-system --dry-run=client -o yaml | kubectl apply -f -
        if ($LASTEXITCODE -eq 0) {
            Write-Host "   [OK] $secretName created" -ForegroundColor Green
        } else {
            Write-Host "   [FAIL] Could not create $secretName." -ForegroundColor Yellow
        }
    } else {
        Write-Host "   [SKIP] SSL certificates not found for $($folder.Name). Please add them to $crt & $key" -ForegroundColor Yellow
    }
}

kubectl apply -f nginx/configmap.yaml

Write-Host "5. Creating ConfigMaps..." -ForegroundColor Yellow
if (Test-Path "monitoring/configmap.yaml") { kubectl apply -f monitoring/configmap.yaml }
# Membuat ConfigMap grafana-dashboards dari folder dashboards (recursive)
if (Test-Path "monitoring/dashboards") {
    kubectl delete configmap grafana-dashboards -n monitoring --ignore-not-found
    $files = Get-ChildItem -Path "monitoring/dashboards" -Recurse -File -Include *.json
    $fromFileArgs = $files | ForEach-Object { "--from-file=$($_.FullName)" }
    $cmd = "kubectl create configmap grafana-dashboards -n monitoring $($fromFileArgs -join ' ')"
    Invoke-Expression $cmd
    Write-Host "ConfigMap grafana-dashboards berhasil dibuat dari folder dashboards (termasuk subfolder)." -ForegroundColor Green
}

Write-Host "6. Deploying monitoring stack..." -ForegroundColor Yellow
if (Test-Path "monitoring/deployment.yaml") { kubectl apply -f monitoring/deployment.yaml }
if (Test-Path "monitoring/service.yaml") { kubectl apply -f monitoring/service.yaml }

Write-Host "7. Deploying HAProxy..." -ForegroundColor Yellow
if (Test-Path "haproxy/configmap.yaml") { kubectl apply -f haproxy/configmap.yaml }
if (Test-Path "haproxy/deployment.yaml") { kubectl apply -f haproxy/deployment.yaml }
if (Test-Path "haproxy/service.yaml") { kubectl apply -f haproxy/service.yaml }
if (Test-Path "haproxy/pdb.yaml") { kubectl apply -f haproxy/pdb.yaml }

Write-Host "8. Creating RBAC for NGINX..." -ForegroundColor Yellow
if (Test-Path "nginx/rbac.yaml") {
    kubectl apply -f nginx/rbac.yaml
}

Write-Host "9. Deploying NGINX..." -ForegroundColor Yellow
kubectl apply -f nginx/deployment.yaml
kubectl apply -f nginx/service.yaml

Write-Host "10. Deploying Suma Applications..." -ForegroundColor Yellow
kubectl apply -f suma-ecommerce-admin/deployment.yaml
kubectl apply -f suma-ecommerce-admin/service.yaml
kubectl apply -f suma-ecommerce-client/deployment.yaml
kubectl apply -f suma-ecommerce-client/service.yaml
kubectl apply -f suma-office/deployment.yaml
kubectl apply -f suma-office/service.yaml

Write-Host "11. Waiting for deployments to be ready..." -ForegroundColor Yellow
$namespaces = @("monitoring", "haproxy", "nginx-system", "suma-ecommerce-admin", "suma-ecommerce-client", "suma-office")
foreach ($ns in $namespaces) {
    Write-Host "   Waiting for deployments in namespace $ns..." -ForegroundColor Yellow
    kubectl wait --for=condition=available --timeout=120s deployment --all -n $ns
    if ($LASTEXITCODE -ne 0) {
        Write-Host "   [WARN] Some deployments in $ns are not ready. Showing pod status:" -ForegroundColor Red
        kubectl get pods -n $ns
    }
}

Write-Host "12. Checking pod status..." -ForegroundColor Yellow
foreach ($ns in $namespaces) {
    kubectl get pods -n $ns
}

Write-Host "13. Service endpoints..." -ForegroundColor Yellow
kubectl get services --all-namespaces

Write-Host "=============================================" -ForegroundColor Gray
Write-Host "  KUBERNETES DEPLOYMENT COMPLETED SUCCESSFULLY!" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Gray