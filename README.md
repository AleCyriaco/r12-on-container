# Oracle EBS R12.2 on Podman for Windows

[Português](README.pt-BR.md) · **English**

Automated deployment of an Oracle E-Business Suite R12.2 instance into a Podman
container on Windows, from a package hosted on Google Drive. One command:
installs Podman, sizes the WSL2 VM, downloads and verifies the package,
extracts, creates the container and brings the whole stack up.

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

**Sizing is automatic.** The script reads the host's RAM and sizes the WSL2 VM
and the Oracle SGA to match — including adjusting `%USERPROFILE%\.wslconfig`
(backed up first) when WSL's default cap of half the host RAM is not enough:

| Host RAM | VM | SGA |
|---|---|---|
| 48 GB+ | 40 GB | 20 GB (package default) |
| 23–47 GB | host − 8 GB | 8 GB |
| 16–22 GB | host − 4 GB | 4 GB |

On a 16 GB host it boots and works, but swaps — expect it to be slow. Override
with `-MemoryMB`, `-Cpus`, `-SgaGb` if you know better.

Virtualisation must be enabled in BIOS/UEFI.

## Quick start

Field-tested one-liner — run from an **elevated** PowerShell:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/AleCyriaco/r12-on-container/main/bootstrap.ps1))) `
    -FolderUrl 'https://drive.google.com/drive/folders/YOUR_FOLDER_ID' `
    -WlsPassword 'YOUR_WEBLOGIC_PASSWORD' `
    -TargetDir 'C:\R12OnContainer'
```

That installs Git if needed, clones this repo to `C:\r12-on-container`, and runs
the full deployment. Expect several hours, dominated by the download.

Two lessons from real runs:

- **`-TargetDir` must point at a real disk.** The default is
  `D:\R12OnContainer`; on machines where `D:` is absent or is a CD-ROM/card
  reader the script now stops immediately and says so. Pointing it at `C:` (or
  whichever drive has ~345 GB free) avoids the round-trip. List real disks with
  `Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3"`.
- **The raw `main` URL is CDN-cached for a few minutes after a push.** If you
  just updated the repo, pin the commit instead:
  `https://raw.githubusercontent.com/AleCyriaco/r12-on-container/<commit-sha>/bootstrap.ps1`
  — a SHA URL is immutable and can never serve a stale version.

Prefer cloning first:

```powershell
git clone https://github.com/AleCyriaco/r12-on-container.git C:\r12-on-container
cd C:\r12-on-container
Copy-Item config.example.psd1 config.psd1   # then fill it in
.\Deploy-R12.ps1
```

## Preparing the package

Split the volume into 5 GB parts and generate a checksum manifest, then upload
everything to a Drive folder shared as *Anyone with the link → Viewer*:

```powershell
.\Split-Package.ps1 `
    -SourceFile '\\server\share\u01-r12-lad-brasil.tar.zst' `
    -ExtraFile  '\\server\share\ebs-image-ol7-cll-ok.tar.zst' `
    -OutDir     'D:\upload'
