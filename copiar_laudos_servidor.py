# -*- coding: utf-8 -*-
import os
import re
import sys
import json
import csv
import uuid
import shutil
import tempfile
import unicodedata
import subprocess
from datetime import datetime

# =========================== CONFIGURACAO ===========================
PASTA_RAIZ_SERVIDOR = r"Z:\2026 - SEGUNDO SEMESTRE"
PASTAS_ORIGEM = [
    r"C:\Users\iversonrx\Documents\LAB RX\LAUDOS MOVER",
]
PDFTOTEXT = r"C:\poppler\poppler-24.08.0\Library\bin\pdftotext.exe"

# Estes arquivos serao criados na mesma pasta deste script.
PASTA_SCRIPT = os.path.dirname(os.path.abspath(__file__))
ARQUIVO_APELIDOS = os.path.join(PASTA_SCRIPT, "associacoes-empresas.json")
PASTA_RELATORIOS = os.path.join(PASTA_SCRIPT, "relatorios")
# ====================================================================

NOMES_MESES = {
    1: "JANEIRO", 2: "FEVEREIRO", 3: "MARCO", 4: "ABRIL", 5: "MAIO", 6: "JUNHO",
    7: "JULHO", 8: "AGOSTO", 9: "SETEMBRO", 10: "OUTUBRO", 11: "NOVEMBRO", 12: "DEZEMBRO",
}

INVALIDOS = '<>:"/\\|?*' + ''.join(chr(c) for c in range(0, 32))


def limpar_nome_pasta(texto: str) -> str:
    limpo = texto.strip()
    for char in INVALIDOS:
        limpo = limpo.replace(char, "")
    return re.sub(r"\s+", " ", limpo).strip()


def normalizar_chave(texto: str) -> str:
    decomposto = unicodedata.normalize("NFD", texto)
    sem_acentos = "".join(c for c in decomposto if unicodedata.category(c) != "Mn")
    return re.sub(r"[^A-Z0-9]", "", sem_acentos.upper())


def obter_pasta_correspondente(pasta_pai: str, nome_procurado: str):
    exata = os.path.join(pasta_pai, nome_procurado)
    if os.path.isdir(exata):
        return exata
    chave = normalizar_chave(nome_procurado)
    if not os.path.isdir(pasta_pai):
        return None
    encontradas = [
        os.path.join(pasta_pai, nome)
        for nome in os.listdir(pasta_pai)
        if os.path.isdir(os.path.join(pasta_pai, nome)) and normalizar_chave(nome) == chave
    ]
    if len(encontradas) == 1:
        return encontradas[0]
    return None


def obter_distancia_levenshtein(a: str, b: str) -> int:
    if len(a) == 0:
        return len(b)
    if len(b) == 0:
        return len(a)
    matriz = [[0] * (len(b) + 1) for _ in range(len(a) + 1)]
    for i in range(len(a) + 1):
        matriz[i][0] = i
    for j in range(len(b) + 1):
        matriz[0][j] = j
    for i in range(1, len(a) + 1):
        for j in range(1, len(b) + 1):
            custo = 0 if a[i - 1] == b[j - 1] else 1
            delecao = matriz[i - 1][j] + 1
            insercao = matriz[i][j - 1] + 1
            substituicao = matriz[i - 1][j - 1] + custo
            matriz[i][j] = min(delecao, insercao, substituicao)
    return matriz[len(a)][len(b)]


def obter_candidatos_empresa(nome_empresa: str):
    chave_empresa = normalizar_chave(nome_empresa)
    candidatos = []
    if not os.path.isdir(PASTA_RAIZ_SERVIDOR):
        return candidatos
    for nome_pasta in os.listdir(PASTA_RAIZ_SERVIDOR):
        caminho_pasta = os.path.join(PASTA_RAIZ_SERVIDOR, nome_pasta)
        if not os.path.isdir(caminho_pasta):
            continue
        chave_pasta = normalizar_chave(nome_pasta)
        tamanho = max(len(chave_empresa), len(chave_pasta))
        similaridade = 0.0 if tamanho == 0 else 1 - (obter_distancia_levenshtein(chave_empresa, chave_pasta) / tamanho)
        if chave_pasta.startswith(chave_empresa) or chave_empresa.startswith(chave_pasta):
            similaridade += 0.20
        candidatos.append({"nome": nome_pasta, "caminho": caminho_pasta, "pontuacao": similaridade})
    candidatos.sort(key=lambda c: c["pontuacao"], reverse=True)
    return candidatos[:5]


