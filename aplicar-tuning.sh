#!/usr/bin/env bash
#
# aplicar-tuning.sh - aplica o baseline de performance para VMs Windows migradas
# no OpenShift Virtualization: enlightenments Hyper-V, clock, grace period e
# ioThreads. Opcionalmente o tuning de alto trafego (multiqueue de rede/disco).
#
# Autocontido: os YAMLs estao embutidos aqui dentro. So' precisa de `oc`, e de
# `virtctl` apenas se usar --restart.
#
# O patch e' um merge (--type merge): o Kubernetes aplica so' as diferencas e
# preserva o que nao esta no patch (cpu, disks, interfaces, volumes). NAO toca
# em CPU de proposito: VM migrada ja' tem cpu explicito e correto.
#
# Antes de aplicar, confirma que a VM e' Windows (falha seguro: aborta se nao
# conseguir provar). Nunca aplica enlightenments de Windows num Linux.
#
# Uso:
#   aplicar-tuning.sh -n NS -vm NOME [opcoes]
#
# Opcoes:
#   -n, --namespace NS   namespace da VM (obrigatorio)
#   -vm NOME             nome da VM (obrigatorio)
#   --context CTX        contexto do oc/virtctl
#   --tuning             aplica tambem o tuning de alto trafego (multiqueue)
#   --restart            apos aplicar, reinicia a VM (shutdown completo + start)
#                        para que as mudancas de dominio entrem. Precisa virtctl.
#   --dry-run            mostra o que seria aplicado (server-side), sem gravar
#   -h, --help           esta ajuda
#
set -euo pipefail

NS=""; VM=""; CTX=""; TUNING=0; RESTART=0; DRYRUN=0

usage() { sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--namespace) NS="$2"; shift 2 ;;
    -vm|--vm)       VM="$2"; shift 2 ;;
    --context)      CTX="$2"; shift 2 ;;
    --tuning)       TUNING=1; shift ;;
    --restart)      RESTART=1; shift ;;
    --dry-run)      DRYRUN=1; shift ;;
    -h|--help)      usage 0 ;;
    *) echo "opcao desconhecida: $1" >&2; usage 2 ;;
  esac
done
[ -n "$NS" ] && [ -n "$VM" ] || { echo "faltou -n NS e/ou -vm NOME" >&2; usage 2; }

OC=(oc); [ -n "$CTX" ] && OC+=(--context "$CTX")
die() { echo "ERRO: $*" >&2; exit 1; }
log() { echo ">> $*"; }

# ---------------------------------------------------------------- YAMLs

BASELINE=$(cat <<'YAML'
spec:
  template:
    spec:
      terminationGracePeriodSeconds: 3600
      domain:
        features:
          acpi: {}
          apic: {}
          hyperv:
            relaxed: {}
            vapic: {}
            vpindex: {}
            synic: {}
            synictimer:
              direct: {}
            spinlocks:
              spinlocks: 8191
            tlbflush: {}
            ipi: {}
            runtime: {}
            reset: {}
            frequencies: {}
            reenlightenment: {}
        clock:
          utc: {}
          timer:
            hpet:
              present: false
            pit:
              tickPolicy: delay
            rtc:
              tickPolicy: catchup
            hyperv: {}
        ioThreadsPolicy: auto
        devices:
          inputs:
            - name: tablet
              type: tablet
              bus: usb
YAML
)

TUNING_YAML=$(cat <<'YAML'
spec:
  template:
    spec:
      domain:
        devices:
          blockMultiQueue: true
          networkInterfaceMultiqueue: true
YAML
)

# ---------------------------------------------------------------- guard de SO

log "Verificando que $NS/$VM e' Windows..."
OSID=$("${OC[@]}" get vmi "$VM" -n "$NS" -o jsonpath='{.status.guestOSInfo.id}' 2>/dev/null || true)
PREF=$("${OC[@]}" get vm  "$VM" -n "$NS" -o jsonpath='{.spec.preference.name}' 2>/dev/null || true)
ANNO=$("${OC[@]}" get vm  "$VM" -n "$NS" -o jsonpath='{.spec.template.metadata.annotations.vm\.kubevirt\.io/os}' 2>/dev/null || true)

