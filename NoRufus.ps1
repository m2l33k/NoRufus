<#
.SYNOPSIS
    NoRufus - Install Linux from Windows without USB.
.DESCRIPTION
    This script sets up a Linux ISO to boot directly from the hard drive.
#>

param (
    [string]$SearchDir = $PWD
)

# Self-elevation to Administrator (Standard Method)
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow
    try {
        Start-Process powershell.exe -ArgumentList "-NoExit -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -SearchDir `"$SearchDir`"" -Verb RunAs
        Exit
    } catch {
        Write-Error "Failed to restart as Administrator. Please run this script as Administrator manually."
        Read-Host "Press Enter to exit..."
        Exit
    }
}

# Enable TLS 1.2 for downloads
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ErrorActionPreference = "Stop"

# Global Error Handler
trap {
    Write-Host "`n[!] An error occurred: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Location: $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
    Read-Host "Press Enter to exit..."
    Exit
}

# --- SECURE BOOT CHECK ---
try {
    $secureBootStatus = Confirm-SecureBootUEFI -ErrorAction SilentlyContinue
} catch {
    $secureBootStatus = $false # Assuming legacy or not readable
}

if ($secureBootStatus) {
    Clear-Host
    Write-Host "=======================================================" -ForegroundColor Red
    Write-Host "                SECURE BOOT DETECTED                   " -ForegroundColor Red
    Write-Host "=======================================================" -ForegroundColor Red
    Write-Host "You have Secure Boot ENABLED." -ForegroundColor Yellow
    Write-Host "Most Linux installers (and this tool) will FAIL with a" -ForegroundColor Yellow
    Write-Host "BLACK SCREEN or ERROR 0xc000007b if Secure Boot is on." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "You MUST disable Secure Boot in your BIOS/UEFI settings."
    Write-Host ""
    Write-Host "Options:"
    Write-Host "1. Reboot to BIOS now (Recommended)"
    Write-Host "2. Continue anyway (Will likely fail)"
    Write-Host "3. Exit"
    Write-Host ""
    
    $choice = Read-Host "Select an option (1-3)"
    
    switch ($choice) {
        "1" { 
            Write-Host "Rebooting to Firmware Setup..."
            shutdown /r /fw /t 0
            Exit
        }
        "2" { Write-Host "Continuing at your own risk..." -ForegroundColor Red }
        "3" { Exit }
        default { Exit }
    }
}
# -------------------------

$WorkDir = "C:\NoRufus"
$ISOPattern = "*.iso"

# 1. Find ISO
if ([string]::IsNullOrWhiteSpace($SearchDir)) {
    $SearchDir = $PWD
}

Write-Host "[*] Searching for Linux ISO in: $SearchDir"
$isoFile = Get-ChildItem -Path $SearchDir -Filter $ISOPattern | Select-Object -First 1

if (!$isoFile) {
    Write-Error "No ISO file found in directory ($SearchDir). Please place your Linux ISO there."
    Exit
}

Write-Host "    Found: $($isoFile.Name)"

