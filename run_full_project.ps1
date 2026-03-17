# Full project run script for aio2025-mlops-project01
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\run_full_project.ps1
# Optional flags:
#   -SkipDeps -SkipData -SkipTrain -SkipServing -ForceRecreate

param(
    [switch]$SkipDeps,
    [switch]$SkipData,
    [switch]$SkipTrain,
    [switch]$SkipServing,
    [switch]$ForceRecreate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Info($msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Warn($msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Err($msg) { Write-Host "[ERROR] $msg" -ForegroundColor Red }

$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

function Ensure-DockerNetwork {
    $netName = "aio-network"
    $exists = docker network ls --format "{{.Name}}" | Where-Object { $_ -eq $netName } | Select-Object -First 1
    if (-not $exists) {
        Info "Creating Docker network '$netName'"
        docker network create $netName | Out-Null
    }
}

function Compose-Up {
    param(
        [Parameter(Mandatory = $true)][string]$ComposeFile
    )

    if (-not (Test-Path $ComposeFile)) {
        Warn "Compose file missing: $ComposeFile"
        return
    }

    $dir = Split-Path -Parent $ComposeFile
    $recreateFlag = if ($ForceRecreate) { "--force-recreate" } else { "" }

    # Use --project-directory so `.env` in the compose folder is loaded reliably.
    docker compose --project-directory $dir -f $ComposeFile up -d $recreateFlag
    docker compose --project-directory $dir -f $ComposeFile ps
}

function Start-DockerServices {
    Info "Starting core Docker services (MLflow, Airflow, Kafka, Monitoring, MinIO)"
    # Keep MLflow/MinIO fully local (S3-compatible MinIO), not real AWS.
    $env:AWS_ACCESS_KEY_ID = "minio"
    $env:AWS_SECRET_ACCESS_KEY = "minio123"
    $env:AWS_DEFAULT_REGION = "us-east-1"
    Ensure-DockerNetwork
    Compose-Up "$root\infra\docker\mlflow\docker-compose.yaml"
    Compose-Up "$root\infra\docker\airflow\docker-compose.yaml"
    Compose-Up "$root\infra\docker\kafka\docker-compose.yaml"
    Compose-Up "$root\infra\docker\monitor\docker-compose.yaml"
}

function Ensure-Redis {
    Info "Ensure Feast Redis online store is running"
    $container = docker ps -a --filter "name=redis-feast" --format "{{.Names}}" | Select-Object -First 1
    if (-not $container) {
        docker run -d -p 6379:6379 --name redis-feast redis:7 | Out-Null
    } else {
        docker start redis-feast | Out-Null
    }
}

function Install-Dependencies {
    Info "Installing Python dependencies for data-pipeline, model-pipeline, serving"
    Set-Location "$root\data-pipeline"
    python -m pip install --upgrade pip setuptools wheel
    python -m pip install -r requirements.txt

    Set-Location "$root\serving_pipeline"
    python -m pip install -r requirements.txt
}

function Prepare-Data {
    Info "Preparing data and features via DVC + Feast"
    Set-Location "$root\data-pipeline"
    try {
        python -m dvc pull
    } catch {
        Warn "DVC pull failed. Will generate sample data if missing."
    }

    $processedFile = "$root\data-pipeline\churn_feature_store\churn_features\feature_repo\data\processed_churn_data.parquet"
    if (-Not (Test-Path $processedFile)) {
        Info "Processed data missing, generating sample data..."
        python -c "import pandas as pd, numpy as np, os; os.makedirs('churn_feature_store/churn_features/feature_repo/data', exist_ok=True); df=pd.DataFrame({'customer_id':range(1,101),'age':np.random.randint(18,70,100),'gender':np.random.choice(['M','F'],100),'tenure_months':np.random.randint(1,60,100),'usage_frequency':np.random.randint(1,100,100),'support_calls':np.random.randint(0,15,100),'payment_delay_days':np.random.randint(0,30,100),'subscription_type':np.random.choice(['Basic','Premium','Pro'],100),'contract_length':np.random.randint(1,36,100),'total_spend':np.random.rand(100)*2000,'last_interaction_days':np.random.randint(0,90,100),'churned':np.random.choice([0,1],100)}); df.to_parquet('churn_feature_store/churn_features/feature_repo/data/processed_churn_data.parquet', index=False)"
    }

    Set-Location "$root\data-pipeline\churn_feature_store\churn_features\feature_repo"
    python -c "from feast.cli.cli import cli; import sys; sys.argv=['feast','apply']; cli()"
    Ensure-Redis
    $ts = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    python -c "from feast.cli.cli import cli; import sys; sys.argv=['feast','materialize-incremental','$ts']; cli()"
}

function Train-Model {
    Info "Training model with model_pipeline"
    Set-Location "$root\model_pipeline"
    $env:PYTHONPATH = "$root\model_pipeline"
    python .\src\scripts\train.py --config .\src\config\logistic_regression.yaml --training-data-path "$root\data-pipeline\churn_feature_store\churn_features\feature_repo\data\processed_churn_data.parquet" --run-name "run_$(Get-Date -Format yyyyMMdd_HHmmss)"
}

function Start-Serving {
    Info "Starting serving pipeline (FastAPI + Gradio)"
    Set-Location "$root\serving_pipeline"
    if (-Not (Test-Path ".env")) {
        if (Test-Path ".env.example") {
            Info "Creating serving_pipeline/.env from .env.example"
            Copy-Item ".env.example" ".env"
        } else {
            Warn "serving_pipeline/.env and .env.example are missing; docker compose will start with blank env vars."
        }
    }
    docker compose up -d $(if ($ForceRecreate) { "--force-recreate" } else { "" })
    Info "Serving started: http://localhost:8000 and UI http://localhost:7860"
}

# Main flow
Start-DockerServices
if (-not $SkipDeps) { Install-Dependencies } else { Warn "SkipDeps enabled - not installing Python deps" }
if (-not $SkipData) { Prepare-Data } else { Warn "SkipData enabled - not preparing data/features" }
if (-not $SkipTrain) { Train-Model } else { Warn "SkipTrain enabled - not training model" }
if (-not $SkipServing) { Start-Serving } else { Warn "SkipServing enabled - not starting serving" }

Info "Run complete. Check: MLflow http://localhost:5000, Airflow http://localhost:8080, Grafana http://localhost:3000, MinIO http://localhost:9000"