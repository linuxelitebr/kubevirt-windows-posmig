# Runbook: preparar VM Windows migrada via guest-run

Prepara uma VM Windows recém-migrada do VMware pro OpenShift Virtualization pelo 
canal do qemu-guest-agent. Duas partes: o trabalho DENTRO da VM (remover VMware 
Tools, pagefile, drivers, MTU) e o tuning no CLUSTER (enlightenments Hyper-V).

## Conteúdo do kit

| Arquivo | Para que |
| --- | --- |
| `README.md` | este guia |
| `preparar-vm.sh` | governador: roda o procedimento inteiro (fases 1 a 3) de ponta a ponta |
| `posmig-openshift-windows.ps1` | roda DENTRO da VM; empurrado e invocado pelo guest-run |
| `aplicar-tuning.sh` | aplica os enlightenments Hyper-V no CLUSTER (autocontido) |
| `hyperv-baseline.yaml` | o patch de baseline (referência; já embutido no .sh) |
| `hyperv-tuning-adicional.yaml` | o patch opcional de alto tráfego (referência; já embutido no .sh) |

A ferramenta `guest-run` (que dirige tudo) NÃO vem no kit: baixe o binário dos
releases (ver Pré-requisitos) e ponha no PATH.

Você fornece separadamente: o **`virtio-win-gt-x64.msi`** (do NAS ou baixado),
necessário só no cenário de VM sem rede (Fase 1, passo 4, opção d).

## Modo automático (o jeito fácil): preparar-vm.sh

O `preparar-vm.sh` é o governador: ele roda o procedimento inteiro numa tacada,
na ordem certa, conferindo cada passo, orquestrando os dois reboots (dispara o
restart e espera a VM voltar com o agente conectado antes de seguir), fazendo
retry do que é transiente e parando no que é terminal. No fim, ele reporta o
que fez. O resto deste runbook (fases 1 a 3, mais abaixo) é o modo manual: o
mesmo procedimento, passo a passo, é exatamente o que o governador faz por baixo.

**Por padrão ele NÃO executa nada: só mostra o plano (dry-run).** Ele reinicia a
VM e remove o VMware Tools, então a execução de verdade exige o `--yes` explícito.

```bash
# 1) ver o plano, sem tocar em nada (valida até o patch de tuning em server dry-run):
./preparar-vm.sh -n NS -vm VM

# 2) executar de verdade (baseline: sem drivers, sem multiqueue):
./preparar-vm.sh -n NS -vm VM --yes

# 3) incluindo a atualização de drivers virtio:
./preparar-vm.sh -n NS -vm VM --drivers --yes

# 4) VM de alto tráfego (soma o multiqueue no tuning):
./preparar-vm.sh -n NS -vm VM --high-traffic --yes

# 5) VM sem rede: empurra o MSI local e força a fonte Local:
./preparar-vm.sh -n NS -vm VM --drivers --media-source Local --media-file ./virtio-win-gt-x64.msi --yes

# 6) drivers do NAS:
./preparar-vm.sh -n NS -vm VM --drivers --media-source NAS --nas-path '\\servidor\share\virtio-win-1.9.57' --yes
```

O que ele faz, nessa ordem: empurra o `.ps1` -> RemoveVMwareTools -> DisablePageFile
-> [UpdateDrivers, só com `--drivers`] -> SetMTU -> **reboot + espera** ->
EnablePageFile -> tuning Hyper-V (patch via `aplicar-tuning.sh`, sem reiniciar ali)
-> **reboot final + espera** (esse único reboot aplica o pagefile reativado e os
enlightenments de uma vez) -> [define o runStrategy, só com `--run-strategy`] ->
verifica e reporta. Os dois reboots usam a mesma
espera robusta: dispara o restart e só segue quando a VMI volta (nova instância)
com o agente reconectado.

