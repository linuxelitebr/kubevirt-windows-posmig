#!/usr/bin/env bash
#
# preparar-vm.sh - governador do pos-migracao de VM Windows (VMware -> OpenShift
# Virtualization). Roda as acoes na ordem do procedimento, confere o resultado
# de cada uma, orquestra os reboots (espera a VM voltar + agente reconectar),
# faz retry do que e' transiente, para no que e' terminal, e reporta no fim.
#
# Delega o patch de tuning Hyper-V ao aplicar-tuning.sh (que mora ao lado); o
# reboot final e' do proprio governador (mesma espera robusta dos outros reboots).
# Precisa de: guest-run, oc, virtctl, e dos arquivos do kit (o .ps1 e o
# aplicar-tuning.sh) na mesma pasta.
#
# SEGURANCA: por padrao so' mostra o PLANO (dry-run). So' executa de verdade com
# --yes. Ele reinicia a VM e remove o VMware Tools; confirme a VM antes.
#
# Uso:
#   preparar-vm.sh -n NS -vm VM [opcoes]
#
# Opcoes:
#   -n, --namespace NS    namespace da VM (obrigatorio)
#   -vm NOME              nome da VM (obrigatorio)
#   --yes                 executa de verdade (sem isso, so' mostra o plano)
#   --drivers             inclui a atualizacao de drivers virtio (padrao: nao)
#   --media-source X      fonte dos drivers: Auto|NAS|URL|Local (padrao: Auto)
#   --media-file ARQ      MSI local a empurrar antes (para --media-source Local)
#   --nas-path UNC        caminho UNC do NAS (fonte NAS; ex '\\srv\share\virtio')
#   --download-url URL    URL base alternativa para a fonte URL
#   --local-media-path P  pasta na VM com o MSI/EXE ja' colocado (fonte Local)
#   --high-traffic        aplica tambem o tuning de multiqueue (VM de alto trafego)
#   --run-strategy X      no fim, define spec.runStrategy (Always|RerunOnFailure|Manual|Halted)
#   --script ARQ          o .ps1 (padrao: posmig-openshift-windows.ps1 ao lado)
#   --context CTX         contexto do oc/virtctl
#   --fresh               ignora o state-file e comeca do zero
#   -h, --help            esta ajuda
#   (env) GUEST_RUN       caminho do binario guest-run, se nao estiver no PATH
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NS=""; VM=""; CTX=""; YES=0; DRIVERS=0; HIGH=0; FRESH=0
MEDIA_SOURCE="Auto"; MEDIA_FILE=""
NAS_PATH=""; DOWNLOAD_URL=""; LOCAL_MEDIA_PATH=""; RUN_STRATEGY=""
SCRIPT_PS="$HERE/posmig-openshift-windows.ps1"
TUNER="$HERE/aplicar-tuning.sh"

usage() { sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
log()  { echo ">> $*"; }
warn() { echo "!! $*" >&2; }
die()  { echo "ERRO: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--namespace) NS="$2"; shift 2 ;;
    -vm|--vm)       VM="$2"; shift 2 ;;
    --yes)          YES=1; shift ;;
    --drivers)      DRIVERS=1; shift ;;
    --media-source) MEDIA_SOURCE="$2"; shift 2 ;;
    --media-file)   MEDIA_FILE="$2"; shift 2 ;;
    --nas-path)     NAS_PATH="$2"; shift 2 ;;
    --download-url) DOWNLOAD_URL="$2"; shift 2 ;;
    --local-media-path) LOCAL_MEDIA_PATH="$2"; shift 2 ;;
    --run-strategy) RUN_STRATEGY="$2"; shift 2 ;;
    --high-traffic) HIGH=1; shift ;;
    --script)       SCRIPT_PS="$2"; shift 2 ;;
    --context)      CTX="$2"; shift 2 ;;
    --fresh)        FRESH=1; shift ;;
    -h|--help)      usage 0 ;;
    *) echo "opcao desconhecida: $1" >&2; usage 2 ;;
  esac
done
[ -n "$NS" ] && [ -n "$VM" ] || { echo "faltou -n NS e/ou -vm NOME" >&2; usage 2; }
if [ -n "$RUN_STRATEGY" ]; then
  case "$RUN_STRATEGY" in
    Always|RerunOnFailure|Manual|Halted) ;;
    *) echo "--run-strategy invalido: '$RUN_STRATEGY' (use Always|RerunOnFailure|Manual|Halted)" >&2; exit 2 ;;
  esac