# 2. Check for ISO Size and Prepare for Partitioning
    Write-Host "[*] Analyzing ISO Size..."
    $isoSize = $isoFile.Length
    $isoSizeGB = [math]::Ceiling($isoSize / 1GB) + 1 # Add 1GB buffer
    $partitionSizeMB = $isoSizeGB * 1024
    
    Write-Host "    Required Size: $isoSizeGB GB ($partitionSizeMB MB)"
    
    # Check if we already have the partition
    $existingPart = Get-Partition | Where-Object { $_.AccessPaths -like "*LINUX_INSTALL*" -or (Get-Volume -Partition $_ -ErrorAction SilentlyContinue).FileSystemLabel -eq "LINUX_INSTALL" }
    
    if ($existingPart) {
        Write-Host "    Found existing LINUX_INSTALL partition. Cleaning it up..."
        $targetDriveLetter = $existingPart.DriveLetter
        if (!$targetDriveLetter) {
            $targetDriveLetter = "L"
            Set-Partition -InputObject $existingPart -NewDriveLetter $targetDriveLetter
        }
        Format-Volume -DriveLetter $targetDriveLetter -FileSystem FAT32 -NewFileSystemLabel "LINUX_INSTALL" -Confirm:$false | Out-Null
    } else {
        # Shrink C: and Create New Partition
        Write-Host "[*] Shrinking C: drive to create installation partition..."
        $cPartition = Get-Partition -DriveLetter C
        $cSize = $cPartition.Size
        $newSize = $cSize - ($partitionSizeMB * 1MB)
        
        try {
            Resize-Partition -DriveLetter C -Size $newSize
        } catch {
            Write-Error "Failed to shrink C: drive. Ensure you have enough free space."
            Exit
        }
        
        Write-Host "    C: drive shrunk. Creating new partition..."
        $newPart = New-Partition -DiskNumber $cPartition.DiskNumber -UseMaximumSize -AssignDriveLetter
        Format-Volume -Partition $newPart -FileSystem FAT32 -NewFileSystemLabel "LINUX_INSTALL" -Confirm:$false | Out-Null
        $targetDriveLetter = $newPart.DriveLetter
    }
    
    Write-Host "    Installation Partition Ready: ${targetDriveLetter}:"
    
    # 3. Mount ISO and Copy ALL Files
    Write-Host "[*] Mounting ISO..."
    $mountResult = Mount-DiskImage -ImagePath $isoFile.FullName -PassThru
    $driveLetter = ($mountResult | Get-Volume).DriveLetter
    $drivePath = "${driveLetter}:"
    
    if (!$driveLetter) {
        Write-Error "Failed to mount ISO."
        Exit
    }
    
    Write-Host "[*] Copying ALL ISO files to ${targetDriveLetter}: (This may take a minute)..."
    Copy-Item -Path "$drivePath\*" -Destination "${targetDriveLetter}:\" -Recurse -Force
    
    # Dismount ISO
    Dismount-DiskImage -ImagePath $isoFile.FullName | Out-Null
    
    # 4. Setup Boot Entry
    # Now we boot from this new partition directly.
    # We need to find the bootloader on the new partition.
    
    $bootLoaderPath = "${targetDriveLetter}:\EFI\BOOT\BOOTx64.EFI"
    if (!(Test-Path $bootLoaderPath)) {
        # Try standard paths if not found
        $bootLoaderPath = "${targetDriveLetter}:\EFI\BOOT\grubx64.efi"
        if (!(Test-Path $bootLoaderPath)) {
             $bootLoaderPath = "${targetDriveLetter}:\EFI\BOOT\shimx64.efi"
        }
    }
    
    if (!(Test-Path $bootLoaderPath)) {
        Write-Error "Could not find a valid bootloader (EFI\BOOT\BOOTx64.EFI) on the extracted partition."
        Exit
    }
    
    Write-Host "    Found Bootloader: $bootLoaderPath"
    
    # Configure BCD
    Write-Host "[*] Configuring Windows Boot Manager..."
    
    # Delete old entry if exists
    bcdedit /enum firmware | Select-String "NoRufus" -Context 0, 5 | ForEach-Object {
        if ($_ -match '{([a-f0-9-]+)}') {
             bcdedit /delete $matches[1] /cleanup
        }
    }

    $bcdOutput = bcdedit /create /d "NoRufus Linux Installer" /application bootapp
    $id = $bcdOutput | Select-String '{[a-f0-9-]+}' -AllMatches | ForEach-Object { $_.Matches.Value }
    
    if (!$id) { Write-Error "Failed to create BCD entry."; Exit }
    
    Write-Host "    Created Entry ID: $id"
    
    # The path must be relative to the partition root, e.g., \EFI\BOOT\BOOTx64.EFI
    $relativePath = $bootLoaderPath.Substring(2) # Remove L:
    
    bcdedit /set $id path $relativePath
    bcdedit /set $id device "partition=${targetDriveLetter}:"
    bcdedit /displayorder $id /addlast
    
    Write-Host "-------------------------------------------------------"
    Write-Host "Success! Dedicated Install Partition Created."
    Write-Host "1. Reboot your computer."
    Write-Host "2. Select 'NoRufus Linux Installer'."
    Write-Host "3. It will boot EXACTLY like a USB stick."
    Write-Host "-------------------------------------------------------"
    Read-Host "Press Enter to exit..."
    Exit
