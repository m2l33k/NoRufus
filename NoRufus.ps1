<#
.SYNOPSIS
    NoRufus - Install Linux from Windows without USB.
.DESCRIPTION
    This script sets up a Linux ISO to boot directly from the hard drive.
#>

param (
    [string]$SearchDir = $PWD
)

# Self-elevation to Administrator
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow
    try {
        # Using -NoExit so the window stays open if there's an error
        Start-Process powershell.exe -ArgumentList "-NoExit -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -SearchDir `"$SearchDir`"" -Verb RunAs
        Exit
    } catch {
        Write-Error "Failed to restart as Administrator. Please run this script as Administrator manually."
        Read-Host "Press Enter to exit..."
        Exit
    }
}

# Enable TLS 1.2 for downloads (fixes issues on older Windows 10)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ErrorActionPreference = "Stop"

# Global Error Handler to keep window open on crash
trap {
    Write-Host "`n[!] An error occurred: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Location: $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
    Read-Host "Press Enter to exit..."
    Exit
}

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

# 2. Prepare Working Directory
if (Test-Path $WorkDir) {
    Write-Host "[*] Cleaning up existing directory $WorkDir..."
    Remove-Item -Path $WorkDir -Recurse -Force
}
New-Item -Path $WorkDir -ItemType Directory | Out-Null
Write-Host "[*] Working directory created: $WorkDir"

# 3. Copy ISO
Write-Host "[*] Copying ISO to working directory..."
Copy-Item -Path $isoFile.FullName -Destination "$WorkDir\install.iso"

# 4. Mount ISO and Extract Kernel/Initrd
Write-Host "[*] Mounting ISO..."
$mountResult = Mount-DiskImage -ImagePath "$WorkDir\install.iso" -PassThru
$driveLetter = ($mountResult | Get-Volume).DriveLetter

if (!$driveLetter) {
    Write-Error "Failed to mount ISO. Please ensure it is a valid ISO."
    Exit
}

$drivePath = "${driveLetter}:"
Write-Host "    Mounted at $drivePath"

# Try to find kernel and initrd
$kernel = Get-ChildItem -Path $drivePath -Recurse -Include "vmlinuz*", "vmlinuz" | Sort-Object Length -Descending | Select-Object -First 1
$initrd = Get-ChildItem -Path $drivePath -Recurse -Include "initrd*", "initrd" | Sort-Object Length -Descending | Select-Object -First 1

if (!$kernel -or !$initrd) {
    Dismount-DiskImage -ImagePath "$WorkDir\install.iso" | Out-Null
    Write-Error "Could not find kernel (vmlinuz) or initrd in the ISO."
    Exit
}

Write-Host "    Found Kernel: $($kernel.Name)"
    Write-Host "    Found Initrd: $($initrd.Name)"

    Copy-Item -Path $kernel.FullName -Destination "$WorkDir\vmlinuz"
    Copy-Item -Path $initrd.FullName -Destination "$WorkDir\initrd"

    # --- NEW: Extract Bootloaders from ISO ---
    Write-Host "[*] Searching for UEFI Bootloaders in ISO..."
    
    # Copy entire EFI/BOOT folder to capture dependencies (shim, grub, modules)
    $isoEfiBoot = Join-Path $drivePath "EFI\BOOT"
    if (Test-Path $isoEfiBoot) {
        Write-Host "    Found EFI\BOOT folder. Copying to temporary storage..."
        New-Item -Path "$WorkDir\EFI_COPY" -ItemType Directory -Force | Out-Null
        Copy-Item -Path "$isoEfiBoot\*" -Destination "$WorkDir\EFI_COPY" -Recurse -Force
    } else {
        Write-Warning "Could not find EFI\BOOT folder in ISO. Trying to find .efi files manually..."
        # Fallback: Find any .efi files
        $efiFiles = Get-ChildItem -Path $drivePath -Recurse -Filter "*.efi"
        New-Item -Path "$WorkDir\EFI_COPY" -ItemType Directory -Force | Out-Null
        foreach ($file in $efiFiles) {
            Copy-Item -Path $file.FullName -Destination "$WorkDir\EFI_COPY" -Force
        }
    }
    # ------------------------------------------

    Dismount-DiskImage -ImagePath "$WorkDir\install.iso" | Out-Null
    Write-Host "[*] ISO Dismounted."

    # --- NEW: Install Bootloader to EFI System Partition (ESP) ---
    # This is critical because many UEFI firmwares (and Shim) cannot read from NTFS.
    Write-Host "[*] Locating EFI System Partition (ESP)..."
    $esp = Get-Partition | Where-Object { $_.Type -eq "System" } | Select-Object -First 1
    
    if (!$esp) {
        Write-Error "Could not find EFI System Partition. Is this a UEFI system?"
        Exit
    }

    # Mount ESP if not mounted
    $espDrive = $esp.DriveLetter
    if (!$espDrive) {
        Write-Host "    Mounting ESP to Z:..."
        # Force mount to Z if free, otherwise find a letter
        if (Test-Path "Z:") { Remove-PSDrive Z -ErrorAction SilentlyContinue }
        Add-PartitionAccessPath -DiskNumber $esp.DiskNumber -PartitionNumber $esp.PartitionNumber -AccessPath "Z:"
        $espDrive = "Z"
    }
    
    $espPath = "${espDrive}:\EFI\NoRufus"
    Write-Host "    Installing bootloader to ESP ($espPath)..."
    
    if (Test-Path $espPath) { Remove-Item $espPath -Recurse -Force }
    New-Item -Path $espPath -ItemType Directory -Force | Out-Null

    # Copy All Bootloaders to ESP
    if (Test-Path "$WorkDir\EFI_COPY") {
        Copy-Item -Path "$WorkDir\EFI_COPY\*" -Destination $espPath -Recurse -Force
    }
    
    # Ensure we have a grubx64.efi and shimx64.efi with standard names
    # Some ISOs name them bootx64.efi (shim) and grubx64.efi
    
    # Define potential source files
    $shimSource = Get-ChildItem -Path "$WorkDir\EFI_COPY" -Recurse -Include "shimx64.efi", "bootx64.efi" | Sort-Object Length -Descending | Select-Object -First 1
    $grubSource = Get-ChildItem -Path "$WorkDir\EFI_COPY" -Recurse -Include "grubx64.efi" | Sort-Object Length -Descending | Select-Object -First 1
    
    if ($shimSource) { 
        Copy-Item -Path $shimSource.FullName -Destination "$espPath\shimx64.efi" -Force 
        Write-Host "    Installed Shim: $($shimSource.Name)"
    }
    if ($grubSource) { 
        Copy-Item -Path $grubSource.FullName -Destination "$espPath\grubx64.efi" -Force 
        Write-Host "    Installed Grub: $($grubSource.Name)"
    }

    
    # Create grub.cfg on ESP (FAT32) to point to C: (NTFS)
    # GRUB usually has NTFS module built-in for signed images
    Write-Host "[*] Creating grub.cfg on ESP..."
    $grubCfgContent = @"