Flags: `--drivers` (padrão off), `--media-source Auto|NAS|URL|Local`, `--media-file`
(MSI único a empurrar pra fonte Local), `--nas-path UNC`, `--download-url URL`,
`--local-media-path P` (pasta Local já preparada na VM), `--high-traffic`
(multiqueue), `--online-data-disks` (discos de dados offline -> online),
`--run-strategy Always|RerunOnFailure|Manual|Halted` (define o
`spec.runStrategy` no fim), `--script` (o `.ps1`, padrão ao lado), `--context`, `--fresh` (ignora
o state-file e recomeça), `--yes` (executa de verdade).

Sobre `--run-strategy`: no fim do processo o governador seta o `spec.runStrategy`
da VM (handoff pra produção; não reinicia a VM, só muda a política pros próximos
stops). `RerunOnFailure` é o mais comum pra VM migrada: sobe de novo se der falha,
mas respeita um desligamento limpo. Na mão:

```bash
oc patch vm VM -n NS --type merge -p '{"spec":{"runStrategy":"RerunOnFailure"}}'
```

Se a VM ainda usa o campo antigo `spec.running` (deprecado), o patch acima falha
(os dois são mutuamente exclusivos); aí acrescente `"running":null` ao patch. O passo
do governador é não-fatal: se o patch não aplicar, ele avisa e segue (o relatório mostra
o runStrategy final), sem derrubar o resto do pós-migração.

Sobre `--online-data-disks`: VM Windows migrada do VMware costuma trazer os discos
de dados secundários **Offline** no primeiro boot (o Windows aplica a SAN policy
quando o controlador muda pra virtio). Essa flag, na Fase 1, traz os discos de
dados offline (não-boot) pra online, limpa o readonly, e seta a política de disco
novo pra `OnlineAll` (pra não recair num hotplug futuro). Na mão, dentro da VM:

```powershell
Get-Disk | Where-Object { $_.OperationalStatus -eq 'Offline' -and -not $_.IsBoot } |
    ForEach-Object { Set-Disk -Number $_.Number -IsOffline $false; Set-Disk -Number $_.Number -IsReadOnly $false }
```

É opt-in porque trazer um disco online o torna gravável; tem que ser deliberado.

**Idempotente.** Cada passo concluído fica gravado num state-file em
`$TMPDIR/preparar-vm_NS_VM.state`. Se o governador for interrompido no meio (ctrl-C,
a sua máquina caiu durante um reboot), rode o mesmo comando de novo: ele pula o que
já terminou e continua de onde parou. Para recomeçar do zero, use `--fresh`.

> IMPORTANTE: rode o dry-run primeiro, e na primeira vez num ambiente novo valide o
> `--yes` numa VM descartável antes de apontar pra produção. Ele reinicia a VM e
> remove o VMware Tools. Cada ambiente tem seus tempos de boot; o teto de espera por
> reboot é de 15 min (90 x 10s).

## Pré-requisitos

- **`guest-run` no PATH** (ver abaixo). Binário único, roda com o seu oc/kubeconfig.
- `oc` (e `virtctl` para o `--restart` da Fase 3).
- Acesso de `exec` ao pod da VM.
- Agente conectado na VM: `oc get vmi <vm> -o jsonpath='{.status.conditions[?(@.type=="AgentConnected")].status}'` deve dar `True`.
  Em VM migrada pelo MTV com sucesso, o agente já vem instalado. Se não vier,
  este runbook não alcança a VM (é o ovo e a galinha; use o console).

### Instalando o guest-run

A ferramenta `guest-run` dirige tudo. Ela NÃO vem neste repo: baixe o binário dos
releases e deixe acessível como `guest-run`.

1. Baixe o asset do seu SO/arquitetura em
   https://github.com/linuxelitebr/kubevirt-guest-run/releases (versão 0.3.0 ou mais
   nova, que tem o `-put` e o `-put-dir`). Os nomes são assim:

