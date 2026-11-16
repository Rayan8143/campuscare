# Fresh full backup of college_complaints_v2_dev before student activation. Root password is typed at the prompt.
$ErrorActionPreference = "Stop"
$bin = "C:\Program Files\MySQL\MySQL Server 8.0\bin"
$stamp = Get-Date -Format yyyyMMdd_HHmmss
$cp = "backups\stage2\admin_pre_activation_$stamp.sql"
if (Test-Path $cp) { throw "backup file already exists" }
& "$bin\mysqldump.exe" -u root -p --single-transaction --routines --triggers --events --no-tablespaces --set-gtid-purged=OFF --default-character-set=utf8mb4 --hex-blob "--result-file=$cp" college_complaints_v2_dev
if ($LASTEXITCODE -ne 0) { throw "mysqldump failed with exit $LASTEXITCODE" }
$h = (Get-FileHash $cp -Algorithm SHA256).Hash
Write-Host "BACKUP OK: $cp  size=$((Get-Item $cp).Length)  sha256=$h"
