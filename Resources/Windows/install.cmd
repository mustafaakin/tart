@echo off
rem Installs Windows from WinPE for tart, called by autounattend.xml as: install.cmd <installer drive>
rem Windows Setup's own disk step fails on Virtualization.framework disks, so this does the install itself
rem and powers off. tart then reads \tart\result and \tart\install.log from the installer.
setlocal EnableExtensions
set M=%1
set T=%M%\tart
set LOG=%T%\install.log
echo [%time%] start > %LOG%

rem The system disk may be virtio-blk, which WinPE only sees once viostor is loaded.
if exist %T%\drivers\viostor\viostor.inf drvload %T%\drivers\viostor\viostor.inf >> %LOG% 2>&1

rem The target is the only disk without partitions; the installer itself always has some.
rem diskpart's output is localized, so rely on its exit codes: selecting a partition fails on an empty disk.
echo list disk > X:\listdisk.txt
diskpart /s X:\listdisk.txt >> %LOG% 2>&1
set N=0
for /l %%d in (0,1,7) do (
  > X:\probe.txt echo select disk %%d
  diskpart /s X:\probe.txt >nul 2>&1 && (
    >> X:\probe.txt echo select partition 1
    diskpart /s X:\probe.txt >nul 2>&1 || (set DISK=%%d& set /a N+=1)
  )
)
if not "%N%"=="1" (echo expected exactly one empty disk, found %N% >> %LOG% & goto fail)
echo target disk %DISK% >> %LOG%

(
echo select disk %DISK%
echo clean
echo convert gpt
echo create partition efi size=260
echo format quick fs=fat32 label=System
echo assign letter=S
echo create partition msr size=16
echo create partition primary
echo format quick fs=ntfs label=Windows
echo assign letter=W
) > X:\partition.txt
diskpart /s X:\partition.txt >> %LOG% 2>&1 || goto fail

set WIM=%M%\sources\install.wim
if not exist %WIM% set WIM=%M%\sources\install.esd
rem Prefer Windows 11 Pro; single-edition ISOs such as Enterprise evaluation get their first edition.
set IMAGE=/Name:"Windows 11 Pro"
dism /Get-ImageInfo /ImageFile:%WIM% %IMAGE% >nul 2>&1 || set IMAGE=/Index:1
echo [%time%] applying image %IMAGE% >> %LOG%
dism /Apply-Image /ImageFile:%WIM% %IMAGE% /ApplyDir:W:\ /Compact >> %LOG% 2>&1 || goto fail
dism /Image:W:\ /Add-Driver /Driver:%T%\drivers /Recurse >> %LOG% 2>&1 || goto fail

rem Windows Server's OOBE stops at a product key page, which Windows 11's doesn't. Standard and Datacenter get
rem Microsoft's public KMS client key (GVLK) in the answer file below, which lets setup finish without activating.
dism /Image:W:\ /Get-CurrentEdition > X:\edition.txt 2>&1
type X:\edition.txt >> %LOG%
rem WinPE has no findstr, so parse "Current Edition : <name>" with for /f alone
set KEY=
for /f "usebackq tokens=2 delims=:" %%E in ("X:\edition.txt") do for %%F in (%%E) do (
  if "%%F"=="ServerStandard" set KEY=TVRH6-WHNXV-R9WG3-9XRFY-MY832
  if "%%F"=="ServerDatacenter" set KEY=D764K-2NDRG-47T6Q-P8T8W-YP6DF
)
echo product key: "%KEY%" >> %LOG%

rem Directory sharing (virtio-fs service + WinFsp) and system disk growth, set up by SetupComplete.cmd.
mkdir W:\ProgramData\Tart 2>nul
copy /y %T%\drivers\viofs\virtiofs.exe W:\ProgramData\Tart\ >> %LOG% || goto fail
copy /y %T%\winfsp.msi W:\ProgramData\Tart\ >> %LOG% || goto fail
copy /y %T%\extend-c.ps1 W:\ProgramData\Tart\ >> %LOG% || goto fail

mkdir W:\Windows\Panther W:\Windows\Setup\Scripts 2>nul
if not defined KEY (copy /y %M%\autounattend.xml W:\Windows\Panther\unattend.xml >> %LOG% || goto fail)
if defined KEY (call :withkey || goto fail)
copy /y %T%\SetupComplete.cmd W:\Windows\Setup\Scripts\ >> %LOG% || goto fail

bcdboot W:\Windows /s S: /f UEFI >> %LOG% 2>&1 || goto fail
rem The framebuffer driver registered \EFI\tart\framebuffer.efi when the installer booted; the firmware
rem finds this copy on the system disk once the installer is detached.
mkdir S:\EFI\tart 2>nul
copy /y %T%\framebuffer.efi S:\EFI\tart\ >> %LOG% || goto fail

echo [%time%] done >> %LOG%
rem Keep a copy on the installed system, since tart discards the installation media
copy /y %LOG% W:\Windows\Panther\tart-install.log >nul
echo OK> %T%\result
wpeutil shutdown
goto wait

:withkey
rem Copies the answer file with the product key in place of its marker line
echo [%time%] product key for this edition goes into unattend.xml >> %LOG%
set REPLACED=
(for /f "usebackq delims=" %%L in ("%M%\autounattend.xml") do (
  if "%%L"=="      <!-- tart:product-key -->" (echo       ^<ProductKey^>%KEY%^</ProductKey^>& set REPLACED=1) else (echo(%%L)
)) > W:\Windows\Panther\unattend.xml
if not defined REPLACED (echo the answer file has no product key marker >> %LOG% & exit /b 1)
exit /b 0

:fail
echo [%time%] failed >> %LOG%
echo FAILED> %T%\result
wpeutil shutdown

:wait
rem Never return to Setup while WinPE powers off.
ping -n 60 127.0.0.1 >nul
goto wait
