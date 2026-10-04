#Requires -Version 3.0

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$KeepNetworkAdapters,
    [ValidateSet('Menu', 'RemoveVMwareTools', 'DisablePageFile', 'EnablePageFile', 'UpdateDrivers', 'SetMTU', 'Reboot')]
    [string]$Action = 'Menu',

    # --- Driver source control (acao UpdateDrivers) ---
    # Ordem de tentativa dos drivers virtio. Auto tenta NAS, depois URL, depois
    # um arquivo local previamente colocado na VM, e por fim apenas reporta a
    # versao ja instalada. Os demais valores forcam uma unica fonte.
    [ValidateSet('Auto', 'NAS', 'URL', 'Local')]
    [string]$MediaSource = 'Auto',

    # Caminho UNC do NAS (fonte 1). SEM padrao: informe -NasPath para usar a
    # fonte NAS, por exemplo:
    #   -NasPath '\\servidor\share\caminho\virtio-win-1.9.xx'
    # Vazio (padrao) = a fonte NAS e' simplesmente pulada.
    [string]$NasPath = '',

    # URL base de download direto (fonte 2). Padrao: build estavel upstream.
    [string]$DownloadUrl = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.302-1',

    # Pasta dentro da VM onde um MSI/EXE foi previamente colocado (fonte 3),
    # por exemplo via 'guest-run -put' quando a VM nao tem rede.
    [string]$LocalMediaPath = 'C:\Windows\Temp\posmig-virtio-local'
)

$ErrorActionPreference = 'Stop'

$script:RemoveVMwareProgressFile = 'C:\Windows\Temp\Remove-VMwareTools.progress'
$script:EnablePageFileProgressFile = 'C:\Windows\Temp\Enable-WindowsPagefile.progress'
$script:ProgressFile = $null

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $color = switch ($Level) {
        'Info'    { 'White' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        'Success' { 'Green' }
    }

    $levelLabel = switch ($Level) {
        'Info'    { 'Informacao' }
        'Warning' { 'Aviso' }
        'Error'   { 'Erro' }
        'Success' { 'Sucesso' }
    }

    Write-Host "[$timestamp] [$levelLabel] $Message" -ForegroundColor $color
}

