<img width="1117" height="855" alt="image" src="https://github.com/user-attachments/assets/4fd43ad0-4767-4512-89ba-64801cf16412" />
# Sandboxie Minus
## Run AppContainer apps with no MSIX packages, VMs or heavy virtualisation required.

**Disclaimer:** Sandboxie Minus is not affiliated with, derived from, or based on David Xanatos' Sandboxie (and Sandboxie Plus). Sandboxie Minus is an independent Windows AppContainer management utility.

---

## Why Sandboxie Minus???

Imagine this scenario:
You are a 3D artist using **Blender**. You download a popular community add-on or asset pack to speed up your workflow. You notice a small disclaimer on the marketplace, but dismiss it.

What you missed: **Blender add-ons are Python scripts.** When Blender loads an add-on, that Python script runs with your **full user privileges**. It can read your browser cookies, grab Discord or SSH tokens, and send it all to the attacker's server since Blender's internal "disable networking" setting only blocks the in-app connections and can't stop them on the OS level.

**Sandboxie Minus solves this.** It wraps existing desktop applications into Windows **AppContainer** and **Less-Privileged AppContainer (LPAC)** isolation boundaries without requiring MSIX packaging, VMs (virtual machines), or heavy virtualization overhead. Most apps don't require native support. You can sandbox your 3D software, your mouse app, or a random game you don't trust.
**Limitations:** You can't sandbox something that needs full user privileges or higher. Games like Valorant won't run since Vanguard is a kernel-level anti-cheat. Firefox won't launch even with full folder and registry permissions because it already uses AppContainer and other features not available inside containers.

---

## System Requirements

- **Operating System:** Windows 10 version 1703 (Build 15063) or newer / Windows 11
  *(FSCTL restrictions require Windows 11 Build 25295+)*
- **Shell:** PowerShell 5.1 (standard on Windows 10/11) with STA mode enabled
- **Privilege Model:**
  - Configuration, ACL updates, and firewall rules require **Administrator elevation** (Apply (admin) / Save (admin))
  - Sandbox launching is **strictly non-admin** (Launch is intentionally blocked in elevated sessions to prevent privilege leakage).

---

## A quick Example Walkthrough: Sandboxing Blender

Here's how the artist in the example will deal with sandboxing Blender:

### 1. Create the Container
Open Sandboxie Minus and click **New**. Name it whatever you want, like 'Blender 5.3'

**Dev Tip:** Container names can't be changed after creation because Windows derives a unique mathematical SID from the name. To rename later, click **Clone** and delete the old one

### 2. Grant Executable Access
Go to the **Folders & files** tab. Enter the path to your Blender executable:
- **Path:** C:\Program Files\Blender Foundation\Blender 5.3\
- **Scope:** Recursive (subfolders & files)
- **Permission:** ReadExecute
- Click **Add / Update Rule**

*Repeat the same process for C:\Windows*

### 3. Handle Parent Traversal
AppContainers enforce strict directory traversal checks. To allow Blender's file browser to navigate the folder tree to your projects:
- Add C:\ with Scope: **This folder only** (ReadExecute). The setting stops the app from reading anything inside of C:\, only giving the filenames and basic info to it
- Add your parent project folder (e.g., D:\3D_Work\) with Scope: **This folder only** (ReadExecute)
 - If on an external drive, add D:\ the same way you added C:\
- Add your actual project files folder (e.g., D:\3D_Work\Projects\) with Scope: **Recursive** (ReadWrite)
This allows you to use Blender's built-in file manager instead of writing the path from scratch every time

### 4. Enable Registry Reading
Switch to the **Registry** tab and tick:
- "[x] Launch-time token capability registryRead"  
*(Blender needs to read system display and Direct3D registry settings, but requires zero registry write permissions)*

### 5. Isolate AppData and other variables
On the **Env & quotas** tab:
- **Redirect USERPROFILE & APPDATA** is enabled by default. Blender will store its cache and config in an isolated container directory rather than touching your host %APPDATA%
- If you want Blender to read your existing host add-ons installed in %APPDATA%\Blender Foundation, untick this box and add an explicit **ReadWrite** rule targeting only that subfolder on the **Folders & files** tab (e.g., \Appdata\Roaming\Blender Foundation and \Appdata\Local\Blender Foundation)
- Add any variable into the redirected variables if your %variable% to be redirected into the container's own location

**IMPORTANT:** The redirect feature only redirects variables. A variable like %APPDATA% will get you to C:\Users\youruser\Appdata\Roaming. This is what's being redirected. If you grant explicit access to the folder the app CAN access it. Don't treat it as a security boundary if rules allow access to the real folder. The redirected folders require zero manual permissions (allowed by default)

### 6. Isolate the Screen and Input
- In **Env & quotas**, ensure **Automatically create & isolate a separate desktop** is checked
- Click **Apply (admin)** to commit your ACLs and firewall rules
- Click **Launch**