fi

# HIGH e' 0/1 (string): nao usar ${HIGH:+...}, porque "0" e' nao-vazio e dispara.
TUNEARG=""; MQ=""
[ "$HIGH" = 1 ] && { TUNEARG="--tuning"; MQ=" + multiqueue"; }

OC=(oc); [ -n "$CTX" ] && OC+=(--context "$CTX")
# Binario do guest-run: 'guest-run' no PATH por padrao; sobrescreva com a env
# GUEST_RUN=/caminho/guest-run se nao quiser mexer no PATH.
GRBIN="${GUEST_RUN:-guest-run}"
GR=("$GRBIN"); [ -n "$CTX" ] && GR+=(-context "$CTX")
command -v "$GRBIN" >/dev/null 2>&1 || die "guest-run nao encontrado (nem no PATH nem em GUEST_RUN='$GRBIN')"
command -v oc        >/dev/null 2>&1 || die "oc nao esta no PATH"

DEST_PS='C:\Windows\Temp\posmig.ps1'
STATE="${TMPDIR:-/tmp}/preparar-vm_${NS}_${VM}.state"
[ "$FRESH" = 1 ] && rm -f "$STATE"
touch "$STATE" 2>/dev/null || true

done_step()  { grep -qxF "$1" "$STATE" 2>/dev/null; }
mark_step()  { echo "$1" >> "$STATE"; }

# ---------------------------------------------------------------- guard de SO

guard_windows() {
  local osid pref anno
  osid=$("${OC[@]}" get vmi "$VM" -n "$NS" -o jsonpath='{.status.guestOSInfo.id}' 2>/dev/null || true)
  pref=$("${OC[@]}" get vm  "$VM" -n "$NS" -o jsonpath='{.spec.preference.name}' 2>/dev/null || true)
  anno=$("${OC[@]}" get vm  "$VM" -n "$NS" -o jsonpath='{.spec.template.metadata.annotations.vm\.kubevirt\.io/os}' 2>/dev/null || true)
  if [ "$osid" = "mswindows" ]; then log "Windows confirmado (agente: guestOSInfo.id=mswindows)."; return 0; fi
  if printf '%s' "$pref" | grep -qiE '^win'; then log "Windows pela preference ($pref)."; return 0; fi
  if printf '%s' "$anno" | grep -qiE 'win'; then log "Windows pela annotation ($anno)."; return 0; fi
  die "nao confirmei que $NS/$VM e' Windows (osid='$osid' pref='$pref' anno='$anno'). Abortado."
}

# ---------------------------------------------------------------- executar acao

# run_action LABEL "ACAO [PARAMS]" "codigos_ok" "timeout"
# Roda o .ps1 via guest-run. Retry no que e' transiente (guest-run exit 2:
# agente fora, timeout, pod sem achar). Para no que e' terminal (codigo fora da
# lista de OK). Idempotente: pula se ja' consta no state-file.
run_action() {
  local label="$1" invoke="$2" okcodes="$3" tmo="${4:-900s}"
  if done_step "$label"; then log "[$label] ja' concluido (state), pulando."; return 0; fi

  local attempt rc
  for attempt in 1 2 3; do
    log "[$label] executando (tentativa $attempt)..."
    set +e
    "${GR[@]}" -n "$NS" -vm "$VM" -timeout "$tmo" -ps \
      "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ${DEST_PS} ${invoke} 2> C:\\Windows\\Temp\\posmig-stderr.log; exit \$LASTEXITCODE"
    rc=$?
    set -e
    if [ "$rc" = 2 ]; then
      warn "[$label] guest-run nao alcancou a VM (transiente). Retry em $((attempt*10))s..."
      sleep $((attempt*10)); continue
    fi
    for ok in $okcodes; do
      if [ "$rc" = "$ok" ]; then
        log "[$label] OK (exit $rc)."
        mark_step "$label"; return 0
      fi
    done
    die "[$label] falhou de forma terminal (exit $rc). Veja a saida acima / o log na VM. Procedimento parado."
  done
  die "[$label] nao completou apos 3 tentativas (transiente persistente)."
}

