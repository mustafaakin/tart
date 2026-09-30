@echo off
rem Runs once as SYSTEM when Windows setup completes, before OOBE; autounattend.xml powers off after it.
powercfg /hibernate off
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0

rem OpenSSH Server comes from Windows Update. VZ's NAT network is classified Public, so allow port 22 on every profile.
powershell -NoProfile -Command "Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0; Set-Service sshd -StartupType Automatic; New-NetFirewallRule -Name tart-sshd -DisplayName 'OpenSSH Server' -Protocol TCP -LocalPort 22 -Action Allow -Profile Any"

rem Directory sharing ("tart run --dir"): WinFsp plus the virtio-fs service, which mounts the shares as a drive (Z:).
msiexec /i C:\ProgramData\Tart\winfsp.msi /qn /norestart
sc create VirtioFsSvc binpath= C:\ProgramData\Tart\virtiofs.exe start= auto depend= WinFsp.Launcher/VirtioFsDrv DisplayName= "Virtio FS Service"

rem Grow C: after "tart set --disk-size", on every boot.
schtasks /create /tn "Tart\Extend system disk" /sc onstart /ru SYSTEM /tr "powershell -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\Tart\extend-c.ps1" /f