def carregar_apelidos() -> dict:
    if not os.path.isfile(ARQUIVO_APELIDOS):
        return {}
    try:
        with open(ARQUIVO_APELIDOS, "r", encoding="utf-8") as f:
            dados = json.load(f)
        return {k: str(v) for k, v in dados.items()} if dados else {}
    except Exception as e:
        print(f"Nao foi possivel ler o arquivo de apelidos: {e}")
        return {}


def salvar_apelidos(apelidos: dict):
    try:
        ordenados = {k: apelidos[k] for k in sorted(apelidos.keys())}
        with open(ARQUIVO_APELIDOS, "w", encoding="utf-8") as f:
            json.dump(ordenados, f, ensure_ascii=False, indent=2)
    except Exception as e:
        print(f"Nao foi possivel salvar os apelidos: {e}")


def obter_caminho_unico(diretorio: str, nome_arquivo: str) -> str:
    candidato = os.path.join(diretorio, nome_arquivo)
    contador = 2
    base, extensao = os.path.splitext(nome_arquivo)
    while os.path.exists(candidato):
        candidato = os.path.join(diretorio, f"{base} ({contador}){extensao}")
        contador += 1
    return candidato


resultados = []


def adicionar_resultado(status: str, mensagem: str, tarefa: dict = None):
    resultados.append({
        "Arquivo": tarefa["arquivo_path"] if tarefa else "",
        "Paciente": tarefa.get("paciente", "") if tarefa else "",
        "Empresa": tarefa.get("empresa", "") if tarefa else "",
        "Mes": tarefa.get("mes", "") if tarefa else "",
        "Destino": tarefa.get("destino", "") if tarefa else "",
        "Status": status,
        "Mensagem": mensagem,
    })


def pausar_e_sair(codigo: int = 0):
    input("Pressione ENTER para sair...")
    sys.exit(codigo)