function Show-Banner {
    Clear-Host
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host '   Pos-migracao de VM Windows (VMware -> OpenShift Virt)    ' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ''
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Admin {
    if (Test-IsAdmin) {
        return
    }

    $scriptPath = $MyInvocation.ScriptName
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        $scriptPath = $PSCommandPath
    }
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        throw 'O script precisa ser executado a partir de um arquivo .ps1 para permitir self-elevation.'
    }

    $argList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$scriptPath`""
    )

    if ($Action -ne 'Menu') {
        $argList += '-Action'
        $argList += $Action
    }
    if ($Force) {
        $argList += '-Force'
    }
    if ($KeepNetworkAdapters) {
        $argList += '-KeepNetworkAdapters'
    }

    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    exit 0
}

function Save-Progress {
    param(
        [int]$Step,
        [string]$Description
    )

    if ([string]::IsNullOrWhiteSpace($script:ProgressFile)) {
        return
    }

    try {
        @(
            "Step=$Step"
            "Description=$Description"
            "UpdatedAt=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        ) | Set-Content -Path $script:ProgressFile -Encoding ASCII -Force
        Write-Log "Progresso salvo: etapa $Step - $Description"
    }
    catch {
        Write-Log "Falha ao salvar arquivo de progresso: $($_.Exception.Message)" -Level Warning
    }
}

function Get-SavedProgress {
    if ([string]::IsNullOrWhiteSpace($script:ProgressFile) -or -not (Test-Path $script:ProgressFile)) {
        return $null
    }

    try {
        $data = @{}
        foreach ($line in Get-Content -Path $script:ProgressFile -ErrorAction Stop) {
            if ($line -match '^(.*?)=(.*)$') {
                $data[$matches[1]] = $matches[2]
            }
        }

        if ($data.ContainsKey('Step')) {
            return [PSCustomObject]@{
                Step        = [int]$data['Step']
                Description = $data['Description']
                UpdatedAt   = $data['UpdatedAt']
            }
        }
    }
    catch {
        Write-Log "Falha ao ler arquivo de progresso: $($_.Exception.Message)" -Level Warning
    }

    return $null
}

function Clear-Progress {
    if ([string]::IsNullOrWhiteSpace($script:ProgressFile) -or -not (Test-Path $script:ProgressFile)) {
        return
    }

    try {
        Remove-Item -Path $script:ProgressFile -Force -ErrorAction Stop
        Write-Log 'Arquivo de progresso removido com sucesso.' -Level Success
    }
    catch {
        Write-Log "Falha ao remover arquivo de progresso: $($_.Exception.Message)" -Level Warning
    }
}

function Resolve-StartStep {
    $saved = Get-SavedProgress
    if (-not $saved) {
        return 1
    }

    Write-Log 'Foi encontrado um arquivo de progresso de execucao anterior.' -Level Warning
    Write-Log "Ultima etapa registrada: $($saved.Step) - $($saved.Description)" -Level Warning
    Write-Log "Atualizado em: $($saved.UpdatedAt)" -Level Warning

    Write-Log "Retomando automaticamente a execucao a partir da etapa $($saved.Step)." -Level Success
    return [int]$saved.Step
}

function Confirm-Reboot {
    Write-Log '=== ATENCAO ===' -Level Warning
    Write-Log 'E necessario reiniciar o sistema para concluir a aplicacao das alteracoes.'
    Write-Log 'Por favor, reinicie o sistema quando conveniente.'
}

function Write-BigRestartWarning {
    Write-Host ''
    Write-Host '################################################################################################' -ForegroundColor Yellow -BackgroundColor Red
    Write-Host '#                                                                                              #' -ForegroundColor Yellow -BackgroundColor Red
    Write-Host '#   ATENCAO: OS DRIVERS FORAM ATUALIZADOS. REINICIE O WINDOWS IMEDIATAMENTE !!!               #' -ForegroundColor Yellow -BackgroundColor Red
    Write-Host '#   ATENCAO: OS DRIVERS FORAM ATUALIZADOS. REINICIE O WINDOWS IMEDIATAMENTE !!!               #' -ForegroundColor Yellow -BackgroundColor Red
    Write-Host '#   ATENCAO: OS DRIVERS FORAM ATUALIZADOS. REINICIE O WINDOWS IMEDIATAMENTE !!!               #' -ForegroundColor Yellow -BackgroundColor Red
    Write-Host '#                                                                                              #' -ForegroundColor Yellow -BackgroundColor Red
    Write-Host '#   SALVE SEU TRABALHO E REINICIE A MAQUINA PARA GARANTIR A APLICACAO COMPLETA DOS DRIVERS.   #' -ForegroundColor Yellow -BackgroundColor Red
    Write-Host '#                                                                                              #' -ForegroundColor Yellow -BackgroundColor Red
    Write-Host '################################################################################################' -ForegroundColor Yellow -BackgroundColor Red
    Write-Host ''
}

function Get-DefaultPageFilePath {
    try {
        $systemDrive = [System.Environment]::GetEnvironmentVariable('SystemDrive')
        if ([string]::IsNullOrWhiteSpace($systemDrive)) {
            $systemDrive = 'C:'
        }
        return "$systemDrive\pagefile.sys"
    }
    catch {
        Write-Log 'Falha ao determinar o disco do sistema. Utilizando caminho padrao C:\pagefile.sys para o arquivo de paginacao.' -Level Warning
        return 'C:\pagefile.sys'
    }
}

function Get-PageFileState {
    try {
        $regPageFilePath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
        $computerSystem = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction SilentlyContinue
        $pageFileSettings = Get-WmiObject -Class Win32_PageFileSetting -ErrorAction SilentlyContinue
        $pageFileUsage = Get-WmiObject -Class Win32_PageFileUsage -ErrorAction SilentlyContinue
        $regValues = Get-ItemProperty -Path $regPageFilePath -ErrorAction SilentlyContinue

        return [PSCustomObject]@{
            AutomaticManagedPagefile = $computerSystem.AutomaticManagedPagefile
            PageFileSettings         = $pageFileSettings
            PageFileUsage            = $pageFileUsage
            PagingFiles              = $regValues.PagingFiles
            ExistingPageFiles        = $regValues.ExistingPageFiles
            TempPageFile             = $regValues.TempPageFile
        }
    }
    catch {
        Write-Log "Falha ao consultar estado atual do arquivo de paginacao: $($_.Exception.Message)" -Level Error
        return $null
    }
}

function Show-PageFileState {
    param([string]$Title)

    Write-Log "=== $Title ===" -Level Info
    $state = Get-PageFileState
    if (-not $state) {
        return
    }

    if ($null -eq $state.AutomaticManagedPagefile) {
        Write-Log 'Gerenciamento automatico do arquivo de paginacao: Nao foi possivel determinar via WMI' -Level Warning
    }
    elseif ($state.AutomaticManagedPagefile) {
        Write-Log 'Gerenciamento automatico do arquivo de paginacao: Habilitado' -Level Success
    }
    else {
        Write-Log 'Gerenciamento automatico do arquivo de paginacao: Desabilitado' -Level Warning
    }

    if ($state.PagingFiles) {
        Write-Log "Registro PagingFiles: $($state.PagingFiles -join '; ')" -Level Info
    }
    else {
        Write-Log 'Registro PagingFiles: vazio ou nao configurado.' -Level Info
    }

    if ($state.ExistingPageFiles) {
        Write-Log "Registro ExistingPageFiles (arquivos de paginacao existentes): $($state.ExistingPageFiles -join '; ')" -Level Info
    }
    if ($null -ne $state.TempPageFile) {
        Write-Log "Registro TempPageFile (arquivo de paginacao temporario): $($state.TempPageFile)" -Level Info
    }
    if ($state.PageFileSettings) {
        Write-Log 'Configuracoes explicitas do arquivo de paginacao encontradas:' -Level Info
        $state.PageFileSettings | ForEach-Object {
            Write-Log "  - $($_.Name) (TamanhoInicial=$($_.InitialSize) MB, TamanhoMaximo=$($_.MaximumSize) MB)" -Level Info
        }
    }
    else {
        Write-Log 'Nenhuma configuracao explicita do arquivo de paginacao encontrada.' -Level Info
    }
    if ($state.PageFileUsage) {
        Write-Log 'Uso atual do arquivo de paginacao detectado:' -Level Info
        $state.PageFileUsage | ForEach-Object {
            Write-Log "  - $($_.Name) (TamanhoAlocado=$($_.AllocatedBaseSize) MB, UsoAtual=$($_.CurrentUsage) MB, PicoDeUso=$($_.PeakUsage) MB)" -Level Info
        }
    }
}

function Export-PageFileConfig {
    $exportPath = "C:\Windows\Temp\pagefile_config_backup_$(Get-Date -Format yyyyMMdd_HHmmss).json"
    $exportData = [ordered]@{
        ExportedAt               = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        ComputerName             = $env:COMPUTERNAME
        AutomaticManagedPagefile = $false
        PageFiles                = @()
    }

    try {
        $cs = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop
        $exportData.AutomaticManagedPagefile = [bool]$cs.AutomaticManagedPagefile

        $pageFileSetting = Get-WmiObject -Class Win32_PageFileSetting -ErrorAction SilentlyContinue
        if ($pageFileSetting) {
            Write-Log 'Arquivo(s) de paginacao encontrado(s):' -Level Info
            $pageFileSetting | ForEach-Object {
                Write-Log "  - $($_.Name)  (TamanhoInicial=$($_.InitialSize) MB, TamanhoMaximo=$($_.MaximumSize) MB)" -Level Info
                $exportData.PageFiles += [ordered]@{
                    Name        = $_.Name
                    InitialSize = $_.InitialSize
                    MaximumSize = $_.MaximumSize
                }
            }
        }
        else {
            Write-Log 'Nenhum arquivo de paginacao explicito encontrado (possivelmente gerenciado automaticamente).' -Level Warning
        }

        $exportData | ConvertTo-Json -Depth 5 | Set-Content -Path $exportPath -Encoding UTF8 -Force
        Write-Log "Backup da configuracao do arquivo de paginacao exportado para: $exportPath" -Level Success
    }
    catch {
        Write-Log "Falha ao exportar configuracao do arquivo de paginacao: $($_.Exception.Message)" -Level Warning
    }
}

function Get-PageFileBackup {
    $backupDir = 'C:\Windows\Temp'
    $pattern = 'pagefile_config_backup_*.json'
    $latest = Get-ChildItem -Path $backupDir -Filter $pattern -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $latest) {
        Write-Log "Nenhum arquivo de backup do arquivo de paginacao encontrado em $backupDir ($pattern)." -Level Warning
        return $null
    }

    try {
        $backup = Get-Content -Path $latest.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Log "Backup carregado: $($latest.FullName) (exportado em $($backup.ExportedAt))" -Level Success
        return $backup
    }
    catch {
        Write-Log "Falha ao ler/parsear o backup '$($latest.FullName)': $($_.Exception.Message)" -Level Error
        return $null
    }
}


function Disable-WindowsPagingFile {
    Write-Log '=== Desabilitando arquivo de paginacao do Windows ===' -Level Info

    try {
        Export-PageFileConfig

        $cs = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop
        if ($cs.AutomaticManagedPagefile) {
            $cs.AutomaticManagedPagefile = $false
            $cs.Put() | Out-Null
            Write-Log 'Gerenciamento automatico do arquivo de paginacao desabilitado.' -Level Success
        }
        else {
            Write-Log 'Gerenciamento automatico do arquivo de paginacao ja estava desabilitado.' -Level Info
        }

        $allPageFiles = Get-WmiObject -Class Win32_PageFileSetting -ErrorAction SilentlyContinue
        if ($allPageFiles) {
            foreach ($pf in $allPageFiles) {
                try {
                    $pf.Delete()
                    Write-Log "Arquivo de paginacao removido: $($pf.Name)" -Level Success
                }
                catch {
                    Write-Log "Falha ao remover arquivo de paginacao '$($pf.Name)': $($_.Exception.Message)" -Level Warning
                }
            }
        }

        $regPageFilePath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
        Set-ItemProperty -Path $regPageFilePath -Name 'PagingFiles' -Value '' -Type MultiString -ErrorAction Stop
        Write-Log "Chave 'PagingFiles' zerada no registro." -Level Success
        Write-Log 'Arquivo de paginacao desabilitado com sucesso. Alteracao efetiva apos a reinicializacao.' -Level Success
    }
    catch {
        Write-Log "Erro ao desabilitar arquivo de paginacao: $($_.Exception.Message)" -Level Error
    }
}

function Enable-WindowsPagingFile {
    $regPageFilePath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
    Write-Log '=== Ativando arquivo de paginacao do Windows ===' -Level Info

    $backup = Get-PageFileBackup
    if ($backup) {
        Write-Log 'Configuracao do backup encontrada:' -Level Info
        Write-Log "  GerenciamentoAutomaticoArquivoPaginacao : $($backup.AutomaticManagedPagefile)" -Level Info
        if ($backup.PageFiles -and $backup.PageFiles.Count -gt 0) {
            $backup.PageFiles | ForEach-Object {
                Write-Log "  Arquivo de paginacao : $($_.Name)  TamanhoInicial=$($_.InitialSize) MB  TamanhoMaximo=$($_.MaximumSize) MB" -Level Info
            }
        }
        else {
            Write-Log '  Nenhum arquivo de paginacao explicito no backup (era gerenciado automaticamente).' -Level Info
        }
    }
    else {
        Write-Log 'Backup nao encontrado. Sera utilizada a configuracao padrao (tamanho gerenciado pelo sistema, caminho do drive do sistema).' -Level Warning
    }

    $useAutomatic = $true
    if ($backup -and ($backup.AutomaticManagedPagefile -eq $false) -and ($backup.PageFiles.Count -gt 0)) {
        $useAutomatic = $false
    }

    try {
        if ($useAutomatic) {
            Write-Log 'Modo de restauracao: Gerenciamento automatico pelo sistema operacional.' -Level Info
            $defaultPageFile = Get-DefaultPageFilePath
            Write-Log "Caminho padrao do arquivo de paginacao: $defaultPageFile" -Level Info

            Set-ItemProperty -Path $regPageFilePath -Name 'PagingFiles' -Value @("$defaultPageFile 0 0") -Type MultiString -ErrorAction Stop
            Write-Log "Chave 'PagingFiles' configurada para tamanho gerenciado pelo sistema: $defaultPageFile" -Level Success

            try {
                Set-ItemProperty -Path $regPageFilePath -Name 'ExistingPageFiles' -Value @($defaultPageFile) -Type MultiString -ErrorAction SilentlyContinue
                Write-Log "Chave 'ExistingPageFiles' ajustada para: $defaultPageFile" -Level Success
            }
            catch {
                Write-Log "Falha ao ajustar 'ExistingPageFiles': $($_.Exception.Message)" -Level Warning
            }

            try {
                $cs = Get-WmiObject -Class Win32_ComputerSystem -EnableAllPrivileges -ErrorAction Stop
                $result = $cs.psbase.InvokeMethod('SetAutomaticManagedPagefile', $true)
                Write-Log "WMI SetAutomaticManagedPagefile executado com retorno: $result" -Level Info
            }
            catch {
                Write-Log "Falha no metodo WMI SetAutomaticManagedPagefile: $($_.Exception.Message)" -Level Warning
            }

            try {
                $cs = Get-WmiObject -Class Win32_ComputerSystem -EnableAllPrivileges -ErrorAction Stop
                $cs.AutomaticManagedPagefile = $true
                $cs.Put() | Out-Null
                Write-Log 'Gerenciamento automatico do arquivo de paginacao habilitado com sucesso (WMI).' -Level Success
            }
            catch {
                Write-Log "Falha ao habilitar gerenciamento automatico via WMI: $($_.Exception.Message)" -Level Error
            }

            try {
                Set-CimInstance -Query 'SELECT * FROM Win32_ComputerSystem' -Property @{ AutomaticManagedPagefile = $true } -ErrorAction SilentlyContinue | Out-Null
                Write-Log 'Tentativa adicional via CIM executada.' -Level Info
            }
            catch {
                Write-Log "Falha na tentativa adicional via CIM: $($_.Exception.Message)" -Level Warning
            }
        }
        else {
            Write-Log 'Modo de restauracao: Tamanhos customizados conforme backup.' -Level Info

            try {
                $cs = Get-WmiObject -Class Win32_ComputerSystem -EnableAllPrivileges -ErrorAction Stop
                $cs.AutomaticManagedPagefile = $false
                $cs.Put() | Out-Null
                Write-Log 'Gerenciamento automatico desabilitado para permitir tamanhos customizados.' -Level Info
            }
            catch {
                Write-Log "Falha ao desabilitar gerenciamento automatico: $($_.Exception.Message)" -Level Warning
            }

            $pagingValues = @()
            foreach ($pf in $backup.PageFiles) {
                $pfName = $pf.Name
                $pfInitial = [int]$pf.InitialSize
                $pfMaximum = [int]$pf.MaximumSize
                $pagingValues += "$pfName $pfInitial $pfMaximum"
                Write-Log "Configurando arquivo de paginacao: $pfName  TamanhoInicial=$pfInitial MB  TamanhoMaximo=$pfMaximum MB" -Level Info

                try {
                    $existingPf = Get-WmiObject -Class Win32_PageFileSetting -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -eq $pfName }
                    if ($existingPf) {
                        $existingPf.InitialSize = $pfInitial
                        $existingPf.MaximumSize = $pfMaximum
                        $existingPf.Put() | Out-Null
                        Write-Log "Arquivo de paginacao '$pfName' atualizado via WMI." -Level Success
                    }
                    else {
                        $newPf = ([WMIClass]'Win32_PageFileSetting').CreateInstance()
                        $newPf.Name = $pfName
                        $newPf.InitialSize = $pfInitial
                        $newPf.MaximumSize = $pfMaximum
                        $newPf.Put() | Out-Null
                        Write-Log "Arquivo de paginacao '$pfName' criado via WMI." -Level Success
                    }
                }
                catch {
                    Write-Log "Falha ao configurar arquivo de paginacao '$pfName' via WMI: $($_.Exception.Message)" -Level Warning
                }
            }

            Set-ItemProperty -Path $regPageFilePath -Name 'PagingFiles' -Value $pagingValues -Type MultiString -ErrorAction Stop
            Write-Log "Chave 'PagingFiles' configurada no registro com $($pagingValues.Count) entrada(s)." -Level Success
        }
    }
    catch {
        Write-Log "Erro critico ao ativar o arquivo de paginacao: $($_.Exception.Message)" -Level Error
        throw
    }


    Start-Sleep -Seconds 2
    try {
        $verify = Get-ItemProperty -Path $regPageFilePath -Name 'PagingFiles' -ErrorAction Stop
        Write-Log "Verificacao 'PagingFiles': $($verify.PagingFiles -join '; ')" -Level Success
    }
    catch {
        Write-Log "Nao foi possivel verificar a chave 'PagingFiles': $($_.Exception.Message)" -Level Warning
    }

    $state = Get-PageFileState
    if ($state -and ($state.AutomaticManagedPagefile -or $state.PageFileSettings)) {
        Write-Log 'Confirmado: arquivo de paginacao configurado com sucesso.' -Level Success
    }
    else {
        Write-Log 'Aviso: a confirmacao imediata via WMI pode nao ter refletido ainda. A configuracao sera aplicada apos a reinicializacao.' -Level Warning
    }

    Write-Log 'A alteracao sera aplicada integralmente apos a reinicializacao.' -Level Warning
}

function Invoke-DisablePageFile {
    Show-Banner
    Write-Log '=== Script de Desativacao do Arquivo de Paginacao do Windows ===' -Level Success
    Write-Log "Executando em: $env:COMPUTERNAME"
    Write-Log "Versao do PowerShell: $($PSVersionTable.PSVersion)"
    Write-Log "Versao do Sistema Operacional: $([Environment]::OSVersion.VersionString)"
    Show-PageFileState -Title 'Estado atual do arquivo de paginacao'
    Disable-WindowsPagingFile
    Start-Sleep -Seconds 2
    Show-PageFileState -Title 'Estado final do arquivo de paginacao'
    Confirm-Reboot
}

function Invoke-EnablePageFile {
    $script:ProgressFile = $script:EnablePageFileProgressFile
    Show-Banner
    $currentStep = Resolve-StartStep
    Write-Log "Execucao iniciando a partir da etapa $currentStep." -Level Info
    Write-Log '=== Script de Ativacao do Arquivo de Paginacao do Windows ===' -Level Success
    Write-Log "Executando em: $env:COMPUTERNAME"
    Write-Log "Versao do PowerShell: $($PSVersionTable.PSVersion)"
    Write-Log "Versao do Sistema Operacional: $([Environment]::OSVersion.VersionString)"

    if ($currentStep -le 1) {
        Save-Progress -Step 1 -Description 'Coleta de estado atual do arquivo de paginacao'
        Show-PageFileState -Title 'Estado atual do arquivo de paginacao'
    }
    if ($currentStep -le 2) {
        Save-Progress -Step 2 -Description 'Ativacao do arquivo de paginacao com gerenciamento automatico pelo sistema operacional'
        Enable-WindowsPagingFile
    }
    if ($currentStep -le 3) {
        Save-Progress -Step 3 -Description 'Verificacao final'
        Start-Sleep -Seconds 2
        Show-PageFileState -Title 'Estado final do arquivo de paginacao'
    }

    Clear-Progress
    Confirm-Reboot
}

function Stop-VMwareProcesses {
    $vmProcesses = @('vmtoolsd.exe', 'VGAuthService.exe', 'vmacthlp.exe')
    foreach ($procName in $vmProcesses) {
        Get-Process -Name $procName -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                Write-Log "Encerrando processo $($_.ProcessName) (PID: $($_.Id))"
                Stop-Process -Id $_.Id -Force
            }
            catch {
                Write-Log "Nao foi possivel encerrar o processo $($_.ProcessName): $($_.Exception.Message)" -Level Warning
            }
        }
    }
}

function Take-Ownership {
    param([string]$Path)

    try {
        Write-Log "Assumindo posse de: $Path"
        Start-Process -FilePath 'cmd.exe' -ArgumentList "/c takeown /f `"$Path`" && icacls `"$Path`" /grant administrators:F" -Wait -Verb runAs
    }
    catch {
        Write-Log "Falha ao assumir posse: $($_.Exception.Message)" -Level Warning
    }
}

