$ErrorActionPreference = "Stop"
Write-Host "== Fresh full backup (enter ROOT password) =="
powershell -ExecutionPolicy Bypass -File .\stage3_logs\backup_pre_activation.ps1
if ($LASTEXITCODE -ne 0) { throw "Backup failed; nothing else was run." }
python .\stage3_logs\issue_four_codes.py
Get-ChildItem activation_codes\*.activation-code | ForEach-Object { icacls $_.FullName }
