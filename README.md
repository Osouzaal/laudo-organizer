# Organizador de Laudos Médicos (PDF)

Automação para extrair dados de laudos em PDF (nome do paciente, empresa e data do exame) e organizá-los automaticamente em uma estrutura de pastas por **Empresa → Mês → Paciente**, disponível em duas linguagens equivalentes: **PowerShell** e **Python**.

Criado para resolver um problema real do dia a dia em um laboratório de radiologia: centenas de laudos em PDF que precisam ser copiados manualmente para pastas de rede organizadas por empresa cliente, mês e paciente.

---

## 🚀 O que o script faz

1. **Lê os PDFs de uma pasta de origem** e extrai o texto usando o `pdftotext` (Poppler).
2. **Identifica automaticamente**, via expressões regulares:
   - Nome do paciente (aceita os rótulos `NOME`, `PACIENTE` ou `COLABORADOR`)
   - Empresa (rótulo `EMPRESA`)
   - Data do exame (aceita `DATA`, `DATA DO RX`, `DATA DO EXAME(S)` ou `DATA DO LAUDO`)
3. **Trata casos de repasse**: quando a empresa aparece como `"NOME ORIGINAL (MSWORK)"` ou `"NOME ORIGINAL (ERGO)"`, o laudo é direcionado direto para a pasta `MSWORK` ou `ERGO` no servidor, ignorando o nome original.
4. **Encontra a pasta da empresa no servidor** usando:
   - Correspondência exata de nome
   - Correspondência "fuzzy" por distância de Levenshtein (tolera diferenças de acentuação, abreviações e pequenos erros de digitação)
5. **Memoriza associações**: quando o nome da empresa no PDF não bate exatamente com nenhuma pasta, o script pergunta ao usuário qual pasta usar (ou se deve criar uma nova) e **salva essa associação** em um arquivo `associacoes-empresas.json`, para nunca mais perguntar de novo para a mesma empresa.
6. **Monta uma prévia completa** antes de mexer em qualquer arquivo:
   - Mostra quantos laudos serão copiados
   - Lista quais pastas de empresa/mês/paciente serão criadas
   - Lista os laudos que serão ignorados e o motivo
7. **Só copia os arquivos após confirmação explícita do usuário** (S/N).
8. **Evita duplicação**: se um arquivo com o mesmo nome já existe na pasta de destino, o laudo é pulado (assume que já foi enviado em uma execução anterior). Em caso de nomes repetidos por outro motivo, adiciona sufixo automático `(2)`, `(3)`, etc.
9. **Gera relatórios** em CSV e TXT ao final de cada execução, com data/hora, listando o que foi copiado, ignorado ou falhou.
10. **Nunca move ou apaga os arquivos originais** — apenas copia.

---

## 📁 Estrutura de pastas gerada

```
PASTA_RAIZ_SERVIDOR/
└── NOME DA EMPRESA/
    └── MES (ex: JANEIRO)/
        └── NOME DO PACIENTE/
            └── laudo.pdf
```

---

## 🧠 Por que existe o sistema de "associações de empresa"

Nem sempre o nome da empresa impresso no PDF bate 100% com o nome da pasta já existente no servidor (abreviações, acentuação diferente, etc). Em vez de pedir confirmação manual toda vez, o script:

- Sugere as 5 pastas mais parecidas (usando similaridade por Levenshtein + bônus se uma é prefixo da outra)
- Deixa o usuário escolher a pasta correta, ou criar uma pasta nova
- Salva essa escolha em `associacoes-empresas.json`, então da próxima vez a associação é aplicada automaticamente

---

## ⚙️ Requisitos

- **Poppler** instalado (para o `pdftotext.exe` / `pdftotext`)
  - Windows: https://github.com/oschwartz10612/poppler-windows
- **Python 3.8+** (apenas para a versão `.py` — usa somente bibliotecas padrão, sem dependências externas)
- **PowerShell 5.1+** (para a versão `.ps1`, já vem no Windows)

---

## 🔧 Configuração

Antes de rodar, edite as variáveis no topo do script (funciona igual nas duas versões):

| Variável | Descrição |
|---|---|
| `PASTA_RAIZ_SERVIDOR` / `$pastaRaizServidor` | Pasta raiz no servidor onde ficam as pastas das empresas |
| `PASTAS_ORIGEM` / `$pastasOrigem` | Lista de pastas onde os PDFs novos chegam |
| `PDFTOTEXT` / `$pdftotext` | Caminho do executável `pdftotext` |

Os arquivos `associacoes-empresas.json` e a pasta `relatorios/` são criados automaticamente ao lado do script, na primeira execução.

---

## ▶️ Como executar

**PowerShell:**
```powershell
.\copiarlaudosservidor_git.ps1
```

**Python:**
```bash
python copiar_laudos_servidor.py
```

---

## 📊 Exemplo de saída (prévia antes de copiar)

```
=========== PREVIA - NENHUM ARQUIVO FOI COPIADO AINDA ===========
Laudos prontos para copiar: 12
Pastas de pacientes que precisarao ser criadas: 3
Laudos ignorados na previa: 1

DESTINOS PREVISTOS:
[PASTA EXISTENTE] [Empresa PDF: EMPRESA XYZ -> Pasta: EMPRESA XYZ LTDA] joao_silva.pdf -> .../EMPRESA XYZ LTDA/JANEIRO/JOAO SILVA

Deseja EXECUTAR agora as copias e criar as pastas listadas? (S/N)
```

---

## ⚠️ Observações

- Os nomes de pastas/arquivos e caminhos usados nos exemplos deste repositório são fictícios — o script deve ser configurado com os caminhos reais do seu ambiente.
- Este projeto foi desenvolvido para automatizar um fluxo de trabalho real de organização de laudos médicos, aplicando conceitos de parsing de texto, matching fuzzy (Levenshtein), manipulação de arquivos e geração de relatórios.

## 🛠️ Tecnologias

- **Python**: regex, subprocess, difflib/Levenshtein manual, json, csv, os/shutil
- **PowerShell**: regex .NET, Get-ChildItem, ConvertTo/From-Json, Export-Csv
- **Poppler** (`pdftotext`) para extração de texto de PDF
