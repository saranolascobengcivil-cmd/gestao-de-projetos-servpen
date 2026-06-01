#!/usr/bin/env bash
# run-local.sh — Sobe ambiente de DEV local: Postgres (Docker) + Streamlit.
#
# Pré-requisitos:
#   - venv criado em ./venv (rode setup-local.sh primeiro se não tiver)
#   - docker instalado e rodando
#   - db.env.local existe (já vem comitado)
#
# Uso:
#   ./run-local.sh                 # sobe Postgres + Streamlit
#   ./run-local.sh --no-docker     # NÃO sobe Postgres (já tá rodando)
#   ./run-local.sh --port=8502     # outra porta pro Streamlit
#
# O app vai abrir em http://localhost:8501 (ou a porta escolhida).

set -euo pipefail

SKIP_DOCKER=0
PORT=8501

for arg in "$@"; do
    case "$arg" in
        --no-docker) SKIP_DOCKER=1 ;;
        --port=*)    PORT="${arg#*=}" ;;
        --help|-h)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "Argumento desconhecido: $arg" >&2; exit 2 ;;
    esac
done

cd "$(dirname "$0")"

# ── Pré-checks ──────────────────────────────────────────────────────
[ -d venv ] || { echo "ERRO: venv não existe. Rode ./setup-local.sh primeiro." >&2; exit 1; }
[ -f db.env.local ] || { echo "ERRO: db.env.local não encontrado." >&2; exit 1; }
[ -f app.py ] || { echo "ERRO: app.py não encontrado (rodou no path errado?)." >&2; exit 1; }

# ── Carrega variáveis de banco ─────────────────────────────────────
# `set -a` exporta tudo que carregar daqui em diante.
set -a
# shellcheck disable=SC1091
source db.env.local
set +a

# ── Sobe Postgres (Docker) ─────────────────────────────────────────
if [ "${SKIP_DOCKER}" = "0" ]; then
    echo "→ Subindo Postgres via Docker..."
    docker compose up -d postgres
    echo "→ Aguardando Postgres ficar pronto..."
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if docker compose exec -T postgres pg_isready -U "${DB_USER}" -d "${DB_NAME}" >/dev/null 2>&1; then
            echo "✓ Postgres pronto"
            break
        fi
        sleep 1
        if [ "$i" = "10" ]; then
            echo "✗ Postgres não respondeu em 10s. Olha os logs:"
            echo "  docker compose logs postgres"
            exit 1
        fi
    done
fi

# ── Cria tabelas (database.criar_tabelas) ───────────────────────────
echo "→ Garantindo schema do banco (criar_tabelas)..."
./venv/bin/python -c "import database as db; db.criar_tabelas()" \
    && echo "✓ schema OK" \
    || { echo "✗ falha ao criar schema"; exit 1; }

# ── Sobe Streamlit ─────────────────────────────────────────────────
echo
echo "──────────────────────────────────────────"
echo "  http://localhost:${PORT}"
echo "  Ctrl+C pra parar Streamlit"
echo "──────────────────────────────────────────"
echo

# Overrides do Streamlit pra DEV LOCAL:
#  - baseUrlPath vazio (em produção é /gestao-de-projetos)
#  - server.address 0.0.0.0 (acessível de outras máquinas da sua rede)
#  - browser.serverAddress=localhost + serverPort=PORT
#    Essas duas controlam a URL que o Streamlit IMPRIME ao iniciar.
#    Sem isso, ele usa o config.toml (que tem 152.92.238.40:80 da
#    produção) e mostra URL errada — embora o servidor de fato rode
#    em localhost:PORT.
exec ./venv/bin/streamlit run app.py \
    --server.port="${PORT}" \
    --server.baseUrlPath="" \
    --server.address="0.0.0.0" \
    --server.headless=true \
    --browser.serverAddress="localhost" \
    --browser.serverPort="${PORT}" \
    --browser.gatherUsageStats=false
