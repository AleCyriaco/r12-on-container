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

## The three commands

Everything you do here fits in three, all runnable straight from the web with
no prior clone, from a PowerShell running **as Administrator**:

```powershell
# 1. INSTALL -- from nothing to EBS up
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/AleCyriaco/r12-on-container/main/bootstrap.ps1))) `
    -BaseUrl 'https://pub-YOURHASH.r2.dev'

# 2. RESUME -- continue from a phase, without redoing what is already done
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/AleCyriaco/r12-on-container/main/bootstrap.ps1))) `
    -BaseUrl 'https://pub-YOURHASH.r2.dev' -From Services

# 3. REMOVE EVERYTHING -- machine, virtual disk, package, folder, hosts line
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/AleCyriaco/r12-on-container/main/Remove-Tudo.ps1)))
```

All three report progress the same way: **`step N/X`**, a **0-100%** bar, and
three clocks — elapsed, remaining, and the total to the end of everything.
X is fixed before anything starts (the package parts are counted in) and each
step's weight **is** its typical duration, so the bar moves on clock time
rather than step count: download and extraction alone are worth nearly 80%.

```
  [ passo 12/35 ]  [ 20% ] [#####....................]  baixar u01-...part001  (decorrido 0:42:03 | falta 2:41:18 | total 3:23:21)
```

The forecast starts from a nominal (45 Mbps link, average extraction) and
**corrects itself**: once a phase begins, its measured pace replaces the
nominal — if the first parts arrive at a third of the expected speed, the
remaining ones are counted at a third. Expect the estimate to jump when the
download gets going; that is measurement replacing the guess. The same state is
written to `<TargetDir>\logs\progresso.json` for reading from another terminal.

Details: [install](#quick-start) · [resume](#resuming) · [remove](#removing).

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

**To check before installing anything**, without touching the machine:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/AleCyriaco/r12-on-container/main/Deploy-R12.ps1))) -SomenteRequisitos
```

It reads RAM, virtualisation and disks, reports what is missing, and exits. The
normal deploy runs that same gate before anything else — including before
installing Git — so a machine that does not qualify ends with **zero changes**.

## Quick start

Field-tested one-liner — run from an **elevated** PowerShell:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/AleCyriaco/r12-on-container/main/bootstrap.ps1))) `
    -BaseUrl 'https://pub-YOURHASH.r2.dev' `
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

Split the volume into 5 GB parts with a checksum manifest:

```powershell
.\Split-Package.ps1 `
    -SourceFile '\\server\share\u01-r12-lad-brasil.tar.zst' `
    -ExtraFile  '\\server\share\ebs-image-ol7-cll-ok.tar.zst' `
    -OutDir     'D:\upload'
```

Then upload **all** of `D:\upload` — parts, container image and `manifest.txt`.
The manifest is what lets the deployment verify each part by size and SHA-256.

### Where to host it

**Use plain HTTP object storage.** Cloudflare R2 costs about **US$0.72/month**
for 58 GB and charges **zero egress**; Backblaze B2 is comparable. Upload with
[Upload-ToR2.ps1](Upload-ToR2.ps1) — the Cloudflare dashboard rejects files
over ~300 MB, so this uses rclone and the S3 API. Then enable public read on
the bucket and pass the resulting URL as `-BaseUrl`.

**Consumer file-sharing services do not work for this**, and we measured why:

| Service | Blocker |
|---|---|
| Google Drive | download quota — after ~56 GB in one window it serves an HTML *"Quota exceeded"* page with HTTP 200 instead of the file. Also needs HTML scraping to list a folder. |
| Proton Drive | end-to-end encrypted. The URL fragment is the decryption key; downloading means implementing SRP-6a plus the OpenPGP key hierarchy. |
| file.kiwi | end-to-end encrypted too — AES-GCM in a web worker, key in the URL fragment. |

They are all built for a human with a browser, not for a script. Object storage
with signed or public URLs is built for exactly this.

### Why split at all

Not for storage — 58 GB is 58 GB either way. It buys:

- **Granular integrity.** A corrupt 5 GB part is detected and re-fetched alone.
- **Streaming reassembly.** `cat parts | zstd -dc | tar -x` never writes the
  58 GB back to disk.
- **Per-file quota relief**, if you are stuck on a service that imposes one.

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

## Resuming

**Re-running the same command is safe.** The phases are idempotent: each one
checks whether its work is already done before redoing it. After a failure — or
a Windows reboot in the middle — repeating the command is the first thing to
try, and nothing already finished is lost.