Blender opens on its own isolated desktop (WinSta0\acm.desk.*). It **can't** read your main desktop pixels and monitor keyboard strokes when you're on your main desktop. Keyboard and other access permissions are in the **Hardening** tab

*(To switch between desktops, click **Desktops...** in the top bar and select your work desktop)*

**Dev Tip:** Enable **[x] Join the first running app's isolated desktop** to have all of your containers in one single desktop instead of switching between multiple. Cons: allows any container sharing that desktop to view the screen while other containers on that desktop are active. Isolate sensitive ones. Still does NOT compromise your real desktop, which is where your browser, work, and everything that isn't a Sandboxie Minus container lives.

---

## Install

* Download the latest zip from Releases
* Unzip it anywhere
* Run **install.cmd**

Then launch Sandboxie Minus using the Desktop shortcut.

---

## Tab Reference and Developer Notes

### 1. Containers
* **User Overview:** Your dashboard. You can view all configured container profiles as cards, check whether ACLs are applied, pick custom icons, and launch or inspect running sandboxes
* **DEV NOTE:** Clicking a card loads profile JSON schema structures into memory. Inspect queries OpenProcess with PROCESS_QUERY_LIMITED_INFORMATION to resolve running container processes via TokenAppContainerSid. Reset data wipes the container's isolated %LOCALAPPDATA%\Packages\<ContainerId> storage

### 2. General
* **User Overview:** Lets you set the executable path, launch arguments, and working directory. Tick ShowConsole for command-line tools like cmd.exe or python.exe
* **DEV NOTE:** Container SIDs are deterministically computed via DeriveAppContainerSidFromAppContainerName. Selecting Ephemeral generates a dynamic throwaway SID (acm.eph.<guid>) that is automatically cleaned up on exit

### 3. Folders & Files
* **User Overview:** Here you can set up whitelist-only file rules. Choose between FolderOnly (the folder itself), DirectContents (1 level down), or Recursive (full tree)
* **DEV NOTE:** AppContainer blocks by default; rules are applied via icacls using explicit Allow ACEs for the container SID. DirectContents applies (OI)(CI)(NP) inheritance flags. Force forces explicit ACL inheritance on directories that drop inheritance under LPAC (S-1-15-2-2)

### 4. Registry
* **User Overview:** Lets you control registry access. Keep **registryRead** ticked for most desktop apps
* **DEV NOTE:** Registry security rules target RegistrySecurity DACLs directly. View: Both writes to both 64-bit and WOW6432Node paths. The Audit rules button flags risky write permissions on persistence keys (Run, IFEO, CLSID, Environment)

### 5. Hardening
* **User Overview:** Exploit mitigation flags. Keep defaults on unless something crashes or you need **clipboard access** within the app
* **DEV NOTE:** Maps directly to SetProcessMitigationPolicy and STARTUPINFOEX process creation mitigation policies:
  - **LPAC:** Strips ALL APPLICATION PACKAGES (S-1-15-2-1), enforcing ALL RESTRICTED APPLICATION PACKAGES (S-1-15-2-2)
  - **NoChild:** Sets PROCESS_CREATION_CHILD_PROCESS_RESTRICTED
  - **NoClipboard / NoDesktopSys:** Sets Job Object UI restrictions (JOB_OBJECT_UILIMIT_READCLIPBOARD, JOB_OBJECT_UILIMIT_DESKTOP, etc.)
  - **ASLR / CFG / CET:** Toggles HighEntropyAslr, ControlFlowGuard, and hardware CET shadow stacks

### 6. Network & Capabilities
* **User Overview:** Gated networking and hardware toggles (Microphone, Camera, Location, USB/HID)
* **DEV NOTE:** Zero ticked network capabilities engages AutoOfflineBlock, generating Windows Defender Firewall block rules targeting the container SID. Block private LAN adds outbound block filters for RFC1918 / gateway subnets. Dev.UsbHidMode applies access rights to device interface GUIDs via setupapi class enumerations

### 7. Env & Quotas
* **User Overview:** Lets you change environment variable pass-through, desktop isolation, and CPU/memory resource caps.
* **DEV NOTE:** Allowlist mode strips host credentials and constructs an explicit null-terminated environment block passed to CreateProcessW (CREATE_UNICODE_ENVIRONMENT). Quotas configure JobObjectExtendedLimitInformation and JobObjectCpuRateControlInformation.

### 8. Presets (*n)
* **User Overview:** Create reusable, shareable sandbox configs
* **DEV NOTE:** Any path containing *1 through *999 placeholders automatically unlocks the Preset tab. Presets are exported to standalone .acmpreset.json files and sanitized (stripping host-specific SIDs, custom desktops, and dangerous write keys) before import. Replace any part of your set up paths with *n (e.g. *1, *2) and the tab appears

---

## Desktop Hotkeys and Navigation

When running inside an isolated desktop:
* **Right Ctrl** - Returns you to your main Windows desktop
* **Alt + Tab** - Opens the internal window switcher to cycle between apps on the isolated desktop.
* **Win Key** - Toggles the desktop application launcher menu