| SO / arquitetura | Asset |
| --- | --- |
| Linux x86_64 | `guest-run_0.3.0_linux_amd64.tar.gz` |
| Linux ARM64 | `guest-run_0.3.0_linux_arm64.tar.gz` |
| macOS Intel | `guest-run_0.3.0_darwin_amd64.tar.gz` |
| macOS Apple Silicon | `guest-run_0.3.0_darwin_arm64.tar.gz` |
| Windows x86_64 | `guest-run_0.3.0_windows_amd64.zip` |

2. Extraia. Dentro vem o binário, chamado **`guest-run`** (no Windows,
   **`guest-run.exe`**), mais LICENSE e README.

3. Deixe o binário chamado `guest-run` numa pasta do PATH:

```bash
tar xzf guest-run_0.3.0_linux_amd64.tar.gz
sudo install guest-run_0.3.0_linux_amd64/guest-run /usr/local/bin/guest-run
guest-run -version   # deve imprimir: guest-run 0.3.0
```

No Windows, copie `guest-run.exe` pra uma pasta que esteja no `Path` (ou adicione a
pasta ao `Path`).

O `preparar-vm.sh` e todos os comandos deste guia chamam `guest-run` pelo nome, sem
caminho, então o binário PRECISA se chamar `guest-run` (ou `guest-run.exe`) e estar
no PATH. Se preferir não mexer no PATH, aponte o governador pro binário com a env
`GUEST_RUN`:

```bash
GUEST_RUN=/caminho/para/guest-run ./preparar-vm.sh -n NS -vm VM
```

Convenção abaixo: `NS` = namespace, `VM` = nome da VM.

## 0. Colocar o script na VM (uma vez)

```bash
guest-run -n NS -vm VM -put ./posmig-openshift-windows.ps1 -dest 'C:\Windows\Temp\posmig.ps1'
```

### Copiar um diretório inteiro pra VM

O jeito direto é o `-put-dir`: num comando só ele zipa o diretório local (sem
precisar do `zip` instalado), empurra e expande na VM com `Expand-Archive`. O
`-dest` é a pasta que vai receber o conteúdo (guest Windows). Precisa do
guest-run 0.3.0+.

```bash
guest-run -n NS -vm VM -timeout 1800s -put-dir ./meudir -dest 'C:\destino\meudir'
```

Num guest-run mais antigo (ou se preferir na mão), o mesmo em três passos: zipa
local, empurra o zip com `-put`, expande na VM. O `Expand-Archive` só lê `.zip`,
nada de `.tar.gz`.

```bash
cd /caminho/pai && zip -r /tmp/meudir.zip meudir
guest-run -n NS -vm VM -timeout 1800s -put /tmp/meudir.zip -dest 'C:\Windows\Temp\meudir.zip'
guest-run -n NS -vm VM -ps 'Expand-Archive -Path C:\Windows\Temp\meudir.zip -DestinationPath C:\destino\meudir -Force'
```

Pra poucos arquivos, o `-put` cria a pasta de destino sozinho:

```bash
guest-run -n NS -vm VM -put ./meudir/app.config -dest 'C:\destino\meudir\app.config'
```

## Como cada ação é chamada

O exit code da ação volta pelo guest-run. O padrão de invocação que propaga o
código corretamente (não use `& script.ps1`, que entra em minishell e perde o
código):

```bash
guest-run -n NS -vm VM -timeout 900s -ps \
  'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\posmig.ps1 -Action <ACAO> <PARAMS> 2> C:\Windows\Temp\posmig-stderr.log; exit $LASTEXITCODE'
```

Cada ação imprime uma linha `RESULT: ...` e sai com um código. `-timeout 900s`
porque instalar driver e remover VMware Tools levam minutos.

## Fase 1 (na ordem do procedimento)

### 1. Remover VMware Tools
```
-Action RemoveVMwareTools
```
Se a VM não tiver VMware Tools (já limpa), reporta "nada a fazer" sem erro.

### 2. Desativar arquivo de paginação
```
-Action DisablePageFile
```

