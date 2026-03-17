# Full project run script for aio2025-mlops-project01
# Usage: powershell -ExecutionPolicy Bypass -File .\run_full_project.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Info($msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Warn($msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Err($msg) { Write-Host "[ERROR] $msg" -ForegroundColor Red }

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

# 1) Start docker services
function Start-DockerPlatformServices {
    Info "Starting Docker platform services"

    $dockerRoot = "$root\infra\docker"
    if (-Not (Test-Path $dockerRoot)) {
        Err "Expected docker directory not found: $dockerRoot"
        exit 1
    }

    # Use docker compose directly so this works in PowerShell on Windows.
    # (This avoids relying on WSL/bash, which may not be installed.)
    $services = @("mlflow", "kafka", "monitor", "airflow")
    foreach ($service in $services) {
        $serviceDir = Join-Path $dockerRoot $service
        $composeFile = Join-Path $serviceDir "docker-compose.yaml"
        if (-Not (Test-Path $composeFile)) {
            Warn "Service compose file not found: $composeFile"
            continue
        }

        Info "Starting service: $service"
        Push-Location $serviceDir
        docker compose up -d
        docker compose ps
        Pop-Location
    }
}

Start-DockerPlatformServices

# 2) Install Python dependencies for data-pipeline
Info "Installing Python dependencies for data-pipeline"
Set-Location "$root\data-pipeline"
try {
    python -m pip install --upgrade pip setuptools wheel
    python -m pip install -r requirements.txt
    python -m pip install hiredis dvc-s3 redis feast[redis]
} catch {
    Warn "Python dependency install exited with errors; some packages may already be installed or require build tools. Continuing anyway."
    Write-Host $_.Exception.Message
}

function Create-LocalSampleData {
    Info "Generating local sample processed data because DVC data is missing or pull failed"
    Set-Location "$root\data-pipeline"
    python -c "import pandas as pd, numpy as np, os; os.makedirs('data/processed', exist_ok=True); df=pd.DataFrame({'CustomerID':range(1,101),'Age':np.random.randint(20,70,100),'Gender':np.random.choice(['M','F'],100),'Tenure':np.random.randint(1,36,100),'Usage Frequency':np.random.randint(1,50,100),'Support Calls':np.random.randint(0,15,100),'Payment Delay':np.random.randint(0,30,100),'Subscription Type':np.random.choice(['Basic','Premium'],100),'Contract Length':np.random.choice(['month','year'],100),'Total Spend':np.random.randint(100,2000,100),'Last Interaction':np.random.randint(0,60,100),'Churn':np.random.choice([0,1],100),'Tenure_Age_Ratio':np.random.rand(100),'Spend_per_Usage':np.random.rand(100),'Support_Calls_per_Tenure':np.random.rand(100)}); df.to_csv('data/processed/df_processed.csv', index=False); print('OK')"
}

# 3) Pull DVC data
Info "Pulling DVC data artifacts"
$hasProcessed = Test-Path "$root\data-pipeline\churn_feature_store\churn_features\feature_repo\data\processed_churn_data.parquet"
try {
    python -m dvc pull
    $hasProcessed = Test-Path "$root\data-pipeline\churn_feature_store\churn_features\feature_repo\data\processed_churn_data.parquet"
} catch {
    Warn "DVC pull failed. Generating local sample processed data instead."
    Write-Host $_.Exception.Message
}

if (-not $hasProcessed) {
    Create-LocalSampleData
    Set-Location "$root\data-pipeline\churn_feature_store\churn_features\feature_repo"
    python prepare_feast_data.py
}

# 4) Feast apply
Info "Applying Feast feature repo"
Set-Location "$root\data-pipeline\churn_feature_store\churn_features\feature_repo"
python -c "from feast.cli.cli import cli; import sys; sys.argv=['feast','apply']; cli()"

function Ensure-RedisRunning {
    Info "Ensuring Redis (redis-feast) is running for Feast online store"

    # Check if container exists
    $containerInfo = docker ps -a --filter "name=redis-feast" --format "{{.Names}}|{{.Status}}" | Select-Object -First 1

    if (-not $containerInfo) {
        Info "Redis container not found, creating and starting..."
        docker run -d -p 6379:6379 --name redis-feast redis:7 | Out-Null
        return
    }

    $parts = $containerInfo -split '\|', 2
    $status = $parts[1]

    if ($status -like 'Up*') {
        Info "Redis container is already running."
    } elseif ($status -like 'Exited*' -or $status -like 'Created*') {
        Info "Redis container is present but not running; starting it..."
        docker start redis-feast | Out-Null
    } else {
        Warn "Redis container has unexpected status: $status. Attempting to start anyway."
        docker start redis-feast | Out-Null
    }
}

# 5) Start redis for Feast online store
Ensure-RedisRunning

# 6) Materialize Feast features
Info "Materializing incremental features"
$ts = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
python -c "from feast.cli.cli import cli; import sys; sys.argv=['feast','materialize-incremental','$ts']; cli()"

# 7) Run sample retrieval
Info "Running sample retrieval script"
Set-Location "$root\data-pipeline"
python scripts/sample_retrieval.py

Info "Full project run completed. Open Airflow: http://localhost:8080, MLflow: http://localhost:5000, Grafana: http://localhost:3000 , MinIO: http://localhost:9000, Prometheus: http://localhost:9090"