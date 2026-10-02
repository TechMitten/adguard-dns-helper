# AdGuard DNS Helper

A small Linux setup script to install and run AdGuard DNS CLI as a local DNS resolver.

## What it does

- downloads the latest AdGuard DNS CLI release
- installs it under `/opt/adguard-cli`
- writes a systemd service
- configures DNS-over-HTTPS, DNS-over-TLS, DNS-over-QUIC, or plain DNS
- points your system resolver at `127.0.0.1` so traffic goes through AdGuard locally

## Requirements

- Linux with `systemd`
- root privileges
- `curl`, `tar`, `getent`, and either `dig` or `nslookup`

## Usage

```bash
sudo ./setup.sh
```

Follow the prompts to choose:

- DNS protocol
- upstream resolver URL
- fallback DNS provider

## Notes

- The script will back up your existing `/etc/resolv.conf` before changing it.
- It can also roll back if setup fails.
- You can undo the DNS change by restoring the backup from `/etc/resolv.conf.bak`.

## License

This project is licensed under the MIT License. See `LICENSE` for details.
