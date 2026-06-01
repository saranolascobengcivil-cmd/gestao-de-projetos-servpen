#!/usr/bin/env bash
# py-local.sh — Roda Python do venv com as envs de banco carregadas.
#
# Equivalente a:
#   set -a; source db.env.local; set +a; ./venv/bin/python <args>
#
# Uso:
#   ./py-local.sh script.py
#   ./py-local.sh -c "import database as db; db.criar_tabelas()"
#   ./py-local.sh -m pip list
#
# Pra usar como REPL interativo:
#   ./py-local.sh

set -euo pipefail
cd "$(dirname "$0")"

[ -f db.env.local ] || { echo "ERRO: db.env.local não encontrado." >&2; exit 1; }
[ -x venv/bin/python ] || { echo "ERRO: venv não está pronto. Rode ./setup-local.sh." >&2; exit 1; }

set -a
# shellcheck disable=SC1091
source db.env.local
set +a

exec ./venv/bin/python "$@"