```

Upload **all** of `D:\upload`: the parts, the container image, and
`manifest.txt`. The manifest is what lets the deployment verify each part by
size and SHA-256.

Splitting is not about storage — 58 GB is 58 GB either way. It buys you:

- **Per-file download quota.** Google throttles public files individually.
- **Real resumability.** A bad 5 GB part costs 5 GB, not 58.
- **Streaming reassembly.** `cat parts | zstd -dc | tar -x` never writes the
  58 GB back to disk.

## How it works

Eight idempotent phases. Each checks whether its work is already done, so
re-running after a failure is safe. Resume with `-From <Phase>`.

| Phase | What it does |
|---|---|
| `Preflight` | hardware, WSL2, virtualisation |
| `Podman` | installs Podman via winget if absent |
| `Machine` | creates the WSL2 VM, relocates its disk to `-TargetDir`, applies Oracle kernel settings |
| `Download` | fetches the parts into the VM, verifying size and SHA-256 |
| `Extract` | extracts `/u01` onto the VM's ext4 |
| `Container` | loads the image, creates the container, fixes `/etc/hosts` |
| `Services` | database, listener, WebLogic stack, concurrent manager |
| `Verify` | HTTP 302/200, ICM status, database contents |

### Where the data lives

The VM's virtual disk goes to `-TargetDir\vm\ext4.vhdx`, and `/u01` is extracted
onto the **ext4 inside it** — never onto `/mnt/c` or `/mnt/d`. Extracting onto a
Windows path goes through 9p/drvfs, which destroys performance and breaks
permissions. Putting the vhdx on the drive you want is how you choose where the
data physically sits without paying that cost.

### Frozen by default

`fs2`, the patch filesystem, is discarded during extraction. EBS detects this
and reports `File System Type: SINGLE` / `PATCH File System: NOT APPLICABLE` —
a configuration it supports natively, not a hack. This saves ~37 GB and means
**`adop` will not run**. Pass `-KeepFs2` for a patchable dual-filesystem
install.

## Configuration

`config.psd1` (gitignored) or command-line parameters:

| Key | Meaning |
|---|---|
| `FolderUrl` | public Drive folder with the parts |
| `WlsPassword` | WebLogic password — **required** |
| `AppsPassword` | APPS schema password (defaults to `apps`) |
| `AppsHost` | hostname baked into the EBS context |
| `TargetDir` | where to install |

## After a Windows reboot

The container has `--restart unless-stopped` and comes back on its own, but it
runs `sleep infinity` — the EBS services do not. Either of these brings it back:

```powershell
podman machine start ebs
cd C:\r12-on-container
.\Deploy-R12.ps1 -From Services
```

Or, straight from inside the machine, with `scripts/bringup.sh`:

```powershell
podman machine start ebs
podman machine ssh ebs 'WLS_PASSWORD=xxx bash /mnt/c/r12-on-container/scripts/bringup.sh'
```

Both do the same thing, in this order: re-apply the canonical name to the
container's `/etc/hosts` (Podman wipes it on every start), restart the database
listener, open the database, **wait for the service to actually accept
connections**, then start the application tier and check the concurrent
manager. Skipping any of those turns into a misleading *"APPS credentials are
wrong"* — see
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md#everything-breaks-after-restarting-the-container).

## Hostname

`AppsLogin` redirects to the hostname EBS wrote into its context and profiles,
so it must resolve on Windows. The deployment adds this automatically when run
elevated; otherwise do it yourself:

```powershell
Add-Content C:\Windows\System32\drivers\etc\hosts "`n127.0.0.1    apps.example.com"
```

## Security notes

- No credentials in this repository, by design. `config.psd1` is gitignored.
- The `.sh` files generated at runtime under `<TargetDir>\scripts\` **do**
  contain the substituted WebLogic password. They are gitignored, but they sit
  in plaintext on the machine — treat that directory accordingly.
- Passing `-WlsPassword` on the command line puts it in your PowerShell history.
  `config.psd1` avoids that.

## Known pitfalls

Summarised here, detailed in [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

**`adstrtal.sh` reads the WebLogic password from stdin.** Without `podman exec
-i` it arrives empty, the AdminServer exits 1, and every managed server is
skipped with *"Skipping startup … AdminServer is down"* — a message that sends
you hunting the NodeManager while the real cause is the password.

**The container's `/etc/hosts` is a bind mount.** `sed -i` fails with *Device or
resource busy*; write in place with `cat > /etc/hosts`. And do not duplicate the
`apps`/`ebs` aliases Podman already creates from `--hostname` — that changes the
IP's canonical name and the listener comes up on `HOST=apps` instead of the
fully-qualified name the instance was built with.

**`pkill -f tnslsnr` kills both listeners** — the database's on 1521 and the
apps tier's on 1626 match the same pattern. Afterwards `adstrtal.sh` complains
about APPS credentials, which points nowhere near the actual problem.

**The ICM loses a race with the previous session's lock**, dying with
`FND_DCP.Request_Session_Lock … result code of 1`. Not corruption, and no
`cmclean.sql` needed — just start it again. The scripts already detect and retry.

**Reading a Drive folder is scraping.** There is no key-free API to list a public
folder, so this parses the `_DRIVE_ivd` blob out of the page, as `gdown` does.
It will break when Google changes their HTML. `-VolumeFileId` and `-ImageFileId`
are the escape hatch.
