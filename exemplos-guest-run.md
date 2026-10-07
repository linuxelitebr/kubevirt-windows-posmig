# Comandos avulsos na VM via guest-run

O `guest-run` fala com a VM pelo canal do qemu-guest-agent (virtio-serial), que não
depende da rede da VM. Ou seja: mesmo com a rede da VM morta, você continua entrando
pra diagnosticar e consertar. É exatamente o caso de "a VM tem IP mas parou de
comunicar".

Este guia é um apanhado de comandos pra rodar UM de cada vez, fora do governador. Pra
preparar uma VM inteira de ponta a ponta, use o `preparar-vm.sh` (ver README).

## Antes de tudo

Todo comando aqui usa o mesmo esqueleto:

```bash
guest-run -n NS -vm VM -ps 'COMANDO POWERSHELL'
```

Troque `NS` pelo namespace e `VM` pelo nome da VM. Se o seu contexto do `oc` não for o
default, acrescente `-context SEU-CONTEXTO`. Pra comando que demora, suba o teto com
`-timeout 300s`.

Uma chatice do PowerShell headless: tabela larga volta cortada com `...`. Quando isso
acontecer, jogue a saída em `| Out-String -Width 4096` no fim. Os exemplos abaixo já
vêm com isso onde faz diferença.

## Diagnóstico de rede: "tem IP mas parou de comunicar"

A ordem abaixo vai do mais perto do fio pro mais longe. Rode de cima pra baixo e pare
quando achar o culpado.

### A placa está de pé?

```bash
guest-run -n NS -vm VM -ps 'Get-NetAdapter -IncludeHidden | Format-Table Name,Status,LinkSpeed,MacAddress,InterfaceDescription -AutoSize | Out-String -Width 4096'
```

Olhe a coluna `Status`. `Up` é o que você quer. `Disabled` = alguém (ou a migração)
desativou, religa com o `ativar-nic.ps1` (abaixo). `Disconnected` = a placa está de pé
mas sem link, aí o problema é a rede virtual (bridge/localnet/VLAN no lado do
OpenShift), não o guest. `Not Present` = o driver virtio não pegou.

### Qual a config de IP?

```bash
guest-run -n NS -vm VM -ps 'Get-NetIPConfiguration -Detailed | Out-String -Width 4096'
```

Só os endereços IPv4, com o estado de cada um:

```bash
guest-run -n NS -vm VM -ps 'Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "*Loopback*" } | Format-Table InterfaceAlias,IPAddress,PrefixLength,AddressState -AutoSize | Out-String -Width 4096'
```

Dois sinais de alerta aqui:

- IP `169.254.x.x` (APIPA): o DHCP falhou e o Windows se auto-atribuiu um endereço de
  ninguém. A VM "tem IP", mas um que não fala com nada.
- `AddressState` = `Duplicate` ou `Invalid`: o Windows achou o mesmo IP em outra placa e
  desativou este. Clássico pós-migração: a placa VMware fantasma (oculta) ainda segura o
  IP estático, e a virtio nova não consegue usar. Veja "driver virtio e NICs ocultas".

### Existe rota default (gateway)?

```bash
guest-run -n NS -vm VM -ps 'Get-NetRoute -DestinationPrefix 0.0.0.0/0 | Format-Table ifIndex,NextHop,RouteMetric,InterfaceAlias -AutoSize | Out-String -Width 4096'
```

Sem linha nenhuma = sem gateway, a VM não sai da própria sub-rede. `NextHop` errado =
rota apontando pro lugar errado (acontece quando a placa fantasma deixou uma rota velha
pra trás).

### A máscara está certa? (prefixo)

Junta IP, prefixo e rotas numa olhada só. É a que pega o erro de máscara pós-migração:

```bash
guest-run -n NS -vm VM -ps 'Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "*Loopback*" } | Format-Table InterfaceAlias,IPAddress,PrefixLength,AddressState -AutoSize | Out-String -Width 4096; "--- rotas ---"; Get-NetRoute -AddressFamily IPv4 | Where-Object { $_.DestinationPrefix -notmatch "^(224|255|127)\." } | Sort-Object InterfaceAlias | Format-Table DestinationPrefix,NextHop,RouteMetric,InterfaceAlias -AutoSize | Out-String -Width 4096'
```

Olhe o `PrefixLength`. O sinal de alerta é um IP `10.x` com prefixo `8` (ou um `172.x`
com `8`/`16`). Isso vem de dois jeitos: alguém digitou a máscara errada na configuração
estática, ou o Windows caiu no default classful porque o IP foi aplicado sem a máscara
(a migração às vezes traz o IP e perde a máscara). Na tabela de rotas aparece como uma
linha on-link larga demais, tipo `10.0.0.0/8  0.0.0.0` em vez da sua sub-rede real. Com
isso a VM acha que meio mundo é vizinho de rede, sai ARPando tudo direto e só fala com
quem está no segmento físico de verdade. O conserto está em "Corrigir a máscara", abaixo.

