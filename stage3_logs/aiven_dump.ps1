# Step 1 of the Aiven copy: three consistent dumps of the LOCAL sandbox (root password typed at each prompt).
# Output goes to backups\aiven\ (git-ignored). Reads only; changes nothing in MySQL.
$ErrorActionPreference = "Stop"
$bin = "C:\Program Files\MySQL\MySQL Server 8.0\bin"
$db = "college_complaints_v2_dev"
$stamp = Get-Date -Format yyyyMMdd_HHmmss
New-Item -ItemType Directory -Force backups\aiven | Out-Null
$common = @("-u", "root", "-p", "--single-transaction", "--no-tablespaces", "--set-gtid-purged=OFF", "--default-character-set=utf8mb4", "--hex-blob")

$parts = @(
  @{ name = "data";     args = @("--skip-triggers") },                                       # tables + data + views
  @{ name = "routines"; args = @("--no-data", "--no-create-info", "--skip-triggers", "--routines") },
  @{ name = "triggers"; args = @("--no-data", "--no-create-info", "--triggers") }
)
foreach ($p in $parts) {
  $out = "backups\aiven\$($p.name)_$stamp.sql"
  if (Test-Path $out) { throw "exists: $out" }
  Write-Host "== dumping $($p.name) (enter ROOT password) =="
  & "$bin\mysqldump.exe" @common @($p.args) "--result-file=$out" $db
  if ($LASTEXITCODE -ne 0) { throw "mysqldump $($p.name) failed" }
  Write-Host ("   {0}  {1} bytes  sha256={2}" -f $out, (Get-Item $out).Length, (Get-FileHash $out -Algorithm SHA256).Hash)
}
"DONE stamp=$stamp"