To jump straight to a phase, use `-From`:

| Phase | What it does | Resume here when |
|---|---|---|
| `Preflight` | WSL2 and the sizing plan | — |
| `Podman` | installs Podman if missing | "Podman installed but not on PATH" |
| `Machine` | creates the WSL2 VM, moves the disk, tunes the kernel | after rebooting for error 1223 or `HCS_E_SERVICE_NOT_AVAILABLE` |
| `Download` | fetches and verifies the package inside the VM | network drop, Drive quota exceeded |
| `Extract` | extracts `/u01` onto the VM's ext4 | after clearing a previous instance |
| `Container` | loads the image and creates the container | — |
| `Services` | starts database, listener, WebLogic and the CM | **after a Windows reboot** |
| `Verify` | checks HTTP, ICM and database contents | to re-check only |

What each resume preserves:

- **Download.** Resumption is byte-exact (`curl -C -`) and every part is
  re-checked by size and SHA-256 against the manifest. An intact part is skipped
  in seconds; only the missing or corrupted one is fetched again. That is what
  splitting the package into 5 GB parts buys you.
- **Extract.** Extraction is **skipped** when a complete instance is already in
  place — never overwritten. The interlock exists because a deploy launched with
  the default `-MachineName` once started extracting over a `/u01` whose database
  was **open**; skipping is both the idempotent and the safe answer, since
  extracting was the only destructive move available. Leftovers from an
  interrupted extraction, on the other hand, are cleaned up automatically before
  restarting.
- **Target directory.** With no `-TargetDir`, an existing instance is adopted
  (found by its `vm\ext4.vhdx`) instead of re-picking "the emptiest drive" —
  which on a resume is no longer the instance's drive, precisely because the
  instance fills it. The free-space requirement does not apply to a disk that
  already holds the instance.
- **Services.** Depends on nothing downloaded: it re-applies the canonical name
  in the container's `/etc/hosts`, starts the database, waits for the service to
  actually accept connections, and only then calls `adstrtal.sh`.

To **replace** an existing complete instance rather than keep it, you have three
ways out — all spelled out in the skip message itself: a different
`-MachineName` and `-TargetDir` for a parallel instance; deleting only `/u01`
with `Remove-Instancia.ps1 -SomenteInstancia` and resuming with `-From Extract`,
reusing the 59 GB already downloaded; or [removing everything](#removing).

To follow along from outside without interfering: `<TargetDir>\logs\progresso.json`
holds the current step, percentage, phase and the three timings (`decorrido`,
`falta`, `tempo_total`), and `<TargetDir>\logs\*.log` holds the full output of
each long phase (`download.log`, `extract.log`, `services.log`).

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

## Removing

Two scripts, for different jobs:

```powershell
# removes EVERYTHING: services, container, machine, virtual disk, the 59 GB
# package, the instance folder and the hosts line the deployment wrote
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/AleCyriaco/r12-on-container/main/Remove-Tudo.ps1)))

# removes only the extracted /u01, keeping the machine and the package
.\Remove-Instancia.ps1 -SomenteInstancia
```

`Remove-Tudo.ps1` looks before it touches: it finds the instance folder from
the WSL registration (no `-TargetDir` needed), lists what it found, builds the
plan from what actually exists, and reports `step N/X` plus a 0-100% bar just
like the deployment. Nothing changes until you type the machine name to
confirm. With no console to answer — a pipe, a `< NUL`, a scheduled task — it
**stops** instead of assuming consent; pass `-Force` if that is what you mean.

Two things it refuses to do: delete a folder that does not look like an
instance (no `vm/logs/scripts/pkg`) or a drive root; and remove any `hosts`
line other than the exact `127.0.0.1 <AppsHost>` the deployment wrote — your
own entry pointing that name elsewhere stays, and the script says so.

It keeps the repository clone and `.wslconfig` by default; `-RemoverRepo` and
`-RestaurarWslConfig` take those too.

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

**A file named `NUL` in the instance folder makes it undeletable.** A
`curl -o NUL` invoked from PowerShell does not discard output: it creates a
real `NUL` file. From then on `<TargetDir>\NUL` resolves to the nul *device*,
not the file, and deleting the folder fails with *"Incorrect function"* — a
message that gives no hint of the cause. `Remove-Tudo.ps1` works around it with
the `\\?\` prefix; by hand it is `cmd /c rd /s /q "\\?\<path>"`. For the same
reason the deployment writes to a temp file instead of `-o NUL`.

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
