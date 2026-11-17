# WinToolkit

Windows toolkit with a GUI. Current tool: system health check and repair:

- DISM component store (CheckHealth / ScanHealth / RestoreHealth)
- SFC system files (`/scannow`, or `/verifyonly` with repair off)
- CHKDSK `/scan` on all local NTFS drives
- Disk health (SMART)
- Failed auto-start services (restarted when repair is on)
- VSS writers and VSS errors

Every run is logged to `C:\Windows\Logs\WinHealth\` with OK / WARN / FIXED / FAIL per finding.

## Run

Open PowerShell and run:

```powershell
irm "https://github.com/lenhei/wintoolkit/raw/main/wintoolkit.ps1" | iex
```

The tool asks for administrator rights (UAC) and opens the window.