### O gateway responde no nível 2 (ARP)?

Esse é o pulo do gato pra "tem IP mas não comunica". Antes de pingar, o Windows precisa
resolver o MAC do gateway por ARP. Se isso falha, o problema está ABAIXO do IP (rede
virtual, não o guest):

```bash
guest-run -n NS -vm VM -ps 'Get-NetNeighbor -AddressFamily IPv4 | Where-Object { $_.State -ne "Permanent" } | Format-Table IPAddress,LinkLayerAddress,State,InterfaceAlias -AutoSize | Out-String -Width 4096'
```

Ache a linha do seu gateway. `Reachable` ou `Stale` com um MAC preenchido = L2 ok.
`Unreachable` ou `Incomplete` (sem MAC) = o quadro ARP não volta. Isso quase sempre é do
lado do cluster (NetworkAttachmentDefinition, bridge sem a VLAN certa, MAC spoofing
bloqueado no localnet), não do Windows. Essa é a distinção que explica por que a VM
responde ao console mas não à rede: o IP está lá, o L2 é que não fecha.

### Pinga o gateway

Descobre o gateway sozinho e manda quatro pacotes:

```bash
guest-run -n NS -vm VM -ps '$gw=(Get-NetRoute -DestinationPrefix 0.0.0.0/0 | Sort-Object RouteMetric | Select-Object -First 1).NextHop; "Gateway: $gw"; Test-Connection -ComputerName $gw -Count 4 -ErrorAction SilentlyContinue | Format-Table -AutoSize | Out-String -Width 4096'
```

Pinga mas a aplicação não fala? Suspeite de firewall ou de MTU (pacote pequeno passa,
transferência grande morre). Veja os dois abaixo.

### Pingar qualquer host (e testar porta TCP)

Pra testar alcance a um IP qualquer (um host interno, um DNS público, o que for), é o
`ping` de sempre ou o `Test-Connection`:

```bash
guest-run -n NS -vm VM -ps 'ping 1.1.1.1'
```

```bash
guest-run -n NS -vm VM -ps 'Test-Connection -ComputerName 1.1.1.1 -Count 4 | Format-Table -AutoSize | Out-String -Width 200'
```

O `-Quiet` volta só `True`/`False`, bom pra script:

```bash
guest-run -n NS -vm VM -ps 'Test-Connection -ComputerName 1.1.1.1 -Count 2 -Quiet'
```

Dois cuidados pra não ler errado o resultado:

- `1.1.1.1` (DNS público da Cloudflare) testa saída pra internet, não a rede interna. Em
  rede corporativa o ICMP de saída pra internet costuma estar bloqueado no firewall,
  então um `False` aqui pode ser o firewall, não a VM. Pra ver se a rede interna voltou,
  pinga algo que deveria responder: o gateway, ou um host interno conhecido.
- Se o ICMP estiver bloqueado mas você precisa saber se alcança um host numa porta (TCP),
  use o `Test-NetConnection`, que não depende de ping:

```bash
guest-run -n NS -vm VM -ps 'Test-NetConnection -ComputerName 1.1.1.1 -Port 443 | Format-List ComputerName,RemoteAddress,TcpTestSucceeded'
```

`TcpTestSucceeded : True` = a porta responde, mesmo que o ping não passe.

### DNS

```bash
guest-run -n NS -vm VM -ps 'Get-DnsClientServerAddress -AddressFamily IPv4 | Format-Table InterfaceAlias,ServerAddresses -AutoSize | Out-String -Width 4096'
```

Teste uma resolução de verdade (troque pelo seu domínio interno):

```bash
guest-run -n NS -vm VM -ps 'Resolve-DnsName seu-dominio-interno -ErrorAction SilentlyContinue | Out-String -Width 4096'
```

### Firewall

Pós-migração o perfil de firewall às vezes volta ligado e bloqueando. Confira:

```bash
guest-run -n NS -vm VM -ps 'Get-NetFirewallProfile | Format-Table Name,Enabled -AutoSize | Out-String -Width 4096'
```

### Driver virtio e NICs ocultas

Confirme que a placa que o Windows está usando é a virtio, e não uma VMware fantasma:

```bash
guest-run -n NS -vm VM -ps 'Get-PnpDevice -Class Net | Format-Table FriendlyName,Status,Present -AutoSize | Out-String -Width 4096'
```

