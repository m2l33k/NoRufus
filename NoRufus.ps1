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
    
    # Try standard paths first
    $isoShim = Get-ChildItem -Path $drivePath -Recurse -Include "bootx64.efi", "shimx64.efi" | Sort-Object Length -Descending | Select-Object -First 1
    $isoGrub = Get-ChildItem -Path $drivePath -Recurse -Include "grubx64.efi" | Sort-Object Length -Descending | Select-Object -First 1

    if ($isoShim) {
        Write-Host "    Found Shim: $($isoShim.Name)"
        Copy-Item -Path $isoShim.FullName -Destination "$WorkDir\bootx64.efi"
    }
    if ($isoGrub) {
        Write-Host "    Found Grub: $($isoGrub.Name)"
        Copy-Item -Path $isoGrub.FullName -Destination "$WorkDir\grubx64.efi"
    }
    # ------------------------------------------

    Dismount-DiskImage -ImagePath "$WorkDir\install.iso" | Out-Null
    Write-Host "[*] ISO Dismounted."

    # Validate Files
    if ((Get-Item "$WorkDir\bootx64.efi").Length -lt 1024) {
        Write-Error "Extracted bootx64.efi is too small or empty. The ISO might not support UEFI properly."
        Exit
    }

    # Check Secure Boot Status
    $secureBoot = Confirm-SecureBootUEFI -ErrorAction SilentlyContinue
    if ($secureBoot) {
        Write-Host "`n[WARNING] SECURE BOOT IS ENABLED!" -ForegroundColor Red -BackgroundColor Black
        Write-Host "Windows Boot Manager usually BLOCKS Linux bootloaders when Secure Boot is ON." -ForegroundColor Yellow
        Write-Host "You will likely see error 0xc000007b or 'Image Failed to Verify'." -ForegroundColor Yellow
        Write-Host "SOLUTION: Reboot into BIOS and DISABLE Secure Boot before trying the NoRufus entry." -ForegroundColor White
        Write-Host "----------------------------------------------------------------"
        Start-Sleep -Seconds 3
    }

    # 5. Download Bootloader (Fallback)
    if (!(Test-Path "$WorkDir\bootx64.efi") -or !(Test-Path "$WorkDir\grubx64.efi")) {
        Write-Host "[!] Bootloaders not found in ISO. Attempting download..."
        
        # Using Ubuntu 22.04 LTS signed binaries as they are widely compatible
        $shimUrl = "http://archive.ubuntu.com/ubuntu/pool/main/s/shim-signed/shim-signed_1.51.3+15.7-0ubuntu1_amd64.deb"
$grubUrl = "http://archive.ubuntu.com/ubuntu/pool/main/g/grub2-signed/grub-efi-amd64-signed_1.187.6+2.06-2ubuntu14.4_amd64.deb"

Write-Host "[*] Downloading Bootloader files..."

function Download-File($url, $dest) {
    try {
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
    } catch {
        Write-Error "Failed to download $url. Check internet connection."
        Exit
    }
}

Download-File $shimUrl "$WorkDir\shim.deb"
Download-File $grubUrl "$WorkDir\grub.deb"

    # 6. Extract .deb files (using tar if available, or just fail if not)
    if (Get-Command "tar" -ErrorAction SilentlyContinue) {
        Write-Host "[*] Extracting bootloader binaries..."
        
        # Extract shim
        tar -xf "$WorkDir\shim.deb" -C $WorkDir
        tar -xf "$WorkDir\data.tar.xz" -C $WorkDir
        $shimBinary = Get-ChildItem -Path $WorkDir -Recurse -Filter "shimx64.efi.signed" | Select-Object -First 1
        if ($shimBinary) {
            Copy-Item $shimBinary.FullName "$WorkDir\bootx64.efi"
        } else {
            Write-Error "Failed to extract shimx64.efi.signed"
        }

        # Clean up shim extraction
        Remove-Item "$WorkDir\data.tar.xz" -ErrorAction SilentlyContinue
        Remove-Item "$WorkDir\control.tar.xz" -ErrorAction SilentlyContinue
        Remove-Item "$WorkDir\debian-binary" -ErrorAction SilentlyContinue
        Remove-Item "$WorkDir\usr" -Recurse -Force -ErrorAction SilentlyContinue

        # Extract grub
        tar -xf "$WorkDir\grub.deb" -C $WorkDir
        tar -xf "$WorkDir\data.tar.xz" -C $WorkDir
        $grubBinary = Get-ChildItem -Path $WorkDir -Recurse -Filter "grubnetx64.efi.signed" | Select-Object -First 1
        # Note: grubnetx64 is often used, but let's check for grubx64
        if (!$grubBinary) {
            $grubBinary = Get-ChildItem -Path $WorkDir -Recurse -Filter "grubx64.efi.signed" | Select-Object -First 1
        }
        
        if ($grubBinary) {
            Copy-Item $grubBinary.FullName "$WorkDir\grubx64.efi"
        } else {
            Write-Error "Failed to extract grubx64.efi.signed"
        }

        # Clean up
        Remove-Item "$WorkDir\usr" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item "$WorkDir\*.deb"
        Remove-Item "$WorkDir\*.xz" -ErrorAction SilentlyContinue
        Remove-Item "$WorkDir\debian-binary" -ErrorAction SilentlyContinue
    } else {
        Write-Error "tar command not found. Please install 7-Zip or run on Windows 10 (1803+)."
        Exit
    }
    } # End of Download fallback

# 7. Create grub.cfg
Write-Host "[*] Creating grub.cfg..."
$grubCfgContent = @"
set timeout=10
set default=0

menuentry "Install Linux (Wipe Windows)" {
    search --set=root --file /NoRufus/vmlinuz
    # Added "root=/dev/ram0" and removed "quiet splash" for better debugging
    linux /NoRufus/vmlinuz boot=casper iso-scan/filename=/NoRufus/install.iso toram root=/dev/ram0 ---
    initrd /NoRufus/initrd
}

menuentry "Reboot to Firmware/BIOS" {
    fwsetup
}
"@
Set-Content -Path "$WorkDir\grub.cfg" -Value $grubCfgContent

# Create fallback directory structure for GRUB
New-Item -Path "$WorkDir\boot\grub" -ItemType Directory -Force | Out-Null
Copy-Item -Path "$WorkDir\grub.cfg" -Destination "$WorkDir\boot\grub\grub.cfg"


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

# Configure the entry
bcdedit /set $id path "\NoRufus\bootx64.efi"
bcdedit /set $id device partition=C:
bcdedit /set $id bootmenupolicy Legacy # Optional, makes menu appear
bcdedit /displayorder $id /addlast

Write-Host "-------------------------------------------------------"
Write-Host "Success! The Linux Installer has been added to your boot menu."
Write-Host "1. Reboot your computer."
Write-Host "2. Select 'NoRufus Linux Installer'."
Write-Host "3. The Linux environment will load into RAM."
Write-Host "4. Once loaded, you can run the installer to wipe Windows."
Write-Host "-------------------------------------------------------"
Read-Host "Press Enter to exit..."
