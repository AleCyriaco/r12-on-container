# Oracle EBS R12.2 on Podman for Windows

Automated deployment of an Oracle E-Business Suite R12.2 instance into a Podman
container on Windows. One command installs Podman, sizes the WSL2 VM, downloads
and verifies your package, extracts it, creates the container and brings the
whole stack up.

> **This repository contains automation only.** No Oracle binaries, no database,
> no credentials, no link to any package. Oracle E-Business Suite is licensed
> software — you supply your own package, and distributing it is your
> responsibility under your Oracle licence.

## Requirements

| | Minimum | Recommended | Why |
|---|---|---|---|
| Windows | 11 or Server 2022 | — | WSL2 |
| RAM | **16 GB** | 48 GB | at 48 GB+ the package's 20 GB SGA runs as-is |
| Free disk | ~345 GB | — | 274 GB extracted + 58 GB package |
| CPUs | 2 | 8 | `adop` uses 32 workers; fewer works, just slower |

Virtualisation must be enabled in BIOS/UEFI.

Sizing is automatic: the script reads the host's RAM and sizes the WSL2 VM and
the Oracle SGA to match, adjusting `%USERPROFILE%\.wslconfig` (backed up first)
when WSL's default cap of half the host RAM is not enough.

| Host RAM | VM | SGA |
|---|---|---|
| 48 GB+ | 40 GB | 20 GB (package default) |
| 23–47 GB | host − 8 GB | 8 GB |
| 16–22 GB | host − 4 GB | 4 GB |

On a 16 GB host it boots and works, but swaps — expect it to be slow. Override
with `-MemoryMB`, `-Cpus`, `-SgaGb` if you know better.

**Check a machine before installing anything on it:**

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/AleCyriaco/r12-on-container/main/Deploy-R12.ps1))) -SomenteRequisitos
```

It reads RAM, virtualisation and disks, reports what is missing, and exits. The
normal deploy runs that same gate before anything else — including before
installing Git — so a machine that does not qualify ends with **zero changes**.

## Install

From a PowerShell running **as Administrator**:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/AleCyriaco/r12-on-container/main/bootstrap.ps1))) `
    -BaseUrl 'https://pub-YOURHASH.r2.dev' `
    -WlsPassword 'welcome1' `
    -TargetDir 'C:\R12OnContainer'
```

That installs Git if needed, clones this repo to `C:\r12-on-container`, and runs
the full deployment. Expect several hours, dominated by the download.

> **`-WlsPassword` is the password the image already has, not one you pick.**
> The deployment authenticates to the NodeManager with it; it does not set or
> change the WebLogic password. The reference package ships with `welcome1` —
> only pass something else if your image was changed. A made-up password here
> does not fail fast: the deployment runs to completion, only WebLogic stays
> down, and the reason (`Invalid credentials passed`) is buried in
> `services.log`.

Two more things worth knowing before the first run:

- **`-TargetDir` must point at a real disk.** The default is
  `D:\R12OnContainer`; where `D:` is absent or is a CD-ROM/card reader the
  script stops immediately and says so. List real disks with
  `Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3"`.
- **The raw `main` URL is CDN-cached for a few minutes after a push.** If the
  repo was just updated, pin the commit instead:
  `https://raw.githubusercontent.com/AleCyriaco/r12-on-container/<commit-sha>/bootstrap.ps1`
  — a SHA URL is immutable and can never serve a stale version.

To clone first instead:

```powershell
git clone https://github.com/AleCyriaco/r12-on-container.git C:\r12-on-container
cd C:\r12-on-container
Copy-Item config.example.psd1 config.psd1   # then fill it in
.\Deploy-R12.ps1
```

## Configuration

`config.psd1` (gitignored) or command-line parameters:

| Key | Meaning |
|---|---|
| `BaseUrl` | public URL of the object-storage bucket holding the package |
| `WlsPassword` | the password that **already exists** in the image domain (factory: `welcome1`) |
| `AppsPassword` | APPS schema password (defaults to `apps`) |
| `AppsHost` | hostname baked into the EBS context (defaults to `apps.example.com`) |
| `TargetDir` | where to install |

## Phases and resuming

Eight idempotent phases. Each checks whether its work is already done, so
**re-running the same command after a failure is safe** — nothing already
finished is lost. Jump straight to one with `-From <Phase>`.