set timeout=30
set default=0
set gfxpayload=keep

menuentry "Install Linux (Standard)" {
    search --set=root --file /NoRufus/vmlinuz
    linux /NoRufus/vmlinuz boot=casper iso-scan/filename=/NoRufus/install.iso toram root=/dev/ram0 quiet splash ---
    initrd /NoRufus/initrd
}

menuentry "Install Linux (Safe Graphics - nomodeset)" {
    search --set=root --file /NoRufus/vmlinuz
    linux /NoRufus/vmlinuz boot=casper iso-scan/filename=/NoRufus/install.iso toram root=/dev/ram0 nomodeset ---
    initrd /NoRufus/initrd
}

menuentry "Install Linux (Verbose/Debug)" {
    search --set=root --file /NoRufus/vmlinuz
    linux /NoRufus/vmlinuz boot=casper iso-scan/filename=/NoRufus/install.iso toram root=/dev/ram0 ---
    initrd /NoRufus/initrd
}

menuentry "Reboot to Firmware/BIOS" {
    fwsetup
}
"@
    Set-Content -Path "$espPath\grub.cfg" -Value $grubCfgContent
    
    # Copy grub.cfg to standard Ubuntu path just in case (/EFI/ubuntu/grub.cfg is hardcoded sometimes)
    # But here we are in /EFI/NoRufus.
    # Some grub builds look for grub.cfg in the same dir.
    
    # -------------------------------------------------------------

    # Validate Files
    if (!(Test-Path "$espPath\shimx64.efi")) {
        Write-Error "Could not find shimx64.efi on ESP."
        Exit
    }
    
    # ... Secure Boot Check (Keep existing) ...

    # 8. Configure BCD
    Write-Host "[*] Configuring Windows Boot Manager..."

    # Create a new entry
    $bcdOutput = bcdedit /create /d "NoRufus Linux Installer" /application bootapp
    $id = $bcdOutput | Select-String '{[a-f0-9-]+}' -AllMatches | ForEach-Object { $_.Matches.Value }

    if (!$id) {
        Write-Error "Failed to create BCD entry."
        Exit
    }

    Write-Host "    Created Entry ID: $id"

    # Configure the entry to point to ESP
    # Pointing to SHIMx64.EFI is the most standard way (it loads grub)
    bcdedit /set $id path "\EFI\NoRufus\shimx64.efi"
    bcdedit /set $id device "partition=${espDrive}:"

    # Removed bootmenupolicy as it causes errors for bootapp
    
    # Force add to display order
    bcdedit /displayorder $id /addlast
    
    Write-Host "-------------------------------------------------------"
    Write-Host "Success! Bootloader installed to ESP."

Write-Host "1. Reboot your computer."
Write-Host "2. Select 'NoRufus Linux Installer'."
Write-Host "3. The Linux environment will load into RAM."
Write-Host "4. Once loaded, you can run the installer to wipe Windows."
Write-Host "-------------------------------------------------------"
Read-Host "Press Enter to exit..."
