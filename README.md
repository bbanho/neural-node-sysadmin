# neural-node-sysadmin

Hardening anti-OOM + visibilidade de erros silenciosos para o NEXUS workbench
(`neural-node`, 8GB RAM, GTX 1660 SUPER, 6 containers docker).

## Problema (boots de 2026-08-17 a 2026-08-19)

O kernel OOM killer era o assassino silencioso do nó:

- **OOM de cgroup** (fix antigo): `nexus-postgres` com `mem_limit=256M` era
  morto no boot (`Memory cgroup out of memory: Killed process ... postgres`).
  Corrigido em `~/handoff-2026-08-19.md` (768M + swap 1536M).
- **OOM de host** (este fix): sob pressão rápida de RAM (ingest + 2 llama-server
  + postgres catch-up + GUI), o kernel OOM mata processos de `system.slice`
  sem aviso. No boot de 2026-08-19 22:14:56 `system.slice` recebeu um kill do
  kernel; o journal veio corrompido na sequência (`Dirty bit ... Fs was not
  properly unmounted`) — o nó ficou inacessível/inconsistente e o operador só
  recuperou via console físico. `systemd-oomd` reage a pressão sustentada
  (30s+); a rampa é rápida demais — o kernel dispara antes.

## Fix deste repo

| O quê | Onde | Efeito |
|---|---|---|
| `OOMScoreAdjust=-900` em sshd/tailscaled/containerd/docker | `/etc/systemd/system/*.service.d/oom-protect.conf` | Mesmo que o kernel OOM dispare, ele escolhe a vítima entre os containers (llama-server ~1GB, qdrant, engine) — que têm restart automático — e **nunca** a porta de acesso / runtime. |
| `vm.swappiness=60` + `vm.page-cluster=0` | `/etc/sysctl.d/90-neural-node-memory.conf` | Faz o swap zram (comprimido em RAM) absorver os picos de memória em vez de o kernel sair matando. |
| Healer detecta OOM de host E cgroup + `logger -p daemon.emerg` | `/usr/local/sbin/nexus-healer.sh` | Erro silencioso vira ALERTA no journal/log (`/var/log/nexus-healer.log`) com PID/vítima. |

## Instalar / aplicar

```bash
sudo ./install/install.sh
```

Idempotente; re-executar à vontade.

## O que NÃO conserta (observado, não bloqueia)

- `ata1.00 FLUSH CACHE EXT ... ABRT` transiente num boot (link resetou e
  recuperou — `EH complete`). Rodar `smartctl -a /dev/sda` de vez em quando para
  vigiar o SSD de 360GB (sistema).
- Ruído de `setroubleshoot`/SELinux e `firewalld NAME_CONFLICT docker-forwarding`
  no journal: cosmético.