#Requires -Version 5.1
<#
    ativar-nic.ps1 - religa placas de rede desativadas ou ocultas numa VM Windows
    recem-migrada do VMware pro OpenShift Virt.

    Rode pelo canal do qemu-guest-agent, sem depender da rede da VM:

        guest-run -n NS -vm VM -ps-file ./ativar-nic.ps1

    O que ele faz (best-effort):
      1. re-escaneia o barramento (pnputil /scan-devices), pra trazer hardware
         presente que ainda nao enumerou;
      2. religa dispositivos de rede PRESENTES e nao-OK (desativados no nivel de device);
      3. religa adaptadores ainda marcados 'Disabled' (nivel de adaptador, inclui ocultos);
      4. imprime o estado final das placas.

    NAO mexe em IP, rota, DNS nem firewall. Isso e' diagnostico/reparo a parte;
    veja exemplos-guest-run.md. Sai 0 em best-effort; sai 20 so' se o modulo de
    rede nao existir (edicao capada).

    Duas notas de implementacao, por causa de como o guest-run -ps-file roda isto:
    ele envia o script como -EncodedCommand (nao -File). Por isso (a) NAO ha bloco
    param()/[CmdletBinding()] no topo (nesse modo eles quebram o parser), e (b) toda
    saida humana vai por [Console]::Out, nao Write-Host: headless via -EncodedCommand,
    o Write-Host despeja a Information stream como CLIXML no final, que polui a saida.
#>

$ErrorActionPreference = 'Continue'

function Say([string]$m) { [Console]::Out.WriteLine("[ativar-nic] " + $m) }

if (-not (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue)) {
    Say "cmdlet Get-NetAdapter indisponivel neste Windows; nada a fazer."
    [Console]::Out.WriteLine("RESULT: FAILED motivo=sem-modulo-netadapter")
    exit 20
}

$enabled = 0

# 1) re-escaneia o barramento
try {
    Say "re-escaneando dispositivos (pnputil /scan-devices)..."
    & pnputil.exe /scan-devices | Out-Null
} catch {
    Say ("pnputil /scan-devices falhou (seguindo): " + $_.Exception.Message)
}

# 2) religa dispositivos de rede presentes e nao-OK (desativados no nivel de device)
if (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) {
    $devs = Get-PnpDevice -Class Net -ErrorAction SilentlyContinue |
            Where-Object { $_.Present -and $_.Status -ne 'OK' }
    foreach ($d in $devs) {
        try {
            Say ("religando device: " + $d.FriendlyName + " (status " + $d.Status + ")")
            Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Stop
            $enabled++
        } catch {
            Say ("  nao deu pra religar " + $d.FriendlyName + ": " + $_.Exception.Message)
        }
    }
}

# 3) religa adaptadores ainda marcados 'Disabled' (inclui ocultos)
$adapters = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'Disabled' }
foreach ($a in $adapters) {
    try {
        Say ("religando adaptador: " + $a.Name + " (" + $a.InterfaceDescription + ")")
        Enable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction Stop
        $enabled++
    } catch {
        Say ("  nao deu pra religar " + $a.Name + ": " + $_.Exception.Message)
    }
}

# 4) estado final, pra ver o resultado na mesma chamada
Say "estado final das placas:"
$finalState = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
    Format-Table Name, Status, LinkSpeed, MacAddress, InterfaceDescription -AutoSize |
    Out-String -Width 4096
[Console]::Out.Write($finalState)

if ($enabled -gt 0) {
    [Console]::Out.WriteLine("RESULT: SUCCESS religadas=" + $enabled)
} else {
    [Console]::Out.WriteLine("RESULT: SUCCESS religadas=0 (nenhuma placa estava desativada; re-scan feito)")
}
exit 0