reboot_and_wait() {
  local label="$1"
  if done_step "$label"; then log "[$label] ja' concluido (state), pulando."; return 0; fi
  log "[$label] reiniciando a VM..."
  local old_uid new_uid ph ag up=0
  old_uid=$("${OC[@]}" get vmi "$VM" -n "$NS" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)
  virtctl restart "$VM" -n "$NS" ${CTX:+--context "$CTX"} || die "[$label] falha ao disparar o restart"
  log "[$label] aguardando a VM voltar (nova VMI, Running, agente conectado)..."
  for _ in $(seq 1 90); do
    new_uid=$("${OC[@]}" get vmi "$VM" -n "$NS" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)
    ph=$("${OC[@]}" get vmi "$VM" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    ag=$("${OC[@]}" get vmi "$VM" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="AgentConnected")].status}' 2>/dev/null || true)
    if [ -n "$new_uid" ] && [ "$new_uid" != "$old_uid" ] && [ "$ph" = "Running" ] && [ "$ag" = "True" ]; then up=1; break; fi
    sleep 10
  done
  [ "$up" = 1 ] || die "[$label] a VM nao voltou (nova VMI Running + agente) no tempo esperado."
  log "[$label] VM de volta."
  mark_step "$label"
}

# ---------------------------------------------------------------- plano

build_plan() {
  echo "  guard: confirmar que $NS/$VM e' Windows"
  echo "  push:  $SCRIPT_PS -> $DEST_PS"
  echo "  Fase 1:"
  echo "    - RemoveVMwareTools"
  echo "    - DisablePageFile"
  if [ "$DRIVERS" = 1 ]; then
    echo "    - UpdateDrivers (-MediaSource $MEDIA_SOURCE)${MEDIA_FILE:+ + push $MEDIA_FILE}"
    [ -n "$NAS_PATH" ]         && echo "        NasPath=$NAS_PATH"
    [ -n "$DOWNLOAD_URL" ]     && echo "        DownloadUrl=$DOWNLOAD_URL"
    [ -n "$LOCAL_MEDIA_PATH" ] && echo "        LocalMediaPath=$LOCAL_MEDIA_PATH"
  fi
  echo "    - SetMTU (1500)"
  echo "    - REBOOT + espera"
  echo "  Fase 2:"
  echo "    - EnablePageFile"
  echo "    - Tuning Hyper-V (baseline$MQ): patch via aplicar-tuning.sh"
  echo "    - REBOOT FINAL + espera (aplica pagefile + enlightenments)"
  [ -n "$RUN_STRATEGY" ] && echo "  Pos: runStrategy -> $RUN_STRATEGY"
}

# ---------------------------------------------------------------- main

log "Alvo: $NS/$VM"
guard_windows

if [ "$YES" != 1 ]; then
  echo
  echo "=== PLANO (dry-run; nada sera executado) ==="
  build_plan
  echo
  log "Validando o patch de tuning (server dry-run)..."
  [ -x "$TUNER" ] || die "aplicar-tuning.sh nao encontrado/executavel em $TUNER"
  "$TUNER" -n "$NS" -vm "$VM" ${CTX:+--context "$CTX"} $TUNEARG --dry-run || warn "o dry-run do tuning reportou algo; revise acima."
  echo
  log "Isto foi um dry-run. Para executar de verdade, rode de novo com --yes."
  exit 0
fi

# --- execucao real ---
[ -f "$SCRIPT_PS" ] || die "script .ps1 nao encontrado em $SCRIPT_PS (use --script)"
[ -x "$TUNER" ]     || die "aplicar-tuning.sh nao encontrado/executavel em $TUNER"
command -v virtctl >/dev/null || die "virtctl nao esta no PATH (necessario para os reboots)"

if done_step "push-ps"; then
  log "[push-ps] ja' concluido (state), pulando."
else
  log "Empurrando o script para a VM..."
  "${GR[@]}" -n "$NS" -vm "$VM" -put "$SCRIPT_PS" -dest "$DEST_PS"
  mark_step "push-ps"
fi