function Get-VMwareToolsInstallerID {
    Write-Log 'Procurando informacoes do instalador do VMware Tools...'

    try {
        foreach ($item in $(Get-ChildItem Registry::HKEY_CLASSES_ROOT\Installer\Products -ErrorAction SilentlyContinue)) {
            $productName = $item.GetValue('ProductName') -as [string]
            if ($productName -eq 'VMware Tools') {
                $productIcon = $item.GetValue('ProductIcon') -as [string]
                if ($productIcon) {
                    $msiMatch = [Regex]::Match($productIcon, '(?<={)(.*?)(?=})')
                    if ($msiMatch.Success) {
                        Write-Log 'ID do instalador do VMware Tools encontrado.' -Level Success
                        return @{
                            reg_id = $item.PSChildName
                            msi_id = $msiMatch.Value
                        }
                    }
                }
            }
        }
    }
    catch {
        Write-Log "Erro ao procurar ID do instalador: $($_.Exception.Message)" -Level Error
    }

    Write-Log 'ID do instalador do VMware Tools nao encontrado no registro.' -Level Warning
    return $null
}

function Remove-RegistryKey {
    param([string]$Path)

    if (Test-Path $Path) {
        try {
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
            Write-Log "Chave de registro removida: $Path" -Level Success
        }
        catch {
            Write-Log "Falha ao remover chave de registro: $Path - $($_.Exception.Message)" -Level Error
        }
    }
}

function Remove-DirectoryWithRetry {
    param(
        [string]$Path,
        [int]$MaxRetries = 3
    )

    if (-not (Test-Path $Path)) {
        return
    }

    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer } |
                Remove-Item -Force -ErrorAction SilentlyContinue
            Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.PSIsContainer } |
                Sort-Object { $_.FullName.Length } -Descending |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
            Write-Log "Diretorio removido: $Path" -Level Success
            return
        }
        catch {
            if ($i -eq $MaxRetries) {
                Write-Log "Falha ao remover diretorio apos $MaxRetries tentativas: $Path - $($_.Exception.Message)" -Level Error
            }
            else {
                Write-Log "Tentativa $i/$MaxRetries para o diretorio: $Path" -Level Warning
                Start-Sleep -Seconds 2
            }
        }
    }
}