Você quer ver `Red Hat VirtIO Ethernet Adapter` com `Status OK` e `Present True`. Se as
únicas placas presentes forem VMware, o driver virtio não foi injetado (rode o
`UpdateDrivers` do kit). As placas VMware com `Present False` são os fantasmas que ainda
seguram IP e rota velhos.

### MTU

```bash
guest-run -n NS -vm VM -ps 'Get-NetIPInterface -AddressFamily IPv4 | Format-Table InterfaceAlias,NlMtu,Dhcp,ConnectionState -AutoSize | Out-String -Width 4096'
```

Lembre da pegadinha: o `SetMTU` só mexe em placa que está de pé. Se a placa estava
desativada, religue primeiro, depois ajuste o MTU.

### Tudo de uma vez

Pra um incidente ao vivo, às vezes você só quer o retrato inteiro numa chamada. Salve o
bloco abaixo como `diag-rede.ps1` e rode com `-ps-file ./diag-rede.ps1`. É tudo
read-only, não muda nada:

```powershell
"=== ADAPTERS ==="; Get-NetAdapter -IncludeHidden | Format-Table Name,Status,LinkSpeed,MacAddress -AutoSize | Out-String -Width 4096
"=== IP ==="; Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "*Loopback*" } | Format-Table InterfaceAlias,IPAddress,PrefixLength,AddressState -AutoSize | Out-String -Width 4096
"=== ROTA DEFAULT ==="; Get-NetRoute -DestinationPrefix 0.0.0.0/0 | Format-Table ifIndex,NextHop,RouteMetric,InterfaceAlias -AutoSize | Out-String -Width 4096
"=== VIZINHOS (ARP) ==="; Get-NetNeighbor -AddressFamily IPv4 | Where-Object { $_.State -ne "Permanent" } | Format-Table IPAddress,LinkLayerAddress,State -AutoSize | Out-String -Width 4096
"=== DNS ==="; Get-DnsClientServerAddress -AddressFamily IPv4 | Format-Table InterfaceAlias,ServerAddresses -AutoSize | Out-String -Width 4096
"=== FIREWALL ==="; Get-NetFirewallProfile | Format-Table Name,Enabled -AutoSize | Out-String -Width 4096
"=== PING GATEWAY ==="; $gw=(Get-NetRoute -DestinationPrefix 0.0.0.0/0 | Sort-Object RouteMetric | Select-Object -First 1).NextHop; "Gateway: $gw"; if ($gw) { Test-Connection -ComputerName $gw -Count 4 -ErrorAction SilentlyContinue | Format-Table -AutoSize | Out-String -Width 4096 } else { "sem rota default" }
```

## Reparos

### Religar placa desativada ou oculta

```bash
guest-run -n NS -vm VM -ps-file ./ativar-nic.ps1
```

Religa o que dá pra religar (nível de device e de adaptador), re-escaneia o barramento e
imprime o estado final. Best-effort, não toca em IP/rota/firewall. Se precisar do código
de saída exato numa automação, use o padrão do governador (empurra e invoca com
`-File ...; exit $LASTEXITCODE`):

```bash
guest-run -n NS -vm VM -put ./ativar-nic.ps1 -dest 'C:\Windows\Temp\ativar-nic.ps1'
guest-run -n NS -vm VM -ps 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\ativar-nic.ps1; exit $LASTEXITCODE'
```

### Ajustar o MTU (só essa etapa do kit)

Empurra o script do kit (se ainda não estiver na VM) e roda só a ação `SetMTU`:

```bash
guest-run -n NS -vm VM -put ./posmig-openshift-windows.ps1 -dest 'C:\Windows\Temp\posmig.ps1'
guest-run -n NS -vm VM -ps 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\posmig.ps1 -Action SetMTU; exit $LASTEXITCODE'
```

Essa ação fixa o MTU em 1500 nas interfaces Ethernet. Se a sua rede usa outro valor, dá
um grito que a gente parametriza.

### Corrigir a máscara de rede (prefixo errado)

Se o diagnóstico mostrou o prefixo errado (um `10.x` como `/8`, por exemplo), o conserto
é cirúrgico e sem reboot: corrige só o prefixo, sem mexer no gateway nem no DNS. Troque o
nome da placa, o IP e o prefixo pelos seus:

```bash
guest-run -n NS -vm VM -ps 'Set-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress 10.20.30.40 -PrefixLength 23 -ErrorAction Stop; Start-Sleep 2; Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias "Ethernet" | Format-List IPAddress,PrefixLength,PrefixOrigin,AddressState'
```

