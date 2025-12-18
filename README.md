# NoRufus

**NoRufus** is a PowerShell script designed to help you install Linux on a Windows 10/11 machine without needing a USB drive, CD/DVD, or external media.

## How it Works
1.  **Detection**: The script finds a Linux ISO file in the current directory.
2.  **Preparation**: It extracts the necessary files (Kernel and Initrd) or the entire ISO content to a local folder on your `C:` drive.
3.  **Bootloader Setup**: It downloads and configures a lightweight bootloader (GRUB2) and adds a new entry to the Windows Boot Manager.
4.  **Reboot**: When you reboot, you can select the "Linux Installer" option, which will load the Linux Live environment from your hard drive.
5.  **Installation**: From the Live environment, you can proceed to install Linux, effectively wiping Windows if you choose to.

## Usage
1.  Download your desired Linux ISO (e.g., Ubuntu, Fedora, Debian).
2.  Place the ISO in this folder.
3.  Right-click `NoRufus.ps1` and select **Run with PowerShell**.
    *   The script will automatically ask for Administrator permission (click "Yes" when prompted).
4.  Follow the on-screen prompts.

## Troubleshooting
*   **Minimal BASH-like line editing is supported**:
    *   This means **GRUB cannot find the configuration file** or the kernel.
    *   **Fix**:
        1.  Type `ls` and press Enter to see the partitions.
        2.  Type `set root=(hd0,gptX)` (replace X with your partition number, usually gpt3 or gpt4 for C:).
        3.  Type `configfile /NoRufus/boot/grub/grub.cfg`.
        4.  If that works, the menu should appear.

*   **Error 0xc000007b (Status: 0xc000007b)**:
    *   This means **Secure Boot is blocking the Linux bootloader**.
    *   **Fix**: Restart your computer, enter BIOS/UEFI Settings, and **Disable Secure Boot**.
    *   Once Linux is installed, you can usually re-enable it (modern Linux distros support it, but the installer chainload process is strict).

## Disclaimer
**WARNING**: This tool involves modifying the Windows Boot Loader and partitioning. While tested, there is always a risk of data loss or creating an unbootable system. **Backup your data before proceeding.**