### 4. Atualizar drivers virtio (só se o time pedir)

A ordem do `-MediaSource Auto` é: NAS -> URL -> Local -> (se nada funcionar e a VM
já tiver virtio) só reporta a versão instalada. `NAS`/`URL`/`Local` forçam uma
fonte única. O `-MediaSource` não tem padrão de caminho embutido: a fonte NAS só
roda se você passar `-NasPath`.

**(a) VM tem rede (caso comum):** cadeia automática.
```
-Action UpdateDrivers -MediaSource Auto
```

**(b) Do NAS:** informe o caminho UNC (obrigatório, sem padrão).
```
-Action UpdateDrivers -MediaSource NAS -NasPath '\\servidor\share\virtio-win-1.9.xx'
```

**(c) Da URL:** build estável por padrão, ou passe outra base com `-DownloadUrl`.
```
-Action UpdateDrivers -MediaSource URL
```

**(d) VM SEM rede, com a mídia na mão (uma pasta ou um .zip):** leve a mídia pra
dentro da VM e aponte a fonte Local. O `-LocalMediaPath` tem que ser a pasta que
contém o `virtio-win-gt-x64.msi` DIRETO (o script faz `Join-Path`, não busca
recursiva). O `guest-run -put` move UM arquivo por vez, então:

*d.1 Só o MSI (o mais simples):* empurre pro caminho Local padrão e instale.
```bash
guest-run -n NS -vm VM -timeout 1800s -put ./virtio-win-gt-x64.msi \
  -dest 'C:\Windows\Temp\posmig-virtio-local\virtio-win-gt-x64.msi'
guest-run -n NS -vm VM -timeout 1800s -ps 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\posmig.ps1 -Action UpdateDrivers -MediaSource Local 2> C:\Windows\Temp\posmig-stderr.log; exit $LASTEXITCODE'
```

*d.2 Um .zip (`virtio-win-1.9.57.zip`):* empurre o zip, expanda na VM, confira onde
caiu o MSI, e aponte o `-LocalMediaPath` pra essa pasta.
```bash
guest-run -n NS -vm VM -timeout 1800s -put ./virtio-win-1.9.57.zip \
  -dest 'C:\Windows\Temp\virtio-win-1.9.57.zip'
guest-run -n NS -vm VM -ps 'Expand-Archive -Path C:\Windows\Temp\virtio-win-1.9.57.zip -DestinationPath C:\Windows\Temp\virtio-media -Force'
guest-run -n NS -vm VM -ps 'Get-ChildItem -Recurse -Filter virtio-win-gt-x64.msi C:\Windows\Temp\virtio-media | Select-Object -ExpandProperty FullName'
# use a pasta que o passo acima mostrou (pode ser uma subpasta do zip):
guest-run -n NS -vm VM -timeout 1800s -ps 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\posmig.ps1 -Action UpdateDrivers -MediaSource Local -LocalMediaPath C:\Windows\Temp\virtio-media 2> C:\Windows\Temp\posmig-stderr.log; exit $LASTEXITCODE'
```