def main():
    try:
        if not os.path.isfile(PDFTOTEXT):
            raise FileNotFoundError(f"pdftotext.exe nao encontrado em: {PDFTOTEXT}")
        if not os.path.isdir(PASTA_RAIZ_SERVIDOR):
            raise NotADirectoryError(f"Pasta raiz do servidor nao encontrada: {PASTA_RAIZ_SERVIDOR}")
        os.makedirs(PASTA_RELATORIOS, exist_ok=True)

        laudos = []
        apelidos = carregar_apelidos()

        # Le somente os campos necessarios dos PDFs; esta etapa ainda nao copia nada.
        for origem in PASTAS_ORIGEM:
            if not os.path.isdir(origem):
                print(f"Origem nao encontrada: {origem}")
                continue
            pdfs = [
                os.path.join(origem, f) for f in os.listdir(origem)
                if os.path.isfile(os.path.join(origem, f))
                and (f.lower().endswith(".pdf") or "." not in f)
            ]
            for arquivo_path in pdfs:
                nome_arquivo = os.path.basename(arquivo_path)
                txt_path = os.path.join(tempfile.gettempdir(), f"{uuid.uuid4()}.txt")
                try:
                    subprocess.run([PDFTOTEXT, "-layout", arquivo_path, txt_path], check=False)
                    with open(txt_path, "r", encoding="utf-8", errors="ignore") as f:
                        conteudo = f.read()

                    # Aceita modelos que chamam a pessoa de NOME, PACIENTE ou COLABORADOR.
                    match_nome = re.search(
                        r"^\s*(?:NOME|PACIENTE|COLABORADOR)\s*:\s*(.+?)(?=\s+(?:CPF|RG|MATR[IÍ]CULA|DATA\s+DE\s+NASCIMENTO)\s*:|\s*$)",
                        conteudo, re.IGNORECASE | re.MULTILINE
                    )
                    match_empresa = re.search(r"^\s*EMPRESA:\s*(.+?)\s*$", conteudo, re.IGNORECASE | re.MULTILINE)
                    # Aceita DATA, DATA DO RX, DATA DO EXAME(S) e DATA DO LAUDO.
                    match_data = re.search(
                        r"^\s*DATA(?:\s+DO\s+(?:RX|EXAMES?|LAUDO))?\s*:\s*(\d{1,2})[./-](\d{1,2})[./-](\d{2,4})\b",
                        conteudo, re.IGNORECASE | re.MULTILINE
                    )

                    if not match_nome or not match_empresa or not match_data:
                        adicionar_resultado(
                            "Ignorado",
                            "Pessoa (NOME/PACIENTE/COLABORADOR), EMPRESA ou DATA nao encontrado no PDF.",
                            {"arquivo_path": arquivo_path}
                        )
                        continue

                    mes_numero = int(match_data.group(2))
                    if mes_numero not in NOMES_MESES:
                        raise ValueError("Mes invalido no campo DATA.")

                    texto_empresa = limpar_nome_pasta(match_empresa.group(1))
                    # Empresas repassadas pela MSWORK ou pela ERGO vem como "NOME ORIGINAL (MSWORK)" ou "(ERGO)".
                    # Nesses casos ignora o nome original e envia direto para a pasta MSWORK ou ERGO no servidor.
                    match_repasse = re.search(r"(?i)\(\s*(MSWORK|ERGO)\s*\)", texto_empresa)
                    eh_repasse = match_repasse is not None
                    nome_para_pasta = match_repasse.group(1).upper() if eh_repasse else texto_empresa

                    laudos.append({
                        "arquivo_path": arquivo_path,
                        "arquivo_nome": nome_arquivo,
                        "paciente": limpar_nome_pasta(match_nome.group(1)),
                        "empresa": texto_empresa,
                        "nome_para_pasta": nome_para_pasta,
                        "eh_repasse": eh_repasse,
                        "mes": NOMES_MESES[mes_numero],
                    })
                except Exception as e:
                    adicionar_resultado("Ignorado", f"Erro na leitura do PDF: {e}", {"arquivo_path": arquivo_path})
                finally:
                    if os.path.exists(txt_path):
                        try:
                            os.remove(txt_path)
                        except OSError:
                            pass

        # Resolve cada empresa uma unica vez. Para abreviacoes, exibe sugestoes e exige sua escolha.
        # Laudos repassados por MSWORK ou ERGO usam nome_para_pasta = "MSWORK"/"ERGO", entao caem todos na mesma pasta.
        pastas_empresa = {}
        empresas_novas = {}
        nomes_para_pasta_unicos = sorted(set(l["nome_para_pasta"] for l in laudos))

        for nome_para_pasta in nomes_para_pasta_unicos:
            chave = normalizar_chave(nome_para_pasta)
            pasta = obter_pasta_correspondente(PASTA_RAIZ_SERVIDOR, nome_para_pasta)
            if pasta is None and chave in apelidos:
                pasta = obter_pasta_correspondente(PASTA_RAIZ_SERVIDOR, apelidos[chave])
            if pasta is not None:
                pastas_empresa[chave] = {"nome": os.path.basename(pasta), "caminho": pasta}
                continue

            candidatos = obter_candidatos_empresa(nome_para_pasta)
            opcao_criar = len(candidatos) + 1
            print()
            print(f"Empresa do PDF nao localizada: '{nome_para_pasta}'")
            for i, cand in enumerate(candidatos):
                print(f"[{i + 1}] {cand['nome']}")
            print(f"[{opcao_criar}] CRIAR PASTA NOVA para esta empresa")
            escolha = input(f"Digite o numero da empresa correta, {opcao_criar} para criar uma pasta nova, ou 0 para ignorar estes laudos: ")

            indice = None
            try:
                indice = int(escolha)
            except ValueError:
                indice = None

            if indice is not None and 1 <= indice <= len(candidatos):
                cand = candidatos[indice - 1]
                pastas_empresa[chave] = {"nome": cand["nome"], "caminho": cand["caminho"]}
                apelidos[chave] = cand["nome"]
                print(f"Associacao salva: '{nome_para_pasta}' -> '{cand['nome']}'")
            elif indice == opcao_criar:
                nome_sugerido = limpar_nome_pasta(nome_para_pasta)
                nome_digitado = input(f"Nome da nova pasta de empresa (ENTER para usar '{nome_sugerido}'): ")
                nome_confirmado = nome_sugerido if not nome_digitado.strip() else limpar_nome_pasta(nome_digitado)
                caminho_nova_empresa = os.path.join(PASTA_RAIZ_SERVIDOR, nome_confirmado)
                print(f"Sera criada a pasta de empresa: {caminho_nova_empresa}")
                confirma_criacao = input("Confirma a criacao desta pasta de empresa (e das pastas de mes/paciente dentro dela)? (S/N): ")
                if re.match(r"^(?i:s|sim|y|yes)$", confirma_criacao.strip()):
                    # Objeto "pendente": ainda nao existe no disco, so sera criado apos a confirmacao final de execucao.
                    pastas_empresa[chave] = {"nome": nome_confirmado, "caminho": caminho_nova_empresa}
                    empresas_novas[chave] = True
                    apelidos[chave] = nome_confirmado
                    print(f"Pasta nova marcada para criacao: '{nome_para_pasta}' -> '{nome_confirmado}'")
                else:
                    print(f"Criacao cancelada. Laudos da empresa '{nome_para_pasta}' serao ignorados.")
            else:
                print(f"Laudos da empresa '{nome_para_pasta}' serao ignorados.")

        salvar_apelidos(apelidos)

        # Monta a previa: empresa -> mes -> paciente. Ainda nao cria nem copia nada.
        tarefas = []
        for laudo in laudos:
            chave_empresa = normalizar_chave(laudo["nome_para_pasta"])
            if chave_empresa not in pastas_empresa:
                adicionar_resultado("Ignorado", "Empresa nao associada.", {
                    "arquivo_path": laudo["arquivo_path"], "paciente": laudo["paciente"],
                    "empresa": laudo["empresa"], "mes": laudo["mes"], "destino": ""
                })
                continue

            pasta_empresa_obj = pastas_empresa[chave_empresa]
            # A pasta do mes pode ser criada automaticamente sempre que a pasta da empresa ja existir
            # (ou for MSWORK/ERGO/empresa nova). A criacao continua dependendo da confirmacao final (S/N).
            if os.path.isdir(pasta_empresa_obj["caminho"]):
                pasta_mes = obter_pasta_correspondente(pasta_empresa_obj["caminho"], laudo["mes"])
            else:
                pasta_mes = None

            caminho_mes = pasta_mes if pasta_mes else os.path.join(pasta_empresa_obj["caminho"], laudo["mes"])

            pasta_paciente = obter_pasta_correspondente(caminho_mes, laudo["paciente"]) if os.path.isdir(caminho_mes) else None
            destino = pasta_paciente if pasta_paciente else os.path.join(caminho_mes, laudo["paciente"])

            # Se ja existe um arquivo com o mesmo nome na pasta de destino, assume que ja foi enviado
            # em uma execucao anterior e pula, em vez de copiar de novo ou duplicar com sufixo "(2)".
            caminho_exato_destino = os.path.join(destino, laudo["arquivo_nome"])
            if os.path.isfile(caminho_exato_destino):
                adicionar_resultado("Ignorado", "Arquivo ja existe no destino (provavelmente enviado em execucao anterior).", {
                    "arquivo_path": laudo["arquivo_path"], "paciente": laudo["paciente"],
                    "empresa": laudo["empresa"], "mes": laudo["mes"], "destino": destino
                })
                continue

            tarefas.append({
                "arquivo_path": laudo["arquivo_path"],
                "arquivo_nome": laudo["arquivo_nome"],
                "paciente": laudo["paciente"],
                "empresa": laudo["empresa"],
                "pasta_empresa": pasta_empresa_obj["nome"],
                "mes": laudo["mes"],
                "destino": destino,
                "criar_pasta": pasta_paciente is None,
                "empresa_nova": chave_empresa in empresas_novas,
            })

        novas_empresas_nomes = sorted(set(pastas_empresa[chave]["nome"] for chave in empresas_novas.keys()))
        novas_pastas = sorted(set(t["destino"] for t in tarefas if t["criar_pasta"]))

        print()
        print("=========== PREVIA - NENHUM ARQUIVO FOI COPIADO AINDA ===========")
        print(f"Laudos prontos para copiar: {len(tarefas)}")
        if novas_empresas_nomes:
            print(f"Empresas novas que serao criadas: {len(novas_empresas_nomes)}")
            for nome in novas_empresas_nomes:
                print(f"- {nome}")
        print(f"Pastas de pacientes que precisarao ser criadas: {len(novas_pastas)}")
        for pasta in novas_pastas:
            print(f"- {pasta}")
        print(f"Laudos ignorados na previa: {len(resultados)}")
        print()
        print("DESTINOS PREVISTOS:")
        for tarefa in sorted(tarefas, key=lambda t: (t["destino"], t["arquivo_nome"])):
            tipo_pasta = "[CRIAR PASTA]" if tarefa["criar_pasta"] else "[PASTA EXISTENTE]"
            marca_empresa_nova = " [EMPRESA NOVA]" if tarefa["empresa_nova"] else ""
            print(f"{tipo_pasta}{marca_empresa_nova} [Empresa PDF: {tarefa['empresa']} -> Pasta: {tarefa['pasta_empresa']}] {tarefa['arquivo_nome']} -> {tarefa['destino']}")

        confirmacao = input("Deseja EXECUTAR agora as copias e criar as pastas listadas? (S/N): ")
        if re.match(r"^(?i:s|sim|y|yes)$", confirmacao.strip()):
            for pasta_nova in novas_pastas:
                os.makedirs(pasta_nova, exist_ok=True)
            for tarefa in tarefas:
                try:
                    destino_arquivo = obter_caminho_unico(tarefa["destino"], tarefa["arquivo_nome"])
                    shutil.copy2(tarefa["arquivo_path"], destino_arquivo)
                    adicionar_resultado("Copiado", "Arquivo copiado com sucesso.", tarefa)
                    print(f"Copiado: {tarefa['arquivo_nome']} -> {tarefa['destino']}")
                except Exception as e:
                    adicionar_resultado("Falha", f"Erro ao copiar: {e}", tarefa)
                    print(f"Falha ao copiar '{tarefa['arquivo_nome']}': {e}")
        else:
            for tarefa in tarefas:
                adicionar_resultado("Cancelado", "Execucao cancelada apos a previa.", tarefa)

        sufixo = datetime.now().strftime("%Y%m%d-%H%M%S")
        csv_path = os.path.join(PASTA_RELATORIOS, f"relatorio-envio-laudos-{sufixo}.csv")
        txt_path_relatorio = os.path.join(PASTA_RELATORIOS, f"relatorio-envio-laudos-{sufixo}.txt")

        campos = ["Arquivo", "Paciente", "Empresa", "Mes", "Destino", "Status", "Mensagem"]
        with open(csv_path, "w", newline="", encoding="utf-8-sig") as f:
            writer = csv.DictWriter(f, fieldnames=campos)
            writer.writeheader()
            writer.writerows(resultados)

        copiados = sum(1 for r in resultados if r["Status"] == "Copiado")
        ignorados = sum(1 for r in resultados if r["Status"] == "Ignorado")
        falhas = sum(1 for r in resultados if r["Status"] == "Falha")

        linhas = [
            f"RELATORIO DE ENVIO DE LAUDOS - {datetime.now().strftime('%d/%m/%Y %H:%M')}",
            "",
            f"Copiados: {copiados} | Ignorados: {ignorados} | Falhas: {falhas}",
            "",
        ]
        for r in resultados:
            linhas.append(
                f"[{r['Status']}] {r['Arquivo']} | Paciente: {r['Paciente']} | Empresa: {r['Empresa']} | "
                f"Mes: {r['Mes']} | Destino: {r['Destino']} | {r['Mensagem']}"
            )

        with open(txt_path_relatorio, "w", encoding="utf-8") as f:
            f.write("\n".join(linhas))

        print()
        print("Relatorios criados:")
        print(csv_path)
        print(txt_path_relatorio)
        print("Os arquivos de origem nao foram movidos nem alterados; apenas sao copiados apos sua confirmacao.")
        pausar_e_sair(0)

    except Exception as e:
        print(f"SCRIPT FALHOU: {e}")
        pausar_e_sair(1)


if __name__ == "__main__":
    main()
