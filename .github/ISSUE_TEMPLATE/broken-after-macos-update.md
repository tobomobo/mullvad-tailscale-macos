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
<!-- Paste the relevant tailscale/mullvad rules if possible. Redact public IPs, hostnames, or unrelated local subnets before posting. -->

```

```

**Output of `sudo pfctl -a tailscale -sr`:**
<!-- This shows whether the Tailscale anchor is loaded. -->

```

```

**Contents of `/etc/pf.conf`:**
<!-- Paste only the tailscale anchor block and nearby lines if possible. Redact unrelated rules, hostnames, and local addressing before posting. -->

```

```

**Did re-running `install.sh` fix it?**
<!-- yes / no — if re-running the install script fixed the issue, the macOS update likely overwrote pf.conf. -->