A rota on-link se ajusta sozinha (a `/8` larga some, entra a máscara certa) e a rota
default pro gateway fica intacta. Confirme o `PrefixLength` na saída.

Dois cuidados:

- Confirme a máscara real ANTES. Não dá pra deduzir pelo gateway: um `.254` tanto é `/24`
  quanto `/23` ou mais largo. Pega o número com a equipe de rede ou de outra máquina que
  funciona no mesmo segmento. Prefixo errado troca um problema por outro.
- Isso vale pra IP estático (`PrefixOrigin` = `Manual`). Se vier `Dhcp`, não mexa na VM:
  o prefixo veio do servidor DHCP, conserte a máscara no escopo lá (e o próprio comando
  acima falha num endereço DHCP, então ele não te deixa estragar).

Alternativa atômica (seta IP, máscara e gateway de uma vez, também sem reboot). A máscara
dotted de `/23` é `255.255.254.0` (a de `/24` é `255.255.255.0`):

```bash
guest-run -n NS -vm VM -ps 'netsh interface ip set address name="Ethernet" static 10.20.30.40 255.255.254.0 10.20.30.1'
```

Nenhum dos dois comandos acima toca no resolver de DNS: ele é configuração à parte
(`netsh interface ip set dnsservers` / `Set-DnsClientServerAddress`). Os servidores de
DNS ficam como estão (medido: `set address` muda a máscara e deixa os DNS intactos).

Depois de corrigir, limpe o ARP que a VM aprendeu errado e teste um alvo que estava
inalcançável (troque pelo IP real que você precisa alcançar):

```bash
guest-run -n NS -vm VM -ps 'Get-NetNeighbor -AddressFamily IPv4 | Where-Object { $_.State -in "Incomplete","Unreachable" } | Remove-NetNeighbor -Confirm:$false -ErrorAction SilentlyContinue; Test-Connection -ComputerName 10.20.30.50 -Count 2 | Format-Table -AutoSize | Out-String -Width 200'
```

### Limpar cache de ARP e DNS

Depois de arrumar rota ou gateway, limpe os caches velhos pra forçar a VM a reaprender:

```bash
guest-run -n NS -vm VM -ps 'Clear-DnsClientCache; Get-NetNeighbor -AddressFamily IPv4 | Where-Object { $_.State -ne "Permanent" } | Remove-NetNeighbor -Confirm:$false -ErrorAction SilentlyContinue; "cache de DNS e ARP limpos"'
```

### Renovar DHCP

Se a placa está em DHCP e pegou um APIPA:

```bash
guest-run -n NS -vm VM -ps 'ipconfig /release; ipconfig /renew | Out-String -Width 4096'
```

### Desligar o firewall (só pra testar)

Cuidado: isso derruba o firewall da VM. Use só pra isolar se o firewall é o culpado, e
religue depois.

```bash
guest-run -n NS -vm VM -ps 'Set-NetFirewallProfile -All -Enabled False; "firewall DESLIGADO (temporario)"'
```

Religar:

```bash
guest-run -n NS -vm VM -ps 'Set-NetFirewallProfile -All -Enabled True; "firewall religado"'
```

## Rodar as ações do kit uma a uma

O `posmig-openshift-windows.ps1` tem ações isoladas. Empurre o script uma vez e chame a
ação que quiser:

```bash
guest-run -n NS -vm VM -put ./posmig-openshift-windows.ps1 -dest 'C:\Windows\Temp\posmig.ps1'
guest-run -n NS -vm VM -ps 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\posmig.ps1 -Action ACAO; exit $LASTEXITCODE'
```

Trocando `ACAO` por:

| Ação | O que faz |
| --- | --- |
| `SetMTU` | fixa o MTU das interfaces Ethernet em 1500 |
| `OnlineDataDisks` | põe online os discos de dados que vieram Offline pós-V2V |
| `RemoveVMwareTools` | remove o VMware Tools e as placas VMware |
| `DisablePageFile` | desativa o pagefile (fase 1, antes do reboot) |
| `EnablePageFile` | restaura o pagefile (fase 2, depois do reboot) |
| `UpdateDrivers` | instala o virtio (precisa de `-MediaSource`, ver README) |
| `Reboot` | reinicia a VM pelo guest |

## Copiar arquivo ou pasta pra VM (sem rede)

Arquivo:

```bash
guest-run -n NS -vm VM -put ./arquivo.ext -dest 'C:\caminho\arquivo.ext'
```

Pasta inteira (zipa, empurra e expande do outro lado; precisa guest-run 0.3.0+):

```bash
guest-run -n NS -vm VM -timeout 1800s -put-dir ./minha-pasta -dest 'C:\destino\minha-pasta'
```