| Phase | What it does | Resume here when |
|---|---|---|
| `Preflight` | hardware, WSL2, virtualisation, sizing plan | — |
| `Podman` | installs Podman via winget if absent | "Podman installed but not on PATH" |
| `Machine` | creates the WSL2 VM, relocates its disk to `-TargetDir`, applies Oracle kernel settings | after rebooting for error 1223 or `HCS_E_SERVICE_NOT_AVAILABLE` |
| `Download` | fetches the parts into the VM, verifying size and SHA-256 | network drop |
| `Extract` | extracts `/u01` onto the VM's ext4 | after clearing a previous instance |
| `Container` | loads the image, creates the container, fixes `/etc/hosts` | — |
| `Services` | database, listener, WebLogic stack, concurrent manager | **after a Windows reboot** |
| `Verify` | HTTP 302/200, ICM status, database contents | to re-check only |

Download resumption is byte-exact (`curl -C -`) and every part is re-checked
against the manifest, so an intact part is skipped in seconds. Extraction is
**skipped**, never overwritten, when a complete instance is already in place;
the skip message spells out the three ways to replace one instead.

Progress is reported as `step N/X` with a 0–100% bar and three clocks. The same
state is written to `<TargetDir>\logs\progresso.json`, and the full output of
each long phase to `<TargetDir>\logs\*.log`, for following along from another
terminal.

## After a Windows reboot

The container has `--restart unless-stopped` and comes back on its own, but it
runs `sleep infinity` — the EBS services do not. Either of these brings it back:

```powershell
podman machine start ebs
cd C:\r12-on-container
.\Deploy-R12.ps1 -From Services
```

```powershell
podman machine start ebs
podman machine ssh ebs 'WLS_PASSWORD=welcome1 bash /mnt/c/r12-on-container/scripts/bringup.sh'
```

Both do the same thing, in this order: re-apply the canonical name to the
container's `/etc/hosts` (Podman wipes it on every start), restart the database
listener, open the database, **wait for the service to actually accept
connections**, then start the application tier and check the concurrent
manager. Skipping any of those turns into a misleading *"APPS credentials are
wrong"*.

## Hostname

`AppsLogin` redirects to the hostname EBS wrote into its context and profiles,
so that name must resolve on Windows — to `127.0.0.1`, because the container
publishes port 8000 on the host. The deployment adds the entry automatically
when run elevated; otherwise, from an elevated PowerShell:

```powershell
Add-Content C:\Windows\System32\drivers\etc\hosts "`n127.0.0.1    apps.example.com"
```

Exactly one line may carry that name. A stale entry pointing it at the
machine's LAN address survives the deployment and stops working at the next
DHCP lease — the symptom is the browser timing out while
`http://127.0.0.1:8000/OA_HTML/AppsLogin` answers `302`.

## Removing

```powershell
# removes EVERYTHING: services, container, machine, virtual disk, the package,
# the instance folder and the hosts line the deployment wrote
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/AleCyriaco/r12-on-container/main/Remove-Tudo.ps1)))

# removes only the extracted /u01, keeping the machine and the package
.\Remove-Instancia.ps1 -SomenteInstancia
```

`Remove-Tudo.ps1` finds the instance folder from the WSL registration (no
`-TargetDir` needed), lists what it found and reports progress the same way the
deployment does. Nothing changes until you type the machine name to confirm;
with no console to answer it **stops** rather than assume consent, so pass
`-Force` for unattended use. It refuses to delete a folder that does not look
like an instance or a drive root, and it removes only the exact
`127.0.0.1 <AppsHost>` line the deployment wrote. The repository clone and
`.wslconfig` are kept unless you pass `-RemoverRepo` / `-RestaurarWslConfig`.

## Notes

- **`adop` will not run by default.** `fs2`, the patch filesystem, is discarded
  during extraction, saving ~37 GB. EBS reports `File System Type: SINGLE` /
  `PATCH File System: NOT APPLICABLE`, a configuration it supports natively.
  Pass `-KeepFs2` for a patchable dual-filesystem install.
- **`/u01` lives on the ext4 inside `<TargetDir>\vm\ext4.vhdx`**, never on
  `/mnt/c` or `/mnt/d`. Extracting onto a Windows path goes through 9p/drvfs,
  which destroys performance and breaks permissions. Placing the vhdx is how
  you choose the physical drive without paying that cost.
- **No credentials in this repository, by design.** `config.psd1` is gitignored.
  The `.sh` files generated at runtime under `<TargetDir>\scripts\` **do**
  contain the substituted WebLogic password in plaintext — treat that directory
  accordingly. Passing `-WlsPassword` on the command line also puts it in your
  PowerShell history; `config.psd1` avoids that.

## Troubleshooting

Every entry in [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) was hit for
real during a deployment. The pattern that repeats: **the visible error names
the wrong component.**
