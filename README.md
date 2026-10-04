# Runbook: preparar VM Windows migrada, por fora, via guest-run

Prepara uma VM Windows recem migrada do VMware pro OpenShift Virtualization, sem
logar na VM, pelo canal do qemu-guest-agent. Duas partes: o trabalho DENTRO da VM
(remover VMware Tools, pagefile, drivers, MTU) e o tuning no CLUSTER
(enlightenments Hyper-V).

## Conteudo do kit

| Arquivo | Para que |
| --- | --- |
| `RUNBOOK.md` | este guia |
| `preparar-vm.sh` | governador: roda o procedimento inteiro (fases 1 a 3) de ponta a ponta |
| `posmig-openshift-windows.ps1` | roda DENTRO da VM; empurrado e invocado pelo guest-run |
| `aplicar-tuning.sh` | aplica os enlightenments Hyper-V no CLUSTER (autocontido) |
| `hyperv-baseline.yaml` | o patch de baseline (referencia; ja' embutido no .sh) |
| `hyperv-tuning-adicional.yaml` | o patch opcional de alto trafego (referencia; ja' embutido no .sh) |

A ferramenta `guest-run` (que dirige tudo) NAO vem no kit: baixe o binario dos
releases (ver Pre-requisitos) e ponha no PATH.

Voce fornece separadamente: o **`virtio-win-gt-x64.msi`** (do NAS ou baixado),
necessario so' no cenario de VM sem rede (Fase 1, passo 4, opcao d).

## Modo automatico (o jeito facil): preparar-vm.sh

O `preparar-vm.sh` e' o governador: ele roda o procedimento inteiro numa tacada,
na ordem certa, conferindo cada passo, orquestrando os dois reboots (dispara o
restart e espera a VM voltar com o agente conectado antes de seguir), fazendo
retry do que e' transiente e parando no que e' terminal. No fim, ele reporta o
que fez. O resto deste runbook (fases 1 a 3, mais abaixo) e' o modo manual: o
mesmo procedimento, passo a passo, e' exatamente o que o governador faz por baixo.

**Por padrao ele NAO executa nada: so' mostra o plano (dry-run).** Ele reinicia a
VM e remove o VMware Tools, entao a execucao de verdade exige o `--yes` explicito.

```bash
# 1) ver o plano, sem tocar em nada (valida ate' o patch de tuning em server dry-run):
./preparar-vm.sh -n NS -vm VM

# 2) executar de verdade (baseline: sem drivers, sem multiqueue):
./preparar-vm.sh -n NS -vm VM --yes

# 3) incluindo a atualizacao de drivers virtio:
./preparar-vm.sh -n NS -vm VM --drivers --yes

# 4) VM de alto trafego (soma o multiqueue no tuning):
./preparar-vm.sh -n NS -vm VM --high-traffic --yes

# 5) VM sem rede: empurra o MSI local e forca a fonte Local:
./preparar-vm.sh -n NS -vm VM --drivers --media-source Local --media-file ./virtio-win-gt-x64.msi --yes

# 6) drivers do NAS:
./preparar-vm.sh -n NS -vm VM --drivers --media-source NAS --nas-path '\\servidor\share\virtio-win-1.9.57' --yes
```

O que ele faz, nessa ordem: empurra o `.ps1` -> RemoveVMwareTools -> DisablePageFile
-> [UpdateDrivers, so' com `--drivers`] -> SetMTU -> **reboot + espera** ->
EnablePageFile -> tuning Hyper-V (patch via `aplicar-tuning.sh`, sem reiniciar ali)
-> **reboot final + espera** (esse unico reboot aplica o pagefile reativado e os
enlightenments de uma vez) -> verifica e reporta. Os dois reboots usam a mesma
espera robusta: dispara o restart e so' segue quando a VMI volta (nova instancia)
com o agente reconectado.

Flags: `--drivers` (padrao off), `--media-source Auto|NAS|URL|Local`, `--media-file`
(MSI unico a empurrar pra fonte Local), `--nas-path UNC`, `--download-url URL`,
`--local-media-path P` (pasta Local ja' preparada na VM), `--high-traffic`
(multiqueue), `--script` (o `.ps1`, padrao ao lado), `--context`, `--fresh` (ignora
o state-file e recomeca), `--yes` (executa de verdade).

**Idempotente.** Cada passo concluido fica gravado num state-file em
`$TMPDIR/preparar-vm_NS_VM.state`. Se o governador for interrompido no meio (ctrl-C,
a sua maquina caiu durante um reboot), rode o mesmo comando de novo: ele pula o que
ja' terminou e continua de onde parou. Para recomecar do zero, use `--fresh`.

> IMPORTANTE: rode o dry-run primeiro, e na primeira vez num ambiente novo valide o
> `--yes` numa VM descartavel antes de apontar pra producao. Ele reinicia a VM e
> remove o VMware Tools. Cada ambiente tem seus tempos de boot; o teto de espera por
> reboot e' de 15 min (90 x 10s).

## Pre-requisitos

- **`guest-run` no PATH** (ver abaixo). Binario unico, roda com o seu oc/kubeconfig.
- `oc` (e `virtctl` para o `--restart` da Fase 3).
- Acesso de `exec` ao pod da VM.
- Agente conectado na VM: `oc get vmi <vm> -o jsonpath='{.status.conditions[?(@.type=="AgentConnected")].status}'` deve dar `True`.
  Em VM migrada pelo MTV com sucesso, o agente ja vem instalado. Se nao vier,
  este runbook nao alcanca a VM (e o ovo e a galinha; use o console).

### Instalando o guest-run

A ferramenta `guest-run` dirige tudo. Ela NAO vem neste repo: baixe o binario dos
releases e deixe acessivel como `guest-run`.

1. Baixe o asset do seu SO/arquitetura em
   https://github.com/linuxelitebr/kubevirt-guest-run/releases (versao 0.2.0 ou mais
   nova, que tem o `-put`). Os nomes sao assim:

| SO / arquitetura | Asset |
| --- | --- |
| Linux x86_64 | `guest-run_0.2.0_linux_amd64.tar.gz` |
| Linux ARM64 | `guest-run_0.2.0_linux_arm64.tar.gz` |
| macOS Intel | `guest-run_0.2.0_darwin_amd64.tar.gz` |
| macOS Apple Silicon | `guest-run_0.2.0_darwin_arm64.tar.gz` |
| Windows x86_64 | `guest-run_0.2.0_windows_amd64.zip` |

2. Extraia. Dentro vem o binario, chamado **`guest-run`** (no Windows,
   **`guest-run.exe`**), mais LICENSE e README.

3. Deixe o binario chamado `guest-run` numa pasta do PATH:

```bash
tar xzf guest-run_0.2.0_linux_amd64.tar.gz
sudo install guest-run_0.2.0_linux_amd64/guest-run /usr/local/bin/guest-run
guest-run -version   # deve imprimir: guest-run 0.2.0
```

No Windows, copie `guest-run.exe` pra uma pasta que esteja no `Path` (ou adicione a
pasta ao `Path`).

O `preparar-vm.sh` e todos os comandos deste guia chamam `guest-run` pelo nome, sem
caminho, entao o binario PRECISA se chamar `guest-run` (ou `guest-run.exe`) e estar
no PATH. Se preferir nao mexer no PATH, aponte o governador pro binario com a env
`GUEST_RUN`:

```bash
GUEST_RUN=/caminho/para/guest-run ./preparar-vm.sh -n NS -vm VM
```

Convencao abaixo: `NS` = namespace, `VM` = nome da VM.

## 0. Colocar o script na VM (uma vez)

```bash
guest-run -n NS -vm VM -put ./posmig-openshift-windows.ps1 -dest 'C:\Windows\Temp\posmig.ps1'
```

## Como cada acao e' chamada

O exit code da acao volta pelo guest-run. O padrao de invocacao que propaga o
codigo corretamente (nao use `& script.ps1`, que entra em minishell e perde o
codigo):

```bash
guest-run -n NS -vm VM -timeout 900s -ps \
  'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\posmig.ps1 -Action <ACAO> <PARAMS> 2> C:\Windows\Temp\posmig-stderr.log; exit $LASTEXITCODE'
```

Cada acao imprime uma linha `RESULT: ...` e sai com um codigo. `-timeout 900s`
porque instalar driver e remover VMware Tools levam minutos.

## Fase 1 (na ordem do procedimento)

### 1. Remover VMware Tools
```
-Action RemoveVMwareTools
```
Se a VM nao tiver VMware Tools (ja limpa), reporta "nada a fazer" sem erro.

### 2. Desativar arquivo de paginacao
```
-Action DisablePageFile
```

### 4. Atualizar drivers virtio (so' se o time pedir)

A ordem do `-MediaSource Auto` e': NAS -> URL -> Local -> (se nada funcionar e a VM
ja' tiver virtio) so' reporta a versao instalada. `NAS`/`URL`/`Local` forcam uma
fonte unica. O `-MediaSource` nao tem padrao de caminho embutido: a fonte NAS so'
roda se voce passar `-NasPath`.

**(a) VM tem rede (caso comum):** cadeia automatica.
```
-Action UpdateDrivers -MediaSource Auto
```

**(b) Do NAS:** informe o caminho UNC (obrigatorio, sem padrao).
```
-Action UpdateDrivers -MediaSource NAS -NasPath '\\servidor\share\virtio-win-1.9.xx'
```

**(c) Da URL:** build estavel por padrao, ou passe outra base com `-DownloadUrl`.
```
-Action UpdateDrivers -MediaSource URL
```

**(d) VM SEM rede, com a midia na mao (uma pasta ou um .zip):** leve a midia pra
dentro da VM e aponte a fonte Local. O `-LocalMediaPath` tem que ser a pasta que
contem o `virtio-win-gt-x64.msi` DIRETO (o script faz `Join-Path`, nao busca
recursiva). O `guest-run -put` move UM arquivo por vez, entao:

*d.1 So' o MSI (o mais simples):* empurre pro caminho Local padrao e instale.
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

*d.3 Uma pasta (`virtio-win-1.9.57\`):* como o `-put` e' arquivo-a-arquivo, ou voce
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

**O que o script faz com a midia:** roda `msiexec /i virtio-win-gt-x64.msi /qn
/norestart /L*v <log> ADDLOCAL=ALL` e, se encontrar o `virtio-win-guest-tools.exe`
na mesma pasta, roda ele em seguida (`/install /quiet /norestart ACCEPTEULA=1`).
Valida a integridade do MSI antes (ver mais abaixo) e imprime a linha `RESULT:`.

**Pelo governador:** o `preparar-vm.sh` aceita `--media-file ARQ` (empurra um MSI
unico pro caminho Local e usa a fonte Local), `--nas-path UNC`, `--download-url URL`
e `--local-media-path P` (aponta pra uma pasta ja' preparada como no d.2/d.3).

Codigos de saida do UpdateDrivers (e a linha RESULT):

| exit | RESULT status | significado |
| --- | --- | --- |
| 0  | SUCCESS | drivers instalados (reinicie para aplicar) |
| 10 | SKIPPED_ALREADY_PRESENT | a VM ja tem virtio igual ou mais novo; nada mudou |
| 11 | FAILED_NO_VIRTIO | nenhuma fonte funcionou E a VM nao tem virtio |
| 13 | FAILED_INSTALL | fonte ok, mas a instalacao falhou (veja o log no RESULT) |

### 5. Ajustar MTU para 1500
```
-Action SetMTU
```
(Nao rode se a VM usa Jumbo Frame de proposito.)

### 6. Reboot
```
-Action Reboot
```

## Fase 2 (apos o Windows reiniciar)

### 3. Reativar arquivo de paginacao
```
-Action EnablePageFile
```

### 6. Reboot
```
-Action Reboot
```

## Fase 3: tuning Hyper-V (no cluster)

Os enlightenments Hyper-V nao sao configurados dentro do Windows: sao um patch na
spec da VM, do lado do cluster. A VM migrada chega sem eles. O `aplicar-tuning.sh`
confirma que a VM e' Windows (falha seguro), aplica o baseline por merge (sem
tocar em cpu, disks, interfaces nem volumes), opcionalmente reinicia e verifica.

```bash
# dry-run primeiro (nao grava nada):
./aplicar-tuning.sh -n NS -vm VM --dry-run

# aplicar o baseline + reiniciar de verdade:
./aplicar-tuning.sh -n NS -vm VM --restart

# VM de alto trafego (muitos usuarios): some o tuning de multiqueue:
./aplicar-tuning.sh -n NS -vm VM --tuning --restart
```

As mudancas sao de dominio: so' entram com shutdown completo + start (o `--restart`
faz isso via virtctl). Sem `--restart`, o patch grava e voce reinicia quando for
conveniente. O script verifica no fim que os 12 enlightenments entraram no dominio.
O baseline NAO mexe em CPU de proposito: VM migrada ja' tem cpu explicito e correto.

## Parametros do UpdateDrivers

- `-NasPath '\\servidor\share\...'` caminho UNC do NAS (fonte 1). SEM padrao: so'
  usa o NAS se voce passar; vazio = a fonte NAS e' pulada.
- `-DownloadUrl 'https://...'` URL base da fonte 2 (padrao: build estavel upstream).
- `-LocalMediaPath 'C:\...'` pasta na VM que contem o MSI/EXE direto (fonte 3).
  Padrao: `C:\Windows\Temp\posmig-virtio-local`.

## Integridade do instalador

O script valida o MSI antes de instalar: confirma que e' mesmo um MSI (barra
pagina de erro/anti-bot baixada por engano), exige assinatura Red Hat valida
quando o build e' assinado (downstream), e aceita com aviso quando o build e'
upstream (nao assinado), confiando no formato e no transporte HTTPS.

## Nota sobre o download direto (fonte URL)

O fedorapeople roda um anti-bot (Anubis). O script ja contorna usando um
User-Agent de ferramenta no download. O download pode levar alguns minutos.
