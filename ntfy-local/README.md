# Local ntfy

Self-hosted ntfy service for backbone alerts.

- Service: `ntfy-backbone.service`
- Container: `docker.io/binwiederhier/ntfy:latest`
- Local publish endpoint: `http://127.0.0.1:8099/backbone-alerts`
- LAN subscribe endpoint: `http://receiver-a:8099/backbone-alerts` or `http://10.10.10.80:8099/backbone-alerts`

Install shape:

```bash
sudo install -d -m 755 /etc/ntfy-backbone /var/lib/ntfy-backbone/cache
sudo install -m 644 server.yml /etc/ntfy-backbone/server.yml
sudo install -m 644 ntfy-backbone.service /etc/systemd/system/ntfy-backbone.service
sudo systemctl daemon-reload
sudo systemctl enable --now ntfy-backbone.service
```