if [ "$OSID" = "mswindows" ]; then
  log "Windows confirmado pelo agente (guestOSInfo.id=mswindows)."
elif printf '%s' "$PREF" | grep -qiE '^win'; then
  log "Windows pela preference ($PREF). Agente nao reportou; sinal declarativo."
elif printf '%s' "$ANNO" | grep -qiE 'win'; then
  log "Windows pela annotation vm.kubevirt.io/os=$ANNO."
else
  die "nao foi possivel confirmar que $NS/$VM e' Windows (guestOSInfo.id='$OSID', preference='$PREF', os-anno='$ANNO'). Patch abortado."
fi

# ---------------------------------------------------------------- aplicar

# Os YAMLs embutidos sao materializados em arquivos temporarios e aplicados com
# --patch-file (que aceita YAML de forma confiavel, diferente de -p). O script
# continua autocontido: o conteudo mora aqui dentro, o arquivo e' so' de runtime.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
printf '%s\n' "$BASELINE"    > "$TMP/baseline.yaml"
printf '%s\n' "$TUNING_YAML" > "$TMP/tuning.yaml"

DRYFLAG=(); [ "$DRYRUN" = 1 ] && DRYFLAG=(--dry-run=server)

log "Aplicando baseline Windows (merge)${DRYRUN:+ [dry-run]}..."
"${OC[@]}" patch vm "$VM" -n "$NS" --type merge "${DRYFLAG[@]}" --patch-file "$TMP/baseline.yaml"

if [ "$TUNING" = 1 ]; then
  log "Aplicando tuning de alto trafego (multiqueue)..."
  "${OC[@]}" patch vm "$VM" -n "$NS" --type merge "${DRYFLAG[@]}" --patch-file "$TMP/tuning.yaml"
fi

if [ "$DRYRUN" = 1 ]; then
  log "dry-run: nada foi gravado. Remova --dry-run para aplicar de verdade."
  exit 0
fi

# ---------------------------------------------------------------- restart

if [ "$RESTART" = 1 ]; then
  command -v virtctl >/dev/null 2>&1 || die "virtctl nao encontrado; reinicie a VM manualmente para aplicar as mudancas."
  log "Reiniciando a VM (shutdown completo + start) para aplicar..."
  virtctl restart "$VM" -n "$NS" ${CTX:+--context "$CTX"}
  log "  restart disparado; aguardando a VMI voltar..."
  for i in $(seq 1 30); do
    PH=$("${OC[@]}" get vmi "$VM" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    [ "$PH" = "Running" ] && break
    sleep 4
  done
else
  log "As mudancas sao de dominio: so' entram com shutdown completo + start."
  log "Rode com --restart, ou reinicie a VM quando for conveniente."
fi

# ---------------------------------------------------------------- verificar

log "Verificando o resultado..."
# No objeto VM (confirma que o patch gravou):
HV_VM=$("${OC[@]}" get vm "$VM" -n "$NS" -o jsonpath='{.spec.template.spec.domain.features.hyperv}' 2>/dev/null || true)
if [ -n "$HV_VM" ]; then
  log "  VM: features.hyperv presente no spec."
else
  die "o patch nao refletiu no spec da VM. Verifique manualmente."
fi
# No VMI em execucao (confirma que esta no dominio ativo):
HV_VMI=$("${OC[@]}" get vmi "$VM" -n "$NS" -o jsonpath='{.spec.domain.features.hyperv.synic}' 2>/dev/null || true)
if [ -n "$HV_VMI" ]; then
  log "  VMI em execucao JA' carrega os enlightenments (synic presente)."
else
  log "  VMI ainda NAO carrega os enlightenments (reinicie para aplicar)."
fi

log "Concluido."
