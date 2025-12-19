# NoRufus

**NoRufus** is a PowerShell tool designed to install Linux on a Windows 10/11 machine **without** a USB drive, CD/DVD, or external media.

It works by creating a dedicated "Installation Partition" on your hard drive, making your PC think a USB stick is plugged in internally.

## Features
*   **Zero External Hardware**: No USB stick or DVD required.
*   **Universal Compatibility**: Works with almost any UEFI-bootable Linux ISO (Ubuntu, Kali, Debian, Fedora, etc.).
*   **Dedicated Partition Method**: Automatically shrinks your C: drive by the exact size of the ISO to create a temporary installation partition. This is safer and more reliable than RAM-disk methods.
*   **Secure Boot Compatible**: Uses the signed bootloaders present on the ISO itself (Shim/GRUB).

## How it Works
1.  **ISO Analysis**: Checks the size of your Linux ISO.
2.  **Partitioning**: Automatically shrinks the `C:` drive to create a small FAT32 partition (Label: `LINUX_INSTALL`) at the end of the disk.
3.  **Extraction**: Copies the **entire** contents of the ISO to this new partition.
4.  **Boot Config**: Adds a new entry to the Windows Boot Manager pointing directly to the bootloader on the new partition.
5.  **Reboot**: You reboot into "NoRufus Linux Installer", which behaves exactly like a bootable USB drive.

## Usage
1.  **Download** your desired Linux ISO.
2.  **Place** the ISO file in the same folder as `NoRufus.ps1`.
3.  **Right-click** `NoRufus.ps1` and select **Run with PowerShell**.
    *   *Note*: If prompted, allow the script to run as **Administrator**.
4.  The script will:
    *   Shrink your C: drive (this may take a moment).
    *   Copy files.
    *   Tell you when it's ready.
5.  **Reboot** your computer.
6.  Select **"NoRufus Linux Installer"** from the boot menu.
7.  Install Linux! (You can delete the 4-5GB partition later during the Linux installation process if you wish).

## Troubleshooting

### Error: "Secure Boot Violation" or Red Warning Box
*   **Cause**: The bootloader on your ISO might not be signed by a key your PC trusts.
*   **Fix**: 
    1.  Restart and enter **BIOS/UEFI Setup** (usually F2, F12, or Del key).
    2.  Find **Secure Boot** settings.
    3.  Set it to **Disabled**.
    4.  Save and Exit.

### Error 0xc000007b (Status: 0xc000007b)
*   **Cause**: Windows Boot Manager is blocking the Linux bootloader (Shim/GRUB).
*   **Fix**: This is almost always caused by **Secure Boot**. Disable it in BIOS as described above.

### Black Screen after selecting "NoRufus"
*   **Cause**: Graphics driver incompatibility during boot.
*   **Fix**: 
    *   If you see a GRUB menu, look for an option that says **"Safe Graphics"** or **"nomodeset"**.
    *   If you don't see a menu at all, try using a different ISO (e.g., Ubuntu LTS usually works best).

## Disclaimer
**WARNING**: This tool performs **disk partitioning** (shrinking C: drive). While it uses standard Windows APIs (`Resize-Partition`), modifying partitions always carries a small risk. **Please backup important data before running this tool.**