# Fase 1
run_action "remove-vmware-tools" "-Action RemoveVMwareTools" "0"
run_action "disable-pagefile"    "-Action DisablePageFile"   "0"
if [ "$DRIVERS" = 1 ]; then
  # pasta Local dentro da VM (o padrao do .ps1 quando --local-media-path e' vazio)
  local_dest="${LOCAL_MEDIA_PATH:-C:\\Windows\\Temp\\posmig-virtio-local}"
  if [ "$MEDIA_SOURCE" = "Local" ] && [ -n "$MEDIA_FILE" ] && ! done_step "push-media"; then
    log "Empurrando a midia de drivers ($MEDIA_FILE) para ${local_dest} ..."
    "${GR[@]}" -n "$NS" -vm "$VM" -timeout 1800s -put "$MEDIA_FILE" -dest "${local_dest}\\virtio-win-gt-x64.msi"
    mark_step "push-media"
  fi
  # Monta a invocacao com as fontes informadas. Aspas simples para o PowerShell
  # externo; barras e espacos sobrevivem porque o -ps do guest-run vai como
  # -EncodedCommand (UTF-16LE base64), sem reparse de cmd/shell no meio.
  drv="-Action UpdateDrivers -MediaSource $MEDIA_SOURCE"
  [ -n "$NAS_PATH" ]         && drv="$drv -NasPath '$NAS_PATH'"
  [ -n "$DOWNLOAD_URL" ]     && drv="$drv -DownloadUrl '$DOWNLOAD_URL'"
  [ -n "$LOCAL_MEDIA_PATH" ] && drv="$drv -LocalMediaPath '$LOCAL_MEDIA_PATH'"
  # OK: 0=instalou, 10=ja' tinha igual/mais novo (ambos aceitaveis para seguir)
  run_action "update-drivers" "$drv" "0 10"
fi
run_action "set-mtu" "-Action SetMTU" "0"

reboot_and_wait "reboot-fase1"

# Fase 2
run_action "enable-pagefile" "-Action EnablePageFile" "0"

# Tuning Hyper-V: so' o patch (sem --restart). O reboot final e' do governador,
# logo abaixo, com a mesma espera robusta (nova VMI + agente) dos outros reboots.
# Esse unico reboot aplica de uma vez o pagefile reativado e os enlightenments.
if done_step "tuning"; then
  log "[tuning] ja' concluido (state), pulando."
else
  log "Aplicando tuning Hyper-V (patch, sem reiniciar aqui)..."
  "$TUNER" -n "$NS" -vm "$VM" ${CTX:+--context "$CTX"} $TUNEARG
  mark_step "tuning"
fi

reboot_and_wait "reboot-fase2-final"

# runStrategy final (padrao de alguns clientes: RerunOnFailure). Patch minimo:
# so muda spec.runStrategy, nao reinicia a VM (so muda a politica pros proximos
# stops). Nota: se a VM ainda usar o campo antigo spec.running, este patch falha
# (running e runStrategy sao mutuamente exclusivos); ai acrescente "running":null.
if [ -n "$RUN_STRATEGY" ]; then
  if done_step "set-runstrategy"; then
    log "[set-runstrategy] ja' concluido (state), pulando."
  else
    cur=$("${OC[@]}" get vm "$VM" -n "$NS" -o jsonpath='{.spec.runStrategy}' 2>/dev/null || true)
    if [ "$cur" = "$RUN_STRATEGY" ]; then
      log "[set-runstrategy] ja' e' $RUN_STRATEGY; nada a fazer."
    else
      log "Definindo runStrategy=$RUN_STRATEGY..."
      "${OC[@]}" patch vm "$VM" -n "$NS" --type merge -p "{\"spec\":{\"runStrategy\":\"$RUN_STRATEGY\"}}" || die "falha ao setar runStrategy"
      new=$("${OC[@]}" get vm "$VM" -n "$NS" -o jsonpath='{.spec.runStrategy}' 2>/dev/null || true)
      [ "$new" = "$RUN_STRATEGY" ] || die "runStrategy nao refletiu (got '$new')"
      log "[set-runstrategy] runStrategy=$new"
    fi
    mark_step "set-runstrategy"
  fi
fi

# ---------------------------------------------------------------- relatorio

echo
echo "=== RELATORIO ==="
HV=$("${OC[@]}" get vmi "$VM" -n "$NS" -o jsonpath='{.spec.domain.features.hyperv.synic}' 2>/dev/null || true)
MTU=$("${OC[@]}" get vmi "$VM" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)
echo "  VM: $NS/$VM"
echo "  passos concluidos: $(tr '\n' ' ' < "$STATE")"
[ -n "$HV" ] && echo "  enlightenments Hyper-V no dominio ativo: SIM" || echo "  enlightenments Hyper-V no dominio ativo: NAO (verifique)"
echo "  VMI: ${MTU:-?}"
log "Pos-migracao concluido. State: $STATE"
