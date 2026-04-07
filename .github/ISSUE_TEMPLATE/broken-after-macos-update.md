---
name: Broken after macOS update
about: Tailscale stopped working alongside Mullvad after a macOS update
labels: macos-update
---

**macOS version before update:**


**macOS version after update:**


**Symptoms:**
<!-- e.g. Tailscale hosts unreachable, Magic DNS not resolving, etc. -->


**Output of `sudo pfctl -sr`:**
<!-- Paste full output. This shows the active PF ruleset. -->

```

```

**Output of `sudo pfctl -a tailscale -sr`:**
<!-- This shows whether the Tailscale anchor is loaded. -->

```

```

**Contents of `/etc/pf.conf`:**
<!-- Check whether the anchor lines are still present. macOS updates can reset this file. -->

```

```

**Did re-running `install.sh` fix it?**
<!-- yes / no — if re-running the install script fixed the issue, the macOS update likely overwrote pf.conf. -->