function Unregister-VMwareDLLs {
    $dllPaths = @(
        'C:\Program Files\VMware\VMware Tools\vmStatsProvider\win64\vmStatsProvider.dll',
        'C:\Program Files\VMware\VMware Tools\vmStatsProvider\win32\vmStatsProvider.dll'
    )

    foreach ($dllPath in $dllPaths) {
        if (Test-Path $dllPath) {
            Take-Ownership -Path $dllPath
            try {
                Write-Log "Desregistrando DLL: $dllPath"
                $process = Start-Process -FilePath 'regsvr32.exe' -ArgumentList '/s', '/u', "`"$dllPath`"" -Wait -PassThru
                if ($process.ExitCode -eq 0) {
                    Write-Log "DLL desregistrada com sucesso: $dllPath" -Level Success
                }
                else {
                    Write-Log "Falha ao desregistrar DLL: $dllPath (Codigo de saida: $($process.ExitCode))" -Level Warning
                }
            }
            catch {
                Write-Log "Erro ao desregistrar DLL: $dllPath - $($_.Exception.Message)" -Level Error
            }
        }
    }
}

function Remove-VMwareNetworkAdapters {
    if ($KeepNetworkAdapters) {
        Write-Log 'Remocao de adaptadores de rede ignorada conforme solicitado.'
        return
    }

    Write-Log 'Removendo adaptadores de rede VMware...'
    try {
        $vmxnet3Adapters = Get-NetAdapter | Where-Object { $_.InterfaceDescription -like '*VMXNET3*' }
        foreach ($adapter in $vmxnet3Adapters) {
            Write-Log "Removendo adaptador VMXNET3: $($adapter.Name)"
            Remove-NetAdapter -Name $adapter.Name -Confirm:$false -ErrorAction SilentlyContinue
        }

        $vmwareDevices = Get-PnpDevice | Where-Object {
            $_.FriendlyName -like '*VMware*' -and $_.Class -eq 'Net'
        }
        foreach ($device in $vmwareDevices) {
            try {
                Write-Log "Removendo dispositivo: $($device.FriendlyName)"
                $device | Disable-PnpDevice -Confirm:$false -ErrorAction SilentlyContinue
                $device | Remove-PnpDevice -Confirm:$false -ErrorAction SilentlyContinue
            }
            catch {
                Write-Log "Falha ao remover dispositivo: $($device.FriendlyName)" -Level Warning
            }
        }
    }
    catch {
        Write-Log "Erro durante a limpeza dos adaptadores de rede: $($_.Exception.Message)" -Level Error
    }
}

function Set-EthernetMTU {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [int]$ToMTU = 1500,
        [string]$InterfacePattern = "*Ethernet*",
        [switch]$AllEthernetAdapters
    )

    Write-Log "Iniciando configuracao de MTU nas interfaces Ethernet..." -Level Info
    Write-Log "Valor de MTU Alvo: $ToMTU" -Level Info
    Write-Log "Padrao de Nome da Interface: $InterfacePattern" -Level Info

    try {
        $allIPInterfaces = Get-NetIPInterface -ErrorAction Stop
    } catch {
        Write-Log "Falha ao consultar interfaces IP via Get-NetIPInterface: $_" -Level Error
        return
    }

    $targetIndices = New-Object 'System.Collections.Generic.HashSet[int]'

    # Metodo 1: Correspondencia pelo padrao de nome ("Ethernet", "Ethernet 1", "vEthernet*", etc.)
    $nameMatched = $allIPInterfaces | Where-Object { $_.InterfaceAlias -like $InterfacePattern }
    foreach ($iface in $nameMatched) {
        [void]$targetIndices.Add($iface.InterfaceIndex)
    }

    # Metodo 2: Correspondencia por adaptador de rede Ethernet (802.3)
    try {
        $netAdapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { 
            $_.MediaType -match "802.3" -or $_.PhysicalMediaType -match "802.3" -or $_.InterfaceDescription -match "Ethernet"
        }
        foreach ($adapter in $netAdapters) {
            [void]$targetIndices.Add($adapter.ifIndex)
        }
    } catch {
        # Fallback se Get-NetAdapter nao estiver disponivel
    }

    # Filtrar interfaces que ainda nao possuem o MTU alvo
    $interfacesToUpdate = $allIPInterfaces | Where-Object { 
        $targetIndices.Contains($_.InterfaceIndex) -and $_.NlMtu -ne $ToMTU
    }

    $alreadySetInterfaces = $allIPInterfaces | Where-Object { 
        $targetIndices.Contains($_.InterfaceIndex) -and $_.NlMtu -eq $ToMTU
    }

    if ($alreadySetInterfaces.Count -gt 0) {
        Write-Log "Interfaces ja configuradas com MTU = $ToMTU ($($alreadySetInterfaces.Count)):" -Level Info
        foreach ($already in $alreadySetInterfaces) {
            Write-Host "  - $($already.InterfaceAlias) (Index: $($already.InterfaceIndex), $($already.AddressFamily)): MTU $($already.NlMtu)" -ForegroundColor Gray
        }
    }

    if (-not $interfacesToUpdate -or $interfacesToUpdate.Count -eq 0) {
        Write-Log "Todas as interfaces Ethernet correspondentes ja estao configuradas com MTU = $ToMTU." -Level Success
        return
    }

    Write-Log "Encontrada(s) $($interfacesToUpdate.Count) configuracao(oes) de interface para atualizar para MTU ${ToMTU}:" -Level Info
    foreach ($toUp in $interfacesToUpdate) {
        Write-Host "  - $($toUp.InterfaceAlias) (Index: $($toUp.InterfaceIndex), $($toUp.AddressFamily)): MTU Atual $($toUp.NlMtu)" -ForegroundColor Yellow
    }

    $successCount = 0
    $failCount = 0

    foreach ($iface in $interfacesToUpdate) {
        $alias = $iface.InterfaceAlias
        $ifIndex = $iface.InterfaceIndex
        $af = $iface.AddressFamily
        $currentMtu = $iface.NlMtu

        $targetDescription = "Interface '$alias' (Index: $ifIndex, $af) MTU de $currentMtu para $ToMTU"

        if ($PSCmdlet.ShouldProcess($targetDescription, "Set-NetIPInterface -NlMtu $ToMTU")) {
            try {
                Set-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily $af -NlMtu $ToMTU -ErrorAction Stop
                Write-Log "Atualizado com sucesso $alias (Index: $ifIndex, $af): MTU $currentMtu -> $ToMTU" -Level Success
                $successCount++
            } catch {
                Write-Log "Falha ao atualizar $alias (Index: $ifIndex, $af): $_" -Level Error
                $failCount++
            }
        }
    }

    Write-Log "Resumo da alteracao de MTU: $successCount atualizadas, $failCount falhas." -Level Info
}

function Set-VirtIOStorageTimeout {
    $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\vioscsi\Parameters'
    $valueName = 'IoTimeoutValue'
    $timeoutSeconds = 120

    Write-Log '=== Configurando timeout de I/O do driver VirtIO SCSI ===' -Level Info
    if (-not (Test-Path $regPath)) {
        try {
            New-Item -Path $regPath -Force | Out-Null
            Write-Log "Chave de registro criada: $regPath" -Level Success
        }
        catch {
            Write-Log "Falha ao criar chave de registro: $regPath - $($_.Exception.Message)" -Level Error
            return
        }
    }
 

    try {
        Set-ItemProperty -Path $regPath -Name $valueName -Value $timeoutSeconds -Type DWord -ErrorAction Stop
        Write-Log "IoTimeoutValue definido como $timeoutSeconds segundos em: $regPath" -Level Success
        $result = Get-ItemProperty -Path $regPath -Name $valueName -ErrorAction Stop
        Write-Log "Verificacao: $valueName = $($result.$valueName) em [$regPath]" -Level Success
    }
    catch {
        Write-Log "Nao foi possivel configurar/verificar o valor IoTimeoutValue: $($_.Exception.Message)" -Level Warning
    }
}

function Invoke-RemoveVMwareTools {
    $script:ProgressFile = $script:RemoveVMwareProgressFile
    Show-Banner
    $currentStep = Resolve-StartStep
    Write-Log "Execucao iniciando a partir da etapa $currentStep." -Level Info

    if ($currentStep -le 0) {
        Save-Progress -Step 0 -Description 'Preparacao inicial dos servicos VMware'
        Write-Log 'Etapa 0: Verificando status de todos os servicos relacionados ao VMware...'
        $allVMWareServices = Get-Service | Where-Object {
            $_.DisplayName -like '*VMware*' -or
            $_.ServiceName -like '*VMWare*' -or
            $_.ServiceName -like '*VMTools*' -or
            $_.DisplayName -like '*Tools*' -or
            $_.ServiceName -eq 'GISvc'
        }

        foreach ($svc in $allVMWareServices) {
            try {
                Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$($svc.Name)" -Name 'Start' -Value 3
                Write-Log "Tipo de inicializacao de '$($svc.DisplayName)' ($($svc.Name)) definido como Manual." -Level Success
            }
            catch {
                Write-Log "Falha ao definir '$($svc.DisplayName)' ($($svc.Name)) como Manual: $($_.Exception.Message)" -Level Warning
            }
            if ($svc.Status -eq 'Running') {
                Write-Log "Servico em execucao: $($svc.DisplayName). Parando..."
                try {
                    Stop-Service -Name $svc.Name -Force -ErrorAction Stop
                }
                catch {
                    Write-Log "Falha ao parar '$($svc.DisplayName)': $($_.Exception.Message)" -Level Warning
                }
            }
        }
    }

    Write-Log '=== Script de Remocao Avancada do VMware Tools ===' -Level Success
    Write-Log "Executando em: $env:COMPUTERNAME"
    Write-Log "Versao do PowerShell: $($PSVersionTable.PSVersion)"
    Write-Log "Versao do Sistema Operacional: $([Environment]::OSVersion.VersionString)"

    $vmwareToolsIds = Get-VMwareToolsInstallerID
    $regTargets = @(
        'Registry::HKEY_CLASSES_ROOT\Installer\Features\',
        'Registry::HKEY_CLASSES_ROOT\Installer\Products\',
        'HKLM:\SOFTWARE\Classes\Installer\Features\',
        'HKLM:\SOFTWARE\Classes\Installer\Products\',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\'
    )
    $filesystemTargets = @(
        'C:\Program Files\VMware',
        'C:\Program Files\Common Files\VMware',
        'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\VMware',
        'C:\ProgramData\VMware'
    )

    $targets = @()
    if ($vmwareToolsIds) {
        foreach ($item in $regTargets) {
            $targets += $item + $vmwareToolsIds.reg_id
        }
        $targets += "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{$($vmwareToolsIds.msi_id)}"
    }

    if ([Environment]::OSVersion.Version.Major -lt 10) {
        $targets += @(
            'HKCR:\CLSID\{D86ADE52-C4D9-4B98-AA0D-9B0C7F1EBBC8}',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{9709436B-5A41-4946-8BE7-2AA433CAF108}',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{FE2F6A2C-196E-4210-9C04-2B1BC21F07EF}'
        )
    }

    $additionalRegistryKeys = @(
        'HKLM:\SOFTWARE\VMware, Inc.',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run\VMware User Process'
    )
    foreach ($key in $additionalRegistryKeys) {
        if (Test-Path $key) {
            $targets += $key
        }
    }
    foreach ($path in $filesystemTargets) {
        if (Test-Path $path) {
            $targets += $path
        }
    }

    Write-Log 'Verificando servicos VMware instalados...'
    $services = @()
    $services += Get-Service -DisplayName 'VMware*' -ErrorAction SilentlyContinue
    $services += Get-Service -DisplayName 'GISvc' -ErrorAction SilentlyContinue

    Write-Log '=== RESUMO DA REMOCAO ===' -Level Warning
    if ($targets.Count -eq 0 -and $services.Count -eq 0) {
        Write-Log 'Nada a fazer! O VMware Tools nao parece estar instalado.' -Level Success
        Clear-Progress
        return
    }

    Write-Log 'Os seguintes itens serao removidos:'
    Write-Log 'Chaves de registro e diretorios:' -Level Warning
    $targets | ForEach-Object { Write-Log "  - $_" }
    if ($services.Count -gt 0) {
        Write-Log 'Servicos:' -Level Warning
        $services | ForEach-Object { Write-Log "  - $($_.DisplayName) ($($_.Name))" }
    }
    if (-not $KeepNetworkAdapters) {
        Write-Log 'Os adaptadores de rede VMware tambem serao removidos.' -Level Warning
    }

    Write-Log '=== INICIANDO PROCESSO DE REMOCAO ===' -Level Success
    if ($currentStep -le 1) {
        Save-Progress -Step 1 -Description 'Encerramento de processos VMware e desregistro de DLLs'
        Write-Log 'Encerrando processos do VMware Tools em execucao...'
        Stop-VMwareProcesses
        Write-Log 'Etapa 1: Desregistrando DLLs do VMware...'
        Unregister-VMwareDLLs
    }

    if ($currentStep -le 2) {
        Save-Progress -Step 2 -Description 'Parada e remocao de servicos VMware'
        if ($services.Count -gt 0) {
            Write-Log 'Etapa 2: Parando e removendo servicos VMware...'
            foreach ($service in $services) {
                try {
                    Write-Log "Parando servico: $($service.DisplayName)"
                    Stop-Service -Name $service.Name -Force -ErrorAction SilentlyContinue
                }
                catch {
                    Write-Log "Falha ao parar o servico: $($service.Name)" -Level Warning
                }
            }
            if (Get-Command Remove-Service -ErrorAction SilentlyContinue) {
                foreach ($service in $services) {
                    try {
                        Remove-Service -Name $service.Name -Confirm:$false -ErrorAction SilentlyContinue
                        Write-Log "Servico removido: $($service.DisplayName)" -Level Success
                    }
                    catch {
                        Write-Log "Falha ao remover servico: $($service.Name)" -Level Warning
                    }
                }
            }
            else {
                foreach ($service in $services) {
                    try {
                        $result = & sc.exe DELETE $service.Name 2>&1
                        if ($LASTEXITCODE -eq 0) {
                            Write-Log "Servico removido: $($service.DisplayName)" -Level Success
                        }
                        else {
                            Write-Log "Falha ao remover servico: $($service.Name) - $result" -Level Warning
                        }
                    }
                    catch {
                        Write-Log "Erro ao remover servico: $($service.Name)" -Level Warning
                    }
                }
            }
        }
    }

    $dependentServices = @()
    if ($currentStep -le 3) {
        Save-Progress -Step 3 -Description 'Parada temporaria de servicos dependentes'
        Write-Log 'Etapa 3: Parando temporariamente servicos dependentes...'
        try {
            $dependentServices += Get-Service -Name 'EventLog' -DependentServices -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
            $dependentServices += Get-Service -Name 'winmgmt' -DependentServices -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
            Stop-Service -Name 'EventLog' -Force -ErrorAction SilentlyContinue
            Stop-Service -Name 'wmiApSrv' -Force -ErrorAction SilentlyContinue
            Stop-Service -Name 'winmgmt' -Force -ErrorAction SilentlyContinue
            Write-Log 'Aguardando os servicos pararem...'
            Start-Sleep -Seconds 5
        }
        catch {
            Write-Log 'Aviso: Nao foi possivel parar alguns servicos dependentes.' -Level Warning
        }
    }

    if ($currentStep -le 4) {
        Save-Progress -Step 4 -Description 'Remocao de arquivos e entradas de registro'
        Write-Log 'Etapa 4: Removendo arquivos e entradas de registro...'
        foreach ($target in $targets) {
            if ($target.StartsWith('HKLM:') -or $target.StartsWith('HKCR:') -or $target.StartsWith('Registry::')) {
                Remove-RegistryKey -Path $target
            }
            else {
                Remove-DirectoryWithRetry -Path $target
            }
        }
    }

    if ($currentStep -le 5) {
        Save-Progress -Step 5 -Description 'Remocao de adaptadores de rede VMware'
        Write-Log 'Etapa 5: Removendo adaptadores de rede VMware...'
        Remove-VMwareNetworkAdapters
    }

    if ($currentStep -le 6) {
        Save-Progress -Step 6 -Description 'Reinicio de servicos dependentes'
        Write-Log 'Etapa 6: Reiniciando servicos dependentes...'
        try {
            Start-Service -Name 'EventLog' -ErrorAction SilentlyContinue
            Start-Service -Name 'wmiApSrv' -ErrorAction SilentlyContinue
            Start-Service -Name 'winmgmt' -ErrorAction SilentlyContinue
            foreach ($serviceName in $dependentServices) {
                try {
                    Start-Service -Name $serviceName -ErrorAction SilentlyContinue
                }
                catch { }
            }
        }
        catch {
            Write-Log 'Aviso: Alguns servicos podem precisar ser reiniciados manualmente.' -Level Warning
        }
    }

    Write-Log '=== VERIFICACAO POS-REMOCAO ===' -Level Success
    $remainingServices = Get-Service -DisplayName 'VMware*' -ErrorAction SilentlyContinue
    $remainingFiles = @()
    foreach ($path in $filesystemTargets) {
        if (Test-Path $path) {
            $remainingFiles += $path
        }
    }
    if ($remainingServices.Count -gt 0) {
        Write-Log 'Aviso: Alguns servicos VMware ainda existem:' -Level Warning
        $remainingServices | ForEach-Object { Write-Log "  - $($_.DisplayName)" -Level Warning }
    }
    if ($remainingFiles.Count -gt 0) {
        Write-Log 'Aviso: Alguns arquivos/diretorios ainda existem:' -Level Warning
        $remainingFiles | ForEach-Object { Write-Log "  - $_" -Level Warning }
    }
    if ($remainingServices.Count -eq 0 -and $remainingFiles.Count -eq 0) {
        Write-Log 'Remocao do VMware Tools concluida com sucesso!' -Level Success
    }
    else {
        Write-Log 'Remocao do VMware Tools concluida com avisos. Verifique os detalhes acima.' -Level Warning
    }

    if ($currentStep -le 7) {
        Save-Progress -Step 7 -Description 'Configuracoes pre-reinicializacao'
        Write-Log '=== Etapa 7: Configuracoes pre-reinicializacao ===' -Level Success
        Set-VirtIOStorageTimeout
        Disable-WindowsPagingFile
    }

    Clear-Progress
    Confirm-Reboot
}

function Get-VirtioDrivers {
    Get-CimInstance -ClassName Win32_PnPSignedDriver |
        Where-Object {
            $_.DeviceName -match 'VirtIO|QEMU|Red Hat|Balloon|NetKVM|viostor|vioscsi|vioinput|viorng|fwcfg' -or
            $_.Manufacturer -match 'Red Hat|QEMU|VirtIO' -or
            $_.DriverProviderName -match 'Red Hat|QEMU|VirtIO' -or
            $_.InfName -match 'vioscsi|viostor|netkvm|balloon|vioinput|viorng|fwcfg'
        } |
        Select-Object DeviceName, DriverVersion, Manufacturer, DriverProviderName, InfName, DriverDate |
        Sort-Object DeviceName, InfName
}

function Convert-DriverEvidenceForDisplay {
    param(
        [Parameter(Mandatory = $true)][array]$Drivers
    )

    foreach ($driver in $Drivers) {
        [PSCustomObject]@{
            NomeDoDispositivo = $driver.DeviceName
            VersaoDoDriver    = $driver.DriverVersion
            Fabricante        = $driver.Manufacturer
            ProvedorDoDriver  = $driver.DriverProviderName
            NomeDoInf         = $driver.InfName
            DataDoDriver      = $driver.DriverDate
        }
    }
}

function Save-DriverEvidence {
    param(
        [Parameter(Mandatory = $true)][array]$Drivers,
        [Parameter(Mandatory = $true)][string]$CsvPath,
        [Parameter(Mandatory = $true)][string]$TxtPath,
        [Parameter(Mandatory = $true)][string]$Title
    )

    $displayDrivers = @(Convert-DriverEvidenceForDisplay -Drivers $Drivers)
    $displayDrivers | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    $report = @()
    $report += $Title
    $report += ('Gerado em: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $report += ''
    if ($Drivers.Count -gt 0) {
        $report += ($displayDrivers | Format-Table -AutoSize | Out-String)
    }
    else {
        $report += 'Nenhum driver VirtIO/QEMU/Red Hat correspondente foi encontrado.'
    }
    $report | Out-File -FilePath $TxtPath -Encoding UTF8
}

function Show-DriverEvidenceOnScreen {
    param(
        [Parameter(Mandatory = $true)][array]$Drivers,
        [Parameter(Mandatory = $true)][string]$Title
    )

    Write-Host ''
    Write-Host '===============================================================' -ForegroundColor Cyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host '===============================================================' -ForegroundColor Cyan
    if ($Drivers.Count -gt 0) {
        Convert-DriverEvidenceForDisplay -Drivers $Drivers | Format-Table -AutoSize
    }
    else {
        Write-Host 'Nenhum driver VirtIO/QEMU/Red Hat correspondente foi encontrado.' -ForegroundColor Yellow
    }
    Write-Host ''
}


function Compare-DriverEvidence {
    param(
        [Parameter(Mandatory = $true)][array]$Before,
        [Parameter(Mandatory = $true)][array]$After
    )

    $comparison = foreach ($beforeItem in $Before) {
        $afterItem = $After | Where-Object {
            $_.DeviceName -eq $beforeItem.DeviceName -and $_.InfName -eq $beforeItem.InfName
        } | Select-Object -First 1

        [PSCustomObject]@{
            NomeDoDispositivo  = $beforeItem.DeviceName
            NomeDoInf          = $beforeItem.InfName
            Fabricante         = $beforeItem.Manufacturer
            ProvedorDoDriver   = $beforeItem.DriverProviderName
            VersaoAntes        = $beforeItem.DriverVersion
            VersaoDepois       = if ($afterItem) { $afterItem.DriverVersion } else { '' }
            Alterado           = if ($afterItem -and $beforeItem.DriverVersion -ne $afterItem.DriverVersion) { 'SIM' } elseif ($afterItem) { 'NAO' } else { 'REMOVIDO/NAO_ENCONTRADO' }
            DataDoDriverAntes  = $beforeItem.DriverDate
            DataDoDriverDepois = if ($afterItem) { $afterItem.DriverDate } else { '' }
        }
    }

    $newOnly = foreach ($afterItem in $After) {
        $beforeItem = $Before | Where-Object {
            $_.DeviceName -eq $afterItem.DeviceName -and $_.InfName -eq $afterItem.InfName
        } | Select-Object -First 1

        if (-not $beforeItem) {
            [PSCustomObject]@{
                NomeDoDispositivo  = $afterItem.DeviceName
                NomeDoInf          = $afterItem.InfName
                Fabricante         = $afterItem.Manufacturer
                ProvedorDoDriver   = $afterItem.DriverProviderName
                VersaoAntes        = ''
                VersaoDepois       = $afterItem.DriverVersion
                Alterado           = 'NOVO'
                DataDoDriverAntes  = ''
                DataDoDriverDepois = $afterItem.DriverDate
            }
        }
    }

    @($comparison + $newOnly) | Sort-Object NomeDoDispositivo, NomeDoInf
}

function Remove-LocalMediaFolder {
    param([Parameter(Mandatory = $true)][string]$FolderPath)

    Write-Host ''
    Write-Host '===============================================================' -ForegroundColor Cyan
    Write-Host ' Limpeza da pasta local de midia copiada para C:\Windows\Temp  ' -ForegroundColor Cyan
    Write-Host '===============================================================' -ForegroundColor Cyan

    if (-not (Test-Path $FolderPath)) {
        Write-Host "Pasta nao encontrada (ja removida ou nunca criada): $FolderPath" -ForegroundColor Yellow
        return
    }

    try {
        Remove-Item -Path $FolderPath -Recurse -Force -ErrorAction Stop
        Write-Host "Pasta removida com sucesso: $FolderPath" -ForegroundColor Green
    }
    catch {
        Write-Host "AVISO: Falha ao remover a pasta '$FolderPath': $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Test-VirtioMediaIntegrity {
    <#
      Integridade do instalador, adaptada ao que cada fonte oferece.
      1) Precisa ser um MSI de verdade (assinatura de formato OLE D0 CF 11 E0).
         Isso sozinho ja barra pagina HTML de erro ou de desafio anti-bot baixada
         por engano no lugar do arquivo.
      2) Se o MSI for assinado (builds downstream da Red Hat), exige Authenticode
         valido e assinante Red Hat/Fedora.
      3) Se nao for assinado (os builds upstream do Fedora nao sao), aceita com
         aviso, confiando na validade do MSI e no transporte da fonte (HTTPS).
      Um MSI assinado porem invalido e sempre rejeitado.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path $Path)) {
        return [PSCustomObject]@{ Ok = $false; Reason = "arquivo nao encontrado: $Path" }
    }

    try {
        $fs = [System.IO.File]::OpenRead($Path)
        $magic = New-Object byte[] 8
        [void]$fs.Read($magic, 0, 8)
        $fs.Close()
    }
    catch {
        return [PSCustomObject]@{ Ok = $false; Reason = "falha ao ler o arquivo: $($_.Exception.Message)" }
    }
    $expected = 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1
    for ($k = 0; $k -lt 8; $k++) {
        if ($magic[$k] -ne $expected[$k]) {
            return [PSCustomObject]@{ Ok = $false; Reason = 'o arquivo baixado nao e um MSI (formato invalido; provavel pagina de erro ou anti-bot)' }
        }
    }

    try {
        $sig = Get-AuthenticodeSignature -FilePath $Path -ErrorAction Stop
    }
    catch {
        return [PSCustomObject]@{ Ok = $false; Reason = "falha ao ler assinatura: $($_.Exception.Message)" }
    }

    $subject = ''
    if ($sig.SignerCertificate) { $subject = $sig.SignerCertificate.Subject }
    $isRedHat = $subject -match 'Red Hat|Fedora|virtio-win'

    # Conteudo nao confere com a assinatura: adulterado. Sempre rejeita.
    if ($sig.Status -eq 'HashMismatch') {
        return [PSCustomObject]@{ Ok = $false; Reason = 'conteudo nao confere com a assinatura (arquivo adulterado)' }
    }
    # Assinatura confiavel de ponta a ponta.
    if ($sig.Status -eq 'Valid') {
        if ($isRedHat) { return [PSCustomObject]@{ Ok = $true; Reason = "assinado e valido ($subject)" } }
        return [PSCustomObject]@{ Ok = $false; Reason = "assinado por terceiro inesperado: $subject" }
    }
    # Assinado pela Red Hat, mas a cadeia nao e' confiavel neste ambiente (cert
    # de dev/self-signed, ou raiz ausente). Nao e' adulteracao: o conteudo bate
    # com a assinatura, so' a confianca na raiz que falta. Aceita.
    if ($isRedHat) {
        return [PSCustomObject]@{ Ok = $true; Reason = "assinado pela Red Hat, cadeia nao verificavel no ambiente (status: $($sig.Status)); aceito por assinante e formato" }
    }
    # Sem assinatura (builds upstream do Fedora): aceita por formato + transporte.
    if ($sig.Status -eq 'NotSigned') {
        return [PSCustomObject]@{ Ok = $true; Reason = 'MSI integro, porem NAO assinado (build upstream); aceito por formato e transporte HTTPS' }
    }
    return [PSCustomObject]@{ Ok = $false; Reason = "assinatura invalida e assinante desconhecido (status: $($sig.Status), signer: $subject)" }
}

function Get-VirtioFromNas {
    param([string]$NasPath, [string]$WorkDir)

    if ([string]::IsNullOrWhiteSpace($NasPath)) {
        Write-Log 'Fonte NAS: nenhum -NasPath informado; pulando a fonte NAS.' -Level Info
        return $null
    }
    Write-Log "Fonte NAS: tentando $NasPath" -Level Info
    $nasMsi = Join-Path $NasPath 'virtio-win-gt-x64.msi'
    if (-not (Test-Path $nasMsi)) {
        Write-Log 'Fonte NAS indisponivel: compartilhamento inacessivel ou MSI ausente.' -Level Warning
        return $null
    }
    try {
        $dstMsi = Join-Path $WorkDir 'virtio-win-gt-x64.msi'
        Copy-Item -Path $nasMsi -Destination $dstMsi -Force -ErrorAction Stop
        $dstExe = $null
        $nasExe = Join-Path $NasPath 'virtio-win-guest-tools.exe'
        if (Test-Path $nasExe) {
            $wantExe = Join-Path $WorkDir 'virtio-win-guest-tools.exe'
            Copy-Item -Path $nasExe -Destination $wantExe -Force -ErrorAction SilentlyContinue
            if (Test-Path $wantExe) { $dstExe = $wantExe }
        }
        Write-Log 'Fonte NAS: MSI copiado com sucesso.' -Level Success
        return [PSCustomObject]@{ Msi = $dstMsi; Exe = $dstExe }
    }
    catch {
        Write-Log "Fonte NAS falhou: $($_.Exception.Message)" -Level Warning
        return $null
    }
}

function Get-VirtioFromUrl {
    param([string]$DownloadUrl, [string]$WorkDir)

    # User-Agent nao-browser: o fedorapeople roda o anti-bot Anubis, que entrega
    # uma pagina de desafio para UA tipo Mozilla (o padrao do Invoke-WebRequest),
    # em vez do arquivo. Um UA de ferramenta (curl) passa direto.
    $ua = 'curl/8.4.0'
    Write-Log "Fonte URL: tentando download de $DownloadUrl" -Level Info
    $dstMsi = Join-Path $WorkDir 'virtio-win-gt-x64.msi'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri "$DownloadUrl/virtio-win-gt-x64.msi" -OutFile $dstMsi -UseBasicParsing -UserAgent $ua -ErrorAction Stop
    }
    catch {
        Write-Log "Fonte URL falhou: $($_.Exception.Message)" -Level Warning
        return $null
    }

    $dstExe = $null
    try {
        $tryExe = Join-Path $WorkDir 'virtio-win-guest-tools.exe'
        Invoke-WebRequest -Uri "$DownloadUrl/virtio-win-guest-tools.exe" -OutFile $tryExe -UseBasicParsing -UserAgent $ua -ErrorAction Stop
        $dstExe = $tryExe
    }
    catch {
        Write-Log "Fonte URL: guest-tools.exe nao baixado ($($_.Exception.Message)). Prosseguindo so com o MSI." -Level Warning
    }
    Write-Log 'Fonte URL: MSI baixado com sucesso.' -Level Success
    return [PSCustomObject]@{ Msi = $dstMsi; Exe = $dstExe }
}

function Get-VirtioFromLocal {
    param([string]$LocalMediaPath)

    Write-Log "Fonte Local: procurando em $LocalMediaPath" -Level Info
    $localMsi = Join-Path $LocalMediaPath 'virtio-win-gt-x64.msi'
    if (-not (Test-Path $localMsi)) {
        Write-Log 'Fonte Local indisponivel: nenhum MSI colocado previamente na VM.' -Level Warning
        return $null
    }
    $localExe = Join-Path $LocalMediaPath 'virtio-win-guest-tools.exe'
    $exe = $null
    if (Test-Path $localExe) { $exe = $localExe }
    Write-Log 'Fonte Local: MSI encontrado.' -Level Success
    return [PSCustomObject]@{ Msi = $localMsi; Exe = $exe }
}

function Resolve-VirtioMedia {
    <#
      Resolve a midia virtio tentando as fontes na ordem pedida e parando na
      primeira que entregue um MSI integro. Retorna um objeto com a fonte usada
      e os caminhos do MSI e (se houver) do EXE guest-tools, ou $null se nenhuma
      fonte funcionou.
    #>
    param(
        [string]$MediaSource,
        [string]$NasPath,
        [string]$DownloadUrl,
        [string]$LocalMediaPath,
        [string]$WorkDir
    )

    $order = switch ($MediaSource) {
        'NAS'   { , @('NAS') }
        'URL'   { , @('URL') }
        'Local' { , @('Local') }
        default { , @('NAS', 'URL', 'Local') }
    }

    foreach ($src in $order) {
        $media = switch ($src) {
            'NAS'   { Get-VirtioFromNas   -NasPath $NasPath -WorkDir $WorkDir }
            'URL'   { Get-VirtioFromUrl   -DownloadUrl $DownloadUrl -WorkDir $WorkDir }
            'Local' { Get-VirtioFromLocal -LocalMediaPath $LocalMediaPath }
        }
        if (-not $media) { continue }

        $chk = Test-VirtioMediaIntegrity -Path $media.Msi
        if (-not $chk.Ok) {
            Write-Log "Fonte $src rejeitada: $($chk.Reason)" -Level Error
            continue
        }
        Write-Log "Integridade do MSI validada ($($chk.Reason))." -Level Success
        return [PSCustomObject]@{ Source = $src; Msi = $media.Msi; Exe = $media.Exe }
    }

    return $null
}

function Install-VirtioMedia {
    param(
        [Parameter(Mandatory = $true)][string]$Msi,
        [string]$Exe,
        [Parameter(Mandatory = $true)][string]$LogDir
    )

    $msiLog = Join-Path $LogDir 'virtio-win-gt-x64.log'
    Write-Log 'Instalando MSI dos drivers (silencioso)...' -Level Info
    $msiProcess = Start-Process -FilePath 'msiexec.exe' `
        -ArgumentList "/i `"$Msi`" /qn /norestart /L*v `"$msiLog`" ADDLOCAL=ALL" `
        -Wait -PassThru
    if (($msiProcess.ExitCode -ne 0) -and ($msiProcess.ExitCode -ne 3010) -and ($msiProcess.ExitCode -ne 1641)) {
        # O instalador recusa downgrade: se a VM ja tem virtio igual ou mais
        # novo, o MSI retorna 1603 com "a newer version is already installed".
        # Isso nao e falha de instalacao, e sim "nada a fazer, ja esta ok".
        $alreadyNewer = $false
        if (($msiProcess.ExitCode -eq 1603) -and (Test-Path $msiLog)) {
            if (Select-String -Path $msiLog -Pattern 'newer version .* is already installed|already installed' -Quiet) {
                $alreadyNewer = $true
            }
        }
        if ($alreadyNewer) {
            return [PSCustomObject]@{ Ok = $false; AlreadyPresent = $true; Reason = 'uma versao igual ou mais nova do virtio ja esta instalada'; RebootRequested = $false }
        }
        return [PSCustomObject]@{ Ok = $false; AlreadyPresent = $false; Reason = "MSI ExitCode=$($msiProcess.ExitCode), veja $msiLog"; RebootRequested = $false }
    }

    $rebootRequested = (($msiProcess.ExitCode -eq 3010) -or ($msiProcess.ExitCode -eq 1641))

    if ($Exe -and (Test-Path $Exe)) {
        $exeLog = Join-Path $LogDir 'virtio-win-guest-tools.log'
        Write-Log 'Instalando guest-tools.exe (silencioso)...' -Level Info
        $exeProcess = Start-Process -FilePath $Exe `
            -ArgumentList "/install /quiet /norestart ACCEPTEULA=1 /log `"$exeLog`"" `
            -Wait -PassThru
        if (($exeProcess.ExitCode -ne 0) -and ($exeProcess.ExitCode -ne 3010) -and ($exeProcess.ExitCode -ne 1641)) {
            return [PSCustomObject]@{ Ok = $false; Reason = "EXE ExitCode=$($exeProcess.ExitCode), veja $exeLog"; RebootRequested = $rebootRequested }
        }
        if (($exeProcess.ExitCode -eq 3010) -or ($exeProcess.ExitCode -eq 1641)) { $rebootRequested = $true }
    }
    else {
        Write-Log 'guest-tools.exe ausente nesta fonte; instalado apenas o MSI de drivers.' -Level Warning
    }

    return [PSCustomObject]@{ Ok = $true; Reason = 'instalacao concluida'; RebootRequested = $rebootRequested }
}

function Invoke-UpdateDrivers {
    [CmdletBinding()]
    param(
        [string]$MediaSource = 'Auto',
        [string]$NasPath,
        [string]$DownloadUrl,
        [string]$LocalMediaPath
    )

    Show-Banner
    $logDir = 'C:\Windows\Temp'
    $workDir = Join-Path $logDir 'posmig-virtio-work'

    # Evidencia ANTES. Enviada ao host (Out-Host) para nao poluir a saida da
    # funcao, cujo unico valor de retorno e o codigo em $script:DriverRc.
    $before = @(Get-VirtioDrivers)
    Show-DriverEvidenceOnScreen -Drivers $before -Title 'EVIDENCIA DE DRIVERS ANTES' | Out-Host
    Save-DriverEvidence -Drivers $before -CsvPath (Join-Path $logDir 'virtio-drivers-before.csv') -TxtPath (Join-Path $logDir 'virtio-drivers-before.txt') -Title 'EVIDENCIA DE DRIVERS ANTES DA ATUALIZACAO'

    if (Test-Path $workDir) { Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null

    Write-Log "=== Resolvendo midia de drivers (estrategia: $MediaSource) ===" -Level Info
    $media = Resolve-VirtioMedia -MediaSource $MediaSource -NasPath $NasPath -DownloadUrl $DownloadUrl -LocalMediaPath $LocalMediaPath -WorkDir $workDir

    if (-not $media) {
        Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
        if ($before.Count -gt 0) {
            $summary = (($before | ForEach-Object { "$($_.InfName)=$($_.DriverVersion)" }) | Sort-Object -Unique) -join ', '
            Write-Log 'Nao foi possivel instalar drivers por nenhuma fonte (NAS, URL e Local indisponiveis).' -Level Warning
            Write-Log 'A VM JA POSSUI drivers virtio instalados. Nada foi alterado.' -Level Success
            Write-Log "Versao instalada atual: $summary" -Level Info
            Write-Host "RESULT: UpdateDrivers status=SKIPPED_ALREADY_PRESENT source=none installed=[$summary]" -ForegroundColor Yellow
            $script:DriverRc = 10
            return $script:DriverRc
        }
        Write-Log 'Nao foi possivel instalar drivers por nenhuma fonte, e a VM NAO possui virtio instalado.' -Level Error
        Write-Host 'RESULT: UpdateDrivers status=FAILED_NO_VIRTIO source=none installed=[]' -ForegroundColor Red
        $script:DriverRc = 11
        return $script:DriverRc
    }

    Write-Log "Midia obtida da fonte: $($media.Source)" -Level Success

    $install = Install-VirtioMedia -Msi $media.Msi -Exe $media.Exe -LogDir $logDir
    if (-not $install.Ok) {
        Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
        if ($install.AlreadyPresent) {
            $summary = (($before | ForEach-Object { "$($_.InfName)=$($_.DriverVersion)" }) | Sort-Object -Unique) -join ', '
            Write-Log 'O instalador recusou: a VM ja possui virtio igual ou mais novo. Nada foi alterado.' -Level Success
            Write-Log "Versao instalada atual: $summary" -Level Info
            Write-Host "RESULT: UpdateDrivers status=SKIPPED_ALREADY_PRESENT source=$($media.Source) installed=[$summary]" -ForegroundColor Yellow
            $script:DriverRc = 10
            return $script:DriverRc
        }
        Write-Log "Falha na instalacao: $($install.Reason)" -Level Error
        Write-Host "RESULT: UpdateDrivers status=FAILED_INSTALL source=$($media.Source) reason=`"$($install.Reason)`"" -ForegroundColor Red
        $script:DriverRc = 13
        return $script:DriverRc
    }

    Set-VirtIOStorageTimeout

    $after = @(Get-VirtioDrivers)
    Show-DriverEvidenceOnScreen -Drivers $after -Title 'EVIDENCIA DE DRIVERS DEPOIS' | Out-Host
    Save-DriverEvidence -Drivers $after -CsvPath (Join-Path $logDir 'virtio-drivers-after.csv') -TxtPath (Join-Path $logDir 'virtio-drivers-after.txt') -Title 'EVIDENCIA DE DRIVERS APOS A ATUALIZACAO'
    $comparison = @(Compare-DriverEvidence -Before $before -After $after)
    $comparison | Export-Csv -Path (Join-Path $logDir 'virtio-drivers-compare.csv') -NoTypeInformation -Encoding UTF8

    $summaryAfter = (($after | ForEach-Object { "$($_.InfName)=$($_.DriverVersion)" }) | Sort-Object -Unique) -join ', '

    Write-Log '=== Desabilitando arquivo de paginacao antes da reinicializacao ===' -Level Info
    Disable-WindowsPagingFile
    Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-BigRestartWarning

    Write-Log 'Instalacao de drivers concluida. Reinicie o Windows para aplicar.' -Level Success
    Write-Host "RESULT: UpdateDrivers status=SUCCESS source=$($media.Source) installed=[$summaryAfter] reboot_required=$($install.RebootRequested)" -ForegroundColor Green
    $script:DriverRc = 0
    return $script:DriverRc
}

function Wait-ReturnToMenu {
    Write-Host ''
    Read-Host 'Pressione ENTER para retornar ao menu' | Out-Null
}

function Invoke-ImmediateReboot {
    Write-Log 'Reinicializacao imediata solicitada pelo menu.' -Level Warning
    Restart-Computer -Force
}

function Invoke-SetEthernetMTU {
    Show-Banner
    Set-EthernetMTU
}

function Show-ActionMenu {
    do {
        Show-Banner
        Write-Host 'Selecione uma acao:' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  1 - Remover VMware Tools'
        Write-Host '  2 - Desativacao do arquivo de paginacao'
        Write-Host '  3 - Ativacao do arquivo de paginacao'
        Write-Host '  4 - Atualizar drivers'
        Write-Host '  5 - Alterar MTU das interfaces Ethernet para 1500'
        Write-Host '  6 - Reboot'
        Write-Host '  0 - Sair'
        Write-Host ''
        $choice = Read-Host 'Opcao'

        switch ($choice) {
            '1' { Invoke-RemoveVMwareTools; Wait-ReturnToMenu }
            '2' { Invoke-DisablePageFile; Wait-ReturnToMenu }
            '3' { Invoke-EnablePageFile; Wait-ReturnToMenu }
            '4' { [void](Invoke-UpdateDrivers -MediaSource $MediaSource -NasPath $NasPath -DownloadUrl $DownloadUrl -LocalMediaPath $LocalMediaPath); Wait-ReturnToMenu }
            '5' { Invoke-SetEthernetMTU; Wait-ReturnToMenu }
            '6' { Invoke-ImmediateReboot }
            '0' { Write-Log 'Saindo do script.' -Level Info; return }
            default {
                Write-Host 'Opcao invalida. Pressione ENTER para tentar novamente.' -ForegroundColor Yellow
                Read-Host | Out-Null
            }
        }
    } while ($true)
}

Assert-Admin

switch ($Action) {
    'Menu'              { Show-ActionMenu }
    'RemoveVMwareTools' { Invoke-RemoveVMwareTools }
    'DisablePageFile'   { Invoke-DisablePageFile }
    'EnablePageFile'    { Invoke-EnablePageFile }
    'UpdateDrivers'     { [void](Invoke-UpdateDrivers -MediaSource $MediaSource -NasPath $NasPath -DownloadUrl $DownloadUrl -LocalMediaPath $LocalMediaPath); exit $script:DriverRc }
    'SetMTU'            { Invoke-SetEthernetMTU }
    'Reboot'            { Invoke-ImmediateReboot }
}
