#!/usr/bin/env bash
# atualizar-app.sh — Atualiza o CÓDIGO da aplicação Streamlit sem mexer em
# venv, banco, anexos, .streamlit/config.toml ou systemd. Pra uso quando você
# quer só "trocar o código" de uma instalação que já existe.
#
# Cenário 1 (recomendado): repositório git já clonado no servidor
#   sudo bash /var/www/setup-novo-servidor/atualizar-app.sh
#
# Cenário 2: arquivos vieram via scp/rsync pra uma pasta temporária
#   sudo SRC=/tmp/gestao-de-projetos-novo \
#        bash /var/www/setup-novo-servidor/atualizar-app.sh
#
# O que o script FAZ:
#   1) Backup do código atual em ${APP_DIR}/backups/codigo.${TS}.tar.gz
#   2) rsync com --delete-after, EXCLUINDO pastas que NÃO devem ser
#      sobrescritas (venv, anexos, backups, .streamlit, *.db legados, etc.)
#   3) Ajusta dono/permissões (www-data:www-data)
#   4) Re-instala libs Python se requirements.txt mudou (detectado via hash)
#   5) Re-roda o cleanup de wheels com AVX2 (NO-OP em CPU moderna; importante
#      em CPU antiga)
#   6) Reinicia o serviço systemd
#
# O que o script NÃO faz (use install.sh pra isso):
#   - Instalar pacotes apt
#   - Criar/migrar Postgres
#   - Criar vhost Apache ou systemd unit (esses estão em outros arquivos)
#   - Mexer em db.env

set -euo pipefail

APP_DIR="${APP_DIR:-/var/www/gestao-de-projetos}"
SETUP_DIR="${SETUP_DIR:-/var/www/setup-novo-servidor}"
SRC="${SRC:-}"
SERVICE_NAME="gestao-de-projetos"

# Pastas/arquivos que NUNCA são sobrescritos pelo rsync. Tudo que estiver
# nessa lista é mantido como está no servidor (cada um por uma razão):
#  - venv/                : pip caro de recriar e nunca está no git
#  - anexos/              : arquivos enviados pelos usuários
#  - backups/             : histórico de backups
#  - .streamlit/          : config.toml gerado pelo install.sh com SERVER_IP
#  - *.db (na raiz)       : SQLite legado que pode estar sendo migrado
#  - .env, db.env         : credenciais locais
#  - __pycache__/         : caches do Python
#  - .git/                : se o app está sob git, não mexer
PRESERVAR=(
    "venv"
    "anexos"
    "backups"
    ".streamlit"
    "*.db"
    ".env"
    "db.env"
    "__pycache__"
    ".git"
)

if [ ! -d "${APP_DIR}" ]; then
    echo "ERRO: ${APP_DIR} não existe. Use install.sh em vez deste script." >&2
    exit 2
fi

# ── Descobre fonte do código novo ───────────────────────────────────────
# Prioridade: SRC explícito > git pull no próprio APP_DIR (se for git repo) >
# Aborta exigindo SRC.
if [ -n "${SRC}" ]; then
    if [ ! -d "${SRC}" ]; then
        echo "ERRO: SRC=${SRC} não é um diretório existente." >&2
        exit 2
    fi
    if [ ! -f "${SRC}/app.py" ]; then
        echo "ERRO: SRC=${SRC} não parece ter o código (sem app.py na raiz)." >&2
        exit 2
    fi
    MODO="rsync"
    echo "==> Modo: rsync de ${SRC} → ${APP_DIR}"
elif [ -d "${APP_DIR}/.git" ]; then
    MODO="git"
    echo "==> Modo: git pull em ${APP_DIR}"
else
    cat >&2 <<HELP
ERRO: não sei de onde puxar o código novo.
  Opção A) Repo git em ${APP_DIR}: rode 'git init && git remote add origin ...' antes.
  Opção B) Passe SRC=/caminho/para/codigo/novo

Exemplo B:
  sudo SRC=/tmp/gestao-de-projetos-novo \\
       bash ${SETUP_DIR}/atualizar-app.sh
HELP
    exit 2
fi

TS="$(date +%Y%m%d-%H%M%S)"

# ── 1/6 Backup do código atual ──────────────────────────────────────────
echo "==>  1/6 Backup do código atual"
mkdir -p "${APP_DIR}/backups"
BACKUP_FILE="${APP_DIR}/backups/codigo.${TS}.tar.gz"

# tar -X com lista de exclusão (idêntica à lista PRESERVAR — não faz sentido
# backup-ar o que não vamos mexer).
TAR_EXCLUDES=()
for p in "${PRESERVAR[@]}"; do
    TAR_EXCLUDES+=(--exclude="${p}")
done
# `tar` precisa rodar do diretório PAI pra que o tar.gz não fique com
# caminho absoluto longo.
( cd "$(dirname "${APP_DIR}")" \
  && tar czf "${BACKUP_FILE}" "${TAR_EXCLUDES[@]}" "$(basename "${APP_DIR}")" ) \
  2>/dev/null || true
