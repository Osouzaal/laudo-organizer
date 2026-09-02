[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
try { chcp 65001 | Out-Null } catch {}

# =========================== CONFIGURACAO ===========================
$pastaRaizServidor = "Z:\2026 - SEGUNDO SEMESTRE"
$pastasOrigem = @(
    "C:\Users\iversonrx\Documents\LAB RX\LAUDOS MOVER"
)
$pdftotext = "C:\poppler\poppler-24.08.0\Library\bin\pdftotext.exe"

# Estes arquivos serao criados na mesma pasta deste script.
$arquivoApelidos = Join-Path $PSScriptRoot "associacoes-empresas.json"
$pastaRelatorios = Join-Path $PSScriptRoot "relatorios"
# ====================================================================

$nomesMeses = @{
    1 = "JANEIRO"; 2 = "FEVEREIRO"; 3 = "MARCO"; 4 = "ABRIL"; 5 = "MAIO"; 6 = "JUNHO"
    7 = "JULHO"; 8 = "AGOSTO"; 9 = "SETEMBRO"; 10 = "OUTUBRO"; 11 = "NOVEMBRO"; 12 = "DEZEMBRO"
}

function Limpar-NomePasta {
    param([Parameter(Mandatory = $true)][string]$Texto)
    $limpo = $Texto.Trim()
    foreach ($char in [System.IO.Path]::GetInvalidFileNameChars()) { $limpo = $limpo.Replace([string]$char, "") }
    return ($limpo -replace "\s+", " ").Trim()
}

function Normalizar-Chave {
    param([Parameter(Mandatory = $true)][string]$Texto)
    $decomposto = $Texto.Normalize([Text.NormalizationForm]::FormD)
    $semAcentos = -join ($decomposto.ToCharArray() | Where-Object {
        [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne [Globalization.UnicodeCategory]::NonSpacingMark
    })
    return ($semAcentos.ToUpperInvariant() -replace "[^A-Z0-9]", "")
}

function Obter-PastaCorrespondente {
    param([Parameter(Mandatory = $true)][string]$PastaPai, [Parameter(Mandatory = $true)][string]$NomeProcurado)
    $exata = Join-Path $PastaPai $NomeProcurado
    if (Test-Path -LiteralPath $exata -PathType Container) { return Get-Item -LiteralPath $exata }
    $chave = Normalizar-Chave $NomeProcurado
    $encontradas = @(Get-ChildItem -LiteralPath $PastaPai -Directory | Where-Object { (Normalizar-Chave $_.Name) -eq $chave })
    if ($encontradas.Count -eq 1) { return $encontradas[0] }
    return $null
}

function Obter-DistanciaLevenshtein {
    param([Parameter(Mandatory = $true)][string]$A, [Parameter(Mandatory = $true)][string]$B)
    if ($A.Length -eq 0) { return $B.Length }
    if ($B.Length -eq 0) { return $A.Length }
    $matriz = New-Object 'int[,]' ($A.Length + 1), ($B.Length + 1)
    for ($i = 0; $i -le $A.Length; $i++) { $matriz[$i, 0] = $i }
    for ($j = 0; $j -le $B.Length; $j++) { $matriz[0, $j] = $j }
    for ($i = 1; $i -le $A.Length; $i++) {
        for ($j = 1; $j -le $B.Length; $j++) {
            $custo = if ($A[$i - 1] -eq $B[$j - 1]) { 0 } else { 1 }
            $delecao = $matriz[($i - 1), $j] + 1
            $insercao = $matriz[$i, ($j - 1)] + 1
            $substituicao = $matriz[($i - 1), ($j - 1)] + $custo
            $matriz[$i, $j] = [Math]::Min($delecao, [Math]::Min($insercao, $substituicao))
        }
    }
    return $matriz[$A.Length, $B.Length]
}

function Obter-CandidatosEmpresa {
    param([Parameter(Mandatory = $true)][string]$NomeEmpresa)
    $chaveEmpresa = Normalizar-Chave $NomeEmpresa
    $candidatos = foreach ($pasta in Get-ChildItem -LiteralPath $pastaRaizServidor -Directory) {
        $chavePasta = Normalizar-Chave $pasta.Name
        $tamanho = [Math]::Max($chaveEmpresa.Length, $chavePasta.Length)
        $similaridade = if ($tamanho -eq 0) { 0 } else { 1 - ((Obter-DistanciaLevenshtein $chaveEmpresa $chavePasta) / $tamanho) }
        if ($chavePasta.StartsWith($chaveEmpresa) -or $chaveEmpresa.StartsWith($chavePasta)) { $similaridade += 0.20 }
        [PSCustomObject]@{ Pasta = $pasta; Pontuacao = $similaridade }
    }
    return @($candidatos | Sort-Object Pontuacao -Descending | Select-Object -First 5)
}

function Carregar-Apelidos {
    $apelidos = @{}
    if (-not (Test-Path -LiteralPath $arquivoApelidos -PathType Leaf)) { return $apelidos }
    try {
        $dados = Get-Content -LiteralPath $arquivoApelidos -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $dados) {
            foreach ($propriedade in $dados.PSObject.Properties) { $apelidos[$propriedade.Name] = [string]$propriedade.Value }
        }
    }
    catch { Write-Host "Nao foi possivel ler o arquivo de apelidos: $_" -ForegroundColor Yellow }
    return $apelidos
}

function Salvar-Apelidos {
    param([Parameter(Mandatory = $true)][hashtable]$Apelidos)
    try {
        $ordenados = [ordered]@{}
        foreach ($chave in ($Apelidos.Keys | Sort-Object)) { $ordenados[$chave] = $Apelidos[$chave] }
        $ordenados | ConvertTo-Json | Set-Content -LiteralPath $arquivoApelidos -Encoding UTF8
    }
    catch { Write-Host "Nao foi possivel salvar os apelidos: $_" -ForegroundColor Yellow }
}

function Obter-CaminhoUnico {
    param([Parameter(Mandatory = $true)][string]$Diretorio, [Parameter(Mandatory = $true)][string]$NomeArquivo)
    $candidato = Join-Path $Diretorio $NomeArquivo
    $contador = 2; $base = [IO.Path]::GetFileNameWithoutExtension($NomeArquivo); $extensao = [IO.Path]::GetExtension($NomeArquivo)
    while (Test-Path -LiteralPath $candidato) { $candidato = Join-Path $Diretorio "$base ($contador)$extensao"; $contador++ }
    return $candidato
}

function Adicionar-Resultado {
    param([string]$Status, [string]$Mensagem, $Tarefa)
    $resultados.Add([PSCustomObject]@{
        Arquivo = if ($null -ne $Tarefa) { $Tarefa.Arquivo.FullName } else { "" }
        Paciente = if ($null -ne $Tarefa) { $Tarefa.Paciente } else { "" }
        Empresa = if ($null -ne $Tarefa) { $Tarefa.Empresa } else { "" }
        Mes = if ($null -ne $Tarefa) { $Tarefa.Mes } else { "" }
        Destino = if ($null -ne $Tarefa) { $Tarefa.Destino } else { "" }
        Status = $Status; Mensagem = $Mensagem
    })
}

try {
    if (-not (Test-Path -LiteralPath $pdftotext -PathType Leaf)) { throw "pdftotext.exe nao encontrado em: $pdftotext" }
    if (-not (Test-Path -LiteralPath $pastaRaizServidor -PathType Container)) { throw "Pasta raiz do servidor nao encontrada: $pastaRaizServidor" }
    New-Item -ItemType Directory -Path $pastaRelatorios -Force | Out-Null

    $resultados = [System.Collections.Generic.List[object]]::new()
    $laudos = [System.Collections.Generic.List[object]]::new()
    $apelidos = Carregar-Apelidos

    # Le somente os campos necessarios dos PDFs; esta etapa ainda nao copia nada.
    foreach ($origem in $pastasOrigem) {
        if (-not (Test-Path -LiteralPath $origem -PathType Container)) { Write-Host "Origem nao encontrada: $origem" -ForegroundColor Yellow; continue }
        $pdfs = Get-ChildItem -LiteralPath $origem -File | Where-Object { $_.Extension -ieq ".pdf" -or [string]::IsNullOrWhiteSpace($_.Extension) }
        foreach ($arquivo in $pdfs) {
            $txt = Join-Path $env:TEMP "$([Guid]::NewGuid()).txt"
            try {
                & $pdftotext -layout $arquivo.FullName $txt
                $conteudo = Get-Content -LiteralPath $txt -Raw -Encoding UTF8
                # Aceita modelos que chamam a pessoa de NOME, PACIENTE ou COLABORADOR.
                $nome = [regex]::Match($conteudo, "(?im)^\s*(?:NOME|PACIENTE|COLABORADOR)\s*:\s*(.+?)(?=\s+(?:CPF|RG|MATR[IÍ]CULA|DATA\s+DE\s+NASCIMENTO)\s*:|\s*$)")
                $empresa = [regex]::Match($conteudo, "(?im)^\s*EMPRESA:\s*(.+?)\s*$")
                # Aceita DATA, DATA DO RX, DATA DO EXAME(S) e DATA DO LAUDO.
                $data = [regex]::Match($conteudo, "(?im)^\s*DATA(?:\s+DO\s+(?:RX|EXAMES?|LAUDO))?\s*:\s*(\d{1,2})[./-](\d{1,2})[./-](\d{2,4})\b")
                if (-not $nome.Success -or -not $empresa.Success -or -not $data.Success) {
                    Adicionar-Resultado "Ignorado" "Pessoa (NOME/PACIENTE/COLABORADOR), EMPRESA ou DATA nao encontrado no PDF." ([PSCustomObject]@{ Arquivo=$arquivo; Paciente=""; Empresa=""; Mes=""; Destino="" })
                    continue
                }
                $mesNumero = [int]$data.Groups[2].Value
                if (-not $nomesMeses.ContainsKey($mesNumero)) { throw "Mes invalido no campo DATA." }
                $textoEmpresa = Limpar-NomePasta $empresa.Groups[1].Value
                # Empresas repassadas pela MSWORK ou pela ERGO vem como "NOME ORIGINAL (MSWORK)" ou "NOME ORIGINAL (ERGO)".
                # Nesses casos ignora o nome original e envia direto para a pasta MSWORK ou ERGO no servidor.
                $matchRepasse = [regex]::Match($textoEmpresa, "(?i)\(\s*(MSWORK|ERGO)\s*\)")
                $ehRepasse = $matchRepasse.Success
                $nomeParaPasta = if ($ehRepasse) { $matchRepasse.Groups[1].Value.ToUpperInvariant() } else { $textoEmpresa }
                $laudos.Add([PSCustomObject]@{ Arquivo=$arquivo; Paciente=(Limpar-NomePasta $nome.Groups[1].Value); Empresa=$textoEmpresa; NomeParaPasta=$nomeParaPasta; EhRepasse=$ehRepasse; Mes=$nomesMeses[$mesNumero] })
            }
            catch { Adicionar-Resultado "Ignorado" "Erro na leitura do PDF: $_" ([PSCustomObject]@{ Arquivo=$arquivo; Paciente=""; Empresa=""; Mes=""; Destino="" }) }
            finally { Remove-Item -LiteralPath $txt -ErrorAction SilentlyContinue }
        }
    }

    # Resolve cada empresa uma unica vez. Para abreviacoes, exibe sugestoes e exige sua escolha.
    # Laudos repassados por MSWORK ou ERGO usam NomeParaPasta = "MSWORK"/"ERGO", entao caem todos na mesma pasta.
    $pastasEmpresa = @{}
    $empresasNovas = @{}
    foreach ($nomeParaPasta in ($laudos.NomeParaPasta | Sort-Object -Unique)) {
        $chave = Normalizar-Chave $nomeParaPasta
        $pasta = $null
        # O nome exato (ou "MSWORK"/"ERGO") tem prioridade sobre qualquer apelido salvo.
        $pasta = Obter-PastaCorrespondente $pastaRaizServidor $nomeParaPasta
        if ($null -eq $pasta -and $apelidos.ContainsKey($chave)) { $pasta = Obter-PastaCorrespondente $pastaRaizServidor $apelidos[$chave] }
        if ($null -ne $pasta) { $pastasEmpresa[$chave] = $pasta; continue }

        $candidatos = Obter-CandidatosEmpresa $nomeParaPasta
        $opcaoCriar = $candidatos.Count + 1
        Write-Host ""; Write-Host "Empresa do PDF nao localizada: '$nomeParaPasta'" -ForegroundColor Yellow
        for ($i = 0; $i -lt $candidatos.Count; $i++) { Write-Host "[$($i + 1)] $($candidatos[$i].Pasta.Name)" }
        Write-Host "[$opcaoCriar] CRIAR PASTA NOVA para esta empresa"
        $escolha = Read-Host "Digite o numero da empresa correta, $opcaoCriar para criar uma pasta nova, ou 0 para ignorar estes laudos"
        $indice = 0
        if ([int]::TryParse($escolha, [ref]$indice) -and $indice -ge 1 -and $indice -le $candidatos.Count) {
            $pasta = $candidatos[$indice - 1].Pasta
            $pastasEmpresa[$chave] = $pasta
            $apelidos[$chave] = $pasta.Name
            Write-Host "Associacao salva: '$nomeParaPasta' -> '$($pasta.Name)'" -ForegroundColor Green
        }
        elseif ($indice -eq $opcaoCriar) {
            $nomeSugerido = Limpar-NomePasta $nomeParaPasta
            $nomeDigitado = Read-Host "Nome da nova pasta de empresa (ENTER para usar '$nomeSugerido')"
            $nomeConfirmado = if ([string]::IsNullOrWhiteSpace($nomeDigitado)) { $nomeSugerido } else { Limpar-NomePasta $nomeDigitado }
            $caminhoNovaEmpresa = Join-Path $pastaRaizServidor $nomeConfirmado
            Write-Host "Sera criada a pasta de empresa: $caminhoNovaEmpresa" -ForegroundColor Yellow
            $confirmaCriacao = Read-Host "Confirma a criacao desta pasta de empresa (e das pastas de mes/paciente dentro dela)? (S/N)"
            if ($confirmaCriacao -match "^(?i:s|sim|y|yes)$") {
                # Objeto "pendente": ainda nao existe no disco, so sera criado apos a confirmacao final de execucao.
                $pastaPendente = [PSCustomObject]@{ FullName = $caminhoNovaEmpresa; Name = $nomeConfirmado }
                $pastasEmpresa[$chave] = $pastaPendente
                $empresasNovas[$chave] = $true
                $apelidos[$chave] = $nomeConfirmado
                Write-Host "Pasta nova marcada para criacao: '$nomeParaPasta' -> '$nomeConfirmado'" -ForegroundColor Green
            }
            else { Write-Host "Criacao cancelada. Laudos da empresa '$nomeParaPasta' serao ignorados." -ForegroundColor Yellow }
        }
        else { Write-Host "Laudos da empresa '$nomeParaPasta' serao ignorados." -ForegroundColor Yellow }
    }
    Salvar-Apelidos $apelidos

    # Monta a previa: empresa -> mes -> paciente. Ainda nao cria nem copia nada.
    $tarefas = [System.Collections.Generic.List[object]]::new()
    foreach ($laudo in $laudos) {
        $chaveEmpresa = Normalizar-Chave $laudo.NomeParaPasta
        if (-not $pastasEmpresa.ContainsKey($chaveEmpresa)) { Adicionar-Resultado "Ignorado" "Empresa nao associada." $laudo; continue }
        $pastaEmpresaObj = $pastasEmpresa[$chaveEmpresa]
        # A pasta do mes pode ser criada automaticamente sempre que a pasta da empresa ja existir
        # (ou for MSWORK/ERGO/empresa nova). A criacao continua dependendo da confirmacao final (S/N).
        $permiteCriarMes = $true
        $pastaMes = if (Test-Path -LiteralPath $pastaEmpresaObj.FullName -PathType Container) { Obter-PastaCorrespondente $pastaEmpresaObj.FullName $laudo.Mes } else { $null }
        if ($null -eq $pastaMes) {
            if ($permiteCriarMes) {
                $caminhoMes = Join-Path $pastaEmpresaObj.FullName $laudo.Mes
            }
            else {
                Adicionar-Resultado "Ignorado" "Pasta do mes '$($laudo.Mes)' nao encontrada na empresa." $laudo
                continue
            }
        }
        else { $caminhoMes = $pastaMes.FullName }
        $pastaPaciente = if (Test-Path -LiteralPath $caminhoMes -PathType Container) { Obter-PastaCorrespondente $caminhoMes $laudo.Paciente } else { $null }
        $destino = if ($null -ne $pastaPaciente) { $pastaPaciente.FullName } else { Join-Path $caminhoMes $laudo.Paciente }

        # Se ja existe um arquivo com o mesmo nome na pasta de destino, assume que ja foi enviado
        # em uma execucao anterior e pula, em vez de copiar de novo ou duplicar com sufixo "(2)".
        $caminhoExatoDestino = Join-Path $destino $laudo.Arquivo.Name
        if (Test-Path -LiteralPath $caminhoExatoDestino -PathType Leaf) {
            Adicionar-Resultado "Ignorado" "Arquivo ja existe no destino (provavelmente enviado em execucao anterior)." $laudo
            continue
        }

        $tarefas.Add([PSCustomObject]@{ Arquivo=$laudo.Arquivo; Paciente=$laudo.Paciente; Empresa=$laudo.Empresa; PastaEmpresa=$pastaEmpresaObj.Name; Mes=$laudo.Mes; Destino=$destino; CriarPasta=($null -eq $pastaPaciente); EmpresaNova=$empresasNovas.ContainsKey($chaveEmpresa) })
    }

    $novasEmpresasNomes = @($empresasNovas.Keys | ForEach-Object { $pastasEmpresa[$_].Name } | Sort-Object -Unique)

    $novasPastas = @($tarefas | Where-Object CriarPasta | Select-Object -ExpandProperty Destino -Unique)
    Write-Host ""; Write-Host "=========== PREVIA - NENHUM ARQUIVO FOI COPIADO AINDA ===========" -ForegroundColor Cyan
    Write-Host "Laudos prontos para copiar: $($tarefas.Count)"
    if ($novasEmpresasNomes.Count -gt 0) {
        Write-Host "Empresas novas que serao criadas: $($novasEmpresasNomes.Count)" -ForegroundColor Yellow
        $novasEmpresasNomes | Sort-Object | ForEach-Object { Write-Host "- $_" }
    }
    Write-Host "Pastas de pacientes que precisarao ser criadas: $($novasPastas.Count)"
    if ($novasPastas.Count -gt 0) { $novasPastas | Sort-Object | ForEach-Object { Write-Host "- $_" } }
    Write-Host "Laudos ignorados na previa: $($resultados.Count)"
    Write-Host ""
    Write-Host "DESTINOS PREVISTOS:" -ForegroundColor Cyan
    foreach ($tarefa in ($tarefas | Sort-Object Destino, @{ Expression = { $_.Arquivo.Name } })) {
        $tipoPasta = if ($tarefa.CriarPasta) { "[CRIAR PASTA]" } else { "[PASTA EXISTENTE]" }
        $marcaEmpresaNova = if ($tarefa.EmpresaNova) { " [EMPRESA NOVA]" } else { "" }
        Write-Host "$tipoPasta$marcaEmpresaNova [Empresa PDF: $($tarefa.Empresa) -> Pasta: $($tarefa.PastaEmpresa)] $($tarefa.Arquivo.Name) -> $($tarefa.Destino)"
    }

    $confirmacao = Read-Host "Deseja EXECUTAR agora as copias e criar as pastas listadas? (S/N)"
    if ($confirmacao -match "^(?i:s|sim|y|yes)$") {
        foreach ($pastaNova in $novasPastas) { New-Item -ItemType Directory -Path $pastaNova -Force | Out-Null }
        foreach ($tarefa in $tarefas) {
            try {
                $destinoArquivo = Obter-CaminhoUnico $tarefa.Destino $tarefa.Arquivo.Name
                Copy-Item -LiteralPath $tarefa.Arquivo.FullName -Destination $destinoArquivo
                Adicionar-Resultado "Copiado" "Arquivo copiado com sucesso." $tarefa
                Write-Host "Copiado: $($tarefa.Arquivo.Name) -> $($tarefa.Destino)" -ForegroundColor Green
            }
            catch { Adicionar-Resultado "Falha" "Erro ao copiar: $_" $tarefa; Write-Host "Falha ao copiar '$($tarefa.Arquivo.Name)': $_" -ForegroundColor Yellow }
        }
    }
    else { foreach ($tarefa in $tarefas) { Adicionar-Resultado "Cancelado" "Execucao cancelada apos a previa." $tarefa } }

    $sufixo = Get-Date -Format "yyyyMMdd-HHmmss"
    $csv = Join-Path $pastaRelatorios "relatorio-envio-laudos-$sufixo.csv"
    $txt = Join-Path $pastaRelatorios "relatorio-envio-laudos-$sufixo.txt"
    $resultados | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
    $linhas = @("RELATORIO DE ENVIO DE LAUDOS - $(Get-Date -Format 'dd/MM/yyyy HH:mm')", "")
    $linhas += "Copiados: $(@($resultados | Where-Object Status -eq 'Copiado').Count) | Ignorados: $(@($resultados | Where-Object Status -eq 'Ignorado').Count) | Falhas: $(@($resultados | Where-Object Status -eq 'Falha').Count)"
    $linhas += ""; $linhas += ($resultados | Format-Table -AutoSize | Out-String)
    $linhas | Set-Content -LiteralPath $txt -Encoding UTF8
    Write-Host ""; Write-Host "Relatorios criados:" -ForegroundColor Green; Write-Host $csv; Write-Host $txt
    Write-Host "Os arquivos de origem nao foram movidos nem alterados; apenas sao copiados apos sua confirmacao."
    Write-Host "Pressione ENTER para sair..."; [void][Console]::ReadLine()
}
catch {
    Write-Host "SCRIPT FALHOU: $_" -ForegroundColor Red
    Write-Host "Pressione ENTER para sair..."; [void][Console]::ReadLine()
}
