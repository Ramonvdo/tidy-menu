# Security

## What tidy-menu does on your machine

- Writes registry keys and values for the current user only, under `HKEY_CURRENT_USER`.
  It doesn't write to `HKEY_LOCAL_MACHINE` and never asks for administrator rights.
- Records every key it creates and every value it sets, including the old value, in
  `%LOCALAPPDATA%\tidy-menu\state.json`. The uninstaller uses that file to undo exactly those
  changes.
- Copies `quick-clean.ps1` and `uninstall.ps1` into `%LOCALAPPDATA%\tidy-menu` and points the
  menu at those copies. They run as you, with `-ExecutionPolicy Bypass`.
- Quick Clean deletes files, and only these: the Recycle Bin after you confirm, browser cache
  folders, package manager caches through each tool's own clean command, downloaded crate
  archives, temp files older than 14 days, and Rust `target` folders under project folders you
  named during install. See the README for the full list.
- Makes no network connections, apart from `get.ps1`, which downloads the latest release from
  GitHub when you use the one-line install. Nothing is collected or sent anywhere.

Things to know:

- The menu runs the scripts in `%LOCALAPPDATA%\tidy-menu`. Anything that can edit those files
  can run code as you the next time you click the menu. By default only your account,
  administrators and SYSTEM can write there. Keep it that way.
- `irm ... | iex` runs code from the internet. If you'd rather not, clone the repo, read the
  scripts and run `install.ps1` yourself.

## Reporting a vulnerability

Open a private security advisory on the GitHub repository (the **Security** tab, then **Report a
vulnerability**). Please include your Windows build and the steps to reproduce.