*d.3 Uma pasta (`virtio-win-1.9.57\`):* como o `-put` é arquivo-a-arquivo, ou você
zipa a pasta e segue o d.2, ou empurra os dois arquivos-chave direto:
```bash
guest-run -n NS -vm VM -timeout 1800s -put './virtio-win-1.9.57/virtio-win-gt-x64.msi' \
  -dest 'C:\Windows\Temp\posmig-virtio-local\virtio-win-gt-x64.msi'
# opcional, se a pasta tiver o guest-tools:
guest-run -n NS -vm VM -timeout 1800s -put './virtio-win-1.9.57/virtio-win-guest-tools.exe' \
  -dest 'C:\Windows\Temp\posmig-virtio-local\virtio-win-guest-tools.exe'
# instala:
guest-run -n NS -vm VM -timeout 1800s -ps 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\posmig.ps1 -Action UpdateDrivers -MediaSource Local 2> C:\Windows\Temp\posmig-stderr.log; exit $LASTEXITCODE'
```

**O que o script faz com a mídia:** roda `msiexec /i virtio-win-gt-x64.msi /qn
/norestart /L*v <log> ADDLOCAL=ALL` e, se encontrar o `virtio-win-guest-tools.exe`
na mesma pasta, roda ele em seguida (`/install /quiet /norestart ACCEPTEULA=1`).
Valida a integridade do MSI antes (ver mais abaixo) e imprime a linha `RESULT:`.

**Pelo governador:** o `preparar-vm.sh` aceita `--media-file ARQ` (empurra um MSI
único pro caminho Local e usa a fonte Local), `--nas-path UNC`, `--download-url URL`
e `--local-media-path P` (aponta pra uma pasta já preparada como no d.2/d.3).

Códigos de saída do UpdateDrivers (e a linha RESULT):

| exit | RESULT status | significado |
| --- | --- | --- |
| 0  | SUCCESS | drivers instalados (reinicie para aplicar) |
| 10 | SKIPPED_ALREADY_PRESENT | a VM já tem virtio igual ou mais novo; nada mudou |
| 11 | FAILED_NO_VIRTIO | nenhuma fonte funcionou E a VM não tem virtio |
| 13 | FAILED_INSTALL | fonte ok, mas a instalação falhou (veja o log no RESULT) |

### 5. Ajustar MTU para 1500
```
-Action SetMTU
```
(Não rode se a VM usa Jumbo Frame de propósito.)

### 6. Reboot
```
-Action Reboot
```

## Fase 2 (após o Windows reiniciar)

### 3. Reativar arquivo de paginação
```
-Action EnablePageFile
```

### 6. Reboot
```
-Action Reboot
```

## Fase 3: tuning Hyper-V (no cluster)

Os enlightenments Hyper-V não são configurados dentro do Windows: são um patch na
spec da VM, do lado do cluster. A VM migrada chega sem eles. O `aplicar-tuning.sh`
confirma que a VM é Windows (falha seguro), aplica o baseline por merge (sem
tocar em cpu, disks, interfaces nem volumes), opcionalmente reinicia e verifica.

```bash
# dry-run primeiro (não grava nada):
./aplicar-tuning.sh -n NS -vm VM --dry-run

# aplicar o baseline + reiniciar de verdade:
./aplicar-tuning.sh -n NS -vm VM --restart

# VM de alto tráfego (muitos usuários): some o tuning de multiqueue:
./aplicar-tuning.sh -n NS -vm VM --tuning --restart
```

As mudanças são de domínio: só entram com shutdown completo + start (o `--restart`
faz isso via virtctl). Sem `--restart`, o patch grava e você reinicia quando for
conveniente. O script verifica no fim que os 12 enlightenments entraram no domínio.
O baseline NÃO mexe em CPU de propósito: VM migrada já tem cpu explícito e correto.

## Parâmetros do UpdateDrivers

- `-NasPath '\\servidor\share\...'` caminho UNC do NAS (fonte 1). SEM padrão: só
  usa o NAS se você passar; vazio = a fonte NAS é pulada.
- `-DownloadUrl 'https://...'` URL base da fonte 2 (padrão: build estável upstream).
- `-LocalMediaPath 'C:\...'` pasta na VM que contém o MSI/EXE direto (fonte 3).
  Padrão: `C:\Windows\Temp\posmig-virtio-local`.

## Integridade do instalador

O script valida o MSI antes de instalar: confirma que é mesmo um MSI (barra
página de erro/anti-bot baixada por engano), exige assinatura Red Hat válida
quando o build é assinado (downstream), e aceita com aviso quando o build é
upstream (não assinado), confiando no formato e no transporte HTTPS.

## Nota sobre o download direto (fonte URL)

O fedorapeople roda um anti-bot (Anubis). O script já contorna usando um
User-Agent de ferramenta no download. O download pode levar alguns minutos.