echo "     ${BACKUP_FILE}"

# ── 2/6 Puxa código novo ────────────────────────────────────────────────
echo "==>  2/6 Puxando código novo"
if [ "${MODO}" = "git" ]; then
    ( cd "${APP_DIR}" \
      && sudo -u www-data git fetch --all \
      && sudo -u www-data git reset --hard origin/main )
else
    # Monta argumentos de exclusão pro rsync. Sem isso, o rsync sobrescreveria
    # venv/anexos/backups com versões "novas" (vazias) do SRC.
    RSYNC_EXCLUDES=()
    for p in "${PRESERVAR[@]}"; do
        RSYNC_EXCLUDES+=("--exclude=${p}")
    done
    # --delete-after: remove no destino o que NÃO existe na fonte (limpa
    # arquivos órfãos da versão antiga). --delete-after = só apaga depois
    # do transfer ter dado certo (mais seguro que --delete).
    rsync -av --delete-after "${RSYNC_EXCLUDES[@]}" \
          "${SRC%/}/" "${APP_DIR}/"
fi

# ── 3/6 Permissões ──────────────────────────────────────────────────────
echo "==>  3/6 Ajustando dono/permissões"
chown -R www-data:www-data "${APP_DIR}"
chmod -R u+rwX,g+rwX "${APP_DIR}"
find "${APP_DIR}" -type d -exec chmod g+s {} \; 2>/dev/null || true

# ── 4/6 Re-instala libs SE requirements.txt mudou ───────────────────────
echo "==>  4/6 Conferindo requirements.txt"
REQ="${APP_DIR}/requirements.txt"
REQ_HASH_FILE="${APP_DIR}/.streamlit/.requirements.hash"
if [ -f "${REQ}" ]; then
    NEW_HASH="$(sha256sum "${REQ}" | awk '{print $1}')"
    OLD_HASH="$(cat "${REQ_HASH_FILE}" 2>/dev/null || true)"
    if [ "${NEW_HASH}" != "${OLD_HASH}" ]; then
        echo "     requirements.txt mudou — re-instalando libs"
        "${APP_DIR}/venv/bin/pip" install --upgrade -r "${REQ}"
        # Persiste hash pra próxima execução só re-instalar se mudar.
        mkdir -p "${APP_DIR}/.streamlit"
        echo "${NEW_HASH}" > "${REQ_HASH_FILE}"
        chown www-data:www-data "${REQ_HASH_FILE}"
    else
        echo "     requirements.txt inalterado — nada a fazer"
    fi
else
    echo "     [skip] sem requirements.txt na raiz"
fi

# ── 5/6 Cleanup wheels AVX2 (NO-OP em CPU moderna) ──────────────────────
echo "==>  5/6 Cleanup wheels AVX2 (preventivo, NO-OP em CPU moderna)"
for mod in numpy pandas pyarrow scipy bottleneck numexpr; do
    rm -rf "${APP_DIR}/venv/lib/python3."*/site-packages/${mod}* 2>/dev/null || true
done

# ── 6/6 Restart do serviço + health check ───────────────────────────────
echo "==>  6/6 Reiniciando ${SERVICE_NAME}"
systemctl restart "${SERVICE_NAME}"

# Lê porta + URL_PATH do config.toml pra fazer health check
STREAMLIT_PORT="$(grep -E '^port' "${APP_DIR}/.streamlit/config.toml" 2>/dev/null | head -1 | sed -E 's/[^0-9]//g')"
STREAMLIT_PORT="${STREAMLIT_PORT:-8501}"
URL_PATH="$(grep -E '^baseUrlPath' "${APP_DIR}/.streamlit/config.toml" 2>/dev/null | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
URL_PATH="${URL_PATH:-gestao-de-projetos}"

echo "     aguardando Streamlit subir..."
for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 2
    HTTP_CODE="$(curl -fsS -o /dev/null -w "%{http_code}" \
        "http://127.0.0.1:${STREAMLIT_PORT}/${URL_PATH}/_stcore/health" 2>/dev/null || echo 000)"
    if [ "${HTTP_CODE}" = "200" ]; then
        echo "     OK (tentativa ${i})"
        break
    fi
done

echo
echo "--- status systemd ---"
systemctl --no-pager -l status "${SERVICE_NAME}" | head -12 || true

echo
echo "============================================================"
echo "Atualização concluída."
echo "Backup do código anterior: ${BACKUP_FILE}"
echo "Logs:    sudo journalctl -u ${SERVICE_NAME} -n 50 --no-pager"
echo "Se der pau, restaura:"
echo "  sudo systemctl stop ${SERVICE_NAME}"
echo "  sudo tar xzf ${BACKUP_FILE} -C $(dirname "${APP_DIR}")"
echo "  sudo systemctl start ${SERVICE_NAME}"
echo "============================================================"
