#!/usr/bin/env bash
# nexus-healer — reparo preventivo do NEXUS workbench (neural-node)
# Roda via systemd timer (a cada 60s) + no boot (90s pós-boot), como root.
# Idempotente: se tudo estiver saudável, não faz NADA além de logar UMA linha.
set -u

LOG=/var/log/nexus-healer.log
STATE=/var/lib/nexus-healer
COMPOSE=/var/home/bruno/repos/NEXUS/compose.yaml
export PROJECT_PATH=/var/home/bruno/repos
SERVICES="postgres qdrant ollama engine mcp gateway"
CONTAINERS="nexus-postgres nexus-qdrant nexus-ollama nexus-engine nexus-mcp nexus-gateway"
HEALTHCHECKED="nexus-postgres nexus-gateway"
PIPELINE="http://127.0.0.1:8000/pipeline-status"

mkdir -p "$STATE/restarts"
now() { date +%FT%T; }
log() { printf '%s %s\n' "$(now)" "$*" >> "$LOG"; }
alert() { msg="$*"; log "ALERT $msg"; logger -p daemon.emerg "NEXUS-HEALER $msg"; }

# espera docker acordar (pós-boot)
for i in $(seq 1 45); do
  docker info >/dev/null 2>&1 && break
  sleep 2
done
docker info >/dev/null 2>&1 || { log "FATAL docker indisponivel"; exit 1; }

# 1) containers caídos -> reconcilia com compose (respeita depends_on)
down=""
for c in $CONTAINERS; do
  [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = "true" ] || down="$down $c"
done
if [ -n "$down" ]; then
  log "REPAIR containers down:$down -> compose up -d"
  docker compose -f "$COMPOSE" up -d >> "$LOG" 2>&1 || log "FAIL compose up -d"
  touch "$STATE/repaired_at"
else
  log "OK stack $(docker ps --filter name=^/nexus -q | wc -l)/6"
fi

# 2) healthchecks persistentes -> restaure o container
for c in $HEALTHCHECKED; do
  st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$c" 2>/dev/null)
  [ "$st" = "unhealthy" ] && { log "REPAIR $c unhealthy -> restart"; docker restart "$c" >> "$LOG" 2>&1; touch "$STATE/restarts/$(date +%s)-$c"; }
done

# 3) gateway endpoint do engine (pipeline vivo de verdade)
if ! curl -sf -m 8 "$PIPELINE" >/dev/null 2>&1; then
  if [ "$(docker inspect -f '{{.State.Running}}' nexus-engine 2>/dev/null)" = "true" ]; then
    log "REPAIR engine endpoint morto (container up) -> restart engine"
    docker restart nexus-engine >> "$LOG" 2>&1
    touch "$STATE/restarts/$(date +%s)-nexus-engine"
  fi
fi

# 4) detecção de OOM (cgroup E host) + ALERTA loud (erro silencioso -> visível)
#    Host-level: 'Out of memory: Killed process' (o kernel matou um processo
#    de system.slice — esse era o assassino silencioso que derrubava o nó).
#    Cgroup-level: 'Memory cgroup out of memory' (limite do container).
host_oom=$(dmesg 2>/dev/null | grep -c "Out of memory: Killed process" || true)
cgrp_oom=$(dmesg 2>/dev/null | grep -c "Memory cgroup out of memory" || true)
n=$((host_oom + cgrp_oom))
last=$(cat "$STATE/last_oom_count" 2>/dev/null || echo 0)
if [ "$n" -gt "$last" ] 2>/dev/null; then
  killed=$(dmesg 2>/dev/null | grep "Killed process" | tail -1)
  victim=$(dmesg 2>/dev/null | grep -E "Memory cgroup out of memory|Out of memory" | tail -1)
  alert "OOM EVENT (eram ${last}, agora ${n}; host=${host_oom} cgrp=${cgrp_oom}): ${killed} | ${victim}"
fi
printf '%s\n' "$n" > "$STATE/last_oom_count"

# 5) guard de memória (sem RAM mata o host) — observa/avisa/age via zram
avail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
swap=$(awk '/SwapFree/{print int($2/1024)}' /proc/meminfo)
if [ "$avail" -lt 1000 ]; then
  alert "MemAvailable=${avail}Mi (<1Gi), SwapFree=${swap}Mi — reduzir carga; engine auto-baixa concurrency"
else
  [ "${1:-}" = "--verbose" ] && log "mem avail=${avail}Mi swap=${swap}Mi"
fi

# 6) crash-loop guard: >3 restarts no mesmo container em 30min -> log e pausa reparo dele 30min
recent=$(find "$STATE/restarts" -mmin -30 -name '*nexus-engine' 2>/dev/null | wc -l)
if [ "$recent" -ge 3 ]; then
  alert "PANIC nexus-engine crash-loop (${recent} restarts/30min) — pausa auto-reparo do engine"; true
fi