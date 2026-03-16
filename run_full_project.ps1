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
Info "Starting Docker platform services (infra/docker/run.sh up)"
Set-Location "$root\infra\docker"
if (-Not (Test-Path .\run.sh)) { Err "run.sh not found in infra/docker"; exit 1 }
bash .\run.sh down
bash .\run.sh up
bash .\run.sh status

# 2) Install Python dependencies for data-pipeline
Info "Installing Python dependencies for data-pipeline"
Set-Location "$root\data-pipeline"
python -m pip install --upgrade pip setuptools wheel
python -m pip install -r requirements.txt
python -m pip install hiredis dvc-s3 redis feast[redis]

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

# 5) Start redis for Feast online store
Info "Starting Redis for Feast online store"
try {
    docker run -d -p 6379:6379 --name redis-feast redis:7 | Out-Null
} catch {
    Warn "Redis container may already exist or failed; continue."
}

# 6) Materialize Feast features
Info "Materializing incremental features"
$ts = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
python -c "from feast.cli.cli import cli; import sys; sys.argv=['feast','materialize-incremental','$ts']; cli()"

# 7) Run sample retrieval
Info "Running sample retrieval script"
Set-Location "$root\data-pipeline"
python scripts/sample_retrieval.py

Info "Full project run completed. Open Airflow: http://localhost:8080, MLflow: http://localhost:5000, Grafana: http://localhost:3000"